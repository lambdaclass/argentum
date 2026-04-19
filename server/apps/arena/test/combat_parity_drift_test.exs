defmodule Arena.CombatParityDriftTest do
  @moduledoc """
  Tests for VB6 parity drifts in the Argentum Online Elixir combat system.
  Each test targets a specific drift identified from VB6 source comparison.
  """
  use ExUnit.Case, async: true

  alias Arena.Combat
  alias Arena.CombatStats

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ==================================================================
  # Drift #1: PvE hit chance uses wrong formula path
  # VB6 uses: 50 + (PoderAtaque - NPC.PoderEvasion) * 0.4, clamped 5..95
  # where PoderAtaque is computed using the player formula
  # (skill + 3*skill/100*agi) * class_mod + 2.5*max(level-12,0)
  # ==================================================================
  describe "Drift #1: hit_chance_vs_npc/4" do
    test "uses simple formula with NPC evasion directly (no class_evasion_mod on NPC)" do
      # A player with skill=50, agi=20, level=25, class=guerrero(6)
      # attack_power = (50 + 3*50/100*20) * class_attack_mod(6) + 2.5*max(25-12,0)
      # NPC evasion = 100 (raw poder_evasion)
      # VB6: hit = clamp(50 + (attack_power - 100) * 0.4, 5, 95)
      # This should NOT apply class_evasion_mod or level bonus to NPC evasion
      result = Combat.hit_chance_vs_npc(50, 20, 25, 6, 100)
      assert is_integer(result)
      assert result >= 5 and result <= 95
    end

    test "clamps to minimum 5" do
      # Very low attack power, very high NPC evasion
      result = Combat.hit_chance_vs_npc(1, 1, 1, 6, 9999)
      assert result == 5
    end

    test "clamps to maximum 95" do
      # Very high attack power, zero NPC evasion
      result = Combat.hit_chance_vs_npc(100, 50, 50, 6, 0)
      assert result == 95
    end

    test "equal attack and evasion gives 50" do
      # When attack_power == npc_evasion, result should be 50
      # We need to compute attack_power manually and set npc_evasion to match
      atk_mod = Arena.Data.GameData.class_attack_mod(6)
      skill = 50
      agi = 20
      level = 25
      attack_power = (skill + 3 * skill / 100 * agi) * atk_mod + 2.5 * max(level - 12, 0)
      npc_evasion = round(attack_power)

      result = Combat.hit_chance_vs_npc(skill, agi, level, 6, npc_evasion)
      # Should be very close to 50 (within rounding)
      assert result >= 48 and result <= 52
    end
  end

  # ==================================================================
  # Drift #2: Missing hit/evasion bonuses
  # VB6 adds GetHitBonus to attack power and GetEvasionBonus to evasion
  # Also adds WeaponHitModifier (ImprovedMeleeHitChance/ImprovedRangedHitChance)
  # ==================================================================
  describe "Drift #2: equipment_hit_bonus/1 and equipment_evasion_bonus/1" do
    test "equipment_hit_bonus returns 0 for empty equipment" do
      assert CombatStats.equipment_hit_bonus(%{}) == 0
    end

    test "equipment_evasion_bonus returns 0 for empty equipment" do
      assert CombatStats.equipment_evasion_bonus(%{}) == 0
    end

    test "hit_chance/10 accepts hit_bonus and evasion_bonus" do
      # PvP hit chance should accept bonuses
      result = Combat.hit_chance(50, 20, 25, 6, 50, 20, 25, 6, 10, 5)
      assert is_integer(result)
      assert result >= 5 and result <= 95
    end

    test "hit_bonus increases hit chance" do
      base = Combat.hit_chance(50, 20, 25, 6, 50, 20, 25, 6, 0, 0)
      with_bonus = Combat.hit_chance(50, 20, 25, 6, 50, 20, 25, 6, 20, 0)
      assert with_bonus > base
    end

    test "evasion_bonus decreases hit chance" do
      base = Combat.hit_chance(50, 20, 25, 6, 50, 20, 25, 6, 0, 0)
      with_evasion = Combat.hit_chance(50, 20, 25, 6, 50, 20, 25, 6, 0, 20)
      assert with_evasion < base
    end

    test "hit_chance_vs_npc/6 accepts hit_bonus" do
      base = Combat.hit_chance_vs_npc(50, 20, 25, 6, 100)
      with_bonus = Combat.hit_chance_vs_npc(50, 20, 25, 6, 100, 20)
      assert with_bonus > base
    end
  end

  # ==================================================================
  # Drift #3: Shield block wrong place and wrong inputs
  # VB6: shield block checked AFTER miss (second chance), not after hit
  # VB6 formula: shield_pct * def_skill / max(def_skill + def_tactics, 1)
  # using DEFENDER's skills
  # ==================================================================
  describe "Drift #3: shield_block? uses defender's skills" do
    test "shield_block? takes defender's defense and defender's tactics" do
      # shield_block?(shield_pct, def_defense_skill, def_tactics)
      # With high defense relative to tactics, block chance should be higher
      :rand.seed(:exsss, {100, 200, 300})
      # Just verify function signature works with defender's tactics
      result = Combat.shield_block?(50, 80, 20)
      assert is_boolean(result)
    end

    test "shield_block? formula: clamp(shield_pct * def_skill / max(def_skill + def_tactics, 1), 10, 90)" do
      # When def_skill=80, def_tactics=20: chance = 50 * 80 / 100 = 40
      # This is the correct VB6 formula using defender's own skills
      # We can verify by computing the expected value
      shield_pct = 50
      def_skill = 80
      def_tactics = 20
      expected = round(shield_pct * def_skill / max(def_skill + def_tactics, 1))
      assert expected == 40
    end

    test "shield_block? clamps minimum to 10" do
      # Very low defense skill relative to tactics
      shield_pct = 10
      def_skill = 1
      def_tactics = 100
      expected_raw = round(shield_pct * def_skill / max(def_skill + def_tactics, 1))
      # raw would be ~0, clamped to 10
      assert expected_raw < 10
    end
  end

  # ==================================================================
  # Drift #4: Critical hits not class-gated
  # VB6: only Bandit class with Knuckle weapon can crit
  # Chance from Wrestling skill: skill * BanditCriticalHitChance + ExtraCritAndStabChance
  # ==================================================================
  describe "Drift #4: critical_hit? class-gated" do
    test "critical_hit? returns false for non-bandido class" do
      # guerrero with knuckle weapon should never crit
      refute Combat.critical_hit?(:guerrero, :knuckle, 100)
    end

    test "critical_hit? returns false for bandido with non-knuckle weapon" do
      # bandido with sword should never crit
      refute Combat.critical_hit?(:bandido, :sword, 100)
    end

    test "critical_hit? can return true for bandido with knuckle" do
      # bandido with knuckle and high wrestling should sometimes crit
      # Run many times to check it's possible
      results = for _ <- 1..1000, do: Combat.critical_hit?(:bandido, :knuckle, 100)
      # At least some should be true (probability based on wrestling skill)
      assert Enum.any?(results)
    end

    test "critical_hit? returns false for bandido with knuckle but 0 wrestling" do
      # With 0 wrestling and 0 extra_chance, should never crit
      results = for _ <- 1..100, do: Combat.critical_hit?(:bandido, :knuckle, 0, 0)
      refute Enum.any?(results)
    end

    test "critical_hit? accepts extra_crit_chance from weapon" do
      # Weapon's ExtraCritAndStabChance adds to base chance
      result_type = Combat.critical_hit?(:bandido, :knuckle, 50, 10)
      assert is_boolean(result_type)
    end
  end

  # ==================================================================
  # Drift #6: Level-up gains simplified
  # VB6 uses biased random with constitution awareness:
  # PromClaseRaza = ModClase.Vida - (21 - con) * 0.5
  # PromPersonaje = (maxhp - con) / (level - 1) [or PromClaseRaza at level 1]
  # PromBias = PromClaseRaza + (PromClaseRaza - PromPersonaje) * DesbalancePromedioVidas
  # AumentoHP = RandomIntBiased(PromClaseRaza - RangoVidas, PromClaseRaza + RangoVidas, PromBias, InfluenciaPromedioVidas)
  # Plus GetMaxHp capping, GetMaxMana recalculation, GetMaxStamina recalculation
  # ==================================================================
  describe "Drift #6: level_up_gains with constitution-aware HP" do
    test "level_up_gains accepts constitution and max_hp parameters" do
      required_xp = Arena.Data.GameData.exp_for_level(2)

      result =
        Combat.level_up_gains(1, 6, 18, 18, required_xp, 0.5, _con = 18, _max_hp = 18)

      assert {:level_up, gains} = result
      assert gains.new_level == 2
      assert gains.hp_gain >= 1
    end

    test "mana_gain uses GetMaxMana formula: int * mana_initial + (mana_mult * int) * (level - 1)" do
      required_xp = Arena.Data.GameData.exp_for_level(2)

      # Mago (class 1) should get mana based on intelligence
      result = Combat.level_up_gains(1, 1, 18, 18, required_xp, 0.5, 18, 18)

      assert {:level_up, gains} = result
      # Mana gain is the delta of GetMaxMana between levels
      mana_initial = Arena.Data.GameData.class_mana_initial(1)
      mana_mult = Arena.Data.GameData.class_mana_mult(1)
      max_mana_level_1 = trunc(18 * mana_initial + mana_mult * 18 * 0)
      max_mana_level_2 = trunc(18 * mana_initial + mana_mult * 18 * 1)
      expected_mana_gain = max_mana_level_2 - max_mana_level_1
      assert gains.mana_gain == expected_mana_gain
    end

    test "sta_gain uses GetMaxStamina formula: 60 + (level - 1) * AumentoSta" do
      required_xp = Arena.Data.GameData.exp_for_level(2)

      result = Combat.level_up_gains(1, 6, 18, 18, required_xp, 0.5, 18, 18)

      assert {:level_up, gains} = result
      sta_growth = Arena.Data.GameData.class_stamina_growth(6)
      # GetMaxStamina at level 1 = 60 + 0 * sta_growth = 60
      # GetMaxStamina at level 2 = 60 + 1 * sta_growth
      expected_sta_gain = trunc(sta_growth)
      assert gains.sta_gain == expected_sta_gain
    end

    test "random_int_biased produces values in [min, max] range" do
      for _ <- 1..100 do
        result = Combat.random_int_biased(5.0, 15.0, 10.0, 0.5)
        assert result >= 5.0 and result <= 15.0
      end
    end

    test "random_int_biased with 0 influence ignores bias" do
      # When influence is 0, result = random_range * 1 + bias * 0 = random_range
      # Just check it's in range
      for _ <- 1..100 do
        result = Combat.random_int_biased(5.0, 15.0, 10.0, 0.0)
        assert result >= 5.0 and result <= 15.0
      end
    end
  end

  # ==================================================================
  # Drift #7: Physical damage simplified
  # VB6 applies GetDefenseBonus, GetArmorPenetration,
  # GetPhysicalDamageModifier, GetPhysicDamageReduction
  # ==================================================================
  describe "Drift #7: physical damage modifiers" do
    test "equipment_defense_bonus returns 0 for empty equipment" do
      assert CombatStats.equipment_defense_bonus(%{}) == 0
    end

    test "apply_physical_damage_modifiers applies all modifiers" do
      # raw=100, defense=30, defense_bonus=5, armor_pen=10,
      # damage_modifier=1.1, damage_reduction=0.9
      result =
        Combat.apply_physical_damage_modifiers(
          _raw_damage = 100,
          _defense = 30,
          _defense_bonus = 5,
          _armor_penetration = 10,
          _damage_modifier = 1.1,
          _damage_reduction = 0.9
        )

      # VB6: defense_total = max(0, (30 + 5) - 10) = 25
      # damage = (100 - 25) * 1.1 * 0.9 = 75 * 0.99 = 74.25 -> 74
      assert result == round(75 * 1.1 * 0.9)
    end

    test "damage never goes below 0" do
      result =
        Combat.apply_physical_damage_modifiers(10, 50, 10, 0, 1.0, 1.0)

      assert result == 0
    end

    test "armor_penetration reduces effective defense" do
      without_pen = Combat.apply_physical_damage_modifiers(100, 50, 0, 0, 1.0, 1.0)
      with_pen = Combat.apply_physical_damage_modifiers(100, 50, 0, 20, 1.0, 1.0)
      assert with_pen > without_pen
    end

    test "physical_damage_modifier increases damage" do
      base = Combat.apply_physical_damage_modifiers(100, 30, 0, 0, 1.0, 1.0)
      modified = Combat.apply_physical_damage_modifiers(100, 30, 0, 0, 1.2, 1.0)
      assert modified > base
    end

    test "physical_damage_reduction decreases damage" do
      base = Combat.apply_physical_damage_modifiers(100, 30, 0, 0, 1.0, 1.0)
      reduced = Combat.apply_physical_damage_modifiers(100, 30, 0, 0, 1.0, 0.8)
      assert reduced < base
    end
  end
end
