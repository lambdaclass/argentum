defmodule Arena.Map.NpcInteraction do
  @moduledoc "NPC interaction handlers (double-click, gambling, forgive, arena entry)."

  alias Arena.Map.{Helpers, Faction, Commerce, Effects}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_revividor 1
  @npc_type_entrenador 3
  @npc_type_banquero 4
  @npc_type_enlistador 5
  # Shipped data: Apostador (NPC301) is NpcType=10, not VB6 enum Timbero=7
  @npc_type_timbero 10
  @npc_type_resucitador_newbie 9
  # VB6: ArenaGuard=24. No arena guard NPCs exist in shipped data yet.
  @npc_type_arena_guard 24
  @npc_type_subastador 16
  @npc_type_quest 17
  @npc_type_entrega_pesca 20

  @doc """
  Handle the eInformation packet (VB6: HandleInformation).

  VB6 behaviour: enlistador-specific flow — validates nearby enlistador NPC
  within range 4, checks player alive, then shows faction-specific duty messages.
  """
  def handle_information(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          {:ok, state, [Effects.send(char_id, console("Estas muerto!"))]}
        else
          case Helpers.resolve_nearby_npc(state, entity, [@npc_type_enlistador], 4) do
            {:ok, _npc, npc_def} ->
              npc_faction = npc_faccion_to_atom(npc_def.faccion)

              cond do
                npc_faction == :royal_army and entity.faction == :royal_army ->
                  {:ok, state,
                   [
                     Effects.send(
                       char_id,
                       console(
                         "Tu deber es luchar contra criminales, cada 100 criminales derrotados recibes recompensa"
                       )
                     )
                   ]}

                npc_faction == :chaos_legion and entity.faction == :chaos_legion ->
                  {:ok, state,
                   [
                     Effects.send(
                       char_id,
                       console(
                         "Tu deber es sembrar caos y desesperacion, cada 100 ciudadanos derrotados recibes recompensa"
                       )
                     )
                   ]}

                true ->
                  {:ok, state, [Effects.send(char_id, console("No perteneces a esta faccion!"))]}
              end

            :not_found ->
              {:ok, state, []}
          end
        end

      :error ->
        {:ok, state, []}
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
                      Effects.run_handler(state, fn s ->
                        Arena.Map.Social.handle_forum_open(s, char_id, item_def.forum_id)
                      end)
                    else
                      {:noreply, state}
                    end

                  _ ->
                    {:noreply, state}
                end
            end
          else
            Effects.run_handler(state, fn s ->
              {:ok, s, [Effects.send(char_id, console("Estas demasiado lejos."))]}
            end)
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
              priest_msg =
                if entity.dead do
                  "#{npc_def.name} dice: Puedo resucitarte. Usa el comando /resucitar."
                else
                  "#{npc_def.name} dice: Puedo curarte. Usa el comando /curar."
                end

              Effects.run_handler(state, fn s ->
                effects =
                  [Effects.send(char_id, console(priest_msg))] ++
                    prontuario_effects(char_id, entity)

                {:ok, s, effects}
              end)

            npc_def.npc_type == @npc_type_enlistador ->
              Faction.handle_enlistador_click(state, char_id, entity, npc_def)

            npc_def.npc_type == @npc_type_banquero ->
              case Arena.Map.Bank.handle_open_bank(state, char_id, npc.x, npc.y) do
                {:reply, _result, new_state} -> {:noreply, new_state}
                _ -> {:noreply, state}
              end

            npc_def.npc_type == @npc_type_entrenador ->
              Effects.run_handler(state, fn s ->
                {:ok, s,
                 [
                   Effects.send(
                     char_id,
                     console("#{npc_def.name} dice: Puedo entrenarte. Usa el boton Entrenar.")
                   )
                 ]}
              end)

            npc_def.npc_type == @npc_type_entrega_pesca ->
              Effects.run_handler(state, fn s ->
                handle_fish_delivery(s, char_id, entity, npc_def)
              end)

            npc_def.npc_type == @npc_type_timbero ->
              Effects.run_handler(state, fn s ->
                {:ok, s,
                 [
                   Effects.send(
                     char_id,
                     console(
                       "#{npc_def.name} dice: Haz tu apuesta con /APOSTAR cantidad (1-5000 monedas)."
                     )
                   )
                 ]}
              end)

            npc_def.npc_type == @npc_type_arena_guard ->
              fee = Map.get(npc_def, :arena_price, 0)

              guard_msg =
                if fee > 0 do
                  "#{npc_def.name} dice: La entrada a la arena cuesta #{fee} monedas de oro."
                else
                  "#{npc_def.name} dice: Bienvenido a la arena."
                end

              Effects.run_handler(state, fn s ->
                {:ok, s, [Effects.send(char_id, console(guard_msg))]}
              end)

            npc_def.npc_type == @npc_type_subastador ->
              Effects.run_handler(state, fn s ->
                handle_subastador_click(s, char_id, entity, npc_def)
              end)

            npc_def.npc_type == @npc_type_quest ->
              Effects.run_handler(state, fn s ->
                handle_quest_npc_click(s, char_id, entity, instance_id, npc_def)
              end)

            true ->
              Effects.run_handler(state, fn s ->
                {:ok, s, [Effects.send(char_id, console("Ves a #{npc_def.name}."))]}
              end)
          end
        end
    end
  end

  defp remember_selected_npc(entity, instance_id, npc_type) do
    entity
    |> Map.put(:last_clicked_npc_instance_id, instance_id)
    |> Map.put(:last_clicked_npc_type, npc_type)
  end

  # Delegations to extracted modules for backward compatibility
  defdelegate handle_train_skill(state, char_id, skill_index), to: Arena.Map.Training
  defdelegate handle_train_list(state, char_id), to: Arena.Map.Training
  defdelegate handle_train_creature(state, char_id, payload), to: Arena.Map.Training
  defdelegate handle_bank_gold_transfer(state, char_id, target_name, amount), to: Arena.Map.Banking

  def handle_gamble(state, char_id, amount, _npc_instance_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            {:ok, state, [Effects.send(char_id, console("Estas muerto!"))]}

          amount <= 0 ->
            {:ok, state, [Effects.send(char_id, console("La apuesta debe ser mayor a 0."))]}

          amount > 5000 ->
            {:ok, state, [Effects.send(char_id, console("La apuesta maxima es 5000."))]}

          entity.gold < amount ->
            {:ok, state, [Effects.send(char_id, console("No tienes suficiente oro."))]}

          true ->
            case Helpers.resolve_selected_npc(state, entity, [@npc_type_timbero], 10) do
              :not_found ->
                {:ok, state, [Effects.send(char_id, console("No hay un timbero cerca."))]}

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
                new_state = %{state | players: players}

                outcome_msg =
                  if won do
                    "#{npc_def.name} te dice: Has ganado #{amount} monedas de oro!"
                  else
                    "#{npc_def.name} te dice: Has perdido #{amount} monedas de oro."
                  end

                effects = [
                  Effects.send(char_id, Encoder.encode({:update_gold, %{gold: entity.gold}})),
                  Effects.send(char_id, console(outcome_msg))
                ]

                {:ok, new_state, effects}
            end
        end

      :error ->
        {:ok, state, []}
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
            {:ok, state, [Effects.send(char_id, console("Estas muerto!"))]}

          not entity.criminal ->
            {:ok, state, [Effects.send(char_id, console("No eres un criminal."))]}

          # VB6: faction members (armada/caos) cannot use /PERDON
          entity.faction == :royal_army or entity.faction == :chaos_legion ->
            {:ok, state,
             [Effects.send(char_id, console("No puedo aceptar tu donacion en este momento."))]}

          true ->
            case find_selected_priest(state, entity) do
              :not_found ->
                {:ok, state,
                 [Effects.send(char_id, console("Necesitas estar cerca de un sacerdote."))]}

              {:ok, _npc, %{npc_type: @npc_type_resucitador_newbie}} when entity.level > 12 ->
                # VB6: ResucitadorNewbie only serves newbies (EsNewbie check)
                {:ok, state,
                 [Effects.send(char_id, console("Solo los newbies pueden ser atendidos aqui."))]}

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
                    {:ok, state, [Effects.send(char_id, console("No tienes suficiente dinero."))]}

                  gold_amount < required_donation ->
                    {:ok, state,
                     [
                       Effects.send(
                         char_id,
                         console("Dios no puede perdonarte si eres una persona avara.")
                       )
                     ]}

                  true ->
                    entity = %{entity | criminal: false, gold: entity.gold - gold_amount}
                    players = Map.put(state.players, char_id, entity)
                    new_state = %{state | players: players}

                    effects = [
                      Effects.send(
                        char_id,
                        Encoder.encode({:update_gold, %{gold: entity.gold}})
                      ),
                      Effects.send(char_id, console("Has sido perdonado."))
                    ]

                    {:ok, new_state, effects}
                end
            end
        end

      :error ->
        {:ok, state, []}
    end
  end

  # Find the selected priest within VB6 range (Distancia <= 3)
  defp find_selected_priest(state, entity) do
    Helpers.resolve_selected_npc(
      state,
      entity,
      [@npc_type_revividor, @npc_type_resucitador_newbie],
      @forgive_max_range
    )
  end

  def handle_arena_entry(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        guard =
          case Helpers.resolve_nearby_npc(state, entity, [@npc_type_arena_guard], 10) do
            {:ok, _npc, npc_def} when npc_def.arena_enabled -> npc_def
            _ -> nil
          end

        cond do
          guard == nil ->
            {:ok, state, [Effects.send(char_id, console("No hay un guardia de arena cerca."))]}

          entity.dead ->
            {:ok, state, [Effects.send(char_id, console("Estas muerto!"))]}

          entity.gold < guard.map_entry_price ->
            {:ok, state,
             [
               Effects.send(
                 char_id,
                 console("Necesitas #{guard.map_entry_price} monedas de oro para entrar.")
               )
             ]}

          true ->
            entity = %{entity | gold: entity.gold - guard.map_entry_price}
            players = Map.put(state.players, char_id, entity)
            new_state = %{state | players: players}

            effects = [
              Effects.send(char_id, Encoder.encode({:update_gold, %{gold: entity.gold}})),
              Effects.transfer(
                char_id,
                guard.map_target_entry,
                guard.map_target_entry_x,
                guard.map_target_entry_y,
                entity
              )
            ]

            {:ok, new_state, effects}
        end

      :error ->
        {:ok, state, []}
    end
  end

  def handle_fish_delivery(state, char_id, entity, npc_def) do
    case Map.fetch(state.players, char_id) do
      {:ok, _entity} ->
        if entity.class != :trabajador do
          {:ok, state,
           [
             Effects.send(
               char_id,
               console("#{npc_def.name} dice: Solo los trabajadores pueden entregar peces.")
             )
           ]}
        else
          {total_points, total_gold, slots_to_clear} =
            entity.inventory
            |> Enum.with_index()
            |> Enum.reduce({0, 0, []}, fn {item, idx}, {pts, gold, slots} ->
              case item do
                %{item_id: item_id, amount: amount} when amount > 0 ->
                  item_def = GameData.get_item(item_id)

                  if item_def != nil and item_def.puntos_pesca > 0 do
                    {pts + item_def.puntos_pesca * amount, gold + item_def.valor * amount,
                     [idx | slots]}
                  else
                    {pts, gold, slots}
                  end

                _ ->
                  {pts, gold, slots}
              end
            end)

          if total_points == 0 do
            {:ok, state,
             [
               Effects.send(
                 char_id,
                 console("#{npc_def.name} dice: No tienes peces especiales para entregar.")
               )
             ]}
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
            new_state = %{state | players: players}

            # Per-slot inventory packets first (one per cleared slot).
            # `slots_to_clear` was built via `[idx | slots]` so the head is
            # the highest slot index — we preserve that traversal order to
            # match the prior `Enum.each` behaviour.
            slot_effects =
              Enum.map(slots_to_clear, fn slot ->
                # Inline encode: cleared slots are nil, so the packet is
                # always the empty-slot variant. Keeping this inline avoids
                # a new effect kind for a one-line encode.
                Effects.send(
                  char_id,
                  Encoder.encode(
                    {:change_inventory_slot,
                     %{slot: slot + 1, obj_index: 0, amount: 0}}
                  )
                )
              end)

            effects =
              slot_effects ++
                [
                  Effects.send(
                    char_id,
                    Encoder.encode({:update_gold, %{gold: entity.gold}})
                  ),
                  Effects.send(
                    char_id,
                    console(
                      "Has entregado peces. Puntos: +#{total_points}, Oro: +#{total_gold}."
                    )
                  )
                ]

            {:ok, new_state, effects}
          end
        end

      :error ->
        {:ok, state, []}
    end
  end

  def handle_subastador_click(state, char_id, entity, npc_def) do
    case Map.fetch(state.players, char_id) do
      {:ok, _entity} ->
        tile_key = {entity.x, entity.y}
        item_on_ground = Map.get(state.ground_items || %{}, tile_key)

        case Arena.Auction.initiate(char_id, item_on_ground) do
          :ok ->
            new_ground = Map.delete(state.ground_items || %{}, tile_key)
            new_state = %{state | ground_items: new_ground}

            # Effect ordering: state mutation already applied (item removed
            # from ground_items); broadcast_visible_all then fans the
            # delete_object packet to every visible session. The runner
            # uses post-handler state for visibility lookups, so the
            # broadcast sees the post-removal world.
            #
            # Decision: reuse `Effects.broadcast_visible_all/3` with an
            # inline-encoded `object_delete` packet rather than adding a
            # `:broadcast_object_delete` effect kind. The encode is a
            # one-liner and the existing effect kind already does exactly
            # what `Helpers.broadcast_object_delete/3` was doing
            # internally.
            delete_packet =
              Encoder.encode({:object_delete, %{x: entity.x, y: entity.y}})

            effects = [
              Effects.broadcast_visible_all(entity.x, entity.y, delete_packet),
              Effects.send(
                char_id,
                console(
                  "#{npc_def.name} dice: Escribe /OFERTAINICIAL (cantidad) para comenzar la subasta. Tienes 15 segundos!"
                )
              )
            ]

            {:ok, new_state, effects}

          {:error, :auction_in_progress} ->
            {:ok, state,
             [
               Effects.send(
                 char_id,
                 console(
                   "#{npc_def.name} dice: Oye amigo, espera tu turno, estoy subastando en este momento."
                 )
               )
             ]}

          {:error, :already_initiating} ->
            {:ok, state,
             [
               Effects.send(
                 char_id,
                 console(
                   "#{npc_def.name} dice: Ya estas preparando una subasta. Escribe /OFERTAINICIAL (cantidad)."
                 )
               )
             ]}

          {:error, :no_item} ->
            {:ok, state,
             [
               Effects.send(
                 char_id,
                 console(
                   "#{npc_def.name} dice: Pues acaso el aire esta en venta ahora? Bribon!"
                 )
               )
             ]}
        end

      :error ->
        {:ok, state, []}
    end
  end

  def handle_quest_npc_click(state, char_id, entity, _instance_id, npc_def) do
    case Map.fetch(state.players, char_id) do
      {:ok, _entity} ->
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
            new_state = put_in(state.players[char_id], updated_entity)

            desc_final_effects =
              if quest_def.desc_final != "" do
                [
                  Effects.send(
                    char_id,
                    console(npc_def.name <> " dice: " <> quest_def.desc_final)
                  )
                ]
              else
                []
              end

            gold_effects =
              if quest_def.reward_gld > 0 do
                [
                  Effects.send(
                    char_id,
                    console("Recibiste #{quest_def.reward_gld} monedas de oro.")
                  ),
                  Effects.send(
                    char_id,
                    Encoder.encode({:update_gold, %{gold: updated_entity.gold}})
                  )
                ]
              else
                []
              end

            exp_effects =
              if quest_def.reward_exp > 0 do
                [
                  Effects.send(
                    char_id,
                    console(
                      "Recibiste #{quest_def.reward_exp} puntos de experiencia."
                    )
                  )
                ]
              else
                []
              end

            effects = desc_final_effects ++ gold_effects ++ exp_effects
            {:ok, new_state, effects}
          else
            {:ok, state,
             [Effects.send(char_id, console("No se pudo completar la mision."))]}
          end
        else
          available = Arena.QuestServer.available_quests_for_npc(entity, npc_def)

          if available == [] do
            {:ok, state,
             [
               Effects.send(
                 char_id,
                 console(npc_def.name <> " dice: No tengo misiones disponibles para ti.")
               )
             ]}
          else
            npc_quest_params = Arena.QuestServer.build_npc_quest_list(available)

            entity = %{entity | quest_npc_id: npc_def.id}
            new_state = put_in(state.players[char_id], entity)

            effects = [
              Effects.send(
                char_id,
                Encoder.encode({:npc_quest_list_send, %{quests: npc_quest_params}})
              )
            ]

            {:ok, new_state, effects}
          end
        end

      :error ->
        {:ok, state, []}
    end
  end

  # VB6: clicking a priest NPC shows the player's prontuario (punishment record).
  # Returns a single-element effects list so the priest branch can splice it
  # into its own effects.
  defp prontuario_effects(char_id, entity) do
    punishments = Map.get(entity, :punishments, [])
    text = Arena.Map.Gm.Moderation.format_punishments(punishments)
    [Effects.send(char_id, console(text))]
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end
end
