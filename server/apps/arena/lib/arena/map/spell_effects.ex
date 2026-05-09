defmodule Arena.Map.SpellEffects do
  @moduledoc """
  Spell effect application (damage, heal, status, resurrect, buffs).

  All `apply_spell_*` functions return `{state, effects}` — pure-ish bodies
  that produce `Arena.Map.Effect.t()` values for the runner. Inner death /
  criminal-flag / XP helpers (NpcDeath, PlayerDeath, CriminalStatus,
  CombatHandlers.award_hit_xp) thread their own effects up through the
  same return shape; nothing in this module emits `{:send_raw, _}`
  directly.
  """

  import Bitwise

  alias Arena.Clock
  alias Arena.Map.{Effects, Helpers}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  require Logger

  # VB6: IntervaloVeneno = 90 counter ticks at 40ms (MaybeRunGameEvents) = 3600ms
  @poison_tick_interval 3600

  def apply_spell(state, char_id, entity, spell_def, target_x, target_y) do
    fx_effects = broadcast_spell_fx(state, entity, spell_def, target_x, target_y)

    {state, effects} =
      if spell_def.area_radio > 0 and target_x != nil and target_y != nil do
        apply_spell_aoe(state, char_id, entity, spell_def, target_x, target_y)
      else
        apply_spell_single(state, char_id, entity, spell_def, target_x, target_y)
      end

    {state, fx_effects ++ effects}
  end

  # Returns the FX/wav broadcast effects (no state mutation).
  def broadcast_spell_fx(state, entity, spell_def, target_x, target_y) do
    fx_effect =
      if spell_def.fx_grh > 0 do
        target_occ =
          if target_x && target_y,
            do: Helpers.get_occupancy(state.occupancy, target_x, target_y),
            else: nil

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

        packet =
          Encoder.encode(
            {:create_fx,
             %{
               char_index: fx_char_index,
               fx: spell_def.fx_grh,
               loops: spell_def.loops,
               x: fx_x,
               y: fx_y
             }}
          )

        [Effects.broadcast_visible_all(entity.x, entity.y, packet)]
      else
        []
      end

    wav_effect =
      if spell_def.wav > 0 do
        packet = Encoder.encode({:play_wave, %{wav: spell_def.wav, x: entity.x, y: entity.y}})
        [Effects.broadcast_visible_all(entity.x, entity.y, packet)]
      else
        []
      end

    fx_effect ++ wav_effect
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
    Enum.reduce(targets, {state, []}, fn {tx, ty, _occ}, {acc, effects} ->
      caster = Map.get(acc.players, char_id, entity)
      {acc, more} = apply_spell_single(acc, char_id, caster, spell_def, tx, ty)
      {acc, effects ++ more}
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
        damage = Arena.Combat.spell_damage(spell_def.min_hp, spell_def.max_hp, entity.level, is_mage)
        apply_spell_damage(state, char_id, entity, damage, spell_def, target_x, target_y)

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
        {%{state | players: players}, []}
    end
  end

  defp console(message, font_index \\ 0) do
    Encoder.encode({:console_msg, %{message: message, font_index: font_index}})
  end

  defp update_mana_effect(char_id, entity) do
    Effects.send(char_id, Encoder.encode({:update_mana, %{min_mana: entity.mana}}))
  end

  # VB6 26g: RemoveInvisibility spell — reveals invisible players in 11-tile radius
  # Players with no_detectable flag are immune.
  def apply_spell_remove_invisibility(state, char_id, entity, _spell_def, target_x, target_y) do
    cx = target_x || entity.x
    cy = target_y || entity.y
    radius = 11

    {state, effects} =
      Enum.reduce(state.players, {state, []}, fn {pid, target}, {acc, effs} ->
        if pid != char_id and target.invisible and not target.no_detectable and
             abs(target.x - cx) <= radius and abs(target.y - cy) <= radius do
          buffs = Enum.reject(target.buffs, &(&1.type == :invisible))
          updated = %{target | invisible: false, buffs: buffs}
          players = Map.put(acc.players, pid, updated)
          acc = %{acc | players: players}

          reveal_effects = [
            Effects.send(pid, console("Tu invisibilidad ya no tiene efecto.")),
            Effects.reveal_to_non_gm(updated)
          ]

          {acc, reveal_effects ++ effs}
        else
          {acc, effs}
        end
      end)

    players = Map.put(state.players, char_id, entity)
    {%{state | players: players}, effects}
  end

  def apply_spell_damage(state, char_id, entity, damage, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    case target do
      {:npc, instance_id} ->
        case Map.get(state.npcs_live, instance_id) do
          npc when is_map(npc) and npc.alive ->
            apply_spell_damage_to_npc(state, char_id, entity, damage, instance_id, npc)

          _ ->
            players = Map.put(state.players, char_id, entity)
            {%{state | players: players}, []}
        end

      {:player, target_id} when target_id != char_id ->
        case Map.get(state.players, target_id) do
          nil ->
            players = Map.put(state.players, char_id, entity)
            {%{state | players: players}, []}

          defender ->
            apply_spell_damage_to_player(state, char_id, entity, damage, spell_def, target_id, defender)
        end

      _ ->
        players = Map.put(state.players, char_id, entity)
        {%{state | players: players}, [update_mana_effect(char_id, entity)]}
    end
  end

  defp apply_spell_damage_to_npc(state, char_id, entity, damage, instance_id, npc) do
    npc_def = GameData.get_npc(npc.npc_id)
    magic_res = if npc_def, do: npc_def.magic_resistance, else: 0
    final_damage = Arena.Combat.apply_magic_resistance(damage, magic_res)
    new_hp = max(npc.hp - final_damage, 0)
    npc = %{npc | hp: new_hp}

    hit_effect =
      Effects.send(
        char_id,
        Encoder.encode({:user_hitted_user, %{char_index: npc.char_index, damage: final_damage}})
      )

    if new_hp <= 0 do
      # NPC died — delegate to consolidated death handler. send_mana_update
      # appends an update_mana effect for the killer, so we don't add one
      # here.
      {entity, state, death_effects} =
        Arena.Map.NpcDeath.resolve_npc_death(state, instance_id, npc,
          killer_char_id: char_id,
          killer_entity: entity,
          final_damage: final_damage,
          source: :spell,
          send_mana_update: true
        )

      players = Map.put(state.players, char_id, entity)
      {%{state | players: players}, [hit_effect | death_effects]}
    else
      npc = %{npc | target_id: char_id}
      state = put_in(state.npcs_live[instance_id], npc)

      # VB6: per-hit proportional XP (no XP for hitting pets)
      {entity, state, xp_effects} =
        if npc.owner_id == nil do
          Arena.Map.CombatHandlers.award_hit_xp(state, char_id, entity, final_damage, npc_def, instance_id)
        else
          {entity, state, []}
        end

      players = Map.put(state.players, char_id, entity)

      {%{state | players: players},
       [hit_effect | xp_effects] ++ [update_mana_effect(char_id, entity)]}
    end
  end

  defp apply_spell_damage_to_player(state, char_id, entity, damage, spell_def, defender_id, defender) do
    # VB6 parity: faction/duel exceptions for safe zone (same as physical attacks)
    duel_pvp_exception =
      Map.get(entity, :in_duel, false) and Map.get(defender, :in_duel, false) and
        Map.get(entity, :duel_opponent_id) == defender_id and Map.get(defender, :duel_opponent_id) == char_id

    cond do
      # VB6: safe zone blocks offensive spells on players (PuedeAtacar)
      Map.get(state.meta, :safe_zone, false) and
          not Arena.Map.CombatHandlers.faction_pvp_exception?(state.map_id, entity, defender) and
          not duel_pvp_exception ->
        spell_pvp_reject(state, char_id, entity, "Zona segura.")

      Arena.Map.CombatHandlers.same_faction?(entity, defender) ->
        spell_pvp_reject(state, char_id, entity, "No puedes atacar a un miembro de tu faccion.")

      Arena.Map.CombatHandlers.party_safe_block?(char_id, defender) ->
        spell_pvp_reject(state, char_id, entity, "No puedes atacar a un miembro de tu grupo.")

      true ->
        # VB6 full PvP magic damage formula (modHechizos.bas:3289-3331)
        # 1. Apply weapon magic bonuses (percentage + flat)
        {w_pct, w_abs, w_pen} = Arena.CombatStats.magic_bonuses_for_slot(entity.equipment, :weapon)
        dmg = damage + round(damage * w_pct / 100) + w_abs

        # 2. Apply ring magic bonuses (percentage + flat)
        {r_pct, r_abs, r_pen} = Arena.CombatStats.magic_bonuses_for_slot(entity.equipment, :ring)
        dmg = dmg + round(dmg * r_pct / 100) + r_abs

        # 3. Total penetration from attacker equipment
        total_penetration = w_pen + r_pen

        # 4. If spell does not ignore MR (anti_rm == 0), compute and apply MR
        anti_rm = Map.get(spell_def, :anti_rm, 0)

        dmg =
          if anti_rm == 0 do
            # VB6: GetUserMR(target) = armor + ring + shield + helmet MR + 100 * class MR mod
            def_class_id = Helpers.class_atom_to_id(defender.class)
            user_mr = Arena.CombatStats.get_user_mr(defender.equipment, def_class_id)

            # Also include resistance skill (VB6: MRSkillProtectionModifier feature)
            resist_skill = Map.get(defender.skills, :resistance, 0)
            total_mr = max(0, user_mr - total_penetration + resist_skill)

            if total_mr > 0 do
              max(round(dmg * (1 - total_mr / 100)), 0)
            else
              dmg
            end
          else
            dmg
          end

        # 5. Apply MagicDamageModifier (attacker) and MagicDamageReduction (defender)
        # VB6: GetMagicDamageModifier = max(1 + User.Modifiers.MagicDamageBonus, 0)
        # VB6: GetMagicDamageReduction = max(1 - User.Modifiers.MagicDamageReduction, 0)
        atk_modifier = max(1.0 + Map.get(entity, :magic_damage_modifier, 0.0), 0.0)
        def_reduction = max(1.0 - Map.get(defender, :magic_damage_reduction, 0.0), 0.0)
        dmg = round(dmg * atk_modifier * def_reduction)

        # VB6: Prevengo dano negativo
        final_damage = max(dmg, 0)

        new_hp = max(defender.hp - final_damage, 0)
        defender = %{defender | hp: new_hp}

        hit_effects = [
          Effects.send(
            char_id,
            Encoder.encode({:user_hitted_user, %{char_index: defender.char_index, damage: final_damage}})
          ),
          Effects.send(
            defender_id,
            Encoder.encode({:user_hitted_by_user, %{char_index: entity.char_index, damage: final_damage}})
          ),
          Effects.send(defender_id, Encoder.encode({:update_hp, %{min_hp: new_hp}})),
          update_mana_effect(char_id, entity)
        ]

        # Guild war: no criminal flag when attacking enemy guild members
        guild_war = Arena.GuildServer.players_at_war?(char_id, defender_id)

        {entity, state, criminal_effects} =
          if not defender.criminal and not guild_war do
            # VB6 Modulo_UsUaRiOs.bas:2260 — VolverCriminal handles
            # sanctuary tiles, Ciudadano→Criminal score reset, NoPKs
            # warping, and party disband.
            Arena.Map.CriminalStatus.volver_criminal(state, char_id, entity)
          else
            {entity, state, []}
          end

        {defender, state, death_effects} =
          if new_hp <= 0 do
            {defender, state, pd_effects} =
              Arena.Map.PlayerDeath.handle_player_death(state, defender_id, defender)

            {defender, state,
             [Effects.send(defender_id, console("Has muerto!", 5)) | pd_effects]}
          else
            {defender, state, []}
          end

        # Faction score + kill counters + guild XP on PvP spell kill
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

        players = state.players |> Map.put(char_id, entity) |> Map.put(defender_id, defender)
        state = %{state | players: players}

        char_change_effects =
          if defender.dead, do: [Effects.broadcast_character_change(defender)], else: []

        {state, hit_effects ++ criminal_effects ++ death_effects ++ char_change_effects}
    end
  end

  # Common reject path for PvP spells that fail safe-zone / faction / party
  # checks: refund-feel update_mana plus the relevant console message.
  defp spell_pvp_reject(state, char_id, entity, message) do
    players = Map.put(state.players, char_id, entity)

    {%{state | players: players},
     [Effects.send(char_id, console(message)), update_mana_effect(char_id, entity)]}
  end

  def apply_spell_heal(state, char_id, entity, heal, _spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil

    case target do
      {:player, target_id} ->
        case Map.get(state.players, target_id) do
          nil ->
            players = Map.put(state.players, char_id, entity)
            {%{state | players: players}, []}

          target_entity ->
            # VB6: cannot heal dead targets
            if target_entity.dead do
              players = Map.put(state.players, char_id, entity)

              {%{state | players: players},
               [
                 Effects.send(char_id, console("Esta muerto.", 5)),
                 update_mana_effect(char_id, entity)
               ]}
            else
              new_hp = min(target_entity.hp + heal, target_entity.max_hp)
              target_entity = %{target_entity | hp: new_hp}

              players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)

              {%{state | players: players},
               [
                 Effects.send(target_id, Encoder.encode({:update_hp, %{min_hp: new_hp}})),
                 update_mana_effect(char_id, entity)
               ]}
            end
        end

      _ ->
        # Self-heal
        new_hp = min(entity.hp + heal, entity.max_hp)
        entity = %{entity | hp: new_hp}
        players = Map.put(state.players, char_id, entity)

        {%{state | players: players},
         [
           Effects.send(char_id, Encoder.encode({:update_hp, %{min_hp: new_hp}})),
           update_mana_effect(char_id, entity)
         ]}
    end
  end

  def apply_spell_status(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil
    now = Clock.now_ms()

    target_id =
      case target do
        {:player, tid} -> tid
        _ -> char_id
      end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        {%{state | players: players}, []}

      target_entity ->
        # VB6: offensive status spells (paralysis, poison, immobilize) blocked in safe zone
        offensive_status = spell_def.paraliza or spell_def.envenena or spell_def.inmoviliza
        is_other_player = target_id != char_id

        safe_zone = Map.get(state.meta, :safe_zone, false)

        duel_pvp_exception =
          is_other_player and Map.get(entity, :in_duel, false) and Map.get(target_entity, :in_duel, false) and
            Map.get(entity, :duel_opponent_id) == target_id and Map.get(target_entity, :duel_opponent_id) == char_id

        if offensive_status and is_other_player and safe_zone and
             not Arena.Map.CombatHandlers.faction_pvp_exception?(state.map_id, entity, target_entity) and
             not duel_pvp_exception do
          players = Map.put(state.players, char_id, entity)
          {%{state | players: players}, [Effects.send(char_id, console("Zona segura."))]}
        else
          duration_ms = max((spell_def.duration || 0) * 1000, 3000)

          target_entity_before = target_entity

          target_entity =
            cond do
              spell_def.paraliza ->
                # VB6: Warrior/Hunter get 0.7x duration, others get full duration.
                effective_dur =
                  if target_entity.class in [:guerrero, :cazador],
                    do: trunc(duration_ms * 0.7),
                    else: duration_ms

                buff = %{type: :paralyzed, expires_at: now + effective_dur}
                buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :paralyzed))]
                %{target_entity | paralyzed: true, buffs: buffs}

              spell_def.envenena ->
                buff = %{type: :poisoned, expires_at: now + duration_ms, next_tick: now + @poison_tick_interval}
                buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :poisoned))]
                %{target_entity | poisoned: true, buffs: buffs}

              spell_def.cura_veneno ->
                buffs = Enum.reject(target_entity.buffs, &(&1.type == :poisoned))
                %{target_entity | poisoned: false, buffs: buffs}

              spell_def.ciega ->
                effective_dur =
                  if target_entity.class in [:guerrero, :cazador],
                    do: trunc(duration_ms * 0.7),
                    else: duration_ms

                buff = %{type: :blind, expires_at: now + effective_dur}
                buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :blind))]
                %{target_entity | blind: true, buffs: buffs}

              spell_def.cura_ceguera ->
                buffs = Enum.reject(target_entity.buffs, &(&1.type == :blind))
                %{target_entity | blind: false, buffs: buffs}

              spell_def.estupidez ->
                effective_dur =
                  if target_entity.class in [:guerrero, :cazador],
                    do: trunc(duration_ms * 0.7),
                    else: duration_ms

                buff = %{type: :dumb, expires_at: now + effective_dur}
                buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :dumb))]
                %{target_entity | dumb: true, buffs: buffs}

              spell_def.cura_estupidez ->
                buffs = Enum.reject(target_entity.buffs, &(&1.type == :dumb))
                %{target_entity | dumb: false, buffs: buffs}

              spell_def.invisibilidad ->
                buff = %{type: :invisible, expires_at: now + duration_ms}
                buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :invisible))]
                %{target_entity | invisible: true, buffs: buffs}

              spell_def.inmoviliza ->
                effective_dur =
                  if target_entity.class in [:guerrero, :cazador],
                    do: trunc(duration_ms * 0.7),
                    else: duration_ms

                buff = %{type: :immobilized, expires_at: now + effective_dur}
                buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :immobilized))]
                %{target_entity | immobilized: true, buffs: buffs}

              true ->
                target_entity
            end

          was_visible = not Map.get(target_entity_before, :invisible, false)
          now_invisible = target_entity.invisible

          # VB6 modHechizos.bas: only writes BlindNoMore / DumbNoMore when the
          # target was previously blind / dumb (mirrors the `.flags.Ceguera > 0`
          # / `.flags.Estupidez > 0` guards).
          was_blind = Map.get(target_entity_before, :blind, false)
          was_dumb = Map.get(target_entity_before, :dumb, false)

          status_effects =
            [update_mana_effect(char_id, entity)] ++
              if(was_blind and not target_entity.blind,
                do: [Effects.send(target_id, Encoder.encode({:blind_no_more, %{}}))],
                else: []
              ) ++
              if(was_dumb and not target_entity.dumb,
                do: [Effects.send(target_id, Encoder.encode({:dumb_no_more, %{}}))],
                else: []
              ) ++
              if(was_visible and now_invisible,
                do: [Effects.hide_from_non_gm(target_entity)],
                else: []
              )

          players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)

          {%{state | players: players}, status_effects}
        end
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
          blind: false,
          dumb: false,
          poisoned: false,
          invisible: false,
          oculto: false
      }

      players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, revived)
      state = %{state | players: players}

      effects = [
        Effects.send(target_id, Encoder.encode({:update_hp, %{min_hp: revive_hp}})),
        Effects.send(target_id, Encoder.encode({:update_mana, %{min_mana: 0}})),
        Effects.send(
          target_id,
          Encoder.encode(
            {:update_hunger_and_thirst,
             %{max_hunger: 100, min_hunger: 0, max_thirst: 100, min_thirst: 0}}
          )
        ),
        Effects.send(target_id, console("Has sido resucitado!")),
        update_mana_effect(char_id, entity),
        Effects.broadcast_character_change(revived)
      ]

      {state, effects}
    else
      # No dead player at target -- just update caster mana
      players = Map.put(state.players, char_id, entity)

      {%{state | players: players},
       [
         update_mana_effect(char_id, entity),
         Effects.send(char_id, console("No hay un jugador muerto ahi.", 5))
       ]}
    end
  end

  def apply_spell_attribute_buff(state, char_id, entity, spell_def, attr, target_x, target_y) do
    target = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y), else: nil
    now = Clock.now_ms()

    target_id =
      case target do
        {:player, tid} -> tid
        _ -> char_id
      end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        {%{state | players: players}, []}

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

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
        {%{state | players: players}, [update_mana_effect(char_id, entity)]}
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
        {%{state | players: players}, []}

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

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)

        {%{state | players: players},
         [
           Effects.send(target_id, Encoder.encode({:update_mana, %{min_mana: target_entity.mana}})),
           update_mana_effect(char_id, entity)
         ]}
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
        {%{state | players: players}, []}

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

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)

        {%{state | players: players},
         [
           Effects.send(target_id, Encoder.encode({:update_stamina, %{min_sta: target_entity.stamina}})),
           update_mana_effect(char_id, entity)
         ]}
    end
  end

  # ------------------------------------------------------------------
  # Elemental combat helpers
  # ------------------------------------------------------------------

  # VB6: attackerElementMask = ObjData(WeaponObjIndex).ElementalTags OR InventorySlot.ElementalTags
  # Combines the weapon definition's base tags with per-instance enchantment tags.
  def attacker_weapon_elemental_tags(entity) do
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

  def apply_elemental_modifiers_for_weapon(damage, entity, npc_def) do
    attacker_tags = attacker_weapon_elemental_tags(entity)
    defender_tags = if npc_def, do: npc_def.elemental_tags, else: 0
    Arena.Combat.apply_elemental_modifiers(damage, attacker_tags, defender_tags)
  end

end
