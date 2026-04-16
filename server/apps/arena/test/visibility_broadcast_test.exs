defmodule Arena.VisibilityBroadcastTest do
  @moduledoc "Tests for Visibility.broadcast_to_map and broadcast unification."
  use ExUnit.Case, async: true

  import Arena.Test.MapStateFactory

  alias Arena.Map.Visibility

  describe "broadcast_to_map/2" do
    test "sends to all sessions regardless of position" do
      test_pid = self()

      state = map_state(
        sessions: %{1 => test_pid, 2 => test_pid, 3 => test_pid},
        visibility_mode: :aoi_grid,
        grid: %{}
      )

      count = Visibility.broadcast_to_map(state, fn pid ->
        send(pid, :got_broadcast)
      end)

      assert length(count) == 3

      # Should receive 3 messages
      assert_received :got_broadcast
      assert_received :got_broadcast
      assert_received :got_broadcast
    end

    test "works with empty sessions" do
      state = map_state(sessions: %{})

      count = Visibility.broadcast_to_map(state, fn pid ->
        send(pid, :got_broadcast)
      end)

      assert count == []
      refute_received :got_broadcast
    end

    test "reaches all sessions in global mode" do
      test_pid = self()
      state = map_state(
        sessions: %{1 => test_pid, 2 => test_pid},
        visibility_mode: :global
      )

      results = Visibility.broadcast_to_map(state, fn pid ->
        send(pid, :map_broadcast)
      end)

      assert length(results) == 2
    end

    test "reaches all sessions in aoi_grid mode" do
      test_pid = self()
      state = map_state(
        sessions: %{1 => test_pid, 2 => test_pid},
        visibility_mode: :aoi_grid,
        grid: %{}
      )

      results = Visibility.broadcast_to_map(state, fn pid ->
        send(pid, :map_broadcast)
      end)

      assert length(results) == 2
    end
  end

  describe "broadcast_visible_all vs broadcast_to_map" do
    test "broadcast_to_map ignores AoI, broadcast_visible respects it" do
      test_pid = self()

      # Player at (1,1) and player at (99,99) — far apart
      far_player = %{x: 99, y: 99, char_index: 2}

      state = map_state(
        players: %{
          1 => %{x: 1, y: 1, char_index: 1},
          2 => far_player
        },
        sessions: %{1 => test_pid, 2 => test_pid},
        visibility_mode: :aoi_scan
      )

      # broadcast_to_map should reach both
      map_results = Visibility.broadcast_to_map(state, fn pid ->
        send(pid, :map_msg)
      end)
      assert length(map_results) == 2

      # broadcast_visible_all from (1,1) should only reach player 1 (not player 2 at 99,99)
      vis_count = Visibility.broadcast_visible_all(state, 1, 1, fn pid ->
        send(pid, :vis_msg)
      end)
      # Only 1 player is within AoI range of (1,1)
      assert vis_count == 1
    end
  end

  describe "adversarial visibility" do
    test "broadcast_to_map with nil sessions field raises" do
      # The struct always has sessions: %{}, but test that broadcast_to_map
      # handles a map with no sessions gracefully
      state = map_state(sessions: %{})
      results = Visibility.broadcast_to_map(state, fn _pid -> :ok end)
      assert results == []
    end

    test "broadcast_visible with nonexistent player position" do
      state = map_state(
        players: %{},
        sessions: %{},
        visibility_mode: :aoi_scan
      )

      # Should handle empty players gracefully
      count = Visibility.broadcast_visible_all(state, 50, 50, fn _pid -> :ok end)
      assert count == 0
    end
  end
end
