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

  @ranged_max_distance 18

  @req_weapon 0x001
  @req_shield 0x002
  @req_armor 0x004
  @req_helm 0x008
  @req_projectile 0x020
  @req_ship 0x040
  @req_on_land 0x200
  @req_on_water 0x400

  # VB6 faction PvP maps — used when elemental/faction combat is wired
  @faction_pvp_maps [58, 59, 60, 195, 196]
  _ = @faction_pvp_maps

  # ==================================================================
  # Attack handlers
  # ==================================================================

  def handle_attack(state, char_id, target_x, target_y) do
    start = System.monotonic_time()
    result = do_handle_attack(state, char_id, target_x, target_y)
    duration = System.monotonic_time() - start

    attack_result =
      case result do
        {:reply, :ok, _} -> :ok
        {:reply, {:error, reason}, _} -> reason
      end

    :telemetry.execute([:arena, :combat, :attack], %{duration: duration},
      %{map_id: state.map_id, result: attack_result})

    result
  end

  defp do_handle_attack(state, char_id, target_x, target_y) do
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

              entity = %{entity | next_attack_at: now + attack_cooldown_ms(), last_attacked_at: now}

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
          entity = %{entity | next_attack_at: now + attack_cooldown_ms(), last_attacked_at: now}

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

  defp attack_cooldown_ms, do: Arena.Settings.get(:attack_cooldown_ms)

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

          # Drift #1: Use hit_chance_vs_npc (VB6: UserImpactoNpc)
          # NPC evasion is used directly, no class_evasion_mod or level bonus
          # Drift #2: Include equipment hit bonus
          hit_bonus = CombatStats.equipment_hit_bonus(entity.equipment)

          hit_roll =
            Combat.hit_chance_vs_npc(
              weapon_skill,
              entity.agi,
              entity.level,
              class_id,
              npc_evasion,
              hit_bonus
            )

          if :rand.uniform(100) <= hit_roll do
            # VB6: base user damage added to weapon damage
            {user_min, user_max} = Combat.base_user_damage(entity.level, class_id)

            raw_damage =
              Combat.melee_damage(min_weapon, max_weapon, entity.str + entity.str_buff, class_id, user_min, user_max)

            # Drift #7: Apply full physical damage pipeline for PvE
            npc_defense = if npc_def, do: npc_def.def, else: 0
            defense_bonus = 0
            armor_pen = 0
            damage_modifier = 1.0
            damage_reduction = 1.0

            final_damage =
              Combat.apply_physical_damage_modifiers(
                raw_damage,
                npc_defense,
                defense_bonus,
                armor_pen,
                damage_modifier,
                damage_reduction
              )

            # VB6: CalculateElementalTagsModifiers — apply elemental matrix
            final_damage = Arena.Map.SpellEffects.apply_elemental_modifiers_for_weapon(final_damage, entity, npc_def)

            new_hp = max(npc.hp - final_damage, 0)
            npc = %{npc | hp: new_hp}

            # VB6: weapon skill gain on hit
            {entity, state} = maybe_gain_skill(state, char_id, entity, skill_name)

            # Send damage feedback to attacker
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:user_hitted_user, %{char_index: npc.char_index, damage: final_damage}})}
            )

            if new_hp <= 0 do
              # NPC died — delegate to consolidated death handler
              {entity, state} =
                Arena.Map.NpcDeath.resolve_npc_death(state, instance_id, npc,
                  killer_char_id: char_id,
                  killer_entity: entity,
                  final_damage: final_damage,
                  source: :melee
                )

              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}
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

            # Drift #2: Include equipment hit and evasion bonuses
            hit_bonus = CombatStats.equipment_hit_bonus(entity.equipment)
            evasion_bonus = CombatStats.equipment_evasion_bonus(defender.equipment)

            hit_roll =
              Combat.hit_chance(
                weapon_skill,
                entity.agi + entity.agi_buff,
                entity.level,
                class_id,
                def_tactics,
                defender.agi + defender.agi_buff,
                defender.level,
                def_class_id,
                hit_bonus,
                evasion_bonus
              )

            # VB6: meditating reduces evasion by 25%
            hit_roll = Combat.adjust_hit_for_meditate(hit_roll, defender.meditating)

            if :rand.uniform(100) <= hit_roll do
              # --- HIT: deal damage ---
              # VB6: weapon skill gain on hit
              {entity, state} = maybe_gain_skill(state, char_id, entity, skill_name)

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

              # Drift #4: Critical hit check — class-gated (bandido + knuckle only)
              weapon_type_id = CombatStats.weapon_type(entity.equipment)
              weapon_type_atom = weapon_type_to_atom(weapon_type_id)
              wrestling_skill = Map.get(entity.skills, :wrestling, 0)
              extra_crit = CombatStats.weapon_extra_crit_chance(entity.equipment)

              raw_damage =
                if Combat.critical_hit?(entity.class, weapon_type_atom, wrestling_skill, extra_crit),
                  do: Combat.apply_critical(raw_damage),
                  else: raw_damage

              # Drift #7: Apply full physical damage pipeline for PvP
              {min_def, max_def} = CombatStats.effective_defense(defender.equipment)
              defense = if max_def > min_def, do: Enum.random(min_def..max_def), else: min_def
              defense_bonus = CombatStats.equipment_defense_bonus(defender.equipment)

              final_damage =
                Combat.apply_physical_damage_modifiers(
                  raw_damage,
                  defense,
                  defense_bonus,
                  _armor_penetration = 0,
                  _damage_modifier = 1.0,
                  _damage_reduction = 1.0
                )

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

              # Guild war: no criminal flag when attacking enemy guild members
              guild_war = Arena.GuildServer.players_at_war?(char_id, defender_id)

              {entity, state} =
                if not defender.criminal and not guild_war do
                  # VB6 Modulo_UsUaRiOs.bas:2260 — VolverCriminal handles
                  # sanctuary tiles, Ciudadano→Criminal score reset, NoPKs
                  # warping, and party disband.
                  Arena.Map.CriminalStatus.volver_criminal(state, char_id, entity)
                else
                  {entity, state}
                end

              {defender, state} =
                if new_hp <= 0 do
                  Helpers.send_to_session(
                    state.sessions,
                    defender_id,
                    {:send_raw, Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})}
                  )

                  Arena.Map.PlayerDeath.handle_player_death(state, defender_id, defender)
                else
                  {defender, state}
                end

              # Faction score + kill counters + guild XP on PvP kill
              entity =
                if defender.dead do
                  score = Arena.Map.Faction.faction_score_for_kill(entity, defender)
                  entity = if score > 0, do: %{entity | faction_score: entity.faction_score + score}, else: entity
                  entity = Arena.Map.PlayerDeath.update_pvp_kill_counters(entity, defender)

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
            else
              # --- MISS: Drift #3 — shield block checked AFTER miss (second chance) ---
              # VB6 ref: SistemaCombate.bas UsuarioImpacto (line 1014-1033)
              shield_pct = CombatStats.shield_defense_pct(defender.equipment)
              def_skill = Map.get(defender.skills, :combat_defense, 50)

              # Drift #3: Use DEFENDER's tactics (not attacker's weapons skill)
              if shield_pct > 0 and Combat.shield_block?(shield_pct, def_skill, def_tactics) do
                # Shield blocked the attack
                {defender, state} = maybe_gain_skill(state, defender_id, defender, :combat_defense)

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
                # Pure miss — no block
                players = Map.put(state.players, char_id, entity)
                %{state | players: players}
              end
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
    start = System.monotonic_time()
    result = do_handle_cast_spell(state, char_id, spell_slot, target_x, target_y)
    duration = System.monotonic_time() - start

    spell_result =
      case result do
        {:reply, :ok, _} -> :ok
        {:reply, {:error, reason}, _} -> reason
      end

    :telemetry.execute([:arena, :combat, :spell], %{duration: duration},
      %{map_id: state.map_id, result: spell_result})

    result
  end

  defp do_handle_cast_spell(state, char_id, spell_slot, target_x, target_y) do
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

                # VB6: Target field validation
                # 1=user only, 2=NPC only, 3=user+NPC, 4=terrain/self
                target_occ =
                  if target_x != nil and target_y != nil and not target_oob do
                    Helpers.get_occupancy(state.occupancy, target_x, target_y)
                  else
                    nil
                  end

                invalid_target =
                  spell_def != nil and target_x != nil and target_y != nil and
                    not valid_spell_target?(spell_def.target, target_occ)

                cond do
                  spell_def == nil ->
                    {:reply, {:error, :unknown_spell}, state}

                  not spell_in_range ->
                    {:reply, {:error, :out_of_range}, state}

                  # VB6: spell target type mismatch
                  invalid_target ->
                    spell_req_fail_target(state, char_id)

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
                    # VB6: casting breaks meditation and rest
                    entity = %{entity | meditating: false, resting: false}

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

                    state = Arena.Map.SpellEffects.apply_spell(state, char_id, entity, spell_def, target_x, target_y)
                    {:reply, :ok, state}
                end
            end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  # VB6: SubirSkill (Modulo_UsUaRiOs.bas:1617-1670). Practice-based skill-up.
  # Gates on hunger/thirst, per-level cap, quadratic probability; on success
  # bumps the skill, awards 5 * ExpMult XP, and checks for level-up.
  def maybe_gain_skill(state, char_id, entity, skill_name) do
    current = Map.get(entity.skills, skill_name, 0)
    expert? = Map.get(entity, :expert_skill_pending, false)
    xp_mult = Arena.Settings.get(:xp_multiplier, 1.0)

    case Combat.roll_skill_gain(entity.level, current, expert?, entity.hunger, entity.thirst, xp_mult) do
      {:gain, bonus_exp} ->
        entity = %{
          entity
          | skills: Map.put(entity.skills, skill_name, current + 1),
            xp: entity.xp + bonus_exp
        }

        entity = check_level_up(entity, state.sessions, char_id)
        send_xp_update(state, char_id, entity)
        {entity, state}

      :no_gain ->
        {entity, state}
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
  def drop_npc_gold(state, _npc, give_gld) when give_gld <= 0, do: state

  def drop_npc_gold(state, npc, give_gld) do
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
    class_id = Helpers.class_atom_to_id(entity.class)

    case Combat.level_up_gains(entity.level, class_id, entity.int, entity.agi, entity.xp, :rand.uniform()) do
      {:level_up, gains} ->
        new_max_hp = entity.max_hp + gains.hp_gain
        new_max_mana = entity.max_mana + gains.mana_gain
        new_max_stamina = entity.max_stamina + gains.sta_gain

        entity = %{
          entity
          | level: gains.new_level,
            xp: gains.remaining_xp,
            max_hp: new_max_hp,
            hp: new_max_hp,
            max_mana: new_max_mana,
            mana: new_max_mana,
            max_stamina: new_max_stamina,
            stamina: new_max_stamina,
            min_hit: gains.min_hit,
            max_hit: gains.max_hit,
            skill_points: entity.skill_points + gains.skill_points
        }

        # Level-up packet
        Helpers.send_to_session(sessions, char_id, {:send_raw, Encoder.encode({:level_up, %{level: gains.new_level}})})

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
          {:send_raw,
           Encoder.encode({:console_msg, %{message: "Has alcanzado el nivel #{gains.new_level}!", font_index: 0}})}
        )

        # Recursive check for multiple level ups
        check_level_up(entity, sessions, char_id)

      :no_level_up ->
        entity
    end
  end

  @doc """
  VB6 deep death: clear all transient combat/status state.
  Called from every path that sets dead: true.
  Despawns pets owned by the dying player.
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
          {capped, new_pool} = Combat.cap_xp_to_pool(xp_gained, npc_live.exp_count)
          npc_live = %{npc_live | exp_count: new_pool}
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
  def same_faction?(attacker, defender) do
    attacker.faction != :none and defender.faction != :none and
      attacker.faction == defender.faction
  end

  # Party safe mode: if both players are in the same party and party safe is on, block the attack.
  def party_safe_block?(attacker_id, defender) do
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

  # ==================================================================
  # VB6: spell target type validation
  # ==================================================================

  # VB6 Hechizos.dat Target field:
  #   1 = user/player only (heals, buffs, cure poison, resurrect)
  #   2 = NPC only (stun, petrify)
  #   3 = user + NPC (damage spells)
  #   4 = terrain/self (summons)
  #   0 = unset/any (treat as 3 for compatibility)

  defp valid_spell_target?(0, _occ), do: true
  defp valid_spell_target?(3, _occ), do: true
  defp valid_spell_target?(4, _occ), do: true
  defp valid_spell_target?(1, nil), do: true
  defp valid_spell_target?(1, {:player, _}), do: true
  defp valid_spell_target?(1, _), do: false
  defp valid_spell_target?(2, {:npc, _}), do: true
  defp valid_spell_target?(2, _), do: false
  defp valid_spell_target?(_, _), do: true

  defp spell_req_fail_target(state, char_id) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw,
       Encoder.encode(
         {:console_msg, %{message: "Objetivo invalido.", font_index: 0}}
       )}
    )

    {:reply, {:error, :invalid_target}, state}
  end

  # VB6 e_WeaponType mapping (Drift #4)
  # Maps integer weapon_type IDs to atoms for critical hit class gating.
  @weapon_type_atoms %{
    1 => :knuckle,
    2 => :bow,
    3 => :gunpowder,
    4 => :dagger,
    5 => :sword
  }
  defp weapon_type_to_atom(type_id), do: Map.get(@weapon_type_atoms, type_id, :sword)
end
