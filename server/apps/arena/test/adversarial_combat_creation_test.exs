defmodule Arena.AdversarialCombatCreationTest do
  @moduledoc """
  Adversarial and negative-path tests for combat formulas and character creation.

  Exercises edge cases, boundary values, invalid inputs, and overflow scenarios
  that normal property/golden tests may not cover.
  """
  use ExUnit.Case, async: true

  alias Arena.Combat
  alias Arena.CharacterCreation

  # Combat class IDs used in GameData
  @class_ids [1, 2, 3, 4, 5, 6]

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp valid_params(overrides \\ %{}) do
    Map.merge(
      %{
        name: "TestChar",
        race: 1,
        gender: 1,
        class: 6,
        head: 1,
        home_city: 1,
        account_id: "acc_adversarial"
      },
      overrides
    )
  end

  # ===========================================================================
  # Combat formula adversarial tests
  # ===========================================================================

  describe "hit_chance adversarial" do
    test "1. zero weapon skill and zero attack mod returns value in 5..95" do
      for def_class <- @class_ids, atk_class <- @class_ids do
        result = Combat.hit_chance(0, 0, 1, atk_class, 0, 0, 1, def_class)
        assert result >= 5 and result <= 95,
               "hit_chance(0,0,1,#{atk_class},0,0,1,#{def_class}) = #{result}, expected 5..95"
      end
    end

    test "2. max possible values (999 skill, 999 mods) no overflow, still in range" do
      for atk_class <- @class_ids, def_class <- @class_ids do
        result = Combat.hit_chance(999, 999, 999, atk_class, 999, 999, 999, def_class)
        assert is_integer(result),
               "hit_chance with max values should return integer, got #{inspect(result)}"
        assert result >= 5 and result <= 95,
               "hit_chance with max values = #{result}, expected 5..95"
      end
    end

    test "3. negative inputs handled gracefully" do
      # Negative skill, agi, level -- should not crash
      for atk_class <- @class_ids, def_class <- @class_ids do
        result = Combat.hit_chance(-10, -5, -1, atk_class, -10, -5, -1, def_class)
        assert is_integer(result),
               "hit_chance with negatives should return integer, got #{inspect(result)}"
        assert result >= 5 and result <= 95,
               "hit_chance with negatives = #{result}, expected 5..95"
      end
    end
  end

  describe "melee_damage adversarial" do
    test "4. zero strength and zero weapon damage returns >= 1" do
      for class <- @class_ids do
        result = Combat.melee_damage(0, 0, 0, class, 0, 0)
        assert result >= 1,
               "melee_damage(0,0,0,#{class},0,0) = #{result}, expected >= 1"
      end
    end

    test "5. extremely high values no integer overflow" do
      for class <- @class_ids do
        result = Combat.melee_damage(999_999, 999_999, 999, class, 999_999, 999_999)
        assert is_integer(result),
               "melee_damage with extreme values should return integer"
        assert result >= 1,
               "melee_damage with extreme values = #{result}, expected >= 1"
      end
    end
  end

  describe "xp_gain adversarial" do
    test "6. level 0 and level -1 edge cases" do
      # level 0 attacker, level 0 defender
      result = Combat.xp_gain(100, 200, 100, 0, 0)
      assert is_integer(result)
      assert result >= 0, "xp_gain with level 0 = #{result}, expected >= 0"

      # level -1 attacker, level -1 defender
      result2 = Combat.xp_gain(100, 200, 100, -1, -1)
      assert is_integer(result2)
      assert result2 >= 0, "xp_gain with level -1 = #{result2}, expected >= 0"

      # level 0 attacker, level 1 defender
      result3 = Combat.xp_gain(100, 200, 100, 0, 1)
      assert is_integer(result3)
      assert result3 >= 0, "xp_gain(100,200,100,0,1) = #{result3}, expected >= 0"
    end

    test "7. attacker level >> defender level yields minimal or 0 XP" do
      # Player level 50 vs NPC level 1: delta = 49, penalty zeroes out
      result = Combat.xp_gain(100, 200, 100, 50, 1)
      assert result == 0,
             "xp_gain with 49-level advantage = #{result}, expected 0"
    end

    test "8. defender level >> attacker level yields higher XP (no penalty)" do
      # Player level 1 vs NPC level 50: delta = -49, no penalty
      high_xp = Combat.xp_gain(100, 200, 100, 1, 50)
      low_xp = Combat.xp_gain(100, 200, 100, 50, 1)

      assert high_xp > low_xp,
             "low-level attacker vs high NPC (#{high_xp}) should yield more XP than high-level vs low NPC (#{low_xp})"
    end
  end

  describe "spell_damage adversarial" do
    test "9. zero magic skill and zero intelligence handles gracefully" do
      # spell_damage with 0 min/max and 0 level
      result_mage = Combat.spell_damage(0, 0, 0, true)
      assert is_integer(result_mage)
      assert result_mage >= 0, "spell_damage(0,0,0,true) = #{result_mage}, expected >= 0"

      result_nonmage = Combat.spell_damage(0, 0, 0, false)
      assert is_integer(result_nonmage)
      assert result_nonmage >= 0, "spell_damage(0,0,0,false) = #{result_nonmage}, expected >= 0"

      # Very large values
      result_large = Combat.spell_damage(99999, 99999, 999, true)
      assert is_integer(result_large)
      assert result_large >= 0
    end
  end

  describe "shield_block adversarial" do
    test "10. zero shield skill computes without crash" do
      # shield_block? with 0 shield_pct returns false (guard clause: shield_pct > 0)
      result = Combat.shield_block?(0, 0, 0)
      assert result == false, "shield_block?(0,0,0) should be false"

      # With positive shield_pct but 0 defense_skill and 0 tactics
      result2 = Combat.shield_block?(50, 0, 0)
      assert is_boolean(result2), "shield_block?(50,0,0) should return boolean"

      # Extreme values
      result3 = Combat.shield_block?(100, 999, 999)
      assert is_boolean(result3), "shield_block?(100,999,999) should return boolean"
    end
  end

  # ===========================================================================
  # Character creation adversarial tests
  # ===========================================================================

  describe "character creation: invalid class" do
    test "11. class 0 (invalid) fails" do
      result = CharacterCreation.create(valid_params(%{class: 0}))
      assert {:error, {:invalid_class, 0}} = result
    end

    test "12. class 99 (out of range) fails" do
      result = CharacterCreation.create(valid_params(%{class: 99}))
      assert {:error, {:invalid_class, 99}} = result
    end
  end

  describe "character creation: invalid race" do
    test "13. race 0 fails" do
      result = CharacterCreation.create(valid_params(%{race: 0}))
      assert {:error, {:invalid_race, 0}} = result
    end

    test "13b. race 99 fails" do
      result = CharacterCreation.create(valid_params(%{race: 99}))
      assert {:error, {:invalid_race, 99}} = result
    end
  end

  describe "character creation: invalid gender" do
    test "14. gender 0 fails" do
      result = CharacterCreation.create(valid_params(%{gender: 0}))
      assert {:error, {:invalid_gender, 0}} = result
    end

    test "14b. gender 99 fails" do
      result = CharacterCreation.create(valid_params(%{gender: 99}))
      assert {:error, {:invalid_gender, 99}} = result
    end
  end

  describe "character creation: invalid head" do
    test "15. head 0 fails" do
      result = CharacterCreation.create(valid_params(%{head: 0}))
      assert {:error, :invalid_head} = result
    end

    test "15b. head 9999 fails" do
      result = CharacterCreation.create(valid_params(%{head: 9999}))
      assert {:error, :invalid_head} = result
    end
  end

  describe "character creation: invalid city" do
    test "16. city 0 fails" do
      result = CharacterCreation.create(valid_params(%{home_city: 0}))
      assert {:error, {:invalid_home_city, 0}} = result
    end

    test "16b. city 99 fails" do
      result = CharacterCreation.create(valid_params(%{home_city: 99}))
      assert {:error, {:invalid_home_city, 99}} = result
    end
  end

  describe "character creation: invalid names" do
    test "17. empty name fails" do
      result = CharacterCreation.create(valid_params(%{name: ""}))
      assert {:error, :name_too_short} = result
    end

    test "18. very long name (500 chars) fails" do
      long_name = String.duplicate("A", 500)
      result = CharacterCreation.create(valid_params(%{name: long_name}))
      assert {:error, :name_too_long} = result
    end

    test "19. SQL injection attempt fails safely" do
      sql_injection = "'; DROP TABLE characters; --"
      result = CharacterCreation.create(valid_params(%{name: sql_injection}))
      assert {:error, :name_invalid_chars} = result
    end

    test "20. unicode/emoji name fails or is handled" do
      emoji_name = "Player\u{1F600}Test"
      result = CharacterCreation.create(valid_params(%{name: emoji_name}))
      assert {:error, :name_invalid_chars} = result

      # Pure unicode
      unicode_name = "\u00E9\u00E8\u00EA\u00EB\u00E0"
      result2 = CharacterCreation.create(valid_params(%{name: unicode_name}))
      assert {:error, :name_invalid_chars} = result2

      # Chinese characters
      cjk_name = "\u4F60\u597D\u4E16\u754C"
      result3 = CharacterCreation.create(valid_params(%{name: cjk_name}))
      assert {:error, :name_invalid_chars} = result3
    end

    test "21. two characters with same name both succeed (no DB uniqueness in pure creation)" do
      # CharacterCreation.create/1 is a pure function -- it does not persist to DB.
      # Both calls should succeed since there is no uniqueness check at this layer.
      params = valid_params(%{name: "DuplicateName"})
      assert {:ok, entity1} = CharacterCreation.create(params)
      assert {:ok, entity2} = CharacterCreation.create(params)
      assert entity1.name == entity2.name
    end
  end

  # ===========================================================================
  # Boundary / edge combat tests
  # ===========================================================================

  describe "boundary: minimal combat" do
    test "22. combat between two level-1 characters with minimum stats: no crashes" do
      # hit_chance with minimum viable stats
      for atk_class <- @class_ids, def_class <- @class_ids do
        hit = Combat.hit_chance(1, 1, 1, atk_class, 1, 1, 1, def_class)
        assert hit >= 5 and hit <= 95

        # melee_damage with minimum weapon
        dmg = Combat.melee_damage(1, 1, 1, atk_class, 0, 0)
        assert dmg >= 1

        # apply_defense with minimum defense
        {final_dmg, loc} = Combat.apply_defense(dmg, {0, 0})
        assert final_dmg >= 0
        assert loc in [:head, :body]

        # base_user_damage at level 1
        {min_h, max_h} = Combat.base_user_damage(1, atk_class)
        assert min_h >= 1
        assert max_h >= 2

        # xp_gain for level 1 vs level 1
        xp = Combat.xp_gain(dmg, 100, 50, 1, 1)
        assert xp >= 0
      end
    end

    test "23. combat at maximum possible stats: no overflow" do
      for class <- @class_ids do
        # hit_chance with very high stats
        hit = Combat.hit_chance(100, 50, 50, class, 100, 50, 50, class)
        assert hit >= 5 and hit <= 95

        # melee_damage with very high weapon/str
        dmg = Combat.melee_damage(9999, 9999, 50, class, 9999, 9999)
        assert is_integer(dmg)
        assert dmg >= 1

        # apply_critical on large damage
        critted = Combat.apply_critical(dmg)
        assert is_integer(critted)
        assert critted >= dmg

        # apply_defense with large damage and large defense
        {final_dmg, _loc} = Combat.apply_defense(critted, {9999, 9999})
        assert is_integer(final_dmg)
        assert final_dmg >= 0

        # spell_damage at max
        spell = Combat.spell_damage(9999, 9999, 50, true)
        assert is_integer(spell)
        assert spell >= 0

        # apply_magic_resistance at max
        resisted = Combat.apply_magic_resistance(spell, 100)
        assert resisted == 0

        # base_user_damage at max level
        {min_h, max_h} = Combat.base_user_damage(50, class)
        assert min_h >= 1
        assert max_h > min_h
      end
    end

    test "24. XP calculation with level-up boundary: XP clamping" do
      # Large damage against high-XP NPC at same level -> large base XP, no penalty
      big_xp = Combat.xp_gain(9999, 9999, 100, 10, 10)
      assert is_integer(big_xp)
      assert big_xp >= 0
      # Should be very large: 9999 * 9999 / 100 = ~999800
      assert big_xp > 0, "large damage + large give_exp should produce positive XP"

      # XP with 0 max_hp uses 1 as denominator -> huge number
      huge_xp = Combat.xp_gain(9999, 9999, 0, 10, 10)
      assert is_integer(huge_xp)
      assert huge_xp >= 0
      # 9999 * 9999 / 1 = 99980001
      assert huge_xp > big_xp,
             "0 max_hp should yield more XP (#{huge_xp}) than 100 max_hp (#{big_xp})"

      # Verify penalty still applies even with huge base
      penalized_xp = Combat.xp_gain(9999, 9999, 100, 50, 1)
      assert penalized_xp == 0,
             "huge level gap should still zero out XP, got #{penalized_xp}"
    end
  end
end
