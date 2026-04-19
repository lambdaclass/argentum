defmodule Arena.Map.NpcInteraction do
  @moduledoc "NPC interaction handlers (double-click, training, gambling, forgive, arena entry)."

  alias Arena.Map.{Helpers, Faction, Commerce}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_revividor 1
  @npc_type_entrenador 3
  @npc_type_banquero 4
  @npc_type_enlistador 5
  @npc_type_timbero 6
  @npc_type_resucitador_newbie 9
  @npc_type_arena_guard 10
  @npc_type_subastador 16
  @npc_type_quest 17
  @npc_type_entrega_pesca 20

  @skill_order [
    :magic, :stealing, :combat_tactics, :combat_weapons, :meditation,
    :short_weapons, :hiding, :survival, :trading, :combat_defense,
    :leadership, :ranged_weapons, :wrestling, :navigation, :riding,
    :resistance, :woodcutting, :fishing, :mining, :blacksmithing,
    :carpentry, :alchemy, :tailoring, :taming
  ]
  @crafting_skills [:woodcutting, :fishing, :mining, :blacksmithing, :carpentry, :alchemy, :tailoring, :taming]

  defp msg(state, char_id, message), do: Helpers.msg(state, char_id, message)
  defdelegate find_nearby_npc_of_type(state, entity, npc_types), to: Helpers

  @doc """
  Handle the eInformation packet (VB6: HandleInformation).

  VB6 behaviour: enlistador-specific flow — validates nearby enlistador NPC
  within range 4, checks player alive, then shows faction-specific duty messages.
  """
  def handle_information(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          case Helpers.find_nearby_npc_of_type(state, entity, [@npc_type_enlistador], 4) do
            {:ok, _npc, npc_def} ->
              npc_faction = npc_faccion_to_atom(npc_def.faccion)

              cond do
                npc_faction == :royal_army and entity.faction == :royal_army ->
                  msg(state, char_id, "Tu deber es luchar contra criminales, cada 100 criminales derrotados recibes recompensa")
                  {:noreply, state}

                npc_faction == :chaos_legion and entity.faction == :chaos_legion ->
                  msg(state, char_id, "Tu deber es sembrar caos y desesperacion, cada 100 ciudadanos derrotados recibes recompensa")
                  {:noreply, state}

                true ->
                  msg(state, char_id, "No perteneces a esta faccion!")
                  {:noreply, state}
              end

            :not_found ->
              {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  defp npc_faccion_to_atom(3), do: :royal_army
  defp npc_faccion_to_atom(2), do: :chaos_legion
  defp npc_faccion_to_atom(_), do: :none

  def handle_double_click(state, char_id, x, y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          {:noreply, state}
        else
          if abs(entity.x - x) <= 4 and abs(entity.y - y) <= 4 do
            case Helpers.get_occupancy(state.occupancy, x, y) do
              {:npc, instance_id} ->
                handle_npc_double_click(state, char_id, entity, instance_id)

              _ ->
                case Map.get(state.ground_items, {x, y}) do
                  %{item_id: item_id} ->
                    item_def = GameData.get_item(item_id)

                    if item_def != nil and item_def.forum_id > 0 do
                      Arena.Map.Social.handle_forum_open(state, char_id, item_def.forum_id)
                    else
                      {:noreply, state}
                    end

                  _ ->
                    {:noreply, state}
                end
            end
          else
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas demasiado lejos.", font_index: 0}})}
            )

            {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_npc_double_click(state, char_id, entity, instance_id) do
    case Map.get(state.npcs_live, instance_id) do
      nil ->
        {:noreply, state}

      npc ->
        npc_def = GameData.get_npc(npc.npc_id)

        if npc_def == nil do
          {:noreply, state}
        else
          entity = remember_selected_npc(entity, instance_id, npc_def.npc_type)
          state = %{state | players: Map.put(state.players, char_id, entity)}

          cond do
            npc_def.comercia ->
              case Commerce.open_npc_commerce(state, char_id, entity, npc) do
                {:reply, _result, new_state} -> {:noreply, new_state}
                other -> other
              end

            npc_def.npc_type in [@npc_type_revividor, @npc_type_resucitador_newbie] ->
              if entity.dead do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode(
                     {:console_msg,
                      %{message: "#{npc_def.name} dice: Puedo resucitarte. Usa el comando /resucitar.", font_index: 0}}
                   )}
                )
              else
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode(
                     {:console_msg,
                      %{message: "#{npc_def.name} dice: Puedo curarte. Usa el comando /curar.", font_index: 0}}
                   )}
                )
              end

              # VB6: clicking a priest also shows the player's prontuario
              show_prontuario(state, char_id, entity)

              {:noreply, state}

            npc_def.npc_type == @npc_type_enlistador ->
              Faction.handle_enlistador_click(state, char_id, entity, npc_def)

            npc_def.npc_type == @npc_type_banquero ->
              case Arena.Map.Bank.handle_open_bank(state, char_id, npc.x, npc.y) do
                {:reply, _result, new_state} -> {:noreply, new_state}
                _ -> {:noreply, state}
              end

            npc_def.npc_type == @npc_type_entrenador ->
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode(
                   {:console_msg,
                    %{message: "#{npc_def.name} dice: Puedo entrenarte. Usa el boton Entrenar.", font_index: 0}}
                 )}
              )

              {:noreply, state}

            npc_def.npc_type == @npc_type_entrega_pesca ->
              handle_fish_delivery(state, char_id, entity, npc_def)

            npc_def.npc_type == @npc_type_timbero ->
              msg(state, char_id, "#{npc_def.name} dice: Haz tu apuesta con /APOSTAR cantidad (1-5000 monedas).")
              {:noreply, state}

            npc_def.npc_type == @npc_type_arena_guard ->
              fee = Map.get(npc_def, :arena_price, 0)

              if fee > 0 do
                msg(state, char_id, "#{npc_def.name} dice: La entrada a la arena cuesta #{fee} monedas de oro.")
              else
                msg(state, char_id, "#{npc_def.name} dice: Bienvenido a la arena.")
              end

              {:noreply, state}

            npc_def.npc_type == @npc_type_subastador ->
              handle_subastador_click(state, char_id, entity, npc_def)

            npc_def.npc_type == @npc_type_quest ->
              handle_quest_npc_click(state, char_id, entity, instance_id, npc_def)

            true ->
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "Ves a #{npc_def.name}.", font_index: 0}})}
              )

              {:noreply, state}
          end
        end
    end
  end

  defp remember_selected_npc(entity, instance_id, npc_type) do
    entity
    |> Map.put(:last_clicked_npc_instance_id, instance_id)
    |> Map.put(:last_clicked_npc_type, npc_type)
  end

  def handle_train_skill(state, char_id, skill_index) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        skill_atom = Enum.at(@skill_order, skill_index)
        trainer_result = find_nearby_npc_of_type(state, entity, [@npc_type_entrenador])
        near_trainer = trainer_result != :not_found

        trainer_npc_def =
          case trainer_result do
            {:ok, _npc, npc_def} -> npc_def
            :not_found -> nil
          end

        cond do
          skill_atom == nil ->
            {:noreply, state}

          near_trainer and not trainer_accepts_skill?(trainer_npc_def, skill_atom) ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "Este entrenador no enseña esa habilidad.", font_index: 0}})}
            )

            {:noreply, state}

          near_trainer and entity.skill_points <= 0 ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "No tienes puntos de skill disponibles.", font_index: 0}})}
            )

            {:noreply, state}

          near_trainer and Map.get(entity.skills, skill_atom, 0) >= 100 ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "Ya tienes el maximo en esa habilidad.", font_index: 0}})}
            )

            {:noreply, state}

          near_trainer ->
            current = Map.get(entity.skills, skill_atom, 0)
            cost = max(current * 10, 10)

            if entity.gold < cost do
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode({:console_msg, %{message: "No tienes suficiente oro. Costo: #{cost}", font_index: 0}})}
              )

              {:noreply, state}
            else
              entity = %{
                entity
                | skills: Map.put(entity.skills, skill_atom, current + 1),
                  skill_points: entity.skill_points - 1,
                  gold: entity.gold - cost
              }

              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})}
              )

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
              )

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode(
                   {:console_msg,
                    %{
                      message: "Has entrenado! Costo: #{cost} oro. Skill points restantes: #{entity.skill_points}",
                      font_index: 0
                    }}
                 )}
              )

              {:noreply, state}
            end

          skill_atom in @crafting_skills ->
            Arena.Map.Crafting.handle_work(state, char_id, skill_atom)

          true ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un entrenador cerca.", font_index: 0}})}
            )

            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp trainer_accepts_skill?(_npc_def, _skill_atom), do: true

  def handle_train_list(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        trainer =
          Enum.find_value(state.npcs_live, fn {_id, npc} ->
            npc_def = GameData.get_npc(npc.npc_id)

            if npc_def != nil and
                 npc_def.npc_type == @npc_type_entrenador and
                 abs(npc.x - entity.x) <= 10 and
                 abs(npc.y - entity.y) <= 10 do
              npc_def
            end
          end)

        if trainer != nil and trainer.creatures != [] do
          raw =
            Encoder.encode({:trainer_creature_list, %{creature_names: trainer.creatures}})

          Helpers.send_to_session(state.sessions, char_id, {:send_raw, raw})
        else
          msg(state, char_id, "No hay criaturas disponibles para entrenar.")
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_gamble(state, char_id, amount, _npc_instance_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            msg(state, char_id, "Estas muerto!")
            {:noreply, state}

          amount <= 0 ->
            msg(state, char_id, "La apuesta debe ser mayor a 0.")
            {:noreply, state}

          amount > 5000 ->
            msg(state, char_id, "La apuesta maxima es 5000.")
            {:noreply, state}

          entity.gold < amount ->
            msg(state, char_id, "No tienes suficiente oro.")
            {:noreply, state}

          true ->
            case find_nearby_npc_of_type(state, entity, [@npc_type_timbero]) do
              :not_found ->
                msg(state, char_id, "No hay un timbero cerca.")
                {:noreply, state}

              {:ok, _npc, npc_def} ->
                # VB6 parity: RandomNumber(1, 100) <= 10 → 10% win rate
                won = :rand.uniform(100) <= 10

                entity =
                  if won do
                    %{entity |
                      gold: entity.gold + amount,
                      gamble_wins: entity.gamble_wins + 1,
                      gamble_plays: entity.gamble_plays + 1}
                  else
                    %{entity |
                      gold: entity.gold - amount,
                      gamble_losses: entity.gamble_losses + 1,
                      gamble_plays: entity.gamble_plays + 1}
                  end

                players = Map.put(state.players, char_id, entity)
                state = %{state | players: players}

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
                )

                if won do
                  msg(state, char_id, "#{npc_def.name} te dice: Has ganado #{amount} monedas de oro!")
                else
                  msg(state, char_id, "#{npc_def.name} te dice: Has perdido #{amount} monedas de oro.")
                end

                {:noreply, state}
            end
        end

      :error ->
        {:noreply, state}
    end
  end

  # VB6 parity constants for /PERDON (HandleDonateGold + HandleForgive)
  # CostoPerdonPorCiudadano = 5000, GoldMult = 1 (from Example.Configuracion.ini)
  @costo_perdon_por_ciudadano 5000
  @gold_mult 1
  # VB6: priest range check uses Distancia > 3
  @forgive_max_range 3

  def handle_forgive(state, char_id, gold_amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            msg(state, char_id, "Estas muerto!")
            {:noreply, state}

          not entity.criminal ->
            msg(state, char_id, "No eres un criminal.")
            {:noreply, state}

          # VB6: faction members (armada/caos) cannot use /PERDON
          entity.faction == :royal_army or entity.faction == :chaos_legion ->
            msg(state, char_id, "No puedo aceptar tu donacion en este momento.")
            {:noreply, state}

          true ->
            case find_nearby_priest(state, entity) do
              :not_found ->
                msg(state, char_id, "Necesitas estar cerca de un sacerdote.")
                {:noreply, state}

              {:ok, _npc, _npc_def} ->
                # VB6: donation threshold based on ciudadanosMatados
                required_donation =
                  if entity.citizens_killed > 0 do
                    entity.citizens_killed * @gold_mult * @costo_perdon_por_ciudadano
                  else
                    div(@costo_perdon_por_ciudadano, 2)
                  end

                cond do
                  entity.gold < gold_amount ->
                    msg(state, char_id, "No tienes suficiente dinero.")
                    {:noreply, state}

                  gold_amount < required_donation ->
                    msg(state, char_id, "Dios no puede perdonarte si eres una persona avara.")
                    {:noreply, state}

                  true ->
                    entity = %{entity | criminal: false, gold: entity.gold - gold_amount}
                    players = Map.put(state.players, char_id, entity)
                    state = %{state | players: players}

                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
                    )

                    msg(state, char_id, "Has sido perdonado.")
                    {:noreply, state}
                end
            end
        end

      :error ->
        {:noreply, state}
    end
  end

  # Find a priest within VB6 range (distance <= 3)
  defp find_nearby_priest(state, entity) do
    result =
      Enum.find_value(state.npcs_live, fn {_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)

        if npc_def != nil and
             npc_def.npc_type in [@npc_type_revividor, @npc_type_resucitador_newbie] and
             abs(npc.x - entity.x) <= @forgive_max_range and
             abs(npc.y - entity.y) <= @forgive_max_range do
          {npc, npc_def}
        end
      end)

    case result do
      {npc, npc_def} -> {:ok, npc, npc_def}
      nil -> :not_found
    end
  end

  def handle_arena_entry(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        guard =
          Enum.find_value(state.npcs_live, fn {_id, npc} ->
            npc_def = GameData.get_npc(npc.npc_id)

            if npc_def != nil and
                 npc_def.npc_type == @npc_type_arena_guard and
                 npc_def.arena_enabled and
                 abs(npc.x - entity.x) <= 10 and
                 abs(npc.y - entity.y) <= 10 do
              npc_def
            end
          end)

        cond do
          guard == nil ->
            msg(state, char_id, "No hay un guardia de arena cerca.")
            {:noreply, state}

          entity.dead ->
            msg(state, char_id, "Estas muerto!")
            {:noreply, state}

          entity.gold < guard.map_entry_price ->
            msg(state, char_id, "Necesitas #{guard.map_entry_price} monedas de oro para entrar.")
            {:noreply, state}

          true ->
            entity = %{entity | gold: entity.gold - guard.map_entry_price}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
            )

            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:transfer, guard.map_target_entry, guard.map_target_entry_x, guard.map_target_entry_y, entity}
            )

            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp handle_fish_delivery(state, char_id, entity, npc_def) do
    if entity.class != :trabajador do
      msg(state, char_id, "#{npc_def.name} dice: Solo los trabajadores pueden entregar peces.")
      {:noreply, state}
    else
      {total_points, total_gold, slots_to_clear} =
        entity.inventory
        |> Enum.with_index()
        |> Enum.reduce({0, 0, []}, fn {item, idx}, {pts, gold, slots} ->
          case item do
            %{item_id: item_id, amount: amount} when amount > 0 ->
              item_def = GameData.get_item(item_id)

              if item_def != nil and item_def.puntos_pesca > 0 do
                {pts + item_def.puntos_pesca * amount, gold + item_def.valor * amount, [idx | slots]}
              else
                {pts, gold, slots}
              end

            _ ->
              {pts, gold, slots}
          end
        end)

      if total_points == 0 do
        msg(state, char_id, "#{npc_def.name} dice: No tienes peces especiales para entregar.")
        {:noreply, state}
      else
        new_inv =
          Enum.reduce(slots_to_clear, entity.inventory, fn idx, inv ->
            List.replace_at(inv, idx, nil)
          end)

        entity = %{
          entity
          | inventory: new_inv,
            fishing_points: entity.fishing_points + total_points,
            gold: entity.gold + total_gold
        }

        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        Enum.each(slots_to_clear, fn slot ->
          Helpers.send_inventory_slot(state.sessions, char_id, entity.inventory, slot)
        end)

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
        )

        msg(state, char_id, "Has entregado peces. Puntos: +#{total_points}, Oro: +#{total_gold}.")
        {:noreply, state}
      end
    end
  end

  defp handle_subastador_click(state, char_id, entity, npc_def) do
    tile_key = {entity.x, entity.y}
    item_on_ground = Map.get(state.ground_items || %{}, tile_key)

    case Arena.Auction.initiate(char_id, item_on_ground) do
      :ok ->
        new_ground = Map.delete(state.ground_items || %{}, tile_key)
        state = %{state | ground_items: new_ground}

        Helpers.broadcast_object_delete(state, entity.x, entity.y)

        msg(
          state,
          char_id,
          "#{npc_def.name} dice: Escribe /OFERTAINICIAL (cantidad) para comenzar la subasta. Tienes 15 segundos!"
        )

        {:noreply, state}

      {:error, :auction_in_progress} ->
        msg(
          state,
          char_id,
          "#{npc_def.name} dice: Oye amigo, espera tu turno, estoy subastando en este momento."
        )

        {:noreply, state}

      {:error, :already_initiating} ->
        msg(
          state,
          char_id,
          "#{npc_def.name} dice: Ya estas preparando una subasta. Escribe /OFERTAINICIAL (cantidad)."
        )

        {:noreply, state}

      {:error, :no_item} ->
        msg(
          state,
          char_id,
          "#{npc_def.name} dice: Pues acaso el aire esta en venta ahora? Bribon!"
        )

        {:noreply, state}
    end
  end

  defp handle_quest_npc_click(state, char_id, entity, _instance_id, npc_def) do
    quest_ids_set = MapSet.new(npc_def.quest_numbers)

    completable =
      entity.active_quests
      |> Enum.with_index()
      |> Enum.filter(fn {aq, idx} ->
        MapSet.member?(quest_ids_set, aq.quest_id) and
          Arena.QuestServer.quest_complete?(entity, idx)
      end)

    if completable != [] do
      {aq, slot} = hd(completable)
      quest_def = Arena.Data.GameData.get_quest(aq.quest_id)
      updated_entity = Arena.QuestServer.complete_quest(entity, slot)

      if updated_entity != entity and quest_def != nil do
        if quest_def.desc_final != "" do
          msg(state, char_id, npc_def.name <> " dice: " <> quest_def.desc_final)
        end

        if quest_def.reward_gld > 0 do
          msg(state, char_id, "Recibiste #{quest_def.reward_gld} monedas de oro.")
          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:update_gold, %{gold: updated_entity.gold}})})
        end

        if quest_def.reward_exp > 0 do
          msg(state, char_id, "Recibiste #{quest_def.reward_exp} puntos de experiencia.")
        end

        state = put_in(state.players[char_id], updated_entity)
        {:noreply, state}
      else
        msg(state, char_id, "No se pudo completar la mision.")
        {:noreply, state}
      end
    else
      available = Arena.QuestServer.available_quests_for_npc(entity, npc_def)

      if available == [] do
        msg(state, char_id, npc_def.name <> " dice: No tengo misiones disponibles para ti.")
        {:noreply, state}
      else
        npc_quest_params = Arena.QuestServer.build_npc_quest_list(available)

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:npc_quest_list_send, %{quests: npc_quest_params}})}
        )

        entity = %{entity | quest_npc_id: npc_def.id}
        state = put_in(state.players[char_id], entity)
        {:noreply, state}
      end
    end
  end

  # VB6: clicking a priest NPC shows the player's prontuario (punishment record)
  defp show_prontuario(state, char_id, entity) do
    punishments = Map.get(entity, :punishments, [])
    text = Arena.Map.Gm.Moderation.format_punishments(punishments)

    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:console_msg, %{message: text, font_index: 0}})}
    )
  end
end
