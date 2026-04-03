defmodule Arena.NpcAi do
  @moduledoc """
  NPC AI tick logic. Pure function that takes and returns MapServer state.
  Called every 500ms from MapServer's :npc_ai_tick handler.
  """

  alias Arena.Combat
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @aggro_range 10
  @map_width 100
  @map_height 100

  @doc "Process one AI tick for all NPCs on this map."
  def tick(state) do
    # Short-circuit if no players on map
    if map_size(state.players) == 0 do
      process_respawns(state, System.monotonic_time(:millisecond))
    else
      now = System.monotonic_time(:millisecond)

      state
      |> process_respawns(now)
      |> process_alive_npcs(now)
    end
  end

  # --- Respawns ---

  defp process_respawns(state, now) do
    Enum.reduce(state.npcs_live, state, fn {instance_id, npc}, state ->
      if not npc.alive and npc.respawn_at != nil and now >= npc.respawn_at do
        respawn_npc(state, instance_id, npc)
      else
        state
      end
    end)
  end

  defp respawn_npc(state, instance_id, npc) do
    npc_def = GameData.get_npc(npc.npc_id)
    x = npc.spawn_x
    y = npc.spawn_y

    # Check if spawn tile is free
    if get_occupancy(state.occupancy, x, y) == nil do
      hp = if npc_def do
        if npc_def.max_hp > npc_def.min_hp, do: Enum.random(npc_def.min_hp..npc_def.max_hp), else: npc_def.max_hp
      else
        npc.max_hp
      end

      npc = %{npc |
        hp: max(hp, 1), alive: true, target_id: nil,
        x: x, y: y, respawn_at: nil,
        next_attack_at: -1_000_000_000_000,
        next_move_at: -1_000_000_000_000
      }

      occupancy = set_occupancy(state.occupancy, x, y, {:npc, instance_id})
      state = %{state | occupancy: occupancy}
      state = put_in(state.npcs_live[instance_id], npc)

      # Broadcast NPC creation to nearby players
      if npc_def do
        raw = Encoder.encode(Arena.Map.Helpers.npc_create_packet(npc, npc_def))
        broadcast_to_nearby_players(state, x, y, raw)
      end

      state
    else
      # Spawn blocked, try again next tick
      state
    end
  end

  # --- Alive NPC processing ---

  defp process_alive_npcs(state, now) do
    Enum.reduce(state.npcs_live, state, fn {instance_id, npc}, state ->
      if npc.alive do
        npc_def = GameData.get_npc(npc.npc_id)
        process_single_npc(state, instance_id, npc, npc_def, now)
      else
        state
      end
    end)
  end

  defp process_single_npc(state, _instance_id, _npc, nil, _now), do: state

  defp process_single_npc(state, instance_id, npc, npc_def, now) do
    # Skip static/non-hostile NPCs with no target
    if npc_def.movement == 1 and not npc_def.hostile and npc.target_id == nil do
      state
    else
      # Acquire or validate target
      npc = acquire_target(state, npc, npc_def)

      # Move toward target or random walk
      {state, npc} = maybe_move_npc(state, instance_id, npc, npc_def, now)

      # Cast spell if available (before melee)
      {state, npc} = maybe_cast_spell(state, instance_id, npc, npc_def, now)

      # Attack if adjacent to target
      state = maybe_attack(state, instance_id, npc, npc_def, now)

      state
    end
  end

  # --- Target acquisition ---

  defp acquire_target(state, npc, npc_def) do
    cond do
      # Validate existing target
      npc.target_id != nil ->
        case Map.get(state.players, npc.target_id) do
          nil -> %{npc | target_id: nil}
          player ->
            if player.dead or player.invisible or abs(player.x - npc.x) > @aggro_range or abs(player.y - npc.y) > @aggro_range do
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

  defp find_nearest_player(state, npc) do
    state.players
    |> Enum.filter(fn {_id, p} ->
      not p.dead and not p.invisible and abs(p.x - npc.x) <= @aggro_range and abs(p.y - npc.y) <= @aggro_range
    end)
    |> Enum.min_by(fn {_id, p} -> abs(p.x - npc.x) + abs(p.y - npc.y) end, fn -> nil end)
    |> case do
      nil -> nil
      {id, _p} -> id
    end
  end

  # --- Movement ---

  defp maybe_move_npc(state, instance_id, npc, npc_def, now) do
    interval = max(npc_def.intervalo_movimiento, 200)

    if now < npc.next_move_at do
      {state, npc}
    else
      cond do
        # Chase target
        npc.target_id != nil ->
          case Map.get(state.players, npc.target_id) do
            nil ->
              {state, npc}

            target ->
              if adjacent?(npc.x, npc.y, target.x, target.y) do
                {state, npc}
              else
                {dx, dy} = direction_toward(npc.x, npc.y, target.x, target.y)
                move_npc_to(state, instance_id, npc, npc.x + dx, npc.y + dy, now + interval)
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
              move_npc_to(state, instance_id, npc, nx, ny, now + interval)
            else
              npc = %{npc | next_move_at: now + interval}
              state = put_in(state.npcs_live[instance_id], npc)
              {state, npc}
            end
          else
            {state, npc}
          end

        true ->
          {state, npc}
      end
    end
  end

  defp move_npc_to(state, instance_id, npc, nx, ny, next_move_at) do
    if nx >= 1 and nx <= @map_width and ny >= 1 and ny <= @map_height and
       TileGrid.is_walkable(state.map_id, nx, ny) and
       get_occupancy(state.occupancy, nx, ny) == nil do
      occupancy = clear_occupancy(state.occupancy, npc.x, npc.y)
      occupancy = set_occupancy(occupancy, nx, ny, {:npc, instance_id})

      npc = %{npc | x: nx, y: ny, next_move_at: next_move_at}
      state = %{state | occupancy: occupancy}
      state = put_in(state.npcs_live[instance_id], npc)

      # Broadcast movement to nearby players
      move_raw = Encoder.encode({:character_move, %{char_index: npc.char_index, x: nx, y: ny}})
      broadcast_to_nearby_players(state, nx, ny, move_raw)

      {state, npc}
    else
      npc = %{npc | next_move_at: next_move_at}
      state = put_in(state.npcs_live[instance_id], npc)
      {state, npc}
    end
  end

  # --- NPC Spell Casting ---

  @npc_spell_range 10

  defp maybe_cast_spell(state, instance_id, npc, npc_def, now) do
    if npc_def.lanza_spells == 0 or npc_def.spells == [] or now < npc.next_spell_at do
      {state, npc}
    else
      case select_npc_spell(state, npc, npc_def) do
        nil -> {state, npc}
        {spell_def, spell_target} ->
          # VB6: cooldown uses NPC's attack interval, not a fixed constant
          cooldown = max(npc_def.intervalo_ataque, 2000)
          npc = %{npc | next_spell_at: now + cooldown}
          state = put_in(state.npcs_live[instance_id], npc)
          state = apply_npc_spell(state, npc, spell_def, spell_target)
          {state, npc}
      end
    end
  end

  defp select_npc_spell(state, npc, npc_def) do
    spells = Enum.map(npc_def.spells, &GameData.get_spell/1) |> Enum.reject(&is_nil/1)

    # Priority 1: Self-heal if HP below 50% (VB6 behavior)
    heal = if npc.hp < div(npc.max_hp, 2) do
      Enum.find(spells, fn s -> s.sube_hp == 1 or s.sanacion end)
    end
    if heal, do: throw({:found, heal, {:self, npc}})

    # Priority 2-3 require a valid target
    target_player = if npc.target_id, do: Map.get(state.players, npc.target_id)

    if target_player && not target_player.dead do
      dist = abs(target_player.x - npc.x) + abs(target_player.y - npc.y)

      if dist <= @npc_spell_range do
        # Priority 2: Paralyze if target not already paralyzed
        para = if not target_player.paralyzed do
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

  defp apply_npc_spell(state, npc, spell_def, target) do
    # Broadcast FX
    if spell_def.fx_grh > 0 do
      fx_char = case target do
        {:player, tid} -> case Map.get(state.players, tid) do nil -> npc.char_index; p -> p.char_index end
        {:self, _} -> npc.char_index
      end
      fx_raw = Encoder.encode({:create_fx, %{char_index: fx_char, fx: spell_def.fx_grh, loops: spell_def.loops, x: npc.x, y: npc.y}})
      broadcast_to_nearby_players(state, npc.x, npc.y, fx_raw)
    end

    if spell_def.wav > 0 do
      wav_raw = Encoder.encode({:play_wave, %{wav: spell_def.wav, x: npc.x, y: npc.y}})
      broadcast_to_nearby_players(state, npc.x, npc.y, wav_raw)
    end

    case target do
      {:self, _npc} ->
        # Self-heal
        heal = if spell_def.max_hp > spell_def.min_hp,
          do: Enum.random(spell_def.min_hp..spell_def.max_hp),
          else: max(spell_def.min_hp, 1)
        npc_now = Map.get(state.npcs_live, npc.instance_id, npc)
        healed = %{npc_now | hp: min(npc_now.hp + heal, npc_now.max_hp)}
        put_in(state.npcs_live[npc.instance_id], healed)

      {:player, target_id} ->
        case Map.get(state.players, target_id) do
          nil -> state
          player ->
            cond do
              # Paralysis spell
              spell_def.paraliza ->
                now = System.monotonic_time(:millisecond)
                duration_ms = max((spell_def.duration || 0) * 1000, 3000)
                buff = %{type: :paralyzed, expires_at: now + div(duration_ms, 2)}
                buffs = [buff | Enum.reject(player.buffs, &(&1.type == :paralyzed))]
                player = %{player | paralyzed: true, buffs: buffs}
                pid = Map.get(state.sessions, target_id)
                if pid do
                  send(pid, {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido paralizado!", font_index: 5}})})
                end
                players = Map.put(state.players, target_id, player)
                %{state | players: players}

              # Damage spell
              spell_def.sube_hp == 2 ->
                damage = Combat.spell_damage(spell_def.min_hp, spell_def.max_hp, npc_def_level(spell_def), false)
                new_hp = max(player.hp - damage, 0)
                player = %{player | hp: new_hp}
                pid = Map.get(state.sessions, target_id)
                if pid do
                  send(pid, {:send_raw, Encoder.encode({:npc_hit_user, %{damage: damage}})})
                  send(pid, {:send_raw, Encoder.encode({:update_hp, %{min_hp: new_hp}})})
                end
                player = if new_hp <= 0 do
                  if pid do
                    send(pid, {:send_raw, Encoder.encode({:npc_kill_user, %{}})})
                    send(pid, {:send_raw, Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})})
                  end
                  %{player | dead: true}
                else
                  player
                end
                players = Map.put(state.players, target_id, player)
                %{state | players: players}

              true -> state
            end
        end
    end
  end

  # NPC spells use npc_level from the npc_def, but we don't have it here.
  # Use a constant effective level for NPC spell damage scaling.
  defp npc_def_level(_spell_def), do: 20

  # --- Attack ---

  defp maybe_attack(state, instance_id, npc, npc_def, now) do
    # Re-read npc from state (may have been updated by movement)
    npc = Map.get(state.npcs_live, instance_id, npc)

    if npc.target_id == nil or not npc.alive or now < npc.next_attack_at do
      state
    else
      case Map.get(state.players, npc.target_id) do
        nil -> state
        player ->
          if not adjacent?(npc.x, npc.y, player.x, player.y) do
            state
          else
            interval = max(npc_def.intervalo_ataque, 500)
            npc = %{npc | next_attack_at: now + interval}
            state = put_in(state.npcs_live[instance_id], npc)

            # Broadcast swing
            swing_raw = Encoder.encode({:char_swing, %{char_index: npc.char_index}})
            broadcast_to_nearby_players(state, npc.x, npc.y, swing_raw)

            # Hit check
            def_class_id = class_atom_to_id(player.class)
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
              pid = Map.get(state.sessions, npc.target_id)
              if pid do
                send(pid, {:send_raw, Encoder.encode({:npc_hit_user, %{damage: final_damage}})})
                send(pid, {:send_raw, Encoder.encode({:update_hp, %{min_hp: new_hp}})})
              end

              {player, state} = if new_hp <= 0 do
                if pid do
                  send(pid, {:send_raw, Encoder.encode({:npc_kill_user, %{}})})
                  send(pid, {:send_raw, Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})})
                end
                npc = %{npc | target_id: nil}
                state = put_in(state.npcs_live[instance_id], npc)
                {%{player | dead: true}, state}
              else
                {player, state}
              end

              players = Map.put(state.players, npc.target_id, player)
              %{state | players: players}
            else
              state
            end
          end
      end
    end
  end

  # --- Utility ---

  defp adjacent?(x1, y1, x2, y2), do: abs(x1 - x2) <= 1 and abs(y1 - y2) <= 1

  defp direction_toward(x1, y1, x2, y2) do
    dx = cond do
      x2 > x1 -> 1
      x2 < x1 -> -1
      true -> 0
    end
    dy = cond do
      y2 > y1 -> 1
      y2 < y1 -> -1
      true -> 0
    end
    # Prefer the axis with greater distance
    if abs(x2 - x1) >= abs(y2 - y1), do: {dx, 0}, else: {0, dy}
  end

  defp broadcast_to_nearby_players(state, _x, _y, raw) do
    for {_cid, pid} <- state.sessions do
      # Simple distance check for all sessions
      send(pid, {:send_raw, raw})
    end
  end

  # Occupancy helpers (duplicated from MapServer for purity)
  defp occ_index(x, y), do: (y - 1) * @map_width + (x - 1)

  defp get_occupancy(occ, x, y) when x >= 1 and x <= @map_width and y >= 1 and y <= @map_height do
    :array.get(occ_index(x, y), occ)
  end
  defp get_occupancy(_occ, _x, _y), do: :out_of_bounds

  defp set_occupancy(occ, x, y, value) when x >= 1 and x <= @map_width and y >= 1 and y <= @map_height do
    :array.set(occ_index(x, y), value, occ)
  end
  defp set_occupancy(occ, _x, _y, _value), do: occ

  defp clear_occupancy(occ, x, y) when x >= 1 and x <= @map_width and y >= 1 and y <= @map_height do
    :array.set(occ_index(x, y), nil, occ)
  end
  defp clear_occupancy(occ, _x, _y), do: occ

  @class_id_map %{
    mago: 1, clerigo: 2, paladin: 3, cazador: 4, trabajador: 5,
    guerrero: 6, ladron: 7, bandido: 8, asesino: 9, druida: 10, bardo: 11, pirata: 12
  }

  defp class_atom_to_id(class_atom), do: Map.get(@class_id_map, class_atom, 6)
end
