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
  @map_width 100
  @map_height 100
  @aoi_range_x Application.compile_env(:arena, :aoi_range_x, 11)
  @aoi_range_y Application.compile_env(:arena, :aoi_range_y, 9)

  @req_weapon 0x001
  @req_shield 0x002
  @req_armor 0x004
  @req_helm 0x008
  @req_projectile 0x020
  @req_ship 0x040
  @req_on_land 0x200
  @req_on_water 0x400

  @poison_tick_interval 2000

  @faction_pvp_maps [58, 59, 60, 195, 196]

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
          now < entity.next_attack_at -> {:reply, {:error, :cooldown}, state}
          entity.dead -> {:reply, {:error, :dead}, state}
          entity.paralyzed -> {:reply, {:error, :paralyzed}, state}
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

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_ranged_attack(state, char_id, entity, _weapon_def, target_x, target_y, now) do
    # VB6 uses Chebyshev distance (max of dx, dy) for ranged checks
    distance = max(abs(entity.x - target_x), abs(entity.y - target_y))

    cond do
      distance > @ranged_max_distance ->
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:console_msg, %{message: "Demasiado lejos.", font_index: 0}})})
        {:reply, {:error, :out_of_range}, state}

      entity.equipment[:municion] == nil ->
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:console_msg, %{message: "No tienes municiones equipadas.", font_index: 0}})})
        {:reply, {:error, :no_ammo}, state}

      true ->
        ammo_id = entity.equipment[:municion]
        ammo_slot_idx = Enum.find_index(entity.inventory, fn
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

    {inventory, equipment} = if new_amount <= 0 do
      {List.replace_at(entity.inventory, slot_idx, nil),
       Map.put(entity.equipment, :municion, nil)}
    else
      {List.replace_at(entity.inventory, slot_idx, %{slot | amount: new_amount}),
       entity.equipment}
    end

    entity = %{entity | inventory: inventory, equipment: equipment}

    # Send inventory update to client
    if new_amount <= 0 do
      Helpers.send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:change_inventory_slot, %{slot: slot_idx + 1, obj_index: 0, amount: 0, equipped: false, valor: 0.0}})})
    else
      item_def = GameData.get_item(ammo_id)
      valor = if item_def, do: item_def.valor / 1, else: 0.0
      Helpers.send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:change_inventory_slot, %{slot: slot_idx + 1, obj_index: ammo_id, amount: new_amount, equipped: true, valor: valor}})})
    end

    entity
  end

  # Find an inventory slot for an item: existing stack if stackable, or first empty slot
  def find_inventory_slot(entity, item_id, stackable) do
    if stackable do
      # Try to find existing stack first
      idx = Enum.find_index(entity.inventory, fn
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
          hit_roll = Combat.hit_chance(weapon_skill, entity.agi, entity.level, class_id,
                                       npc_evasion, 0, (if npc_def, do: npc_def.npc_level, else: 1), class_id)

          if :rand.uniform(100) <= hit_roll do
            # VB6: base user damage added to weapon damage
            {user_min, user_max} = Combat.base_user_damage(entity.level, class_id)
            raw_damage = Combat.melee_damage(min_weapon, max_weapon, entity.str + entity.str_buff, class_id, user_min, user_max)
            npc_defense = if npc_def, do: npc_def.def, else: 0
            final_damage = max(raw_damage - npc_defense, 0)

            new_hp = max(npc.hp - final_damage, 0)
            npc = %{npc | hp: new_hp}

            # VB6: weapon skill gain on hit
            entity = maybe_gain_skill(entity, skill_name)

            # Send damage feedback to attacker
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:user_hitted_user, %{char_index: npc.char_index, damage: final_damage}})})

            if new_hp <= 0 do
              # NPC died
              npc = %{npc | alive: false, respawn_at: System.monotonic_time(:millisecond) + ((if npc_def, do: npc_def.intervalo_respawn, else: 60) * 1000)}
              state = put_in(state.npcs_live[instance_id], npc)
              occupancy = Helpers.clear_occupancy(state.occupancy, npc.x, npc.y)
              state = %{state | occupancy: occupancy}

              # Broadcast NPC removal
              remove_raw = Encoder.encode({:character_remove, %{char_index: npc.char_index}})
              Visibility.broadcast_visible_all(state, npc.x, npc.y, fn pid -> send(pid, {:send_raw, remove_raw}) end)

              # Award XP
              give_exp = if npc_def, do: npc_def.give_exp, else: 0
              npc_level = if npc_def, do: npc_def.npc_level, else: 1
              xp_gained = Combat.xp_gain(final_damage, give_exp, npc.max_hp, entity.level, npc_level)
              entity = %{entity | xp: entity.xp + xp_gained}

              # Check level up
              entity = check_level_up(entity, state.sessions, char_id)

              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_exp, %{current_xp: entity.xp, next_xp: GameData.exp_for_level(entity.level + 1) || 0}})})

              # Award gold
              give_gld = if npc_def, do: npc_def.give_gld, else: 0
              entity = if give_gld > 0, do: %{entity | gold: entity.gold + give_gld}, else: entity
              if give_gld > 0 do
                Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:update_gold, %{gold: entity.gold}})})
              end

              # Drop loot
              state = drop_npc_loot(state, npc, npc_def)

              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            else
              state = put_in(state.npcs_live[instance_id], npc)
              # NPC acquires target on being hit
              npc = %{npc | target_id: char_id}
              state = put_in(state.npcs_live[instance_id], npc)

              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            end
          else
            # Miss
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
        cond do
          entity.safe_mode ->
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:console_msg, %{message: "Tienes el seguro activado.", font_index: 0}})})
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          state.safe_zone and not faction_pvp_exception?(state.map_id, entity, defender) ->
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:console_msg, %{message: "Zona segura.", font_index: 0}})})
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

            hit_roll = Combat.hit_chance(weapon_skill, entity.agi + entity.agi_buff, entity.level, class_id,
                                         def_tactics, defender.agi + defender.agi_buff, defender.level, def_class_id)

            # VB6: meditating reduces evasion by 25%
            hit_roll = Combat.adjust_hit_for_meditate(hit_roll, defender.meditating)

            if :rand.uniform(100) <= hit_roll do
              shield_pct = CombatStats.shield_defense_pct(defender.equipment)
              def_skill = Map.get(defender.skills, :combat_defense, 50)

              if shield_pct > 0 and Combat.shield_block?(shield_pct, def_skill, weapon_skill) do
                # VB6: defense skill gain on block
                defender = maybe_gain_skill(defender, :combat_defense)

                Helpers.send_to_session(state.sessions, defender_id, {:send_raw,
                  Encoder.encode({:blocked_with_shield_user, %{}})})
                block_raw = Encoder.encode({:blocked_with_shield_other, %{char_index: defender.char_index}})
                Visibility.broadcast_visible(state, defender.x, defender.y, defender_id, fn pid ->
                  send(pid, {:send_raw, block_raw})
                end)

                players = state.players
                  |> Map.put(char_id, entity)
                  |> Map.put(defender_id, defender)
                %{state | players: players}
              else
                # VB6: base user damage added to weapon damage
                {user_min, user_max} = Combat.base_user_damage(entity.level, class_id)
                raw_damage = Combat.melee_damage(min_weapon, max_weapon, entity.str + entity.str_buff, class_id, user_min, user_max)
                {min_def, max_def} = CombatStats.effective_defense(defender.equipment)
                {final_damage, _location} = Combat.apply_defense(raw_damage, {min_def, max_def})

                new_hp = max(defender.hp - final_damage, 0)
                defender = %{defender | hp: new_hp}

                Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:user_hitted_user, %{char_index: defender.char_index, damage: final_damage}})})
                Helpers.send_to_session(state.sessions, defender_id, {:send_raw,
                  Encoder.encode({:user_hitted_by_user, %{char_index: entity.char_index, damage: final_damage}})})
                Helpers.send_to_session(state.sessions, defender_id, {:send_raw,
                  Encoder.encode({:update_hp, %{min_hp: new_hp}})})

                # VB6: weapon skill gain on hit
                entity = maybe_gain_skill(entity, skill_name)
                entity = if not defender.criminal, do: %{entity | criminal: true}, else: entity

                defender = if new_hp <= 0 do
                  Helpers.send_to_session(state.sessions, defender_id, {:send_raw,
                    Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})})
                  %{defender | dead: true}
                else
                  defender
                end

                players = state.players
                  |> Map.put(char_id, entity)
                  |> Map.put(defender_id, defender)
                %{state | players: players}
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
          now < slot_cd -> {:reply, {:error, :cooldown}, state}
          entity.dead -> {:reply, {:error, :dead}, state}
          entity.paralyzed -> {:reply, {:error, :paralyzed}, state}
          true ->
            spell_idx = spell_slot - 1

            cond do
              spell_idx < 0 or spell_idx >= length(entity.spells) ->
                {:reply, {:error, :invalid_slot}, state}

              true ->
                spell_id = Enum.at(entity.spells, spell_idx)
                spell_def = GameData.get_spell(spell_id)

                # VB6: spell range check uses AoI range
                spell_in_range = target_x == nil or target_y == nil or
                  (abs(entity.x - target_x) <= @aoi_range_x and abs(entity.y - target_y) <= @aoi_range_y)

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
                    Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:console_msg, %{message: "Tu nivel es muy alto para lanzar este hechizo.", font_index: 0}})})
                    {:reply, {:error, :level_too_high}, state}

                  # VB6: NeedStaff -- requires a magic staff equipped
                  spell_def.need_staff and not has_staff_equipped?(entity) ->
                    Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:console_msg, %{message: "Necesitas un baculo equipado.", font_index: 0}})})
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

                  true ->
                    entity = Helpers.break_invisibility(entity, state, char_id)
                    # VB6: per-spell cooldown in seconds
                    cooldown_ms = spell_def.cooldown * 1000
                    entity = %{entity |
                      mana: entity.mana - spell_def.mana_required,
                      stamina: max(entity.stamina - spell_def.sta_required, 0),
                      spell_cooldowns: Map.put(entity.spell_cooldowns, spell_slot, now + cooldown_ms)
                    }

                    state = apply_spell(state, char_id, entity, spell_def, target_x, target_y)
                    {:reply, :ok, state}
                end
            end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
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
      fx_char_index = case target_occ do
        {:player, pid} -> case Map.get(state.players, pid) do nil -> 0; p -> p.char_index end
        {:npc, iid} -> case Map.get(state.npcs_live, iid) do nil -> 0; n -> n.char_index end
        _ -> entity.char_index
      end

      fx_x = if target_x, do: target_x, else: entity.x
      fx_y = if target_y, do: target_y, else: entity.y
      fx_raw = Encoder.encode({:create_fx, %{char_index: fx_char_index, fx: spell_def.fx_grh, loops: spell_def.loops, x: fx_x, y: fx_y}})
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
          tx >= 1 and tx <= @map_width and ty >= 1 and ty <= @map_height do
        {tx, ty, Helpers.get_occupancy(state.occupancy, tx, ty)}
      end

    # Filter by area_afecta: 1=users, 2=NPCs, 3=both
    targets = Enum.filter(targets, fn {_tx, _ty, occ} ->
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
        heal = if spell_def.max_hp > spell_def.min_hp,
          do: Enum.random(spell_def.min_hp..spell_def.max_hp),
          else: spell_def.min_hp
        apply_spell_heal(state, char_id, entity, heal, spell_def, target_x, target_y)

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

            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:user_hitted_user, %{char_index: npc.char_index, damage: final_damage}})})

            if new_hp <= 0 do
              npc = %{npc | alive: false, respawn_at: System.monotonic_time(:millisecond) + ((if npc_def, do: npc_def.intervalo_respawn, else: 60) * 1000)}
              state = put_in(state.npcs_live[instance_id], npc)
              occupancy = Helpers.clear_occupancy(state.occupancy, npc.x, npc.y)
              state = %{state | occupancy: occupancy}

              remove_raw = Encoder.encode({:character_remove, %{char_index: npc.char_index}})
              Visibility.broadcast_visible_all(state, npc.x, npc.y, fn pid -> send(pid, {:send_raw, remove_raw}) end)

              give_exp = if npc_def, do: npc_def.give_exp, else: 0
              npc_level = if npc_def, do: npc_def.npc_level, else: 1
              xp_gained = Combat.xp_gain(final_damage, give_exp, npc.max_hp, entity.level, npc_level)
              entity = %{entity | xp: entity.xp + xp_gained}
              entity = check_level_up(entity, state.sessions, char_id)

              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_exp, %{current_xp: entity.xp, next_xp: GameData.exp_for_level(entity.level + 1) || 0}})})
              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

              state = drop_npc_loot(state, npc, npc_def)
              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            else
              npc = %{npc | target_id: char_id}
              state = put_in(state.npcs_live[instance_id], npc)
              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_mana, %{min_mana: entity.mana}})})
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
            final_damage = damage
            new_hp = max(defender.hp - final_damage, 0)
            defender = %{defender | hp: new_hp}

            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:user_hitted_user, %{char_index: defender.char_index, damage: final_damage}})})
            Helpers.send_to_session(state.sessions, target_id, {:send_raw,
              Encoder.encode({:user_hitted_by_user, %{char_index: entity.char_index, damage: final_damage}})})
            Helpers.send_to_session(state.sessions, target_id, {:send_raw,
              Encoder.encode({:update_hp, %{min_hp: new_hp}})})
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

            entity = if not defender.criminal, do: %{entity | criminal: true}, else: entity

            defender = if new_hp <= 0 do
              Helpers.send_to_session(state.sessions, target_id, {:send_raw,
                Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})})
              %{defender | dead: true}
            else
              defender
            end

            players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, defender)
            %{state | players: players}
        end

      _ ->
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})
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
              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:console_msg, %{message: "Esta muerto.", font_index: 5}})})
              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_mana, %{min_mana: entity.mana}})})
              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            else
              new_hp = min(target_entity.hp + heal, target_entity.max_hp)
              target_entity = %{target_entity | hp: new_hp}

              Helpers.send_to_session(state.sessions, target_id, {:send_raw,
                Encoder.encode({:update_hp, %{min_hp: new_hp}})})
              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

              players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
              %{state | players: players}
            end
        end

      _ ->
        # Self-heal
        new_hp = min(entity.hp + heal, entity.max_hp)
        entity = %{entity | hp: new_hp}

        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_hp, %{min_hp: new_hp}})})
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

        players = Map.put(state.players, char_id, entity)
        %{state | players: players}
    end
  end

  def apply_spell_status(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil
    now = System.monotonic_time(:millisecond)

    target_id = case target do
      {:player, tid} -> tid
      _ -> char_id
    end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      target_entity ->
        duration_ms = max((spell_def.duration || 0) * 1000, 3000)

        target_entity = cond do
          spell_def.paraliza ->
            buff = %{type: :paralyzed, expires_at: now + div(duration_ms, 2)}
            buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :paralyzed))]
            %{target_entity | paralyzed: true, buffs: buffs}

          spell_def.envenena ->
            buff = %{type: :poisoned, expires_at: now + duration_ms, next_tick: now + 2000}
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

          true -> target_entity
        end

        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
        %{state | players: players}
    end
  end

  def apply_spell_resurrect(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    target_id = case target do
      {:player, tid} -> tid
      _ -> nil
    end

    target_player = if target_id, do: Map.get(state.players, target_id)

    if target_player && target_player.dead do
      # VB6: spell min_hp is the % of max_hp to revive at (e.g. 10 -> 10%)
      revive_pct = max(spell_def.min_hp, 10)
      revive_hp = max(div(target_player.max_hp * revive_pct, 100), 1)

      revived = %{target_player |
        dead: false, hp: revive_hp, mana: 0, hunger: 0, thirst: 0,
        buffs: [], paralyzed: false, poisoned: false, invisible: false
      }

      # Notify revived player
      Helpers.send_to_session(state.sessions, target_id, {:send_raw,
        Encoder.encode({:update_hp, %{min_hp: revive_hp}})})
      Helpers.send_to_session(state.sessions, target_id, {:send_raw,
        Encoder.encode({:update_mana, %{min_mana: 0}})})
      Helpers.send_to_session(state.sessions, target_id, {:send_raw,
        Encoder.encode({:update_hunger_and_thirst, %{max_hunger: 100, min_hunger: 0, max_thirst: 100, min_thirst: 0}})})
      Helpers.send_to_session(state.sessions, target_id, {:send_raw,
        Encoder.encode({:console_msg, %{message: "Has sido resucitado!", font_index: 0}})})

      # Update caster mana
      Helpers.send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

      players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, revived)
      %{state | players: players}
    else
      # No dead player at target -- just update caster mana
      Helpers.send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:update_mana, %{min_mana: entity.mana}})})
      Helpers.send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:console_msg, %{message: "No hay un jugador muerto ahi.", font_index: 5}})})
      players = Map.put(state.players, char_id, entity)
      %{state | players: players}
    end
  end

  def apply_spell_attribute_buff(state, char_id, entity, spell_def, attr, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil
    now = System.monotonic_time(:millisecond)

    target_id = case target do
      {:player, tid} -> tid
      _ -> char_id
    end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      target_entity ->
        {sube, min_val, max_val} = case attr do
          :str -> {spell_def.sube_fu, spell_def.min_fu, spell_def.max_fu}
          :agi -> {spell_def.sube_ag, spell_def.min_ag, spell_def.max_ag}
        end

        amount = if max_val > min_val, do: Enum.random(min_val..max_val), else: min_val
        duration_ms = max((spell_def.duration || 0) * 1000, 3000)
        buff_type = if attr == :str, do: :str_buff, else: :agi_buff

        # sube == 1 -> increase, sube == 2 -> decrease
        actual = if sube == 1, do: amount, else: -amount

        target_entity = case attr do
          :str -> %{target_entity | str_buff: target_entity.str_buff + actual}
          :agi -> %{target_entity | agi_buff: target_entity.agi_buff + actual}
        end

        buff = %{type: buff_type, expires_at: now + duration_ms, value: actual}
        buffs = [buff | target_entity.buffs]
        target_entity = %{target_entity | buffs: buffs}

        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
        %{state | players: players}
    end
  end

  def apply_spell_mana(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    target_id = case target do
      {:player, tid} -> tid
      _ -> char_id
    end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      target_entity ->
        amount = if spell_def.max_mana > spell_def.min_mana,
          do: Enum.random(spell_def.min_mana..spell_def.max_mana),
          else: spell_def.min_mana

        target_entity = if spell_def.sube_mana == 1 do
          # Restore mana
          %{target_entity | mana: min(target_entity.mana + amount, target_entity.max_mana)}
        else
          # Drain mana
          %{target_entity | mana: max(target_entity.mana - amount, 0)}
        end

        Helpers.send_to_session(state.sessions, target_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: target_entity.mana}})})
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
        %{state | players: players}
    end
  end

  def apply_spell_stamina(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    target_id = case target do
      {:player, tid} -> tid
      _ -> char_id
    end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      target_entity ->
        amount = if spell_def.max_sta > spell_def.min_sta,
          do: Enum.random(spell_def.min_sta..spell_def.max_sta),
          else: spell_def.min_sta

        target_entity = if spell_def.sube_sta == 1 do
          %{target_entity | stamina: min(target_entity.stamina + amount, target_entity.max_stamina)}
        else
          %{target_entity | stamina: max(target_entity.stamina - amount, 0)}
        end

        Helpers.send_to_session(state.sessions, target_id, {:send_raw,
          Encoder.encode({:update_stamina, %{min_sta: target_entity.stamina}})})
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

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
    entity = Enum.reduce(expired, entity, fn buff, ent ->
      case buff.type do
        :paralyzed -> %{ent | paralyzed: false}
        :poisoned -> %{ent | poisoned: false}
        :invisible -> %{ent | invisible: false}
        :immobilized -> %{ent | immobilized: false}
        :str_buff -> %{ent | str_buff: max(ent.str_buff - (buff[:value] || 0), 0)}
        :agi_buff -> %{ent | agi_buff: max(ent.agi_buff - (buff[:value] || 0), 0)}
        _ -> ent
      end
    end)

    # Process poison ticks on active poison buffs
    {entity, active} = Enum.map_reduce(active, entity, fn buff, ent ->
      if buff.type == :poisoned and now >= (buff[:next_tick] || 0) do
        damage = max(Enum.random(3..5) * div(ent.max_hp, 100), 1)
        new_hp = max(ent.hp - damage, 0)
        ent = %{ent | hp: new_hp}

        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_hp, %{min_hp: new_hp}})})
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:console_msg, %{message: "Veneno te hace #{damage} de daño.", font_index: 5}})})

        buff = %{buff | next_tick: now + @poison_tick_interval}
        {buff, ent}
      else
        {buff, ent}
      end
    end)

    entity = %{entity | buffs: active}

    # Check poison death
    entity = if entity.hp <= 0 and not entity.dead do
      Helpers.send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})})
      %{entity | dead: true}
    else
      entity
    end

    players = Map.put(state.players, char_id, entity)
    %{state | players: players}
  end

  def maybe_gain_skill(entity, skill_name) do
    current = Map.get(entity.skills, skill_name, 0)
    if current < @max_skill and :rand.uniform(100) <= @skill_gain_chance do
      %{entity | skills: Map.put(entity.skills, skill_name, current + 1)}
    else
      entity
    end
  end

  def check_level_up(entity, sessions, char_id) do
    next_xp = GameData.exp_for_level(entity.level + 1)

    if next_xp && entity.xp >= next_xp do
      entity = %{entity | level: entity.level + 1, xp: entity.xp - next_xp}
      Helpers.send_to_session(sessions, char_id, {:send_raw, Encoder.encode({:level_up, %{level: entity.level}})})
      # Recursive check for multiple level ups
      check_level_up(entity, sessions, char_id)
    else
      entity
    end
  end

  def drop_npc_loot(state, _npc, nil), do: state
  def drop_npc_loot(state, npc, npc_def) do
    Enum.reduce(npc_def.loot_table, state, fn %{item_id: item_id, amount: amount}, state ->
      # Simple probability: 1 in 5 chance per loot entry
      if :rand.uniform(5) == 1 do
        pos = {npc.x, npc.y}
        unless Map.has_key?(state.ground_items, pos) do
          ground_items = Map.put(state.ground_items, pos, %{item_id: item_id, amount: amount})
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

  # VB6: requirement mask failure -- send message and return error reply
  def spell_req_fail(state, char_id, message) do
    Helpers.send_to_session(state.sessions, char_id, {:send_raw,
      Encoder.encode({:console_msg, %{message: message, font_index: 0}})})
    {:reply, {:error, :requirement_not_met}, state}
  end

  # TileGrid tile values: 0=walkable, 1=blocked, 2=water, 3=lava
  def tile_is_water?(state, x, y) do
    TileGrid.get_tile(state.map_id, x, y) == 2
  end

  # VB6: Armada vs Caos PvP is allowed in faction city maps even in safe zones.
  # Maps 58-60 = Armada cities, 195-196 = Caos cities.
  def faction_pvp_exception?(map_id, attacker, defender) do
    map_id in @faction_pvp_maps and
      attacker.criminal != defender.criminal
  end
end
