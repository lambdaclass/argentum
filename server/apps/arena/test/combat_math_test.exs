defmodule Arena.CombatMathTest do
  use ExUnit.Case, async: true

  alias Arena.Combat

  @all_class_ids 1..12

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ==================================================================
  # level_up_gains/6
  # ==================================================================
  describe "level_up_gains/6" do
    test "normal level up from level 1 to 2 for guerrero (class 6)" do
      # exp_for_level(2) is the threshold; give enough XP
      required_xp = Arena.Data.GameData.exp_for_level(2)
      assert required_xp != nil

      result = Combat.level_up_gains(1, 6, 18, 18, required_xp, 0.5)

      assert {:level_up, gains} = result
      assert gains.new_level == 2
      assert gains.hp_gain >= 1
      assert gains.sta_gain >= 1
      assert gains.remaining_xp == 0
      assert gains.min_hit >= 1
      assert gains.max_hit >= gains.min_hit
    end

    test "normal level up with various class_ids" do
      for class_id <- @all_class_ids do
        required_xp = Arena.Data.GameData.exp_for_level(2)

        result = Combat.level_up_gains(1, class_id, 18, 18, required_xp, 0.5)

        assert {:level_up, gains} = result,
               "class_id #{class_id} should level up"

        assert gains.new_level == 2
        assert gains.hp_gain >= 1
        assert gains.sta_gain >= 1
        assert is_integer(gains.skill_points)
      end
    end

    test "max level returns :no_level_up" do
      # Level 50 is typically max; exp_for_level(51) should return nil
      # Use a high level where exp_for_level returns nil
      result = Combat.level_up_gains(50, 6, 18, 18, 999_999_999, 0.5)
      assert result == :no_level_up
    end

    test "insufficient XP returns :no_level_up" do
      required_xp = Arena.Data.GameData.exp_for_level(2)
      # Give 1 less than required
      result = Combat.level_up_gains(1, 6, 18, 18, required_xp - 1, 0.5)
      assert result == :no_level_up
    end

    test "edge: 0 int and 0 agi" do
      required_xp = Arena.Data.GameData.exp_for_level(2)

      result = Combat.level_up_gains(1, 6, 0, 0, required_xp, 0.5)

      assert {:level_up, gains} = result
      assert gains.new_level == 2
      assert gains.hp_gain >= 1
      # 0 agi means sta_gain = trunc(sta_growth * 0 / 33) which is 0, clamped to 1
      assert gains.sta_gain >= 1
      # 0 int means mana_gain = trunc(0 * mana_mult) = 0
      assert gains.mana_gain == 0
    end

    test "edge: very high stats (255 int, 255 agi)" do
      required_xp = Arena.Data.GameData.exp_for_level(2)

      result = Combat.level_up_gains(1, 6, 255, 255, required_xp, 0.5)

      assert {:level_up, gains} = result
      assert gains.new_level == 2
      assert gains.hp_gain >= 1
      assert gains.mana_gain >= 0
      assert gains.sta_gain >= 1
    end

    test "edge: negative XP should not level up" do
      result = Combat.level_up_gains(1, 6, 18, 18, -100, 0.5)
      assert result == :no_level_up
    end

    test "all valid class_ids produce valid gains" do
      required_xp = Arena.Data.GameData.exp_for_level(2)

      for class_id <- @all_class_ids do
        result = Combat.level_up_gains(1, class_id, 20, 20, required_xp, 0.5)

        assert {:level_up, gains} = result,
               "class_id #{class_id} failed to level up"

        assert is_integer(gains.hp_gain) and gains.hp_gain >= 1,
               "class_id #{class_id}: hp_gain should be >= 1, got #{gains.hp_gain}"

        assert is_integer(gains.mana_gain) and gains.mana_gain >= 0,
               "class_id #{class_id}: mana_gain should be >= 0, got #{gains.mana_gain}"

        assert is_integer(gains.sta_gain) and gains.sta_gain >= 1,
               "class_id #{class_id}: sta_gain should be >= 1, got #{gains.sta_gain}"

        assert is_integer(gains.skill_points) and gains.skill_points >= 0,
               "class_id #{class_id}: skill_points should be >= 0"

        assert gains.min_hit >= 1
        assert gains.max_hit >= gains.min_hit
      end
    end

    test "rand_hp_factor of 0 vs max (close to 1.0)" do
      required_xp = Arena.Data.GameData.exp_for_level(2)

      {:level_up, gains_min} = Combat.level_up_gains(1, 6, 18, 18, required_xp, 0.0)
      {:level_up, gains_max} = Combat.level_up_gains(1, 6, 18, 18, required_xp, 0.999)

      # HP gain with factor 0 should be <= HP gain with factor ~1
      assert gains_min.hp_gain <= gains_max.hp_gain
      # Both must be at least 1
      assert gains_min.hp_gain >= 1
      assert gains_max.hp_gain >= 1
    end

    test "remaining XP is correctly calculated with excess XP" do
      required_xp = Arena.Data.GameData.exp_for_level(2)

      {:level_up, gains} = Combat.level_up_gains(1, 6, 18, 18, required_xp + 500, 0.5)

      assert gains.remaining_xp == 500
    end
  end

  # ==================================================================
  # skill_gain_probability/1
  # ==================================================================
  describe "skill_gain_probability/1" do
    test "skill 0 returns 35" do
      assert Combat.skill_gain_probability(0) == 35
    end

    test "skill 50 returns 35" do
      assert Combat.skill_gain_probability(50) == 35
    end

    test "skill 99 returns 35" do
      assert Combat.skill_gain_probability(99) == 35
    end

    test "skill 100 (max) returns 0" do
      assert Combat.skill_gain_probability(100) == 0
    end

    test "skill > 100 returns 0" do
      assert Combat.skill_gain_probability(101) == 0
      assert Combat.skill_gain_probability(200) == 0
      assert Combat.skill_gain_probability(999) == 0
    end

    test "all skills from 0 to 99 return 35" do
      for skill <- 0..99 do
        assert Combat.skill_gain_probability(skill) == 35,
               "skill #{skill} should return 35"
      end
    end
  end

  # ==================================================================
  # cap_xp_to_pool/2
  # ==================================================================
  describe "cap_xp_to_pool/2" do
    test "normal: xp_gained=100, pool=1000 returns {100, 900}" do
      assert Combat.cap_xp_to_pool(100, 1000) == {100, 900}
    end

    test "capped: xp_gained=500, pool=100 returns {100, 0}" do
      assert Combat.cap_xp_to_pool(500, 100) == {100, 0}
    end

    test "zero pool: xp_gained=100, pool=0 returns {0, 0}" do
      assert Combat.cap_xp_to_pool(100, 0) == {0, 0}
    end

    test "zero XP: xp_gained=0, pool=100 returns {0, 100}" do
      # xp_gained=0 doesn't match the first guard (xp_gained > 0),
      # so falls through to the catch-all which returns {0, 100}
      assert Combat.cap_xp_to_pool(0, 100) == {0, 100}
    end

    test "negative XP falls through to catch-all" do
      # Negative xp_gained doesn't match xp_gained > 0 guard,
      # so the catch-all returns the values as-is
      assert Combat.cap_xp_to_pool(-50, 100) == {-50, 100}
    end

    test "exact pool match: xp_gained equals pool" do
      assert Combat.cap_xp_to_pool(200, 200) == {200, 0}
    end

    test "pool of 1: xp_gained=100, pool=1 returns {1, 0}" do
      assert Combat.cap_xp_to_pool(100, 1) == {1, 0}
    end

    test "xp_gained=1, pool=1 returns {1, 0}" do
      assert Combat.cap_xp_to_pool(1, 1) == {1, 0}
    end

    test "negative pool falls through to catch-all" do
      # available_pool < 0 doesn't match the guard (available_pool >= 0)
      assert Combat.cap_xp_to_pool(100, -50) == {100, -50}
    end
  end
end
