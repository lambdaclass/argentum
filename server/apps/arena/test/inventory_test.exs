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

  describe "add_item/3" do
    test "adds item to first empty slot" do
      # Item 37 is "Espada corta" (ObjType 2, weapon) — non-stackable
      {:ok, inv, slot} = Inventory.add_item(@empty_inventory, 37, 1)
      assert slot == 0
      assert Enum.at(inv, 0) == %{item_id: 37, amount: 1, equipped: false}
    end

    test "adds to first empty slot when earlier slots occupied" do
      inv = List.replace_at(@empty_inventory, 0, %{item_id: 37, amount: 1, equipped: false})
      {:ok, inv2, slot} = Inventory.add_item(inv, 38, 1)
      assert slot == 1
      assert Enum.at(inv2, 1) == %{item_id: 38, amount: 1, equipped: false}
    end

    test "stacks stackable items on existing slot" do
      # Item 12 is gold (ObjType 5) — returns {:gold, amount} instead
      # Use a potion (ObjType 1 is stackable). Item 37 is ObjType 2 (weapon, not stackable).
      # We need to find a stackable item. Let's check what items have stackable types.
      # Stackable types: [1, 5, 11, 13, 32, 33, 34]
      # ObjType 1 = potions. Let's use item 37 first to see its type.
      # Actually, let's just test with a known stackable item from obj.dat.
      # Item 38 might be a potion. Let's use a safe approach: find any stackable item.
      stackable_id = find_stackable_item()

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

  describe "equip_toggle/3" do
    test "equips an equippable item" do
      # Use item 37 if it's a weapon (ObjType 2)
      equippable_id = find_equippable_item(:weapon)

      if equippable_id do
        inv = List.replace_at(@empty_inventory, 0, %{item_id: equippable_id, amount: 1, equipped: false})
        {:ok, inv2, equip2, changed} = Inventory.equip_toggle(inv, @empty_equipment, 0)
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
        {:ok, inv2, equip2, changed} = Inventory.equip_toggle(inv, equip, 0)
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
          {:ok, inv2, equip2, changed} = Inventory.equip_toggle(inv, equip, 1)

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
      assert {:error, :empty_slot} = Inventory.equip_toggle(@empty_inventory, @empty_equipment, 0)
    end

    test "returns error for non-equippable item" do
      # Find a non-equippable item (not weapon/armor/shield/helmet)
      non_equip_id = find_non_equippable_item()

      if non_equip_id do
        inv = List.replace_at(@empty_inventory, 0, %{item_id: non_equip_id, amount: 1, equipped: false})
        assert {:error, :not_equippable} = Inventory.equip_toggle(inv, @empty_equipment, 0)
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

  defp find_stackable_item do
    # Scan ETS for a stackable item that isn't gold (12)
    :ets.foldl(
      fn
        {{:item, id}, %{stackable: true}}, nil when id != 12 -> id
        _, acc -> acc
      end,
      nil,
      :arena_game_data
    )
  end

  defp find_equippable_item(slot, exclude \\ nil) do
    :ets.foldl(
      fn
        {{:item, id}, %{equip_slot: ^slot}}, nil when id != exclude -> id
        _, acc -> acc
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
end
