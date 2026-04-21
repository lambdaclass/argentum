defmodule Arena.FormulaGoldenTest do
  @moduledoc """
  Golden tests for VB6 combat and progression formulas.

  Focuses on formula paths not exhaustively covered by existing golden tests:
  - cap_xp_to_pool/2 (VB6 ExpCount tracking)
  - roll_skill_gain/6 (VB6 SubirSkill — Drift #11)
  - level_up_gains/6 with deterministic rand_hp_factor
  - Composite hit_chance → xp_gain pipelines
  - XP penalty at exact boundary transitions
  - Melee damage formula with combined weapon + user damage ranges
  - Spell damage mage modifier precision
  - apply_defense boundary: damage == defense
  - npc_damage minimum bounds
  - base_user_damage monotonicity invariant across all levels
  - apply_elemental_modifiers with zero masks
  """
  use ExUnit.Case, async: true

  alias Arena.Combat
  alias Arena.Data.GameData

  # Class IDs matching the VB6 engine (1-based)
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

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── cap_xp_to_pool/2 golden tests ──────────────────────────────────────

  describe "cap_xp_to_pool/2 golden values" do
    test "xp gained less than pool returns full xp" do
      assert Combat.cap_xp_to_pool(30, 100) == {30, 70}
    end

    test "xp gained equals pool returns full xp and depletes pool" do
      assert Combat.cap_xp_to_pool(100, 100) == {100, 0}
    end

    test "xp gained exceeds pool, capped to pool" do
      assert Combat.cap_xp_to_pool(150, 100) == {100, 0}
    end

    test "pool of 0 yields 0 xp" do
      assert Combat.cap_xp_to_pool(50, 0) == {0, 0}
    end

    test "pool of 1 caps large xp to 1" do
      assert Combat.cap_xp_to_pool(9999, 1) == {1, 0}
    end

    test "xp gained of 0 returns 0 and unchanged pool" do
      # xp_gained 0 is not > 0, falls to second clause
      assert Combat.cap_xp_to_pool(0, 100) == {0, 100}
    end

    test "negative xp_gained passes through unchanged" do
      # Falls to second clause (not > 0)
      assert Combat.cap_xp_to_pool(-5, 100) == {-5, 100}
    end

    test "pool tracks remaining correctly after multiple caps" do
      # Simulate two hits against same NPC
      {xp1, pool1} = Combat.cap_xp_to_pool(30, 100)
      assert {xp1, pool1} == {30, 70}

      {xp2, pool2} = Combat.cap_xp_to_pool(50, pool1)
      assert {xp2, pool2} == {50, 20}

      {xp3, pool3} = Combat.cap_xp_to_pool(50, pool2)
      assert {xp3, pool3} == {20, 0}

      # Pool exhausted
      {xp4, pool4} = Combat.cap_xp_to_pool(10, pool3)
      assert {xp4, pool4} == {0, 0}
    end
  end

  # ── roll_skill_gain/6 golden values ─────────────────────────────────────
  # Drift #11: VB6 `SubirSkill` replaced the flat 35% probability.

  describe "roll_skill_gain/6 golden values" do
    test "skill at MAXSKILLPOINTS (100) never gains" do
      for _ <- 1..200 do
        assert Combat.roll_skill_gain(50, 100, false, 100, 100, 1.0) == :no_gain
      end
    end

    test "skill above MAXSKILLPOINTS never gains" do
      for _ <- 1..200 do
        assert Combat.roll_skill_gain(50, 101, false, 100, 100, 1.0) == :no_gain
      end
    end

    test "hunger 0 never gains" do
      for _ <- 1..200 do
        assert Combat.roll_skill_gain(40, 10, false, 0, 100, 1.0) == :no_gain
      end
    end

    test "thirst 0 never gains" do
      for _ <- 1..200 do
        assert Combat.roll_skill_gain(40, 10, false, 100, 0, 1.0) == :no_gain
      end
    end

    test "per-level cap: level 10 blocks gain at skill 25" do
      for _ <- 1..200 do
        assert Combat.roll_skill_gain(10, 25, false, 100, 100, 1.0) == :no_gain
      end
    end

    test "successful gain returns {:gain, 5 * xp_mult}" do
      result =
        Stream.repeatedly(fn -> Combat.roll_skill_gain(1, 0, true, 100, 100, 2.0) end)
        |> Enum.find(&match?({:gain, _}, &1))

      assert {:gain, 10} = result
    end
  end

  # ── level_up_gains/6 deterministic tests ────────────────────────────────

  describe "level_up_gains/6 deterministic golden values" do
    test "returns :no_level_up when XP is insufficient" do
      # Level 1 with 0 XP - shouldn't level up
      assert Combat.level_up_gains(1, @guerrero, 18, 18, 0, 0.5) == :no_level_up
    end

    test "VB6 biased HP gain is within bounded range (constitution-aware)" do
      # VB6: HP gain uses RandomIntBiased with PromClaseRaza +/- RangoVidas
      next_xp = GameData.exp_for_level(2)

      if next_xp do
        current_xp = next_xp + 10
        con = 18

        {:level_up, gains} =
          Combat.level_up_gains(1, @guerrero, 18, 18, current_xp, 0.0, con, con)

        assert gains.new_level == 2
        assert gains.hp_gain >= 1
        assert gains.remaining_xp == current_xp - next_xp

        # HP gain should be within reasonable range for the class
        hp_mod = GameData.class_hp_mod(@guerrero)
        prom = hp_mod - (21 - con) * 0.5
        # With RangoVidas=2, range is [prom-2, prom+2] plus capping
        assert gains.hp_gain <= round(prom + 2 + 10)
      end
    end

    test "level up with rand_hp_factor 1.0 yields valid HP gain" do
      next_xp = GameData.exp_for_level(2)

      if next_xp do
        current_xp = next_xp

        {:level_up, gains} =
          Combat.level_up_gains(1, @guerrero, 18, 18, current_xp, 1.0, 18, 18)

        assert gains.hp_gain >= 1
        assert gains.new_level == 2
      end
    end

    test "mana gain uses VB6 GetMaxMana delta formula" do
      # VB6: GetMaxMana = int * ManaInicial + (MultMana * int) * (level - 1)
      next_xp = GameData.exp_for_level(2)

      if next_xp do
        int = 25
        {:level_up, gains} =
          Combat.level_up_gains(1, @mago, int, 18, next_xp, 0.5, 18, 18)

        mana_initial = GameData.class_mana_initial(@mago)
        mana_mult = GameData.class_mana_mult(@mago)
        max_mana_old = trunc(int * mana_initial + mana_mult * int * 0)
        max_mana_new = trunc(int * mana_initial + mana_mult * int * 1)
        expected_mana = max_mana_new - max_mana_old

        assert gains.mana_gain == expected_mana
      end
    end

    test "stamina gain uses VB6 GetMaxStamina delta formula" do
      # VB6: GetMaxStamina = 60 + (level - 1) * AumentoSta
      next_xp = GameData.exp_for_level(2)

      if next_xp do
        agi = 20
        {:level_up, gains} =
          Combat.level_up_gains(1, @guerrero, 18, agi, next_xp, 0.5, 18, 18)

        sta_growth = GameData.class_stamina_growth(@guerrero)
        # Delta: (60 + 1*sta_growth) - (60 + 0*sta_growth) = sta_growth
        expected_sta = trunc(sta_growth)

        assert gains.sta_gain == expected_sta
      end
    end

    test "guerrero gets 0 mana per level" do
      next_xp = GameData.exp_for_level(2)

      if next_xp do
        {:level_up, gains} =
          Combat.level_up_gains(1, @guerrero, 18, 18, next_xp, 0.5)

        assert gains.mana_gain == 0
      end
    end

    test "skill_points comes from class data" do
      next_xp = GameData.exp_for_level(2)

      if next_xp do
        {:level_up, gains} =
          Combat.level_up_gains(1, @guerrero, 18, 18, next_xp, 0.5)

        expected_pts = GameData.class_skill_points(@guerrero)
        assert gains.skill_points == expected_pts
      end
    end

    test "min_hit and max_hit match base_user_damage for new level" do
      next_xp = GameData.exp_for_level(2)

      if next_xp do
        {:level_up, gains} =
          Combat.level_up_gains(1, @guerrero, 18, 18, next_xp, 0.5)

        {expected_min, expected_max} = Combat.base_user_damage(2, @guerrero)
        assert gains.min_hit == expected_min
        assert gains.max_hit == expected_max
      end
    end

    test "remaining_xp is correctly computed" do
      next_xp = GameData.exp_for_level(2)

      if next_xp do
        overflow = 42
        {:level_up, gains} =
          Combat.level_up_gains(1, @guerrero, 18, 18, next_xp + overflow, 0.5)

        assert gains.remaining_xp == overflow
      end
    end

    test "exactly meeting XP threshold triggers level up with 0 remaining" do
      next_xp = GameData.exp_for_level(2)

      if next_xp do
        {:level_up, gains} =
          Combat.level_up_gains(1, @guerrero, 18, 18, next_xp, 0.5)

        assert gains.remaining_xp == 0
      end
    end
  end

  # ── XP penalty exact boundary transitions ───────────────────────────────

  describe "xp_gain penalty boundary transitions" do
    test "delta 4 is last penalty-free level" do
      base = Combat.xp_gain(60, 200, 120, 14, 10)
      assert base == div(60 * 200, 120)
      assert base == 100
    end

    test "delta 5 applies exactly 10% penalty" do
      penalized = Combat.xp_gain(60, 200, 120, 15, 10)
      # base = 100, factor = 0.9
      assert penalized == 90
    end

    test "delta 8 applies exactly 40% penalty" do
      penalized = Combat.xp_gain(60, 200, 120, 18, 10)
      # factor = 1.0 - 0.1 * 4 = 0.6
      assert penalized == 60
    end

    test "delta 14 zeroes XP exactly" do
      penalized = Combat.xp_gain(60, 200, 120, 24, 10)
      # factor = 1.0 - 0.1 * 10 = 0.0
      assert penalized == 0
    end

    test "negative delta (player below NPC) gives no penalty" do
      result = Combat.xp_gain(60, 200, 120, 5, 10)
      assert result == 100
    end

    test "delta 0 gives no penalty" do
      result = Combat.xp_gain(60, 200, 120, 10, 10)
      assert result == 100
    end
  end

  # ── Melee damage with combined weapon + user damage ─────────────────────

  describe "melee_damage deterministic golden values with user damage" do
    test "user damage adds to raw before class modifier" do
      dmg_mod = GameData.class_damage_mod(@guerrero)
      # weapon_dmg = 15 (min==max), user_dmg = 10 (min==max), str = 20
      # str_bonus = 15 * 0.2 * max(0, 20 - 15) = 15 * 0.2 * 5 = 15
      # raw = (3 * 15 + 15 + 10) * dmg_mod = 70 * dmg_mod
      expected = max(round(70 * dmg_mod), 1)
      assert Combat.melee_damage(15, 15, 20, @guerrero, 10, 10) == expected
    end

    test "all classes produce different damage for same inputs" do
      all_classes = [@mago, @clerigo, @paladin, @cazador, @trabajador,
                     @guerrero, @ladron, @bandido, @asesino, @druida, @bardo, @pirata]

      damages =
        for class_id <- all_classes do
          Combat.melee_damage(20, 20, 25, class_id, 5, 5)
        end

      # All should be >= 1
      for dmg <- damages, do: assert(dmg >= 1)

      # At least some classes should produce different values
      assert length(Enum.uniq(damages)) > 1
    end

    test "pirata damage is computable and positive" do
      dmg_mod = GameData.class_damage_mod(@pirata)
      # weapon 30, str 22, user_dmg 8
      # str_bonus = 30 * 0.2 * (22 - 15) = 30 * 0.2 * 7 = 42
      # raw = (90 + 42 + 8) * dmg_mod = 140 * dmg_mod
      expected = max(round(140 * dmg_mod), 1)
      assert Combat.melee_damage(30, 30, 22, @pirata, 8, 8) == expected
    end

    test "bandido damage with str below threshold" do
      dmg_mod = GameData.class_damage_mod(@bandido)
      # str = 10 < 15, so str_bonus = 0
      # raw = (3 * 25 + 0 + 3) * dmg_mod = 78 * dmg_mod
      expected = max(round(78 * dmg_mod), 1)
      assert Combat.melee_damage(25, 25, 10, @bandido, 3, 3) == expected
    end
  end

  # ── Spell damage mage modifier precision ────────────────────────────────

  describe "spell_damage mage modifier precision" do
    test "mage modifier on odd total" do
      # base 15, level 20, non-mage
      # level_bonus = floor(15 * 0.03 * 20) = floor(9.0) = 9
      # total = 24
      assert Combat.spell_damage(15, 15, 20, false) == 24

      # mage: round(24 * 0.7) = round(16.8) = 17
      assert Combat.spell_damage(15, 15, 20, true) == 17
    end

    test "mage modifier on even total" do
      # base 20, level 10, non-mage
      # level_bonus = floor(20 * 0.03 * 10) = floor(6.0) = 6
      # total = 26
      assert Combat.spell_damage(20, 20, 10, false) == 26

      # mage: round(26 * 0.7) = round(18.2) = 18
      assert Combat.spell_damage(20, 20, 10, true) == 18
    end

    test "base 50 level 25 non-mage" do
      # level_bonus = floor(50 * 0.03 * 25) = floor(37.5) = 37
      # total = 87
      assert Combat.spell_damage(50, 50, 25, false) == 87
    end

    test "base 50 level 25 mage" do
      # total = 87, mage = round(87 * 0.7) = round(60.9) = 61
      assert Combat.spell_damage(50, 50, 25, true) == 61
    end
  end

  # ── apply_defense boundary tests ────────────────────────────────────────

  describe "apply_defense boundary: damage equals defense" do
    test "damage exactly matches defense yields 0" do
      {result, _loc} = Combat.apply_defense(50, {50, 50})
      assert result == 0
    end

    test "damage 1 less than defense yields 0" do
      {result, _loc} = Combat.apply_defense(49, {50, 50})
      assert result == 0
    end

    test "damage 1 more than defense yields 1" do
      {result, _loc} = Combat.apply_defense(51, {50, 50})
      assert result == 1
    end

    test "zero damage against any defense yields 0" do
      {result, _loc} = Combat.apply_defense(0, {100, 100})
      assert result == 0
    end

    test "any damage against zero defense passes through" do
      {result, _loc} = Combat.apply_defense(75, {0, 0})
      assert result == 75
    end

    test "hit location is always :head or :body" do
      for _ <- 1..30 do
        {_dmg, loc} = Combat.apply_defense(100, {10, 10})
        assert loc in [:head, :body]
      end
    end
  end

  # ── npc_damage minimum bounds ───────────────────────────────────────────

  describe "npc_damage minimum bounds" do
    test "min == max == 1 always returns 1" do
      assert Combat.npc_damage(1, 1) == 1
    end

    test "min 5 max 5 returns 5" do
      assert Combat.npc_damage(5, 5) == 5
    end

    test "min > max returns max(min, 1)" do
      assert Combat.npc_damage(10, 3) == 10
    end

    test "min and max both 0 returns 1 (floor)" do
      assert Combat.npc_damage(0, 0) == 1
    end

    test "large range produces values in bounds" do
      for _ <- 1..50 do
        result = Combat.npc_damage(10, 100)
        assert result >= 10 and result <= 100
      end
    end
  end

  # ── base_user_damage monotonicity invariant ─────────────────────────────

  describe "base_user_damage monotonicity: damage never decreases with level" do
    for {class_id, class_name} <- [
          {1, "mago"}, {2, "clerigo"}, {3, "paladin"}, {4, "cazador"},
          {5, "trabajador"}, {6, "guerrero"}, {7, "ladron"}, {8, "bandido"},
          {9, "asesino"}, {10, "druida"}, {11, "bardo"}, {12, "pirata"}
        ] do
      test "#{class_name} damage is monotonically non-decreasing from level 1 to 50" do
        damages =
          for level <- 1..50 do
            {min_hit, _max_hit} = Combat.base_user_damage(level, unquote(class_id))
            min_hit
          end

        for [prev, curr] <- Enum.chunk_every(damages, 2, 1, :discard) do
          assert curr >= prev,
            "#{unquote(class_name)} base_user_damage decreased: #{prev} -> #{curr}"
        end
      end
    end
  end

  # ── apply_elemental_modifiers with zero masks ───────────────────────────

  describe "apply_elemental_modifiers with zero masks" do
    test "attacker_tags 0 returns damage unchanged" do
      assert Combat.apply_elemental_modifiers(100, 0, 0b1111) == 100
    end

    test "defender_tags 0 returns damage unchanged" do
      assert Combat.apply_elemental_modifiers(100, 0b1111, 0) == 100
    end

    test "both tags 0 returns damage unchanged" do
      assert Combat.apply_elemental_modifiers(100, 0, 0) == 100
    end

    test "zero damage with non-zero tags stays 0" do
      assert Combat.apply_elemental_modifiers(0, 1, 1) == 0
    end
  end

  # ── Composite pipeline: melee damage → critical → xp_gain ──────────────

  describe "composite pipeline golden values" do
    test "guerrero hits NPC: melee + critical + XP calculation" do
      dmg_mod = GameData.class_damage_mod(@guerrero)
      # Deterministic melee: weapon 20/20, str 25, user 5/5
      # str_bonus = 20 * 0.2 * 10 = 40
      # raw = (60 + 40 + 5) * dmg_mod = 105 * dmg_mod
      base_dmg = max(round(105 * dmg_mod), 1)

      # Apply critical (VB6: CriticalHitDmgModifier = 0.33)
      crit_dmg = Combat.apply_critical(base_dmg)
      assert crit_dmg == round(base_dmg + base_dmg * 0.33)

      # XP from damage: npc_give_exp=200, npc_max_hp=150, player_level=10, npc_level=10
      xp = Combat.xp_gain(crit_dmg, 200, 150, 10, 10)
      expected_xp = div(crit_dmg * 200, 150)
      assert xp == max(expected_xp, 0)
    end

    test "mago spell pipeline: spell_damage + magic_resistance + xp" do
      # Deterministic spell: base 80, level 15, mage
      # level_bonus = floor(80 * 0.03 * 15) = floor(36.0) = 36
      # total = 116, mage = round(116 * 0.7) = round(81.2) = 81
      spell_dmg = Combat.spell_damage(80, 80, 15, true)
      assert spell_dmg == 81

      # 30% magic resistance
      reduced = Combat.apply_magic_resistance(spell_dmg, 30)
      # round(81 * 0.7) = round(56.7) = 57
      assert reduced == 57

      # XP: npc_give_exp=150, npc_max_hp=100, player=15, npc=12
      xp = Combat.xp_gain(reduced, 150, 100, 15, 12)
      # base = div(57 * 150, 100) = 85, delta = 3, no penalty
      assert xp == 85
    end
  end

  # ── adjust_hit_for_meditate combined with hit_chance ────────────────────

  describe "adjust_hit_for_meditate integration with hit_chance" do
    test "hit chance adjusted for meditation is always within 10..90" do
      for base_hit <- [5, 10, 25, 50, 75, 90, 95] do
        adjusted = Combat.adjust_hit_for_meditate(base_hit, true)
        assert adjusted >= 10 and adjusted <= 90,
          "Meditate-adjusted hit #{adjusted} out of range for base #{base_hit}"
      end
    end

    test "meditation always increases hit chance (reduces miss chance by 25%)" do
      for base_hit <- [5, 10, 25, 50, 75] do
        adjusted = Combat.adjust_hit_for_meditate(base_hit, true)
        assert adjusted >= base_hit,
          "Meditate should not reduce hit chance: #{base_hit} -> #{adjusted}"
      end
    end
  end

  # ── shield_block? with 0 shield_pct ─────────────────────────────────────

  describe "shield_block? protocol invariant" do
    test "0 shield_pct always returns false regardless of skills" do
      for _ <- 1..20 do
        refute Combat.shield_block?(0, 100, 0)
        refute Combat.shield_block?(0, 50, 50)
        refute Combat.shield_block?(0, 0, 0)
      end
    end
  end
end
