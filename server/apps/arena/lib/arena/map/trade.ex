defmodule Arena.Map.Trade do
  @moduledoc "User-to-user trade handlers."

  alias Arena.Map.Helpers
  alias Arena.Inventory
  alias AoProtocol.Server.Encoder

  @trade_max_items 6

  def handle_user_trade_offer(state, char_id, obj_index, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:reply, {:error, :dead}, state}

      {:ok, entity} when entity.trade_partner_id != nil ->
        # Validate: item must exist in player's inventory (unequipped)
        slot_idx = Enum.find_index(entity.inventory, fn
          %{item_id: ^obj_index, equipped: false} = item -> item.amount >= amount
          _ -> false
        end)

        if slot_idx == nil or amount <= 0 do
          {:reply, {:error, :invalid_offer}, state}
        else
          # Add or update the offered item in trade_offer_items
          existing = Enum.find_index(entity.trade_offer_items, fn {id, _} -> id == obj_index end)

          trade_items =
            if existing do
              List.update_at(entity.trade_offer_items, existing, fn {id, old_amt} ->
                {id, old_amt + amount}
              end)
            else
              if length(entity.trade_offer_items) >= @trade_max_items do
                entity.trade_offer_items
              else
                entity.trade_offer_items ++ [{obj_index, amount}]
              end
            end

          # Reset both players' accepted state on any offer change
          entity = %{entity | trade_offer_items: trade_items, trade_accepted: false}
          players = Map.put(state.players, char_id, entity)

          partner = Map.get(players, entity.trade_partner_id)
          players =
            if partner do
              Map.put(players, entity.trade_partner_id, %{partner | trade_accepted: false})
            else
              players
            end

          state = %{state | players: players}
          send_trade_slot_update(state, char_id, entity)
          {:reply, :ok, state}
        end

      {:ok, _entity} ->
        {:reply, {:error, :not_trading}, state}

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_user_trade_accept(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:reply, {:error, :dead}, state}

      {:ok, entity} when entity.trade_partner_id != nil ->
        entity = %{entity | trade_accepted: true}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        partner = Map.get(state.players, entity.trade_partner_id)

        if partner && partner.trade_accepted do
          # Both accepted -- execute trade
          state = execute_trade(state, char_id, entity.trade_partner_id)
          {:reply, :ok, state}
        else
          {:reply, :ok, state}
        end

      {:ok, _entity} ->
        {:reply, {:error, :not_trading}, state}

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_user_trade_reject(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.trade_partner_id != nil ->
        state = end_user_trade(state, char_id)
        {:reply, :ok, state}

      {:ok, _entity} ->
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_user_trade_end(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.trade_partner_id != nil ->
        state = end_user_trade(state, char_id)
        {:reply, :ok, state}

      {:ok, entity} when entity.trade_request_target != nil ->
        # Cancel pending request
        entity = %{entity | trade_request_target: nil}
        players = Map.put(state.players, char_id, entity)
        {:reply, :ok, %{state | players: players}}

      {:ok, _entity} ->
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  # Trade helpers

  def start_user_trade_request(state, char_id, entity, target_id) do
    case Map.get(state.players, target_id) do
      nil ->
        {:reply, {:error, :target_not_found}, state}

      target ->
        # VB6: if both players have requested trade with each other, start trade
        if target.trade_request_target == char_id do
          # Both ready -- start trade
          entity = %{entity | trade_partner_id: target_id, trade_request_target: nil,
                     trade_offer_gold: 0, trade_offer_items: [], trade_accepted: false}
          target = %{target | trade_partner_id: char_id, trade_request_target: nil,
                     trade_offer_gold: 0, trade_offer_items: [], trade_accepted: false}

          Helpers.send_to_session(state.sessions, char_id, {:send_raw,
            Encoder.encode({:user_commerce_init, %{name: target.name}})})
          Helpers.send_to_session(state.sessions, target_id, {:send_raw,
            Encoder.encode({:user_commerce_init, %{name: entity.name}})})

          players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target)
          {:reply, :ok, %{state | players: players}}
        else
          # First request -- store and notify target
          entity = %{entity | trade_request_target: target_id}
          Helpers.send_to_session(state.sessions, target_id, {:send_raw,
            Encoder.encode({:console_msg, %{message: "#{entity.name} desea comerciar contigo.", font_index: 0}})})

          players = Map.put(state.players, char_id, entity)
          {:reply, :ok, %{state | players: players}}
        end
    end
  end

  def end_user_trade(state, char_id) do
    case Map.get(state.players, char_id) do
      nil -> state
      entity ->
        partner_id = entity.trade_partner_id
        entity = %{entity | trade_partner_id: nil, trade_request_target: nil,
                   trade_offer_gold: 0, trade_offer_items: [], trade_accepted: false}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:user_commerce_end, %{}})})

        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        # Also clean up partner
        if partner_id do
          case Map.get(state.players, partner_id) do
            nil -> state
            partner ->
              partner = %{partner | trade_partner_id: nil, trade_request_target: nil,
                         trade_offer_gold: 0, trade_offer_items: [], trade_accepted: false}
              Helpers.send_to_session(state.sessions, partner_id, {:send_raw,
                Encoder.encode({:user_commerce_end, %{}})})
              players = Map.put(state.players, partner_id, partner)
              %{state | players: players}
          end
        else
          state
        end
    end
  end

  def send_trade_slot_update(state, char_id, entity) do
    items = Enum.map(entity.trade_offer_items, fn {obj_index, amount} ->
      item_def = Arena.Data.GameData.get_item(obj_index)
      %{
        obj_index: obj_index,
        name: (item_def && item_def.name) || "",
        grh_index: (item_def && item_def.grh_index) || 0,
        amount: amount,
        elemental_tags: 0
      }
    end)

    # Send to self (my_offer: true)
    Helpers.send_to_session(state.sessions, char_id, {:send_raw,
      Encoder.encode({:change_user_trade_slot, %{my_offer: true, gold: entity.trade_offer_gold, items: items}})})

    # Send to partner (my_offer: false)
    if entity.trade_partner_id do
      Helpers.send_to_session(state.sessions, entity.trade_partner_id, {:send_raw,
        Encoder.encode({:change_user_trade_slot, %{my_offer: false, gold: entity.trade_offer_gold, items: items}})})
    end
  end

  def execute_trade(state, char_id, partner_id) do
    entity = Map.get(state.players, char_id)
    partner = Map.get(state.players, partner_id)

    # Validate gold
    cond do
      entity.trade_offer_gold > entity.gold ->
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:console_msg, %{message: "No tienes esa cantidad de oro.", font_index: 0}})})
        end_user_trade(state, char_id)

      partner.trade_offer_gold > partner.gold ->
        Helpers.send_to_session(state.sessions, partner_id, {:send_raw,
          Encoder.encode({:console_msg, %{message: "No tienes esa cantidad de oro.", font_index: 0}})})
        end_user_trade(state, char_id)

      true ->
        # Transfer gold
        entity = %{entity | gold: entity.gold - entity.trade_offer_gold + partner.trade_offer_gold}
        partner = %{partner | gold: partner.gold - partner.trade_offer_gold + entity.trade_offer_gold}

        # Transfer items: remove from offerer, add to receiver
        {entity, partner} = transfer_trade_items(entity, partner)
        {partner, entity} = transfer_trade_items(partner, entity)

        # Clear trade state
        entity = %{entity | trade_partner_id: nil, trade_request_target: nil,
                   trade_offer_gold: 0, trade_offer_items: [], trade_accepted: false}
        partner = %{partner | trade_partner_id: nil, trade_request_target: nil,
                   trade_offer_gold: 0, trade_offer_items: [], trade_accepted: false}

        # Notify both
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:user_commerce_end, %{}})})
        Helpers.send_to_session(state.sessions, partner_id, {:send_raw,
          Encoder.encode({:user_commerce_end, %{}})})

        # Send updated gold
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_gold, %{gold: entity.gold}})})
        Helpers.send_to_session(state.sessions, partner_id, {:send_raw,
          Encoder.encode({:update_gold, %{gold: partner.gold}})})

        # Send full inventory updates
        Enum.each(0..23, fn slot ->
          Helpers.send_inventory_slot(state.sessions, char_id, entity.inventory, slot)
          Helpers.send_inventory_slot(state.sessions, partner_id, partner.inventory, slot)
        end)

        players = state.players |> Map.put(char_id, entity) |> Map.put(partner_id, partner)
        %{state | players: players}
    end
  end

  def transfer_trade_items(giver, receiver) do
    Enum.reduce(giver.trade_offer_items, {giver, receiver}, fn {obj_index, amount}, {g, r} ->
      # Find the slot in giver's inventory that holds this item
      slot_idx = Enum.find_index(g.inventory, fn
        %{item_id: ^obj_index, equipped: false} -> true
        _ -> false
      end)

      if slot_idx do
        case Inventory.remove_from_slot(g.inventory, slot_idx, amount) do
          {:ok, new_inv, _} ->
            g = %{g | inventory: new_inv}
            case Inventory.add_item(r.inventory, obj_index, amount) do
              {:ok, new_inv, _slot} -> {g, %{r | inventory: new_inv}}
              {:gold, gold_amount} -> {g, %{r | gold: r.gold + gold_amount}}
              _ -> {g, r}
            end
          _ -> {g, r}
        end
      else
        {g, r}
      end
    end)
  end
end
