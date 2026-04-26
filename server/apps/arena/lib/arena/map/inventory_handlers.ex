defmodule Arena.Map.InventoryHandlers do
  @moduledoc """
  Inventory handler logic — pick up, drop, equip, use.

  All four public handlers (`handle_pick_up/2`, `handle_drop_item/4`,
  `handle_equip_item/3`, `handle_use_item/3,5`) follow the effects
  contract: they return `{:ok, state, effects}` and the MapServer
  `handle_call` dispatches via `Arena.Map.Effects.run_handler_call/2`.

  Rejection paths (dead, cooldown, empty slot, mounted, etc.) are
  communicated via console-message effects rather than non-`:ok`
  replies — same uniform shape as the migrated NpcInteraction handlers.
  """

  alias Arena.Map.{Effects, Helpers}
  alias Arena.Inventory
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  # ---- Inventory operations ----

  def handle_pick_up(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          {:ok, state, []}
        else
          entity = Helpers.break_invisibility(entity, state, char_id)
          state = %{state | players: Map.put(state.players, char_id, entity)}
          pos = {entity.x, entity.y}

          case Map.get(state.ground_items, pos) do
            nil ->
              {:ok, state, []}

            ground_item ->
              do_pick_up(state, char_id, entity, pos, ground_item)
          end
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp do_pick_up(state, char_id, entity, pos, ground_item) do
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

        # VB6: Check if this pickup completes a treasure event
        check_treasure_event(state.map_id, entity.x, entity.y, entity.name)

        effects = [
          Effects.send(char_id, Encoder.encode({:update_gold, %{gold: entity.gold}})),
          Effects.broadcast_visible_all(
            entity.x,
            entity.y,
            Encoder.encode({:object_delete, %{x: entity.x, y: entity.y}})
          )
        ]

        {:ok, state, effects}

      {:ok, new_inventory, slot} ->
        entity = %{entity | inventory: new_inventory}
        players = Map.put(state.players, char_id, entity)
        ground_items = Map.delete(state.ground_items, pos)
        state = %{state | players: players, ground_items: ground_items}

        # VB6: Check if this pickup completes a treasure event
        check_treasure_event(state.map_id, entity.x, entity.y, entity.name)

        effects = [
          Effects.send(char_id, inventory_slot_packet(new_inventory, slot)),
          Effects.broadcast_visible_all(
            entity.x,
            entity.y,
            Encoder.encode({:object_delete, %{x: entity.x, y: entity.y}})
          )
        ]

        {:ok, state, effects}

      {:error, :inventory_full} ->
        {:ok, state, [Effects.send(char_id, console("No tienes espacio en el inventario."))]}
    end
  end

  @gold_slot 200
  @gold_item_id 12
  @max_gold_drop 100_000

  def handle_drop_item(state, char_id, slot, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          # VB6: dead players cannot drop
          entity.dead ->
            {:ok, state, []}

          # D9: VB6 Comerciando — block drop while trading
          entity.trade_partner_id != nil ->
            {:ok, state,
             [Effects.send(char_id, console("No puedes tirar objetos mientras comercias."))]}

          # D9: VB6 Montado — block drop while mounted
          entity.mounted ->
            {:ok, state,
             [
               Effects.send(
                 char_id,
                 console("Debes descender de tu montura para dejar objetos en el suelo.")
               )
             ]}

          # D10: VB6 FLAGORO (slot 200) — gold drop
          slot == @gold_slot ->
            handle_gold_drop(state, char_id, entity, amount)

          true ->
            handle_item_drop(state, char_id, entity, slot, amount)
        end

      :error ->
        {:ok, state, []}
    end
  end

  # D10: Gold drop — VB6 TirarOro
  defp handle_gold_drop(state, char_id, entity, amount) do
    # VB6: cap at 100000
    drop_amount = min(amount, @max_gold_drop)

    if entity.gold < drop_amount do
      {:ok, state, [Effects.send(char_id, console("No tienes suficiente oro."))]}
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

      effects = [Effects.send(char_id, Encoder.encode({:update_gold, %{gold: entity.gold}}))]

      effects =
        if ground_amount > 0 do
          effects ++
            [
              Effects.broadcast_visible_all(
                entity.x,
                entity.y,
                object_create_packet(entity.x, entity.y, @gold_item_id, ground_amount, 0)
              )
            ]
        else
          effects
        end

      {:ok, state, effects}
    end
  end

  # Regular item drop (non-gold slots)
  defp handle_item_drop(state, char_id, entity, slot, amount) do
    pos = {entity.x, entity.y}

    case Inventory.get_slot(entity.inventory, slot) do
      nil ->
        {:ok, state, []}

      item ->
        item_def = GameData.get_item(item.item_id)

        # VB6: newbie items cannot be dropped; intirable=1 blocks drop;
        # instransferible=1 blocks drop
        cond do
          item_def != nil and item_def.newbie ->
            {:ok, state,
             [Effects.send(char_id, console("Objetos newbies no se pueden tirar."))]}

          # D11 fix: intirable=true means "non-throwable" (Intirable=1 in VB6).
          # Block when intirable IS true.
          item_def != nil and item_def.intirable ->
            {:ok, state,
             [Effects.send(char_id, console("Este objeto no se puede tirar."))]}

          # D9: instransferible items cannot be dropped
          item_def != nil and item_def.instransferible ->
            {:ok, state,
             [Effects.send(char_id, console("Este objeto no se puede tirar."))]}

          true ->
            # VB6: allow stacking same item on ground tile
            existing = Map.get(state.ground_items, pos)

            cond do
              existing != nil and existing.item_id != item.item_id ->
                {:ok, state,
                 [Effects.send(char_id, console("Ya hay otro objeto en el suelo."))]}

              true ->
                drop_amount = min(amount, item.amount)
                do_item_drop(state, char_id, entity, slot, item, item_def, existing, drop_amount)
            end
        end
    end
  end

  defp do_item_drop(state, char_id, entity, slot, item, item_def, existing, drop_amount) do
    pos = {entity.x, entity.y}

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

          effects = [Effects.send(char_id, inventory_slot_packet(new_inventory, slot))]

          effects =
            if visual_changed,
              do: effects ++ [Effects.broadcast_character_change(entity)],
              else: effects

          {:ok, state, effects}
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

          effects =
            [
              Effects.send(char_id, inventory_slot_packet(new_inventory, slot)),
              Effects.broadcast_visible_all(
                entity.x,
                entity.y,
                object_create_packet(entity.x, entity.y, item.item_id, new_amount, item_tags)
              )
            ]

          effects =
            if visual_changed,
              do: effects ++ [Effects.broadcast_character_change(entity)],
              else: effects

          {:ok, state, effects}
        end

      {:error, _reason} ->
        {:ok, state, []}
    end
  end

  def handle_equip_item(state, char_id, slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          {:ok, state, []}
        else
          do_equip(state, char_id, entity, slot)
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp do_equip(state, char_id, entity, slot) do
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

        slot_effects =
          for s <- changed_slots do
            Effects.send(char_id, inventory_slot_packet(new_inventory, s))
          end

        effects = slot_effects ++ [Effects.broadcast_character_change(entity)]

        {:ok, state, effects}

      {:error, reason} ->
        {:ok, state, [Effects.send(char_id, console(equip_error_msg(reason)))]}
    end
  end

  defp equip_error_msg(:empty_slot), do: "No hay nada en ese slot."
  defp equip_error_msg(:not_equippable), do: "No puedes equipar este objeto."
  defp equip_error_msg(:level_too_low), do: "No tienes el nivel necesario."
  defp equip_error_msg(:class_not_allowed), do: "Tu clase no puede usar este objeto."
  defp equip_error_msg(:race_not_allowed), do: "Tu raza no puede usar este objeto."
  defp equip_error_msg(_), do: "No puedes equipar este objeto."

  def handle_use_item(state, char_id, slot, target_x \\ nil, target_y \\ nil) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)

        cond do
          entity.dead ->
            {:ok, state, []}

          now < entity.next_item_use_at ->
            {:ok, state, []}

          true ->
            do_use_item(state, char_id, entity, slot, target_x, target_y, now)
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp do_use_item(state, char_id, entity, slot, target_x, target_y, now) do
    case Inventory.get_slot(entity.inventory, slot) do
      nil ->
        {:ok, state, []}

      item ->
        item_def = GameData.get_item(item.item_id)

        cond do
          item_def == nil ->
            {:ok, state, []}

          # VB6 parity (InvUsuario.bas:1877-1887): the otPotions branch
          # only gates on Muerto + IntervaloPermiteGolpeUsar. Paralizado
          # is NOT a gate for potions, so a paralyzed character can still
          # drink a cure/speed/strength potion. Every other item type
          # retains the paralyzed rejection.
          entity.paralyzed and item_def.obj_type != 1 ->
            {:ok, state, []}

          true ->
            case apply_item_use(entity, item_def, slot, state, target_x, target_y) do
              {:ok, entity, state, item_effects} ->
                entity = %{entity | next_item_use_at: now + item_use_cooldown_ms()}
                players = Map.put(state.players, char_id, entity)
                state = %{state | players: players}
                {:ok, state, item_effects}

              {:error, _reason} ->
                {:ok, state, []}
            end
        end
    end
  end

  # Apply item use effects based on obj_type
  # ObjType reference: 1=potion, 5=money, 8=food, 9=drink, 11=arrow, 13=key,
  # 14=ship, 18=working tool
  #
  # Returns {:ok, entity, state, effects} or {:error, reason}.
  def apply_item_use(entity, item_def, slot, state, target_x \\ nil, target_y \\ nil) do
    case item_def.obj_type do
      # Food
      8 ->
        new_hunger = min(entity.hunger + item_def.min_ham, 100)
        entity = %{entity | hunger: new_hunger}
        {entity, state, effects} = consume_and_notify(entity, slot, state, :hunger)
        {:ok, entity, state, effects}

      # Drink
      9 ->
        new_thirst = min(entity.thirst + item_def.min_sed, 100)
        entity = %{entity | thirst: new_thirst}
        {entity, state, effects} = consume_and_notify(entity, slot, state, :thirst)
        {:ok, entity, state, effects}

      # Potion (tipo_pocion: 1=HP, 2=Mana, 4=Stamina, 6=Strength, etc.)
      1 ->
        was_paralyzed = entity.paralyzed

        # Drift #16: DivineBlood-flagged users reject mortal HP potions
        # (VB6 InvUsuario.bas:1925-1928). We check before applying so the
        # item is NOT consumed and a console message is sent.
        if hp_potion_blocked_by_divine_blood?(entity, item_def) do
          effects = [
            Effects.send(
              entity.char_id,
              console("Tu sangre divina no puede mezclarse con la de los mortales.")
            )
          ]

          {:ok, entity, state, effects}
        else
          entity = apply_potion(entity, item_def)
          {entity, state, effects} = consume_and_notify(entity, slot, state, :potion)
          extra = paralize_cleared_effects(entity, was_paralyzed)
          {:ok, entity, state, effects ++ extra}
        end

      # VB6 otBarcos (14): toggle navigation mode
      14 ->
        new_nav = not entity.navigating
        entity = %{entity | navigating: new_nav}

        players = Map.put(state.players, entity.char_id, entity)
        state = %{state | players: players}

        effects = [
          Effects.send(entity.char_id, Encoder.encode({:navigate_toggle, %{new_state: new_nav}}))
        ]

        {:ok, entity, state, effects}

      # Working tools used for production-form opening.
      # Crafting still uses legacy send_to_session shims and returns
      # {:ok, entity, state} | {:error, reason}. We bridge by treating
      # its side effects as already-applied and emitting an empty
      # effects list — the legacy shim is what the existing crafting
      # tests assert against.
      18 ->
        case Arena.Map.Crafting.handle_tool_use(
               state,
               entity.char_id,
               entity,
               item_def.id,
               target_x,
               target_y
             ) do
          {:ok, entity, state} -> {:ok, entity, state, []}
          {:error, reason} -> {:error, reason}
        end

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
  defp paralize_cleared_effects(entity, was_paralyzed) do
    if was_paralyzed and not entity.paralyzed do
      [Effects.send(entity.char_id, Encoder.encode({:paralize_ok, %{}}))]
    else
      []
    end
  end

  # Returns {entity, state, effects} after consuming the item and emitting
  # per-effect follow-up packets. State mutation (inventory remove) happens
  # BEFORE the effects fan out so post-handler state is consistent for
  # visibility lookups. The updated entity is returned so callers can chain
  # further mutations (e.g. setting next_item_use_at) without losing the
  # consumption.
  def consume_and_notify(entity, slot, state, effect_type) do
    {:ok, new_inventory, _} = Inventory.remove_from_slot(entity.inventory, slot, 1)
    entity = %{entity | inventory: new_inventory}
    players = Map.put(state.players, entity.char_id, entity)
    state = %{state | players: players}

    base_effect = [Effects.send(entity.char_id, inventory_slot_packet(new_inventory, slot))]

    follow_ups =
      case effect_type do
        :hunger ->
          [
            Effects.send(
              entity.char_id,
              Encoder.encode(
                {:update_hunger_and_thirst,
                 %{
                   max_hunger: 100,
                   min_hunger: entity.hunger,
                   max_thirst: 100,
                   min_thirst: entity.thirst
                 }}
              )
            )
          ]

        :thirst ->
          [
            Effects.send(
              entity.char_id,
              Encoder.encode(
                {:update_hunger_and_thirst,
                 %{
                   max_hunger: 100,
                   min_hunger: entity.hunger,
                   max_thirst: 100,
                   min_thirst: entity.thirst
                 }}
              )
            )
          ]

        :potion ->
          [
            Effects.send(entity.char_id, Encoder.encode({:update_hp, %{min_hp: entity.hp}})),
            Effects.send(entity.char_id, Encoder.encode({:update_mana, %{min_mana: entity.mana}})),
            Effects.send(entity.char_id, Encoder.encode({:update_stamina, %{min_sta: entity.stamina}}))
          ]
      end

    {entity, state, base_effect ++ follow_ups}
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

  # ── Inline encode helpers (mirror Helpers.send_inventory_slot /
  #     broadcast_object_create / broadcast_object_delete) ─────────────────

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

  defp object_create_packet(x, y, item_id, amount, elemental_tags) do
    item_def = GameData.get_item(item_id)
    grh = if item_def, do: item_def.grh_index, else: 0

    Encoder.encode(
      {:object_create,
       %{x: x, y: y, obj_index: grh, amount: amount, elemental_tags: elemental_tags}}
    )
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end
end
