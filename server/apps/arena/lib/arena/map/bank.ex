defmodule Arena.Map.Bank do
  @moduledoc """
  Banking handlers.

  All public handlers return `{:ok, state, reply, [Effect.t()]}` —
  rich-reply variant of the effects contract. MapServer dispatches
  through `Arena.Map.Effects.run_handler_call_reply/2`, which surfaces
  `reply` to the caller (e.g. `:ok` or `{:error, reason}`) and runs the
  side-effect list against post-handler state.
  """

  alias Arena.Map.Effects
  alias Arena.{Inventory, Data.GameData}
  alias AoProtocol.Server.Encoder

  @npc_type_banquero 4
  @bank_max_slots 40
  @gold_item_id 12

  def handle_open_bank(state, char_id, target_x, target_y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, {:error, :dead}, []}

      {:ok, entity} when entity.trade_partner_id != nil ->
        {:ok, state, {:error, :already_trading}, []}

      {:ok, entity} when entity.meditating ->
        {:ok, state, {:error, :meditating}, []}

      {:ok, entity} when entity.navigating ->
        {:ok, state, {:error, :navigating}, []}

      {:ok, entity} when entity.paralyzed ->
        {:ok, state, {:error, :paralyzed}, []}

      {:ok, entity} ->
        npc =
          if target_x && target_y do
            case Arena.Map.Helpers.get_occupancy(state.occupancy, target_x, target_y) do
              {:npc, inst_id} -> Map.get(state.npcs_live, inst_id)
              _ -> nil
            end
          end

        npc_def = if npc, do: GameData.get_npc(npc.npc_id)

        cond do
          npc_def == nil or npc_def.npc_type != @npc_type_banquero ->
            {:ok, state, {:error, :no_banker},
             [Effects.send(char_id, console("No hay un banquero cerca."))]}

          abs(entity.x - target_x) > 6 or abs(entity.y - target_y) > 6 ->
            {:ok, state, {:error, :too_far},
             [Effects.send(char_id, console("Estas demasiado lejos."))]}

          true ->
            # Load bank from DB
            bank_items = GameBackend.BankItems.get_bank(entity.char_id)
            bank_gold = get_bank_gold(entity.char_id)

            entity = %{entity | bank_npc_id: npc.instance_id, bank_gold: bank_gold}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            # VB6: bank_init (empty packet opens UI), then gold, then slots
            slot_effects =
              for bi <- bank_items do
                item_def = GameData.get_item(bi.item_id)
                valor = if item_def, do: item_def.valor, else: 0

                Effects.send(
                  char_id,
                  Encoder.encode(
                    {:change_bank_slot,
                     %{
                       slot: bi.slot,
                       obj_index: bi.item_id,
                       amount: bi.amount,
                       valor: valor,
                       elemental_tags: bi.elemental_tags || 0
                     }}
                  )
                )
              end

            effects =
              [
                Effects.send(char_id, Encoder.encode({:bank_init, %{}})),
                Effects.send(
                  char_id,
                  Encoder.encode({:update_bank_gold, %{bank_gold: bank_gold}})
                )
              ] ++ slot_effects

            {:ok, state, :ok, effects}
        end

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  def handle_bank_deposit(state, char_id, slot, amount, slot_destino) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case validate_bank_session(state, entity) do
          {:error, reason} ->
            {:ok, state, {:error, reason}, []}

          :ok ->
            inv_idx = slot - 1
            inv_item = Enum.at(entity.inventory, inv_idx)

            cond do
              # VB6 parity: Cantidad > 0 (modBanco.bas:201)
              amount <= 0 ->
                {:ok, state, {:error, :invalid_amount}, []}

              # VB6 parity: validate inventory slot range. Patron tiers
              # grow the slot list beyond 24 (drift #5), so the upper bound
              # comes from the actual inventory size rather than a constant.
              slot < 1 or slot > length(entity.inventory) ->
                {:ok, state, {:error, :invalid_slot}, []}

              # VB6 parity: validate slot_destino range against bank_max_slots
              slot_destino != 0 and (slot_destino < 1 or slot_destino > @bank_max_slots) ->
                {:ok, state, {:error, :invalid_bank_slot}, []}

              inv_item == nil ->
                {:ok, state, {:error, :empty_slot}, []}

              inv_item.amount < amount ->
                {:ok, state, {:error, :not_enough}, []}

              # VB6 parity: gold is stored separately (Stats.Banco), not as bank item
              inv_item.item_id == @gold_item_id ->
                {:ok, state, {:error, :use_gold_deposit}, []}

              true ->
                item_def = GameData.get_item(inv_item.item_id)

                # VB6: instransferible items cannot be banked
                if item_def != nil and item_def.instransferible do
                  {:ok, state, {:error, :untradeable},
                   [Effects.send(char_id, console("No puedes depositar este objeto."))]}
                else
                  do_deposit_item(state, char_id, entity, inv_idx, inv_item, amount, slot_destino, item_def)
                end
            end
        end

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  defp do_deposit_item(state, char_id, entity, inv_idx, inv_item, amount, slot_destino, item_def) do
    # DB write first — only modify inventory on success
    inv_tags = Map.get(inv_item, :elemental_tags, 0)
    max_stack = max_stack_for_item(inv_item.item_id)

    # VB6 parity (modBanco.bas:223-258):
    # If slot_destino specified, validate it's either empty or
    # same item with room. Otherwise fall through to auto-search.
    bank_slot =
      if slot_destino > 0 do
        bank_items = GameBackend.BankItems.get_bank(entity.char_id)
        dest_item = Enum.find(bank_items, fn bi -> bi.slot == slot_destino end)

        cond do
          # Empty slot — valid
          dest_item == nil ->
            slot_destino

          # Same item + tags with room — valid (VB6 line 227-228)
          dest_item.item_id == inv_item.item_id and
            (dest_item.elemental_tags || 0) == inv_tags and
              dest_item.amount + amount <= max_stack ->
            slot_destino

          # Invalid — fall through to auto-search
          true ->
            find_bank_slot(entity.char_id, inv_item.item_id, inv_tags, amount)
        end
      else
        find_bank_slot(entity.char_id, inv_item.item_id, inv_tags, amount)
      end

    # VB6 parity (modBanco.bas:261): final overflow guard before writing
    bank_items = GameBackend.BankItems.get_bank(entity.char_id)
    existing_in_slot = Enum.find(bank_items, fn bi -> bi.slot == bank_slot end)
    existing_amount = if existing_in_slot, do: existing_in_slot.amount, else: 0

    if existing_amount + amount > max_stack do
      {:ok, state, {:error, :stack_full},
       [Effects.send(char_id, console("El banco no puede cargar tantos objetos."))]}
    else
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

          inv_packet = inventory_slot_packet(inventory, inv_idx)

          # Send updated bank slot
          bank_item =
            GameBackend.BankItems.get_bank(entity.char_id)
            |> Enum.find(fn bi -> bi.slot == bank_slot end)

          bank_effects =
            if bank_item do
              valor = if item_def, do: item_def.valor, else: 0

              [
                Effects.send(
                  char_id,
                  Encoder.encode(
                    {:change_bank_slot,
                     %{
                       slot: bank_slot,
                       obj_index: bank_item.item_id,
                       amount: bank_item.amount,
                       valor: valor,
                       elemental_tags: bank_item.elemental_tags || 0
                     }}
                  )
                )
              ]
            else
              []
            end

          effects = [Effects.send(char_id, inv_packet) | bank_effects]

          {:ok, state, :ok, effects}

        {:error, reason} ->
          require Logger
          Logger.error("Bank deposit failed for char #{char_id}: #{inspect(reason)}")

          {:ok, state, {:error, :db_error},
           [Effects.send(char_id, console("Error al depositar. Intenta de nuevo."))]}
      end
    end
  end

  def handle_bank_extract_item(state, char_id, slot, amount, _slot_destino) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case validate_bank_session(state, entity) do
          {:error, reason} ->
            {:ok, state, {:error, reason}, []}

          :ok ->
            cond do
              # VB6 parity: Cantidad < 1 (modBanco.bas:94)
              amount <= 0 ->
                {:ok, state, {:error, :invalid_amount}, []}

              true ->
                bank_items = GameBackend.BankItems.get_bank(entity.char_id)
                bank_item = Enum.find(bank_items, fn bi -> bi.slot == slot end)

                cond do
                  bank_item == nil ->
                    {:ok, state, {:error, :empty_bank_slot}, []}

                  bank_item.amount < amount ->
                    {:ok, state, {:error, :not_enough}, []}

                  true ->
                    do_extract_item(state, char_id, entity, slot, amount, bank_item)
                end
            end
        end

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  defp do_extract_item(state, char_id, entity, slot, amount, bank_item) do
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

            bank_slot_packet =
              if new_bank_amount <= 0 do
                Encoder.encode({:change_bank_slot, %{slot: slot, obj_index: 0, amount: 0, valor: 0}})
              else
                item_def = GameData.get_item(bank_item.item_id)
                valor = if item_def, do: item_def.valor, else: 0

                Encoder.encode(
                  {:change_bank_slot,
                   %{
                     slot: slot,
                     obj_index: bank_item.item_id,
                     amount: new_bank_amount,
                     valor: valor,
                     elemental_tags: bank_item.elemental_tags || 0
                   }}
                )
              end

            inv_packet = inventory_slot_packet(new_inventory, inv_slot)

            effects = [
              Effects.send(char_id, bank_slot_packet),
              Effects.send(char_id, inv_packet)
            ]

            {:ok, state, :ok, effects}

          {:gold, gold_amount} ->
            # VB6 parity: gold items (item_id 12) should not be in bank storage.
            entity = %{entity | gold: entity.gold + gold_amount}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            effects = [
              Effects.send(char_id, Encoder.encode({:update_gold, %{gold: entity.gold}})),
              Effects.send(
                char_id,
                Encoder.encode({:change_bank_slot, %{slot: slot, obj_index: 0, amount: 0, valor: 0}})
              )
            ]

            {:ok, state, :ok, effects}

          {:error, :inventory_full} ->
            # DB already withdrew — re-deposit to restore bank state
            upsert_bank_item(entity.char_id, slot, bank_item.item_id, amount, bank_item.elemental_tags || 0)

            {:ok, state, {:error, :inventory_full},
             [Effects.send(char_id, console("No tienes espacio en tu inventario."))]}
        end

      {:error, reason} ->
        require Logger
        Logger.error("Bank withdraw failed for char #{char_id}: #{inspect(reason)}")

        {:ok, state, {:error, :db_error},
         [Effects.send(char_id, console("Error al retirar. Intenta de nuevo."))]}
    end
  end

  def handle_bank_deposit_gold(state, char_id, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case validate_bank_session(state, entity) do
          {:error, reason} ->
            {:ok, state, {:error, reason}, []}

          :ok ->
            cond do
              amount <= 0 or entity.gold < amount ->
                {:ok, state, {:error, :not_enough_gold}, []}

              true ->
                new_bank_gold = entity.bank_gold + amount

                case save_bank_gold(entity.char_id, new_bank_gold) do
                  {:ok, _} ->
                    entity = %{entity | gold: entity.gold - amount, bank_gold: new_bank_gold}
                    players = Map.put(state.players, char_id, entity)
                    state = %{state | players: players}

                    effects = [
                      Effects.send(char_id, Encoder.encode({:update_gold, %{gold: entity.gold}})),
                      Effects.send(
                        char_id,
                        Encoder.encode({:update_bank_gold, %{bank_gold: entity.bank_gold}})
                      )
                    ]

                    {:ok, state, :ok, effects}

                  {:error, reason} ->
                    require Logger
                    Logger.error("Bank gold deposit failed for char #{char_id}: #{inspect(reason)}")

                    {:ok, state, {:error, :db_error},
                     [Effects.send(char_id, console("Error al depositar oro. Intenta de nuevo."))]}
                end
            end
        end

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  def handle_bank_extract_gold(state, char_id, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case validate_bank_session(state, entity) do
          {:error, reason} ->
            {:ok, state, {:error, reason}, []}

          :ok ->
            cond do
              amount <= 0 or entity.bank_gold < amount ->
                {:ok, state, {:error, :not_enough_gold}, []}

              true ->
                new_bank_gold = entity.bank_gold - amount

                case save_bank_gold(entity.char_id, new_bank_gold) do
                  {:ok, _} ->
                    entity = %{entity | gold: entity.gold + amount, bank_gold: new_bank_gold}
                    players = Map.put(state.players, char_id, entity)
                    state = %{state | players: players}

                    effects = [
                      Effects.send(char_id, Encoder.encode({:update_gold, %{gold: entity.gold}})),
                      Effects.send(
                        char_id,
                        Encoder.encode({:update_bank_gold, %{bank_gold: entity.bank_gold}})
                      )
                    ]

                    {:ok, state, :ok, effects}

                  {:error, reason} ->
                    require Logger
                    Logger.error("Bank gold extract failed for char #{char_id}: #{inspect(reason)}")

                    {:ok, state, {:error, :db_error},
                     [Effects.send(char_id, console("Error al retirar oro. Intenta de nuevo."))]}
                end
            end
        end

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  def handle_bank_end(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | bank_npc_id: nil}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        effects = [Effects.send(char_id, Encoder.encode({:bank_end, %{}}))]
        {:ok, state, :ok, effects}

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
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

          abs(entity.x - npc.x) > 10 or abs(entity.y - npc.y) > 10 ->
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

  def find_bank_slot(char_id, item_id, elemental_tags \\ 0, deposit_amount \\ 1) do
    bank_items = GameBackend.BankItems.get_bank(char_id)
    max_stack = max_stack_for_item(item_id)

    # VB6 parity (modBanco.bas:235-236): only match a slot if adding deposit_amount
    # would not exceed GetMaxInvOBJ() (max_stack).
    case Enum.find(bank_items, fn bi ->
           bi.item_id == item_id and
             (bi.elemental_tags || 0) == elemental_tags and
             bi.amount + deposit_amount <= max_stack
         end) do
      nil ->
        # Find first empty slot (1-based)
        used = MapSet.new(bank_items, & &1.slot)
        Enum.find(1..@bank_max_slots, fn s -> not MapSet.member?(used, s) end) || 1

      bi ->
        bi.slot
    end
  end

  @default_max_stack 10_000

  defp max_stack_for_item(item_id) do
    case GameData.get_item(item_id) do
      %{max_hit: max_hit} when is_integer(max_hit) and max_hit > 0 -> max_hit
      _ -> @default_max_stack
    end
  end

  def upsert_bank_item(char_id, bank_slot, item_id, amount, elemental_tags \\ 0) do
    max_stack = max_stack_for_item(item_id)

    try do
      GameBackend.BankItems.upsert(char_id, bank_slot, item_id, amount, elemental_tags, max_stack)
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

  # Mirror of `Helpers.send_inventory_slot/4` packet construction (sans
  # transmission). Bank handlers emit the binary packet through an
  # `Effects.send/2` effect rather than calling the legacy
  # `{:send_raw, _}` shim directly.
  defp inventory_slot_packet(inventory, slot) do
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
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end
end
