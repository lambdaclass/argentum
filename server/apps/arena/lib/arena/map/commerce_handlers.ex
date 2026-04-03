defmodule Arena.Map.CommerceHandlers do
  @moduledoc """
  Commerce, banking, user-to-user trade, NPC interaction, safe-toggle,
  chat/social, and stat-request handlers extracted from MapServer.

  Every function receives (and returns) the full MapServer state so the
  GenServer can delegate with a single-line call.
  """

  alias Arena.Map.{Helpers, Visibility}
  alias Arena.{Inventory, Data.GameData}
  alias AoProtocol.Server.Encoder

  @trade_max_items 10
  @npc_type_revividor 1
  @npc_type_banquero 4
  @npc_type_resucitador_newbie 9
  @yell_range_x (Application.compile_env(:arena, :aoi_range_x, 11)) * 2
  @yell_range_y (Application.compile_env(:arena, :aoi_range_y, 9)) * 2
  @bank_max_slots 40
  @magical_classes [:mage, :cleric, :druid, :bard, :paladin]

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

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  # ==================================================================
  # NPC Commerce
  # ==================================================================

  def handle_open_commerce(state, char_id, target_x, target_y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        target_occ = if target_x && target_y, do: Helpers.get_occupancy(state.occupancy, target_x, target_y)

        case target_occ do
          # VB6: target is a player -> user-to-user trade request
          {:player, target_id} when target_id != char_id ->
            start_user_trade_request(state, char_id, entity, target_id)

          # Target is NPC -> NPC commerce
          {:npc, inst_id} ->
            npc = Map.get(state.npcs_live, inst_id)
            open_npc_commerce(state, char_id, entity, npc)

          _ ->
            {:reply, {:error, :no_target}, state}
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_commerce_buy(state, char_id, slot, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        npc_id = entity.commerce_npc_id
        npc_def = if npc_id, do: GameData.get_npc(npc_id)

        if npc_def == nil or not npc_def.comercia do
          {:reply, {:error, :no_commerce}, state}
        else
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
                Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:console_msg, %{message: "No tienes suficiente oro.", font_index: 0}})})
                {:reply, {:error, :not_enough_gold}, state}
              else
                case find_inventory_slot(entity, shop_item.item_id, item_def.stackable) do
                  nil ->
                    Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:console_msg, %{message: "Inventario lleno.", font_index: 0}})})
                    {:reply, {:error, :inventory_full}, state}

                  inv_slot ->
                    entity = %{entity | gold: entity.gold - buy_price}
                    current = Enum.at(entity.inventory, inv_slot)
                    new_item = if current && current.item_id == shop_item.item_id do
                      %{current | amount: current.amount + amount}
                    else
                      %{item_id: shop_item.item_id, amount: amount, equipped: false}
                    end
                    inventory = List.replace_at(entity.inventory, inv_slot, new_item)
                    entity = %{entity | inventory: inventory}

                    Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:change_inventory_slot, %{
                        slot: inv_slot + 1,
                        obj_index: shop_item.item_id,
                        amount: new_item.amount,
                        equipped: new_item.equipped,
                        valor: item_def.valor / 1.0
                      }})})
                    Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:update_gold, %{gold: entity.gold}})})

                    players = Map.put(state.players, char_id, entity)
                    {:reply, :ok, %{state | players: players}}
                end
              end
            end
          end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_commerce_sell(state, char_id, slot, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.commerce_npc_id == nil do
          {:reply, {:error, :no_commerce}, state}
        else
          inv_idx = slot - 1
          inv_item = Enum.at(entity.inventory, inv_idx)

          cond do
            inv_item == nil ->
              {:reply, {:error, :empty_slot}, state}

            inv_item.amount < amount ->
              {:reply, {:error, :not_enough}, state}

            true ->
              item_def = GameData.get_item(inv_item.item_id)

              # VB6: newbie items cannot be sold
              cond do
                item_def != nil and item_def.newbie ->
                  Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                    Encoder.encode({:console_msg, %{message: "Objetos newbies no se pueden vender.", font_index: 0}})})
                  {:reply, {:error, :newbie_item}, state}

                true ->
              sell_price = if item_def, do: div(item_def.valor, 3) * amount, else: 0

              new_amount = inv_item.amount - amount
              inventory = if new_amount <= 0 do
                List.replace_at(entity.inventory, inv_idx, nil)
              else
                List.replace_at(entity.inventory, inv_idx, %{inv_item | amount: new_amount})
              end

              entity = %{entity | inventory: inventory, gold: entity.gold + sell_price}

              if new_amount <= 0 do
                Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:change_inventory_slot, %{slot: slot, obj_index: 0, amount: 0, equipped: false, valor: 0.0}})})
              else
                valor = if item_def, do: item_def.valor / 1.0, else: 0.0
                Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:change_inventory_slot, %{
                    slot: slot, obj_index: inv_item.item_id, amount: new_amount,
                    equipped: inv_item.equipped, valor: valor
                  }})})
              end

              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_gold, %{gold: entity.gold}})})

              players = Map.put(state.players, char_id, entity)
              {:reply, :ok, %{state | players: players}}
              end
          end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_commerce_end(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | commerce_npc_id: nil}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:commerce_end, %{}})})
        players = Map.put(state.players, char_id, entity)
        {:reply, :ok, %{state | players: players}}

      :error -> {:reply, {:error, :not_on_map}, state}
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

      abs(entity.x - npc.x) > 2 or abs(entity.y - npc.y) > 2 ->
        {:reply, {:error, :too_far}, state}

      true ->
        entity = %{entity | commerce_npc_id: npc.npc_id}

        Helpers.send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:commerce_init, %{npc_name: npc_def.name || "Comerciante"}})})

        npc_def.shop_items
        |> Enum.with_index(1)
        |> Enum.each(fn {%{item_id: item_id}, slot} ->
          item_def = GameData.get_item(item_id)
          if item_def do
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:change_npc_inventory_slot, %{
                slot: slot,
                obj_index: item_id,
                amount: 10000,
                price: item_def.valor / 1.0,
                puede_usar: 1
              }})})
          end
        end)

        players = Map.put(state.players, char_id, entity)
        {:reply, :ok, %{state | players: players}}
    end
  end

  # ==================================================================
  # Bank
  # ==================================================================

  def handle_open_bank(state, char_id, target_x, target_y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        npc = if target_x && target_y do
          case Helpers.get_occupancy(state.occupancy, target_x, target_y) do
            {:npc, inst_id} -> Map.get(state.npcs_live, inst_id)
            _ -> nil
          end
        end

        npc_def = if npc, do: GameData.get_npc(npc.npc_id)

        cond do
          npc_def == nil or npc_def.npc_type != @npc_type_banquero ->
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:console_msg, %{message: "No hay un banquero cerca.", font_index: 0}})})
            {:reply, {:error, :no_banker}, state}

          abs(entity.x - target_x) > 4 or abs(entity.y - target_y) > 4 ->
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:console_msg, %{message: "Estas demasiado lejos.", font_index: 0}})})
            {:reply, {:error, :too_far}, state}

          true ->
            # Load bank from DB
            bank_items = GameBackend.BankItems.get_bank(entity.char_id)
            bank_gold = get_bank_gold(entity.char_id)

            entity = %{entity | bank_npc_id: npc.instance_id, bank_gold: bank_gold}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            # VB6: bank_init (empty packet opens UI), then gold, then slots
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:bank_init, %{}})})
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:update_bank_gold, %{bank_gold: bank_gold}})})

            # Send each bank slot
            for bi <- bank_items do
              item_def = GameData.get_item(bi.item_id)
              valor = if item_def, do: item_def.valor, else: 0
              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:change_bank_slot, %{
                  slot: bi.slot, obj_index: bi.item_id,
                  amount: bi.amount, valor: valor
                }})})
            end

            {:reply, :ok, state}
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_deposit(state, char_id, slot, amount, slot_destino) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.bank_npc_id == nil do
          {:reply, {:error, :no_bank}, state}
        else
          inv_idx = slot - 1
          inv_item = Enum.at(entity.inventory, inv_idx)

          cond do
            inv_item == nil ->
              {:reply, {:error, :empty_slot}, state}

            inv_item.amount < amount ->
              {:reply, {:error, :not_enough}, state}

            true ->
              item_def = GameData.get_item(inv_item.item_id)

              # VB6: instransferible items cannot be banked
              if item_def != nil and item_def.instransferible do
                Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:console_msg, %{message: "No puedes depositar este objeto.", font_index: 0}})})
                {:reply, {:error, :untradeable}, state}
              else
                # Remove from inventory
                new_amount = inv_item.amount - amount
                inventory = if new_amount <= 0 do
                  List.replace_at(entity.inventory, inv_idx, nil)
                else
                  List.replace_at(entity.inventory, inv_idx, %{inv_item | amount: new_amount})
                end

                entity = %{entity | inventory: inventory}
                players = Map.put(state.players, char_id, entity)
                state = %{state | players: players}

                # Upsert into bank DB
                bank_slot = if slot_destino > 0, do: slot_destino, else: find_bank_slot(entity.char_id, inv_item.item_id)
                upsert_bank_item(entity.char_id, bank_slot, inv_item.item_id, amount)

                # Send updated inventory slot
                Helpers.send_inventory_slot(state.sessions, char_id, inventory, inv_idx)

                # Send updated bank slot
                bank_item = GameBackend.BankItems.get_bank(entity.char_id)
                  |> Enum.find(fn bi -> bi.slot == bank_slot end)
                if bank_item do
                  valor = if item_def, do: item_def.valor, else: 0
                  Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                    Encoder.encode({:change_bank_slot, %{
                      slot: bank_slot, obj_index: bank_item.item_id,
                      amount: bank_item.amount, valor: valor
                    }})})
                end

                {:reply, :ok, state}
              end
          end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_extract_item(state, char_id, slot, amount, _slot_destino) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.bank_npc_id == nil do
          {:reply, {:error, :no_bank}, state}
        else
          bank_items = GameBackend.BankItems.get_bank(entity.char_id)
          bank_item = Enum.find(bank_items, fn bi -> bi.slot == slot end)

          cond do
            bank_item == nil ->
              {:reply, {:error, :empty_bank_slot}, state}

            bank_item.amount < amount ->
              {:reply, {:error, :not_enough}, state}

            true ->
              # Add to inventory
              case Inventory.add_item(entity.inventory, bank_item.item_id, amount) do
                {:ok, new_inventory, inv_slot} ->
                  entity = %{entity | inventory: new_inventory}
                  players = Map.put(state.players, char_id, entity)
                  state = %{state | players: players}

                  # Update bank DB
                  GameBackend.BankItems.withdraw(entity.char_id, slot, amount)
                  new_bank_amount = bank_item.amount - amount
                  if new_bank_amount <= 0 do
                    Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:change_bank_slot, %{slot: slot, obj_index: 0, amount: 0, valor: 0}})})
                  else
                    item_def = GameData.get_item(bank_item.item_id)
                    valor = if item_def, do: item_def.valor, else: 0
                    Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:change_bank_slot, %{slot: slot, obj_index: bank_item.item_id, amount: new_bank_amount, valor: valor}})})
                  end

                  # Send updated inventory slot
                  Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, inv_slot)
                  {:reply, :ok, state}

                {:gold, gold_amount} ->
                  entity = %{entity | gold: entity.gold + gold_amount}
                  players = Map.put(state.players, char_id, entity)
                  state = %{state | players: players}
                  Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})})
                  {:reply, :ok, state}

                {:error, :inventory_full} ->
                  Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                    Encoder.encode({:console_msg, %{message: "No tienes espacio en tu inventario.", font_index: 0}})})
                  {:reply, {:error, :inventory_full}, state}
              end
          end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_deposit_gold(state, char_id, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.bank_npc_id == nil ->
            {:reply, {:error, :no_bank}, state}

          amount <= 0 or entity.gold < amount ->
            {:reply, {:error, :not_enough_gold}, state}

          true ->
            entity = %{entity | gold: entity.gold - amount, bank_gold: entity.bank_gold + amount}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            save_bank_gold(entity.char_id, entity.bank_gold)
            Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})})
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:update_bank_gold, %{bank_gold: entity.bank_gold}})})

            {:reply, :ok, state}
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_extract_gold(state, char_id, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.bank_npc_id == nil ->
            {:reply, {:error, :no_bank}, state}

          amount <= 0 or entity.bank_gold < amount ->
            {:reply, {:error, :not_enough_gold}, state}

          true ->
            entity = %{entity | gold: entity.gold + amount, bank_gold: entity.bank_gold - amount}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            save_bank_gold(entity.char_id, entity.bank_gold)
            Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})})
            Helpers.send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:update_bank_gold, %{bank_gold: entity.bank_gold}})})

            {:reply, :ok, state}
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_end(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | bank_npc_id: nil}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:bank_end, %{}})})
        players = Map.put(state.players, char_id, entity)
        {:reply, :ok, %{state | players: players}}

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  # Bank helpers

  def get_bank_gold(char_id) do
    case GameBackend.Characters.get(char_id) do
      nil -> 0
      char -> char.bank_gold || 0
    end
  end

  def save_bank_gold(char_id, amount) do
    GameBackend.Characters.save_snapshot(char_id, %{bank_gold: amount})
  end

  def find_bank_slot(char_id, item_id) do
    bank_items = GameBackend.BankItems.get_bank(char_id)
    # Try to stack on existing slot with same item
    case Enum.find(bank_items, fn bi -> bi.item_id == item_id end) do
      nil ->
        # Find first empty slot (1-based)
        used = MapSet.new(bank_items, & &1.slot)
        Enum.find(1..@bank_max_slots, fn s -> not MapSet.member?(used, s) end) || 1
      bi -> bi.slot
    end
  end

  def upsert_bank_item(char_id, bank_slot, item_id, amount) do
    GameBackend.BankItems.upsert(char_id, bank_slot, item_id, amount)
  end

  # ==================================================================
  # User-to-user trade
  # ==================================================================

  def handle_user_trade_offer(state, char_id, obj_index, amount) do
    case Map.fetch(state.players, char_id) do
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
            Encoder.encode({:user_commerce_init, %{}})})
          Helpers.send_to_session(state.sessions, target_id, {:send_raw,
            Encoder.encode({:user_commerce_init, %{}})})

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
      %{obj_index: obj_index, amount: amount}
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

  # ==================================================================
  # NPC interaction
  # ==================================================================

  def handle_npc_double_click(state, char_id, entity, instance_id) do
    case Map.get(state.npcs_live, instance_id) do
      nil ->
        {:noreply, state}

      npc ->
        npc_def = GameData.get_npc(npc.npc_id)

        cond do
          npc_def == nil ->
            {:noreply, state}

          # Shopkeeper -- open commerce
          npc_def.comercia ->
            # Delegate to the existing open_commerce handler via internal cast
            GenServer.cast(self(), {:open_commerce_internal, char_id, entity.x, entity.y, npc, npc_def})
            {:noreply, state}

          # Revividor / ResucitadorNewbie -- show healer prompt
          npc_def.npc_type in [@npc_type_revividor, @npc_type_resucitador_newbie] ->
            if entity.dead do
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Puedo resucitarte. Usa el comando /resucitar.", font_index: 0}})})
            else
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Puedo curarte. Usa el comando /curar.", font_index: 0}})})
            end
            {:noreply, state}

          # Banker
          npc_def.npc_type == @npc_type_banquero ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Bienvenido al banco.", font_index: 0}})})
            {:noreply, state}

          # Default: show NPC name
          true ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Ves a #{npc_def.name}.", font_index: 0}})})
            {:noreply, state}
        end
    end
  end

  def find_nearby_npc_of_type(state, entity, npc_types) do
    result =
      Enum.find_value(state.npcs_live, fn {_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)
        if npc_def != nil and
          npc_def.npc_type in npc_types and
          abs(npc.x - entity.x) <= 5 and
          abs(npc.y - entity.y) <= 5 do
          {npc, npc_def}
        end
      end)

    case result do
      {npc, npc_def} -> {:ok, npc, npc_def}
      nil -> :not_found
    end
  end

  # ==================================================================
  # Chat / Social
  # ==================================================================

  def handle_chat(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        chat_raw = Encoder.encode({:chat_over_head, %{
          message: message,
          char_index: entity.char_index,
          color: 0x00FFFFFF,
          x: entity.x,
          y: entity.y,
          min_display_time: 2000,
          max_display_time: 5000
        }})

        # Send to nearby players including the speaker
        chat_recipients =
          Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
            send(pid, {:send_raw, chat_raw})
          end)

        Arena.Metrics.inc_chat(chat_recipients)

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_yell(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
          {:noreply, state}
        else
          # VB6: yelling breaks invisibility
          entity = Helpers.break_invisibility(entity, state, char_id)
          players = Map.put(state.players, char_id, entity)

          yell_raw = Encoder.encode({:chat_over_head, %{
            message: message,
            char_index: entity.char_index,
            color: 0x00FF0000,
            x: entity.x,
            y: entity.y,
            min_display_time: 3000,
            max_display_time: 6000
          }})

          Visibility.broadcast_range(%{state | players: players}, entity.x, entity.y, @yell_range_x, @yell_range_y, fn pid ->
            send(pid, {:send_raw, yell_raw})
          end)

          {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_rest(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
            {:noreply, state}

          entity.hp >= entity.max_hp ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas sano.", font_index: 0}})})
            {:noreply, state}

          true ->
            new_resting = not entity.resting
            entity = %{entity | resting: new_resting, meditating: false}
            players = Map.put(state.players, char_id, entity)

            msg = if new_resting, do: "Has comenzado a descansar.", else: "Has dejado de descansar."
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: msg, font_index: 0}})})

            {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_meditate(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
            {:noreply, state}

          entity.class not in @magical_classes ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Solo las clases magicas pueden meditar.", font_index: 0}})})
            {:noreply, state}

          entity.mana >= entity.max_mana ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Tienes el mana completo.", font_index: 0}})})
            {:noreply, state}

          true ->
            new_meditating = not entity.meditating
            entity = %{entity | meditating: new_meditating, resting: false}
            players = Map.put(state.players, char_id, entity)

            msg = if new_meditating, do: "Has comenzado a meditar.", else: "Has dejado de meditar."
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: msg, font_index: 0}})})

            # VB6: show meditate FX (varies by level/faction; simplified to fx_id 4 here)
            if new_meditating do
              Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
                send(pid, {:send_raw, Encoder.encode({:create_fx, %{char_index: entity.char_index, fx_id: 4, loops: 0}})})
              end)
            end

            {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_heal(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
            {:noreply, state}

          entity.hp >= entity.max_hp ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas sano.", font_index: 0}})})
            {:noreply, state}

          true ->
            # VB6: heal is NPC interaction -- full heal from Revividor NPC.
            # Check if player has a targeted NPC that is a healer.
            case find_nearby_npc_of_type(state, entity, [@npc_type_revividor, @npc_type_resucitador_newbie]) do
              {:ok, _npc, npc_def} ->
                # VB6: ResucitadorNewbie only serves newbies (level <= 12)
                if npc_def.npc_type == @npc_type_resucitador_newbie and entity.level > 12 do
                  Helpers.send_to_session(state.sessions, char_id,
                    {:send_raw, Encoder.encode({:console_msg, %{message: "Solo los newbies pueden ser curados aqui.", font_index: 0}})})
                  {:noreply, state}
                else
                  entity = %{entity | hp: entity.max_hp}
                  players = Map.put(state.players, char_id, entity)

                  Helpers.send_to_session(state.sessions, char_id,
                    {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido curado.", font_index: 0}})})
                  Helpers.send_to_session(state.sessions, char_id,
                    {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})})

                  {:noreply, %{state | players: players}}
                end

              :not_found ->
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un sacerdote cerca.", font_index: 0}})})
                {:noreply, state}
            end
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_resucitate(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          # VB6: resurrection requires Revividor NPC nearby
          case find_nearby_npc_of_type(state, entity, [@npc_type_revividor, @npc_type_resucitador_newbie]) do
            {:ok, _npc, npc_def} ->
              # VB6: ResucitadorNewbie only serves newbies (level <= 12)
              if npc_def.npc_type == @npc_type_resucitador_newbie and entity.level > 12 do
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Solo los newbies pueden ser resucitados aqui.", font_index: 0}})})
                {:noreply, state}
              else
                entity = %{entity |
                  dead: false,
                  hp: entity.max_hp,
                  mana: 0,
                  buffs: [],
                  paralyzed: false,
                  poisoned: false,
                  invisible: false
                }
                players = Map.put(state.players, char_id, entity)

                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})})
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:update_mana, %{min_mana: 0}})})
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido resucitado.", font_index: 0}})})

                Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
                  send(pid, {:send_raw, Encoder.encode({:create_fx, %{char_index: entity.char_index, fx_id: 15, loops: 0}})})
                end)

                {:noreply, %{state | players: players}}
              end

            :not_found ->
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un sacerdote cerca.", font_index: 0}})})
              {:noreply, state}
          end
        else
          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "No estas muerto.", font_index: 0}})})
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_request_atributes(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:update_user_stats, %{
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
          }})})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_request_skills(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_request_mini_stats(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:mini_stats, %{
            ciudadanos_matados: 0,
            criminales_matados: 0,
            faction_status: if(entity.criminal, do: 1, else: 0),
            npcs_killed: 0,
            class: Helpers.class_to_int(entity.class),
            penalty: 0,
            deaths: 0,
            gender: if(entity.gender == :male, do: 1, else: 2),
            fishing_points: 0,
            race: Helpers.race_to_int(entity.race)
          }})})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_double_click(state, char_id, x, y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          {:noreply, state}
        else
          # VB6 uses distance <= 4 for most NPC interactions
          if abs(entity.x - x) <= 4 and abs(entity.y - y) <= 4 do
            case Helpers.get_occupancy(state.occupancy, x, y) do
              {:npc, instance_id} ->
                handle_npc_double_click(state, char_id, entity, instance_id)

              _ ->
                {:noreply, state}
            end
          else
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas demasiado lejos.", font_index: 0}})})
            {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Private helpers
  # ==================================================================

  defp find_inventory_slot(entity, item_id, stackable) do
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
end
