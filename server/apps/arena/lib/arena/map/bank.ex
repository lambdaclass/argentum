defmodule Arena.Map.Bank do
  @moduledoc "Banking handlers."

  alias Arena.Map.Helpers
  alias Arena.{Inventory, Data.GameData}
  alias AoProtocol.Server.Encoder

  @npc_type_banquero 4
  @bank_max_slots 40

  def handle_open_bank(state, char_id, target_x, target_y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:reply, {:error, :dead}, state}

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
end
