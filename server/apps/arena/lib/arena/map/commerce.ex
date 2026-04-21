defmodule Arena.Map.Commerce do
  @moduledoc "NPC shopkeeper commerce handlers."

  alias Arena.Map.{Helpers, Trade}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @gold_item_id 12

  def handle_open_commerce(state, char_id, target_x, target_y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:reply, {:error, :dead}, state}

      {:ok, entity} ->
        target_occ = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y)

        cond do
          entity.trade_partner_id != nil ->
            {:reply, {:error, :already_trading}, state}

          entity.meditating ->
            {:reply, {:error, :meditating}, state}

          entity.navigating ->
            {:reply, {:error, :navigating}, state}

          entity.paralyzed ->
            {:reply, {:error, :paralyzed}, state}

          true ->
        case target_occ do
          # VB6: target is a player -> user-to-user trade request
          {:player, target_id} when target_id != char_id ->
            if Map.get(state.meta, :safe_zone, false) do
              {:reply, {:error, :safe_zone}, state}
            else
            target = Map.get(state.players, target_id)

            cond do
              target == nil ->
                {:reply, {:error, :target_not_found}, state}

              target.dead ->
                {:reply, {:error, :target_dead}, state}

              abs(entity.x - target.x) > 3 or abs(entity.y - target.y) > 3 ->
                {:reply, {:error, :too_far}, state}

              true ->
                Trade.start_user_trade_request(state, char_id, entity, target_id)
            end
            end

          # Target is NPC -> NPC commerce
          {:npc, inst_id} ->
            npc = Map.get(state.npcs_live, inst_id)
            open_npc_commerce(state, char_id, entity, npc)

          _ ->
            {:reply, {:error, :no_target}, state}
        end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_commerce_buy(state, char_id, slot, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:reply, {:error, :dead}, state}

      {:ok, entity} ->
        if amount <= 0 do
          {:reply, {:error, :invalid_amount}, state}
        else
        npc_id = entity.commerce_npc_id
        npc_def = if npc_id, do: GameData.get_npc(npc_id)

        cond do
          npc_def == nil or not npc_def.comercia ->
            {:reply, {:error, :no_commerce}, state}

          not merchant_still_valid?(state, entity, npc_id) ->
            {:reply, {:error, :merchant_gone}, state}

          true ->
          shop_item = Enum.at(npc_def.shop_items, slot - 1)

          if shop_item == nil do
            {:reply, {:error, :invalid_slot}, state}
          else
            item_def = GameData.get_item(shop_item.item_id)

            if item_def == nil do
              {:reply, {:error, :invalid_item}, state}
            else
              trading_skill = Map.get(entity.skills, :trading, 0)
              buy_price = ceil(item_def.valor / (1 + trading_skill / 100) * amount)

              if entity.gold < buy_price do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "No tienes suficiente oro.", font_index: 0}})}
                )

                {:reply, {:error, :not_enough_gold}, state}
              else
                case find_inventory_slot(entity, shop_item.item_id, item_def.stackable) do
                  nil ->
                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw, Encoder.encode({:console_msg, %{message: "Inventario lleno.", font_index: 0}})}
                    )

                    {:reply, {:error, :inventory_full}, state}

                  inv_slot ->
                    entity = %{entity | gold: entity.gold - buy_price}
                    current = Enum.at(entity.inventory, inv_slot)

                    new_item =
                      if current && current.item_id == shop_item.item_id do
                        %{current | amount: current.amount + amount}
                      else
                        %{item_id: shop_item.item_id, amount: amount, equipped: false}
                      end

                    inventory = List.replace_at(entity.inventory, inv_slot, new_item)
                    entity = %{entity | inventory: inventory}

                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw,
                       Encoder.encode(
                         {:change_inventory_slot,
                          %{
                            slot: inv_slot + 1,
                            obj_index: shop_item.item_id,
                            amount: new_item.amount,
                            equipped: new_item.equipped,
                            valor: item_def.valor / 1.0
                          }}
                       )}
                    )

                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
                    )

                    players = Map.put(state.players, char_id, entity)
                    {:reply, :ok, %{state | players: players}}
                end
              end
            end
          end
        end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_commerce_sell(state, char_id, slot, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:reply, {:error, :dead}, state}

      {:ok, entity} ->
        cond do
          entity.commerce_npc_id == nil ->
            {:reply, {:error, :no_commerce}, state}

          not merchant_still_valid?(state, entity, entity.commerce_npc_id) ->
            {:reply, {:error, :merchant_gone}, state}

          # VB6 Comercio.bas:130-133 — Consejero/SemiDios cannot sell items.
          Map.get(entity, :gm_level) in [:consejero, :semi_dios] ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "No podes vender items.", font_index: 0}})}
            )

            {:reply, {:error, :gm_cannot_sell}, state}

          amount <= 0 ->
            {:reply, {:error, :invalid_amount}, state}

          # Drift #5 — patron tiers grow the inventory slot list.
          slot < 1 or slot > length(entity.inventory) ->
            {:reply, {:error, :invalid_slot}, state}

          true ->
          inv_idx = slot - 1
          inv_item = Enum.at(entity.inventory, inv_idx)

          cond do
            inv_item == nil ->
              {:reply, {:error, :empty_slot}, state}

            inv_item.equipped ->
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode({:console_msg, %{message: "Debes desequipar el objeto antes de venderlo.", font_index: 0}})}
              )

              {:reply, {:error, :equipped_item}, state}

            inv_item.amount < amount ->
              {:reply, {:error, :not_enough}, state}

            true ->
              item_def = GameData.get_item(inv_item.item_id)

              # VB6: newbie items cannot be sold
              cond do
                item_def != nil and item_def.newbie ->
                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw,
                     Encoder.encode({:console_msg, %{message: "Objetos newbies no se pueden vender.", font_index: 0}})}
                  )

                  {:reply, {:error, :newbie_item}, state}

                item_def != nil and Map.get(item_def, :instransferible, false) ->
                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw,
                     Encoder.encode({:console_msg, %{message: "No puedes vender objetos instransferibles.", font_index: 0}})}
                  )

                  {:reply, {:error, :untradeable}, state}

                item_def != nil and Map.get(item_def, :destruye, false) ->
                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw,
                     Encoder.encode({:console_msg, %{message: "Lo siento, no puedo comprarte ese item.", font_index: 0}})}
                  )

                  {:reply, {:error, :destruye_item}, state}

                inv_item.item_id == @gold_item_id ->
                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw,
                     Encoder.encode({:console_msg, %{message: "No puedes vender oro.", font_index: 0}})}
                  )

                  {:reply, {:error, :gold_item}, state}

                quest_objective_item?(entity, inv_item.item_id) ->
                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw,
                     Encoder.encode(
                       {:console_msg, %{message: "No puedes vender objetos de mision.", font_index: 0}}
                     )}
                  )

                  {:reply, {:error, :quest_item}, state}

                true ->
                  sell_price = if item_def, do: trunc(item_def.valor / sell_price_denom(entity)) * amount, else: 0

                  new_amount = inv_item.amount - amount

                  inventory =
                    if new_amount <= 0 do
                      List.replace_at(entity.inventory, inv_idx, nil)
                    else
                      List.replace_at(entity.inventory, inv_idx, %{inv_item | amount: new_amount})
                    end

                  entity = %{entity | inventory: inventory, gold: entity.gold + sell_price}

                  if new_amount <= 0 do
                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw,
                       Encoder.encode(
                         {:change_inventory_slot, %{slot: slot, obj_index: 0, amount: 0, equipped: false, valor: 0.0}}
                       )}
                    )
                  else
                    valor = if item_def, do: item_def.valor / 1.0, else: 0.0

                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw,
                       Encoder.encode(
                         {:change_inventory_slot,
                          %{
                            slot: slot,
                            obj_index: inv_item.item_id,
                            amount: new_amount,
                            equipped: inv_item.equipped,
                            valor: valor
                          }}
                       )}
                    )
                  end

                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
                  )

                  players = Map.put(state.players, char_id, entity)
                  {:reply, :ok, %{state | players: players}}
              end
          end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_commerce_end(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | commerce_npc_id: nil, commerce_npc_instance_id: nil}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:commerce_end, %{}})})
        players = Map.put(state.players, char_id, entity)
        {:reply, :ok, %{state | players: players}}

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def open_npc_commerce(state, _char_id, _entity, nil) do
    {:reply, {:error, :no_npc}, state}
  end

  def open_npc_commerce(state, char_id, entity, npc) do
    npc_def = GameData.get_npc(npc.npc_id)

    cond do
      npc_def == nil or not npc_def.comercia ->
        {:reply, {:error, :not_a_merchant}, state}

      abs(entity.x - npc.x) > 3 or abs(entity.y - npc.y) > 3 ->
        {:reply, {:error, :too_far}, state}

      true ->
        entity = %{entity | commerce_npc_id: npc.npc_id, commerce_npc_instance_id: npc.instance_id}

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:commerce_init, %{npc_name: npc_def.name || "Comerciante"}})}
        )

        npc_def.shop_items
        |> Enum.with_index(1)
        |> Enum.each(fn {%{item_id: item_id}, slot} ->
          item_def = GameData.get_item(item_id)

          if item_def do
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode(
                 {:change_npc_inventory_slot,
                  %{
                    slot: slot,
                    obj_index: item_id,
                    amount: 10000,
                    price: item_def.valor / 1.0,
                    puede_usar: 1
                  }}
               )}
            )
          end
        end)

        players = Map.put(state.players, char_id, entity)
        {:reply, :ok, %{state | players: players}}
    end
  end

  # Private helpers

  defp merchant_still_valid?(state, entity, npc_id) do
    case Map.get(entity, :commerce_npc_instance_id) do
      nil ->
        case Enum.find(state.npcs_live, fn {_inst, npc} -> npc.npc_id == npc_id end) do
          nil -> false
          {_inst, npc} -> abs(entity.x - npc.x) <= 3 and abs(entity.y - npc.y) <= 3
        end

      inst_id ->
        case Map.get(state.npcs_live, inst_id) do
          %{npc_id: ^npc_id} = npc ->
            abs(entity.x - npc.x) <= 3 and abs(entity.y - npc.y) <= 3

          _ ->
            false
        end
    end
  end

  defp quest_objective_item?(entity, item_id) do
    active_quests = Map.get(entity, :active_quests, [])

    Enum.any?(active_quests, fn qs ->
      quest_def = GameData.get_quest(qs.quest_id)

      quest_def != nil and
        Enum.any?(quest_def.required_objs, fn req -> req.id == item_id end)
    end)
  end

  # VB6 Comercio.bas:294-310 (SalePrice) — base denominator is
  # REDUCTOR_PRECIOVENTA = 3; Trabajador subtracts level * 0.025 (clamped at 2).
  defp sell_price_denom(entity) do
    if Map.get(entity, :class) == :trabajador do
      max(3 - Map.get(entity, :level, 1) * 0.025, 2)
    else
      3
    end
  end

  defp find_inventory_slot(entity, item_id, stackable) do
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
end
