defmodule Arena.Map.InventoryHandlers do
  @moduledoc "Extracted inventory handler logic from MapServer."

  alias Arena.Map.Helpers
  alias Arena.Inventory
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  # ---- Inventory operations ----

  def handle_pick_up(state, char_id) do
    Helpers.with_player_call(state, char_id, fn entity ->
      if entity.dead do
        {:reply, {:error, :dead}, state}
      else
        entity = Helpers.break_invisibility(entity, state, char_id)
        pos = {entity.x, entity.y}

        case Map.get(state.ground_items, pos) do
          nil ->
            {:reply, {:error, :no_item}, state}

          ground_item ->
            case Inventory.add_item(
                   entity.inventory,
                   ground_item.item_id,
                   ground_item.amount,
                   Map.get(ground_item, :elemental_tags, 0)
                 ) do
              {:gold, amount} ->
                entity = %{entity | gold: entity.gold + amount}
                players = Map.put(state.players, char_id, entity)
                ground_items = Map.delete(state.ground_items, pos)
                state = %{state | players: players, ground_items: ground_items}

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
                )

                Helpers.broadcast_object_delete(state, entity.x, entity.y)

                # VB6: Check if this pickup completes a treasure event
                check_treasure_event(state.map_id, entity.x, entity.y, entity.name)

                {:reply, :ok, state}

              {:ok, new_inventory, slot} ->
                entity = %{entity | inventory: new_inventory}
                players = Map.put(state.players, char_id, entity)
                ground_items = Map.delete(state.ground_items, pos)
                state = %{state | players: players, ground_items: ground_items}

                Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, slot)
                Helpers.broadcast_object_delete(state, entity.x, entity.y)

                # VB6: Check if this pickup completes a treasure event
                check_treasure_event(state.map_id, entity.x, entity.y, entity.name)

                {:reply, :ok, state}

              {:error, :inventory_full} ->
                {:reply, {:error, :inventory_full}, state}
            end
        end
      end
    end)
  end

  @gold_slot 200
  @gold_item_id 12
  @max_gold_drop 100_000

  def handle_drop_item(state, char_id, slot, amount) do
    Helpers.with_player_call(state, char_id, fn entity ->
      cond do
        # VB6: dead players cannot drop
        entity.dead ->
          {:reply, {:error, :dead}, state}

        # D9: VB6 Comerciando — block drop while trading
        entity.trade_partner_id != nil ->
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw,
             Encoder.encode(
               {:console_msg,
                %{message: "No puedes tirar objetos mientras comercias.", font_index: 0}}
             )}
          )

          {:reply, {:error, :trading}, state}

        # D9: VB6 Montado — block drop while mounted
        entity.mounted ->
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw,
             Encoder.encode(
               {:console_msg,
                %{
                  message: "Debes descender de tu montura para dejar objetos en el suelo.",
                  font_index: 0
                }}
             )}
          )

          {:reply, {:error, :mounted}, state}

        # D10: VB6 FLAGORO (slot 200) — gold drop
        slot == @gold_slot ->
          handle_gold_drop(state, char_id, entity, amount)

        true ->
          handle_item_drop(state, char_id, entity, slot, amount)
      end
    end)
  end

  # D10: Gold drop — VB6 TirarOro
  defp handle_gold_drop(state, char_id, entity, amount) do
    # VB6: cap at 100000
    drop_amount = min(amount, @max_gold_drop)

    if entity.gold < drop_amount do
      {:reply, {:error, :insufficient_gold}, state}
    else
      pos = {entity.x, entity.y}
      entity = %{entity | gold: entity.gold - drop_amount}
      players = Map.put(state.players, char_id, entity)

      # Place gold on the ground (stack with existing gold)
      existing = Map.get(state.ground_items, pos)

      {ground_items, ground_amount} =
        cond do
          existing != nil and existing.item_id == @gold_item_id ->
            new_amount = existing.amount + drop_amount
            {Map.put(state.ground_items, pos, %{existing | amount: new_amount}), new_amount}

          existing != nil ->
            # Tile occupied by a different item; just deduct gold (VB6 tries adjacent tiles,
            # but for now we drop on the same tile or skip ground placement)
            {state.ground_items, 0}

          true ->
            item = %{item_id: @gold_item_id, amount: drop_amount, elemental_tags: 0}
            {Map.put(state.ground_items, pos, item), drop_amount}
        end

      state = %{state | players: players, ground_items: ground_items}

      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
      )

      if ground_amount > 0 do
        Helpers.broadcast_object_create(
          state,
          entity.x,
          entity.y,
          @gold_item_id,
          ground_amount,
          0
        )
      end

      {:reply, :ok, state}
    end
  end

  # Regular item drop (non-gold slots)
  defp handle_item_drop(state, char_id, entity, slot, amount) do
    pos = {entity.x, entity.y}

    case Inventory.get_slot(entity.inventory, slot) do
      nil ->
        {:reply, {:error, :empty_slot}, state}

      item ->
        item_def = GameData.get_item(item.item_id)

        # VB6: newbie items cannot be dropped; intirable=1 blocks drop;
        # instransferible=1 blocks drop
        cond do
          item_def != nil and item_def.newbie ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode(
                 {:console_msg,
                  %{message: "Objetos newbies no se pueden tirar.", font_index: 0}}
               )}
            )

            {:reply, {:error, :newbie_item}, state}

          # D11 fix: intirable=true means "non-throwable" (Intirable=1 in VB6).
          # Block when intirable IS true.
          item_def != nil and item_def.intirable ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode(
                 {:console_msg,
                  %{message: "Este objeto no se puede tirar.", font_index: 0}}
               )}
            )

            {:reply, {:error, :not_throwable}, state}

          # D9: instransferible items cannot be dropped
          item_def != nil and item_def.instransferible ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode(
                 {:console_msg, %{message: "Este objeto no se puede tirar.", font_index: 0}}
               )}
            )

            {:reply, {:error, :instransferible}, state}

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

                    new_body_id =
                      if visual_changed and item_def && item_def.equip_slot == :armor do
                        entity.base_body_id
                      else
                        entity.body_id
                      end

                    entity = %{
                      entity
                      | inventory: new_inventory,
                        equipment: new_equipment,
                        body_id: new_body_id
                    }

                    players = Map.put(state.players, char_id, entity)

                    if item_def && item_def.destruye do
                      # Destruye items are destroyed on drop, not placed on ground
                      state = %{state | players: players}
                      Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, slot)
                      if visual_changed, do: Helpers.broadcast_character_change(state, entity)
                      {:reply, :ok, state}
                    else
                      # Stack with existing ground item or create new
                      new_amount = drop_amount + if existing, do: existing.amount, else: 0
                      item_tags = Map.get(item, :elemental_tags, 0)

                      ground_items =
                        Map.put(state.ground_items, pos, %{
                          item_id: item.item_id,
                          amount: new_amount,
                          elemental_tags: item_tags
                        })

                      state = %{state | players: players, ground_items: ground_items}

                      Helpers.send_inventory_slot(
                        state.sessions,
                        char_id,
                        new_inventory,
                        slot
                      )

                      Helpers.broadcast_object_create(
                        state,
                        entity.x,
                        entity.y,
                        item.item_id,
                        new_amount,
                        item_tags
                      )

                      if visual_changed, do: Helpers.broadcast_character_change(state, entity)
                      {:reply, :ok, state}
                    end

                  {:error, reason} ->
                    {:reply, {:error, reason}, state}
                end
            end
        end
    end
  end

  def handle_equip_item(state, char_id, slot) do
    Helpers.with_player_call(state, char_id, fn entity ->
      if entity.dead do
        {:reply, {:error, :dead}, state}
      else
        character_info = %{
          level: entity.level,
          class: entity.class,
          race: entity.race,
          gender: entity.gender
        }

        case Inventory.equip_toggle(entity.inventory, entity.equipment, slot, character_info) do
          {:ok, new_inventory, new_equipment, changed_slots} ->
            new_body_id =
              if new_equipment[:armor] != entity.equipment[:armor] do
                case new_equipment[:armor] do
                  nil ->
                    entity.base_body_id

                  armor_id ->
                    item_def = GameData.get_item(armor_id)

                    if item_def && item_def.ropaje do
                      key = ropaje_key(entity.race, entity.gender)
                      Map.get(item_def.ropaje, key, entity.body_id)
                    else
                      entity.body_id
                    end
                end
              else
                entity.body_id
              end

            entity = %{entity | inventory: new_inventory, equipment: new_equipment, body_id: new_body_id}

            # VB6 26i: equipping a mount (otSaddles = 44) breaks invisible + oculto
            item = Inventory.get_slot(new_inventory, slot)
            item_def = if item, do: GameData.get_item(item.item_id)

            entity =
              if item_def && item_def.obj_type == 44 do
                entity = Helpers.break_invisibility(entity, state, char_id)

                # Toggle mount state based on whether saddle is now equipped
                saddle_equipped = new_equipment[:saddle] != nil

                if saddle_equipped do
                  # Block mounting while navigating
                  if entity.navigating do
                    entity
                  else
                    %{entity |
                      mounted: true,
                      saddle_obj_index: item.item_id,
                      saddle_slot: slot}
                  end
                else
                  %{entity | mounted: false, saddle_obj_index: 0, saddle_slot: 0}
                end
              else
                entity
              end

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
      end
    end)
  end

  def handle_use_item(state, char_id, slot, target_x \\ nil, target_y \\ nil) do
    Helpers.with_player_call(state, char_id, fn entity ->
      now = System.monotonic_time(:millisecond)

      cond do
        entity.dead ->
          {:reply, {:error, :dead}, state}

        entity.paralyzed ->
          {:reply, {:error, :paralyzed}, state}

        now < entity.next_item_use_at ->
          {:reply, {:error, :cooldown}, state}

        true ->
          case Inventory.get_slot(entity.inventory, slot) do
            nil ->
              {:reply, {:error, :empty_slot}, state}

            item ->
              item_def = GameData.get_item(item.item_id)

              if item_def == nil do
                {:reply, {:error, :unknown_item}, state}
              else
                case apply_item_use(entity, item_def, slot, state, target_x, target_y) do
                  {:ok, entity, state} ->
                    entity = %{entity | next_item_use_at: now + item_use_cooldown_ms()}
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
  # ObjType reference: 1=potion, 5=money, 8=food, 9=drink, 11=arrow, 13=key,
  # 14=ship, 18=working tool
  def apply_item_use(entity, item_def, slot, state, target_x \\ nil, target_y \\ nil) do
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
        was_paralyzed = entity.paralyzed

        # Drift #16: DivineBlood-flagged users reject mortal HP potions
        # (VB6 InvUsuario.bas:1925-1928). We check before applying so the
        # item is NOT consumed and a console message is sent.
        if hp_potion_blocked_by_divine_blood?(entity, item_def) do
          Helpers.send_to_session(
            state.sessions,
            entity.char_id,
            {:send_raw,
             Encoder.encode(
               {:console_msg,
                %{
                  message: "Tu sangre divina no puede mezclarse con la de los mortales.",
                  font_index: 0
                }}
             )}
          )

          {:ok, entity, state}
        else
          entity = apply_potion(entity, item_def)
          state = consume_and_notify(entity, slot, state, :potion)
          state = maybe_notify_paralize_cleared(state, entity, was_paralyzed)
          {:ok, entity, state}
        end

      # VB6 otBarcos (14): toggle navigation mode
      14 ->
        new_nav = not entity.navigating
        entity = %{entity | navigating: new_nav}

        Helpers.send_to_session(
          state.sessions,
          entity.char_id,
          {:send_raw, Encoder.encode({:navigate_toggle, %{new_state: new_nav}})}
        )

        players = Map.put(state.players, entity.char_id, entity)
        state = %{state | players: players}
        {:ok, entity, state}

      # Working tools used for production-form opening.
      18 ->
        Arena.Map.Crafting.handle_tool_use(
          state,
          entity.char_id,
          entity,
          item_def.id,
          target_x,
          target_y
        )

      _ ->
        {:error, :not_usable}
    end
  end

  defp item_use_cooldown_ms, do: Arena.Settings.get(:item_use_cooldown_ms)

  def apply_potion(entity, item_def) do
    amount = Enum.random(item_def.min_modificador..max(item_def.max_modificador, item_def.min_modificador))

    case item_def.tipo_pocion do
      # HP potion — VB6 InvUsuario.bas:1923-1945.
      # Drift #16: DivineBlood gate is applied by the caller (apply_item_use)
      # before reaching this function so the item is not consumed on reject.
      # Healing amount is multiplied by UserMod.GetSelfHealingBonus(U)
      #   = max(1 + Modifiers.SelfHealingBonus, 0). (Modulo_UsUaRiOs.bas:3066)
      1 ->
        bonus = get_self_healing_bonus(entity)
        healed = round(amount * bonus)
        %{entity | hp: min(entity.hp + healed, entity.max_hp)}

      # Mana potion — VB6 InvUsuario.bas:1946-1956 uses the item's Porcentaje
      # field as a percentage of max mana (not the min/max modificador range).
      2 ->
        mana_restore = div(entity.max_mana * Map.get(item_def, :porcentaje, 0), 100)
        %{entity | mana: min(entity.mana + mana_restore, entity.max_mana)}

      # Stamina potion
      4 ->
        %{entity | stamina: min(entity.stamina + amount, entity.max_stamina)}

      # Poison cure
      5 ->
        buffs = Enum.reject(entity.buffs, &(&1.type == :poisoned))
        %{entity | poisoned: false, buffs: buffs}

      # Strength potion — VB6 InvUsuario.bas:1908-1922.
      #   UserAtributos(Fuerza) = MinimoInt(Atr + rnd, AtributosBackUP * 2)
      #   flags.DuracionEfecto = obj.DuracionEfecto
      #   flags.TomoPocion = True
      # In Elixir the live attribute is modelled as `str + str_buff`, with
      # `str_backup` as the immutable base (= VB6 AtributosBackUP). So we
      # clamp the combined value at `str_backup * 2`, then store the
      # duration and raised flag. DuracionPociones (General.bas:1278)
      # restores the attribute on expiry.
      6 ->
        backup = potion_attr_backup(entity, :str)
        delta = Map.get(entity, :str_potion_delta, 0)
        spell_buff = entity.str_buff - delta
        current = entity.str + entity.str_buff
        raised = min(current + amount, backup * 2)
        new_delta = max(raised - entity.str - spell_buff, 0)
        new_buff = spell_buff + new_delta
        duration = Map.get(item_def, :duracion_efecto, 0)

        %{
          entity
          | str_buff: new_buff,
            str_potion_delta: new_delta,
            tomo_pocion: true,
            duracion_efecto: max(entity.duracion_efecto, duration)
        }

      # Agility potion — VB6 InvUsuario.bas:1893-1907 (same shape).
      7 ->
        backup = potion_attr_backup(entity, :agi)
        delta = Map.get(entity, :agi_potion_delta, 0)
        spell_buff = entity.agi_buff - delta
        current = entity.agi + entity.agi_buff
        raised = min(current + amount, backup * 2)
        new_delta = max(raised - entity.agi - spell_buff, 0)
        new_buff = spell_buff + new_delta
        duration = Map.get(item_def, :duracion_efecto, 0)

        %{
          entity
          | agi_buff: new_buff,
            agi_potion_delta: new_delta,
            tomo_pocion: true,
            duracion_efecto: max(entity.duracion_efecto, duration)
        }

      # Paralysis cure
      8 ->
        buffs = Enum.reject(entity.buffs, &(&1.type == :paralyzed))
        %{entity | paralyzed: false, buffs: buffs}

      _ ->
        entity
    end
  end

  # Drift #18 — VB6 Stats.UserAtributosBackUP is the immutable base for
  # strength/agility potion clamping. Characters that loaded before the
  # backup fields were persisted have backup == 0, so fall back to the
  # current live base attribute (which is still the un-bumped value
  # because str_buff/agi_buff are the only potion bonus).
  defp potion_attr_backup(entity, :str) do
    case Map.get(entity, :str_backup, 0) do
      n when is_integer(n) and n > 0 -> n
      _ -> entity.str
    end
  end

  defp potion_attr_backup(entity, :agi) do
    case Map.get(entity, :agi_backup, 0) do
      n when is_integer(n) and n > 0 -> n
      _ -> entity.agi
    end
  end

  # VB6 Modulo_UsUaRiOs.bas:3066
  #   GetSelfHealingBonus = max(1 + User.Modifiers.SelfHealingBonus, 0)
  # The VB6 modifier is populated purely by effects-over-time
  # (EffectsOverTime.bas:716/745); base class/race do not contribute.
  # Default Modifiers.SelfHealingBonus is 0 -> multiplier 1.0.
  # TODO: once effect-over-time buffs are ported they must write this field
  # via UpdateIncreaseModifier; today no code path mutates it, so the
  # multiplier is always 1.0 for live players.
  def get_self_healing_bonus(entity) do
    bonus = Map.get(entity, :self_healing_bonus, 0.0)
    max(1 + bonus, 0)
  end

  # VB6 InvUsuario.bas:1925 — a character with flags.DivineBlood > 0 cannot
  # use a mortal HP potion. This gate is checked by apply_item_use before
  # the potion is consumed, so the caller can skip consumption and send the
  # divine-blood console message.
  def hp_potion_blocked_by_divine_blood?(entity, item_def) do
    item_def.tipo_pocion == 1 and Map.get(entity, :divine_blood, 0) > 0
  end

  # VB6 InvUsuario.bas:1983/2149 (paralysis-cure potion) emits WriteParalizeOK
  # to the client when the Paralizado flag is cleared so the local character
  # exits the frozen animation.
  defp maybe_notify_paralize_cleared(state, entity, was_paralyzed) do
    if was_paralyzed and not entity.paralyzed do
      Helpers.send_to_session(
        state.sessions,
        entity.char_id,
        {:send_raw, Encoder.encode({:paralize_ok, %{}})}
      )
    end

    state
  end

  def consume_and_notify(entity, slot, state, effect_type) do
    {:ok, new_inventory, _} = Inventory.remove_from_slot(entity.inventory, slot, 1)
    entity = %{entity | inventory: new_inventory}
    players = Map.put(state.players, entity.char_id, entity)
    state = %{state | players: players}

    Helpers.send_inventory_slot(state.sessions, entity.char_id, new_inventory, slot)

    case effect_type do
      :hunger ->
        Helpers.send_to_session(
          state.sessions,
          entity.char_id,
          {:send_raw,
           Encoder.encode(
             {:update_hunger_and_thirst,
              %{
                max_hunger: 100,
                min_hunger: entity.hunger,
                max_thirst: 100,
                min_thirst: entity.thirst
              }}
           )}
        )

      :thirst ->
        Helpers.send_to_session(
          state.sessions,
          entity.char_id,
          {:send_raw,
           Encoder.encode(
             {:update_hunger_and_thirst,
              %{
                max_hunger: 100,
                min_hunger: entity.hunger,
                max_thirst: 100,
                min_thirst: entity.thirst
              }}
           )}
        )

      :potion ->
        Helpers.send_to_session(
          state.sessions,
          entity.char_id,
          {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.hp}})}
        )

        Helpers.send_to_session(
          state.sessions,
          entity.char_id,
          {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
        )

        Helpers.send_to_session(
          state.sessions,
          entity.char_id,
          {:send_raw, Encoder.encode({:update_stamina, %{min_sta: entity.stamina}})}
        )
    end

    state
  end

  def build_ground_items(objects) do
    objects
    |> Enum.reduce(%{}, fn obj, acc ->
      Map.put(acc, {obj.x, obj.y}, %{item_id: obj.obj_index, amount: obj.amount, elemental_tags: 0})
    end)
  end

  defp ropaje_key(race, gender) do
    suffix = if gender == "female" or gender == :female, do: "_f", else: "_m"
    race_str = to_string(race)
    String.to_atom(race_str <> suffix)
  end

  # VB6: After picking up an item, check if it completes a treasure event.
  # This is a fire-and-forget check; errors are silently ignored.
  defp check_treasure_event(map_id, x, y, player_name) do
    try do
      Arena.TreasureEvent.check_pickup(map_id, x, y, player_name)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  @doc "Speed bonus from mount tier (VB6: 10 tiers of saddle quality)."
  def mount_speed_bonus(saddle_obj_index) when saddle_obj_index > 0 do
    item_def = GameData.get_item(saddle_obj_index)
    tier = if item_def, do: max(item_def.min_hit, 1), else: 1
    # 10 tiers: 0.05 per tier up to 0.5
    min(tier * 0.05, 0.5)
  end

  def mount_speed_bonus(_), do: 0.0
end
