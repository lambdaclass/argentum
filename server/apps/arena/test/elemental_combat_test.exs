defmodule Arena.ElementalCombatTest do
  @moduledoc """
  Tests for data-driven elemental combat modifiers.

  VB6 reference: SistemaCombate.bas CalculateElementalTagsModifiers
  Elements are bitmask flags: Fire=1, Water=2, Earth=4, Wind=8
  A 4x4 matrix (ElementalMatrixForNpcs) maps attacker-element vs defender-element
  to a damage multiplier. Both masks must be non-zero for any effect.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Arena.Combat
  alias Arena.Data.{GameData, ItemDef, NpcDef, SpellDef}

  # Element bitmask constants (VB6 e_ElementalTags)
  @fire 1
  @water 2
  @earth 4
  @wind 8

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Seed a custom elemental matrix for deterministic tests:
    #         Fire  Water  Earth  Wind
    # Fire    1.0   0.5    1.5    1.0
    # Water   1.5   1.0    1.0    0.5
    # Earth   0.5   1.0    1.0    1.5
    # Wind    1.0   1.5    0.5    1.0
    matrix = [
      [1.0, 0.5, 1.5, 1.0],
      [1.5, 1.0, 1.0, 0.5],
      [0.5, 1.0, 1.0, 1.5],
      [1.0, 1.5, 0.5, 1.0]
    ]

    for {row_vals, row_idx} <- Enum.with_index(matrix, 1) do
      for {val, col_idx} <- Enum.with_index(row_vals, 1) do
        :ets.insert(:arena_game_data, {{:elemental_matrix, row_idx, col_idx}, val})
      end
    end

    :ets.insert(:arena_game_data, {:max_element_tags, 4})

    :ok
  end

  # ------------------------------------------------------------------
  # Combat.apply_elemental_modifiers/3
  # ------------------------------------------------------------------

  describe "apply_elemental_modifiers/3" do
    test "returns damage unchanged when attacker_tags is 0" do
      assert Combat.apply_elemental_modifiers(100, 0, @fire) == 100
    end

    test "returns damage unchanged when defender_tags is 0" do
      assert Combat.apply_elemental_modifiers(100, @fire, 0) == 100
    end

    test "returns damage unchanged when both tags are 0" do
      assert Combat.apply_elemental_modifiers(100, 0, 0) == 100
    end

    test "fire vs water applies 0.5x multiplier" do
      # Matrix[1][2] = 0.5
      result = Combat.apply_elemental_modifiers(100, @fire, @water)
      assert result == 50
    end

    test "fire vs earth applies 1.5x multiplier" do
      # Matrix[1][3] = 1.5
      result = Combat.apply_elemental_modifiers(100, @fire, @earth)
      assert result == 150
    end

    test "water vs fire applies 1.5x multiplier" do
      # Matrix[2][1] = 1.5
      result = Combat.apply_elemental_modifiers(100, @water, @fire)
      assert result == 150
    end

    test "water vs wind applies 0.5x multiplier" do
      # Matrix[2][4] = 0.5
      result = Combat.apply_elemental_modifiers(100, @water, @wind)
      assert result == 50
    end

    test "earth vs fire applies 0.5x multiplier" do
      # Matrix[3][1] = 0.5
      result = Combat.apply_elemental_modifiers(100, @earth, @fire)
      assert result == 50
    end

    test "wind vs earth applies 0.5x multiplier" do
      # Matrix[4][3] = 0.5
      result = Combat.apply_elemental_modifiers(100, @wind, @earth)
      assert result == 50
    end

    test "same element uses diagonal (1.0x)" do
      assert Combat.apply_elemental_modifiers(100, @fire, @fire) == 100
      assert Combat.apply_elemental_modifiers(100, @water, @water) == 100
      assert Combat.apply_elemental_modifiers(100, @earth, @earth) == 100
      assert Combat.apply_elemental_modifiers(100, @wind, @wind) == 100
    end

    test "multi-element attacker against single-element defender applies all rows" do
      # Fire+Water (bitmask 3) vs Earth (bitmask 4)
      # Fire vs Earth = 1.5, then Water vs Earth = 1.0
      # 100 * 1.5 * 1.0 = 150
      result = Combat.apply_elemental_modifiers(100, @fire ||| @water, @earth)
      assert result == 150
    end

    test "single-element attacker vs multi-element defender applies all columns" do
      # Fire vs Water+Earth (bitmask 6)
      # Fire vs Water = 0.5, Fire vs Earth = 1.5
      # 100 * 0.5 * 1.5 = 75
      result = Combat.apply_elemental_modifiers(100, @fire, @water ||| @earth)
      assert result == 75
    end

    test "multi-element vs multi-element applies full cross product" do
      # Fire+Water vs Fire+Water
      # Fire vs Fire = 1.0, Fire vs Water = 0.5, Water vs Fire = 1.5, Water vs Water = 1.0
      # 100 * 1.0 * 0.5 * 1.5 * 1.0 = 75
      result = Combat.apply_elemental_modifiers(100, @fire ||| @water, @fire ||| @water)
      assert result == 75
    end

    test "result never goes below 0" do
      # Even with strong reduction, floor is 0
      assert Combat.apply_elemental_modifiers(1, @fire, @water) >= 0
    end

    test "zero damage stays zero regardless of multipliers" do
      assert Combat.apply_elemental_modifiers(0, @fire, @earth) == 0
    end
  end

  # ------------------------------------------------------------------
  # Data struct parsing includes elemental_tags
  # ------------------------------------------------------------------

  describe "ItemDef.from_section/2 parses elemental_tags" do
    test "parses ElementalTags from item section" do
      section = %{"name" => "Fire Sword", "objtype" => "2", "elementaltags" => "1"}
      item = ItemDef.from_section(999, section)
      assert item.elemental_tags == 1
    end

    test "defaults to 0 when ElementalTags is absent" do
      section = %{"name" => "Normal Sword", "objtype" => "2"}
      item = ItemDef.from_section(999, section)
      assert item.elemental_tags == 0
    end

    test "parses combined bitmask" do
      # Fire + Water = 3
      section = %{"name" => "Dual Sword", "objtype" => "2", "elementaltags" => "3"}
      item = ItemDef.from_section(999, section)
      assert item.elemental_tags == 3
    end
  end

  describe "NpcDef.from_section/2 parses elemental_tags" do
    test "parses ElementalTags from NPC section" do
      section = %{"name" => "Fire Golem", "elementaltags" => "1", "maxhp" => "500"}
      npc = NpcDef.from_section(999, section)
      assert npc.elemental_tags == 1
    end

    test "defaults to 0 when ElementalTags is absent" do
      section = %{"name" => "Goblin", "maxhp" => "50"}
      npc = NpcDef.from_section(999, section)
      assert npc.elemental_tags == 0
    end
  end

  describe "SpellDef.from_section/2 parses is_elemental_tags_only" do
    test "parses IsElementalTagsOnly flag" do
      section = %{"nombre" => "Elemental Blast", "iselementaltagsonly" => "1"}
      spell = SpellDef.from_section(999, section)
      assert spell.is_elemental_tags_only == true
    end

    test "defaults to false when absent" do
      section = %{"nombre" => "Fireball"}
      spell = SpellDef.from_section(999, section)
      assert spell.is_elemental_tags_only == false
    end
  end

  # ------------------------------------------------------------------
  # Elemental matrix loading from GameData
  # ------------------------------------------------------------------

  describe "GameData.elemental_matrix/2" do
    test "returns loaded matrix value" do
      # Fire vs Water = 0.5 (row 1, col 2)
      assert GameData.elemental_matrix(1, 2) == 0.5
    end

    test "returns 1.0 for unloaded entries" do
      # Row 99 was never loaded
      assert GameData.elemental_matrix(99, 99) == 1.0
    end
  end

  describe "GameData.max_element_tags/0" do
    test "returns the configured max element tags" do
      assert GameData.max_element_tags() == 4
    end
  end

  # ------------------------------------------------------------------
  # Inert behavior: no elemental data = no change
  # ------------------------------------------------------------------

  describe "inert when no elemental data present" do
    test "NPC with elemental_tags=0 receives unmodified damage" do
      # Weapon with fire, but NPC has no tags -> no modification
      damage = Combat.apply_elemental_modifiers(100, @fire, 0)
      assert damage == 100
    end

    test "weapon with no elemental tags vs elemental NPC produces unmodified damage" do
      damage = Combat.apply_elemental_modifiers(100, 0, @fire)
      assert damage == 100
    end

    test "plain weapon vs plain NPC produces unmodified damage" do
      damage = Combat.apply_elemental_modifiers(100, 0, 0)
      assert damage == 100
    end
  end
end
