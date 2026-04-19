defmodule Arena.Map.Bank do
  @moduledoc "Banking handlers."

  alias Arena.Map.Helpers
  alias Arena.{Inventory, Data.GameData}
  alias AoProtocol.Server.Encoder

  @npc_type_banquero 4
  @bank_max_slots 40
  @gold_item_id 12

  def handle_open_bank(state, char_id, target_x, target_y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:reply, {:error, :dead}, state}

      {:ok, entity} when entity.trade_partner_id != nil ->
        {:reply, {:error, :already_trading}, state}

      {:ok, entity} when entity.meditating ->
        {:reply, {:error, :meditating}, state}

      {:ok, entity} when entity.navigating ->
        {:reply, {:error, :navigating}, state}

      {:ok, entity} when entity.paralyzed ->
        {:reply, {:error, :paralyzed}, state}

      {:ok, entity} ->
        npc =
          if target_x && target_y do
            case Helpers.get_occupancy(state.occupancy, target_x, target_y) do
              {:npc, inst_id} -> Map.get(state.npcs_live, inst_id)
              _ -> nil
            end
          end

        npc_def = if npc, do: GameData.get_npc(npc.npc_id)

        cond do
          npc_def == nil or npc_def.npc_type != @npc_type_banquero ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un banquero cerca.", font_index: 0}})}
            )

            {:reply, {:error, :no_banker}, state}

          abs(entity.x - target_x) > 6 or abs(entity.y - target_y) > 6 ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas demasiado lejos.", font_index: 0}})}
            )

            {:reply, {:error, :too_far}, state}

          true ->
            # Load bank from DB
            bank_items = GameBackend.BankItems.get_bank(entity.char_id)
            bank_gold = get_bank_gold(entity.char_id)

            entity = %{entity | bank_npc_id: npc.instance_id, bank_gold: bank_gold}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            # VB6: bank_init (empty packet opens UI), then gold, then slots
            Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:bank_init, %{}})})

            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:update_bank_gold, %{bank_gold: bank_gold}})}
            )

            # Send each bank slot
            for bi <- bank_items do
              item_def = GameData.get_item(bi.item_id)
              valor = if item_def, do: item_def.valor, else: 0

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode(
                   {:change_bank_slot,
                    %{
                      slot: bi.slot,
                      obj_index: bi.item_id,
                      amount: bi.amount,
                      valor: valor,
                      elemental_tags: bi.elemental_tags || 0
                    }}
                 )}
              )
            end

            {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_deposit(state, char_id, slot, amount, slot_destino) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case validate_bank_session(state, entity) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          :ok ->
          inv_idx = slot - 1
          inv_item = Enum.at(entity.inventory, inv_idx)

          cond do
            # VB6 parity: Cantidad > 0 (modBanco.bas:201)
            amount <= 0 ->
              {:reply, {:error, :invalid_amount}, state}

            # VB6 parity: validate inventory slot range (1..24)
            slot < 1 or slot > 24 ->
              {:reply, {:error, :invalid_slot}, state}

            # VB6 parity: validate slot_destino range against bank_max_slots
            slot_destino != 0 and (slot_destino < 1 or slot_destino > @bank_max_slots) ->
              {:reply, {:error, :invalid_bank_slot}, state}

            inv_item == nil ->
              {:reply, {:error, :empty_slot}, state}

            inv_item.amount < amount ->
              {:reply, {:error, :not_enough}, state}

            # VB6 parity: gold is stored separately (Stats.Banco), not as bank item
            inv_item.item_id == @gold_item_id ->
              {:reply, {:error, :use_gold_deposit}, state}

            true ->
              item_def = GameData.get_item(inv_item.item_id)

              # VB6: instransferible items cannot be banked
              if item_def != nil and item_def.instransferible do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode({:console_msg, %{message: "No puedes depositar este objeto.", font_index: 0}})}
                )

                {:reply, {:error, :untradeable}, state}
              else
                # DB write first — only modify inventory on success
                inv_tags = Map.get(inv_item, :elemental_tags, 0)

                bank_slot =
                  if slot_destino > 0,
                    do: slot_destino,
                    else: find_bank_slot(entity.char_id, inv_item.item_id, inv_tags)

                case upsert_bank_item(entity.char_id, bank_slot, inv_item.item_id, amount, inv_tags) do
                  {:ok, _} ->
                    # DB succeeded — now update in-memory inventory
                    new_amount = inv_item.amount - amount

                    inventory =
                      if new_amount <= 0 do
                        List.replace_at(entity.inventory, inv_idx, nil)
                      else
                        List.replace_at(entity.inventory, inv_idx, %{inv_item | amount: new_amount})
                      end

                    entity = %{entity | inventory: inventory}
                    players = Map.put(state.players, char_id, entity)
                    state = %{state | players: players}

                    # Send updated inventory slot
                    Helpers.send_inventory_slot(state.sessions, char_id, inventory, inv_idx)

                    # Send updated bank slot
                    bank_item =
                      GameBackend.BankItems.get_bank(entity.char_id)
                      |> Enum.find(fn bi -> bi.slot == bank_slot end)

                    if bank_item do
                      valor = if item_def, do: item_def.valor, else: 0

                      Helpers.send_to_session(
                        state.sessions,
                        char_id,
                        {:send_raw,
                         Encoder.encode(
                           {:change_bank_slot,
                            %{
                              slot: bank_slot,
                              obj_index: bank_item.item_id,
                              amount: bank_item.amount,
                              valor: valor,
                              elemental_tags: bank_item.elemental_tags || 0
                            }}
                         )}
                      )
                    end

                    {:reply, :ok, state}

                  {:error, reason} ->
                    require Logger
                    Logger.error("Bank deposit failed for char #{char_id}: #{inspect(reason)}")

                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw,
                       Encoder.encode({:console_msg, %{message: "Error al depositar. Intenta de nuevo.", font_index: 0}})}
                    )

                    {:reply, {:error, :db_error}, state}
                end
              end
          end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_extract_item(state, char_id, slot, amount, _slot_destino) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case validate_bank_session(state, entity) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          :ok ->
        cond do
          # VB6 parity: Cantidad < 1 (modBanco.bas:94)
          amount <= 0 ->
            {:reply, {:error, :invalid_amount}, state}

          true ->
            bank_items = GameBackend.BankItems.get_bank(entity.char_id)
            bank_item = Enum.find(bank_items, fn bi -> bi.slot == slot end)

            cond do
              bank_item == nil ->
                {:reply, {:error, :empty_bank_slot}, state}

              bank_item.amount < amount ->
                {:reply, {:error, :not_enough}, state}

              true ->
                # DB withdraw first — only modify inventory on success
                case bank_withdraw(entity.char_id, slot, amount) do
                  {:ok, _} ->
                    new_bank_amount = bank_item.amount - amount

                    # Now add to inventory (DB already committed)
                    case Inventory.add_item(entity.inventory, bank_item.item_id, amount, bank_item.elemental_tags || 0) do
                      {:ok, new_inventory, inv_slot} ->
                        entity = %{entity | inventory: new_inventory}
                        players = Map.put(state.players, char_id, entity)
                        state = %{state | players: players}

                        if new_bank_amount <= 0 do
                          Helpers.send_to_session(
                            state.sessions,
                            char_id,
                            {:send_raw, Encoder.encode({:change_bank_slot, %{slot: slot, obj_index: 0, amount: 0, valor: 0}})}
                          )
                        else
                          item_def = GameData.get_item(bank_item.item_id)
                          valor = if item_def, do: item_def.valor, else: 0

                          Helpers.send_to_session(
                            state.sessions,
                            char_id,
                            {:send_raw,
                             Encoder.encode(
                               {:change_bank_slot,
                                %{
                                  slot: slot,
                                  obj_index: bank_item.item_id,
                                  amount: new_bank_amount,
                                  valor: valor,
                                  elemental_tags: bank_item.elemental_tags || 0
                                }}
                             )}
                          )
                        end

                        # Send updated inventory slot
                        Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, inv_slot)
                        {:reply, :ok, state}

                      {:gold, gold_amount} ->
                        # VB6 parity: gold items (item_id 12) should not be in bank storage.
                        entity = %{entity | gold: entity.gold + gold_amount}
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
                          {:send_raw, Encoder.encode({:change_bank_slot, %{slot: slot, obj_index: 0, amount: 0, valor: 0}})}
                        )

                        {:reply, :ok, state}

                      {:error, :inventory_full} ->
                        # DB already withdrew — re-deposit to restore bank state
                        upsert_bank_item(entity.char_id, slot, bank_item.item_id, amount, bank_item.elemental_tags || 0)

                        Helpers.send_to_session(
                          state.sessions,
                          char_id,
                          {:send_raw,
                           Encoder.encode({:console_msg, %{message: "No tienes espacio en tu inventario.", font_index: 0}})}
                        )

                        {:reply, {:error, :inventory_full}, state}
                    end

                  {:error, reason} ->
                    require Logger
                    Logger.error("Bank withdraw failed for char #{char_id}: #{inspect(reason)}")

                    Helpers.send_to_session(
                      state.sessions,
                      char_id,
                      {:send_raw,
                       Encoder.encode({:console_msg, %{message: "Error al retirar. Intenta de nuevo.", font_index: 0}})}
                    )

                    {:reply, {:error, :db_error}, state}
                end
            end
        end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_deposit_gold(state, char_id, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case validate_bank_session(state, entity) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          :ok ->
        cond do
          amount <= 0 or entity.gold < amount ->
            {:reply, {:error, :not_enough_gold}, state}

          true ->
            new_bank_gold = entity.bank_gold + amount

            case save_bank_gold(entity.char_id, new_bank_gold) do
              {:ok, _} ->
                entity = %{entity | gold: entity.gold - amount, bank_gold: new_bank_gold}
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
                  {:send_raw, Encoder.encode({:update_bank_gold, %{bank_gold: entity.bank_gold}})}
                )

                {:reply, :ok, state}

              {:error, reason} ->
                require Logger
                Logger.error("Bank gold deposit failed for char #{char_id}: #{inspect(reason)}")

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode({:console_msg, %{message: "Error al depositar oro. Intenta de nuevo.", font_index: 0}})}
                )

                {:reply, {:error, :db_error}, state}
            end
        end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_extract_gold(state, char_id, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case validate_bank_session(state, entity) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          :ok ->
        cond do
          amount <= 0 or entity.bank_gold < amount ->
            {:reply, {:error, :not_enough_gold}, state}

          true ->
            new_bank_gold = entity.bank_gold - amount

            case save_bank_gold(entity.char_id, new_bank_gold) do
              {:ok, _} ->
                entity = %{entity | gold: entity.gold + amount, bank_gold: new_bank_gold}
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
                  {:send_raw, Encoder.encode({:update_bank_gold, %{bank_gold: entity.bank_gold}})}
                )

                {:reply, :ok, state}

              {:error, reason} ->
                require Logger
                Logger.error("Bank gold extract failed for char #{char_id}: #{inspect(reason)}")

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode({:console_msg, %{message: "Error al retirar oro. Intenta de nuevo.", font_index: 0}})}
                )

                {:reply, {:error, :db_error}, state}
            end
        end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  def handle_bank_end(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | bank_npc_id: nil}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:bank_end, %{}})})
        players = Map.put(state.players, char_id, entity)
        {:reply, :ok, %{state | players: players}}

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  # Bank helpers

  def validate_bank_session(state, entity) do
    cond do
      entity.bank_npc_id == nil ->
        {:error, :no_bank}

      true ->
        npc = Map.get(state.npcs_live, entity.bank_npc_id)

        cond do
          npc == nil ->
            {:error, :no_bank}

          abs(entity.x - npc.x) > 6 or abs(entity.y - npc.y) > 6 ->
            {:error, :too_far}

          true ->
            :ok
        end
    end
  end

  def get_bank_gold(char_id) do
    case GameBackend.Characters.get(char_id) do
      nil -> 0
      char -> char.bank_gold || 0
    end
  end

  def save_bank_gold(char_id, amount) do
    case GameBackend.Characters.save_snapshot(char_id, %{bank_gold: amount}) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end

  def find_bank_slot(char_id, item_id, elemental_tags \\ 0) do
    bank_items = GameBackend.BankItems.get_bank(char_id)
    # Try to stack on existing slot with same item AND same elemental_tags
    case Enum.find(bank_items, fn bi -> bi.item_id == item_id and (bi.elemental_tags || 0) == elemental_tags end) do
      nil ->
        # Find first empty slot (1-based)
        used = MapSet.new(bank_items, & &1.slot)
        Enum.find(1..@bank_max_slots, fn s -> not MapSet.member?(used, s) end) || 1

      bi ->
        bi.slot
    end
  end

  def upsert_bank_item(char_id, bank_slot, item_id, amount, elemental_tags \\ 0) do
    try do
      GameBackend.BankItems.upsert(char_id, bank_slot, item_id, amount, elemental_tags)
    rescue
      e -> {:error, e}
    end
  end

  defp bank_withdraw(char_id, slot, amount) do
    try do
      case GameBackend.BankItems.withdraw(char_id, slot, amount) do
        {:ok, _} = ok -> ok
        {:error, _} = err -> err
      end
    rescue
      e -> {:error, e}
    end
  end
end
