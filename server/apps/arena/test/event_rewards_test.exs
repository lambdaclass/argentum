defmodule Arena.Events.RewardsTest do
  @moduledoc """
  Tests for Arena.Events.Rewards — pure reward computation.

  Covers:
    - Capture: winners get 2x entry fee, losers get nothing
    - Siege: top-10 get base_reward * gold_mult on defender win, nothing on attacker win
    - Tournament: winner gets entire prize pool
    - Edge cases: empty lists, zero values, single winner
  """
  use ExUnit.Case, async: true

  alias Arena.Events.Rewards

  # ── Capture ──────────────────────────────────────────────────────────

  describe "calculate_capture_rewards/2" do
    test "winners each receive 2x the entry fee" do
      winners = [1, 2, 3]
      entry_fee = 500

      result = Rewards.calculate_capture_rewards(winners, entry_fee)

      assert result == [{1, 1000}, {2, 1000}, {3, 1000}]
    end

    test "single winner receives 2x the entry fee" do
      assert Rewards.calculate_capture_rewards([42], 1000) == [{42, 2000}]
    end

    test "empty winner list returns empty rewards" do
      assert Rewards.calculate_capture_rewards([], 500) == []
    end

    test "zero entry fee returns empty rewards" do
      assert Rewards.calculate_capture_rewards([1, 2], 0) == []
    end

    test "large entry fee computes correctly" do
      result = Rewards.calculate_capture_rewards([10], 1_000_000)
      assert result == [{10, 2_000_000}]
    end
  end

  # ── Siege / Invasion ─────────────────────────────────────────────────

  describe "calculate_siege_rewards/3" do
    test "defenders win: top-10 each get 50_000 * gold_mult" do
      top10 = [{1, 150}, {2, 120}, {3, 100}]

      result = Rewards.calculate_siege_rewards(top10, :defenders_win, 1)

      assert result == [{1, 50_000}, {2, 50_000}, {3, 50_000}]
    end

    test "defenders win with fractional gold_mult" do
      top10 = [{1, 100}]

      result = Rewards.calculate_siege_rewards(top10, :defenders_win, 1.5)

      assert result == [{1, 75_000}]
    end

    test "defenders win with gold_mult of 2" do
      top10 = [{1, 200}, {2, 150}]

      result = Rewards.calculate_siege_rewards(top10, :defenders_win, 2)

      assert result == [{1, 100_000}, {2, 100_000}]
    end

    test "attackers win: nobody gets rewards" do
      top10 = [{1, 150}, {2, 120}]

      assert Rewards.calculate_siege_rewards(top10, :attackers_win, 1) == []
    end

    test "empty scoreboard returns empty rewards" do
      assert Rewards.calculate_siege_rewards([], :defenders_win, 1) == []
    end

    test "zero gold_mult returns empty rewards (integer)" do
      top10 = [{1, 100}]
      assert Rewards.calculate_siege_rewards(top10, :defenders_win, 0) == []
    end

    test "zero gold_mult returns empty rewards (float)" do
      top10 = [{1, 100}]
      assert Rewards.calculate_siege_rewards(top10, :defenders_win, 0.0) == []
    end

    test "single defender in top-10 gets full reward" do
      result = Rewards.calculate_siege_rewards([{99, 500}], :defenders_win, 1)

      assert result == [{99, 50_000}]
    end
  end

  # ── Tournament ───────────────────────────────────────────────────────

  describe "calculate_tournament_rewards/2" do
    test "winner receives entire prize pool" do
      assert Rewards.calculate_tournament_rewards(7, 100_000) == [{7, 100_000}]
    end

    test "nil winner returns empty rewards" do
      assert Rewards.calculate_tournament_rewards(nil, 100_000) == []
    end

    test "zero prize pool returns empty rewards" do
      assert Rewards.calculate_tournament_rewards(7, 0) == []
    end

    test "large prize pool" do
      assert Rewards.calculate_tournament_rewards(1, 5_000_000) == [{1, 5_000_000}]
    end
  end
end
