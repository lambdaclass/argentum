defmodule Arena.Inventory do
  @moduledoc """
  Pure functions for inventory and equipment operations.

  Inventory is a list of 24 slots, each nil or %{item_id: int, amount: int, equipped: bool}.
  Equipment is %{weapon: item_id | nil, armor: item_id | nil, shield: item_id | nil, helmet: item_id | nil, ring: item_id | nil}.
  """

  alias Arena.Data.GameData

  @max_slots 24
  @max_stack 10_000
  @gold_item_id 12

  @doc "Add an item to inventory. Stacks if stackable, otherwise uses first empty slot."
  def add_item(inventory, item_id, amount \\ 1, elemental_tags \\ 0) do
    item_def = GameData.get_item(item_id)

    cond do
      item_id == @gold_item_id ->
        {:gold, amount}

      item_def != nil and item_def.stackable ->
        add_stackable(inventory, item_id, amount, elemental_tags)

      true ->
        add_to_empty_slot(inventory, item_id, amount, elemental_tags)
    end
  end

  @doc "Remove `amount` from a slot. Clears slot if amount reaches 0."
  def remove_from_slot(inventory, slot, amount) do
    case get_slot(inventory, slot) do
      nil ->
        {:error, :empty_slot}

      item when item.amount < amount ->
        {:error, :insufficient_amount}

      item ->
        new_amount = item.amount - amount

        new_inventory =
          if new_amount <= 0 do
            List.replace_at(inventory, slot, nil)
          else
            List.replace_at(inventory, slot, %{item | amount: new_amount})
          end

        {:ok, new_inventory, slot}
    end
  end

  @doc """
  Toggle equip on an inventory slot with restriction checking.

  `character_info` is `%{level: int, class: atom, race: atom, gender: atom}`.
  """
  def equip_toggle(inventory, equipment, slot, character_info) do
    case get_slot(inventory, slot) do
      nil ->
        {:error, :empty_slot}

      item ->
        item_def = GameData.get_item(item.item_id)

        cond do
          item_def == nil ->
            {:error, :unknown_item}

          item_def.equip_slot == nil ->
            {:error, :not_equippable}

          item.equipped ->
            # Unequip — no restrictions
            new_item = %{item | equipped: false}
            new_inventory = List.replace_at(inventory, slot, new_item)
            new_equipment = Map.put(equipment, item_def.equip_slot, nil)
            {:ok, new_inventory, new_equipment, [slot]}

          item_def.min_elv > 0 and character_info.level < item_def.min_elv ->
            {:error, :level_too_low}

          item_def.max_elv > 0 and character_info.level > item_def.max_elv ->
            {:error, :level_too_high}

          not class_allowed?(item_def, character_info.class) ->
            {:error, :class_not_allowed}

          not race_allowed?(item_def, character_info.race) ->
            {:error, :race_not_allowed}

          not gender_allowed?(item_def, character_info.gender) ->
            {:error, :gender_not_allowed}

          true ->
            # Equip — first unequip any item in the same slot
            {new_inventory, unequipped_slots} =
              unequip_slot(inventory, equipment, item_def.equip_slot)

            # VB6: two-handed weapons auto-unequip shield
            {new_inventory, new_equipment, extra_unequipped} =
              if item_def.dos_manos and item_def.equip_slot == :weapon do
                {inv2, slots2} = unequip_slot(new_inventory, equipment, :shield)
                {inv2, Map.put(equipment, :shield, nil), slots2}
              else
                {new_inventory, equipment, []}
              end

            new_item = %{item | equipped: true}
            new_inventory = List.replace_at(new_inventory, slot, new_item)
            new_equipment = Map.put(new_equipment, item_def.equip_slot, item.item_id)
            {:ok, new_inventory, new_equipment, [slot | unequipped_slots ++ extra_unequipped]}
        end
    end
  end

  @doc "Get item at slot index."
  def get_slot(inventory, slot) when slot >= 0 and slot < @max_slots do
    Enum.at(inventory, slot)
  end

  def get_slot(_inventory, _slot), do: nil

  @doc "Find first empty slot index."
  def find_empty_slot(inventory) do
    Enum.find_index(inventory, &is_nil/1)
  end

  # --- Private ---

  defp class_allowed?(%{forbidden_classes: nil}, _), do: true

  defp class_allowed?(%{forbidden_classes: classes}, char_class) do
    not MapSet.member?(classes, to_string(char_class))
  end

  defp race_allowed?(%{allowed_races: nil}, _), do: true

  defp race_allowed?(%{allowed_races: allowed}, char_race) do
    MapSet.member?(allowed, char_race)
  end

  defp gender_allowed?(%{gender_restriction: :any}, _), do: true
  defp gender_allowed?(%{gender_restriction: required}, char_gender), do: required == char_gender

  defp add_stackable(inventory, item_id, amount, elemental_tags) do
    case find_stack_slot(inventory, item_id, elemental_tags) do
      nil ->
        add_to_empty_slot(inventory, item_id, amount, elemental_tags)

      idx ->
        item = Enum.at(inventory, idx)
        new_amount = min(item.amount + amount, @max_stack)
        new_item = %{item | amount: new_amount}
        {:ok, List.replace_at(inventory, idx, new_item), idx}
    end
  end

  defp add_to_empty_slot(inventory, item_id, amount, elemental_tags) do
    case find_empty_slot(inventory) do
      nil ->
        {:error, :inventory_full}

      idx ->
        new_item = %{item_id: item_id, amount: amount, equipped: false, elemental_tags: elemental_tags}
        {:ok, List.replace_at(inventory, idx, new_item), idx}
    end
  end

  defp find_stack_slot(inventory, item_id, elemental_tags) do
    Enum.find_index(inventory, fn
      %{item_id: ^item_id, equipped: false} = item ->
        Map.get(item, :elemental_tags, 0) == elemental_tags
      _ -> false
    end)
  end

  defp unequip_slot(inventory, equipment, equip_slot) do
    current_item_id = Map.get(equipment, equip_slot)

    if current_item_id == nil do
      {inventory, []}
    else
      # Find the equipped slot for this equip_slot
      idx =
        Enum.find_index(inventory, fn
          %{item_id: ^current_item_id, equipped: true} -> true
          _ -> false
        end)

      if idx != nil do
        item = Enum.at(inventory, idx)
        {List.replace_at(inventory, idx, %{item | equipped: false}), [idx]}
      else
        {inventory, []}
      end
    end
  end
end
