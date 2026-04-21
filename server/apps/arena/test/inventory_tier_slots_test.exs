defmodule Arena.InventoryTierSlotsTest do
  @moduledoc """
  Drift #5 — inventory slot count by patron tier.

  VB6 reference: `old/server/Codigo/CharacterPersistence.bas:95-109`
  (`get_num_inv_slots_from_tier`) — base 24 + 6 for Aventurero,
  +12 for Heroe, +18 for Leyenda. MAX_INVENTORY_SLOTS = 42.
  """
  use ExUnit.Case, async: true

  alias Arena.Inventory

  describe "max_slots_for_tier/1 (drift #5)" do
    test "normal tier grants base 24 slots" do
      assert Inventory.max_slots_for_tier(:normal) == 24
    end

    test "adventurer tier grants 30 slots (24 + 6)" do
      assert Inventory.max_slots_for_tier(:adventurer) == 30
    end

    test "hero tier grants 36 slots (24 + 12)" do
      assert Inventory.max_slots_for_tier(:hero) == 36
    end

    test "legend tier grants 42 slots (24 + 18 = MAX_INVENTORY_SLOTS)" do
      assert Inventory.max_slots_for_tier(:legend) == 42
    end

    test "unknown atom falls back to base 24" do
      assert Inventory.max_slots_for_tier(:unknown_tier) == 24
    end
  end

  describe "max_slots_for_entity/1 (drift #5)" do
    test "reads entity.user_tier" do
      assert Inventory.max_slots_for_entity(%{user_tier: :adventurer}) == 30
      assert Inventory.max_slots_for_entity(%{user_tier: :hero}) == 36
      assert Inventory.max_slots_for_entity(%{user_tier: :legend}) == 42
    end

    test "missing user_tier defaults to 24" do
      assert Inventory.max_slots_for_entity(%{}) == 24
    end
  end

  describe "get_slot/2 respects dynamic inventory length (drift #5)" do
    test "slot 29 is accessible in a 30-slot adventurer inventory" do
      inv = List.duplicate(nil, 30)
      item = %{item_id: 37, amount: 1, equipped: false, elemental_tags: 0}
      inv = List.replace_at(inv, 29, item)

      assert Inventory.get_slot(inv, 29) == item
    end

    test "slot 41 is accessible in a 42-slot legend inventory" do
      inv = List.duplicate(nil, 42)
      item = %{item_id: 37, amount: 1, equipped: false, elemental_tags: 0}
      inv = List.replace_at(inv, 41, item)

      assert Inventory.get_slot(inv, 41) == item
    end

    test "slot 24 is inaccessible in a 24-slot normal inventory" do
      inv = List.duplicate(nil, 24)
      assert Inventory.get_slot(inv, 24) == nil
    end
  end
end
