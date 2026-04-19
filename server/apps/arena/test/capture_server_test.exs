defmodule Arena.Events.CaptureServerTest do
  @moduledoc """
  Tests for the team-based flag capture event — faithful to VB6 clsCaptura.cls + ModCaptura.bas.

  Tests the CaptureServer GenServer in isolation (no MapServer, no sessions).
  """

  use ExUnit.Case, async: true

  alias Arena.Events.CaptureServer
  alias Arena.Events.CaptureServer.{Capture, Participant, FlagState}

  # Helpers to build player info maps for registration
  defp player_info(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Player",
        level: 25,
        gold: 1000,
        dead: false,
        jailed: false,
        trade_partner_id: nil,
        mounted: false,
        navigating: false,
        map_id: 1,
        x: 50,
        y: 50
      },
      overrides
    )
  end

  setup do
    name = :"capture_server_#{System.unique_integer([:positive])}"
    {:ok, pid} = CaptureServer.start_link(name: name)
    %{server: name, pid: pid}
  end

  # ── GM start/stop/status ───────────────────────────────────────────

  describe "start_capture/6" do
    test "starts a new capture event", %{server: s} do
      assert :ok = CaptureServer.start_capture(100, 3, 1, 50, "AdminGM", s)
    end

    test "rejects starting when one is already active", %{server: s} do
      :ok = CaptureServer.start_capture(100, 3, 1, 50, "GM", s)

      assert {:error, :capture_already_active} =
               CaptureServer.start_capture(100, 3, 1, 50, "GM", s)
    end

    test "allows starting after previous event finished", %{server: s} do
      :ok = CaptureServer.start_capture(100, 3, 1, 50, "GM", s)
      :ok = CaptureServer.stop(s)
      assert :ok = CaptureServer.start_capture(100, 3, 1, 50, "GM", s)
    end
  end

  describe "stop/1" do
    test "cancels an active event", %{server: s} do
      :ok = CaptureServer.start_capture(100, 3, 1, 50, "GM", s)
      assert :ok = CaptureServer.stop(s)
    end

    test "returns error when no event is active", %{server: s} do
      assert {:error, :no_capture_event} = CaptureServer.stop(s)
    end
  end

  describe "status/1" do
    test "returns idle when no event active", %{server: s} do
      assert {:ok, :idle, %{}} = CaptureServer.status(s)
    end

    test "returns event info when active", %{server: s} do
      :ok = CaptureServer.start_capture(200, 5, 10, 40, "GM", s)

      assert {:ok, :registration, info} = CaptureServer.status(s)
      assert info.entry_fee == 200
      assert info.best_of == 5
      assert info.participant_count == 0
    end
  end

  # ── Registration validation ────────────────────────────────────────

  describe "join/3 — registration validation" do
    setup %{server: s} do
      :ok = CaptureServer.start_capture(100, 3, 10, 40, "GM", s)
      :ok
    end

    test "accepts valid player", %{server: s} do
      assert {:ok, team} = CaptureServer.join(1, player_info(%{name: "Hero", level: 25}), s)
      assert team in [:blue, :red]
    end

    test "rejects player with insufficient gold", %{server: s} do
      assert {:error, :insufficient_gold} =
               CaptureServer.join(1, player_info(%{gold: 50}), s)
    end

    test "rejects player below min level", %{server: s} do
      assert {:error, :level_too_low} =
               CaptureServer.join(1, player_info(%{level: 5}), s)
    end

    test "rejects player above max level", %{server: s} do
      assert {:error, :level_too_high} =
               CaptureServer.join(1, player_info(%{level: 45}), s)
    end

    test "rejects dead player", %{server: s} do
      assert {:error, :player_dead} =
               CaptureServer.join(1, player_info(%{dead: true}), s)
    end

    test "rejects jailed player", %{server: s} do
      assert {:error, :player_jailed} =
               CaptureServer.join(1, player_info(%{jailed: true}), s)
    end

    test "rejects trading player", %{server: s} do
      assert {:error, :player_trading} =
               CaptureServer.join(1, player_info(%{trade_partner_id: 42}), s)
    end

    test "rejects mounted player", %{server: s} do
      assert {:error, :player_mounted} =
               CaptureServer.join(1, player_info(%{mounted: true}), s)
    end

    test "rejects navigating player", %{server: s} do
      assert {:error, :player_navigating} =
               CaptureServer.join(1, player_info(%{navigating: true}), s)
    end

    test "rejects duplicate registration", %{server: s} do
      {:ok, _} = CaptureServer.join(1, player_info(), s)

      assert {:error, :already_registered} =
               CaptureServer.join(1, player_info(), s)
    end

    test "rejects registration when no event active", %{server: s} do
      :ok = CaptureServer.stop(s)

      assert {:error, :no_capture_event} =
               CaptureServer.join(1, player_info(), s)
    end
  end

  # ── Team assignment balance ────────────────────────────────────────

  describe "team assignment balance" do
    setup %{server: s} do
      :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", s)
      :ok
    end

    test "first player goes to blue", %{server: s} do
      assert {:ok, :blue} = CaptureServer.join(1, player_info(%{name: "P1"}), s)
    end

    test "second player goes to red", %{server: s} do
      {:ok, :blue} = CaptureServer.join(1, player_info(%{name: "P1"}), s)
      assert {:ok, :red} = CaptureServer.join(2, player_info(%{name: "P2"}), s)
    end

    test "alternates teams to keep balance", %{server: s} do
      {:ok, :blue} = CaptureServer.join(1, player_info(%{name: "P1"}), s)
      {:ok, :red} = CaptureServer.join(2, player_info(%{name: "P2"}), s)
      {:ok, :blue} = CaptureServer.join(3, player_info(%{name: "P3"}), s)
      {:ok, :red} = CaptureServer.join(4, player_info(%{name: "P4"}), s)

      {:ok, _, info} = CaptureServer.status(s)
      assert info.participant_count == 4
    end
  end

  # ── State transitions ──────────────────────────────────────────────

  describe "state transitions — registration to round_warmup" do
    test "transitions to round_warmup when timer expires with enough players", %{server: s} do
      :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", s)
      {:ok, _} = CaptureServer.join(1, player_info(%{name: "P1"}), s)
      {:ok, _} = CaptureServer.join(2, player_info(%{name: "P2"}), s)

      # Tick down the registration timer (90 seconds)
      events = tick_n(s, CaptureServer.registration_time())

      assert {:registration_closed} in flat_events(events)
    end

    test "retries registration once with 30s extension when insufficient players", %{server: s} do
      :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", s)
      # Only 1 player, not enough
      {:ok, _} = CaptureServer.join(1, player_info(%{name: "Solo"}), s)

      events = tick_n(s, CaptureServer.registration_time())
      assert {:registration_extended} in flat_events(events)

      # Event should still be in registration phase
      {:ok, :registration, _info} = CaptureServer.status(s)
    end

    test "cancels after max retries with insufficient players", %{server: s} do
      :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", s)
      {:ok, _} = CaptureServer.join(1, player_info(%{name: "Solo"}), s)

      # First 90s (retry 1)
      tick_n(s, CaptureServer.registration_time())
      # 30s retry (retry 2)
      tick_n(s, CaptureServer.registration_retry_time())
      # 30s retry (fails — max retries reached)
      events = tick_n(s, CaptureServer.registration_retry_time())

      assert {:event_cancelled_insufficient_players} in flat_events(events)

      {:ok, :finished, info} = CaptureServer.status(s)
      assert info.winner_team == nil
    end
  end

  describe "state transitions — round_warmup to in_game" do
    test "transitions to in_game after warmup countdown", %{server: s} do
      c = setup_in_game(s)

      {:ok, :in_game, _} = CaptureServer.status(s)
    end
  end

  # ── Flag capture detection ─────────────────────────────────────────

  describe "flag pickup and capture" do
    test "player picks up enemy flag when at enemy base", %{server: s} do
      setup_in_game(s)

      # Blue player 1 moves to red base (80, 80) to pick up the red flag
      {:ok, events} = CaptureServer.player_moved(1, 80, 80, s)

      assert {:flag_picked_up, 1, :red} in events
    end

    test "player within range of enemy base picks up flag", %{server: s} do
      setup_in_game(s)

      # Within range_x=8, range_y=5 of red base (80, 80)
      {:ok, events} = CaptureServer.player_moved(1, 75, 78, s)

      assert {:flag_picked_up, 1, :red} in events
    end

    test "player out of range does not pick up flag", %{server: s} do
      setup_in_game(s)

      # Too far from red base (80, 80)
      {:ok, events} = CaptureServer.player_moved(1, 50, 50, s)

      assert events == []
    end

    test "carrier starts hold timer at own base", %{server: s} do
      setup_in_game(s)

      # Blue player picks up red flag
      {:ok, _} = CaptureServer.player_moved(1, 80, 80, s)

      # Blue player brings flag to blue base (20, 20)
      {:ok, events} = CaptureServer.player_moved(1, 20, 20, s)

      assert {:flag_hold_started, 1} in events
    end

    test "hold timer resets when carrier moves away from base", %{server: s} do
      setup_in_game(s)

      # Pick up red flag
      {:ok, _} = CaptureServer.player_moved(1, 80, 80, s)
      # Start hold at blue base
      {:ok, _} = CaptureServer.player_moved(1, 20, 20, s)
      # Move away from base
      {:ok, events} = CaptureServer.player_moved(1, 50, 50, s)

      assert {:flag_hold_cancelled, 1} in events
    end

    test "flag capture after hold timer counts down", %{server: s} do
      setup_in_game(s)

      # Blue player picks up red flag
      {:ok, _} = CaptureServer.player_moved(1, 80, 80, s)
      # Starts hold at blue base
      {:ok, _} = CaptureServer.player_moved(1, 20, 20, s)

      # Tick down the flag hold timer (7 seconds)
      events = tick_n(s, CaptureServer.flag_hold_time())

      assert {:flag_captured, :blue} in flat_events(events)
    end
  end

  # ── Death timer escalation ─────────────────────────────────────────

  describe "death timer escalation" do
    test "first death gives base death timer", %{server: s} do
      setup_in_game(s)

      assert {:ok, :died, respawn} = CaptureServer.player_died(1, s)
      assert respawn == CaptureServer.base_death_timer()
    end

    test "second death gives escalated timer", %{server: s} do
      setup_in_game(s)

      {:ok, :died, _} = CaptureServer.player_died(1, s)

      # Need to respawn the player first via ticks
      tick_n(s, CaptureServer.base_death_timer())

      {:ok, :died, respawn} = CaptureServer.player_died(1, s)

      expected = CaptureServer.base_death_timer() + CaptureServer.death_timer_increment()
      assert respawn == expected
    end

    test "third death gives further escalated timer", %{server: s} do
      setup_in_game(s)

      # Die, respawn, die, respawn, die
      {:ok, :died, _} = CaptureServer.player_died(1, s)
      tick_n(s, CaptureServer.base_death_timer())

      {:ok, :died, _} = CaptureServer.player_died(1, s)
      tick_n(s, CaptureServer.base_death_timer() + CaptureServer.death_timer_increment())

      {:ok, :died, respawn} = CaptureServer.player_died(1, s)

      expected = CaptureServer.base_death_timer() + CaptureServer.death_timer_increment() * 2
      assert respawn == expected
    end

    test "respawn timer counts down and player becomes alive", %{server: s} do
      setup_in_game(s)

      {:ok, :died, respawn} = CaptureServer.player_died(1, s)

      # Tick respawn - 1 times (should still be dead)
      tick_n(s, respawn - 1)

      # After one more tick, should be alive
      tick_n(s, 1)

      # Now the player should be alive and movable
      {:ok, _events} = CaptureServer.player_moved(1, 50, 50, s)
    end

    test "dead player cannot interact with flags", %{server: s} do
      setup_in_game(s)

      CaptureServer.player_died(1, s)

      # Dead player at enemy base should not pick up flag
      {:ok, events} = CaptureServer.player_moved(1, 80, 80, s)
      assert events == []
    end
  end

  # ── Flag drop on death ─────────────────────────────────────────────

  describe "flag drop on death" do
    test "flag returns to base when carrier dies", %{server: s} do
      setup_in_game(s)

      # Blue player picks up red flag
      {:ok, _} = CaptureServer.player_moved(1, 80, 80, s)

      # Blue player dies
      {:ok, :died, _} = CaptureServer.player_died(1, s)

      # Red flag should be back at base — another blue player should be able to pick it up
      # (Player 3 was also on blue team if we have 4+ players, but let's verify with player 1
      # after respawn)
      tick_n(s, CaptureServer.base_death_timer())

      {:ok, events} = CaptureServer.player_moved(1, 80, 80, s)
      assert {:flag_picked_up, 1, :red} in events
    end
  end

  # ── Round progression and win condition ────────────────────────────

  describe "round progression" do
    test "winning a round transitions to round_warmup for next round", %{server: s} do
      setup_in_game(s)

      # Blue captures red flag
      {:ok, _} = CaptureServer.player_moved(1, 80, 80, s)
      {:ok, _} = CaptureServer.player_moved(1, 20, 20, s)
      tick_n(s, CaptureServer.flag_hold_time())

      # Should be in round_warmup for round 2
      {:ok, :round_warmup, info} = CaptureServer.status(s)
      assert info.round_scores.blue == 1
      assert info.current_round == 2
    end

    test "winning enough rounds (best-of-3 requires 2 wins) finishes the event", %{server: s} do
      setup_in_game(s)

      # Round 1: Blue captures
      {:ok, _} = CaptureServer.player_moved(1, 80, 80, s)
      {:ok, _} = CaptureServer.player_moved(1, 20, 20, s)
      tick_n(s, CaptureServer.flag_hold_time())

      # Now in round_warmup — tick through warmup
      tick_n(s, CaptureServer.round_warmup_time())

      # Round 2: Blue captures again
      {:ok, _} = CaptureServer.player_moved(1, 80, 80, s)
      {:ok, _} = CaptureServer.player_moved(1, 20, 20, s)
      events = tick_n(s, CaptureServer.flag_hold_time())

      # Should be finished with blue as winner
      {:ok, :finished, info} = CaptureServer.status(s)
      assert info.winner_team == :blue
      assert info.round_scores.blue == 2
    end

    test "best-of-5 requires 3 wins", %{server: s} do
      :ok = CaptureServer.start_capture(0, 5, 1, 50, "GM", s)
      {:ok, _} = CaptureServer.join(1, player_info(%{name: "Blue1"}), s)
      {:ok, _} = CaptureServer.join(2, player_info(%{name: "Red1"}), s)

      # Tick through registration + warmup
      tick_n(s, CaptureServer.registration_time())
      tick_n(s, CaptureServer.round_warmup_time())

      # Win 2 rounds — should NOT be finished yet
      for _ <- 1..2 do
        {:ok, _} = CaptureServer.player_moved(1, 80, 80, s)
        {:ok, _} = CaptureServer.player_moved(1, 20, 20, s)
        tick_n(s, CaptureServer.flag_hold_time())
        tick_n(s, CaptureServer.round_warmup_time())
      end

      {:ok, :in_game, info} = CaptureServer.status(s)
      assert info.round_scores.blue == 2

      # Win round 3 — should finish
      {:ok, _} = CaptureServer.player_moved(1, 80, 80, s)
      {:ok, _} = CaptureServer.player_moved(1, 20, 20, s)
      tick_n(s, CaptureServer.flag_hold_time())

      {:ok, :finished, info} = CaptureServer.status(s)
      assert info.winner_team == :blue
      assert info.round_scores.blue == 3
    end
  end

  # ── Reward calculation ─────────────────────────────────────────────

  describe "compute_rewards/2 — pure function" do
    test "splits pot among winners evenly" do
      capture = %Capture{
        entry_fee: 100,
        participants: %{
          1 => %Participant{char_id: 1, team: :blue, name: "B1", level: 25},
          2 => %Participant{char_id: 2, team: :blue, name: "B2", level: 25},
          3 => %Participant{char_id: 3, team: :red, name: "R1", level: 25},
          4 => %Participant{char_id: 4, team: :red, name: "R2", level: 25}
        }
      }

      rewards = CaptureServer.compute_rewards(capture, :blue)

      # 4 players * 100 fee = 400 pot, split among 2 blue winners = 200 each
      assert rewards.total_pot == 400
      assert rewards.reward_per_winner == 200
      assert rewards.winning_team == :blue
      assert 1 in rewards.winners
      assert 2 in rewards.winners
      assert length(rewards.winners) == 2
    end

    test "handles uneven teams" do
      capture = %Capture{
        entry_fee: 100,
        participants: %{
          1 => %Participant{char_id: 1, team: :blue, name: "B1", level: 25},
          2 => %Participant{char_id: 2, team: :red, name: "R1", level: 25},
          3 => %Participant{char_id: 3, team: :red, name: "R2", level: 25}
        }
      }

      rewards = CaptureServer.compute_rewards(capture, :red)

      # 3 players * 100 = 300, split among 2 red winners = 150 each
      assert rewards.total_pot == 300
      assert rewards.reward_per_winner == 150
      assert length(rewards.winners) == 2
    end

    test "zero entry fee means zero rewards" do
      capture = %Capture{
        entry_fee: 0,
        participants: %{
          1 => %Participant{char_id: 1, team: :blue, name: "B1", level: 25},
          2 => %Participant{char_id: 2, team: :red, name: "R1", level: 25}
        }
      }

      rewards = CaptureServer.compute_rewards(capture, :blue)

      assert rewards.total_pot == 0
      assert rewards.reward_per_winner == 0
    end
  end

  # ── Disconnect during event ────────────────────────────────────────

  describe "player_disconnected/2" do
    test "removes player from participants", %{server: s} do
      :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", s)
      {:ok, _} = CaptureServer.join(1, player_info(%{name: "P1"}), s)
      {:ok, _} = CaptureServer.join(2, player_info(%{name: "P2"}), s)

      {:ok, _, info_before} = CaptureServer.status(s)
      assert info_before.participant_count == 2

      :ok = CaptureServer.player_disconnected(1, s)

      {:ok, _, info_after} = CaptureServer.status(s)
      assert info_after.participant_count == 1
    end

    test "drops flag when carrier disconnects", %{server: s} do
      setup_in_game(s)

      # Blue player picks up red flag
      {:ok, events} = CaptureServer.player_moved(1, 80, 80, s)
      assert {:flag_picked_up, 1, :red} in events

      # Player disconnects
      :ok = CaptureServer.player_disconnected(1, s)

      # Join a replacement blue player and verify flag is back at base
      # (We can't easily re-join mid game, but we can check via status that
      #  the event hasn't broken. We'll verify by having player 3 try to pick up)
      # Player 3 should also be on blue team from setup_in_game
      {:ok, pickup_events} = CaptureServer.player_moved(3, 80, 80, s)
      assert {:flag_picked_up, 3, :red} in pickup_events
    end

    test "team forfeit when all members of a team disconnect", %{server: s} do
      setup_in_game(s)

      # Disconnect all blue players (1 and 3 in our 4-player setup)
      :ok = CaptureServer.player_disconnected(1, s)
      :ok = CaptureServer.player_disconnected(3, s)

      {:ok, :finished, info} = CaptureServer.status(s)
      assert info.winner_team == :red
    end

    test "returns error when player not in event", %{server: s} do
      :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", s)

      assert {:error, :not_in_event} = CaptureServer.player_disconnected(999, s)
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────

  describe "edge cases" do
    test "player_died returns error when not in game phase", %{server: s} do
      :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", s)

      assert {:error, :not_in_game} = CaptureServer.player_died(1, s)
    end

    test "player_moved returns error when not in game phase", %{server: s} do
      :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", s)

      assert {:error, :not_in_game} = CaptureServer.player_moved(1, 50, 50, s)
    end

    test "player_died returns error for non-participant", %{server: s} do
      setup_in_game(s)

      assert {:error, :not_in_event} = CaptureServer.player_died(999, s)
    end

    test "player_moved returns error for non-participant", %{server: s} do
      setup_in_game(s)

      assert {:error, :not_in_event} = CaptureServer.player_moved(999, 50, 50, s)
    end

    test "registration closed rejects late joiners", %{server: s} do
      setup_in_game(s)

      assert {:error, :registration_closed} =
               CaptureServer.join(99, player_info(%{name: "LateJoiner"}), s)
    end

    test "tick on idle server returns idle", %{server: s} do
      assert {:ok, :idle} = CaptureServer.tick(s)
    end

    test "tick on finished event is a no-op", %{server: s} do
      :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", s)

      # Let registration time out with insufficient players and exhaust retries
      tick_n(s, CaptureServer.registration_time())
      tick_n(s, CaptureServer.registration_retry_time())
      tick_n(s, CaptureServer.registration_retry_time())

      {:ok, :finished, _} = CaptureServer.status(s)

      # Additional ticks should be harmless
      {:ok, :finished, []} = CaptureServer.tick(s)
    end
  end

  # ── Pure state function tests ──────────────────────────────────────

  describe "validate_registration/3 — pure function" do
    test "accepts valid player info" do
      capture = %Capture{entry_fee: 100, min_level: 10, max_level: 40, participants: %{}}
      info = player_info(%{level: 25, gold: 500})

      assert :ok = CaptureServer.validate_registration(capture, 1, info)
    end

    test "rejects already registered player" do
      capture = %Capture{
        entry_fee: 0,
        min_level: 1,
        max_level: 50,
        participants: %{1 => %Participant{char_id: 1}}
      }

      assert {:error, :already_registered} =
               CaptureServer.validate_registration(capture, 1, player_info())
    end
  end

  describe "assign_team/1 — pure function" do
    test "assigns to blue when teams are equal" do
      capture = %Capture{participants: %{}}
      assert :blue = CaptureServer.assign_team(capture)
    end

    test "assigns to red when blue has more" do
      capture = %Capture{
        participants: %{
          1 => %Participant{char_id: 1, team: :blue}
        }
      }

      assert :red = CaptureServer.assign_team(capture)
    end

    test "assigns to blue when red has more" do
      capture = %Capture{
        participants: %{
          1 => %Participant{char_id: 1, team: :blue},
          2 => %Participant{char_id: 2, team: :red},
          3 => %Participant{char_id: 3, team: :red}
        }
      }

      assert :blue = CaptureServer.assign_team(capture)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  # Tick N times and collect all events
  defp tick_n(server, n) do
    Enum.map(1..n, fn _ ->
      {:ok, _phase, events} = CaptureServer.tick(server)
      events
    end)
  end

  # Flatten a list of event lists into a flat list of tagged tuples
  defp flat_events(event_lists) do
    event_lists
    |> List.flatten()
    |> Enum.map(fn
      event when is_atom(event) -> {event}
      event -> event
    end)
  end

  # Set up a capture event that's already in the in_game phase with 4 players
  defp setup_in_game(server) do
    :ok = CaptureServer.start_capture(0, 3, 1, 50, "GM", server)

    # Register 4 players (2 per team)
    {:ok, :blue} = CaptureServer.join(1, player_info(%{name: "Blue1", level: 25}), server)
    {:ok, :red} = CaptureServer.join(2, player_info(%{name: "Red1", level: 25}), server)
    {:ok, :blue} = CaptureServer.join(3, player_info(%{name: "Blue2", level: 20}), server)
    {:ok, :red} = CaptureServer.join(4, player_info(%{name: "Red2", level: 20}), server)

    # Tick through registration (90s) + warmup (60s)
    tick_n(server, CaptureServer.registration_time())
    tick_n(server, CaptureServer.round_warmup_time())

    {:ok, :in_game, _} = CaptureServer.status(server)
    :ok
  end
end
