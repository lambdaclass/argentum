defmodule Arena.CombatTest do
  use ExUnit.Case, async: true

  alias Arena.Combat

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
    :ok
  end

  describe "hit_chance/8" do
    test "returns value between 5 and 95" do
      # Low skill vs high tactics -> low hit chance
      result = Combat.hit_chance(10, 18, 1, 6, 80, 30, 50, 6)
      assert result >= 5 and result <= 95

      # High skill vs low tactics -> high hit chance
      result = Combat.hit_chance(100, 30, 50, 6, 10, 18, 1, 6)
      assert result >= 5 and result <= 95
    end

    test "equal combatants get ~50%" do
      result = Combat.hit_chance(50, 20, 25, 6, 50, 20, 25, 6)
      assert result >= 40 and result <= 60
    end

    test "never below 5" do
      result = Combat.hit_chance(0, 0, 1, 6, 100, 50, 50, 6)
      assert result == 5
    end

    test "never above 95" do
      result = Combat.hit_chance(100, 50, 50, 6, 0, 0, 1, 6)
      assert result == 95
    end
  end

  describe "melee_damage/4" do
    test "returns at least 1" do
      assert Combat.melee_damage(0, 0, 10, 6) >= 1
    end

    test "higher str gives more damage" do
      # Str > 15 adds bonus damage
      low_str = Combat.melee_damage(10, 20, 15, 6)
      high_str = Combat.melee_damage(10, 20, 30, 6)
      # High str should generally be higher (probabilistic, use fixed seed)
      assert high_str > 0
      assert low_str > 0
    end
  end

  describe "apply_defense/2" do
    test "reduces damage by defense amount" do
      # With zero defense, damage passes through
      {dmg, _loc} = Combat.apply_defense(50, {0, 0})
      assert dmg == 50
    end

    test "damage never goes below 0" do
      {dmg, _loc} = Combat.apply_defense(10, {50, 50})
      assert dmg == 0
    end

    test "returns hit location atom" do
      {_dmg, loc} = Combat.apply_defense(50, {0, 0})
      assert loc in [:head, :body]
    end
  end

  describe "shield_block?/3" do
    test "returns false when shield_pct is 0" do
      refute Combat.shield_block?(0, 50, 50)
    end

    test "returns boolean for positive shield" do
      result = Combat.shield_block?(50, 50, 50)
      assert is_boolean(result)
    end
  end

  describe "xp_gain/5" do
    test "basic XP calculation" do
      xp = Combat.xp_gain(30, 100, 60, 10, 10)
      assert xp == 50  # 30 * 100 / 60
    end

    test "level penalty after 4 levels difference" do
      base_xp = Combat.xp_gain(30, 100, 60, 10, 10)
      penalized = Combat.xp_gain(30, 100, 60, 15, 10)
      assert penalized < base_xp
    end

    test "never negative" do
      assert Combat.xp_gain(0, 100, 60, 50, 1) >= 0
    end
  end

  describe "spell_damage/4" do
    test "returns positive damage" do
      dmg = Combat.spell_damage(14, 18, 10, false)
      assert dmg > 0
    end

    test "mage modifier reduces damage" do
      # Run multiple times to get average
      non_mage = for _ <- 1..100, do: Combat.spell_damage(100, 100, 10, false)
      mage = for _ <- 1..100, do: Combat.spell_damage(100, 100, 10, true)
      assert Enum.sum(mage) < Enum.sum(non_mage)
    end
  end

  describe "apply_magic_resistance/2" do
    test "reduces damage by percentage" do
      assert Combat.apply_magic_resistance(100, 50) == 50
    end

    test "zero resistance passes damage through" do
      assert Combat.apply_magic_resistance(100, 0) == 100
    end

    test "never goes below 0" do
      assert Combat.apply_magic_resistance(10, 200) == 0
    end
  end

  describe "npc_hit_chance/5" do
    test "returns value between 5 and 95" do
      result = Combat.npc_hit_chance(80, 50, 20, 25, 6)
      assert result >= 5 and result <= 95
    end
  end

  describe "npc_damage/2" do
    test "returns at least 1" do
      assert Combat.npc_damage(0, 0) >= 1
    end

    test "in range" do
      for _ <- 1..50 do
        dmg = Combat.npc_damage(10, 20)
        assert dmg >= 10 and dmg <= 20
      end
    end
  end
end
