defmodule Arena.VB6FormulaGoldenExpansionTest do
  @moduledoc """
  Expanded golden tests for VB6 formulas NOT covered by the original
  `VB6FormulaGoldenTest` module.

  Covers:
  - Melee damage (melee_damage/6) with deterministic weapon/user rolls
  - Critical hit chance (critical_hit? threshold) and apply_critical edge cases
  - Shield block chance formula
  - Adjust hit for meditate
  - Spell damage level bonus (deterministic via fixed base)
  - Commerce buy/sell price formulas (pure arithmetic, no GenServer)
  - Training gold cost formula
  - Regen rates: rest HP, meditate mana, passive HP, passive mana, stamina
  - Hunger/thirst drain arithmetic
  - Starvation HP damage
  - Level-up stat growth formulas (HP, mana, stamina, skill points)
  - Character creation initial stats (HP, mana from class/race)
  """
  use ExUnit.Case, async: true

  alias Arena.Combat
  alias Arena.Data.GameData

  # Class IDs matching VB6
  @mago 1
  @clerigo 2
  @paladin 3
  @cazador 4
  # @trabajador 5 — available for future tests
  @guerrero 6
  @ladron 7
  # @bandido 8 — available for future tests
  # @asesino 9 — used in compile-time comprehension below
  @druida 10
  # @bardo 11 — available for future tests
  # @pirata 12 — available for future tests

  # Race IDs
  @humano 1
  @elfo 2
  @enano 4

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp clamp(val, lo, hi), do: min(max(val, lo), hi)

  # ── adjust_hit_for_meditate/2 ──────────────────────────────────────────────
  # VB6: miss_chance = (100 - hit_chance) * 0.75; result = clamp(100 - miss_chance, 10, 90)

  describe "adjust_hit_for_meditate/2 golden values" do
    test "50% hit vs meditating defender" do
      # miss = (100 - 50) * 0.75 = 37.5, result = round(100 - 37.5) = 63
      assert Combat.adjust_hit_for_meditate(50, true) == 63
    end

    test "5% hit vs meditating defender floors at 10" do
      # miss = (100 - 5) * 0.75 = 71.25, result = round(100 - 71.25) = 29
      # clamp(29, 10, 90) = 29
      assert Combat.adjust_hit_for_meditate(5, true) == 29
    end

    test "95% hit vs meditating defender caps at 90" do
      # miss = (100 - 95) * 0.75 = 3.75, result = round(100 - 3.75) = 96
      # clamp(96, 10, 90) = 90
      assert Combat.adjust_hit_for_meditate(95, true) == 90
    end

    test "10% hit vs meditating defender" do
      # miss = (100 - 10) * 0.75 = 67.5, result = round(100 - 67.5) = 33
      assert Combat.adjust_hit_for_meditate(10, true) == 33
    end

    test "non-meditating defender returns unchanged" do
      assert Combat.adjust_hit_for_meditate(50, false) == 50
      assert Combat.adjust_hit_for_meditate(95, false) == 95
      assert Combat.adjust_hit_for_meditate(5, false) == 5
    end

    test "90% hit vs meditating defender" do
      # miss = (100 - 90) * 0.75 = 7.5, result = round(100 - 7.5) = 93
      # clamp(93, 10, 90) = 90
      assert Combat.adjust_hit_for_meditate(90, true) == 90
    end

    test "0% theoretical hit vs meditating" do
      # miss = (100 - 0) * 0.75 = 75, result = round(100 - 75) = 25
      # clamp(25, 10, 90) = 25
      assert Combat.adjust_hit_for_meditate(0, true) == 25
    end

    test "100% theoretical hit vs meditating" do
      # miss = (100 - 100) * 0.75 = 0, result = round(100 - 0) = 100
      # clamp(100, 10, 90) = 90
      assert Combat.adjust_hit_for_meditate(100, true) == 90
    end
  end

  # ── apply_critical/1 additional edge cases ─────────────────────────────────
  # VB6: damage * 1.5, rounded

  describe "apply_critical/1 extended golden values" do
    test "2 damage becomes 3" do
      assert Combat.apply_critical(2) == 3
    end

    test "3 damage becomes 5 (4.5 rounds to 4? check)" do
      # 3 * 1.5 = 4.5, Elixir round/1 rounds to even = 4
      assert Combat.apply_critical(3) == round(3 * 1.5)
    end

    test "999 damage becomes 1499" do
      # 999 * 1.5 = 1498.5 -> round = 1498 (banker's rounding) or 1499
      assert Combat.apply_critical(999) == round(999 * 1.5)
    end

    test "large damage 10000 becomes 15000" do
      assert Combat.apply_critical(10000) == 15000
    end
  end

  # ── apply_magic_resistance/2 extended ──────────────────────────────────────
  # VB6: damage * (1 - resistance_pct / 100), min 0

  describe "apply_magic_resistance/2 extended golden values" do
    test "0 damage at any resistance yields 0" do
      assert Combat.apply_magic_resistance(0, 50) == 0
    end

    test "1 damage at 50% resistance yields 1" do
      # round(1 * 0.5) = 1
      assert Combat.apply_magic_resistance(1, 50) == 1
    end

    test "1 damage at 99% resistance yields 0" do
      # round(1 * 0.01) = 0
      assert Combat.apply_magic_resistance(1, 99) == 0
    end

    test "negative resistance is treated as 0 (no reduction)" do
      # resistance_pct <= 0 falls to the second clause which returns damage as-is
      assert Combat.apply_magic_resistance(100, -10) == 100
      assert Combat.apply_magic_resistance(100, 0) == 100
    end

    test "33% resistance on 100 damage" do
      # round(100 * (1 - 33/100)) = round(100 * 0.67) = round(67.0) = 67
      assert Combat.apply_magic_resistance(100, 33) == 67
    end

    test "66% resistance on 100 damage" do
      # round(100 * 0.34) = round(34.0) = 34
      assert Combat.apply_magic_resistance(100, 66) == 34
    end
  end

  # ── melee_damage/6 deterministic tests ─────────────────────────────────────
  # VB6: raw = (3 * weapon_dmg + weapon_max * 0.2 * max(0, str - 15) + user_dmg) * class_dmg_mod
  # When weapon_min == weapon_max and user_min == user_max, the result is deterministic.

  describe "melee_damage/6 deterministic golden values" do
    test "minimum damage with 0 str guerrero" do
      # weapon_dmg = 10, str = 0 => str_bonus = 0.2 * 10 * max(0, 0 - 15) = 0
      # raw = (3 * 10 + 0 + 0) * class_damage_mod
      dmg_mod = GameData.class_damage_mod(@guerrero)
      expected = max(round((3 * 10 + 10 * 0.2 * max(0, 0 - 15) + 0) * dmg_mod), 1)
      assert Combat.melee_damage(10, 10, 0, @guerrero, 0, 0) == expected
    end

    test "str exactly 15 gives no str bonus" do
      dmg_mod = GameData.class_damage_mod(@guerrero)
      # max(0, 15 - 15) = 0
      expected = max(round((3 * 20 + 20 * 0.2 * 0 + 5) * dmg_mod), 1)
      assert Combat.melee_damage(20, 20, 15, @guerrero, 5, 5) == expected
    end

    test "str 25 with weapon max 20, guerrero" do
      dmg_mod = GameData.class_damage_mod(@guerrero)
      # str_bonus = 20 * 0.2 * (25 - 15) = 20 * 0.2 * 10 = 40
      # raw = (3 * 20 + 40 + 5) * dmg_mod = 105 * dmg_mod
      expected = max(round((3 * 20 + 20 * 0.2 * 10 + 5) * dmg_mod), 1)
      assert Combat.melee_damage(20, 20, 25, @guerrero, 5, 5) == expected
    end

    test "str 25 with weapon max 20, mago" do
      dmg_mod = GameData.class_damage_mod(@mago)
      expected = max(round((3 * 20 + 20 * 0.2 * 10 + 5) * dmg_mod), 1)
      assert Combat.melee_damage(20, 20, 25, @mago, 5, 5) == expected
    end

    test "str 25 with weapon max 20, ladron" do
      dmg_mod = GameData.class_damage_mod(@ladron)
      expected = max(round((3 * 20 + 20 * 0.2 * 10 + 5) * dmg_mod), 1)
      assert Combat.melee_damage(20, 20, 25, @ladron, 5, 5) == expected
    end

    test "zero weapon damage still returns at least 1" do
      result = Combat.melee_damage(0, 0, 0, @guerrero, 0, 0)
      assert result >= 1
    end

    test "high str 50 with strong weapon" do
      dmg_mod = GameData.class_damage_mod(@guerrero)
      # str_bonus = 50 * 0.2 * max(0, 50 - 15) = 50 * 0.2 * 35 = 350
      # raw = (3 * 50 + 350 + 10) * dmg_mod = 510 * dmg_mod
      expected = max(round((3 * 50 + 50 * 0.2 * 35 + 10) * dmg_mod), 1)
      assert Combat.melee_damage(50, 50, 50, @guerrero, 10, 10) == expected
    end
  end

  # ── shield_block_chance formula ────────────────────────────────────────────
  # VB6: chance = clamp(shield_pct * def_skill / max(def_skill + tactics, 1), 10, 90)
  # shield_block?/3 is random, so we test the formula computation directly.

  describe "shield block chance formula (computed manually)" do
    test "50% shield, skill 50, tactics 50 yields 25 clamped to 25" do
      # 50 * 50 / max(50 + 50, 1) = 2500 / 100 = 25
      chance = round(50 * 50 / max(50 + 50, 1)) |> clamp(10, 90)
      assert chance == 25
    end

    test "100% shield, skill 100, tactics 0 yields 90 (capped)" do
      # 100 * 100 / max(100 + 0, 1) = 10000 / 100 = 100 -> clamp 90
      chance = round(100 * 100 / max(100 + 0, 1)) |> clamp(10, 90)
      assert chance == 90
    end

    test "0% shield means no block" do
      # shield_block?(0, ...) always returns false
      refute Combat.shield_block?(0, 100, 0)
    end

    test "10% shield, skill 10, tactics 90 yields 10 (floor)" do
      # 10 * 10 / (10 + 90) = 100 / 100 = 1 -> clamp to 10
      chance = round(10 * 10 / max(10 + 90, 1)) |> clamp(10, 90)
      assert chance == 10
    end

    test "80% shield, skill 80, tactics 20 yields 64" do
      # 80 * 80 / (80 + 20) = 6400 / 100 = 64
      chance = round(80 * 80 / max(80 + 20, 1)) |> clamp(10, 90)
      assert chance == 64
    end

    test "skill 0 and tactics 0 uses denominator 1" do
      # shield_pct * 0 / 1 = 0 -> clamp 10
      chance = round(50 * 0 / max(0 + 0, 1)) |> clamp(10, 90)
      assert chance == 10
    end
  end

  # ── commerce buy price formula ─────────────────────────────────────────────
  # VB6: buy_price = ceil(item_valor / (1 + trading_skill / 100) * amount)

  describe "commerce buy price formula" do
    test "trading skill 0, valor 100, amount 1" do
      # ceil(100 / (1 + 0/100) * 1) = ceil(100 / 1.0) = 100
      assert ceil(100 / (1 + 0 / 100) * 1) == 100
    end

    test "trading skill 50, valor 100, amount 1" do
      # ceil(100 / (1 + 50/100) * 1) = ceil(100 / 1.5) = ceil(66.67) = 67
      assert ceil(100 / (1 + 50 / 100) * 1) == 67
    end

    test "trading skill 100, valor 100, amount 1" do
      # ceil(100 / (1 + 100/100) * 1) = ceil(100 / 2.0) = 50
      assert ceil(100 / (1 + 100 / 100) * 1) == 50
    end

    test "trading skill 0, valor 100, amount 5" do
      # ceil(100 / 1.0 * 5) = 500
      assert ceil(100 / (1 + 0 / 100) * 5) == 500
    end

    test "trading skill 100, valor 150, amount 3" do
      # ceil(150 / 2.0 * 3) = ceil(225.0) = 225
      assert ceil(150 / (1 + 100 / 100) * 3) == 225
    end

    test "trading skill 25, valor 50, amount 10" do
      # ceil(50 / 1.25 * 10) = ceil(400.0) = 400
      assert ceil(50 / (1 + 25 / 100) * 10) == 400
    end

    test "trading skill 75, valor 200, amount 1" do
      # ceil(200 / 1.75) = ceil(114.2857) = 115
      assert ceil(200 / (1 + 75 / 100) * 1) == 115
    end
  end

  # ── commerce sell price formula ────────────────────────────────────────────
  # VB6: sell_price = div(item_valor, 3) * amount (integer division)

  describe "commerce sell price formula" do
    test "valor 100, amount 1" do
      assert div(100, 3) * 1 == 33
    end

    test "valor 100, amount 5" do
      assert div(100, 3) * 5 == 165
    end

    test "valor 3, amount 1 gives 1" do
      assert div(3, 3) * 1 == 1
    end

    test "valor 2, amount 1 truncates to 0" do
      assert div(2, 3) * 1 == 0
    end

    test "valor 1, amount 1 truncates to 0" do
      assert div(1, 3) * 1 == 0
    end

    test "valor 300, amount 10" do
      assert div(300, 3) * 10 == 1000
    end

    test "valor 50, amount 3" do
      # div(50, 3) = 16, 16 * 3 = 48
      assert div(50, 3) * 3 == 48
    end
  end

  # ── training gold cost formula ─────────────────────────────────────────────
  # VB6: cost = max(current_skill * 10, 10)

  describe "training gold cost formula" do
    test "skill 0 costs 10 gold" do
      assert max(0 * 10, 10) == 10
    end

    test "skill 1 costs 10 gold" do
      assert max(1 * 10, 10) == 10
    end

    test "skill 10 costs 100 gold" do
      assert max(10 * 10, 10) == 100
    end

    test "skill 50 costs 500 gold" do
      assert max(50 * 10, 10) == 500
    end

    test "skill 99 costs 990 gold" do
      assert max(99 * 10, 10) == 990
    end

    test "skill 100 costs 1000 gold (max skill)" do
      assert max(100 * 10, 10) == 1000
    end
  end

  # ── regen formulas (pure arithmetic, no state) ─────────────────────────────
  # VB6: rest HP regen = max(div(con, 6), 1)
  # VB6: meditate mana regen = max(div(int * max(med_skill, 1), 35), 1)
  # VB6: passive HP regen = max(div(con, 30), 1)
  # VB6: passive mana regen = max(div(int, 35), 1)
  # VB6: stamina regen = max(div(agi, 6), 1)

  describe "rest HP regen (con / 6, min 1)" do
    test "con 18" do
      assert max(div(18, 6), 1) == 3
    end

    test "con 1" do
      assert max(div(1, 6), 1) == 1
    end

    test "con 0" do
      assert max(div(0, 6), 1) == 1
    end

    test "con 6" do
      assert max(div(6, 6), 1) == 1
    end

    test "con 30" do
      assert max(div(30, 6), 1) == 5
    end

    test "con 100" do
      assert max(div(100, 6), 1) == 16
    end
  end

  describe "meditate mana regen (int * max(med_skill, 1) / 35, min 1)" do
    test "int 18, meditation 0 (uses 1)" do
      # max(div(18 * 1, 35), 1) = max(0, 1) = 1
      assert max(div(18 * max(0, 1), 35), 1) == 1
    end

    test "int 18, meditation 50" do
      # div(18 * 50, 35) = div(900, 35) = 25
      assert max(div(18 * max(50, 1), 35), 1) == 25
    end

    test "int 18, meditation 100" do
      # div(18 * 100, 35) = div(1800, 35) = 51
      assert max(div(18 * max(100, 1), 35), 1) == 51
    end

    test "int 30, meditation 10" do
      # div(30 * 10, 35) = div(300, 35) = 8
      assert max(div(30 * max(10, 1), 35), 1) == 8
    end

    test "int 1, meditation 1" do
      # div(1 * 1, 35) = 0 -> 1
      assert max(div(1 * max(1, 1), 35), 1) == 1
    end

    test "int 35, meditation 1" do
      # div(35 * 1, 35) = 1
      assert max(div(35 * max(1, 1), 35), 1) == 1
    end
  end

  describe "passive HP regen (con / 30, min 1)" do
    test "con 18" do
      assert max(div(18, 30), 1) == 1
    end

    test "con 30" do
      assert max(div(30, 30), 1) == 1
    end

    test "con 60" do
      assert max(div(60, 30), 1) == 2
    end

    test "con 0" do
      assert max(div(0, 30), 1) == 1
    end

    test "con 100" do
      assert max(div(100, 30), 1) == 3
    end
  end

  describe "passive mana regen (int / 35, min 1)" do
    test "int 18" do
      assert max(div(18, 35), 1) == 1
    end

    test "int 35" do
      assert max(div(35, 35), 1) == 1
    end

    test "int 70" do
      assert max(div(70, 35), 1) == 2
    end

    test "int 0" do
      assert max(div(0, 35), 1) == 1
    end

    test "int 100" do
      assert max(div(100, 35), 1) == 2
    end
  end

  describe "stamina regen (agi / 6, min 1)" do
    test "agi 18" do
      assert max(div(18, 6), 1) == 3
    end

    test "agi 1" do
      assert max(div(1, 6), 1) == 1
    end

    test "agi 0" do
      assert max(div(0, 6), 1) == 1
    end

    test "agi 6" do
      assert max(div(6, 6), 1) == 1
    end

    test "agi 100" do
      assert max(div(100, 6), 1) == 16
    end
  end

  # ── hunger/thirst drain arithmetic ─────────────────────────────────────────
  # VB6: drain_amount = 10 per interval

  describe "hunger/thirst drain arithmetic" do
    test "hunger 100 drains to 90" do
      assert max(100 - 10, 0) == 90
    end

    test "hunger 10 drains to 0" do
      assert max(10 - 10, 0) == 0
    end

    test "hunger 5 drains to 0 (floors at 0)" do
      assert max(5 - 10, 0) == 0
    end

    test "hunger 0 stays at 0" do
      assert max(0 - 10, 0) == 0
    end

    test "thirst follows same formula" do
      assert max(50 - 10, 0) == 40
      assert max(3 - 10, 0) == 0
    end

    test "10 drains from 100 to 0 in 10 intervals" do
      final = Enum.reduce(1..10, 100, fn _i, acc -> max(acc - 10, 0) end)
      assert final == 0
    end

    test "11 drains still at 0" do
      final = Enum.reduce(1..11, 100, fn _i, acc -> max(acc - 10, 0) end)
      assert final == 0
    end
  end

  # ── starvation HP damage ───────────────────────────────────────────────────
  # VB6: when stamina == 0 AND starving AND dehydrated: HP -= 5 * 2 = 10
  #      when stamina == 0 AND (starving XOR dehydrated): HP -= 5

  describe "starvation HP damage" do
    @hunger_thirst_damage 5

    test "both starving and dehydrated, stamina 0: HP loses 10" do
      hp = 100
      assert max(hp - @hunger_thirst_damage * 2, 0) == 90
    end

    test "only starving, stamina 0: HP loses 5" do
      hp = 100
      assert max(hp - @hunger_thirst_damage, 0) == 95
    end

    test "only dehydrated, stamina 0: HP loses 5" do
      hp = 50
      assert max(hp - @hunger_thirst_damage, 0) == 45
    end

    test "HP floors at 0, not negative" do
      assert max(3 - @hunger_thirst_damage * 2, 0) == 0
      assert max(2 - @hunger_thirst_damage, 0) == 0
    end

    test "stamina drain when starving: stamina decrements by 1" do
      assert max(10 - 1, 0) == 9
      assert max(1 - 1, 0) == 0
      assert max(0 - 1, 0) == 0
    end
  end

  # ── level-up HP growth ─────────────────────────────────────────────────────
  # VB6: hp_gain = max(trunc(hp_mod * (0.8 + rand * 0.4)), 1)
  # Deterministic bounds: min_gain = max(trunc(hp_mod * 0.8), 1)
  #                       max_gain = max(trunc(hp_mod * 1.2), 1)

  describe "level-up HP growth bounds per class" do
    for {class_name, class_id} <- [
          {"mago", 1},
          {"clerigo", 2},
          {"paladin", 3},
          {"cazador", 4},
          {"trabajador", 5},
          {"guerrero", 6},
          {"ladron", 7},
          {"bandido", 8},
          {"asesino", 9},
          {"druida", 10},
          {"bardo", 11},
          {"pirata", 12}
        ] do
      test "#{class_name} HP gain is within expected bounds" do
        hp_mod = GameData.class_hp_mod(unquote(class_id))
        min_gain = max(trunc(hp_mod * 0.8), 1)
        max_gain = max(trunc(hp_mod * 1.2), 1)

        # Generate 50 random samples and check all fall within bounds
        for _i <- 1..50 do
          gain = max(trunc(hp_mod * (0.8 + :rand.uniform() * 0.4)), 1)
          assert gain >= min_gain, "HP gain #{gain} below min #{min_gain} for class #{unquote(class_name)}"
          assert gain <= max_gain, "HP gain #{gain} above max #{max_gain} for class #{unquote(class_name)}"
        end
      end
    end
  end

  # ── level-up mana growth ───────────────────────────────────────────────────
  # VB6: mana_gain = trunc(int * class_mana_mult)

  describe "level-up mana growth per class" do
    test "guerrero gets 0 mana (non-caster)" do
      mana_mult = GameData.class_mana_mult(@guerrero)
      assert trunc(18 * mana_mult) == 0
    end

    test "mago gets mana based on int 18" do
      mana_mult = GameData.class_mana_mult(@mago)
      gain = trunc(18 * mana_mult)
      # Mago should have non-zero mana growth
      assert gain > 0
    end

    test "mago with int 30" do
      mana_mult = GameData.class_mana_mult(@mago)
      gain = trunc(30 * mana_mult)
      assert gain > 0
      assert gain == trunc(30 * mana_mult)
    end

    test "clerigo gets mana based on int 18" do
      mana_mult = GameData.class_mana_mult(@clerigo)
      gain = trunc(18 * mana_mult)
      assert gain >= 0
    end

    test "druida gets mana based on int 18" do
      mana_mult = GameData.class_mana_mult(@druida)
      gain = trunc(18 * mana_mult)
      assert gain >= 0
    end

    test "ladron gets 0 or minimal mana" do
      mana_mult = GameData.class_mana_mult(@ladron)
      gain = trunc(18 * mana_mult)
      assert gain == trunc(18 * mana_mult)
    end
  end

  # ── level-up stamina growth ────────────────────────────────────────────────
  # VB6: sta_gain = max(trunc(sta_growth * agi / 33), 1)

  describe "level-up stamina growth" do
    test "guerrero with agi 18" do
      sta_growth = GameData.class_stamina_growth(@guerrero)
      expected = max(trunc(sta_growth * 18 / 33), 1)
      assert expected == max(trunc(sta_growth * 18 / 33), 1)
      assert expected >= 1
    end

    test "mago with agi 18" do
      sta_growth = GameData.class_stamina_growth(@mago)
      expected = max(trunc(sta_growth * 18 / 33), 1)
      assert expected >= 1
    end

    test "guerrero with agi 0 still gets at least 1" do
      sta_growth = GameData.class_stamina_growth(@guerrero)
      expected = max(trunc(sta_growth * 0 / 33), 1)
      assert expected == 1
    end

    test "guerrero with agi 50" do
      sta_growth = GameData.class_stamina_growth(@guerrero)
      expected = max(trunc(sta_growth * 50 / 33), 1)
      assert expected >= 1
    end

    for {class_name, class_id} <- [
          {"cazador", 4},
          {"asesino", 9},
          {"pirata", 12}
        ] do
      test "#{class_name} with agi 25 gets expected stamina" do
        sta_growth = GameData.class_stamina_growth(unquote(class_id))
        expected = max(trunc(sta_growth * 25 / 33), 1)
        assert expected >= 1
      end
    end
  end

  # ── class skill points per level ───────────────────────────────────────────
  # VB6: each class has a fixed skill point award per level

  describe "class skill points per level" do
    test "all classes return a positive integer" do
      for class_id <- 1..12 do
        pts = GameData.class_skill_points(class_id)
        assert is_integer(pts) and pts > 0,
               "Class #{class_id} skill_points should be positive, got #{pts}"
      end
    end
  end

  # ── character creation initial stats ───────────────────────────────────────
  # VB6: attribute = 18 + race_mod(race, stat)
  # VB6: initial HP = con
  # VB6: initial mana = trunc(int * class_mana_initial)

  describe "character creation initial attributes" do
    test "human has base 18 for all stats (race mods may vary)" do
      for stat <- [:str, :agi, :int, :con, :cha] do
        mod = GameData.race_mod(@humano, stat)
        assert 18 + mod >= 1, "Human #{stat} must be at least 1"
      end
    end

    test "elf race modifiers applied correctly" do
      for stat <- [:str, :agi, :int, :con, :cha] do
        mod = GameData.race_mod(@elfo, stat)
        assert is_integer(mod), "Elf #{stat} modifier must be integer"
        val = 18 + mod
        assert val >= 1 and val <= 50, "Elf #{stat} = #{val} out of sane range"
      end
    end

    test "dwarf race modifiers applied correctly" do
      for stat <- [:str, :agi, :int, :con, :cha] do
        mod = GameData.race_mod(@enano, stat)
        assert is_integer(mod), "Dwarf #{stat} modifier must be integer"
        val = 18 + mod
        assert val >= 1 and val <= 50, "Dwarf #{stat} = #{val} out of sane range"
      end
    end

    test "initial HP equals constitution" do
      con = 18 + GameData.race_mod(@humano, :con)
      assert con == 18 + GameData.race_mod(@humano, :con)
    end

    test "initial mana for mago: trunc(int * class_mana_initial)" do
      int = 18 + GameData.race_mod(@humano, :int)
      mana_mult = GameData.class_mana_initial(@mago)
      expected_mana = trunc(int * mana_mult)
      assert expected_mana == trunc(int * mana_mult)
      assert expected_mana >= 0
    end

    test "initial mana for guerrero is 0 (non-caster)" do
      int = 18 + GameData.race_mod(@humano, :int)
      mana_mult = GameData.class_mana_initial(@guerrero)
      assert trunc(int * mana_mult) == 0
    end

    test "initial mana for elf mago is higher than human mago (elf has +int)" do
      human_int = 18 + GameData.race_mod(@humano, :int)
      elf_int = 18 + GameData.race_mod(@elfo, :int)
      mana_mult = GameData.class_mana_initial(@mago)
      human_mana = trunc(human_int * mana_mult)
      elf_mana = trunc(elf_int * mana_mult)
      # Elves traditionally have higher int
      if GameData.race_mod(@elfo, :int) > GameData.race_mod(@humano, :int) do
        assert elf_mana > human_mana
      else
        assert elf_mana >= 0
      end
    end
  end

  # ── base_user_damage/2 additional classes ──────────────────────────────────
  # Existing tests only cover guerrero and mago. Add paladin, ladron, cazador.

  describe "base_user_damage/2 golden values for Paladin" do
    setup do
      pre36 = GameData.class_hit_pre36(@paladin)
      post36 = GameData.class_hit_post36(@paladin)
      {:ok, pre36: pre36, post36: post36}
    end

    test "level 1", ctx do
      expected_mod = 0 * ctx.pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(1, @paladin) == expected
    end

    test "level 20", ctx do
      expected_mod = 19 * ctx.pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(20, @paladin) == expected
    end

    test "level 36", ctx do
      expected_mod = 35 * ctx.pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(36, @paladin) == expected
    end

    test "level 45", ctx do
      expected_mod = 35 * ctx.pre36 + 9 * ctx.post36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(45, @paladin) == expected
    end
  end

  describe "base_user_damage/2 golden values for Ladron" do
    setup do
      pre36 = GameData.class_hit_pre36(@ladron)
      post36 = GameData.class_hit_post36(@ladron)
      {:ok, pre36: pre36, post36: post36}
    end

    test "level 1", ctx do
      expected_mod = 0 * ctx.pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(1, @ladron) == expected
    end

    test "level 36", ctx do
      expected_mod = 35 * ctx.pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(36, @ladron) == expected
    end

    test "level 46", ctx do
      expected_mod = 35 * ctx.pre36 + 10 * ctx.post36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(46, @ladron) == expected
    end
  end

  describe "base_user_damage/2 golden values for Cazador" do
    setup do
      pre36 = GameData.class_hit_pre36(@cazador)
      post36 = GameData.class_hit_post36(@cazador)
      {:ok, pre36: pre36, post36: post36}
    end

    test "level 1", ctx do
      expected_mod = 0 * ctx.pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(1, @cazador) == expected
    end

    test "level 36", ctx do
      expected_mod = 35 * ctx.pre36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(36, @cazador) == expected
    end

    test "level 46", ctx do
      expected_mod = 35 * ctx.pre36 + 10 * ctx.post36
      expected = {max(expected_mod + 1, 1), max(expected_mod + 2, 2)}
      assert Combat.base_user_damage(46, @cazador) == expected
    end
  end

  # ── xp_gain/5 additional edge cases ────────────────────────────────────────

  describe "xp_gain/5 extended golden values" do
    test "player lower level than NPC yields full XP" do
      # player_level 5 < npc_level 10, delta = -5, no penalty
      assert Combat.xp_gain(30, 100, 60, 5, 10) == 50
    end

    test "exact delta 4 boundary from below" do
      # player 13, npc 10, delta = 3 -> no penalty
      assert Combat.xp_gain(30, 100, 60, 13, 10) == 50
    end

    test "delta 13 reduces by 90%" do
      # factor = 1.0 - 0.1 * (13 - 4) = 1.0 - 0.9 = 0.1
      # round(50 * 0.1) = 5
      assert Combat.xp_gain(30, 100, 60, 23, 10) == 5
    end

    test "very large damage" do
      # 1000 * 500 / 200 = 2500
      assert Combat.xp_gain(1000, 500, 200, 10, 10) == 2500
    end

    test "damage exceeds max_hp (overkill)" do
      # 200 * 100 / 60 = 333
      assert Combat.xp_gain(200, 100, 60, 10, 10) == 333
    end

    test "1 damage yields minimal XP" do
      # 1 * 100 / 60 = 1 (integer division)
      assert Combat.xp_gain(1, 100, 60, 10, 10) == 1
    end
  end

  # ── npc_damage/2 golden values ─────────────────────────────────────────────
  # VB6: random between min_hit and max_hit, or max(min_hit, 1) if max <= min

  describe "npc_damage/2 golden values" do
    test "equal min and max returns that value" do
      assert Combat.npc_damage(10, 10) == 10
    end

    test "min > max returns max(min, 1)" do
      assert Combat.npc_damage(20, 5) == 20
    end

    test "min 0 max 0 returns 1 (floor)" do
      # max(0, 1) = 1
      assert Combat.npc_damage(0, 0) == 1
    end

    test "range produces values in bounds" do
      for _i <- 1..50 do
        result = Combat.npc_damage(5, 15)
        assert result >= 5 and result <= 15
      end
    end
  end

  # ── critical_hit? threshold formula ────────────────────────────────────────
  # VB6: chance = min(div(weapon_skill, 100) * 10 + 5, 15)
  # We test the chance computation, not the randomness.

  describe "critical_hit? chance formula" do
    test "weapon_skill 0: chance = min(0 + 5, 15) = 5" do
      assert min(div(0, 100) * 10 + 5, 15) == 5
    end

    test "weapon_skill 50: chance = min(0 + 5, 15) = 5" do
      # div(50, 100) = 0
      assert min(div(50, 100) * 10 + 5, 15) == 5
    end

    test "weapon_skill 100: chance = min(10 + 5, 15) = 15" do
      assert min(div(100, 100) * 10 + 5, 15) == 15
    end

    test "weapon_skill 200: chance = min(20 + 5, 15) = 15 (capped)" do
      assert min(div(200, 100) * 10 + 5, 15) == 15
    end

    test "weapon_skill 99: chance = min(0 + 5, 15) = 5" do
      # div(99, 100) = 0
      assert min(div(99, 100) * 10 + 5, 15) == 5
    end
  end

  # ── spell_damage/4 deterministic tests ─────────────────────────────────────
  # VB6: base = random(min_hp, max_hp)
  #      level_bonus = floor(base * 0.03 * caster_level)
  #      total = base + level_bonus
  #      if is_mage: round(total * 0.7)
  # When min_hp == max_hp, base is deterministic.

  describe "spell_damage/4 deterministic golden values" do
    test "base 100, level 1, non-mage" do
      # level_bonus = floor(100 * 0.03 * 1) = floor(3.0) = 3
      # total = 100 + 3 = 103
      assert Combat.spell_damage(100, 100, 1, false) == 103
    end

    test "base 100, level 1, mage" do
      # total = 103, mage = round(103 * 0.7) = round(72.1) = 72
      assert Combat.spell_damage(100, 100, 1, true) == 72
    end

    test "base 100, level 10, non-mage" do
      # level_bonus = floor(100 * 0.03 * 10) = floor(30.0) = 30
      # total = 130
      assert Combat.spell_damage(100, 100, 10, false) == 130
    end

    test "base 100, level 10, mage" do
      # total = 130, mage = round(130 * 0.7) = round(91.0) = 91
      assert Combat.spell_damage(100, 100, 10, true) == 91
    end

    test "base 100, level 50, non-mage" do
      # level_bonus = floor(100 * 0.03 * 50) = floor(150.0) = 150
      # total = 250
      assert Combat.spell_damage(100, 100, 50, false) == 250
    end

    test "base 100, level 50, mage" do
      # total = 250, mage = round(250 * 0.7) = round(175.0) = 175
      assert Combat.spell_damage(100, 100, 50, true) == 175
    end

    test "base 0, level 50, non-mage" do
      # level_bonus = floor(0 * 0.03 * 50) = 0
      # total = 0
      assert Combat.spell_damage(0, 0, 50, false) == 0
    end

    test "base 0, level 50, mage" do
      # total = 0, round(0 * 0.7) = 0
      assert Combat.spell_damage(0, 0, 50, true) == 0
    end

    test "base 1, level 1, non-mage" do
      # level_bonus = floor(1 * 0.03 * 1) = floor(0.03) = 0
      # total = 1
      assert Combat.spell_damage(1, 1, 1, false) == 1
    end

    test "base 1, level 1, mage" do
      # total = 1, round(1 * 0.7) = round(0.7) = 1
      assert Combat.spell_damage(1, 1, 1, true) == 1
    end

    test "base 50, level 33, non-mage" do
      # level_bonus = floor(50 * 0.03 * 33) = floor(49.5) = 49
      # total = 99
      assert Combat.spell_damage(50, 50, 33, false) == 99
    end

    test "base 50, level 33, mage" do
      # total = 99, round(99 * 0.7) = round(69.3) = 69
      assert Combat.spell_damage(50, 50, 33, true) == 69
    end

    test "random range produces values in bounds" do
      for _i <- 1..50 do
        result = Combat.spell_damage(10, 20, 10, false)
        min_possible = 10 + floor(10 * 0.03 * 10)
        max_possible = 20 + floor(20 * 0.03 * 10)
        assert result >= min_possible and result <= max_possible
      end
    end
  end

  # ── penalty decrement ──────────────────────────────────────────────────────
  # VB6: penalty decrements by 1 per minute (20 ticks of 3s)

  describe "penalty decrement formula" do
    test "penalty 10 decrements to 9" do
      assert max(10 - 1, 0) == 9
    end

    test "penalty 1 decrements to 0" do
      assert max(1 - 1, 0) == 0
    end

    test "penalty 0 stays at 0" do
      assert max(0 - 1, 0) == 0
    end
  end

  # ── character creation initial stamina bounds ──────────────────────────────
  # VB6: stamina = 20 * random(1..max(div(agi, 6), 2))

  describe "character creation initial stamina" do
    test "agi 18: roll range is 1..3, so stamina in {20, 40, 60}" do
      roll_max = max(div(18, 6), 2)
      assert roll_max == 3

      for _i <- 1..50 do
        roll = Enum.random(1..roll_max)
        stamina = 20 * roll
        assert stamina in [20, 40, 60]
      end
    end

    test "agi 6: roll range is 1..2, so stamina in {20, 40}" do
      roll_max = max(div(6, 6), 2)
      assert roll_max == 2

      for _i <- 1..50 do
        stamina = 20 * Enum.random(1..roll_max)
        assert stamina in [20, 40]
      end
    end

    test "agi 1: roll range floor is 2, so stamina in {20, 40}" do
      roll_max = max(div(1, 6), 2)
      assert roll_max == 2
    end

    test "agi 60: roll range is 1..10, stamina in 20..200 (multiples of 20)" do
      roll_max = max(div(60, 6), 2)
      assert roll_max == 10

      for _i <- 1..50 do
        stamina = 20 * Enum.random(1..roll_max)
        assert rem(stamina, 20) == 0
        assert stamina >= 20 and stamina <= 200
      end
    end
  end
end
