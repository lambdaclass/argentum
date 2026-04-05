defmodule Arena.Map.InventoryHandlers do
  @moduledoc "Extracted inventory handler logic from MapServer."

  alias Arena.Map.Helpers
  alias Arena.Inventory
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @item_use_cooldown_ms 500

  # ---- Inventory operations ----

  def handle_pick_up(state, char_id) do
    Helpers.with_player_call(state, char_id, fn entity ->
      entity = Helpers.break_invisibility(entity, state, char_id)
      pos = {entity.x, entity.y}

      case Map.get(state.ground_items, pos) do
        nil ->
          {:reply, {:error, :no_item}, state}

        ground_item ->
          case Inventory.add_item(entity.inventory, ground_item.item_id, ground_item.amount) do
            {:gold, amount} ->
              entity = %{entity | gold: entity.gold + amount}
              players = Map.put(state.players, char_id, entity)
              ground_items = Map.delete(state.ground_items, pos)
              state = %{state | players: players, ground_items: ground_items}

              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_gold, %{gold: entity.gold}})})
              Helpers.broadcast_object_delete(state, entity.x, entity.y)

              {:reply, :ok, state}

            {:ok, new_inventory, slot} ->
              entity = %{entity | inventory: new_inventory}
              players = Map.put(state.players, char_id, entity)
              ground_items = Map.delete(state.ground_items, pos)
              state = %{state | players: players, ground_items: ground_items}

              Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, slot)
              Helpers.broadcast_object_delete(state, entity.x, entity.y)

              {:reply, :ok, state}

            {:error, :inventory_full} ->
              {:reply, {:error, :inventory_full}, state}
          end
      end
    end)
  end

  def handle_drop_item(state, char_id, slot, amount) do
    Helpers.with_player_call(state, char_id, fn entity ->
      pos = {entity.x, entity.y}

      case Inventory.get_slot(entity.inventory, slot) do
        nil ->
          {:reply, {:error, :empty_slot}, state}

        item ->
          item_def = GameData.get_item(item.item_id)

          # VB6: newbie items cannot be dropped, intirable=0 means non-throwable
          cond do
            item_def != nil and item_def.newbie ->
              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:console_msg, %{message: "Objetos newbies no se pueden tirar.", font_index: 0}})})
              {:reply, {:error, :newbie_item}, state}

            item_def != nil and not item_def.intirable ->
              Helpers.send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:console_msg, %{message: "Este objeto no se puede tirar.", font_index: 0}})})
              {:reply, {:error, :not_throwable}, state}

            true ->
          # VB6: allow stacking same item on ground tile
          existing = Map.get(state.ground_items, pos)
          cond do
            existing != nil and existing.item_id != item.item_id ->
              {:reply, {:error, :tile_occupied}, state}

            true ->
              drop_amount = min(amount, item.amount)

              case Inventory.remove_from_slot(entity.inventory, slot, drop_amount) do
                {:ok, new_inventory, _slot} ->
                  # If the dropped item was equipped, clear the equipment slot
                  new_equipment =
                    if item.equipped do
                      if item_def && item_def.equip_slot do
                        Map.put(entity.equipment, item_def.equip_slot, nil)
                      else
                        entity.equipment
                      end
                    else
                      entity.equipment
                    end

                  visual_changed = item.equipped and entity.equipment != new_equipment
                  entity = %{entity | inventory: new_inventory, equipment: new_equipment}
                  players = Map.put(state.players, char_id, entity)

                  if item_def && item_def.destruye do
                    # Destruye items are destroyed on drop, not placed on ground
                    state = %{state | players: players}
                    Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, slot)
                    if visual_changed, do: Helpers.broadcast_character_change(state, entity)
                    {:reply, :ok, state}
                  else
                    # Stack with existing ground item or create new
                    new_amount = drop_amount + (if existing, do: existing.amount, else: 0)
                    ground_items = Map.put(state.ground_items, pos, %{item_id: item.item_id, amount: new_amount})
                    state = %{state | players: players, ground_items: ground_items}
                    Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, slot)
                    Helpers.broadcast_object_create(state, entity.x, entity.y, item.item_id, new_amount)
                    if visual_changed, do: Helpers.broadcast_character_change(state, entity)
                    {:reply, :ok, state}
                  end

                {:error, reason} ->
                  {:reply, {:error, reason}, state}
              end
          end
          end
      end
    end)
  end

  def handle_equip_item(state, char_id, slot) do
    Helpers.with_player_call(state, char_id, fn entity ->
      character_info = %{
        level: entity.level,
        class: entity.class,
        race: entity.race,
        gender: entity.gender
      }
      case Inventory.equip_toggle(entity.inventory, entity.equipment, slot, character_info) do
        {:ok, new_inventory, new_equipment, changed_slots} ->
          entity = %{entity | inventory: new_inventory, equipment: new_equipment}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          for s <- changed_slots do
            Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, s)
          end

          Helpers.broadcast_character_change(state, entity)

          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end)
  end

  def handle_use_item(state, char_id, slot) do
    Helpers.with_player_call(state, char_id, fn entity ->
      now = System.monotonic_time(:millisecond)

      cond do
        entity.dead -> {:reply, {:error, :dead}, state}
        entity.paralyzed -> {:reply, {:error, :paralyzed}, state}
        now < entity.next_item_use_at -> {:reply, {:error, :cooldown}, state}
        true ->
          case Inventory.get_slot(entity.inventory, slot) do
            nil ->
              {:reply, {:error, :empty_slot}, state}

            item ->
              item_def = GameData.get_item(item.item_id)

              if item_def == nil do
                {:reply, {:error, :unknown_item}, state}
              else
                case apply_item_use(entity, item_def, slot, state) do
                  {:ok, entity, state} ->
                    entity = %{entity | next_item_use_at: now + @item_use_cooldown_ms}
                    players = Map.put(state.players, char_id, entity)
                    state = %{state | players: players}
                    {:reply, :ok, state}

                  {:error, reason} ->
                    {:reply, {:error, reason}, state}
                end
              end
          end
      end
    end)
  end

  # Apply item use effects based on obj_type
  # ObjType reference: 1=potion, 5=money, 8=food, 9=drink, 11=arrow, 13=key, 14=ship
  def apply_item_use(entity, item_def, slot, state) do
    case item_def.obj_type do
      # Food
      8 ->
        new_hunger = min(entity.hunger + item_def.min_ham, 100)
        entity = %{entity | hunger: new_hunger}
        {:ok, entity, consume_and_notify(entity, slot, state, :hunger)}

      # Drink
      9 ->
        new_thirst = min(entity.thirst + item_def.min_sed, 100)
        entity = %{entity | thirst: new_thirst}
        {:ok, entity, consume_and_notify(entity, slot, state, :thirst)}

      # Potion (tipo_pocion: 1=HP, 2=Mana, 4=Stamina, 6=Strength, etc.)
      1 ->
        entity = apply_potion(entity, item_def)
        {:ok, entity, consume_and_notify(entity, slot, state, :potion)}

      # VB6 otBarcos (14): toggle navigation mode
      14 ->
        new_nav = not entity.navigating
        entity = %{entity | navigating: new_nav}
        Helpers.send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:navigate_toggle, %{new_state: new_nav}})})
        players = Map.put(state.players, entity.char_id, entity)
        state = %{state | players: players}
        {:ok, entity, state}

      _ ->
        {:error, :not_usable}
    end
  end

  def apply_potion(entity, item_def) do
    amount = Enum.random(item_def.min_modificador..max(item_def.max_modificador, item_def.min_modificador))

    case item_def.tipo_pocion do
      # HP potion
      1 -> %{entity | hp: min(entity.hp + amount, entity.max_hp)}
      # Mana potion
      2 -> %{entity | mana: min(entity.mana + amount, entity.max_mana)}
      # Stamina potion
      4 -> %{entity | stamina: min(entity.stamina + amount, entity.max_stamina)}
      # Poison cure
      5 ->
        buffs = Enum.reject(entity.buffs, &(&1.type == :poisoned))
        %{entity | poisoned: false, buffs: buffs}
      # Strength potion
      6 -> %{entity | str_buff: entity.str_buff + amount}
      # Agility potion
      7 -> %{entity | agi_buff: entity.agi_buff + amount}
      # Paralysis cure
      8 ->
        buffs = Enum.reject(entity.buffs, &(&1.type == :paralyzed))
        %{entity | paralyzed: false, buffs: buffs}
      _ -> entity
    end
  end

  def consume_and_notify(entity, slot, state, effect_type) do
    {:ok, new_inventory, _} = Inventory.remove_from_slot(entity.inventory, slot, 1)
    entity = %{entity | inventory: new_inventory}
    players = Map.put(state.players, entity.char_id, entity)
    state = %{state | players: players}

    Helpers.send_inventory_slot(state.sessions, entity.char_id, new_inventory, slot)

    case effect_type do
      :hunger ->
        Helpers.send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_hunger_and_thirst, %{
            max_hunger: 100, min_hunger: entity.hunger,
            max_thirst: 100, min_thirst: entity.thirst
          }})})

      :thirst ->
        Helpers.send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_hunger_and_thirst, %{
            max_hunger: 100, min_hunger: entity.hunger,
            max_thirst: 100, min_thirst: entity.thirst
          }})})

      :potion ->
        Helpers.send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_hp, %{min_hp: entity.hp}})})
        Helpers.send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})
        Helpers.send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_stamina, %{min_sta: entity.stamina}})})
    end

    state
  end

  def build_ground_items(objects) do
    objects
    |> Enum.reduce(%{}, fn obj, acc ->
      Map.put(acc, {obj.x, obj.y}, %{item_id: obj.obj_index, amount: obj.amount})
    end)
  end
end
