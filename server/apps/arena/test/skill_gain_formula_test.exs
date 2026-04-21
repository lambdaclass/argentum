defmodule Arena.SkillGainFormulaTest do
  @moduledoc """
  Drift #11: VB6 `SubirSkill` has a quadratic per-level probability, a
  per-level skill cap, a hunger/thirst gate, an expert cutoff, and grants
  `5 * ExpMult` bonus XP on success.

  VB6 refs:
  - old/server/Codigo/Modulo_UsUaRiOs.bas:1617-1670 (`SubirSkill`)
  - old/server/Codigo/Declares.bas:1083-1084 (`EXPERT_SKILL_CUTOFF = 17`,
    `NONEXPERT_SKILL_CUTOFF = 10`)
  - resources/raw/Dat/Balance.dat:328 (`DificultadSubirSkill = 2`)
  """
  use ExUnit.Case, async: true

  alias Arena.Combat

  describe "roll_skill_gain/6 hunger/thirst gate" do
    test "hunger at 0 never rises regardless of level" do
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(40, 50, false, 0, 100, 1.0) == :no_gain
      end
    end

    test "thirst at 0 never rises regardless of level" do
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(40, 50, false, 100, 0, 1.0) == :no_gain
      end
    end

    test "both hunger and thirst at 0 never rises" do
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(1, 0, true, 0, 0, 1.0) == :no_gain
      end
    end
  end

  describe "roll_skill_gain/6 per-level cap (maxPermitido)" do
    test "level 10 caps skill at 25 (maxPermitido)" do
      # VB6: even level Lvl \\ 2 * 5 = 5 * 5 = 25
      for _ <- 1..1000 do
        assert Combat.roll_skill_gain(10, 25, false, 100, 100, 1.0) == :no_gain
      end
    end

    test "level 10 allows gain at skill 24 (just below cap)" do
      gains =
        for _ <- 1..2000, reduce: 0 do
          acc ->
            case Combat.roll_skill_gain(10, 24, false, 100, 100, 1.0) do
              {:gain, _} -> acc + 1
              :no_gain -> acc
            end
        end

      assert gains > 0, "expected at least one gain at skill 24 (below cap)"
    end

    test "skill at MAXSKILLPOINTS (100) never rises" do
      for _ <- 1..500 do
        assert Combat.roll_skill_gain(50, 100, false, 100, 100, 1.0) == :no_gain
      end
    end
  end

  describe "roll_skill_gain/6 quadratic probability" do
    test "level 40 non-expert gain chance is approx 9/350 (2.57%)" do
      trials = 10_000

      gains =
        for _ <- 1..trials, reduce: 0 do
          acc ->
            case Combat.roll_skill_gain(40, 20, false, 100, 100, 1.0) do
              {:gain, _} -> acc + 1
              :no_gain -> acc
            end
        end

      rate = gains / trials
      # Expected ≈ 9/350 ≈ 2.57%
      assert rate >= 0.015 and rate <= 0.045,
             "expected non-expert gain rate ~0.0257, got #{rate}"
    end

    test "level 40 expert gain chance exceeds non-expert" do
      trials = 10_000

      non_expert_gains =
        for _ <- 1..trials, reduce: 0 do
          acc ->
            case Combat.roll_skill_gain(40, 20, false, 100, 100, 1.0) do
              {:gain, _} -> acc + 1
              :no_gain -> acc
            end
        end

      expert_gains =
        for _ <- 1..trials, reduce: 0 do
          acc ->
            case Combat.roll_skill_gain(40, 20, true, 100, 100, 1.0) do
              {:gain, _} -> acc + 1
              :no_gain -> acc
            end
        end

      # Expert cutoff 17 vs non-expert 10 — expert should be roughly ~1.8x
      assert expert_gains > non_expert_gains,
             "expected expert gains (#{expert_gains}) > non-expert gains (#{non_expert_gains})"
    end
  end

  describe "roll_skill_gain/6 XP bonus" do
    test "success returns {:gain, 5 * xp_mult}" do
      # With xp_mult 1.0 expected bonus 5.
      result =
        Stream.repeatedly(fn ->
          Combat.roll_skill_gain(1, 0, true, 100, 100, 1.0)
        end)
        |> Enum.find(&match?({:gain, _}, &1))

      assert {:gain, 5} = result
    end

    test "success scales bonus XP with xp_mult" do
      result =
        Stream.repeatedly(fn ->
          Combat.roll_skill_gain(1, 0, true, 100, 100, 3.0)
        end)
        |> Enum.find(&match?({:gain, _}, &1))

      assert {:gain, 15} = result
    end
  end
end
