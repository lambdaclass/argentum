defmodule Arena.VB6FormulaGoldenTest do
  @moduledoc """
  Golden tests for VB6 combat formulas.

  Each test case uses hardcoded inputs and asserts an exact expected output
  derived from the VB6 formulas. These serve as regression protection against
  accidental formula changes.
  """
  use ExUnit.Case, async: true

  alias Arena.Combat
  alias Arena.Data.GameData

  # Class IDs matching the VB6 engine
  @guerrero 1
  @mago 7

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Pre-load class modifiers so we can compute expected values in tests
    guerrero_atk_mod = GameData.class_attack_mod(@guerrero)
    guerrero_eva_mod = GameData.class_evasion_mod(@guerrero)
    mago_atk_mod = GameData.class_attack_mod(@mago)
    mago_eva_mod = GameData.class_evasion_mod(@mago)

    guerrero_pre36 = GameData.class_hit_pre36(@guerrero)
    guerrero_post36 = GameData.class_hit_post36(@guerrero)
    mago_pre36 = GameData.class_hit_pre36(@mago)
    mago_post36 = GameData.class_hit_post36(@mago)

    {:ok,
     guerrero_atk_mod: guerrero_atk_mod,
     guerrero_eva_mod: guerrero_eva_mod,
     mago_atk_mod: mago_atk_mod,
     mago_eva_mod: mago_eva_mod,
     guerrero_pre36: guerrero_pre36,
     guerrero_post36: guerrero_post36,
     mago_pre36: mago_pre36,
     mago_post36: mago_post36}
  end

  # ── Helper: compute expected hit_chance from the VB6 formula ──────────────

  defp expected_hit_chance(atk_skill, atk_agi, atk_level, atk_mod, def_tactics, def_agi, def_level, def_mod) do
    attack_power =
      (atk_skill + 3 * atk_skill / 100 * atk_agi) * atk_mod + 2.5 * max(atk_level - 12, 0)

    evasion =
      (def_tactics + 3 * def_tactics / 100 * def_agi) * def_mod + 2.5 * max(def_level - 12, 0)

    round(50 + (attack_power - evasion) * 0.4) |> clamp(5, 95)
  end

  defp expected_npc_hit_chance(poder_ataque, def_tactics, def_agi, def_level, def_mod) do
    evasion =
      (def_tactics + 3 * def_tactics / 100 * def_agi) * def_mod + 2.5 * max(def_level - 12, 0)

    round(50 + (poder_ataque - evasion) * 0.4) |> clamp(10, 90)
  end

  defp clamp(val, min_val, max_val), do: min(max(val, min_val), max_val)

  # ── hit_chance/8 golden tests ─────────────────────────────────────────────

  describe "hit_chance/8 golden values" do
    test "equal combatants yield exactly 50", ctx do
      # Same class, same skill, same agi, same level -> attack_power == evasion -> 50
      result = Combat.hit_chance(50, 20, 25, @guerrero, 50, 20, 25, @guerrero)

      expected =
        expected_hit_chance(
          50, 20, 25, ctx.guerrero_atk_mod,
          50, 20, 25, ctx.guerrero_eva_mod
        )

      assert result == expected
    end

    test "high attacker skill caps at 95", ctx do
      result = Combat.hit_chance(100, 50, 50, @guerrero, 0, 0, 1, @guerrero)

      expected =
        expected_hit_chance(
          100, 50, 50, ctx.guerrero_atk_mod,
          0, 0, 1, ctx.guerrero_eva_mod
        )

      assert result == expected
      assert result == 95
    end

    test "high defender evasion floors at 5", ctx do
      result = Combat.hit_chance(0, 0, 1, @guerrero, 100, 50, 50, @guerrero)

      expected =
        expected_hit_chance(
          0, 0, 1, ctx.guerrero_atk_mod,
          100, 50, 50, ctx.guerrero_eva_mod
        )

      assert result == expected
      assert result == 5
    end

    test "mid-range combatants with different classes", ctx do
      # Guerrero attacking, Mago defending
      result = Combat.hit_chance(60, 25, 30, @guerrero, 40, 20, 25, @mago)

      expected =
        expected_hit_chance(
          60, 25, 30, ctx.guerrero_atk_mod,
          40, 20, 25, ctx.mago_eva_mod
        )

      assert result == expected
    end

    test "level 1 combatants get no level bonus", ctx do
      # level 1 < 12, so max(level - 12, 0) == 0
      result = Combat.hit_chance(30, 15, 1, @guerrero, 30, 15, 1, @guerrero)

      expected =
        expected_hit_chance(
          30, 15, 1, ctx.guerrero_atk_mod,
          30, 15, 1, ctx.guerrero_eva_mod
        )

      assert result == expected
    end

    test "high level combatants include level bonus", ctx do
      # level 45: level bonus = 2.5 * (45 - 12) = 82.5
      result = Combat.hit_chance(50, 20, 45, @guerrero, 50, 20, 45, @guerrero)

      expected =
        expected_hit_chance(
          50, 20, 45, ctx.guerrero_atk_mod,
          50, 20, 45, ctx.guerrero_eva_mod
        )

      assert result == expected
    end

    test "level asymmetry shifts hit chance", ctx do
      # High level attacker vs low level defender
      result = Combat.hit_chance(50, 20, 45, @guerrero, 50, 20, 10, @guerrero)

      expected =
        expected_hit_chance(
          50, 20, 45, ctx.guerrero_atk_mod,
          50, 20, 10, ctx.guerrero_eva_mod
        )

      assert result == expected
      # Attacker has level bonus, defender does not -> should be above 50
      assert result > 50
    end
  end

  # ── xp_gain/5 golden tests ───────────────────────────────────────────────

  describe "xp_gain/5 golden values" do
    test "no penalty when level delta is 0" do
      # 30 * 100 / 60 = 50
      assert Combat.xp_gain(30, 100, 60, 10, 10) == 50
    end

    test "no penalty when level delta is exactly 4" do
      # delta = 4, no penalty applies
      assert Combat.xp_gain(30, 100, 60, 14, 10) == 50
    end

    test "penalty at delta 5 reduces by 10%" do
      # delta 5: factor = 1.0 - 0.1 * (5 - 4) = 0.9
      # base = 50, penalized = round(50 * 0.9) = 45
      assert Combat.xp_gain(30, 100, 60, 15, 10) == 45
    end

    test "penalty at delta 6 reduces by 20%" do
      # factor = 1.0 - 0.1 * 2 = 0.8, round(50 * 0.8) = 40
      assert Combat.xp_gain(30, 100, 60, 16, 10) == 40
    end

    test "penalty at delta 7 reduces by 30%" do
      # factor = 1.0 - 0.1 * 3 = 0.7, round(50 * 0.7) = 35
      assert Combat.xp_gain(30, 100, 60, 17, 10) == 35
    end

    test "penalty at delta 10 reduces by 60%" do
      # factor = 1.0 - 0.1 * 6 = 0.4, round(50 * 0.4) = 20
      assert Combat.xp_gain(30, 100, 60, 20, 10) == 20
    end

    test "penalty at delta 14 yields zero XP" do
      # factor = 1.0 - 0.1 * 10 = 0.0
      assert Combat.xp_gain(30, 100, 60, 24, 10) == 0
    end

    test "penalty at delta 15 floors at zero" do
      # factor = max(1.0 - 0.1 * 11, 0.0) = 0.0
      assert Combat.xp_gain(30, 100, 60, 25, 10) == 0
    end

    test "zero damage yields zero XP" do
      assert Combat.xp_gain(0, 100, 60, 10, 10) == 0
    end

    test "zero give_exp yields zero XP" do
      assert Combat.xp_gain(30, 0, 60, 10, 10) == 0
    end

    test "zero max_hp uses 1 as denominator" do
      # div(30 * 100, 1) = 3000
      assert Combat.xp_gain(30, 100, 0, 10, 10) == 3000
    end

    test "large damage with no penalty" do
      # 500 * 200 / 100 = 1000
      assert Combat.xp_gain(500, 200, 100, 10, 10) == 1000
    end
  end

  # ── base_user_damage/2 golden tests ───────────────────────────────────────

  describe "base_user_damage/2 golden values for Guerrero" do
    test "level 1", ctx do
      # modifier = (1 - 1) * pre36 = 0
      # {0 + 1, 0 + 2} = {1, 2}
      expected_mod = 0 * ctx.guerrero_pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(1, @guerrero) == expected
    end

    test "level 10", ctx do
      expected_mod = 9 * ctx.guerrero_pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(10, @guerrero) == expected
    end

    test "level 20", ctx do
      expected_mod = 19 * ctx.guerrero_pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(20, @guerrero) == expected
    end

    test "level 36 is the boundary", ctx do
      expected_mod = 35 * ctx.guerrero_pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(36, @guerrero) == expected
    end

    test "level 37 uses post36 formula", ctx do
      expected_mod = 35 * ctx.guerrero_pre36 + 1 * ctx.guerrero_post36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(37, @guerrero) == expected
    end

    test "level 40", ctx do
      expected_mod = 35 * ctx.guerrero_pre36 + 4 * ctx.guerrero_post36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(40, @guerrero) == expected
    end

    test "level 46", ctx do
      expected_mod = 35 * ctx.guerrero_pre36 + 10 * ctx.guerrero_post36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(46, @guerrero) == expected
    end
  end

  describe "base_user_damage/2 golden values for Mago" do
    test "level 1", ctx do
      expected_mod = 0 * ctx.mago_pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(1, @mago) == expected
    end

    test "level 10", ctx do
      expected_mod = 9 * ctx.mago_pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(10, @mago) == expected
    end

    test "level 20", ctx do
      expected_mod = 19 * ctx.mago_pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(20, @mago) == expected
    end

    test "level 36", ctx do
      expected_mod = 35 * ctx.mago_pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(36, @mago) == expected
    end

    test "level 37", ctx do
      expected_mod = 35 * ctx.mago_pre36 + 1 * ctx.mago_post36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(37, @mago) == expected
    end

    test "level 40", ctx do
      expected_mod = 35 * ctx.mago_pre36 + 4 * ctx.mago_post36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(40, @mago) == expected
    end

    test "level 46", ctx do
      expected_mod = 35 * ctx.mago_pre36 + 10 * ctx.mago_post36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(46, @mago) == expected
    end
  end

  # ── apply_critical/1 golden tests ─────────────────────────────────────────

  describe "apply_critical/1 golden values" do
    test "100 damage becomes 150" do
      assert Combat.apply_critical(100) == 150
    end

    test "1 damage becomes 2 (rounds 1.5 to 2)" do
      assert Combat.apply_critical(1) == 2
    end

    test "0 damage stays 0" do
      assert Combat.apply_critical(0) == 0
    end

    test "odd number 33 becomes 50 (rounds 49.5 to 50)" do
      assert Combat.apply_critical(33) == 50
    end

    test "200 damage becomes 300" do
      assert Combat.apply_critical(200) == 300
    end
  end

  # ── apply_magic_resistance/2 golden tests ─────────────────────────────────

  describe "apply_magic_resistance/2 golden values" do
    test "100 damage at 50% resistance yields 50" do
      assert Combat.apply_magic_resistance(100, 50) == 50
    end

    test "100 damage at 0% resistance yields 100" do
      assert Combat.apply_magic_resistance(100, 0) == 100
    end

    test "100 damage at 100% resistance yields 0" do
      assert Combat.apply_magic_resistance(100, 100) == 0
    end

    test "100 damage at 25% resistance yields 75" do
      assert Combat.apply_magic_resistance(100, 25) == 75
    end

    test "100 damage at 75% resistance yields 25" do
      assert Combat.apply_magic_resistance(100, 75) == 25
    end

    test "50 damage at 30% resistance yields 35" do
      # round(50 * (1 - 30/100)) = round(50 * 0.7) = round(35.0) = 35
      assert Combat.apply_magic_resistance(50, 30) == 35
    end

    test "10 damage at 200% resistance floors at 0" do
      assert Combat.apply_magic_resistance(10, 200) == 0
    end
  end

  # ── npc_hit_chance/5 golden tests ─────────────────────────────────────────

  describe "npc_hit_chance/5 golden values" do
    test "high poder_ataque caps at 90", ctx do
      result = Combat.npc_hit_chance(9999, 0, 0, 1, @guerrero)

      expected =
        expected_npc_hit_chance(9999, 0, 0, 1, ctx.guerrero_eva_mod)

      assert result == expected
      assert result == 90
    end

    test "zero poder_ataque against high defender floors at 10", ctx do
      result = Combat.npc_hit_chance(0, 100, 50, 50, @guerrero)

      expected =
        expected_npc_hit_chance(0, 100, 50, 50, ctx.guerrero_eva_mod)

      assert result == expected
      assert result == 10
    end

    test "balanced NPC vs player", ctx do
      result = Combat.npc_hit_chance(100, 50, 20, 25, @guerrero)

      expected =
        expected_npc_hit_chance(100, 50, 20, 25, ctx.guerrero_eva_mod)

      assert result == expected
    end

    test "NPC vs Mago defender", ctx do
      result = Combat.npc_hit_chance(80, 30, 15, 20, @mago)

      expected =
        expected_npc_hit_chance(80, 30, 15, 20, ctx.mago_eva_mod)

      assert result == expected
    end

    test "NPC vs low level defender with no level bonus", ctx do
      # level 10 < 12 -> no level bonus for defender
      result = Combat.npc_hit_chance(50, 40, 18, 10, @guerrero)

      expected =
        expected_npc_hit_chance(50, 40, 18, 10, ctx.guerrero_eva_mod)

      assert result == expected
    end
  end
end
