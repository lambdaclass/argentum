defmodule Arena.Map.Commerce do
  @moduledoc """
  NPC shopkeeper commerce handlers.

  All public handlers return `{:ok, state, reply, [Effect.t()]}` —
  the rich-reply variant of the effects contract. MapServer dispatches
  through `Arena.Map.Effects.run_handler_call_reply/2`, which surfaces
  `reply` to the caller (e.g. `:ok` or `{:error, reason}`) and runs the
  side-effect list against post-handler state.

  `open_npc_commerce/4` is also on the rich-reply shape because it is
  called both from `handle_open_commerce/4` (in-handler composition,
  appending its effects to the parent list) and from the NPC double-click
  bridge in `Arena.Map.NpcInteraction`.
  """

  alias Arena.Map.{Effects, Helpers, Trade}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @gold_item_id 12

  def handle_open_commerce(state, char_id, target_x, target_y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, {:error, :dead}, []}

      {:ok, entity} ->
        target_occ =
          if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y)

        cond do
          entity.trade_partner_id != nil ->
            {:ok, state, {:error, :already_trading}, []}

          entity.meditating ->
            {:ok, state, {:error, :meditating}, []}

          entity.navigating ->
            {:ok, state, {:error, :navigating}, []}

          entity.paralyzed ->
            {:ok, state, {:error, :paralyzed}, []}

          true ->
            case target_occ do
              # VB6: target is a player -> user-to-user trade request
              {:player, target_id} when target_id != char_id ->
                if Map.get(state.meta, :safe_zone, false) do
                  {:ok, state, {:error, :safe_zone}, []}
                else
                  target = Map.get(state.players, target_id)

                  cond do
                    target == nil ->
                      {:ok, state, {:error, :target_not_found}, []}

                    target.dead ->
                      {:ok, state, {:error, :target_dead}, []}

                    abs(entity.x - target.x) > 3 or abs(entity.y - target.y) > 3 ->
                      {:ok, state, {:error, :too_far}, []}

                    true ->
                      # Trade is on the rich-reply effects contract: append its
                      # effects to ours and surface its reply to the caller.
                      Trade.start_user_trade_request(state, char_id, entity, target_id)
                  end
                end

              # Target is NPC -> NPC commerce
              {:npc, inst_id} ->
                npc = Map.get(state.npcs_live, inst_id)
                open_npc_commerce(state, char_id, entity, npc)

              _ ->
                {:ok, state, {:error, :no_target}, []}
            end
        end

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  def handle_commerce_buy(state, char_id, slot, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, {:error, :dead}, []}

      # VB6 Comercio.bas / Protocol.bas — Comerciando is a shared mutex
      # between NPC commerce and user-to-user trade. While a player has an
      # active trade_partner_id, NPC commerce must be blocked (defense-in-depth
      # in case commerce_npc_id lingers from a prior session).
      {:ok, entity} when entity.trade_partner_id != nil ->
        {:ok, state, {:error, :already_trading}, []}

      {:ok, entity} ->
        if amount <= 0 do
          {:ok, state, {:error, :invalid_amount}, []}
        else
          npc_id = entity.commerce_npc_id
          npc_def = if npc_id, do: GameData.get_npc(npc_id)

          cond do
            npc_def == nil or not npc_def.comercia ->
              {:ok, state, {:error, :no_commerce}, []}

            not merchant_still_valid?(state, entity, npc_id) ->
              {:ok, state, {:error, :merchant_gone}, []}

            true ->
              shop_item = Enum.at(npc_def.shop_items, slot - 1)

              if shop_item == nil do
                {:ok, state, {:error, :invalid_slot}, []}
              else
                item_def = GameData.get_item(shop_item.item_id)

                if item_def == nil do
                  {:ok, state, {:error, :invalid_item}, []}
                else
                  do_buy(state, char_id, entity, shop_item, item_def, amount)
                end
              end
          end
        end

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  defp do_buy(state, char_id, entity, shop_item, item_def, amount) do
    trading_skill = Map.get(entity.skills, :trading, 0)
    buy_price = ceil(item_def.valor / (1 + trading_skill / 100) * amount)

    cond do
      entity.gold < buy_price ->
        {:ok, state, {:error, :not_enough_gold},
         [Effects.send(char_id, console("No tienes suficiente oro."))]}

      true ->
        case find_inventory_slot(entity, shop_item.item_id, item_def.stackable) do
          nil ->
            {:ok, state, {:error, :inventory_full},
             [Effects.send(char_id, console("Inventario lleno."))]}

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

            slot_packet =
              Encoder.encode(
                {:change_inventory_slot,
                 %{
                   slot: inv_slot + 1,
                   obj_index: shop_item.item_id,
                   amount: new_item.amount,
                   equipped: new_item.equipped,
                   valor: item_def.valor / 1.0
                 }}
              )

            gold_packet = Encoder.encode({:update_gold, %{gold: entity.gold}})

            effects = [
              Effects.send(char_id, slot_packet),
              Effects.send(char_id, gold_packet)
            ]

            players = Map.put(state.players, char_id, entity)
            {:ok, %{state | players: players}, :ok, effects}
        end
    end
  end

  def handle_commerce_sell(state, char_id, slot, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, {:error, :dead}, []}

      # VB6 Comercio.bas / Protocol.bas — Comerciando is a shared mutex
      # between NPC commerce and user-to-user trade. While a player has an
      # active trade_partner_id, NPC commerce must be blocked (defense-in-depth
      # in case commerce_npc_id lingers from a prior session).
      {:ok, entity} when entity.trade_partner_id != nil ->
        {:ok, state, {:error, :already_trading}, []}

      {:ok, entity} ->
        cond do
          entity.commerce_npc_id == nil ->
            {:ok, state, {:error, :no_commerce}, []}

          not merchant_still_valid?(state, entity, entity.commerce_npc_id) ->
            {:ok, state, {:error, :merchant_gone}, []}

          # VB6 Comercio.bas:130-133 — Consejero/SemiDios cannot sell items.
          Map.get(entity, :gm_level) in [:consejero, :semi_dios] ->
            {:ok, state, {:error, :gm_cannot_sell},
             [Effects.send(char_id, console("No podes vender items."))]}

          amount <= 0 ->
            {:ok, state, {:error, :invalid_amount}, []}

          # Drift #5 — patron tiers grow the inventory slot list.
          slot < 1 or slot > length(entity.inventory) ->
            {:ok, state, {:error, :invalid_slot}, []}

          true ->
            inv_idx = slot - 1
            inv_item = Enum.at(entity.inventory, inv_idx)

            cond do
              inv_item == nil ->
                {:ok, state, {:error, :empty_slot}, []}

              inv_item.equipped ->
                {:ok, state, {:error, :equipped_item},
                 [
                   Effects.send(
                     char_id,
                     console("Debes desequipar el objeto antes de venderlo.")
                   )
                 ]}

              inv_item.amount < amount ->
                {:ok, state, {:error, :not_enough}, []}

              true ->
                do_sell(state, char_id, entity, inv_idx, inv_item, slot, amount)
            end
        end

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  defp do_sell(state, char_id, entity, inv_idx, inv_item, slot, amount) do
    item_def = GameData.get_item(inv_item.item_id)

    # VB6: newbie items cannot be sold
    cond do
      item_def != nil and item_def.newbie ->
        {:ok, state, {:error, :newbie_item},
         [Effects.send(char_id, console("Objetos newbies no se pueden vender."))]}

      item_def != nil and Map.get(item_def, :instransferible, false) ->
        {:ok, state, {:error, :untradeable},
         [Effects.send(char_id, console("No puedes vender objetos instransferibles."))]}

      item_def != nil and Map.get(item_def, :destruye, false) ->
        {:ok, state, {:error, :destruye_item},
         [Effects.send(char_id, console("Lo siento, no puedo comprarte ese item."))]}

      inv_item.item_id == @gold_item_id ->
        {:ok, state, {:error, :gold_item},
         [Effects.send(char_id, console("No puedes vender oro."))]}

      quest_objective_item?(entity, inv_item.item_id) ->
        {:ok, state, {:error, :quest_item},
         [Effects.send(char_id, console("No puedes vender objetos de mision."))]}

      true ->
        sell_price =
          if item_def, do: trunc(item_def.valor / sell_price_denom(entity)) * amount, else: 0

        new_amount = inv_item.amount - amount

        inventory =
          if new_amount <= 0 do
            List.replace_at(entity.inventory, inv_idx, nil)
          else
            List.replace_at(entity.inventory, inv_idx, %{inv_item | amount: new_amount})
          end

        entity = %{entity | inventory: inventory, gold: entity.gold + sell_price}

        slot_packet =
          if new_amount <= 0 do
            Encoder.encode(
              {:change_inventory_slot,
               %{slot: slot, obj_index: 0, amount: 0, equipped: false, valor: 0.0}}
            )
          else
            valor = if item_def, do: item_def.valor / 1.0, else: 0.0

            Encoder.encode(
              {:change_inventory_slot,
               %{
                 slot: slot,
                 obj_index: inv_item.item_id,
                 amount: new_amount,
                 equipped: inv_item.equipped,
                 valor: valor
               }}
            )
          end

        effects = [
          Effects.send(char_id, slot_packet),
          Effects.send(char_id, Encoder.encode({:update_gold, %{gold: entity.gold}}))
        ]

        players = Map.put(state.players, char_id, entity)
        {:ok, %{state | players: players}, :ok, effects}
    end
  end

  def handle_commerce_end(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | commerce_npc_id: nil, commerce_npc_instance_id: nil}
        players = Map.put(state.players, char_id, entity)
        effects = [Effects.send(char_id, Encoder.encode({:commerce_end, %{}}))]
        {:ok, %{state | players: players}, :ok, effects}

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  def open_npc_commerce(state, _char_id, _entity, nil) do
    {:ok, state, {:error, :no_npc}, []}
  end

  def open_npc_commerce(state, char_id, entity, npc) do
    npc_def = GameData.get_npc(npc.npc_id)

    cond do
      npc_def == nil or not npc_def.comercia ->
        {:ok, state, {:error, :not_a_merchant}, []}

      abs(entity.x - npc.x) > 3 or abs(entity.y - npc.y) > 3 ->
        {:ok, state, {:error, :too_far}, []}

      true ->
        entity = %{
          entity
          | commerce_npc_id: npc.npc_id,
            commerce_npc_instance_id: npc.instance_id
        }

        init_effect =
          Effects.send(
            char_id,
            Encoder.encode({:commerce_init, %{npc_name: npc_def.name || "Comerciante"}})
          )

        slot_effects =
          npc_def.shop_items
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {%{item_id: item_id}, slot} ->
            case GameData.get_item(item_id) do
              nil ->
                []

              item_def ->
                [
                  Effects.send(
                    char_id,
                    Encoder.encode(
                      {:change_npc_inventory_slot,
                       %{
                         slot: slot,
                         obj_index: item_id,
                         amount: 10000,
                         price: item_def.valor / 1.0,
                         puede_usar: 1
                       }}
                    )
                  )
                ]
            end
          end)

        players = Map.put(state.players, char_id, entity)
        {:ok, %{state | players: players}, :ok, [init_effect | slot_effects]}
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

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end
end
