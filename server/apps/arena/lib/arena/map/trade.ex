defmodule Arena.Map.Trade do
  @moduledoc """
  User-to-user trade handlers.

  Public top-level handlers follow the effects contract:
  `{:ok, state, reply, effects}` — they are dispatched by MapServer via
  `Arena.Map.Effects.run_handler_call_reply/2` because their callers branch
  on the reply (e.g. tests assert specific error reasons). Internal
  helpers used inside the trade flow (`end_user_trade/2`, `execute_trade/3`,
  `start_user_trade_request/4`) return `{state, effects}` or
  `{state, reply, effects}` so they can be composed without an extra
  effect-runner layer.
  """

  alias Arena.Map.{Effects, Helpers}
  alias Arena.Inventory
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @trade_max_items 6

  def handle_user_trade_offer(state, char_id, obj_index, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, {:error, :dead}, []}

      {:ok, entity} when entity.trade_partner_id != nil ->
        # Validate: item must exist in player's inventory (unequipped)
        slot_idx =
          Enum.find_index(entity.inventory, fn
            %{item_id: ^obj_index, equipped: false} = item -> item.amount >= amount
            _ -> false
          end)

        if slot_idx == nil or amount <= 0 do
          {:ok, state, {:error, :invalid_offer}, []}
        else
          inv_item = Enum.at(entity.inventory, slot_idx)
          item_def = GameData.get_item(inv_item.item_id)

          # VB6 parity: instransferible items cannot be traded
          cond do
            item_def != nil and Map.get(item_def, :instransferible, false) ->
              {:ok, state, {:error, :untradeable},
               [Effects.send(char_id, console("No puedes comerciar objetos instransferibles."))]}

            # VB6 parity: newbie items cannot be traded
            item_def != nil and item_def.newbie ->
              {:ok, state, {:error, :newbie_item},
               [Effects.send(char_id, console("No puedes comerciar objetos newbies."))]}

            true ->
              item_tags = Map.get(inv_item, :elemental_tags, 0)

              # Check total already offered for this item
              already_offered =
                Enum.reduce(entity.trade_offer_items, 0, fn
                  {id, amt, t}, acc when id == obj_index and t == item_tags -> acc + amt
                  _, acc -> acc
                end)

              if already_offered + amount > inv_item.amount do
                {:ok, state, {:error, :invalid_offer}, []}
              else
                # Add or update the offered item in trade_offer_items
                existing =
                  Enum.find_index(entity.trade_offer_items, fn {id, _, t} ->
                    id == obj_index and t == item_tags
                  end)

                trade_items =
                  if existing do
                    List.update_at(entity.trade_offer_items, existing, fn {id, old_amt, tags} ->
                      {id, old_amt + amount, tags}
                    end)
                  else
                    if length(entity.trade_offer_items) >= @trade_max_items do
                      entity.trade_offer_items
                    else
                      entity.trade_offer_items ++ [{obj_index, amount, item_tags}]
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
                slot_effects = trade_slot_update_effects(char_id, entity)
                {:ok, state, :ok, slot_effects}
              end
          end
        end

      {:ok, _entity} ->
        {:ok, state, {:error, :not_trading}, []}

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  def handle_user_trade_accept(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, {:error, :dead}, []}

      {:ok, entity} when entity.trade_partner_id != nil ->
        entity = %{entity | trade_accepted: true}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        partner = Map.get(state.players, entity.trade_partner_id)

        if partner && partner.trade_accepted do
          # Both accepted -- verify distance before executing trade
          if abs(entity.x - partner.x) > 3 or abs(entity.y - partner.y) > 3 do
            {state, end_effects} = end_user_trade(state, char_id)
            {:ok, state, {:error, :too_far}, end_effects}
          else
            # Both accepted and within range -- execute trade
            {state, exec_effects} = execute_trade(state, char_id, entity.trade_partner_id)
            {:ok, state, :ok, exec_effects}
          end
        else
          {:ok, state, :ok, []}
        end

      {:ok, _entity} ->
        {:ok, state, {:error, :not_trading}, []}

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  def handle_user_trade_reject(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.trade_partner_id != nil ->
        {state, end_effects} = end_user_trade(state, char_id)
        {:ok, state, :ok, end_effects}

      {:ok, _entity} ->
        {:ok, state, :ok, []}

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  def handle_user_trade_end(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.trade_partner_id != nil ->
        {state, end_effects} = end_user_trade(state, char_id)
        {:ok, state, :ok, end_effects}

      {:ok, entity} when entity.trade_request_target != nil ->
        # Cancel pending request
        entity = %{entity | trade_request_target: nil}
        players = Map.put(state.players, char_id, entity)
        {:ok, %{state | players: players}, :ok, []}

      {:ok, _entity} ->
        {:ok, state, :ok, []}

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  # Trade helpers

  @doc """
  Initiate or accept a trade request between `char_id` and `target_id`.

  Returns `{:ok, state, reply, effects}` so the caller (e.g.
  `Commerce.handle_open_commerce`, also on the rich-reply effects
  contract) can append the effects directly to its own list and surface
  the reply to the GenServer client via `Effects.run_handler_call_reply/2`.

  Note: when both sides are ready, this also dispatches the in-band
  `:trade_started` session-state hint (sets `in_trade: true` on the
  gateway loop). That hint is not an encoded packet, so it stays on
  `Helpers.send_to_session/3` — the `{:send_raw, _}` guard is keyed on
  the `:send_raw` atom, not on raw `send/2`.
  """
  def start_user_trade_request(state, char_id, entity, target_id) do
    case Map.get(state.players, target_id) do
      nil ->
        {:ok, state, {:error, :target_not_found}, []}

      target ->
        cond do
          target.dead ->
            {:ok, state, {:error, :target_dead},
             [Effects.send(char_id, console("No puedes comerciar con un muerto."))]}

          entity.trade_partner_id != nil ->
            {:ok, state, {:error, :already_trading}, []}

          target.trade_partner_id != nil ->
            {:ok, state, {:error, :target_busy}, []}

          true ->
            # VB6: if both players have requested trade with each other, start trade
            if target.trade_request_target == char_id do
              # Both ready -- start trade
              entity = %{
                entity
                | trade_partner_id: target_id,
                  trade_request_target: nil,
                  trade_offer_gold: 0,
                  trade_offer_items: [],
                  trade_accepted: false
              }

              target = %{
                target
                | trade_partner_id: char_id,
                  trade_request_target: nil,
                  trade_offer_gold: 0,
                  trade_offer_items: [],
                  trade_accepted: false
              }

              # `:trade_started` is an in-band session-state hint, not a wire
              # packet. Send it directly via the legacy session shim — it
              # does not use `:send_raw`.
              Helpers.send_to_session(state.sessions, char_id, :trade_started)
              Helpers.send_to_session(state.sessions, target_id, :trade_started)

              effects = [
                Effects.send(
                  char_id,
                  Encoder.encode({:user_commerce_init, %{name: target.name}})
                ),
                Effects.send(
                  target_id,
                  Encoder.encode({:user_commerce_init, %{name: entity.name}})
                )
              ]

              players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target)
              {:ok, %{state | players: players}, :ok, effects}
            else
              # First request -- store and notify target
              entity = %{entity | trade_request_target: target_id}

              effects = [
                Effects.send(
                  target_id,
                  console("#{entity.name} desea comerciar contigo.")
                )
              ]

              players = Map.put(state.players, char_id, entity)
              {:ok, %{state | players: players}, :ok, effects}
            end
        end
    end
  end

  @doc """
  Clean up trade state on both sides and emit `user_commerce_end` packets.

  Returns `{state, effects}`. Used internally by the handler entry points
  and by the failure path of `execute_trade/3`.
  """
  def end_user_trade(state, char_id) do
    case Map.get(state.players, char_id) do
      nil ->
        {state, []}

      entity ->
        partner_id = entity.trade_partner_id

        entity = %{
          entity
          | trade_partner_id: nil,
            trade_request_target: nil,
            trade_offer_gold: 0,
            trade_offer_items: [],
            trade_accepted: false
        }

        effects = [Effects.send(char_id, Encoder.encode({:user_commerce_end, %{}}))]

        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        # Also clean up partner
        if partner_id do
          case Map.get(state.players, partner_id) do
            nil ->
              {state, effects}

            partner ->
              partner = %{
                partner
                | trade_partner_id: nil,
                  trade_request_target: nil,
                  trade_offer_gold: 0,
                  trade_offer_items: [],
                  trade_accepted: false
              }

              effects =
                effects ++ [Effects.send(partner_id, Encoder.encode({:user_commerce_end, %{}}))]

              players = Map.put(state.players, partner_id, partner)
              {%{state | players: players}, effects}
          end
        else
          {state, effects}
        end
    end
  end

  defp trade_slot_update_effects(char_id, entity) do
    items =
      Enum.map(entity.trade_offer_items, fn {obj_index, amount, tags} ->
        item_def = GameData.get_item(obj_index)

        %{
          obj_index: obj_index,
          name: (item_def && item_def.name) || "",
          grh_index: (item_def && item_def.grh_index) || 0,
          amount: amount,
          elemental_tags: tags
        }
      end)

    self_packet =
      Encoder.encode(
        {:change_user_trade_slot,
         %{my_offer: true, gold: entity.trade_offer_gold, items: items}}
      )

    self_effect = Effects.send(char_id, self_packet)

    if entity.trade_partner_id do
      partner_packet =
        Encoder.encode(
          {:change_user_trade_slot,
           %{my_offer: false, gold: entity.trade_offer_gold, items: items}}
        )

      [self_effect, Effects.send(entity.trade_partner_id, partner_packet)]
    else
      [self_effect]
    end
  end

  @doc """
  Run the trade commit between `char_id` and `partner_id`.

  Returns `{state, effects}`. Validates each side's gold, persists both
  characters via `GameBackend.Characters.save_trade_snapshots/2`, and
  only mutates the in-memory inventories/gold after the DB write
  succeeds. On any failure the trade is ended with the partner's state
  untouched.
  """
  def execute_trade(state, char_id, partner_id) do
    entity = Map.get(state.players, char_id)
    partner = Map.get(state.players, partner_id)

    cond do
      entity.trade_offer_gold > entity.gold ->
        notify_effects = [
          Effects.send(char_id, console("No tienes esa cantidad de oro."))
        ]

        {state, end_effects} = end_user_trade(state, char_id)
        {state, notify_effects ++ end_effects}

      partner.trade_offer_gold > partner.gold ->
        notify_effects = [
          Effects.send(partner_id, console("No tienes esa cantidad de oro."))
        ]

        {state, end_effects} = end_user_trade(state, char_id)
        {state, notify_effects ++ end_effects}

      true ->
        # Compute post-trade state (in local vars, not yet applied)
        new_entity = %{entity | gold: entity.gold - entity.trade_offer_gold + partner.trade_offer_gold}
        new_partner = %{partner | gold: partner.gold - partner.trade_offer_gold + entity.trade_offer_gold}

        {new_entity, new_partner} = transfer_trade_items(new_entity, new_partner)
        {new_partner, new_entity} = transfer_trade_items(new_partner, new_entity)

        # Persist both players atomically BEFORE mutating in-memory state.
        # On failure, leave both players unchanged and end the trade.
        persist_result =
          try do
            GameBackend.Characters.save_trade_snapshots(new_entity, new_partner)
          rescue
            e ->
              require Logger
              Logger.error("Trade commit raised for #{char_id} <-> #{partner_id}: #{inspect(e)}")
              {:error, :exception}
          end

        case persist_result do
          :ok ->
            # DB committed — now apply to in-memory state
            new_entity = clear_trade_state(new_entity)
            new_partner = clear_trade_state(new_partner)

            notify_effects =
              notify_trade_complete_effects(char_id, partner_id, new_entity, new_partner)

            players =
              state.players |> Map.put(char_id, new_entity) |> Map.put(partner_id, new_partner)

            {%{state | players: players}, notify_effects}

          {:error, reason} ->
            require Logger
            Logger.error("Trade commit failed for #{char_id} <-> #{partner_id}: #{inspect(reason)}")

            failure_effects = [
              Effects.send(char_id, console("Comercio fallido, intente nuevamente.")),
              Effects.send(partner_id, console("Comercio fallido, intente nuevamente."))
            ]

            # End trade without modifying gold or inventory
            {state, end_effects} = end_user_trade(state, char_id)
            {state, failure_effects ++ end_effects}
        end
    end
  end

  defp clear_trade_state(entity) do
    %{
      entity
      | trade_partner_id: nil,
        trade_request_target: nil,
        trade_offer_gold: 0,
        trade_offer_items: [],
        trade_accepted: false
    }
  end

  defp notify_trade_complete_effects(char_id, partner_id, entity, partner) do
    base = [
      Effects.send(char_id, Encoder.encode({:user_commerce_end, %{}})),
      Effects.send(partner_id, Encoder.encode({:user_commerce_end, %{}})),
      Effects.send(char_id, Encoder.encode({:update_gold, %{gold: entity.gold}})),
      Effects.send(partner_id, Encoder.encode({:update_gold, %{gold: partner.gold}}))
    ]

    inventory_effects =
      Enum.flat_map(0..23, fn slot ->
        [
          inventory_slot_effect(char_id, entity.inventory, slot),
          inventory_slot_effect(partner_id, partner.inventory, slot)
        ]
      end)

    base ++ inventory_effects
  end

  def transfer_trade_items(giver, receiver) do
    Enum.reduce(giver.trade_offer_items, {giver, receiver}, fn {obj_index, amount, tags}, {g, r} ->
      # Find the slot in giver's inventory that holds this item
      slot_idx =
        Enum.find_index(g.inventory, fn
          %{item_id: ^obj_index, equipped: false} = item ->
            Map.get(item, :elemental_tags, 0) == tags

          _ ->
            false
        end)

      if slot_idx do
        case Inventory.remove_from_slot(g.inventory, slot_idx, amount) do
          {:ok, new_inv, _} ->
            case Inventory.add_item(r.inventory, obj_index, amount, tags) do
              {:ok, new_inv_r, _slot} -> {%{g | inventory: new_inv}, %{r | inventory: new_inv_r}}
              {:gold, gold_amount} -> {%{g | inventory: new_inv}, %{r | gold: r.gold + gold_amount}}
              _ -> {g, r}
            end

          _ ->
            {g, r}
        end
      else
        {g, r}
      end
    end)
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  # Mirror of `Helpers.send_inventory_slot/4` packet construction (without
  # the send_to_session shim). Inlined here so effect production stays in
  # the handler module — the legacy helper still emits `{:send_raw, _}`.
  defp inventory_slot_effect(char_id, inventory, slot) do
    packet =
      case Enum.at(inventory, slot) do
        nil ->
          Encoder.encode({:change_inventory_slot, %{slot: slot + 1, obj_index: 0, amount: 0}})

        item ->
          item_def = GameData.get_item(item.item_id)
          valor = if item_def, do: item_def.valor, else: 0
          instance_tags = Map.get(item, :elemental_tags, 0)

          Encoder.encode(
            {:change_inventory_slot,
             %{
               slot: slot + 1,
               obj_index: item.item_id,
               amount: item.amount,
               equipped: item.equipped,
               valor: valor / 1,
               elemental_tags: instance_tags
             }}
          )
      end

    Effects.send(char_id, packet)
  end
end
