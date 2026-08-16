defmodule Arena.InventoryTest do
  use ExUnit.Case, async: true

  alias Arena.Inventory

  # We need GameData running for item lookups.
  # Start it once for the whole test module.
  setup_all do
    # GameData may already be started by the application; start if not
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  @empty_inventory List.duplicate(nil, 24)
  @empty_equipment %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil}
  @default_char %{level: 50, class: :guerrero, race: :humano, gender: :male}

  describe "add_item/3" do
    test "adds item to first empty slot" do
      # Item 37 is "Espada corta" (ObjType 2, weapon) — non-stackable
      {:ok, inv, slot} = Inventory.add_item(@empty_inventory, 37, 1)
      assert slot == 0
      assert Enum.at(inv, 0) == %{item_id: 37, amount: 1, equipped: false, elemental_tags: 0}
    end

    test "adds to first empty slot when earlier slots occupied" do
      inv = List.replace_at(@empty_inventory, 0, %{item_id: 37, amount: 1, equipped: false})
      {:ok, inv2, slot} = Inventory.add_item(inv, 38, 1)
      assert slot == 1
      assert Enum.at(inv2, 1) == %{item_id: 38, amount: 1, equipped: false, elemental_tags: 0}
    end

    test "stacks stackable items on existing slot" do
      stackable_id = find_stackable_item(8)

      if stackable_id do
        {:ok, inv, slot1} = Inventory.add_item(@empty_inventory, stackable_id, 5)
        assert slot1 == 0
        {:ok, inv2, slot2} = Inventory.add_item(inv, stackable_id, 3)
        assert slot2 == 0
        assert Enum.at(inv2, 0).amount == 8
      end
    end

    test "gold returns {:gold, amount}" do
      assert {:gold, 100} = Inventory.add_item(@empty_inventory, 12, 100)
    end

    test "returns error when inventory is full" do
      full = for _ <- 1..24, do: %{item_id: 37, amount: 1, equipped: false}
      assert {:error, :inventory_full} = Inventory.add_item(full, 38, 1)
    end
  end

  describe "remove_from_slot/3" do
    test "decrements amount" do
      inv = List.replace_at(@empty_inventory, 0, %{item_id: 37, amount: 5, equipped: false})
      {:ok, inv2, 0} = Inventory.remove_from_slot(inv, 0, 3)
      assert Enum.at(inv2, 0).amount == 2
    end

    test "clears slot when amount reaches 0" do
      inv = List.replace_at(@empty_inventory, 0, %{item_id: 37, amount: 1, equipped: false})
      {:ok, inv2, 0} = Inventory.remove_from_slot(inv, 0, 1)
      assert Enum.at(inv2, 0) == nil
    end

    test "returns error on empty slot" do
      assert {:error, :empty_slot} = Inventory.remove_from_slot(@empty_inventory, 0, 1)
    end

    test "returns error when removing more than available" do
      inv = List.replace_at(@empty_inventory, 0, %{item_id: 37, amount: 2, equipped: false})
      assert {:error, :insufficient_amount} = Inventory.remove_from_slot(inv, 0, 5)
    end
  end

  describe "equip_toggle/4" do
    test "equips an equippable item" do
      equippable_id = find_equippable_item(:weapon)

      if equippable_id do
        inv = List.replace_at(@empty_inventory, 0, %{item_id: equippable_id, amount: 1, equipped: false})
        {:ok, inv2, equip2, changed} = Inventory.equip_toggle(inv, @empty_equipment, 0, @default_char)
        assert Enum.at(inv2, 0).equipped == true
        assert equip2.weapon == equippable_id
        assert 0 in changed
      end
    end

    test "unequips an equipped item" do
      equippable_id = find_equippable_item(:weapon)

      if equippable_id do
        inv = List.replace_at(@empty_inventory, 0, %{item_id: equippable_id, amount: 1, equipped: true})
        equip = %{@empty_equipment | weapon: equippable_id}
        {:ok, inv2, equip2, changed} = Inventory.equip_toggle(inv, equip, 0, @default_char)
        assert Enum.at(inv2, 0).equipped == false
        assert equip2.weapon == nil
        assert 0 in changed
      end
    end

    test "swaps when equipping same slot type" do
      weapon1 = find_equippable_item(:weapon)

      if weapon1 do
        # Find a second weapon
        weapon2 = find_equippable_item(:weapon, weapon1)

        if weapon2 do
          inv =
            @empty_inventory
            |> List.replace_at(0, %{item_id: weapon1, amount: 1, equipped: true})
            |> List.replace_at(1, %{item_id: weapon2, amount: 1, equipped: false})

          equip = %{@empty_equipment | weapon: weapon1}
          {:ok, inv2, equip2, changed} = Inventory.equip_toggle(inv, equip, 1, @default_char)

          # Old weapon unequipped
          assert Enum.at(inv2, 0).equipped == false
          # New weapon equipped
          assert Enum.at(inv2, 1).equipped == true
          assert equip2.weapon == weapon2
          assert 0 in changed
          assert 1 in changed
        end
      end
    end

    test "returns error on empty slot" do
      assert {:error, :empty_slot} = Inventory.equip_toggle(@empty_inventory, @empty_equipment, 0, @default_char)
    end

    test "returns error for non-equippable item" do
      non_equip_id = find_non_equippable_item()

      if non_equip_id do
        inv = List.replace_at(@empty_inventory, 0, %{item_id: non_equip_id, amount: 1, equipped: false})
        assert {:error, :not_equippable} = Inventory.equip_toggle(inv, @empty_equipment, 0, @default_char)
      end
    end

    test "rejects equip when level is too low" do
      # Find an item with min_elv > 1
      item_id = find_item_with_level_req()

      if item_id do
        item_def = Arena.Data.GameData.get_item(item_id)
        inv = List.replace_at(@empty_inventory, 0, %{item_id: item_id, amount: 1, equipped: false})
        low_level_char = %{@default_char | level: item_def.min_elv - 1}
        assert {:error, :level_too_low} = Inventory.equip_toggle(inv, @empty_equipment, 0, low_level_char)
      end
    end

    test "allows equip when level meets requirement" do
      item_id = find_item_with_level_req()

      if item_id do
        item_def = Arena.Data.GameData.get_item(item_id)
        inv = List.replace_at(@empty_inventory, 0, %{item_id: item_id, amount: 1, equipped: false})
        ok_char = %{@default_char | level: item_def.min_elv}
        {:ok, _inv, _eq, _changed} = Inventory.equip_toggle(inv, @empty_equipment, 0, ok_char)
      end
    end

    test "rejects equip when class is forbidden" do
      item_id = find_item_with_class_restriction()

      if item_id do
        item_def = Arena.Data.GameData.get_item(item_id)
        [forbidden_class | _] = MapSet.to_list(item_def.forbidden_classes)
        inv = List.replace_at(@empty_inventory, 0, %{item_id: item_id, amount: 1, equipped: false})
        bad_char = %{@default_char | level: 50, class: String.to_atom(forbidden_class)}
        assert {:error, :class_not_allowed} = Inventory.equip_toggle(inv, @empty_equipment, 0, bad_char)
      end
    end
  end

  describe "find_empty_slot/1" do
    test "returns 0 for empty inventory" do
      assert Inventory.find_empty_slot(@empty_inventory) == 0
    end

    test "returns nil for full inventory" do
      full = for _ <- 1..24, do: %{item_id: 37, amount: 1, equipped: false}
      assert Inventory.find_empty_slot(full) == nil
    end
  end

  # --- Helpers to find real items from obj.dat ---

  # Lowest-numbered stackable item that can actually hold the amount a test
  # wants to stack.
  #
  # This used to fold over the ETS table and take whichever stackable item came
  # first. ETS iteration order is unspecified, so the chosen item varied between
  # runs — and items carry a per-item stack limit (`max_hit`, capped by
  # `add_stackable`). Whenever the run happened to pick an item with a limit
  # below the test's target, adding to the stack correctly capped and the
  # hardcoded expectation failed. That produced an intermittent failure with no
  # relation to the code under test.
  defp find_stackable_item(min_capacity) do
    :ets.foldl(
      fn
        {{:item, id}, %{stackable: true} = item}, acc when id != 12 ->
          capacity =
            case item do
              %{max_hit: max_hit} when is_integer(max_hit) and max_hit > 0 -> max_hit
              _ -> 10_000
            end

          if capacity >= min_capacity and (acc == nil or id < acc), do: id, else: acc

        _, acc ->
          acc
      end,
      nil,
      :arena_game_data
    )
  end

  defp find_equippable_item(slot, exclude \\ nil) do
    :ets.foldl(
      fn
        {{:item, id}, %{equip_slot: ^slot, forbidden_classes: nil, allowed_races: nil, min_elv: min_elv}}, nil
        when id != exclude and min_elv <= 1 ->
          id

        _, acc ->
          acc
      end,
      nil,
      :arena_game_data
    )
  end

  defp find_non_equippable_item do
    :ets.foldl(
      fn
        {{:item, id}, %{equip_slot: nil, stackable: false}}, nil -> id
        _, acc -> acc
      end,
      nil,
      :arena_game_data
    )
  end

  defp find_item_with_level_req do
    :ets.foldl(
      fn
        {{:item, id}, %{equip_slot: slot, min_elv: min_elv}}, nil
        when slot != nil and min_elv > 1 ->
          id

        _, acc ->
          acc
      end,
      nil,
      :arena_game_data
    )
  end

  defp find_item_with_class_restriction do
    :ets.foldl(
      fn
        {{:item, id}, %{equip_slot: slot, forbidden_classes: classes}}, nil
        when slot != nil and classes != nil ->
          id

        _, acc ->
          acc
      end,
      nil,
      :arena_game_data
    )
  end
end
