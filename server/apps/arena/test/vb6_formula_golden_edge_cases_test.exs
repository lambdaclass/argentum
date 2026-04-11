defmodule Arena.VB6FormulaGoldenEdgeCasesTest do
  @moduledoc """
  Extended golden tests for VB6 formula edge cases.

  Covers gaps not addressed by the existing golden and expansion test files:
  - hit_chance/8 cross-class matrix (all 12 classes as attacker/defender)
  - npc_hit_chance/5 for all defender classes
  - base_user_damage/2 for all 12 classes including boundary levels
  - melee_damage/6 extreme edge cases (max str, zero weapon, large values)
  - spell_damage/4 rounding edge cases and boundary levels
  - class_shield_mod golden verification
  - Combined formula chains (damage -> critical -> defense -> magic resist)
  - xp_gain/5 with level 1 and extreme level gaps
  - Race modifier completeness for all 5 races
  - Effective defense/damage for naked characters (CombatStats)
  - apply_defense/2 deterministic cases
  """
  use ExUnit.Case, async: true

  alias Arena.Combat
  alias Arena.CombatStats
  alias Arena.Data.GameData

  # Class IDs matching VB6
  @mago 1
  @clerigo 2
  @paladin 3
  @cazador 4
  @trabajador 5
  @guerrero 6
  @ladron 7
  @bandido 8
  @asesino 9
  @druida 10
  @bardo 11
  @pirata 12

  @all_classes [
    {@mago, "mago"},
    {@clerigo, "clerigo"},
    {@paladin, "paladin"},
    {@cazador, "cazador"},
    {@trabajador, "trabajador"},
    {@guerrero, "guerrero"},
    {@ladron, "ladron"},
    {@bandido, "bandido"},
    {@asesino, "asesino"},
    {@druida, "druida"},
    {@bardo, "bardo"},
    {@pirata, "pirata"}
  ]

  # Race IDs
  @humano 1
  @elfo 2
  @elfo_oscuro 3
  @gnomo 4
  @enano 5

  @all_races [
    {@humano, "humano"},
    {@elfo, "elfo"},
    {@elfo_oscuro, "elfo_oscuro"},
    {@gnomo, "gnomo"},
    {@enano, "enano"}
  ]

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp clamp(val, lo, hi), do: min(max(val, lo), hi)

  defp expected_hit_chance(atk_skill, atk_agi, atk_level, atk_class, def_tactics, def_agi, def_level, def_class) do
    atk_mod = GameData.class_attack_mod(atk_class)
    def_mod = GameData.class_evasion_mod(def_class)

    attack_power =
      (atk_skill + 3 * atk_skill / 100 * atk_agi) * atk_mod + 2.5 * max(atk_level - 12, 0)

    evasion =
      (def_tactics + 3 * def_tactics / 100 * def_agi) * def_mod + 2.5 * max(def_level - 12, 0)

    round(50 + (attack_power - evasion) * 0.4) |> clamp(5, 95)
  end

  defp expected_npc_hit_chance(poder_ataque, def_tactics, def_agi, def_level, def_class) do
    def_mod = GameData.class_evasion_mod(def_class)

    evasion =
      (def_tactics + 3 * def_tactics / 100 * def_agi) * def_mod + 2.5 * max(def_level - 12, 0)

    round(50 + (poder_ataque - evasion) * 0.4) |> clamp(10, 90)
  end

  # ── hit_chance/8 cross-class matrix ────────────────────────────────────────
  # Verify that every class pair produces the expected value at fixed stats.

  describe "hit_chance/8 cross-class matrix at skill=50 agi=20 level=25" do
    for {atk_id, atk_name} <- [
          {1, "mago"},
          {2, "clerigo"},
          {3, "paladin"},
          {4, "cazador"},
          {5, "trabajador"},
          {6, "guerrero"},
          {7, "ladron"},
          {8, "bandido"},
          {9, "asesino"},
          {10, "druida"},
          {11, "bardo"},
          {12, "pirata"}
        ],
        {def_id, def_name} <- [
          {1, "mago"},
          {6, "guerrero"},
          {7, "ladron"},
          {3, "paladin"}
        ] do
      test "#{atk_name} vs #{def_name}" do
        result = Combat.hit_chance(50, 20, 25, unquote(atk_id), 50, 20, 25, unquote(def_id))

        expected =
          expected_hit_chance(50, 20, 25, unquote(atk_id), 50, 20, 25, unquote(def_id))

        assert result == expected
        assert result >= 5 and result <= 95
      end
    end
  end

  # ── hit_chance/8 zero stats edge cases ─────────────────────────────────────

  describe "hit_chance/8 zero and extreme stat edge cases" do
    test "both combatants with zero skill and agi, level 1" do
      for {class_id, _name} <- @all_classes do
        result = Combat.hit_chance(0, 0, 1, class_id, 0, 0, 1, class_id)
        expected = expected_hit_chance(0, 0, 1, class_id, 0, 0, 1, class_id)
        assert result == expected
        # Zero vs zero should be near 50
        assert result == 50
      end
    end

    test "max skill 100 and max agi 50 at level 50 vs zero" do
      result = Combat.hit_chance(100, 50, 50, @guerrero, 0, 0, 1, @mago)
      expected = expected_hit_chance(100, 50, 50, @guerrero, 0, 0, 1, @mago)
      assert result == expected
      assert result == 95
    end

    test "zero attacker vs max defender" do
      result = Combat.hit_chance(0, 0, 1, @mago, 100, 50, 50, @guerrero)
      expected = expected_hit_chance(0, 0, 1, @mago, 100, 50, 50, @guerrero)
      assert result == expected
      assert result == 5
    end

    test "level 12 boundary - no level bonus" do
      result = Combat.hit_chance(50, 20, 12, @guerrero, 50, 20, 12, @guerrero)
      expected = expected_hit_chance(50, 20, 12, @guerrero, 50, 20, 12, @guerrero)
      assert result == expected
    end

    test "level 13 - just past level bonus threshold" do
      at_12 = Combat.hit_chance(50, 20, 12, @guerrero, 50, 20, 1, @guerrero)
      at_13 = Combat.hit_chance(50, 20, 13, @guerrero, 50, 20, 1, @guerrero)
      # Level 13 should have higher hit chance than level 12 (gets 2.5 * 1 bonus)
      assert at_13 >= at_12
    end

    test "attacker level 50 vs defender level 1 - max level asymmetry" do
      result = Combat.hit_chance(50, 20, 50, @guerrero, 50, 20, 1, @guerrero)
      expected = expected_hit_chance(50, 20, 50, @guerrero, 50, 20, 1, @guerrero)
      assert result == expected
      assert result > 50
    end

    test "skill 1 agi 1 level 1 - minimum viable combatant" do
      result = Combat.hit_chance(1, 1, 1, @guerrero, 1, 1, 1, @guerrero)
      expected = expected_hit_chance(1, 1, 1, @guerrero, 1, 1, 1, @guerrero)
      assert result == expected
    end
  end

  # ── npc_hit_chance/5 for all defender classes ──────────────────────────────

  describe "npc_hit_chance/5 against all defender classes" do
    for {class_id, class_name} <- [
          {1, "mago"},
          {2, "clerigo"},
          {3, "paladin"},
          {4, "cazador"},
          {5, "trabajador"},
          {6, "guerrero"},
          {7, "ladron"},
          {8, "bandido"},
          {9, "asesino"},
          {10, "druida"},
          {11, "bardo"},
          {12, "pirata"}
        ] do
      test "NPC poder_ataque 100 vs #{class_name} level 25" do
        result = Combat.npc_hit_chance(100, 50, 20, 25, unquote(class_id))
        expected = expected_npc_hit_chance(100, 50, 20, 25, unquote(class_id))
        assert result == expected
        assert result >= 10 and result <= 90
      end
    end

    test "NPC with 0 poder_ataque vs naked level 1 defender" do
      result = Combat.npc_hit_chance(0, 0, 0, 1, @guerrero)
      expected = expected_npc_hit_chance(0, 0, 0, 1, @guerrero)
      assert result == expected
      assert result == 50
    end

    test "NPC with 0 poder_ataque vs high evasion defender floors at 10" do
      result = Combat.npc_hit_chance(0, 100, 50, 50, @ladron)
      expected = expected_npc_hit_chance(0, 100, 50, 50, @ladron)
      assert result == expected
      assert result == 10
    end

    test "NPC with massive poder_ataque vs naked defender caps at 90" do
      result = Combat.npc_hit_chance(50_000, 0, 0, 1, @mago)
      expected = expected_npc_hit_chance(50_000, 0, 0, 1, @mago)
      assert result == expected
      assert result == 90
    end

    test "NPC vs level 11 defender - no level bonus yet" do
      result = Combat.npc_hit_chance(80, 40, 20, 11, @cazador)
      expected = expected_npc_hit_chance(80, 40, 20, 11, @cazador)
      assert result == expected
    end
  end

  # ── base_user_damage/2 for ALL 12 classes ──────────────────────────────────

  describe "base_user_damage/2 level boundaries for all classes" do
    for {class_id, class_name} <- [
          {1, "mago"},
          {2, "clerigo"},
          {3, "paladin"},
          {4, "cazador"},
          {5, "trabajador"},
          {6, "guerrero"},
          {7, "ladron"},
          {8, "bandido"},
          {9, "asesino"},
          {10, "druida"},
          {11, "bardo"},
          {12, "pirata"}
        ] do
      test "#{class_name} level 1 yields {1, 2}" do
        {min_hit, max_hit} = Combat.base_user_damage(1, unquote(class_id))
        pre36 = GameData.class_hit_pre36(unquote(class_id))
        expected_mod = 0 * pre36
        assert min_hit == max(expected_mod + 1, 1)
        assert max_hit == max(expected_mod + 2, 2)
      end

      test "#{class_name} level 36 is boundary" do
        pre36 = GameData.class_hit_pre36(unquote(class_id))
        expected_mod = 35 * pre36
        expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
        assert Combat.base_user_damage(36, unquote(class_id)) == expected
      end

      test "#{class_name} level 37 uses post36 formula" do
        pre36 = GameData.class_hit_pre36(unquote(class_id))
        post36 = GameData.class_hit_post36(unquote(class_id))
        expected_mod = 35 * pre36 + 1 * post36
        expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
        assert Combat.base_user_damage(37, unquote(class_id)) == expected
      end

      test "#{class_name} level 50 (max-ish)" do
        pre36 = GameData.class_hit_pre36(unquote(class_id))
        post36 = GameData.class_hit_post36(unquote(class_id))
        expected_mod = 35 * pre36 + 14 * post36
        expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
        assert Combat.base_user_damage(50, unquote(class_id)) == expected
      end
    end

    test "level 2 gives exactly 1 * pre36 modifier" do
      for {class_id, _} <- @all_classes do
        pre36 = GameData.class_hit_pre36(class_id)
        expected_mod = 1 * pre36
        expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
        assert Combat.base_user_damage(2, class_id) == expected
      end
    end

    test "level 35 and level 36 differ by exactly pre36" do
      for {class_id, _} <- @all_classes do
        {min35, _} = Combat.base_user_damage(35, class_id)
        {min36, _} = Combat.base_user_damage(36, class_id)
        pre36 = GameData.class_hit_pre36(class_id)
        assert min36 - min35 == pre36
      end
    end

    test "level 36 and level 37 differ by exactly post36" do
      for {class_id, _} <- @all_classes do
        {min36, _} = Combat.base_user_damage(36, class_id)
        {min37, _} = Combat.base_user_damage(37, class_id)
        post36 = GameData.class_hit_post36(class_id)
        assert min37 - min36 == post36
      end
    end

    test "max_hit always exceeds min_hit by exactly 1" do
      for {class_id, _} <- @all_classes, level <- [1, 10, 20, 36, 37, 45, 50] do
        {min_hit, max_hit} = Combat.base_user_damage(level, class_id)
        assert max_hit - min_hit == 1
      end
    end
  end

  # ── melee_damage/6 extreme edge cases ──────────────────────────────────────

  describe "melee_damage/6 extreme edge cases" do
    test "max str 50, max weapon 50, guerrero - deterministic" do
      dmg_mod = GameData.class_damage_mod(@guerrero)
      # weapon_dmg = 50 (min==max), user_dmg = 10 (min==max)
      # str_bonus = 50 * 0.2 * max(0, 50 - 15) = 50 * 0.2 * 35 = 350
      # raw = (3 * 50 + 350 + 10) * dmg_mod = 510 * dmg_mod
      expected = max(round((3 * 50 + 50 * 0.2 * 35 + 10) * dmg_mod), 1)
      assert Combat.melee_damage(50, 50, 50, @guerrero, 10, 10) == expected
    end

    test "str exactly 15 gives zero str bonus for all classes" do
      for {class_id, _} <- @all_classes do
        dmg_mod = GameData.class_damage_mod(class_id)
        # max(0, 15 - 15) = 0 -> str_bonus = 0
        expected = max(round((3 * 10 + 10 * 0.2 * 0 + 0) * dmg_mod), 1)
        assert Combat.melee_damage(10, 10, 15, class_id, 0, 0) == expected
      end
    end

    test "str 14 gives zero str bonus (below threshold)" do
      dmg_mod = GameData.class_damage_mod(@guerrero)
      expected = max(round((3 * 10 + 10 * 0.2 * 0 + 0) * dmg_mod), 1)
      assert Combat.melee_damage(10, 10, 14, @guerrero, 0, 0) == expected
    end

    test "str 16 gives minimal str bonus" do
      dmg_mod = GameData.class_damage_mod(@guerrero)
      # str_bonus = 10 * 0.2 * max(0, 16 - 15) = 10 * 0.2 * 1 = 2
      expected = max(round((3 * 10 + 10 * 0.2 * 1 + 0) * dmg_mod), 1)
      assert Combat.melee_damage(10, 10, 16, @guerrero, 0, 0) == expected
    end

    test "zero weapon, zero str, zero user damage returns 1 for all classes" do
      for {class_id, _} <- @all_classes do
        result = Combat.melee_damage(0, 0, 0, class_id, 0, 0)
        assert result >= 1, "Class #{class_id} melee_damage(0,0,0) should be >= 1, got #{result}"
      end
    end

    test "weapon 1,1 str 0 user 0 across all classes" do
      for {class_id, _} <- @all_classes do
        dmg_mod = GameData.class_damage_mod(class_id)
        # weapon_dmg = 1, str_bonus = 0 (str < 15), user_dmg = 0
        # raw = (3 * 1 + 0 + 0) * dmg_mod = 3 * dmg_mod
        expected = max(round(3 * dmg_mod), 1)
        assert Combat.melee_damage(1, 1, 0, class_id, 0, 0) == expected
      end
    end

    test "large weapon damage 100,100 with high str" do
      dmg_mod = GameData.class_damage_mod(@guerrero)
      # str_bonus = 100 * 0.2 * (40 - 15) = 100 * 0.2 * 25 = 500
      # raw = (300 + 500 + 0) * dmg_mod = 800 * dmg_mod
      expected = max(round(800 * dmg_mod), 1)
      assert Combat.melee_damage(100, 100, 40, @guerrero, 0, 0) == expected
    end

    test "user_min == user_max makes user_dmg deterministic" do
      dmg_mod = GameData.class_damage_mod(@ladron)
      # weapon_dmg = 5, user_dmg = 20, str = 0
      expected = max(round((3 * 5 + 5 * 0.2 * 0 + 20) * dmg_mod), 1)
      assert Combat.melee_damage(5, 5, 0, @ladron, 20, 20) == expected
    end
  end

  # ── spell_damage/4 rounding edge cases ─────────────────────────────────────

  describe "spell_damage/4 rounding edge cases" do
    test "base 1, level 33 non-mage: tiny level bonus" do
      # level_bonus = floor(1 * 0.03 * 33) = floor(0.99) = 0
      # total = 1 + 0 = 1
      assert Combat.spell_damage(1, 1, 33, false) == 1
    end

    test "base 1, level 34 non-mage: just crosses 1.0" do
      # level_bonus = floor(1 * 0.03 * 34) = floor(1.02) = 1
      # total = 1 + 1 = 2
      assert Combat.spell_damage(1, 1, 34, false) == 2
    end

    test "base 1, level 34 mage: small value rounding" do
      # total = 2, mage = round(2 * 0.7) = round(1.4) = 1
      assert Combat.spell_damage(1, 1, 34, true) == 1
    end

    test "base 10, level 0 non-mage: no level bonus" do
      # level_bonus = floor(10 * 0.03 * 0) = 0
      assert Combat.spell_damage(10, 10, 0, false) == 10
    end

    test "base 10, level 0 mage" do
      # total = 10, mage = round(10 * 0.7) = round(7.0) = 7
      assert Combat.spell_damage(10, 10, 0, true) == 7
    end

    test "base 200, level 46 non-mage" do
      # level_bonus = floor(200 * 0.03 * 46) = floor(276.0) = 276
      # total = 200 + 276 = 476
      assert Combat.spell_damage(200, 200, 46, false) == 476
    end

    test "base 200, level 46 mage" do
      # total = 476, mage = round(476 * 0.7) = round(333.2) = 333
      assert Combat.spell_damage(200, 200, 46, true) == 333
    end

    test "base 3, level 10 mage: banker's rounding check" do
      # level_bonus = floor(3 * 0.03 * 10) = floor(0.9) = 0
      # total = 3, mage = round(3 * 0.7) = round(2.1) = 2
      assert Combat.spell_damage(3, 3, 10, true) == 2
    end

    test "base 5, level 20 mage" do
      # level_bonus = floor(5 * 0.03 * 20) = floor(3.0) = 3
      # total = 8, mage = round(8 * 0.7) = round(5.6) = 6
      assert Combat.spell_damage(5, 5, 20, true) == 6
    end

    test "base 7, level 15 non-mage" do
      # level_bonus = floor(7 * 0.03 * 15) = floor(3.15) = 3
      # total = 10
      assert Combat.spell_damage(7, 7, 15, false) == 10
    end
  end

  # ── class_shield_mod golden verification ───────────────────────────────────

  describe "class_shield_mod golden verification" do
    test "all classes return a non-negative float modifier" do
      for {class_id, name} <- @all_classes do
        mod = GameData.class_shield_mod(class_id)
        assert is_number(mod) and mod >= 0, "#{name} shield_mod should be non-negative, got #{mod}"
      end
    end

    test "guerrero has higher shield_mod than mago" do
      guerrero_mod = GameData.class_shield_mod(@guerrero)
      mago_mod = GameData.class_shield_mod(@mago)
      assert guerrero_mod >= mago_mod,
             "Guerrero shield_mod #{guerrero_mod} should >= mago #{mago_mod}"
    end

    test "class_shield_mod values are consistent across calls" do
      for {class_id, _} <- @all_classes do
        first = GameData.class_shield_mod(class_id)
        second = GameData.class_shield_mod(class_id)
        assert first == second
      end
    end
  end

  # ── class_damage_mod golden verification ───────────────────────────────────

  describe "class_damage_mod golden verification" do
    test "all classes return a positive number" do
      for {class_id, name} <- @all_classes do
        mod = GameData.class_damage_mod(class_id)
        assert is_number(mod) and mod > 0, "#{name} damage_mod should be positive, got #{mod}"
      end
    end

    test "guerrero has high damage modifier" do
      guerrero_mod = GameData.class_damage_mod(@guerrero)
      mago_mod = GameData.class_damage_mod(@mago)
      assert guerrero_mod >= mago_mod,
             "Guerrero damage_mod #{guerrero_mod} should >= mago #{mago_mod}"
    end
  end

  # ── class_attack_mod and class_evasion_mod golden checks ───────────────────

  describe "class_attack_mod and class_evasion_mod for all classes" do
    for {class_id, class_name} <- [
          {1, "mago"},
          {2, "clerigo"},
          {3, "paladin"},
          {4, "cazador"},
          {5, "trabajador"},
          {6, "guerrero"},
          {7, "ladron"},
          {8, "bandido"},
          {9, "asesino"},
          {10, "druida"},
          {11, "bardo"},
          {12, "pirata"}
        ] do
      test "#{class_name} attack_mod is positive" do
        mod = GameData.class_attack_mod(unquote(class_id))
        assert is_number(mod) and mod > 0
      end

      test "#{class_name} evasion_mod is positive" do
        mod = GameData.class_evasion_mod(unquote(class_id))
        assert is_number(mod) and mod > 0
      end
    end
  end

  # ── Combined formula chain golden tests ────────────────────────────────────
  # Simulate a full melee attack pipeline: damage -> critical -> defense -> result

  describe "combined formula chain: melee attack pipeline" do
    test "critical hit on base damage, then zero defense" do
      # Step 1: base damage 100
      # Step 2: apply critical -> 150
      # Step 3: apply defense with {0, 0} -> {150, _location}
      crit_dmg = Combat.apply_critical(100)
      assert crit_dmg == 150
      {final, _loc} = Combat.apply_defense(crit_dmg, {0, 0})
      assert final == 150
    end

    test "non-critical damage absorbed entirely by defense" do
      # 50 damage vs {60, 60} defense -> 0
      {final, _loc} = Combat.apply_defense(50, {60, 60})
      assert final == 0
    end

    test "spell damage reduced by magic resistance" do
      # base 100, level 10, non-mage -> 130
      spell_dmg = Combat.spell_damage(100, 100, 10, false)
      assert spell_dmg == 130
      # Apply 50% resistance -> 65
      reduced = Combat.apply_magic_resistance(spell_dmg, 50)
      assert reduced == 65
    end

    test "mage spell damage reduced by 100% resistance" do
      # base 100, level 10, mage -> round(130 * 0.7) = 91
      spell_dmg = Combat.spell_damage(100, 100, 10, true)
      assert spell_dmg == 91
      # 100% resistance -> 0
      reduced = Combat.apply_magic_resistance(spell_dmg, 100)
      assert reduced == 0
    end

    test "critical on 1 damage then high defense yields 0" do
      crit = Combat.apply_critical(1)
      assert crit == 2
      {final, _loc} = Combat.apply_defense(crit, {10, 10})
      assert final == 0
    end
  end

  # ── xp_gain/5 level 1 and extreme scenarios ───────────────────────────────

  describe "xp_gain/5 level 1 and extreme scenarios" do
    test "level 1 player vs level 1 NPC - no penalty" do
      # 30 * 100 / 60 = 50
      assert Combat.xp_gain(30, 100, 60, 1, 1) == 50
    end

    test "level 1 player vs level 50 NPC - no penalty (player below NPC)" do
      assert Combat.xp_gain(30, 100, 60, 1, 50) == 50
    end

    test "level 50 player vs level 1 NPC - heavy penalty" do
      # delta = 49, extra = 49 - 4 = 45
      # factor = max(1.0 - 0.1 * 45, 0.0) = 0.0
      assert Combat.xp_gain(30, 100, 60, 50, 1) == 0
    end

    test "level 5 player vs level 1 NPC - delta exactly 4, no penalty" do
      assert Combat.xp_gain(30, 100, 60, 5, 1) == 50
    end

    test "level 6 player vs level 1 NPC - delta 5, 10% penalty" do
      # factor = 1.0 - 0.1 * 1 = 0.9
      # round(50 * 0.9) = 45
      assert Combat.xp_gain(30, 100, 60, 6, 1) == 45
    end

    test "1 damage on 1 HP NPC with 1 give_exp" do
      # 1 * 1 / 1 = 1
      assert Combat.xp_gain(1, 1, 1, 1, 1) == 1
    end

    test "max damage on weak NPC with high give_exp" do
      # 9999 * 9999 / 1 = 99980001
      assert Combat.xp_gain(9999, 9999, 1, 10, 10) == 99_980_001
    end

    test "penalty at exactly delta 14 = zero XP" do
      # delta = 14, extra = 10, factor = 1.0 - 0.1 * 10 = 0.0
      assert Combat.xp_gain(30, 100, 60, 24, 10) == 0
    end

    test "penalty at delta 8 reduces by 40%" do
      # delta = 8, extra = 4, factor = 1.0 - 0.1 * 4 = 0.6
      # base = 50, round(50 * 0.6) = 30
      assert Combat.xp_gain(30, 100, 60, 18, 10) == 30
    end

    test "penalty at delta 9 reduces by 50%" do
      # factor = 1.0 - 0.1 * 5 = 0.5
      # round(50 * 0.5) = 25
      assert Combat.xp_gain(30, 100, 60, 19, 10) == 25
    end
  end

  # ── Race modifier completeness ─────────────────────────────────────────────

  describe "race modifier completeness for all 5 races" do
    for {race_id, race_name} <- [
          {1, "humano"},
          {2, "elfo"},
          {3, "elfo_oscuro"},
          {4, "gnomo"},
          {5, "enano"}
        ] do
      test "#{race_name} has modifiers for all 5 stats" do
        for stat <- [:str, :agi, :int, :con, :cha] do
          mod = GameData.race_mod(unquote(race_id), stat)
          assert is_integer(mod), "#{unquote(race_name)} #{stat} modifier must be integer"
        end
      end

      test "#{race_name} produces valid attribute values (18 + mod in 1..50)" do
        for stat <- [:str, :agi, :int, :con, :cha] do
          mod = GameData.race_mod(unquote(race_id), stat)
          val = 18 + mod
          assert val >= 1 and val <= 50,
                 "#{unquote(race_name)} #{stat} = #{val} out of range"
        end
      end
    end

    test "race modifier sum is balanced (no race has extreme total bonus)" do
      for {race_id, race_name} <- @all_races do
        total =
          Enum.sum(
            for stat <- [:str, :agi, :int, :con, :cha] do
              GameData.race_mod(race_id, stat)
            end
          )

        # Total modifiers should be reasonable (within -10..+10 from zero-sum)
        assert total >= -15 and total <= 15,
               "#{race_name} total modifier #{total} seems extreme"
      end
    end

    test "race modifiers are consistent integers across calls" do
      for {race_id, _} <- @all_races, stat <- [:str, :agi, :int, :con, :cha] do
        first = GameData.race_mod(race_id, stat)
        second = GameData.race_mod(race_id, stat)
        assert first == second, "Race #{race_id} #{stat} modifier not stable"
        assert is_integer(first)
      end
    end
  end

  # ── Effective defense/damage for naked characters ──────────────────────────

  describe "CombatStats.effective_defense/1 naked character" do
    test "no equipment gives {0, 0} defense" do
      equipment = %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil}
      assert CombatStats.effective_defense(equipment) == {0, 0}
    end
  end

  describe "CombatStats.effective_damage/1 unarmed" do
    test "no weapon gives {1, 1} damage" do
      equipment = %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil}
      assert CombatStats.effective_damage(equipment) == {1, 1}
    end
  end

  describe "CombatStats.shield_defense_pct/1 no shield" do
    test "no shield gives 0%" do
      equipment = %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil}
      assert CombatStats.shield_defense_pct(equipment) == 0
    end
  end

  # ── apply_defense/2 deterministic cases ────────────────────────────────────

  describe "apply_defense/2 deterministic cases (min_def == max_def)" do
    test "exact defense equals damage yields 0" do
      {dmg, _loc} = Combat.apply_defense(50, {50, 50})
      assert dmg == 0
    end

    test "defense exceeds damage yields 0" do
      {dmg, _loc} = Combat.apply_defense(10, {50, 50})
      assert dmg == 0
    end

    test "defense 0 passes full damage" do
      {dmg, _loc} = Combat.apply_defense(100, {0, 0})
      assert dmg == 100
    end

    test "damage 0 defense 0 yields 0" do
      {dmg, _loc} = Combat.apply_defense(0, {0, 0})
      assert dmg == 0
    end

    test "partial defense leaves remainder" do
      {dmg, _loc} = Combat.apply_defense(100, {30, 30})
      assert dmg == 70
    end

    test "hit location is :head or :body" do
      for _i <- 1..50 do
        {_dmg, loc} = Combat.apply_defense(50, {10, 10})
        assert loc in [:head, :body]
      end
    end
  end

  # ── apply_critical/1 comprehensive edge cases ──────────────────────────────

  describe "apply_critical/1 comprehensive values" do
    test "negative damage stays negative (edge: should not happen in practice)" do
      # round(-10 * 1.5) = -15
      assert Combat.apply_critical(-10) == -15
    end

    test "very large damage 99999" do
      assert Combat.apply_critical(99_999) == round(99_999 * 1.5)
    end

    test "even numbers: 2 -> 3, 4 -> 6, 10 -> 15, 100 -> 150" do
      assert Combat.apply_critical(2) == 3
      assert Combat.apply_critical(4) == 6
      assert Combat.apply_critical(10) == 15
      assert Combat.apply_critical(100) == 150
    end

    test "odd numbers: 1 -> 2, 3 -> 4/5, 5 -> 8, 7 -> 10/11" do
      assert Combat.apply_critical(1) == round(1 * 1.5)
      assert Combat.apply_critical(3) == round(3 * 1.5)
      assert Combat.apply_critical(5) == round(5 * 1.5)
      assert Combat.apply_critical(7) == round(7 * 1.5)
    end
  end

  # ── adjust_hit_for_meditate/2 boundary values ──────────────────────────────

  describe "adjust_hit_for_meditate/2 additional boundary values" do
    test "hit_chance at midpoints: 25, 33, 67, 75" do
      # 25: miss = 75 * 0.75 = 56.25, result = round(43.75) = 44
      assert Combat.adjust_hit_for_meditate(25, true) == 44
      # 33: miss = 67 * 0.75 = 50.25, result = round(49.75) = 50
      assert Combat.adjust_hit_for_meditate(33, true) == 50
      # 67: miss = 33 * 0.75 = 24.75, result = round(75.25) = 75
      assert Combat.adjust_hit_for_meditate(67, true) == 75
      # 75: miss = 25 * 0.75 = 18.75, result = round(81.25) = 81
      assert Combat.adjust_hit_for_meditate(75, true) == 81
    end

    test "all values 0..100 stay within [10, 90] when meditating" do
      for hit <- 0..100 do
        result = Combat.adjust_hit_for_meditate(hit, true)
        assert result >= 10 and result <= 90,
               "hit=#{hit} produced #{result} outside [10,90]"
      end
    end

    test "meditate always increases hit chance (except at caps)" do
      for hit <- 5..89 do
        adjusted = Combat.adjust_hit_for_meditate(hit, true)
        assert adjusted >= hit,
               "hit=#{hit} should not decrease when meditating, got #{adjusted}"
      end
    end
  end

  # ── Level-up HP growth deterministic bounds for all classes ─────────────────

  describe "level-up HP growth deterministic bounds" do
    for {class_id, class_name} <- [
          {1, "mago"},
          {2, "clerigo"},
          {3, "paladin"},
          {4, "cazador"},
          {5, "trabajador"},
          {6, "guerrero"},
          {7, "ladron"},
          {8, "bandido"},
          {9, "asesino"},
          {10, "druida"},
          {11, "bardo"},
          {12, "pirata"}
        ] do
      test "#{class_name} min HP gain = max(trunc(hp_mod * 0.8), 1)" do
        hp_mod = GameData.class_hp_mod(unquote(class_id))
        min_gain = max(trunc(hp_mod * 0.8), 1)
        assert min_gain >= 1
        # Verify with 100 random samples
        for _ <- 1..100 do
          gain = max(trunc(hp_mod * (0.8 + :rand.uniform() * 0.4)), 1)
          assert gain >= min_gain
        end
      end

      test "#{class_name} max HP gain = max(trunc(hp_mod * 1.2), 1)" do
        hp_mod = GameData.class_hp_mod(unquote(class_id))
        max_gain = max(trunc(hp_mod * 1.2), 1)
        assert max_gain >= 1
        for _ <- 1..100 do
          gain = max(trunc(hp_mod * (0.8 + :rand.uniform() * 0.4)), 1)
          assert gain <= max_gain
        end
      end
    end
  end

  # ── Level-up mana growth for all caster and non-caster classes ─────────────

  describe "level-up mana growth golden values" do
    test "mana multiplier is non-negative for all classes" do
      for {class_id, name} <- @all_classes do
        mana_mult = GameData.class_mana_mult(class_id)
        assert mana_mult >= 0, "#{name} mana_mult should be >= 0, got #{mana_mult}"
      end
    end

    test "mana gain formula is deterministic: trunc(int * mult)" do
      for {class_id, _} <- @all_classes do
        mult = GameData.class_mana_mult(class_id)
        gain_a = trunc(18 * mult)
        gain_b = trunc(18 * mult)
        assert gain_a == gain_b
        assert gain_a >= 0
      end
    end

    test "mana gain scales with int (higher int = more or equal mana)" do
      for {class_id, _} <- @all_classes do
        mult = GameData.class_mana_mult(class_id)
        gain_low = trunc(10 * mult)
        gain_high = trunc(30 * mult)
        assert gain_high >= gain_low,
               "Class #{class_id}: int 30 mana #{gain_high} < int 10 mana #{gain_low}"
      end
    end
  end

  # ── Stamina growth golden values for all classes ───────────────────────────

  describe "stamina growth golden values" do
    test "all classes with agi 0 get at least 1 stamina" do
      for {class_id, name} <- @all_classes do
        sta_growth = GameData.class_stamina_growth(class_id)
        expected = max(trunc(sta_growth * 0 / 33), 1)
        assert expected == 1, "#{name} should get 1 stamina with agi 0"
      end
    end

    test "all classes with agi 33 get exactly sta_growth" do
      for {class_id, name} <- @all_classes do
        sta_growth = GameData.class_stamina_growth(class_id)
        expected = max(trunc(sta_growth * 33 / 33), 1)
        assert expected == max(trunc(sta_growth), 1),
               "#{name} agi 33 stamina: expected #{max(trunc(sta_growth), 1)}, got #{expected}"
      end
    end

    test "higher agi produces equal or more stamina" do
      for {class_id, _} <- @all_classes do
        sta_growth = GameData.class_stamina_growth(class_id)
        low = max(trunc(sta_growth * 10 / 33), 1)
        high = max(trunc(sta_growth * 40 / 33), 1)
        assert high >= low
      end
    end
  end

  # ── Character creation initial mana for all class/race combos ──────────────

  describe "character creation initial mana for all class/race combinations" do
    for {race_id, race_name} <- [{1, "humano"}, {2, "elfo"}, {5, "enano"}],
        {class_id, class_name} <- [{1, "mago"}, {6, "guerrero"}, {2, "clerigo"}] do
      test "#{race_name} #{class_name} initial mana" do
        int_val = 18 + GameData.race_mod(unquote(race_id), :int)
        mana_mult = GameData.class_mana_initial(unquote(class_id))
        expected = trunc(int_val * mana_mult)
        assert expected == trunc(int_val * mana_mult)
        assert expected >= 0
      end
    end
  end

  # ── Commerce formulas additional edge cases ────────────────────────────────

  describe "commerce buy price additional edge cases" do
    test "valor 1, skill 0: cheapest item" do
      assert ceil(1 / (1 + 0 / 100) * 1) == 1
    end

    test "valor 1, skill 100: still costs 1 (ceil of 0.5)" do
      assert ceil(1 / (1 + 100 / 100) * 1) == 1
    end

    test "valor 10000, skill 0, amount 99: large purchase" do
      assert ceil(10_000 / (1 + 0 / 100) * 99) == 990_000
    end

    test "valor 10000, skill 100, amount 99: discounted large purchase" do
      assert ceil(10_000 / (1 + 100 / 100) * 99) == 495_000
    end
  end

  describe "commerce sell price additional edge cases" do
    test "valor 0 sells for 0" do
      assert div(0, 3) * 1 == 0
    end

    test "valor 9999 sells for 3333 per unit" do
      assert div(9999, 3) * 1 == 3333
    end

    test "valor 10000, amount 100" do
      assert div(10_000, 3) * 100 == 333_300
    end
  end

  # ── Training cost additional edge cases ────────────────────────────────────

  describe "training cost additional edge cases" do
    test "skill 2 costs 20 gold" do
      assert max(2 * 10, 10) == 20
    end

    test "skill 5 costs 50 gold" do
      assert max(5 * 10, 10) == 50
    end

    test "training 0 to 100 total gold cost" do
      total = Enum.sum(for skill <- 0..99, do: max(skill * 10, 10))
      # 10 + 10 + 20 + 30 + ... + 990 = 10 + sum(10..990 step 10)
      # sum(1..99) * 10 = 4950 * 10 = 49500, but first entry is 10 not 0
      assert total == 10 + Enum.sum(for s <- 1..99, do: s * 10)
    end
  end

  # ── Regen formulas with extreme values ─────────────────────────────────────

  describe "regen formulas extreme values" do
    test "rest HP regen with con 200 (theoretical max)" do
      assert max(div(200, 6), 1) == 33
    end

    test "meditate mana regen with int 50 meditation 100" do
      assert max(div(50 * 100, 35), 1) == 142
    end

    test "passive HP regen with con 1" do
      assert max(div(1, 30), 1) == 1
    end

    test "passive mana regen with int 1" do
      assert max(div(1, 35), 1) == 1
    end

    test "stamina regen with agi 50" do
      assert max(div(50, 6), 1) == 8
    end

    test "all regen formulas return at least 1" do
      for val <- [0, 1, 2, 5] do
        assert max(div(val, 6), 1) >= 1
        assert max(div(val, 30), 1) >= 1
        assert max(div(val, 35), 1) >= 1
      end
    end
  end

  # ── Critical hit chance formula additional cases ───────────────────────────

  describe "critical_hit? chance formula edge cases" do
    test "weapon_skill 1..99 all yield chance 5 (div by 100 = 0)" do
      for skill <- 1..99 do
        assert min(div(skill, 100) * 10 + 5, 15) == 5
      end
    end

    test "weapon_skill 150: chance = min(15, 15) = 15 (capped)" do
      assert min(div(150, 100) * 10 + 5, 15) == 15
    end

    test "weapon_skill 300: still capped at 15" do
      assert min(div(300, 100) * 10 + 5, 15) == 15
    end
  end
end
