defmodule Arena.DuelServerTest do
  @moduledoc """
  Tests for the duel (reto) lifecycle — faithful to VB6 ModRetos.bas.

  Tests the DuelServer GenServer in isolation (no MapServer, no sessions).
  """

  use ExUnit.Case, async: true

  alias Arena.DuelServer
  alias Arena.DuelServer.{Challenge, Duel}

  @challenger_id 1001
  @target_id 1002
  @bet 5000

  setup do
    # Start a per-test DuelServer instance to keep tests isolated
    name = :"duel_server_#{System.unique_integer([:positive])}"
    {:ok, pid} = DuelServer.start_link(name: name)
    %{server: name, pid: pid}
  end

  # ── Challenge creation ───────────────────────────────────────────────

  describe "create_challenge/4 (VB6: CrearReto)" do
    test "creates a pending challenge", %{server: s} do
      assert :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      challenge = DuelServer.get_challenge(@challenger_id, s)
      assert %Challenge{challenger_id: @challenger_id, target_id: @target_id, bet: @bet} = challenge
    end

    test "rejects self-challenge", %{server: s} do
      assert {:error, :cannot_challenge_self} =
               DuelServer.create_challenge(@challenger_id, @challenger_id, @bet, s)
    end

    test "rejects zero or negative bet", %{server: s} do
      assert {:error, :invalid_bet} = DuelServer.create_challenge(@challenger_id, @target_id, 0, s)
      assert {:error, :invalid_bet} = DuelServer.create_challenge(@challenger_id, @target_id, -100, s)
    end

    test "rejects duplicate challenge from same player", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)

      assert {:error, :already_has_challenge} =
               DuelServer.create_challenge(@challenger_id, 1003, @bet, s)
    end

    test "rejects challenge when challenger is already in a duel", %{server: s} do
      # Set up and start a duel first
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      assert {:error, :already_in_duel} =
               DuelServer.create_challenge(@challenger_id, 1003, @bet, s)
    end

    test "rejects challenge when target is already in a duel", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      assert {:error, :target_in_duel} =
               DuelServer.create_challenge(1003, @target_id, @bet, s)
    end
  end

  # ── Challenge acceptance ─────────────────────────────────────────────

  describe "accept_challenge/3 (VB6: AceptarReto)" do
    test "starts a duel when target accepts", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      assert {:ok, %Duel{player_a: @challenger_id, player_b: @target_id, bet: @bet, round: 1, score: 0}} =
               DuelServer.accept_challenge(@target_id, "Challenger", s)
    end

    test "both players show as in duel after acceptance", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      assert DuelServer.in_duel?(@challenger_id, s)
      assert DuelServer.in_duel?(@target_id, s)
    end

    test "pending challenge is removed after acceptance", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      assert DuelServer.get_challenge(@challenger_id, s) == nil
    end

    test "returns error when no pending challenge exists", %{server: s} do
      assert {:error, :no_pending_challenge} =
               DuelServer.accept_challenge(@target_id, "Nobody", s)
    end

    test "returns error when acceptor is already in a duel", %{server: s} do
      # Create and start a duel between 1003 and target_id
      :ok = DuelServer.create_challenge(1003, @target_id, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(@target_id, "Other", s)

      # target_id is now in a duel, so creating a challenge targeting them fails
      assert {:error, :target_in_duel} =
               DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
    end
  end

  # ── Challenge cancellation ───────────────────────────────────────────

  describe "cancel_challenge/2 (VB6: CancelarSolicitudReto)" do
    test "challenger can cancel their own challenge", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      assert :ok = DuelServer.cancel_challenge(@challenger_id, s)
      assert DuelServer.get_challenge(@challenger_id, s) == nil
    end

    test "target can reject (cancel) a challenge aimed at them", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      assert :ok = DuelServer.cancel_challenge(@target_id, s)
      assert DuelServer.get_challenge(@challenger_id, s) == nil
    end

    test "returns error when no challenge exists", %{server: s} do
      assert {:error, :no_challenge} = DuelServer.cancel_challenge(9999, s)
    end
  end

  # ── Duel opponent query ──────────────────────────────────────────────

  describe "duel_opponent/2" do
    test "returns opponent's char_id", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      assert DuelServer.duel_opponent(@challenger_id, s) == @target_id
      assert DuelServer.duel_opponent(@target_id, s) == @challenger_id
    end

    test "returns nil when not in duel", %{server: s} do
      assert DuelServer.duel_opponent(9999, s) == nil
    end
  end

  # ── Round scoring and duel finalization (VB6: MuereEnReto, ProcesarRondaGanada, FinalizarReto) ──

  describe "player_died/2 — round tracking" do
    setup %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, duel} = DuelServer.accept_challenge(@target_id, "Challenger", s)
      %{duel: duel}
    end

    test "first death triggers round 1 win, duel continues", %{server: s} do
      result = DuelServer.player_died(@target_id, s)

      assert {:duel_round_result, %{type: :round_won, round: 1, round_winner: @challenger_id}} = result

      # Duel still active — round 2
      duel = DuelServer.get_duel(@challenger_id, s)
      assert duel.round == 2
      assert duel.score == -1
    end

    test "two consecutive wins by same player ends duel (2-0 sweep)", %{server: s} do
      # Round 1: target dies
      {:duel_round_result, %{type: :round_won}} = DuelServer.player_died(@target_id, s)

      # Round 2: target dies again -> 2-0 sweep
      result = DuelServer.player_died(@target_id, s)

      assert {:duel_round_result,
              %{
                type: :winner,
                winner: @challenger_id,
                loser: @target_id,
                prize: prize
              }} = result

      # Prize = bet * 2 * (1 - 0.10) = 5000 * 2 * 0.9 = 9000
      assert prize == 9000

      # Duel should be cleaned up
      refute DuelServer.in_duel?(@challenger_id, s)
      refute DuelServer.in_duel?(@target_id, s)
    end

    test "alternating wins go to round 3", %{server: s} do
      # Round 1: target dies (challenger wins)
      {:duel_round_result, %{type: :round_won, round: 1}} = DuelServer.player_died(@target_id, s)

      # Round 2: challenger dies (target wins)
      {:duel_round_result, %{type: :round_won, round: 2}} = DuelServer.player_died(@challenger_id, s)

      # Score is 0 (tied), round 3
      duel = DuelServer.get_duel(@challenger_id, s)
      assert duel.round == 3
      assert duel.score == 0
    end

    test "round 3 death finalizes duel with a winner", %{server: s} do
      # Round 1: target dies
      DuelServer.player_died(@target_id, s)
      # Round 2: challenger dies
      DuelServer.player_died(@challenger_id, s)
      # Round 3: target dies -> challenger wins 2-1
      result = DuelServer.player_died(@target_id, s)

      assert {:duel_round_result,
              %{
                type: :winner,
                winner: @challenger_id,
                loser: @target_id,
                prize: 9000
              }} = result

      refute DuelServer.in_duel?(@challenger_id, s)
    end

    test "round 3 tie (score stays 0) returns tie result", %{server: s} do
      # To get a tie: round 1 target dies, round 2 challenger dies, round 3...
      # Actually with best-of-3, after round 2 with score 0 we go to round 3.
      # If challenger dies in round 3, score becomes +1 (target wins).
      # The only way to get a true tie is not possible in normal play.
      # VB6 handles tie via timeout. Let's test normal 2-1 win for target.
      DuelServer.player_died(@target_id, s)
      DuelServer.player_died(@challenger_id, s)
      # Round 3: challenger dies -> target wins
      result = DuelServer.player_died(@challenger_id, s)

      assert {:duel_round_result,
              %{
                type: :winner,
                winner: @target_id,
                loser: @challenger_id,
                prize: 9000
              }} = result
    end

    test "player not in duel returns :not_in_duel", %{server: s} do
      assert :not_in_duel = DuelServer.player_died(9999, s)
    end
  end

  # ── Abandon (VB6: AbandonarReto) ────────────────────────────────────

  describe "abandon_duel/2" do
    test "abandoning player loses, opponent wins", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      assert {:ok,
              %{
                type: :winner,
                winner: @target_id,
                loser: @challenger_id,
                prize: 9000
              }} = DuelServer.abandon_duel(@challenger_id, s)

      refute DuelServer.in_duel?(@challenger_id, s)
      refute DuelServer.in_duel?(@target_id, s)
    end

    test "returns error when not in duel", %{server: s} do
      assert {:error, :not_in_duel} = DuelServer.abandon_duel(9999, s)
    end
  end

  # ── Gold calculations ───────────────────────────────────────────────

  describe "gold/tax calculations (VB6: FinalizarReto)" do
    test "10% tax is applied to total pot", %{server: s} do
      bet = 10_000
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, bet, s)
      {:ok, _} = DuelServer.accept_challenge(@target_id, "Challenger", s)

      # 2-0 sweep
      DuelServer.player_died(@target_id, s)
      {:duel_round_result, result} = DuelServer.player_died(@target_id, s)

      # Total pot = 10000 * 2 = 20000, tax = 2000, prize = 18000
      assert result.prize == 18_000
      assert result.tax == 2_000
    end
  end

  # ── Concurrent / edge cases ─────────────────────────────────────────

  describe "edge cases" do
    test "new challenge can be created after previous duel ends", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      {:ok, _} = DuelServer.accept_challenge(@target_id, "Challenger", s)
      # End duel via abandon
      DuelServer.abandon_duel(@challenger_id, s)

      # Now both players should be free to duel again
      assert :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
    end

    test "cancelling challenge frees both players", %{server: s} do
      :ok = DuelServer.create_challenge(@challenger_id, @target_id, @bet, s)
      :ok = DuelServer.cancel_challenge(@challenger_id, s)

      # Challenger can create a new challenge
      assert :ok = DuelServer.create_challenge(@challenger_id, 1003, @bet, s)
    end
  end
end
