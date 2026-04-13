defmodule Arena.Map.CombatHandlers do
  @moduledoc """
  Combat and spell handler logic extracted from MapServer.

  All functions are public (`def`) so MapServer can delegate to them.
  State threading follows the same pattern as the original: functions receive
  the full GenServer state and return either `{:reply, term, state}` (for
  handle_call wrappers) or plain `state` (for internal helpers).
  """

  import Bitwise

  alias Arena.Map.{Helpers, Visibility}
  alias Arena.{Combat, CombatStats, Data.GameData}
  alias AoProtocol.Server.Encoder

  @attack_cooldown_ms 1500
  @ranged_max_distance 18

  @req_weapon 0x001
  @req_shield 0x002
  @req_armor 0x004
  @req_helm 0x008
  @req_projectile 0x020
  @req_ship 0x040
  @req_on_land 0x200
  @req_on_water 0x400

  # VB6: IntervaloVeneno = 90 counter ticks at 40ms (MaybeRunGameEvents) = 3600ms
  @poison_tick_interval 3600

  # VB6 faction PvP maps — used when elemental/faction combat is wired
  @faction_pvp_maps [58, 59, 60, 195, 196]
  _ = @faction_pvp_maps

  @skill_gain_chance 35
  @max_skill 100

  # ==================================================================
  # Attack handlers
  # ==================================================================

  def handle_attack(state, char_id, target_x, target_y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)

        cond do
          now < entity.next_attack_at ->
            {:reply, {:error, :cooldown}, state}

          entity.dead ->
            {:reply, {:error, :dead}, state}

          entity.paralyzed ->
            {:reply, {:error, :paralyzed}, state}

          entity.mounted ->
            {:reply, {:error, :mounted}, state}

          true ->
            entity = Helpers.break_invisibility(entity, state, char_id)
            weapon_id = entity.equipment[:weapon]
            weapon_def = if weapon_id, do: GameData.get_item(weapon_id)
            is_ranged = weapon_def != nil and weapon_def.proyectil > 0

            if is_ranged and target_x != nil and target_y != nil do
              handle_ranged_attack(state, char_id, entity, weapon_def, target_x, target_y, now)
            else
              # Melee attack
              {tx, ty} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
              target = Helpers.get_occupancy(state.occupancy, tx, ty)

              entity = %{entity | next_attack_at: now + @attack_cooldown_ms}

              swing_raw = Encoder.encode({:char_swing, %{char_index: entity.char_index}})

              Visibility.broadcast_visible(state, entity.x, entity.y, char_id, fn pid ->
                send(pid, {:send_raw, swing_raw})
              end)

              state = handle_attack_target(state, char_id, entity, target)
              {:reply, :ok, state}
            end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_ranged_attack(state, char_id, entity, _weapon_def, target_x, target_y, now) do
    cond do
      target_x < 1 or target_x > Helpers.map_width() or target_y < 1 or target_y > Helpers.map_height() ->
        {:reply, {:error, :out_of_range}, state}

      max(abs(entity.x - target_x), abs(entity.y - target_y)) > @ranged_max_distance ->
        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Demasiado lejos.", font_index: 0}})}
        )

        {:reply, {:error, :out_of_range}, state}

      entity.equipment[:municion] == nil ->
        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "No tienes municiones equipadas.", font_index: 0}})}
        )

        {:reply, {:error, :no_ammo}, state}

      true ->
        ammo_id = entity.equipment[:municion]

        ammo_slot_idx =
          Enum.find_index(entity.inventory, fn
            %{item_id: ^ammo_id, equipped: true} -> true
            _ -> false
          end)

        if ammo_slot_idx == nil do
          entity = %{entity | equipment: Map.put(entity.equipment, :municion, nil)}
          players = Map.put(state.players, char_id, entity)
          {:reply, {:error, :no_ammo}, %{state | players: players}}
        else
          ammo_def = GameData.get_item(ammo_id)
          entity = consume_ammo(entity, state, char_id, ammo_slot_idx, ammo_id)
          entity = %{entity | next_attack_at: now + @attack_cooldown_ms}

          swing_raw = Encoder.encode({:char_swing, %{char_index: entity.char_index}})

          Visibility.broadcast_visible(state, entity.x, entity.y, char_id, fn pid ->
            send(pid, {:send_raw, swing_raw})
          end)

          target = Helpers.get_occupancy(state.occupancy, target_x, target_y)

          # Compute extra ammo damage
          {ammo_min, ammo_max} = if ammo_def, do: {ammo_def.min_hit, ammo_def.max_hit}, else: {0, 0}
          opts = [skill: :ranged_weapons, extra_min: ammo_min, extra_max: ammo_max]

          state = handle_attack_target(state, char_id, entity, target, opts)
          {:reply, :ok, state}
        end
    end
  end

  def consume_ammo(entity, state, char_id, slot_idx, ammo_id) do
    slot = Enum.at(entity.inventory, slot_idx)
    new_amount = slot.amount - 1

    {inventory, equipment} =
      if new_amount <= 0 do
        {List.replace_at(entity.inventory, slot_idx, nil), Map.put(entity.equipment, :municion, nil)}
      else
        {List.replace_at(entity.inventory, slot_idx, %{slot | amount: new_amount}), entity.equipment}
      end

    entity = %{entity | inventory: inventory, equipment: equipment}

    # Send inventory update to client
    if new_amount <= 0 do
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw,
         Encoder.encode(
           {:change_inventory_slot, %{slot: slot_idx + 1, obj_index: 0, amount: 0, equipped: false, valor: 0.0}}
         )}
      )
    else
      item_def = GameData.get_item(ammo_id)
      valor = if item_def, do: item_def.valor / 1, else: 0.0

      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw,
         Encoder.encode(
           {:change_inventory_slot,
            %{slot: slot_idx + 1, obj_index: ammo_id, amount: new_amount, equipped: true, valor: valor}}
         )}
      )
    end

    entity
  end

  # Find an inventory slot for an item: existing stack if stackable, or first empty slot
  def find_inventory_slot(entity, item_id, stackable) do
    if stackable do
      # Try to find existing stack first
      idx =
        Enum.find_index(entity.inventory, fn
          %{item_id: ^item_id} -> true
          _ -> false
        end)

      idx || Enum.find_index(entity.inventory, &is_nil/1)
    else
      Enum.find_index(entity.inventory, &is_nil/1)
    end
  end

  def handle_attack_target(state, char_id, entity, target, opts \\ [])

  def handle_attack_target(state, char_id, entity, {:npc, instance_id}, opts) do
    case Map.get(state.npcs_live, instance_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      npc ->
        if not npc.alive do
          players = Map.put(state.players, char_id, entity)
          %{state | players: players}
        else
          npc_def = GameData.get_npc(npc.npc_id)
          {min_weapon, max_weapon} = CombatStats.effective_damage(entity.equipment)
          min_weapon = min_weapon + Keyword.get(opts, :extra_min, 0)
          max_weapon = max_weapon + Keyword.get(opts, :extra_max, 0)

          class_id = Helpers.class_atom_to_id(entity.class)

          skill_name = Keyword.get(opts, :skill, :combat_weapons)
          weapon_skill = Map.get(entity.skills, skill_name, 50)
          npc_evasion = if npc_def, do: npc_def.poder_evasion, else: 0

          hit_roll =
            Combat.hit_chance(
              weapon_skill,
              entity.agi,
              entity.level,
              class_id,
              npc_evasion,
              0,
              if(npc_def, do: npc_def.npc_level, else: 1),
              class_id
            )

          if :rand.uniform(100) <= hit_roll do
            # VB6: base user damage added to weapon damage
            {user_min, user_max} = Combat.base_user_damage(entity.level, class_id)

            raw_damage =
              Combat.melee_damage(min_weapon, max_weapon, entity.str + entity.str_buff, class_id, user_min, user_max)

            npc_defense = if npc_def, do: npc_def.def, else: 0
            final_damage = max(raw_damage - npc_defense, 0)

            # VB6: CalculateElementalTagsModifiers — apply elemental matrix
            final_damage = apply_elemental_modifiers_for_weapon(final_damage, entity, npc_def)

            new_hp = max(npc.hp - final_damage, 0)
            npc = %{npc | hp: new_hp}

            # VB6: weapon skill gain on hit
            entity = maybe_gain_skill(entity, skill_name)

            # Send damage feedback to attacker
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:user_hitted_user, %{char_index: npc.char_index, damage: final_damage}})}
            )

            if new_hp <= 0 do
              # NPC died
              state =
                if npc.owner_id != nil do
                  # Pet died — remove from npcs_live and owner's pet_ids
                  handle_pet_death(state, instance_id, npc)
                else
                  npc = %{
                    npc
                    | alive: false,
                      respawn_at:
                        System.monotonic_time(:millisecond) +
                          if(npc_def, do: npc_def.intervalo_respawn, else: 60) * 1000
                  }

                  put_in(state.npcs_live[instance_id], npc)
                end

              occupancy = Helpers.clear_occupancy(state.occupancy, npc.x, npc.y)
              state = %{state | occupancy: occupancy}

              # Broadcast NPC removal
              remove_raw = Encoder.encode({:character_remove, %{char_index: npc.char_index}})
              Visibility.broadcast_visible_all(state, npc.x, npc.y, fn pid -> send(pid, {:send_raw, remove_raw}) end)

              # Per-hit XP on the killing blow (no XP for killing pets)
              {entity, state} =
                if npc.owner_id == nil do
                  award_hit_xp(state, char_id, entity, final_damage, npc_def, instance_id)
                else
                  {entity, state}
                end

              # Kill rewards (counter, guild XP, gold, loot) — no rewards for killing pets
              state =
                if npc.owner_id == nil do
                  entity = %{entity | npcs_killed: entity.npcs_killed + 1}

                  # Notify invasion system about NPC kill (melee)
                  Arena.Events.InvasionServer.notify_npc_killed(state.map_id, instance_id)

                  # Award guild XP on NPC kill
                  give_exp = if npc_def, do: npc_def.give_exp, else: 0

                  if give_exp > 0 do
                    case Arena.GuildServer.guild_id_for(char_id) do
                      nil -> :ok
                      gid -> Arena.GuildServer.add_guild_exp(gid, max(div(give_exp, 10), 1))
                    end
                  end

                  # VB6: NPCTirarOro — drop gold on the floor at NPC position
                  give_gld = if npc_def, do: npc_def.give_gld, else: 0
                  state = drop_npc_gold(state, npc, give_gld)

                  # Drop loot
                  state = drop_npc_loot(state, npc, npc_def)

                  players = Map.put(state.players, char_id, entity)
                  %{state | players: players}
                else
                  players = Map.put(state.players, char_id, entity)
                  %{state | players: players}
                end

              state
            else
              state = put_in(state.npcs_live[instance_id], npc)
              # NPC acquires target on being hit
              npc = %{npc | target_id: char_id}
              state = put_in(state.npcs_live[instance_id], npc)

              # VB6: per-hit proportional XP (no XP for hitting pets)
              {entity, state} =
                if npc.owner_id == nil do
                  award_hit_xp(state, char_id, entity, final_damage, npc_def, instance_id)
                else
                  {entity, state}
                end

              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            end
          else
            # Miss — NPC still acquires aggro on the attacker (VB6 parity)
            npc = %{npc | target_id: char_id}
            state = put_in(state.npcs_live[instance_id], npc)
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}
          end
        end
    end
  end

  def handle_attack_target(state, char_id, entity, {:player, defender_id}, opts) do
    case Map.get(state.players, defender_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      defender ->
        # VB6: EnReto — in-duel restriction: can only attack duel opponent
        in_duel_attacking_wrong_target =
          entity.in_duel and entity.duel_opponent_id != defender_id

        # VB6: Duel bypasses safe-zone restriction when attacking opponent
        duel_pvp_exception =
          entity.in_duel and entity.duel_opponent_id == defender_id

        cond do
          in_duel_attacking_wrong_target ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode(
                 {:console_msg, %{message: "Solo puedes atacar a tu oponente de reto.", font_index: 0}}
               )}
            )

            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          entity.safe_mode and not duel_pvp_exception ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Tienes el seguro activado.", font_index: 0}})}
            )

            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          same_faction?(entity, defender) and not duel_pvp_exception ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "No puedes atacar a un miembro de tu faccion.", font_index: 0}})}
            )

            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          party_safe_block?(char_id, defender) and not duel_pvp_exception ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "No puedes atacar a un miembro de tu grupo.", font_index: 0}})}
            )

            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          state.meta.safe_zone and not faction_pvp_exception?(state.map_id, entity, defender) and
              not duel_pvp_exception ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Zona segura.", font_index: 0}})}
            )

            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          defender.dead ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          true ->
            class_id = Helpers.class_atom_to_id(entity.class)
            def_class_id = Helpers.class_atom_to_id(defender.class)
            {min_weapon, max_weapon} = CombatStats.effective_damage(entity.equipment)
            min_weapon = min_weapon + Keyword.get(opts, :extra_min, 0)
            max_weapon = max_weapon + Keyword.get(opts, :extra_max, 0)

            skill_name = Keyword.get(opts, :skill, :combat_weapons)
            weapon_skill = Map.get(entity.skills, skill_name, 50)
            def_tactics = Map.get(defender.skills, :combat_tactics, 50)

            hit_roll =
              Combat.hit_chance(
                weapon_skill,
                entity.agi + entity.agi_buff,
                entity.level,
                class_id,
                def_tactics,
                defender.agi + defender.agi_buff,
                defender.level,
                def_class_id
              )

            # VB6: meditating reduces evasion by 25%
            hit_roll = Combat.adjust_hit_for_meditate(hit_roll, defender.meditating)

            if :rand.uniform(100) <= hit_roll do
              shield_pct = CombatStats.shield_defense_pct(defender.equipment)
              def_skill = Map.get(defender.skills, :combat_defense, 50)

              # VB6: shield block uses attacker's weapon skill, not tactics
              if shield_pct > 0 and
                   Combat.shield_block?(shield_pct, def_skill, Map.get(entity.skills, :combat_weapons, 50)) do
                # VB6: defense skill gain on block
                defender = maybe_gain_skill(defender, :combat_defense)

                Helpers.send_to_session(
                  state.sessions,
                  defender_id,
                  {:send_raw, Encoder.encode({:blocked_with_shield_user, %{}})}
                )

                block_raw = Encoder.encode({:blocked_with_shield_other, %{char_index: defender.char_index}})

                Visibility.broadcast_visible(state, defender.x, defender.y, defender_id, fn pid ->
                  send(pid, {:send_raw, block_raw})
                end)

                players =
                  state.players
                  |> Map.put(char_id, entity)
                  |> Map.put(defender_id, defender)

                %{state | players: players}
              else
                # VB6: base user damage added to weapon damage
                {user_min, user_max} = Combat.base_user_damage(entity.level, class_id)

                raw_damage =
                  Combat.melee_damage(
                    min_weapon,
                    max_weapon,
                    entity.str + entity.str_buff,
                    class_id,
                    user_min,
                    user_max
                  )

                # VB6: critical hit check
                raw_damage =
                  if Combat.critical_hit?(weapon_skill), do: Combat.apply_critical(raw_damage), else: raw_damage

                {min_def, max_def} = CombatStats.effective_defense(defender.equipment)
                {final_damage, _location} = Combat.apply_defense(raw_damage, {min_def, max_def})

                new_hp = max(defender.hp - final_damage, 0)
                defender = %{defender | hp: new_hp}

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode({:user_hitted_user, %{char_index: defender.char_index, damage: final_damage}})}
                )

                Helpers.send_to_session(
                  state.sessions,
                  defender_id,
                  {:send_raw,
                   Encoder.encode({:user_hitted_by_user, %{char_index: entity.char_index, damage: final_damage}})}
                )

                Helpers.send_to_session(
                  state.sessions,
                  defender_id,
                  {:send_raw, Encoder.encode({:update_hp, %{min_hp: new_hp}})}
                )

                # VB6: weapon skill gain on hit
                entity = maybe_gain_skill(entity, skill_name)
                # Guild war: no criminal flag when attacking enemy guild members
                guild_war = Arena.GuildServer.players_at_war?(char_id, defender_id)
                entity = if not defender.criminal and not guild_war, do: %{entity | criminal: true}, else: entity

                {defender, state} =
                  if new_hp <= 0 do
                    Helpers.send_to_session(
                      state.sessions,
                      defender_id,
                      {:send_raw, Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})}
                    )

                    handle_player_death(state, defender_id, defender)
                  else
                    {defender, state}
                  end

                # Faction score + kill counters + guild XP on PvP kill
                entity =
                  if defender.dead do
                    score = Arena.Map.Social.faction_score_for_kill(entity, defender)
                    entity = if score > 0, do: %{entity | faction_score: entity.faction_score + score}, else: entity
                    entity = update_pvp_kill_counters(entity, defender)

                    case Arena.GuildServer.guild_id_for(char_id) do
                      nil -> :ok
                      gid -> Arena.GuildServer.add_guild_exp(gid, 50)
                    end

                    entity
                  else
                    entity
                  end

                players =
                  state.players
                  |> Map.put(char_id, entity)
                  |> Map.put(defender_id, defender)

                state = %{state | players: players}

                if defender.dead do
                  Helpers.broadcast_character_change(state, defender)
                end

                state
              end
            else
              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            end
        end
    end
  end

  def handle_attack_target(state, char_id, entity, _no_target, _opts) do
    players = Map.put(state.players, char_id, entity)
    %{state | players: players}
  end

  # ==================================================================
  # Spell handlers
  # ==================================================================

  def handle_cast_spell(state, char_id, spell_slot, target_x, target_y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)
        # VB6: per-spell-slot cooldown check
        slot_cd = Map.get(entity.spell_cooldowns, spell_slot, -1_000_000_000_000)

        cond do
          now < slot_cd ->
            {:reply, {:error, :cooldown}, state}

          entity.dead ->
            {:reply, {:error, :dead}, state}

          entity.paralyzed ->
            {:reply, {:error, :paralyzed}, state}

          entity.mounted ->
            {:reply, {:error, :mounted}, state}

          true ->
            spell_idx = spell_slot - 1

            cond do
              spell_idx < 0 or spell_idx >= length(entity.spells) ->
                {:reply, {:error, :invalid_slot}, state}

              true ->
                spell_id = Enum.at(entity.spells, spell_idx)
                spell_def = GameData.get_spell(spell_id)

                # Bounds + range check
                target_oob =
                  target_x != nil and target_y != nil and
                    (target_x < 1 or target_x > Helpers.map_width() or target_y < 1 or target_y > Helpers.map_height())

                spell_in_range =
                  not target_oob and
                    (target_x == nil or target_y == nil or
                       (abs(entity.x - target_x) <= Helpers.aoi_range_x() and
                          abs(entity.y - target_y) <= Helpers.aoi_range_y()))

                magic_skill = Map.get(entity.skills, :magic, 0)
                req = if spell_def, do: spell_def.requirement_mask, else: 0

                cond do
                  spell_def == nil ->
                    {:reply, {:error, :unknown_spell}, state}

                  not spell_in_range ->
                    {:reply, {:error, :out_of_range}, state}

                  spell_def.min_skill > 0 and magic_skill < spell_def.min_skill ->
                    {:reply, {:error, :skill_too_low}, state}

                  entity.mana < spell_def.mana_required ->
                    {:reply, {:error, :not_enough_mana}, state}

                  entity.stamina < spell_def.sta_required ->
                    {:reply, {:error, :not_enough_stamina}, state}

                  # VB6: MaxLevelCasteable -- spell has a max caster level
                  spell_def.max_level_casteable > 0 and entity.level > spell_def.max_level_casteable ->
                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw,
                       Encoder.encode(
                         {:console_msg, %{message: "Tu nivel es muy alto para lanzar este hechizo.", font_index: 0}}
                       )}
                    )

                    {:reply, {:error, :level_too_high}, state}

                  # VB6: NeedStaff -- requires a magic staff equipped
                  spell_def.need_staff and not has_staff_equipped?(entity) ->
                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw,
                       Encoder.encode({:console_msg, %{message: "Necesitas un baculo equipado.", font_index: 0}})}
                    )

                    {:reply, {:error, :need_staff}, state}

                  # VB6: RequirementMask -- equipment requirements
                  band(req, @req_weapon) != 0 and entity.equipment[:weapon] == nil ->
                    spell_req_fail(state, char_id, "Necesitas un arma equipada.")

                  band(req, @req_shield) != 0 and entity.equipment[:shield] == nil ->
                    spell_req_fail(state, char_id, "Necesitas un escudo equipado.")

                  band(req, @req_armor) != 0 and entity.equipment[:armor] == nil ->
                    spell_req_fail(state, char_id, "Necesitas una armadura equipada.")

                  band(req, @req_helm) != 0 and entity.equipment[:helmet] == nil ->
                    spell_req_fail(state, char_id, "Necesitas un casco equipado.")

                  band(req, @req_projectile) != 0 and entity.equipment[:municion] == nil ->
                    spell_req_fail(state, char_id, "Necesitas municion equipada.")

                  # VB6: eRequireShip -- must be navigating
                  band(req, @req_ship) != 0 and not entity.navigating ->
                    spell_req_fail(state, char_id, "Necesitas estar navegando.")

                  # VB6: eRequireTargetOnLand -- target must be on land
                  band(req, @req_on_land) != 0 and target_x != nil and
                      tile_is_water?(state, target_x, target_y) ->
                    spell_req_fail(state, char_id, "El objetivo debe estar en tierra.")

                  # VB6: eRequireTargetOnWater -- target must be on water
                  band(req, @req_on_water) != 0 and target_x != nil and
                      not tile_is_water?(state, target_x, target_y) ->
                    spell_req_fail(state, char_id, "El objetivo debe estar en agua.")

                  # VB6: WorkOnDead -- reject if target is dead and spell cannot work on dead
                  not spell_def.work_on_dead and target_x != nil and target_y != nil and
                      target_is_dead?(state, target_x, target_y) ->
                    spell_req_fail(state, char_id, "No puedes lanzar ese hechizo sobre un muerto.")

                  # VB6: StaffAfecta -- requires a weapon of specific obj_type
                  spell_def.staff_afecta > 0 and
                      not has_required_weapon_type?(entity, spell_def.staff_afecta) ->
                    spell_req_fail(state, char_id, "Necesitas el arma adecuada para lanzar ese hechizo.")

                  # VB6: RequireWeaponType -- requires weapon of specific e_WeaponType enum
                  spell_def.require_weapon_type > 0 and
                      not has_required_weapon_enum?(entity, spell_def.require_weapon_type) ->
                    spell_req_fail(state, char_id, "Necesitas el tipo de arma correcto para lanzar ese hechizo.")

                  true ->
                    # VB6 26c: offensive spell casting breaks invisible + oculto
                    # Only negative/offensive spells (TargetEffectType=2) break invis
                    entity =
                      if spell_def.target_effect_type == 2 do
                        Helpers.break_invisibility(entity, state, char_id)
                      else
                        entity
                      end

                    # VB6: per-spell cooldown in seconds
                    cooldown_ms = spell_def.cooldown * 1000

                    entity = %{
                      entity
                      | mana: entity.mana - spell_def.mana_required,
                        stamina: max(entity.stamina - spell_def.sta_required, 0),
                        spell_cooldowns: Map.put(entity.spell_cooldowns, spell_slot, now + cooldown_ms)
                    }

                    state = apply_spell(state, char_id, entity, spell_def, target_x, target_y)
                    {:reply, :ok, state}
                end
            end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def apply_spell(state, char_id, entity, spell_def, target_x, target_y) do
    # Broadcast FX at target center
    broadcast_spell_fx(state, entity, spell_def, target_x, target_y)

    # VB6 AoE: area_radio > 0 means square radius; area_afecta: 1=users, 2=NPCs, 3=both
    if spell_def.area_radio > 0 and target_x != nil and target_y != nil do
      apply_spell_aoe(state, char_id, entity, spell_def, target_x, target_y)
    else
      apply_spell_single(state, char_id, entity, spell_def, target_x, target_y)
    end
  end

  def broadcast_spell_fx(state, entity, spell_def, target_x, target_y) do
    if spell_def.fx_grh > 0 do
      target_occ = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

      fx_char_index =
        case target_occ do
          {:player, pid} ->
            case Map.get(state.players, pid) do
              nil -> 0
              p -> p.char_index
            end

          {:npc, iid} ->
            case Map.get(state.npcs_live, iid) do
              nil -> 0
              n -> n.char_index
            end

          _ ->
            entity.char_index
        end

      fx_x = if target_x, do: target_x, else: entity.x
      fx_y = if target_y, do: target_y, else: entity.y

      fx_raw =
        Encoder.encode(
          {:create_fx, %{char_index: fx_char_index, fx: spell_def.fx_grh, loops: spell_def.loops, x: fx_x, y: fx_y}}
        )

      Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid -> send(pid, {:send_raw, fx_raw}) end)
    end

    if spell_def.wav > 0 do
      wav_raw = Encoder.encode({:play_wave, %{wav: spell_def.wav, x: entity.x, y: entity.y}})
      Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid -> send(pid, {:send_raw, wav_raw}) end)
    end
  end

  # VB6: iterate square area centered on target, apply spell to matching occupants
  def apply_spell_aoe(state, char_id, entity, spell_def, center_x, center_y) do
    r = spell_def.area_radio

    targets =
      for ty <- (center_y - r)..(center_y + r),
          tx <- (center_x - r)..(center_x + r),
          tx >= 1 and tx <= Helpers.map_width() and ty >= 1 and ty <= Helpers.map_height() do
        {tx, ty, Helpers.get_occupancy(state.occupancy, tx, ty)}
      end

    # Filter by area_afecta: 1=users, 2=NPCs, 3=both
    targets =
      Enum.filter(targets, fn {_tx, _ty, occ} ->
        case {spell_def.area_afecta, occ} do
          {1, {:player, _}} -> true
          {2, {:npc, _}} -> true
          {3, {:player, _}} -> true
          {3, {:npc, _}} -> true
          _ -> false
        end
      end)

    # Apply spell to each target, threading state. Re-fetch entity from state each iteration
    # since damage spells can update entity (XP, criminal flag).
    Enum.reduce(targets, state, fn {tx, ty, _occ}, acc ->
      caster = Map.get(acc.players, char_id, entity)
      apply_spell_single(acc, char_id, caster, spell_def, tx, ty)
    end)
  end

  def apply_spell_single(state, char_id, entity, spell_def, target_x, target_y) do
    cond do
      # Resurrection spell
      spell_def.revivir ->
        apply_spell_resurrect(state, char_id, entity, spell_def, target_x, target_y)

      # Damage spell (sube_hp == 2)
      spell_def.sube_hp == 2 ->
        is_mage = entity.class in [:mago]
        damage = Combat.spell_damage(spell_def.min_hp, spell_def.max_hp, entity.level, is_mage)
        apply_spell_damage(state, char_id, entity, damage, target_x, target_y)

      # Heal spell (sube_hp == 1 or sanacion)
      spell_def.sube_hp == 1 or spell_def.sanacion ->
        heal =
          if spell_def.max_hp > spell_def.min_hp,
            do: Enum.random(spell_def.min_hp..spell_def.max_hp),
            else: spell_def.min_hp

        apply_spell_heal(state, char_id, entity, heal, spell_def, target_x, target_y)

      # VB6 26g: RemoveInvisibility spell (area detection)
      spell_def.remove_invisibility ->
        apply_spell_remove_invisibility(state, char_id, entity, spell_def, target_x, target_y)

      # Status effects
      spell_def.paraliza or spell_def.envenena or spell_def.cura_veneno or
        spell_def.invisibilidad or spell_def.inmoviliza ->
        apply_spell_status(state, char_id, entity, spell_def, target_x, target_y)

      # Strength buff/debuff (sube_fu: 1=buff, 2=debuff)
      spell_def.sube_fu > 0 ->
        apply_spell_attribute_buff(state, char_id, entity, spell_def, :str, target_x, target_y)

      # Agility buff/debuff (sube_ag: 1=buff, 2=debuff)
      spell_def.sube_ag > 0 ->
        apply_spell_attribute_buff(state, char_id, entity, spell_def, :agi, target_x, target_y)

      # Mana drain/restore (sube_mana: 1=restore, 2=drain)
      spell_def.sube_mana > 0 ->
        apply_spell_mana(state, char_id, entity, spell_def, target_x, target_y)

      # Stamina drain/restore (sube_sta: 1=restore, 2=drain)
      spell_def.sube_sta > 0 ->
        apply_spell_stamina(state, char_id, entity, spell_def, target_x, target_y)

      # Default: just update mana
      true ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}
    end
  end

  # VB6 26g: RemoveInvisibility spell — reveals invisible players in 11-tile radius
  # Players with no_detectable flag are immune.
  def apply_spell_remove_invisibility(state, char_id, entity, _spell_def, target_x, target_y) do
    cx = target_x || entity.x
    cy = target_y || entity.y
    radius = 11

    state =
      Enum.reduce(state.players, state, fn {pid, target}, acc ->
        if pid != char_id and target.invisible and not target.no_detectable and
             abs(target.x - cx) <= radius and abs(target.y - cy) <= radius do
          buffs = Enum.reject(target.buffs, &(&1.type == :invisible))
          updated = %{target | invisible: false, buffs: buffs}
          players = Map.put(acc.players, pid, updated)

          Helpers.send_to_session(
            acc.sessions,
            pid,
            {:send_raw,
             Encoder.encode(
               {:console_msg, %{message: "Tu invisibilidad ya no tiene efecto.", font_index: 0}}
             )}
          )

          %{acc | players: players}
        else
          acc
        end
      end)

    players = Map.put(state.players, char_id, entity)
    %{state | players: players}
  end

  def apply_spell_damage(state, char_id, entity, damage, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    case target do
      {:npc, instance_id} ->
        case Map.get(state.npcs_live, instance_id) do
          nil ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          npc when npc.alive ->
            npc_def = GameData.get_npc(npc.npc_id)
            magic_res = if npc_def, do: npc_def.magic_resistance, else: 0
            final_damage = Combat.apply_magic_resistance(damage, magic_res)
            new_hp = max(npc.hp - final_damage, 0)
            npc = %{npc | hp: new_hp}

            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:user_hitted_user, %{char_index: npc.char_index, damage: final_damage}})}
            )

            if new_hp <= 0 do
              state =
                if npc.owner_id != nil do
                  handle_pet_death(state, instance_id, npc)
                else
                  npc = %{
                    npc
                    | alive: false,
                      respawn_at:
                        System.monotonic_time(:millisecond) +
                          if(npc_def, do: npc_def.intervalo_respawn, else: 60) * 1000
                  }

                  put_in(state.npcs_live[instance_id], npc)
                end

              occupancy = Helpers.clear_occupancy(state.occupancy, npc.x, npc.y)
              state = %{state | occupancy: occupancy}

              remove_raw = Encoder.encode({:character_remove, %{char_index: npc.char_index}})
              Visibility.broadcast_visible_all(state, npc.x, npc.y, fn pid -> send(pid, {:send_raw, remove_raw}) end)

              # Per-hit XP on the killing blow (no XP for killing pets)
              {entity, state} =
                if npc.owner_id == nil do
                  award_hit_xp(state, char_id, entity, final_damage, npc_def, instance_id)
                else
                  {entity, state}
                end

              # Kill rewards (counter, guild XP, loot) — no rewards for killing pets
              state =
                if npc.owner_id == nil do
                  entity = %{entity | npcs_killed: entity.npcs_killed + 1}

                  # Notify invasion system about NPC kill (spell)
                  Arena.Events.InvasionServer.notify_npc_killed(state.map_id, instance_id)

                  # Award guild XP on NPC spell kill
                  give_exp = if npc_def, do: npc_def.give_exp, else: 0

                  if give_exp > 0 do
                    case Arena.GuildServer.guild_id_for(char_id) do
                      nil -> :ok
                      gid -> Arena.GuildServer.add_guild_exp(gid, max(div(give_exp, 10), 1))
                    end
                  end

                  # VB6: NPCTirarOro — drop gold on the floor at NPC position
                  give_gld = if npc_def, do: npc_def.give_gld, else: 0
                  state = drop_npc_gold(state, npc, give_gld)

                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
                  )

                  state = drop_npc_loot(state, npc, npc_def)
                  players = Map.put(state.players, char_id, entity)
                  %{state | players: players}
                else
                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
                  )

                  players = Map.put(state.players, char_id, entity)
                  %{state | players: players}
                end

              state
            else
              npc = %{npc | target_id: char_id}
              state = put_in(state.npcs_live[instance_id], npc)

              # VB6: per-hit proportional XP (no XP for hitting pets)
              {entity, state} =
                if npc.owner_id == nil do
                  award_hit_xp(state, char_id, entity, final_damage, npc_def, instance_id)
                else
                  {entity, state}
                end

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
              )

              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            end

          _ ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}
        end

      {:player, target_id} when target_id != char_id ->
        case Map.get(state.players, target_id) do
          nil ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          defender ->
            cond do
              same_faction?(entity, defender) ->
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode(
                     {:console_msg, %{message: "No puedes atacar a un miembro de tu faccion.", font_index: 0}}
                   )}
                )

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
                )

                players = Map.put(state.players, char_id, entity)
                %{state | players: players}

              party_safe_block?(char_id, defender) ->
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode(
                     {:console_msg, %{message: "No puedes atacar a un miembro de tu grupo.", font_index: 0}}
                   )}
                )

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
                )

                players = Map.put(state.players, char_id, entity)
                %{state | players: players}

              true ->
                # VB6: apply magic resistance in PvP (resistance skill as percentage)
                resist_pct = Map.get(defender.skills, :resistance, 0)
                final_damage = Combat.apply_magic_resistance(damage, resist_pct)
                new_hp = max(defender.hp - final_damage, 0)
                defender = %{defender | hp: new_hp}

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode({:user_hitted_user, %{char_index: defender.char_index, damage: final_damage}})}
                )

                Helpers.send_to_session(
                  state.sessions,
                  target_id,
                  {:send_raw,
                   Encoder.encode({:user_hitted_by_user, %{char_index: entity.char_index, damage: final_damage}})}
                )

                Helpers.send_to_session(
                  state.sessions,
                  target_id,
                  {:send_raw, Encoder.encode({:update_hp, %{min_hp: new_hp}})}
                )

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
                )

                # Guild war: no criminal flag when attacking enemy guild members
                guild_war = Arena.GuildServer.players_at_war?(char_id, target_id)
                entity = if not defender.criminal and not guild_war, do: %{entity | criminal: true}, else: entity

                {defender, state} =
                  if new_hp <= 0 do
                    Helpers.send_to_session(
                      state.sessions,
                      target_id,
                      {:send_raw, Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})}
                    )

                    handle_player_death(state, target_id, defender)
                  else
                    {defender, state}
                  end

                # Faction score + kill counters + guild XP on PvP spell kill
                entity =
                  if defender.dead do
                    score = Arena.Map.Social.faction_score_for_kill(entity, defender)
                    entity = if score > 0, do: %{entity | faction_score: entity.faction_score + score}, else: entity
                    entity = update_pvp_kill_counters(entity, defender)

                    case Arena.GuildServer.guild_id_for(char_id) do
                      nil -> :ok
                      gid -> Arena.GuildServer.add_guild_exp(gid, 50)
                    end

                    entity
                  else
                    entity
                  end

                players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, defender)
                state = %{state | players: players}

                if defender.dead do
                  Helpers.broadcast_character_change(state, defender)
                end

                state
            end
        end

      _ ->
        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
        )

        players = Map.put(state.players, char_id, entity)
        %{state | players: players}
    end
  end

  def apply_spell_heal(state, char_id, entity, heal, _spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    case target do
      {:player, target_id} ->
        case Map.get(state.players, target_id) do
          nil ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          target_entity ->
            # VB6: cannot heal dead targets
            if target_entity.dead do
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "Esta muerto.", font_index: 5}})}
              )

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
              )

              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            else
              new_hp = min(target_entity.hp + heal, target_entity.max_hp)
              target_entity = %{target_entity | hp: new_hp}

              Helpers.send_to_session(
                state.sessions,
                target_id,
                {:send_raw, Encoder.encode({:update_hp, %{min_hp: new_hp}})}
              )

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
              )

              players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
              %{state | players: players}
            end
        end

      _ ->
        # Self-heal
        new_hp = min(entity.hp + heal, entity.max_hp)
        entity = %{entity | hp: new_hp}

        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:update_hp, %{min_hp: new_hp}})})

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
        )

        players = Map.put(state.players, char_id, entity)
        %{state | players: players}
    end
  end

  def apply_spell_status(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil
    now = System.monotonic_time(:millisecond)

    target_id =
      case target do
        {:player, tid} -> tid
        _ -> char_id
      end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      target_entity ->
        duration_ms = max((spell_def.duration || 0) * 1000, 3000)

        target_entity =
          cond do
            spell_def.paraliza ->
              buff = %{type: :paralyzed, expires_at: now + div(duration_ms, 2)}
              buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :paralyzed))]
              %{target_entity | paralyzed: true, buffs: buffs}

            spell_def.envenena ->
              buff = %{type: :poisoned, expires_at: now + duration_ms, next_tick: now + @poison_tick_interval}
              buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :poisoned))]
              %{target_entity | poisoned: true, buffs: buffs}

            spell_def.cura_veneno ->
              buffs = Enum.reject(target_entity.buffs, &(&1.type == :poisoned))
              %{target_entity | poisoned: false, buffs: buffs}

            spell_def.invisibilidad ->
              buff = %{type: :invisible, expires_at: now + duration_ms}
              buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :invisible))]
              %{target_entity | invisible: true, buffs: buffs}

            spell_def.inmoviliza ->
              # VB6: immobilize duration is halved
              buff = %{type: :immobilized, expires_at: now + div(duration_ms, 2)}
              buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :immobilized))]
              %{target_entity | immobilized: true, buffs: buffs}

            true ->
              target_entity
          end

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
        )

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
        %{state | players: players}
    end
  end

  def apply_spell_resurrect(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    target_id =
      case target do
        {:player, tid} -> tid
        _ -> nil
      end

    target_player = if target_id, do: Map.get(state.players, target_id)

    if target_player && target_player.dead do
      # VB6: spell min_hp is the % of max_hp to revive at (e.g. 10 -> 10%)
      revive_pct = max(spell_def.min_hp, 10)
      revive_hp = max(div(target_player.max_hp * revive_pct, 100), 1)

      revived = %{
        target_player
        | dead: false,
          hp: revive_hp,
          mana: 0,
          hunger: 0,
          thirst: 0,
          buffs: [],
          paralyzed: false,
          poisoned: false,
          invisible: false,
          oculto: false
      }

      # Notify revived player
      Helpers.send_to_session(
        state.sessions,
        target_id,
        {:send_raw, Encoder.encode({:update_hp, %{min_hp: revive_hp}})}
      )

      Helpers.send_to_session(state.sessions, target_id, {:send_raw, Encoder.encode({:update_mana, %{min_mana: 0}})})

      Helpers.send_to_session(
        state.sessions,
        target_id,
        {:send_raw,
         Encoder.encode({:update_hunger_and_thirst, %{max_hunger: 100, min_hunger: 0, max_thirst: 100, min_thirst: 0}})}
      )

      Helpers.send_to_session(
        state.sessions,
        target_id,
        {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido resucitado!", font_index: 0}})}
      )

      # Update caster mana
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
      )

      players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, revived)
      state = %{state | players: players}
      Helpers.broadcast_character_change(state, revived)
      state
    else
      # No dead player at target -- just update caster mana
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
      )

      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un jugador muerto ahi.", font_index: 5}})}
      )

      players = Map.put(state.players, char_id, entity)
      %{state | players: players}
    end
  end

  def apply_spell_attribute_buff(state, char_id, entity, spell_def, attr, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil
    now = System.monotonic_time(:millisecond)

    target_id =
      case target do
        {:player, tid} -> tid
        _ -> char_id
      end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      target_entity ->
        {sube, min_val, max_val} =
          case attr do
            :str -> {spell_def.sube_fu, spell_def.min_fu, spell_def.max_fu}
            :agi -> {spell_def.sube_ag, spell_def.min_ag, spell_def.max_ag}
          end

        amount = if max_val > min_val, do: Enum.random(min_val..max_val), else: min_val
        duration_ms = max((spell_def.duration || 0) * 1000, 3000)
        buff_type = if attr == :str, do: :str_buff, else: :agi_buff

        # sube == 1 -> increase, sube == 2 -> decrease
        actual = if sube == 1, do: amount, else: -amount

        target_entity =
          case attr do
            :str -> %{target_entity | str_buff: target_entity.str_buff + actual}
            :agi -> %{target_entity | agi_buff: target_entity.agi_buff + actual}
          end

        buff = %{type: buff_type, expires_at: now + duration_ms, value: actual}
        buffs = [buff | target_entity.buffs]
        target_entity = %{target_entity | buffs: buffs}

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
        )

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
        %{state | players: players}
    end
  end

  def apply_spell_mana(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    target_id =
      case target do
        {:player, tid} -> tid
        _ -> char_id
      end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      target_entity ->
        amount =
          if spell_def.max_mana > spell_def.min_mana,
            do: Enum.random(spell_def.min_mana..spell_def.max_mana),
            else: spell_def.min_mana

        target_entity =
          if spell_def.sube_mana == 1 do
            # Restore mana
            %{target_entity | mana: min(target_entity.mana + amount, target_entity.max_mana)}
          else
            # Drain mana
            %{target_entity | mana: max(target_entity.mana - amount, 0)}
          end

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw, Encoder.encode({:update_mana, %{min_mana: target_entity.mana}})}
        )

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
        )

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
        %{state | players: players}
    end
  end

  def apply_spell_stamina(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    target_id =
      case target do
        {:player, tid} -> tid
        _ -> char_id
      end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      target_entity ->
        amount =
          if spell_def.max_sta > spell_def.min_sta,
            do: Enum.random(spell_def.min_sta..spell_def.max_sta),
            else: spell_def.min_sta

        target_entity =
          if spell_def.sube_sta == 1 do
            %{target_entity | stamina: min(target_entity.stamina + amount, target_entity.max_stamina)}
          else
            %{target_entity | stamina: max(target_entity.stamina - amount, 0)}
          end

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw, Encoder.encode({:update_stamina, %{min_sta: target_entity.stamina}})}
        )

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
        )

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
        %{state | players: players}
    end
  end

  # ==================================================================
  # Combat helpers
  # ==================================================================

  def process_player_buffs(state, char_id, entity, now) do
    {expired, active} = Enum.split_with(entity.buffs, fn b -> now >= b.expires_at end)

    # Clear flags for expired buffs
    entity =
      Enum.reduce(expired, entity, fn buff, ent ->
        case buff.type do
          :paralyzed -> %{ent | paralyzed: false}
          :poisoned -> %{ent | poisoned: false}
          :invisible -> %{ent | invisible: false}
          :oculto -> %{ent | oculto: false}
          :immobilized -> %{ent | immobilized: false}
          :str_buff -> %{ent | str_buff: max(ent.str_buff - (buff[:value] || 0), 0)}
          :agi_buff -> %{ent | agi_buff: max(ent.agi_buff - (buff[:value] || 0), 0)}
          _ -> ent
        end
      end)

    # Process poison ticks on active poison buffs
    {active, entity} =
      Enum.map_reduce(active, entity, fn buff, ent ->
        if buff.type == :poisoned and now >= (buff[:next_tick] || 0) do
          damage = max(Enum.random(3..5) * div(ent.max_hp, 100), 1)
          new_hp = max(ent.hp - damage, 0)
          ent = %{ent | hp: new_hp}

          Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:update_hp, %{min_hp: new_hp}})})

          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "Veneno te hace #{damage} de daño.", font_index: 5}})}
          )

          buff = %{buff | next_tick: now + @poison_tick_interval}
          {buff, ent}
        else
          {buff, ent}
        end
      end)

    entity = %{entity | buffs: active}

    # Check poison death
    was_alive = not entity.dead

    {entity, state} =
      if entity.hp <= 0 and was_alive do
        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})}
        )

        handle_player_death(state, char_id, entity)
      else
        {entity, state}
      end

    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}

    if was_alive and entity.dead do
      Helpers.broadcast_character_change(state, entity)
    end

    state
  end

  def maybe_gain_skill(entity, skill_name) do
    current = Map.get(entity.skills, skill_name, 0)

    if current < @max_skill and :rand.uniform(100) <= @skill_gain_chance do
      %{entity | skills: Map.put(entity.skills, skill_name, current + 1)}
    else
      entity
    end
  end

  defp award_xp_with_party(state, char_id, entity, xp_gained) do
    nearby = Arena.PartyServer.nearby_members(char_id, state.players)

    if nearby == [] do
      # Solo — full XP
      entity = %{entity | xp: entity.xp + xp_gained}
      entity = check_level_up(entity, state.sessions, char_id)
      send_xp_update(state, char_id, entity)
      {entity, state}
    else
      # Split among killer + nearby party members
      share_count = length(nearby) + 1
      share = max(div(xp_gained, share_count), 1)

      entity = %{entity | xp: entity.xp + share}
      entity = check_level_up(entity, state.sessions, char_id)
      send_xp_update(state, char_id, entity)

      state =
        Enum.reduce(nearby, state, fn mid, state ->
          case Map.get(state.players, mid) do
            nil ->
              state

            member ->
              member = %{member | xp: member.xp + share}
              member = check_level_up(member, state.sessions, mid)
              send_xp_update(state, mid, member)
              %{state | players: Map.put(state.players, mid, member)}
          end
        end)

      {entity, state}
    end
  end

  defp send_xp_update(state, char_id, entity) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw,
       Encoder.encode({:update_exp, %{current_xp: entity.xp, next_xp: GameData.exp_for_level(entity.level + 1) || 0}})}
    )
  end

  # VB6: NPCTirarOro — drop gold on the floor at the NPC's death position.
  # Gold item ID 12 (iORO), capped at @max_stack per ground tile.
  @gold_item_id 12
  defp drop_npc_gold(state, _npc, give_gld) when give_gld <= 0, do: state

  defp drop_npc_gold(state, npc, give_gld) do
    pos = {npc.x, npc.y}

    unless Map.has_key?(state.ground_items, pos) do
      ground_items = Map.put(state.ground_items, pos, %{item_id: @gold_item_id, amount: give_gld, elemental_tags: 0})
      state = %{state | ground_items: ground_items}
      Helpers.broadcast_object_create(state, npc.x, npc.y, @gold_item_id, give_gld)
      state
    else
      state
    end
  end

  def check_level_up(entity, sessions, char_id) do
    next_xp = GameData.exp_for_level(entity.level + 1)

    if next_xp && entity.xp >= next_xp do
      class_id = Helpers.class_atom_to_id(entity.class)
      new_level = entity.level + 1

      # HP growth: randomized around class modifier
      hp_mod = GameData.class_hp_mod(class_id)
      hp_gain = max(trunc(hp_mod * (0.8 + :rand.uniform() * 0.4)), 1)
      new_max_hp = entity.max_hp + hp_gain

      # Mana growth: int * class multiplier (0 for non-casters)
      mana_mult = GameData.class_mana_mult(class_id)
      mana_gain = trunc(entity.int * mana_mult)
      new_max_mana = entity.max_mana + mana_gain

      # Stamina growth
      sta_growth = GameData.class_stamina_growth(class_id)
      sta_gain = max(trunc(sta_growth * entity.agi / 33), 1)
      new_max_stamina = entity.max_stamina + sta_gain

      # Skill points
      skill_pts = GameData.class_skill_points(class_id)

      # Base damage for new level
      {new_min_hit, new_max_hit} = Combat.base_user_damage(new_level, class_id)

      entity = %{
        entity
        | level: new_level,
          xp: entity.xp - next_xp,
          max_hp: new_max_hp,
          hp: new_max_hp,
          max_mana: new_max_mana,
          mana: new_max_mana,
          max_stamina: new_max_stamina,
          stamina: new_max_stamina,
          min_hit: new_min_hit,
          max_hit: new_max_hit,
          skill_points: entity.skill_points + skill_pts
      }

      # Level-up packet
      Helpers.send_to_session(sessions, char_id, {:send_raw, Encoder.encode({:level_up, %{level: new_level}})})

      # Full stat refresh
      Helpers.send_to_session(
        sessions,
        char_id,
        {:send_raw,
         Encoder.encode(
           {:update_user_stats,
            %{
              max_hp: entity.max_hp,
              min_hp: entity.hp,
              shield: 0,
              max_mana: entity.max_mana,
              min_mana: entity.mana,
              max_sta: entity.max_stamina,
              min_sta: entity.stamina,
              gold: entity.gold,
              gold_cap: 1_000_000,
              level: entity.level,
              exp_next_level: GameData.exp_for_level(entity.level + 1) || 0,
              exp: entity.xp,
              class: Helpers.class_atom_to_id(entity.class)
            }}
         )}
      )

      Helpers.send_to_session(
        sessions,
        char_id,
        {:send_raw, Encoder.encode({:console_msg, %{message: "Has alcanzado el nivel #{new_level}!", font_index: 0}})}
      )

      # Recursive check for multiple level ups
      check_level_up(entity, sessions, char_id)
    else
      entity
    end
  end

  @doc """
  VB6 deep death: clear all transient combat/status state.
  Called from every path that sets dead: true.
  Despawns pets owned by the dying player.
  """
  def handle_player_death(state, char_id, player) do
    player = %{
      player
      | dead: true,
        deaths: player.deaths + 1,
        stamina: 0,
        hunger: 0,
        thirst: 0,
        paralyzed: false,
        invisible: false,
        oculto: false,
        oculto_timer: 0,
        mounted: false,
        poisoned: false,
        meditating: false,
        resting: false,
        immobilized: false,
        buffs: [],
        commerce_npc_id: nil,
        bank_npc_id: nil,
        trade_partner_id: nil,
        trade_request_target: nil,
        trade_offer_gold: 0,
        trade_offer_items: [],
        trade_accepted: false
    }

    # VB6: unequip all equipped items on death
    {player, unequipped_slots} = unequip_all_on_death(player)

    # VB6: TirarTodosLosItems — drop inventory on ground in unsafe zones
    {player, state} =
      if not Map.get(state.meta || %{}, :safe_zone, false) do
        drop_inventory_on_death(state, player)
      else
        {player, state}
      end

    # Despawn all pets owned by this player
    pet_ids =
      state.npcs_live
      |> Enum.filter(fn {_id, npc} -> npc.owner_id == char_id end)
      |> Enum.map(fn {id, _npc} -> id end)

    state =
      Enum.reduce(pet_ids, state, fn instance_id, st ->
        case Map.get(st.npcs_live, instance_id) do
          nil -> st
          npc -> Arena.NpcAi.despawn_pet(st, instance_id, npc)
        end
      end)

    # Send unequip slot updates to client
    for slot <- unequipped_slots do
      Helpers.send_inventory_slot(state.sessions, char_id, player.inventory, slot)
    end

    # VB6: /HOGAR message in unsafe zones
    if not Map.get(state.meta || %{}, :safe_zone, false) do
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw,
         Encoder.encode(
           {:console_msg, %{message: "Escribe /HOGAR si deseas regresar rápido a tu hogar.", font_index: 5}}
         )}
      )
    end

    # VB6: MuereEnReto — notify DuelServer when a dueling player dies
    if player.in_duel do
      notify_duel_death(char_id)
    end

    {player, state}
  end

  # Asynchronously notify DuelServer about a duel participant's death.
  # Uses spawn to avoid blocking the MapServer process.
  defp notify_duel_death(char_id) do
    spawn(fn ->
      try do
        Arena.DuelServer.player_died(char_id)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # Unequip all equipped items. Returns {updated_player, list_of_changed_slot_indices}.
  defp unequip_all_on_death(player) do
    {new_inventory, changed_slots} =
      player.inventory
      |> Enum.with_index()
      |> Enum.reduce({player.inventory, []}, fn {item, idx}, {inv, slots} ->
        if item != nil and item.equipped do
          new_item = %{item | equipped: false}
          {List.replace_at(inv, idx, new_item), [idx | slots]}
        else
          {inv, slots}
        end
      end)

    equipment = %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil}
    player = %{player | inventory: new_inventory, equipment: equipment}
    {player, changed_slots}
  end

  # Drop all non-newbie items on the ground at player position.
  # VB6: TirarTodosLosItems — drops each item from inventory to the floor.
  defp drop_inventory_on_death(state, player) do
    {new_inventory, state} =
      player.inventory
      |> Enum.with_index()
      |> Enum.reduce({player.inventory, state}, fn {item, idx}, {inv, st} ->
        if item != nil do
          item_def = GameData.get_item(item.item_id)
          # VB6: don't drop newbie items or quest items
          newbie = item_def != nil and Map.get(item_def, :newbie, false)

          if newbie do
            {inv, st}
          else
            pos = {player.x, player.y}
            # Only drop if tile doesn't already have a ground item
            st =
              unless Map.has_key?(st.ground_items, pos) do
                ground_items =
                  Map.put(st.ground_items, pos, %{
                    item_id: item.item_id,
                    amount: item.amount,
                    elemental_tags: Map.get(item, :elemental_tags, 0)
                  })

                st = %{st | ground_items: ground_items}

                Helpers.broadcast_object_create(
                  st,
                  player.x,
                  player.y,
                  item.item_id,
                  item.amount,
                  Map.get(item, :elemental_tags, 0)
                )

                st
              else
                st
              end

            {List.replace_at(inv, idx, nil), st}
          end
        else
          {inv, st}
        end
      end)

    {%{player | inventory: new_inventory}, state}
  end

  @doc """
  VB6 per-hit XP: award proportional XP on each damaging hit, not just on kill.
  xp = damage * give_exp / max_hp (with level penalty).
  Capped by NPC's remaining exp_count pool to prevent over-awarding.
  """
  def award_hit_xp(state, char_id, entity, final_damage, npc_def, instance_id) do
    if npc_def == nil or final_damage <= 0 do
      {entity, state}
    else
      give_exp = npc_def.give_exp || 0
      npc_level = npc_def.npc_level || 1
      npc_max_hp = max(npc_def.max_hp, 1)
      xp_gained = Combat.xp_gain(final_damage, give_exp, npc_max_hp, entity.level, npc_level)

      # VB6 ExpCount pool: cap XP at remaining pool, deduct from NPC
      npc_live = Map.get(state.npcs_live, instance_id)

      {xp_gained, state} =
        if npc_live != nil and xp_gained > 0 do
          available = npc_live.exp_count
          capped = min(xp_gained, available)
          npc_live = %{npc_live | exp_count: available - capped}
          state = put_in(state.npcs_live[instance_id], npc_live)
          {capped, state}
        else
          {xp_gained, state}
        end

      if xp_gained > 0 do
        award_xp_with_party(state, char_id, entity, xp_gained)
      else
        {entity, state}
      end
    end
  end

  def drop_npc_loot(state, _npc, nil), do: state

  def drop_npc_loot(state, npc, npc_def) do
    Enum.reduce(npc_def.loot_table, state, fn %{item_id: item_id, amount: amount}, state ->
      # Simple probability: 1 in 5 chance per loot entry
      if :rand.uniform(5) == 1 do
        pos = {npc.x, npc.y}

        unless Map.has_key?(state.ground_items, pos) do
          ground_items = Map.put(state.ground_items, pos, %{item_id: item_id, amount: amount, elemental_tags: 0})
          state = %{state | ground_items: ground_items}
          Helpers.broadcast_object_create(state, npc.x, npc.y, item_id, amount)
          state
        else
          state
        end
      else
        state
      end
    end)
  end

  def has_staff_equipped?(entity) do
    weapon_id = entity.equipment[:weapon]

    if weapon_id do
      item_def = GameData.get_item(weapon_id)
      item_def != nil and item_def.staff_power > 0
    else
      false
    end
  end

  # VB6: WorkOnDead -- check if the targeted tile has a dead player
  defp target_is_dead?(state, target_x, target_y) do
    case Helpers.get_occupancy(state.occupancy, target_x, target_y) do
      {:player, target_id} ->
        case Map.get(state.players, target_id) do
          nil -> false
          target_entity -> target_entity.dead
        end

      _ ->
        false
    end
  end

  # VB6: StaffAfecta -- check if the caster's weapon obj_type matches required type
  defp has_required_weapon_type?(entity, required_obj_type) do
    weapon_id = entity.equipment[:weapon]

    if weapon_id do
      item_def = GameData.get_item(weapon_id)
      item_def != nil and item_def.obj_type == required_obj_type
    else
      false
    end
  end

  # VB6: CriminalesMatados / ciudadanosMatados — track kill type based on victim status
  defp update_pvp_kill_counters(attacker, defender) do
    cond do
      # Victim is criminal or chaos faction → increment criminals_killed
      defender.criminal or defender.faction in [:chaos_legion] ->
        %{attacker | criminals_killed: attacker.criminals_killed + 1}

      # Victim is citizen or armada faction → increment citizens_killed
      not defender.criminal and defender.faction in [:none, :royal_army] ->
        %{attacker | citizens_killed: attacker.citizens_killed + 1}

      true ->
        attacker
    end
  end

  # VB6: RequireWeaponType -- check weapon_type enum (sword=1, dagger=2, etc.)
  defp has_required_weapon_enum?(entity, required_weapon_type) do
    weapon_id = entity.equipment[:weapon]

    if weapon_id do
      item_def = GameData.get_item(weapon_id)
      item_def != nil and item_def.weapon_type == required_weapon_type
    else
      false
    end
  end

  # VB6: requirement mask failure -- send message and return error reply
  def spell_req_fail(state, char_id, message) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:console_msg, %{message: message, font_index: 0}})}
    )

    {:reply, {:error, :requirement_not_met}, state}
  end

  # TileGrid tile values: 0=walkable, 1=blocked, 2=water, 3=lava
  def tile_is_water?(state, x, y) do
    TileGrid.get_tile(state.map_id, x, y) == 2
  end

  # VB6: Armada vs Caos PvP is allowed in faction city maps even in safe zones.
  # Maps 58-60 = Armada cities, 195-196 = Caos cities.
  # Also, different-faction players can attack each other in safe zones anywhere.
  def faction_pvp_exception?(_map_id, attacker, defender) do
    attacker.faction != :none and defender.faction != :none and
      attacker.faction != defender.faction
  end

  # Same-faction players cannot attack each other regardless of zone.
  defp same_faction?(attacker, defender) do
    attacker.faction != :none and defender.faction != :none and
      attacker.faction == defender.faction
  end

  # Party safe mode: if both players are in the same party and party safe is on, block the attack.
  defp party_safe_block?(attacker_id, defender) do
    Arena.PartyServer.same_party?(attacker_id, defender.char_id) and
      Arena.PartyServer.party_safe?(attacker_id)
  end

  # ==================================================================
  # Regen tick (rest + meditate)
  # ==================================================================

  # VB6 parity (intervalos.ini + PasarSegundo at 1s + MaybeRunGameEvents at 40ms):
  #
  # Hunger/thirst: HambreYSed called from PasarSegundo (1s timer).
  #   IntervaloSed   = 4000 / 25 = 160 counter ticks at 1s = 160 seconds between drains.
  #   IntervaloHambre = 4500 / 25 = 180 counter ticks at 1s = 180 seconds between drains.
  #   Each drain subtracts 10 from the respective stat.
  #   Regen tick = 3s, so:
  #     thirst_drain_interval = ceil(160 / 3) = 54 regen ticks (~162s)
  #     hunger_drain_interval = ceil(180 / 3) = 60 regen ticks (~180s)
  #   VB6 uses SEPARATE counters for hunger vs thirst; Elixir mirrors that.
  #
  # Poison: EfectoVeneno called from MaybeRunGameEvents (40ms timer).
  #   IntervaloVeneno = 90 counter ticks at 40ms = 3600ms between damage ticks.
  #
  # At 0 hunger OR 0 thirst: stamina regen blocked, stamina drains by 1/tick.
  # HP/mana regen also blocked when starving or dehydrated.
  # HP damage only when stamina reaches 0 AND (hunger == 0 OR thirst == 0).
  @hunger_thirst_damage 5
  # VB6: IntervaloSed = 4000/25 = 160s; at 3s regen tick = 54 ticks
  @thirst_drain_interval 54
  # VB6: IntervaloHambre = 4500/25 = 180s; at 3s regen tick = 60 ticks
  @hunger_drain_interval 60
  # VB6 drains hunger/thirst by 10 per interval (not 1)
  @hunger_thirst_drain_amount 10
  # VB6: penalty (jail) decrements by 1 per minute. Tick = 3s, so 20 ticks = 1 min.
  @penalty_decrement_interval 20

  def process_regen_tick(state) do
    # Separate counters for hunger and thirst (VB6 has AGUACounter / COMCounter).
    thirst_counter = Map.get(state, :thirst_tick_counter, 0) + 1
    drain_thirst? = thirst_counter >= @thirst_drain_interval
    thirst_counter = if drain_thirst?, do: 0, else: thirst_counter
    state = Map.put(state, :thirst_tick_counter, thirst_counter)

    hunger_counter = Map.get(state, :hunger_tick_counter, 0) + 1
    drain_hunger? = hunger_counter >= @hunger_drain_interval
    hunger_counter = if drain_hunger?, do: 0, else: hunger_counter
    state = Map.put(state, :hunger_tick_counter, hunger_counter)

    # Legacy key: keep hunger_thirst_tick_counter in sync for backward compat
    # (uses thirst counter as the "primary" counter)
    state = Map.put(state, :hunger_thirst_tick_counter, thirst_counter)

    # VB6: penalty (jail timer) decrements by 1 per minute
    penalty_counter = Map.get(state, :penalty_tick_counter, 0) + 1
    decrement_penalty? = penalty_counter >= @penalty_decrement_interval
    penalty_counter = if decrement_penalty?, do: 0, else: penalty_counter
    state = Map.put(state, :penalty_tick_counter, penalty_counter)

    Enum.reduce(state.players, state, fn {char_id, entity}, state ->
      if entity.dead do
        state
      else
        original_entity = state.players[char_id]

        # VB6: decrement jail penalty every minute
        entity =
          if decrement_penalty? and entity.penalty > 0 do
            %{entity | penalty: entity.penalty - 1}
          else
            entity
          end

        # Decrement oculto timer; when it reaches 0, break oculto
        # Exception: hunters with 100% hiding skill + camo armor stay hidden
        entity =
          if entity.oculto and entity.oculto_timer > 0 do
            hiding_skill = Map.get(entity.skills, :hiding, 0)
            armor_id = entity.equipment[:armor]
            armor_def = if armor_id, do: GameData.get_item(armor_id)
            has_camo = armor_def != nil and armor_def.obj_type == 43

            if hiding_skill >= 100 and has_camo do
              entity
            else
              new_timer = entity.oculto_timer - 1

              if new_timer <= 0 do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has vuelto a ser visible.", font_index: 0}})}
                )

                %{entity | oculto: false, oculto_timer: 0}
              else
                %{entity | oculto_timer: new_timer}
              end
            end
          else
            entity
          end

        # Drain thirst and hunger on their own VB6-matched intervals.
        {entity, thirst_changed} =
          if drain_thirst? and entity.thirst > 0 do
            new_thirst = max(entity.thirst - @hunger_thirst_drain_amount, 0)
            {%{entity | thirst: new_thirst}, new_thirst != entity.thirst}
          else
            {entity, false}
          end

        {entity, hunger_changed} =
          if drain_hunger? and entity.hunger > 0 do
            new_hunger = max(entity.hunger - @hunger_thirst_drain_amount, 0)
            {%{entity | hunger: new_hunger}, new_hunger != entity.hunger}
          else
            {entity, false}
          end

        vitals_changed = thirst_changed or hunger_changed

        starving = entity.hunger == 0
        dehydrated = entity.thirst == 0

        # VB6: at 0 hunger or 0 thirst, drain stamina by 1 per tick
        entity =
          if (starving or dehydrated) and entity.stamina > 0 do
            %{entity | stamina: max(entity.stamina - 1, 0)}
          else
            entity
          end

        stamina_changed = entity.stamina != original_entity.stamina

        # VB6: HP damage only when stamina == 0 AND (starving or dehydrated)
        entity =
          cond do
            entity.stamina == 0 and starving and dehydrated ->
              %{entity | hp: max(entity.hp - @hunger_thirst_damage * 2, 0)}

            entity.stamina == 0 and (starving or dehydrated) ->
              %{entity | hp: max(entity.hp - @hunger_thirst_damage, 0)}

            true ->
              entity
          end

        hp_changed = entity.hp != original_entity.hp

        # Kill on starvation
        {entity, state} =
          if entity.hp <= 0 and not entity.dead do
            handle_player_death(state, char_id, %{entity | hp: 0})
          else
            {entity, state}
          end

        # Regen (blocked by starvation/dehydration)
        entity =
          cond do
            starving or dehydrated ->
              entity

            entity.resting and entity.hp < entity.max_hp ->
              # VB6: rest regen = con / 6, min 1
              regen = max(div(entity.con, 6), 1)
              new_hp = min(entity.hp + regen, entity.max_hp)
              entity = %{entity | hp: new_hp}

              if new_hp >= entity.max_hp do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has terminado de descansar.", font_index: 0}})}
                )

                %{entity | resting: false}
              else
                entity
              end

            entity.meditating and entity.mana < entity.max_mana ->
              # VB6: meditate regen = int * meditation_skill / 35, min 1
              med_skill = Map.get(entity.skills, :meditation, 0)
              regen = max(div(entity.int * max(med_skill, 1), 35), 1)
              new_mana = min(entity.mana + regen, entity.max_mana)
              entity = %{entity | mana: new_mana}

              if new_mana >= entity.max_mana do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has terminado de meditar.", font_index: 0}})}
                )

                %{entity | meditating: false}
              else
                entity
              end

            true ->
              entity
          end

        # VB6: passive HP regen (1/5 of rest rate) when not resting
        entity =
          if not entity.resting and not (starving or dehydrated) and entity.hp < entity.max_hp do
            passive_hp = max(div(entity.con, 30), 1)
            %{entity | hp: min(entity.hp + passive_hp, entity.max_hp)}
          else
            entity
          end

        # VB6: passive mana regen when not meditating
        entity =
          if not entity.meditating and not (starving or dehydrated) and entity.mana < entity.max_mana do
            passive_mana = max(div(entity.int, 35), 1)
            %{entity | mana: min(entity.mana + passive_mana, entity.max_mana)}
          else
            entity
          end

        # VB6: stamina regen (agi-based, ~1-3 per tick)
        entity =
          if not (starving or dehydrated) and entity.stamina < entity.max_stamina do
            sta_regen = max(div(entity.agi, 6), 1)
            %{entity | stamina: min(entity.stamina + sta_regen, entity.max_stamina)}
          else
            entity
          end

        # Send updates
        if vitals_changed do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw,
             Encoder.encode(
               {:update_hunger_and_thirst,
                %{
                  max_hunger: 100,
                  min_hunger: entity.hunger,
                  max_thirst: 100,
                  min_thirst: entity.thirst
                }}
             )}
          )
        end

        if hp_changed or entity.hp != original_entity.hp do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.hp, shield: 0}})}
          )
        end

        if entity.mana != original_entity.mana do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
          )
        end

        if stamina_changed or entity.stamina != original_entity.stamina do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:update_stamina, %{min_sta: entity.stamina}})}
          )
        end

        if entity.dead and not original_entity.dead do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "Has muerto de inanición.", font_index: 0}})}
          )

          state = %{state | players: Map.put(state.players, char_id, entity)}
          Helpers.broadcast_character_change(state, entity)
          state
        else
          %{state | players: Map.put(state.players, char_id, entity)}
        end
      end
    end)
  end

  # ------------------------------------------------------------------
  # Elemental combat helpers
  # ------------------------------------------------------------------

  # VB6: attackerElementMask = ObjData(WeaponObjIndex).ElementalTags OR InventorySlot.ElementalTags
  # Combines the weapon definition's base tags with per-instance enchantment tags.
  defp attacker_weapon_elemental_tags(entity) do
    weapon_id = entity.equipment[:weapon]

    if weapon_id == nil do
      0
    else
      base_tags =
        case GameData.get_item(weapon_id) do
          nil -> 0
          item_def -> item_def.elemental_tags
        end

      # Find equipped weapon slot's per-instance elemental tags
      instance_tags =
        case Enum.find(entity.inventory || [], fn
               %{item_id: ^weapon_id, equipped: true} -> true
               _ -> false
             end) do
          nil -> 0
          item -> Map.get(item, :elemental_tags, 0)
        end

      bor(base_tags, instance_tags)
    end
  end

  defp apply_elemental_modifiers_for_weapon(damage, entity, npc_def) do
    attacker_tags = attacker_weapon_elemental_tags(entity)
    defender_tags = if npc_def, do: npc_def.elemental_tags, else: 0
    Combat.apply_elemental_modifiers(damage, attacker_tags, defender_tags)
  end

  # Handle pet NPC death: remove from npcs_live and owner's pet_ids
  defp handle_pet_death(state, instance_id, npc) do
    # Remove from npcs_live entirely (pets don't respawn)
    npcs_live = Map.delete(state.npcs_live, instance_id)
    state = %{state | npcs_live: npcs_live}

    # Remove instance_id from owner's pet_ids
    case Map.get(state.players, npc.owner_id) do
      nil ->
        state

      owner ->
        owner = %{owner | pet_ids: List.delete(owner.pet_ids, instance_id)}
        players = Map.put(state.players, npc.owner_id, owner)
        %{state | players: players}
    end
  end
end
