defmodule Arena.ObjDatSourceParityTest do
  @moduledoc """
  Source-data parity for `apps/arena/lib/arena/data/item_def.ex` against
  the real shipped `resources/raw/Dat/obj.dat`. Phase 1 / Item 1 of
  `ROADMAP.md` — closes the backend parity tail for:

    * Per-instance `elemental_tags` parsing on `ItemDef`.
    * Faction-exclusive item flags (`real`, `caos`) on `ItemDef`.

  These pin the loader against well-known OBJ ids so a future
  `obj.dat` shuffle or loader rename trips the test instead of silently
  drifting away from VB6.

  VB6 anchors:
    * `Declaraciones.bas` — ObjData record (ElementalTags, Real, Caos).
    * `InvUsuario.bas` — pickup / drop / trade (carries instance
      elemental_tags).
    * `ModFacciones.bas:357` — PerderItemsFaccionarios (faction strip).
  """
  use ExUnit.Case, async: true

  alias Arena.Data.{GameData, ItemDef}

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ────────────────────────────────────────────────────────────────────
  # ItemDef.from_section/2 — ElementalTags parsing
  # VB6: `Declaraciones.bas` ObjData.ElementalTags (Long bitmask).
  # ────────────────────────────────────────────────────────────────────

  describe "ItemDef.from_section/2 — ElementalTags bitmask" do
    test "missing key defaults to 0" do
      item = ItemDef.from_section(1, %{"name" => "Plain Sword", "objtype" => "2"})
      assert item.elemental_tags == 0
    end

    test "single-element bitmask (Fire=1) survives" do
      item =
        ItemDef.from_section(1, %{
          "name" => "Fire Sword",
          "objtype" => "2",
          "elementaltags" => "1"
        })

      assert item.elemental_tags == 1
    end

    test "multi-element bitmask (Fire+Water=3) survives" do
      item =
        ItemDef.from_section(1, %{
          "name" => "Dual Sword",
          "objtype" => "2",
          "elementaltags" => "3"
        })

      assert item.elemental_tags == 3
    end

    test "full bitmask (Fire+Water+Earth+Wind=15) survives" do
      item =
        ItemDef.from_section(1, %{
          "name" => "Master Sword",
          "objtype" => "2",
          "elementaltags" => "15"
        })

      assert item.elemental_tags == 15
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Shipped obj.dat — real items load with the expected Real / Caos
  # flags. The values are pinned against the VB6 baseline so a future
  # data-file revision can't silently flip a faction lock.
  # ────────────────────────────────────────────────────────────────────

  describe "shipped obj.dat — Royal Army (Real=1) items" do
    test "OBJ659 (Casco del Imperio) is flagged real" do
      item = GameData.get_item(659)
      assert item != nil, "OBJ659 must be present in obj.dat"
      assert item.real == true, "OBJ659 must load with real=true (VB6 Real=1)"
      assert item.caos == false
      # No ElementalTags key on this row; loader must default to 0.
      assert item.elemental_tags == 0
    end
  end

  describe "shipped obj.dat — Chaos Legion (Caos=1) items" do
    test "OBJ1240 (Uniforme Legionario 1ª Jerarquía) is flagged caos" do
      item = GameData.get_item(1240)
      assert item != nil, "OBJ1240 must be present in obj.dat"
      assert item.caos == true, "OBJ1240 must load with caos=true (VB6 Caos=1)"
      assert item.real == false
      assert item.elemental_tags == 0
    end
  end

  describe "shipped obj.dat — neutral items" do
    test "OBJ1 (Manzana Roja or similar) carries neither faction flag" do
      item = GameData.get_item(1)

      if item do
        assert item.real == false
        assert item.caos == false
      end
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Per-instance elemental_tags preservation through inventory paths.
  # ────────────────────────────────────────────────────────────────────

  describe "Arena.Inventory.add_item/4 — per-instance elemental_tags" do
    alias Arena.Inventory

    test "add_item keeps the elemental_tags argument on the new slot" do
      empty = List.duplicate(nil, 24)
      # Use a known stackable item id (Manzana — obj.dat OBJ1). The
      # loader covers @stackable_types so add_item routes to the
      # stackable branch, but the elemental_tags assertion is the
      # same either way.
      {:ok, inv, slot} = Inventory.add_item(empty, 1, 1, 7)
      assert %{elemental_tags: 7} = Enum.at(inv, slot)
    end

    test "stackable items only merge slots with matching elemental_tags" do
      empty = List.duplicate(nil, 24)
      {:ok, inv1, slot1} = Inventory.add_item(empty, 1, 1, 1)
      {:ok, inv2, slot2} = Inventory.add_item(inv1, 1, 1, 2)
      # Different elemental_tags must NOT stack into slot1.
      assert slot1 != slot2
      assert Enum.at(inv2, slot1).elemental_tags == 1
      assert Enum.at(inv2, slot2).elemental_tags == 2
    end

    test "stackable items DO merge into a slot with matching elemental_tags" do
      empty = List.duplicate(nil, 24)
      {:ok, inv1, slot1} = Inventory.add_item(empty, 1, 1, 5)
      {:ok, inv2, slot2} = Inventory.add_item(inv1, 1, 3, 5)
      assert slot1 == slot2
      assert Enum.at(inv2, slot1).amount == 4
      assert Enum.at(inv2, slot1).elemental_tags == 5
    end
  end
end
