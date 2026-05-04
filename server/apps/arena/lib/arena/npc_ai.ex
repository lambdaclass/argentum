defmodule Arena.NpcAi do
  @moduledoc """
  NPC AI tick logic. Pure functions that take MapServer state and return
  `{state, effects}` where effects is a list of side-effect tuples.
  Called every 500ms from MapServer's :npc_ai_tick handler.

  ## Effect types

  - `{:broadcast_visible, x, y, raw}` — send raw packet to all players who can see (x, y)
  - `{:send_to_session, char_id, raw}` — send raw packet to a specific player session
  - `{:broadcast_character_change, entity}` — broadcast a character_change packet for an entity
  """

  require Logger

  alias Arena.Clock
  alias Arena.Combat
  alias Arena.Data.GameData
  alias Arena.Map.Helpers
  alias AoProtocol.Server.Encoder

  @aggro_range 10
  @leash_distance 15
  # VB6: poison tick interval in milliseconds (matches status_ticks.ex)
  @poison_tick_interval 3600

  # ---- Effect Dispatcher ----

  @doc """
  Dispatch a list of effects produced by AI functions.
  Each effect is a tuple describing a side-effect to perform.
  """
  def dispatch_effects(state, effects) do
    Enum.each(effects, fn
      {:broadcast_visible, x, y, raw} ->
        Helpers.broadcast_visible_all(state, x, y, fn pid -> send(pid, {:send_raw, raw}) end)

      {:send_to_session, char_id, raw} ->
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, raw})

      {:broadcast_character_change, entity} ->
        Helpers.broadcast_character_change(state, entity)
    end)
  end

  # ---- Public API ----

  @doc "Process one AI tick for all NPCs on this map. Returns `{state, effects}`."
  def tick(state) do
    # Short-circuit if no players on map
    if map_size(state.players) == 0 do
      process_respawns(state, Clock.now_ms(), [])
    else
      now = Clock.now_ms()

      {state, effects} = process_respawns(state, now, [])
      process_alive_npcs(state, now, effects)
    end
  end

  @doc """
  Despawn a pet. Returns `{state, map_effects}` on the
  `Arena.Map.Effect.t()` shape — callers on the map-layer effects
  contract (e.g. PlayerDeath.handle_player_death/3) thread them up;
  callers on NpcAi's own dispatch chain run them inline via
  `Arena.Map.Effects.run/2`.
  """
  def despawn_pet(state, instance_id, npc) do
    # Delegate to consolidated NPC death handler (pet despawn — no killer, no rewards).
    {nil, state, effects} =
      Arena.Map.NpcDeath.resolve_npc_death(state, instance_id, npc, source: :pet)

    {state, effects}
  end

  # --- Respawns ---

  defp process_respawns(state, now, effects) do
    Enum.reduce(state.npcs_live, {state, effects}, fn {instance_id, npc}, {state, effects} ->
      # Pets don't respawn — they are removed on death/despawn
      if not npc.alive and npc.respawn_at != nil and now >= npc.respawn_at and npc.owner_id == nil do
        respawn_npc(state, instance_id, npc, effects)
      else
        {state, effects}
      end
    end)
  end

  defp respawn_npc(state, instance_id, npc, effects) do
    npc_def = GameData.get_npc(npc.npc_id)
    x = npc.spawn_x
    y = npc.spawn_y

    # Check if spawn tile is free
    if Helpers.get_occupancy(state.occupancy, x, y) == nil do
      hp =
        if npc_def do
          if npc_def.max_hp > npc_def.min_hp, do: Enum.random(npc_def.min_hp..npc_def.max_hp), else: npc_def.max_hp
        else
          npc.max_hp
        end

      npc = %{
        npc
        | hp: max(hp, 1),
          alive: true,
          target_id: nil,
          x: x,
          y: y,
          respawn_at: nil,
          next_attack_at: -1_000_000_000_000,
          next_move_at: -1_000_000_000_000,
          returning_to_spawn: false,
          exp_count: if(npc_def, do: npc_def.give_exp || 0, else: 0)
      }

      occupancy = Helpers.set_occupancy(state.occupancy, x, y, {:npc, instance_id})
      state = %{state | occupancy: occupancy}
      state = put_in(state.npcs_live[instance_id], npc)

      # Collect broadcast effect for NPC creation
      effects =
        if npc_def do
          raw = Encoder.encode(Arena.Map.Helpers.npc_create_packet(npc, npc_def))
          effects ++ [{:broadcast_visible, x, y, raw}]
        else
          effects
        end

      {state, effects}
    else
      # Spawn blocked, try again next tick
      {state, effects}
    end
  end

  # --- Alive NPC processing ---

  defp process_alive_npcs(state, now, effects) do
    Enum.reduce(state.npcs_live, {state, effects}, fn {instance_id, npc}, {state, effects} ->
      if npc.alive do
        npc_def = GameData.get_npc(npc.npc_id)
        process_single_npc(state, instance_id, npc, npc_def, now, effects)
      else
        {state, effects}
      end
    end)
  end

  # Pet AI — owner_id is set (must match before nil npc_def catch-all)
  defp process_single_npc(state, instance_id, %{owner_id: owner_id} = npc, npc_def, now, effects)
       when owner_id != nil do
    process_pet_npc(state, instance_id, npc, npc_def, now, effects)
  end

  defp process_single_npc(state, _instance_id, _npc, nil, _now, effects), do: {state, effects}

  defp process_single_npc(state, instance_id, npc, npc_def, now, effects) do
    # Skip static/non-hostile NPCs with no target
    if npc_def.movement == 1 and not npc_def.hostile and npc.target_id == nil and
         not npc.returning_to_spawn do
      {state, effects}
    else
      # Check leash: if NPC is returning to spawn, continue returning
      # If NPC is beyond leash distance from spawn, start returning
      {state, npc, effects} = check_leash(state, instance_id, npc, npc_def, now, effects)

      if npc.returning_to_spawn do
        # NPC is returning to spawn — just walk toward spawn, no combat
        state = put_in(state.npcs_live[instance_id], npc)
        {state, effects}
      else
        # Acquire or validate target
        npc = acquire_target(state, npc, npc_def)

        # Move toward target or random walk
        {state, npc, effects} = maybe_move_npc(state, instance_id, npc, npc_def, now, effects)

        # Cast spell if available (before melee)
        {state, npc, effects} = maybe_cast_spell(state, instance_id, npc, npc_def, now, effects)

        # Persist npc updates (target_id, spell cooldowns) before attack
        # so maybe_attack's re-read from state sees the current npc
        state = put_in(state.npcs_live[instance_id], npc)

        # Attack if adjacent to target
        maybe_attack(state, instance_id, npc, npc_def, now, effects)
      end
    end
  end

  # --- Leash logic ---

  # Chebyshev distance from NPC to its spawn point
  defp spawn_distance(npc) do
    max(abs(npc.x - npc.spawn_x), abs(npc.y - npc.spawn_y))
  end

  defp check_leash(state, instance_id, npc, npc_def, now, effects) do
    cond do
      # Already returning — check if we've reached spawn
      npc.returning_to_spawn ->
        if npc.x == npc.spawn_x and npc.y == npc.spawn_y do
          # Arrived at spawn: heal to full, stop returning
          npc = %{npc | hp: npc.max_hp, returning_to_spawn: false}
          state = put_in(state.npcs_live[instance_id], npc)
          {state, npc, effects}
        else
          # Keep walking toward spawn
          interval = max(npc_def.intervalo_movimiento, 200)

          if now >= npc.next_move_at do
            step_toward(state, instance_id, npc, npc.spawn_x, npc.spawn_y, now + interval, effects)
          else
            {state, npc, effects}
          end
        end

      # Beyond leash distance — start returning
      spawn_distance(npc) > @leash_distance ->
        npc = %{npc | target_id: nil, returning_to_spawn: true}
        interval = max(npc_def.intervalo_movimiento, 200)

        if now >= npc.next_move_at do
          step_toward(state, instance_id, npc, npc.spawn_x, npc.spawn_y, now + interval, effects)
        else
          state = put_in(state.npcs_live[instance_id], npc)
          {state, npc, effects}
        end

      # Within leash distance — normal behavior
      true ->
        {state, npc, effects}
    end
  end

  # --- Pet AI ---

  @pet_follow_distance 5
  @pet_idle_range 3
  @pet_aggro_range 8

  defp process_pet_npc(state, instance_id, npc, npc_def, now, effects) do
    case Map.get(state.players, npc.owner_id) do
      nil ->
        # Owner left the map — despawn the pet. despawn_pet/3 returns
        # map-layer Effect.t() values; NpcAi's tick chain dispatches its
        # own different-shaped tuples via dispatch_effects/2, so we run
        # the death effects through the map-layer runner here.
        {state, pet_effects} = despawn_pet(state, instance_id, npc)
        Arena.Map.Effects.run(state, pet_effects)
        {state, effects}

      owner ->
        if owner.dead or npc.pet_mode == :stand do
          # Owner is dead or pet is in stand mode — idle in place
          {state, effects}
        else
          dist_x = abs(npc.x - owner.x)
          dist_y = abs(npc.y - owner.y)
          interval = if npc_def, do: max(npc_def.intervalo_movimiento, 200), else: 500

          cond do
            # Owner is far away — follow
            dist_x > @pet_follow_distance or dist_y > @pet_follow_distance ->
              if now >= npc.next_move_at do
                {state, _npc, effects} =
                  step_toward(state, instance_id, npc, owner.x, owner.y, now + interval, effects)

                {state, effects}
              else
                {state, effects}
              end

            # Look for nearby hostile wild NPC to attack
            true ->
              case find_nearest_wild_npc(state, npc) do
                nil ->
                  # No enemy nearby — idle with random movement
                  pet_idle(state, instance_id, npc, owner, now, interval, effects)

                {target_instance_id, target_npc} ->
                  if adjacent?(npc.x, npc.y, target_npc.x, target_npc.y) do
                    maybe_pet_attack(state, instance_id, npc, npc_def, now, target_instance_id, target_npc, effects)
                  else
                    if now >= npc.next_move_at do
                      {state, _npc, effects} =
                        step_toward(state, instance_id, npc, target_npc.x, target_npc.y, now + interval, effects)

                      {state, effects}
                    else
                      {state, effects}
                    end
                  end
              end
          end
        end
    end
  end

  defp pet_idle(state, instance_id, npc, owner, now, interval, effects) do
    if now >= npc.next_move_at and :rand.uniform(4) == 1 do
      {dx, dy} = Enum.random([{0, -1}, {0, 1}, {-1, 0}, {1, 0}])
      nx = npc.x + dx
      ny = npc.y + dy

      if abs(nx - owner.x) <= @pet_idle_range and abs(ny - owner.y) <= @pet_idle_range do
        {state, _npc, effects} = move_npc_to(state, instance_id, npc, nx, ny, now + interval, effects)
        {state, effects}
      else
        npc = %{npc | next_move_at: now + interval}
        {put_in(state.npcs_live[instance_id], npc), effects}
      end
    else
      {state, effects}
    end
  end

  # Find the nearest alive wild (non-pet) hostile NPC within aggro range of the pet.
  defp find_nearest_wild_npc(state, pet) do
    state.npcs_live
    |> Enum.filter(fn {_id, n} ->
      n.alive and n.owner_id == nil and
        abs(n.x - pet.x) <= @pet_aggro_range and
        abs(n.y - pet.y) <= @pet_aggro_range and
        n.instance_id != pet.instance_id
    end)
    |> Enum.filter(fn {_id, n} ->
      npc_def = GameData.get_npc(n.npc_id)
      # If def is missing, assume hostile (wild NPC without def is anomalous but safe default)
      npc_def == nil or npc_def.hostile
    end)
    |> Enum.min_by(fn {_id, n} -> Helpers.vb6_distancia(n, pet) end, fn -> nil end)
  end

  defp maybe_pet_attack(state, instance_id, npc, npc_def, now, target_instance_id, target_npc, effects) do
    if now < npc.next_attack_at do
      {state, effects}
    else
      interval = if npc_def, do: max(npc_def.intervalo_ataque, 500), else: 1500
      npc = %{npc | next_attack_at: now + interval}
      state = put_in(state.npcs_live[instance_id], npc)

      # Broadcast swing
      swing_raw = Encoder.encode({:char_swing, %{char_index: npc.char_index}})
      effects = effects ++ [{:broadcast_visible, npc.x, npc.y, swing_raw}]

      # Damage calc: use NPC min/max hit from def
      raw_damage =
        if npc_def && npc_def.max_hit > npc_def.min_hit do
          Enum.random(npc_def.min_hit..npc_def.max_hit)
        else
          if npc_def, do: max(npc_def.min_hit, 1), else: 1
        end

      target_def = GameData.get_npc(target_npc.npc_id)
      defense = if target_def, do: target_def.def, else: 0
      final_damage = max(raw_damage - defense, 0)
      new_hp = max(target_npc.hp - final_damage, 0)
      target_npc = %{target_npc | hp: new_hp}

      if new_hp <= 0 do
        # Target NPC died — delegate to consolidated death handler. Run the
        # resulting map-effects inline; NpcAi's own effect-dispatch chain
        # (dispatch_effects/2) carries different-shaped tuples.
        {nil, state, death_effects} =
          Arena.Map.NpcDeath.resolve_npc_death(state, target_instance_id, target_npc, source: :pet)

        Arena.Map.Effects.run(state, death_effects)
        {state, effects}
      else
        {put_in(state.npcs_live[target_instance_id], target_npc), effects}
      end
    end
  end

  # --- Target acquisition ---

  defp acquire_target(state, npc, npc_def) do
    cond do
      # Validate existing target
      npc.target_id != nil ->
        case Map.get(state.players, npc.target_id) do
          nil ->
            %{npc | target_id: nil}

          player ->
            if player.dead or player.invisible or Map.get(player, :oculto, false) or abs(player.x - npc.x) > @aggro_range or
                 abs(player.y - npc.y) > @aggro_range do
              %{npc | target_id: nil}
            else
              npc
            end
        end

      # Hostile NPC: find nearest player
      npc_def.hostile ->
        nearest = find_nearest_player(state, npc)
        if nearest, do: %{npc | target_id: nearest}, else: npc

      true ->
        npc
    end
  end

  # VB6: nearest player uses Chebyshev distance (max of abs deltas),
  # consistent with the aggro range filter which also uses Chebyshev.
  defp find_nearest_player(state, npc) do
    state.players
    |> Enum.filter(fn {_id, p} ->
      not p.dead and not p.invisible and not Map.get(p, :oculto, false) and abs(p.x - npc.x) <= @aggro_range and
        abs(p.y - npc.y) <= @aggro_range
    end)
    |> Enum.min_by(fn {_id, p} -> max(abs(p.x - npc.x), abs(p.y - npc.y)) end, fn -> nil end)
    |> case do
      nil -> nil
      {id, _p} -> id
    end
  end

  # --- Movement ---

  defp maybe_move_npc(state, instance_id, npc, npc_def, now, effects) do
    interval = max(npc_def.intervalo_movimiento, 200)

    if now < npc.next_move_at do
      {state, npc, effects}
    else
      cond do
        # Chase target
        npc.target_id != nil ->
          case Map.get(state.players, npc.target_id) do
            nil ->
              {state, npc, effects}

            target ->
              if adjacent?(npc.x, npc.y, target.x, target.y) do
                {state, npc, effects}
              else
                step_toward(state, instance_id, npc, target.x, target.y, now + interval, effects)
              end
          end

        # Random walk
        npc_def.movement == 2 ->
          if :rand.uniform(4) == 1 do
            {dx, dy} = Enum.random([{0, -1}, {0, 1}, {-1, 0}, {1, 0}])
            nx = npc.x + dx
            ny = npc.y + dy

            # Stay near spawn
            if abs(nx - npc.spawn_x) <= 5 and abs(ny - npc.spawn_y) <= 5 do
              move_npc_to(state, instance_id, npc, nx, ny, now + interval, effects)
            else
              npc = %{npc | next_move_at: now + interval}
              state = put_in(state.npcs_live[instance_id], npc)
              {state, npc, effects}
            end
          else
            {state, npc, effects}
          end

        true ->
          {state, npc, effects}
      end
    end
  end

  defp move_npc_to(state, instance_id, npc, nx, ny, next_move_at, effects) do
    if step_allowed?(state, nx, ny) do
      apply_step(state, instance_id, npc, nx, ny, next_move_at, effects)
    else
      block_step(state, instance_id, npc, next_move_at, effects)
    end
  end

  # --- NPC Spell Casting ---

  @npc_spell_range 10

  defp maybe_cast_spell(state, instance_id, npc, npc_def, now, effects) do
    if npc_def.lanza_spells == 0 or npc_def.spells == [] or now < npc.next_spell_at do
      {state, npc, effects}
    else
      case select_npc_spell(state, npc, npc_def) do
        nil ->
          {state, npc, effects}

        {spell_def, spell_target} ->
          # VB6: cooldown uses NPC's attack interval, not a fixed constant
          cooldown = max(npc_def.intervalo_ataque, 2000)
          npc = %{npc | next_spell_at: now + cooldown}
          state = put_in(state.npcs_live[instance_id], npc)
          {state, effects} = apply_npc_spell(state, npc, npc_def, spell_def, spell_target, effects)
          {state, npc, effects}
      end
    end
  end

  defp select_npc_spell(state, npc, npc_def) do
    spells = Enum.map(npc_def.spells, &GameData.get_spell/1) |> Enum.reject(&is_nil/1)

    # Priority 1: Self-heal if HP below 50% (VB6 behavior)
    heal =
      if npc.hp < div(npc.max_hp, 2) do
        Enum.find(spells, fn s -> s.sube_hp == 1 or s.sanacion end)
      end

    if heal, do: throw({:found, heal, {:self, npc}})

    # Priority 2-3 require a valid target
    target_player = if npc.target_id, do: Map.get(state.players, npc.target_id)

    if target_player && not target_player.dead do
      dist = Helpers.vb6_distancia(target_player, npc)

      if dist <= @npc_spell_range do
        # Priority 2: Paralyze if target not already paralyzed
        para =
          if not target_player.paralyzed do
            Enum.find(spells, fn s -> s.paraliza end)
          end

        if para, do: throw({:found, para, {:player, npc.target_id}})

        # Priority 3: Damage spell
        dmg = Enum.find(spells, fn s -> s.sube_hp == 2 end)
        if dmg, do: throw({:found, dmg, {:player, npc.target_id}})
      end
    end

    nil
  catch
    {:found, spell_def, target} -> {spell_def, target}
  end

  defp apply_npc_spell(state, npc, npc_def, spell_def, target, effects) do
    # Broadcast FX
    effects =
      if spell_def.fx_grh > 0 do
        fx_char =
          case target do
            {:player, tid} ->
              case Map.get(state.players, tid) do
                nil -> npc.char_index
                p -> p.char_index
              end

            {:self, _} ->
              npc.char_index
          end

        fx_raw =
          Encoder.encode(
            {:create_fx, %{char_index: fx_char, fx: spell_def.fx_grh, loops: spell_def.loops, x: npc.x, y: npc.y}}
          )

        effects ++ [{:broadcast_visible, npc.x, npc.y, fx_raw}]
      else
        effects
      end

    effects =
      if spell_def.wav > 0 do
        wav_raw = Encoder.encode({:play_wave, %{wav: spell_def.wav, x: npc.x, y: npc.y}})
        effects ++ [{:broadcast_visible, npc.x, npc.y, wav_raw}]
      else
        effects
      end

    case target do
      {:self, _npc} ->
        # Self-heal
        heal =
          if spell_def.max_hp > spell_def.min_hp,
            do: Enum.random(spell_def.min_hp..spell_def.max_hp),
            else: max(spell_def.min_hp, 1)

        npc_now = Map.get(state.npcs_live, npc.instance_id, npc)
        healed = %{npc_now | hp: min(npc_now.hp + heal, npc_now.max_hp)}
        {put_in(state.npcs_live[npc.instance_id], healed), effects}

      {:player, target_id} ->
        case Map.get(state.players, target_id) do
          nil ->
            {state, effects}

          player ->
            cond do
              # Paralysis spell
              spell_def.paraliza ->
                now = Clock.now_ms()
                duration_ms = max((spell_def.duration || 0) * 1000, 3000)
                buff = %{type: :paralyzed, expires_at: now + div(duration_ms, 2)}
                buffs = [buff | Enum.reject(player.buffs, &(&1.type == :paralyzed))]
                player = %{player | paralyzed: true, buffs: buffs}

                effects =
                  effects ++
                    [
                      {:send_to_session, target_id,
                       Encoder.encode({:console_msg, %{message: "Has sido paralizado!", font_index: 5}})}
                    ]

                players = Map.put(state.players, target_id, player)
                {%{state | players: players}, effects}

              # Damage spell
              spell_def.sube_hp == 2 ->
                damage = Combat.spell_damage(spell_def.min_hp, spell_def.max_hp, npc_def_level(npc_def), false)
                new_hp = max(player.hp - damage, 0)
                player = %{player | hp: new_hp}

                effects =
                  effects ++
                    [
                      {:send_to_session, target_id, Encoder.encode({:npc_hit_user, %{damage: damage}})},
                      {:send_to_session, target_id, Encoder.encode({:update_hp, %{min_hp: new_hp}})}
                    ]

                {player, state, effects} =
                  if new_hp <= 0 do
                    effects =
                      effects ++
                        [
                          {:send_to_session, target_id, Encoder.encode({:npc_kill_user, %{}})},
                          {:send_to_session, target_id,
                           Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})}
                        ]

                    {player, state, pd_effects} =
                      Arena.Map.PlayerDeath.handle_player_death(state, target_id, player)

                    Arena.Map.Effects.run(state, pd_effects)
                    {player, state, effects}
                  else
                    {player, state, effects}
                  end

                players = Map.put(state.players, target_id, player)
                state = %{state | players: players}

                effects =
                  if player.dead do
                    effects ++ [{:broadcast_character_change, player}]
                  else
                    effects
                  end

                {state, effects}

              true ->
                {state, effects}
            end
        end
    end
  end

  # NPC spells use the actual npc_level from the NPC definition for damage scaling.
  # Falls back to 1 if the level is 0 or nil.
  defp npc_def_level(%{npc_level: level}) when is_integer(level) and level > 0, do: level
  defp npc_def_level(_npc_def), do: 1

  # --- Attack ---

  defp maybe_attack(state, instance_id, npc, npc_def, now, effects) do
    # Re-read npc from state (may have been updated by movement)
    npc = Map.get(state.npcs_live, instance_id, npc)

    if npc.target_id == nil or not npc.alive or now < npc.next_attack_at do
      {state, effects}
    else
      case Map.get(state.players, npc.target_id) do
        nil ->
          {state, effects}

        player ->
          if not adjacent?(npc.x, npc.y, player.x, player.y) do
            {state, effects}
          else
            interval = max(npc_def.intervalo_ataque, 500)
            npc = %{npc | next_attack_at: now + interval}
            state = put_in(state.npcs_live[instance_id], npc)

            # Broadcast swing
            swing_raw = Encoder.encode({:char_swing, %{char_index: npc.char_index}})
            effects = effects ++ [{:broadcast_visible, npc.x, npc.y, swing_raw}]

            # Hit check
            def_class_id = Helpers.class_atom_to_id(player.class)
            def_tactics = Map.get(player.skills, :combat_tactics, 50)
            hit_roll = Combat.npc_hit_chance(npc_def.poder_ataque, def_tactics, player.agi, player.level, def_class_id)

            if :rand.uniform(100) <= hit_roll do
              raw_damage = Combat.npc_damage(npc_def.min_hit, npc_def.max_hit)

              # Player defense
              {min_def, max_def} = Arena.CombatStats.effective_defense(player.equipment)
              {final_damage, _loc} = Combat.apply_defense(raw_damage, {min_def, max_def})

              new_hp = max(player.hp - final_damage, 0)
              player = %{player | hp: new_hp}

              # Send damage to player
              target_char_id = npc.target_id

              effects =
                effects ++
                  [
                    {:send_to_session, target_char_id, Encoder.encode({:npc_hit_user, %{damage: final_damage}})},
                    {:send_to_session, target_char_id, Encoder.encode({:update_hp, %{min_hp: new_hp}})}
                  ]

              # VB6: NPC melee poison — if npc_def.veneno > 0 and player is not already
              # poisoned, apply a poison debuff. Duration = veneno * 1000 ms.
              {player, effects} =
                if npc_def.veneno > 0 and not Map.get(player, :poisoned, false) and new_hp > 0 and :rand.uniform(100) < 30 do
                  poison_now = Clock.now_ms()
                  duration_ms = npc_def.veneno * 1000
                  buff = %{type: :poisoned, expires_at: poison_now + duration_ms, next_tick: poison_now + @poison_tick_interval}
                  buffs = [buff | Enum.reject(Map.get(player, :buffs, []), &(&1.type == :poisoned))]
                  player = %{player | poisoned: true, buffs: buffs}

                  effects =
                    effects ++
                      [
                        {:send_to_session, target_char_id,
                         Encoder.encode({:console_msg, %{message: "Has sido envenenado!", font_index: 5}})}
                      ]

                  {player, effects}
                else
                  {player, effects}
                end

              {player, state, effects} =
                if new_hp <= 0 do
                  effects =
                    effects ++
                      [
                        {:send_to_session, target_char_id, Encoder.encode({:npc_kill_user, %{}})},
                        {:send_to_session, target_char_id,
                         Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})}
                      ]

                  npc = %{npc | target_id: nil}
                  state = put_in(state.npcs_live[instance_id], npc)

                  {player, state, pd_effects} =
                    Arena.Map.PlayerDeath.handle_player_death(state, target_char_id, player)

                  Arena.Map.Effects.run(state, pd_effects)
                  {player, state, effects}
                else
                  {player, state, effects}
                end

              players = Map.put(state.players, target_char_id, player)
              state = %{state | players: players}

              effects =
                if player.dead do
                  effects ++ [{:broadcast_character_change, player}]
                else
                  effects
                end

              {state, effects}
            else
              {state, effects}
            end
          end
      end
    end
  end

  # --- Utility ---

  defp adjacent?(x1, y1, x2, y2), do: abs(x1 - x2) <= 1 and abs(y1 - y2) <= 1

  # VB6 NPCs move on a 4-directional grid (N/E/S/W). Returns the cardinal
  # steps to attempt, in priority order: prefer the larger-delta axis, fall
  # back to the perpendicular axis when the primary tile is blocked. Ties go
  # to the X axis.
  defp preferred_cardinal_steps(x1, y1, x2, y2) do
    dx = step_sign(x2 - x1)
    dy = step_sign(y2 - y1)

    cond do
      dx == 0 and dy == 0 -> []
      dx == 0 -> [{0, dy}]
      dy == 0 -> [{dx, 0}]
      abs(x2 - x1) >= abs(y2 - y1) -> [{dx, 0}, {0, dy}]
      true -> [{0, dy}, {dx, 0}]
    end
  end

  defp step_sign(d) when d > 0, do: 1
  defp step_sign(d) when d < 0, do: -1
  defp step_sign(_), do: 0

  defp step_toward(state, instance_id, npc, target_x, target_y, next_move_at, effects) do
    steps = preferred_cardinal_steps(npc.x, npc.y, target_x, target_y)
    attempt_steps(state, instance_id, npc, steps, next_move_at, effects)
  end

  defp attempt_steps(state, instance_id, npc, [], next_move_at, effects) do
    block_step(state, instance_id, npc, next_move_at, effects)
  end

  defp attempt_steps(state, instance_id, npc, [{dx, dy} | rest], next_move_at, effects) do
    nx = npc.x + dx
    ny = npc.y + dy

    if step_allowed?(state, nx, ny) do
      apply_step(state, instance_id, npc, nx, ny, next_move_at, effects)
    else
      attempt_steps(state, instance_id, npc, rest, next_move_at, effects)
    end
  end

  defp step_allowed?(state, nx, ny) do
    nx >= 1 and nx <= Helpers.map_width() and ny >= 1 and ny <= Helpers.map_height() and
      TileGrid.is_walkable(state.map_id, nx, ny) and
      Helpers.get_occupancy(state.occupancy, nx, ny) == nil
  end

  defp apply_step(state, instance_id, npc, nx, ny, next_move_at, effects) do
    occupancy = Helpers.clear_occupancy(state.occupancy, npc.x, npc.y)
    occupancy = Helpers.set_occupancy(occupancy, nx, ny, {:npc, instance_id})

    npc = %{npc | x: nx, y: ny, next_move_at: next_move_at}
    state = %{state | occupancy: occupancy}
    state = put_in(state.npcs_live[instance_id], npc)

    move_raw = Encoder.encode({:character_move, %{char_index: npc.char_index, x: nx, y: ny}})
    effects = effects ++ [{:broadcast_visible, nx, ny, move_raw}]

    {state, npc, effects}
  end

  defp block_step(state, instance_id, npc, next_move_at, effects) do
    npc = %{npc | next_move_at: next_move_at}
    state = put_in(state.npcs_live[instance_id], npc)
    {state, npc, effects}
  end
end
