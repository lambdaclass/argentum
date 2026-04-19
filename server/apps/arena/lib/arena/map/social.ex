defmodule Arena.Map.Social do
  @moduledoc "Chat, social commands, stat requests, and NPC interaction."

  alias Arena.Map.{Helpers, Visibility}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_revividor 1
  @npc_type_banquero 4
  @npc_type_enlistador 5
  @npc_type_timbero 6

  # ==================================================================
  # Safe toggle
  # ==================================================================

  def handle_safe_toggle(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        new_safe = not entity.safe_mode
        entity = %{entity | safe_mode: new_safe}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        packet = if new_safe, do: {:safe_mode_on, %{}}, else: {:safe_mode_off, %{}}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode(packet)})

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  # ==================================================================
  # Stat requests
  # ==================================================================

  def handle_request_atributes(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(
          state.sessions,
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
                class: Helpers.class_to_int(entity.class)
              }}
           )}
        )

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw,
           Encoder.encode(
             {:send_atributes,
              %{
                str: entity.str,
                agi: entity.agi,
                int: entity.int,
                con: entity.con,
                cha: entity.cha
              }}
           )}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_request_skills(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end


  def handle_request_mini_stats(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(
          state.sessions,
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
                class: Helpers.class_to_int(entity.class)
              }}
           )}
        )

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw,
           Encoder.encode(
             {:mini_stats,
              %{
                ciudadanos_matados: entity.citizens_killed,
                criminales_matados: entity.criminals_killed,
                faction_status:
                  case Map.get(entity, :faction, :none) do
                    :royal_army -> 1
                    :chaos_legion -> 2
                    :none -> if entity.criminal, do: 3, else: 0
                  end,
                npcs_killed: entity.npcs_killed,
                class: Helpers.class_to_int(entity.class),
                penalty: entity.penalty,
                deaths: entity.deaths,
                gender: if(entity.gender == :male, do: 1, else: 2),
                fishing_points: entity.fishing_points,
                race: Helpers.race_to_int(entity.race)
              }}
           )}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Double-click / NPC interaction
  # ==================================================================

  # Double-click and NPC interaction delegated to Arena.Map.NpcInteraction
  # Faction system delegated to Arena.Map.Faction

  # Faction functions removed — see Arena.Map.Faction

  defp msg(state, char_id, message), do: Helpers.msg(state, char_id, message)

  defdelegate find_nearby_npc_of_type(state, entity, npc_types), to: Helpers

  # Pet commands delegated to Arena.Map.Pets

  # ==================================================================
  # Move spell (VB6: reorder spell slots)
  # ==================================================================

  def handle_move_spell(state, char_id, upwards, slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        spells = entity.spells || []
        # Convert 1-based slot to 0-based index
        idx = slot - 1
        swap_idx = if upwards, do: idx - 1, else: idx + 1

        if idx >= 0 and idx < length(spells) and swap_idx >= 0 and swap_idx < length(spells) do
          a = Enum.at(spells, idx)
          b = Enum.at(spells, swap_idx)
          spells = spells |> List.replace_at(idx, b) |> List.replace_at(swap_idx, a)
          spell_cooldowns = swap_spell_cooldowns(entity.spell_cooldowns, idx + 1, swap_idx + 1)
          entity = %{entity | spells: spells, spell_cooldowns: spell_cooldowns}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          # Send updated spell slots to client
          send_spell_slot(state.sessions, char_id, spells, idx)
          send_spell_slot(state.sessions, char_id, spells, swap_idx)
          {:noreply, state}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp send_spell_slot(sessions, char_id, spells, idx) do
    spell_id = Enum.at(spells, idx) || 0
    packet = Encoder.encode({:change_spell_slot, %{slot: idx + 1, spell_id: spell_id}})
    Helpers.send_to_session(sessions, char_id, {:send_raw, packet})
  end

  defp swap_spell_cooldowns(cooldowns, slot_a, slot_b) do
    cooldown_a = Map.get(cooldowns, slot_a)
    cooldown_b = Map.get(cooldowns, slot_b)

    cooldowns
    |> put_or_delete_cooldown(slot_a, cooldown_b)
    |> put_or_delete_cooldown(slot_b, cooldown_a)
  end

  defp put_or_delete_cooldown(cooldowns, slot, nil), do: Map.delete(cooldowns, slot)
  defp put_or_delete_cooldown(cooldowns, slot, value), do: Map.put(cooldowns, slot, value)

  # ==================================================================
  # Modify skills (VB6: distribute skill points from stats screen)
  # ==================================================================

  @skill_order [
    :magic,
    :stealing,
    :combat_tactics,
    :combat_weapons,
    :meditation,
    :short_weapons,
    :hiding,
    :survival,
    :trading,
    :combat_defense,
    :leadership,
    :ranged_weapons,
    :wrestling,
    :navigation,
    :riding,
    :resistance,
    :woodcutting,
    :fishing,
    :mining,
    :blacksmithing,
    :carpentry,
    :alchemy,
    :tailoring,
    :taming
  ]

  def handle_modify_skills(state, char_id, points_list) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          # Reject any negative values in the list
          if Enum.any?(points_list, &(&1 < 0)) do
            msg(state, char_id, "Valores invalidos.")
            {:noreply, state}
          else
            # Sum requested points — must not exceed available skill_points
            total_requested = Enum.sum(points_list)

            if total_requested <= 0 or total_requested > entity.skill_points do
              msg(state, char_id, "No tienes suficientes puntos de habilidad.")
              {:noreply, state}
            else
              # Apply points to skills, capping each at 100
              {new_skills, points_used} =
                @skill_order
                |> Enum.zip(points_list)
                |> Enum.reduce({entity.skills, 0}, fn {skill_atom, pts}, {skills, used} ->
                  if pts > 0 do
                    current = Map.get(skills, skill_atom, 0)
                    add = min(pts, 100 - current)

                    if add > 0 do
                      {Map.put(skills, skill_atom, current + add), used + add}
                    else
                      {skills, used}
                    end
                  else
                    {skills, used}
                  end
                end)

              entity = %{entity | skills: new_skills, skill_points: entity.skill_points - points_used}
              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              # Send updated skills back
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})}
              )

              {:noreply, state}
            end
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Change description
  # ==================================================================

  @max_description_length 200

  def handle_change_description(state, char_id, desc) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        msg(state, char_id, "Estas muerto.")
        {:noreply, state}

      {:ok, entity} ->
        desc = String.slice(desc, 0, @max_description_length)
        entity = %{entity | description: desc}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}
        msg(state, char_id, "Descripcion cambiada.")
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Spell info (VB6: show spell details for a slot)
  # ==================================================================

  def handle_spell_info(state, char_id, slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        idx = slot - 1
        spell_id = Enum.at(entity.spells || [], idx)

        if spell_id && spell_id > 0 do
          case GameData.get_spell(spell_id) do
            nil ->
              msg(state, char_id, "Hechizo no encontrado.")

            spell_def ->
              info = "#{spell_def.name} - Mana: #{spell_def.mana_required}"

              info =
                if spell_def.min_hp && spell_def.min_hp > 0,
                  do: info <> " - Daño: #{spell_def.min_hp}-#{spell_def.max_hp}",
                  else: info

              msg(state, char_id, info)
          end
        else
          msg(state, char_id, "No hay hechizo en ese slot.")
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Move item (swap inventory slots)
  # ==================================================================

  def handle_move_item(state, char_id, from_slot, to_slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        inv = entity.inventory || []
        from_idx = from_slot - 1
        to_idx = to_slot - 1

        if from_idx >= 0 and from_idx < length(inv) and to_idx >= 0 and to_idx < length(inv) do
          a = Enum.at(inv, from_idx)
          b = Enum.at(inv, to_idx)
          inv = inv |> List.replace_at(from_idx, b) |> List.replace_at(to_idx, a)
          entity = %{entity | inventory: inv}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          # Send updated slots
          Helpers.send_inventory_slot(state.sessions, char_id, inv, from_idx)
          Helpers.send_inventory_slot(state.sessions, char_id, inv, to_idx)
          {:noreply, state}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Modify gold (add or subtract)
  # ==================================================================

  def handle_modify_gold(state, char_id, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:noreply, state}

      {:ok, entity} ->
        new_gold = max(entity.gold + amount, 0)
        entity = %{entity | gold: new_gold}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:update_gold, %{gold: new_gold}})})
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @doc """
  Atomically deduct gold from a player, returning {:reply, {:ok, new_gold}, state}
  or {:reply, {:error, reason}, state}. Used by transfer_gold/donate_gold to avoid
  TOCTOU races where snapshot_entity reads gold then async modify fires later.
  """
  def handle_deduct_gold(state, char_id, amount) when amount > 0 do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:reply, {:error, :dead}, state}

      {:ok, entity} when entity.gold >= amount ->
        new_gold = entity.gold - amount
        entity = %{entity | gold: new_gold}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:update_gold, %{gold: new_gold}})})
        {:reply, {:ok, new_gold}, state}

      {:ok, _entity} ->
        {:reply, {:error, :not_enough_gold}, state}

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_deduct_gold(state, _char_id, _amount) do
    {:reply, {:error, :invalid_amount}, state}
  end

  # ==================================================================
  # Marriage system (VB6: HandleCasamiento)
  # ==================================================================

  @doc """
  Handle a marriage proposal.

  VB6 flow (Protocol.bas HandleCasamiento):
  1. Target must be online (on same map)
  2. Proposer must have clicked a priest NPC (Revividor, type 1)
  3. Priest must be within 10 tiles
  4. Cannot marry yourself
  5. Proposer must not already be married
  6. Target must not already be married
  7. If target already proposed to proposer (mutual), marry them
  8. Otherwise, set proposer's candidato = target, notify target
  """
  def handle_propose_marriage(state, char_id, target_char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case Map.fetch(state.players, target_char_id) do
          {:ok, target_entity} ->
            do_propose_marriage(state, char_id, entity, target_char_id, target_entity)

          :error ->
            msg(state, char_id, "El jugador no se encuentra en este mapa.")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp do_propose_marriage(state, char_id, entity, target_char_id, target_entity) do
    priest_result = find_nearby_npc_of_type(state, entity, [@npc_type_revividor])

    cond do
      # Must be near a priest
      priest_result == :not_found ->
        msg(state, char_id, "Primero haz click sobre un sacerdote.")
        {:noreply, state}

      # Priest too far (find_nearby_npc_of_type already checks distance <= 5)
      # If we got here, priest is nearby. Check other conditions.

      # Cannot marry yourself
      char_id == target_char_id ->
        msg(state, char_id, "No puedes casarte contigo mismo.")
        {:noreply, state}

      # Proposer already married
      entity.spouse_id != 0 and entity.spouse_id != nil ->
        msg(state, char_id, "Ya estas casado! Debes divorciarte de tu actual pareja para casarte nuevamente.")
        {:noreply, state}

      # Target already married
      target_entity.spouse_id != 0 and target_entity.spouse_id != nil ->
        msg(state, char_id, "Tu pareja debe divorciarse antes de tomar tu mano en matrimonio.")
        {:noreply, state}

      # Mutual proposal: target already proposed to us -> marry!
      target_entity.marriage_proposal_target == char_id ->
        {:ok, _npc, _npc_def} = priest_result

        # Set both as married
        entity = %{entity | spouse_id: target_entity.char_id, marriage_proposal_target: nil}
        target_entity = %{target_entity | spouse_id: entity.char_id, marriage_proposal_target: nil}

        players =
          state.players
          |> Map.put(char_id, entity)
          |> Map.put(target_char_id, target_entity)

        state = %{state | players: players}

        # Broadcast marriage announcement (VB6: SendData ToAll)
        announce = "El sacerdote celebra el casamiento entre #{entity.name} y #{target_entity.name}."

        Visibility.broadcast_to_map(state, fn pid ->
          send(pid, {:send_packet, {:console_msg, %{message: announce, font_index: 0}}})
        end)

        # Congratulations to both (VB6: Msg1414/1415)
        congrats = "Los declaro unidos en legal matrimonio. Felicidades!"
        msg(state, char_id, congrats)
        msg(state, target_char_id, congrats)

        {:noreply, state}

      # First proposal: set candidato, notify target
      true ->
        entity = %{entity | marriage_proposal_target: target_char_id}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        msg(state, char_id, "La solicitud de casamiento ha sido enviada a #{target_entity.name}.")

        # VB6: Msg1956
        msg(
          state,
          target_char_id,
          "#{entity.name} desea casarse contigo, para permitirlo haz click en el sacerdote y escribe /PROPONER #{entity.name}."
        )

        {:noreply, state}
    end
  end

  @doc """
  Handle divorce.

  VB6 uses a special potion, but we also support a /DIVORCIAR command.
  Both players must be on the same map. Sets spouse_id = 0 on both.
  """
  # ==================================================================
  # Ocultarse (hiding skill) — task 26b
  # ==================================================================

  def handle_ocultarse(state, char_id, skill_level) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            msg(state, char_id, "Estas muerto!")
            {:noreply, state}

          entity.oculto ->
            msg(state, char_id, "Ya estas oculto.")
            {:noreply, state}

          skill_level < 1 ->
            msg(state, char_id, "No tienes habilidad suficiente para ocultarte.")
            {:noreply, state}

          true ->
            # VB6: success roll — random(1..100) <= hiding skill
            if :rand.uniform(100) <= skill_level do
              # VB6: hide timer = skill_level / 2 regen ticks
              timer = max(div(skill_level, 2), 1)
              entity = %{entity | oculto: true, oculto_timer: timer, invisible: true}
              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              Arena.Map.Visibility.hide_from_non_gm(state, entity)
              msg(state, char_id, "Te has ocultado entre las sombras.")
              {:noreply, state}
            else
              msg(state, char_id, "No has logrado ocultarte.")
              {:noreply, state}
            end
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Forum (double-click on forum object) — task 44
  # ==================================================================

  def handle_forum_open(state, char_id, forum_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, _entity} ->
        messages = Arena.Forum.get_messages(forum_id)

        raw =
          Encoder.encode(
            {:show_forum_form,
             %{
               forum_id: forum_id,
               messages: messages
             }}
          )

        Helpers.send_to_session(state.sessions, char_id, {:send_raw, raw})

        # Tell the session handler which forum is open
        Helpers.send_to_session(state.sessions, char_id, {:set_viewing_forum, forum_id})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_divorce(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.spouse_id == 0 or entity.spouse_id == nil do
          msg(state, char_id, "No estas casado.")
          {:noreply, state}
        else
          spouse_id = entity.spouse_id

          entity = %{entity | spouse_id: 0, marriage_proposal_target: nil}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          # Try to update spouse if on same map
          case Map.fetch(state.players, spouse_id) do
            {:ok, spouse_entity} ->
              spouse_entity = %{spouse_entity | spouse_id: 0, marriage_proposal_target: nil}
              players = Map.put(state.players, spouse_id, spouse_entity)
              state = %{state | players: players}

              msg(state, char_id, "Te has divorciado.")
              msg(state, spouse_id, "#{entity.name} se ha divorciado de ti.")

              {:noreply, state}

            :error ->
              # Spouse offline or on another map -- only clear our side
              msg(state, char_id, "Te has divorciado.")
              {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  defp selected_npc(state, entity) do
    case Map.get(entity, :last_clicked_npc_instance_id) do
      nil ->
        {:error, :no_selection}

      instance_id ->
        case Map.get(state.npcs_live, instance_id) do
          nil ->
            {:error, :stale_selection}

          npc ->
            case GameData.get_npc(npc.npc_id) do
              nil -> {:error, :stale_selection}
              npc_def -> {:ok, npc, npc_def}
            end
        end
    end
  end

  defp within_selected_npc_range?(entity, npc, max_distance) do
    abs(entity.x - npc.x) <= max_distance and abs(entity.y - npc.y) <= max_distance
  end

  # ==================================================================
  # Account state — VB6: HandleRequestAccountState
  # Banker shows bank gold, Timbero shows gambling stats.
  # ==================================================================

  def handle_request_account_state(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        msg(state, char_id, "No puedes hacer eso estando muerto.")
        {:noreply, state}

      {:ok, entity} ->
        case selected_npc(state, entity) do
          {:ok, npc, npc_def} ->
            cond do
              npc_def.npc_type == @npc_type_banquero and within_selected_npc_range?(entity, npc, 3) ->
                bank_gold = Map.get(entity, :bank_gold, 0)
                msg(state, char_id, "Tenes #{bank_gold} monedas de oro en tu cuenta.")
                {:noreply, state}

              npc_def.npc_type == @npc_type_timbero and within_selected_npc_range?(entity, npc, 3) ->
                # VB6: HandleRequestAccountState shows three separate gambling counters
                wins = Map.get(entity, :gamble_wins, 0)
                losses = Map.get(entity, :gamble_losses, 0)
                plays = Map.get(entity, :gamble_plays, 0)
                msg(state, char_id, "Apuestas ganadas: #{wins}")
                msg(state, char_id, "Apuestas perdidas: #{losses}")
                msg(state, char_id, "Veces jugadas: #{plays}")
                {:noreply, state}

              npc_def.npc_type in [@npc_type_banquero, @npc_type_timbero] ->
                msg(state, char_id, "Estas demasiado lejos.")
                {:noreply, state}

              true ->
                msg(state, char_id, "Primero debes seleccionar un personaje, haz click izquierdo sobre el.")
                {:noreply, state}
            end

          {:error, :stale_selection} ->
            msg(state, char_id, "Primero debes seleccionar un personaje, haz click izquierdo sobre el.")
            {:noreply, state}

          {:error, :no_selection} ->
            msg(state, char_id, "Primero debes seleccionar un personaje, haz click izquierdo sobre el.")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Reward — VB6: HandleReward requires targeting enlistador NPC
  # ==================================================================

  def handle_request_reward(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        msg(state, char_id, "No puedes hacer eso estando muerto.")
        {:noreply, state}

      {:ok, entity} ->
        case selected_npc(state, entity) do
          {:ok, npc, npc_def} ->
            cond do
              npc_def.npc_type != @npc_type_enlistador ->
                msg(state, char_id, "Primero debes seleccionar un personaje, haz click izquierdo sobre el.")
                {:noreply, state}

              not within_selected_npc_range?(entity, npc, 4) ->
                msg(state, char_id, "Estas demasiado lejos.")
                {:noreply, state}

              entity.faction == :none ->
                msg(state, char_id, "No perteneces a ninguna faccion.")
                {:noreply, state}

              true ->
                # VB6: HandleReward — check faction_score & level vs rank
                # requirements, then award rank-up + items for any newly-
                # qualified rank.
                do_reward_npc(state, char_id, entity)
            end

          {:error, :stale_selection} ->
            msg(state, char_id, "Primero debes seleccionar un personaje, haz click izquierdo sobre el.")
            {:noreply, state}

          {:error, :no_selection} ->
            msg(state, char_id, "Primero debes seleccionar un personaje, haz click izquierdo sobre el.")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end


  # ── /REWARD NPC rank-check + reward granting ──────────────────────────

  defp do_reward_npc(state, char_id, entity) do
    faction = entity.faction
    current_rank = current_faction_rank(entity, faction)
    ranks = GameData.faction_ranks(faction)
    next_rank_def = Enum.find(ranks, fn r -> r.rank == current_rank + 1 end)

    cond do
      next_rank_def == nil ->
        msg(state, char_id, "Ya tienes el rango maximo.")
        {:noreply, state}

      entity.level < next_rank_def.required_level ->
        needed = next_rank_def.required_level - entity.level
        msg(state, char_id, "Te faltan #{needed} niveles para poder recibir la proxima recompensa.")
        {:noreply, state}

      entity.faction_score < next_rank_def.required_score ->
        needed = next_rank_def.required_score - entity.faction_score
        msg(state, char_id, "Te faltan #{needed} puntos de faccion para subir de rango.")
        {:noreply, state}

      true ->
        new_rank = next_rank_def.rank
        entity = assign_faction_rank(entity, faction, new_rank)
        {entity, state} = give_reward_items(entity, state, char_id, faction, current_rank, new_rank)
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        msg(state, char_id, "Has ascendido al rango #{new_rank}: #{next_rank_def.title}!")
        {:noreply, state}
    end
  end

  defp current_faction_rank(entity, :royal_army), do: entity.faction_rank_armada
  defp current_faction_rank(entity, :chaos_legion), do: entity.faction_rank_chaos

  defp assign_faction_rank(entity, :royal_army, rank), do: %{entity | faction_rank_armada: rank}
  defp assign_faction_rank(entity, :chaos_legion, rank), do: %{entity | faction_rank_chaos: rank}

  defp give_reward_items(entity, state, char_id, faction, old_rank, new_rank) do
    rewards = GameData.faction_rewards(faction)

    rewards_to_give =
      Enum.filter(rewards, fn r -> r.rank > old_rank and r.rank <= new_rank end)

    Enum.reduce(rewards_to_give, {entity, state}, fn reward, {ent, st} ->
      item_def = GameData.get_item(reward.obj_index)

      if item_def == nil do
        {ent, st}
      else
        case Arena.Inventory.add_item(ent.inventory, reward.obj_index, 1) do
          {:ok, new_inv, slot} ->
            ent = %{ent | inventory: new_inv}
            Helpers.send_inventory_slot(st.sessions, char_id, new_inv, slot)
            msg(st, char_id, "Has recibido #{item_def.name}.")
            {ent, st}

          _ ->
            msg(st, char_id, "No tienes espacio para #{item_def.name}.")
            {ent, st}
        end
      end
    end)
  end

  # Quest handlers delegated to Arena.Map.QuestHandlers
end
