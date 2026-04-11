defmodule Arena.CombatPropertyTest do
  @moduledoc """
  Property-based / fuzz tests for combat formulas.
  Uses randomized inputs to verify invariants hold across the entire input space.
  Each invariant is tested with 1000+ random samples.
  """
  use ExUnit.Case, async: true

  alias Arena.Combat

  @iterations 1000

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # Valid class IDs used in GameData
  @class_ids [1, 2, 3, 4, 5, 6]

  defp rand_class, do: Enum.random(@class_ids)
  defp rand_skill, do: :rand.uniform(100)
  defp rand_stat, do: :rand.uniform(50)
  defp rand_level, do: :rand.uniform(50)
  defp rand_damage, do: :rand.uniform(200)
  defp rand_pct, do: :rand.uniform(100)

  # ---- hit_chance: always in [5, 95] ----

  describe "hit_chance invariant: always in [5, 95]" do
    test "#{@iterations} random combatant pairs" do
      for _ <- 1..@iterations do
        result =
          Combat.hit_chance(
            rand_skill(),
            rand_stat(),
            rand_level(),
            rand_class(),
            rand_skill(),
            rand_stat(),
            rand_level(),
            rand_class()
          )

        assert result >= 5 and result <= 95,
               "hit_chance=#{result} out of [5, 95]"
      end
    end

    test "extreme attacker vs zero defender" do
      for _ <- 1..100 do
        result = Combat.hit_chance(100, 50, 50, rand_class(), 0, 0, 1, rand_class())
        assert result >= 5 and result <= 95
      end
    end

    test "zero attacker vs extreme defender" do
      for _ <- 1..100 do
        result = Combat.hit_chance(0, 0, 1, rand_class(), 100, 50, 50, rand_class())
        assert result >= 5 and result <= 95
      end
    end
  end

  # ---- melee_damage: always >= 1 ----

  describe "melee_damage invariant: always >= 1" do
    test "#{@iterations} random weapon + str combinations" do
      for _ <- 1..@iterations do
        min_w = :rand.uniform(30)
        max_w = min_w + :rand.uniform(20)
        str = rand_stat()
        class = rand_class()
        user_min = :rand.uniform(10) - 1
        user_max = user_min + :rand.uniform(5)

        result = Combat.melee_damage(min_w, max_w, str, class, user_min, user_max)
        assert result >= 1, "melee_damage=#{result} below 1"
      end
    end

    test "zero weapon and zero str still >= 1" do
      for _ <- 1..100 do
        result = Combat.melee_damage(0, 0, 0, rand_class(), 0, 0)
        assert result >= 1
      end
    end

    test "zero weapon with high str still >= 1" do
      for _ <- 1..100 do
        result = Combat.melee_damage(0, 0, 50, rand_class(), 0, 0)
        assert result >= 1
      end
    end
  end

  # ---- apply_defense: damage floor at 0 ----

  describe "apply_defense invariant: result >= 0" do
    test "#{@iterations} random damage and defense values" do
      for _ <- 1..@iterations do
        raw = rand_damage()
        min_def = :rand.uniform(100) - 1
        max_def = min_def + :rand.uniform(50)

        {dmg, loc} = Combat.apply_defense(raw, {min_def, max_def})
        assert dmg >= 0, "apply_defense=#{dmg} below 0"
        assert loc in [:head, :body]
      end
    end

    test "defense exceeding damage yields 0" do
      for _ <- 1..100 do
        {dmg, _loc} = Combat.apply_defense(1, {100, 200})
        assert dmg == 0
      end
    end

    test "zero defense passes damage through" do
      for _ <- 1..100 do
        raw = rand_damage()
        {dmg, _loc} = Combat.apply_defense(raw, {0, 0})
        assert dmg == raw
      end
    end
  end

  # ---- xp_gain: never negative ----

  describe "xp_gain invariant: always >= 0" do
    test "#{@iterations} random combat scenarios" do
      for _ <- 1..@iterations do
        damage = :rand.uniform(200)
        give_exp = :rand.uniform(500)
        max_hp = :rand.uniform(500) + 1
        player_level = rand_level()
        npc_level = rand_level()

        result = Combat.xp_gain(damage, give_exp, max_hp, player_level, npc_level)
        assert result >= 0, "xp_gain=#{result} negative"
      end
    end

    test "zero damage always yields zero XP" do
      for _ <- 1..100 do
        result = Combat.xp_gain(0, :rand.uniform(500), :rand.uniform(500), rand_level(), rand_level())
        assert result == 0
      end
    end

    test "zero give_exp always yields zero XP" do
      for _ <- 1..100 do
        result = Combat.xp_gain(:rand.uniform(200), 0, :rand.uniform(500), rand_level(), rand_level())
        assert result == 0
      end
    end

    test "level penalty increases with gap" do
      # At same level, no penalty
      base = Combat.xp_gain(100, 100, 100, 10, 10)
      # At 5 levels above (penalty starts at >4)
      pen_5 = Combat.xp_gain(100, 100, 100, 15, 10)
      # At 10 levels above
      pen_10 = Combat.xp_gain(100, 100, 100, 20, 10)

      assert base > 0
      assert pen_5 < base
      assert pen_10 < pen_5
    end

    test "penalty clamps at 0 XP, not negative" do
      # 30 levels above: penalty factor would be deeply negative
      result = Combat.xp_gain(100, 100, 100, 40, 10)
      assert result == 0
    end
  end

  # ---- apply_magic_resistance: clamped to [0, damage] ----

  describe "apply_magic_resistance invariant: result in [0, damage]" do
    test "#{@iterations} random damage and resistance values" do
      for _ <- 1..@iterations do
        damage = rand_damage()
        # Allow >100% to test clamping
        resist = :rand.uniform(150)

        result = Combat.apply_magic_resistance(damage, resist)
        assert result >= 0, "magic_resist=#{result} below 0"
        assert result <= damage, "magic_resist=#{result} > original damage=#{damage}"
      end
    end

    test "0% resistance is identity" do
      for _ <- 1..100 do
        damage = rand_damage()
        assert Combat.apply_magic_resistance(damage, 0) == damage
      end
    end

    test "100% resistance yields 0" do
      for _ <- 1..100 do
        assert Combat.apply_magic_resistance(rand_damage(), 100) == 0
      end
    end
  end

  # ---- npc_hit_chance: always in [10, 90] (different bounds than PvP) ----

  describe "npc_hit_chance invariant: always in [10, 90]" do
    test "#{@iterations} random NPC vs player scenarios" do
      for _ <- 1..@iterations do
        poder = :rand.uniform(200)
        tactics = rand_skill()
        agi = rand_stat()
        level = rand_level()
        class = rand_class()

        result = Combat.npc_hit_chance(poder, tactics, agi, level, class)

        assert result >= 10 and result <= 90,
               "npc_hit_chance=#{result} out of [10, 90]"
      end
    end
  end

  # ---- npc_damage: always >= 1, always in [min, max] ----

  describe "npc_damage invariant: >= 1 and in range" do
    test "#{@iterations} random min/max pairs" do
      for _ <- 1..@iterations do
        min_hit = :rand.uniform(30)
        max_hit = min_hit + :rand.uniform(30)

        result = Combat.npc_damage(min_hit, max_hit)
        assert result >= min_hit, "npc_damage=#{result} < min=#{min_hit}"
        assert result <= max_hit, "npc_damage=#{result} > max=#{max_hit}"
      end
    end

    test "equal min/max returns that value" do
      for _ <- 1..100 do
        val = :rand.uniform(50)
        assert Combat.npc_damage(val, val) == val
      end
    end

    test "zero/zero returns at least 1" do
      assert Combat.npc_damage(0, 0) >= 1
    end
  end

  # ---- spell_damage: always positive ----

  describe "spell_damage invariant: always > 0" do
    test "#{@iterations} random spell parameters" do
      for _ <- 1..@iterations do
        min_hp = :rand.uniform(50)
        max_hp = min_hp + :rand.uniform(100)
        level = rand_level()
        is_mage = :rand.uniform(2) == 1

        result = Combat.spell_damage(min_hp, max_hp, level, is_mage)
        assert result > 0, "spell_damage=#{result} not positive"
      end
    end

    test "mage modifier always reduces damage compared to non-mage" do
      # Run enough samples to be statistically confident
      {mage_total, non_mage_total} =
        Enum.reduce(1..@iterations, {0, 0}, fn _, {m, nm} ->
          min_hp = 50
          max_hp = 100
          level = 20
          mage_dmg = Combat.spell_damage(min_hp, max_hp, level, true)
          non_mage_dmg = Combat.spell_damage(min_hp, max_hp, level, false)
          {m + mage_dmg, nm + non_mage_dmg}
        end)

      # On average, mage damage should be ~70% of non-mage
      ratio = mage_total / max(non_mage_total, 1)

      assert ratio > 0.60 and ratio < 0.80,
             "mage/non-mage ratio=#{Float.round(ratio, 3)}, expected ~0.70"
    end
  end

  # ---- shield_block?: always boolean, 0 shield never blocks ----

  describe "shield_block? invariant" do
    test "zero shield_pct always returns false" do
      for _ <- 1..100 do
        refute Combat.shield_block?(0, rand_skill(), rand_skill())
      end
    end

    test "always returns boolean" do
      for _ <- 1..@iterations do
        result = Combat.shield_block?(:rand.uniform(100), rand_skill(), rand_skill())
        assert is_boolean(result)
      end
    end
  end

  # ---- critical_hit?: always boolean ----

  describe "critical_hit? invariant" do
    test "always returns boolean" do
      for _ <- 1..@iterations do
        result = Combat.critical_hit?(rand_skill())
        assert is_boolean(result)
      end
    end

    test "crit rate is bounded (≤15% by design)" do
      hits = for _ <- 1..10_000, Combat.critical_hit?(100), do: 1
      rate = length(hits) / 10_000
      # Should be around 15% ± tolerance
      assert rate < 0.20, "crit rate=#{Float.round(rate, 3)} exceeds 20%"
    end
  end

  # ---- apply_critical: always > original damage ----

  describe "apply_critical invariant" do
    test "critical always increases damage" do
      for _ <- 1..@iterations do
        damage = :rand.uniform(200) + 1
        result = Combat.apply_critical(damage)
        assert result > damage, "critical(#{damage})=#{result}, not greater"
      end
    end

    test "multiplier is exactly 1.5x" do
      assert Combat.apply_critical(100) == 150
      assert Combat.apply_critical(10) == 15
      # round(1 * 1.5) = 2
      assert Combat.apply_critical(1) == 2
    end
  end

  # ---- base_user_damage: min < max, both >= 1 ----

  describe "base_user_damage invariant" do
    test "min_hit < max_hit for all levels and classes" do
      for level <- 1..50, class <- @class_ids do
        {min_hit, max_hit} = Combat.base_user_damage(level, class)
        assert min_hit >= 1, "min_hit=#{min_hit} < 1 at level=#{level}"
        assert max_hit >= 2, "max_hit=#{max_hit} < 2 at level=#{level}"
        assert max_hit > min_hit, "max_hit=#{max_hit} <= min_hit=#{min_hit}"
      end
    end

    test "damage increases with level" do
      for class <- @class_ids do
        {low_min, _} = Combat.base_user_damage(5, class)
        {high_min, _} = Combat.base_user_damage(40, class)
        assert high_min > low_min
      end
    end
  end

  # ---- adjust_hit_for_meditate: meditating increases hit chance ----

  describe "adjust_hit_for_meditate invariant" do
    test "meditating always increases hit chance" do
      for _ <- 1..@iterations do
        base = 5 + :rand.uniform(85)
        result = Combat.adjust_hit_for_meditate(base, true)

        assert result >= base,
               "meditate adjust(#{base})=#{result}, should be >= base"
      end
    end

    test "not meditating returns unchanged" do
      for _ <- 1..100 do
        base = 5 + :rand.uniform(85)
        assert Combat.adjust_hit_for_meditate(base, false) == base
      end
    end

    test "result always in [10, 90]" do
      for _ <- 1..@iterations do
        base = :rand.uniform(100)
        result = Combat.adjust_hit_for_meditate(base, true)

        assert result >= 10 and result <= 90,
               "meditate hit=#{result} out of [10, 90]"
      end
    end
  end
end
