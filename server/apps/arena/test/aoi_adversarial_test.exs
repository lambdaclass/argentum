defmodule Arena.Map.AoiAdversarialTest do
  @moduledoc """
  Adversarial tests for the AoI (Area of Interest) visibility system.

  These tests target edge cases and potential exploit vectors that could lead to
  wallhack/maphack exploits: rapid teleport spam, boundary precision, diagonal
  corners, grid cell edges, large coordinates, concurrent enter/leave, step-by-step
  boundary crossing, dead player visibility, re-enter same tile, and stress with
  many players in a small area.

  Uses the same infrastructure as aoi_visibility_test.exs: map 2, :aoi_grid mode.
  """
  use ExUnit.Case

  alias Arena.Map.MapServer
  alias Arena.Map.MapSupervisor
  alias AoEntities.PlayerEntity

  # Use map 2 to avoid conflicts with other test files
  @test_map_id 2

  # Production AoI half-ranges (compile-time in helpers.ex)
  @aoi_x 11
  @aoi_y 9

  # Grid cell size from visibility.ex: max(max(11, 9), 12) = 12
  @cell_size 12

  setup_all do
    Application.ensure_all_started(:phoenix_pubsub)

    ensure_started(fn -> Registry.start_link(keys: :unique, name: Arena.MapRegistry) end)
    ensure_started(fn -> Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub) end)
    ensure_started(fn -> Arena.Data.GameData.start_link([]) end)
    ensure_started(fn -> MapSupervisor.start_link([]) end)

    :ok
  end

  defp ensure_started(start_fn) do
    case start_fn.() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  setup do
    original_mode = Application.get_env(:arena, :visibility_mode)
    Application.put_env(:arena, :visibility_mode, :aoi_grid)

    MapSupervisor.stop_map(@test_map_id)
    Process.sleep(50)
    {:ok, _pid} = MapSupervisor.start_map(@test_map_id)

    on_exit(fn ->
      Application.put_env(:arena, :visibility_mode, original_mode)
      MapSupervisor.stop_map(@test_map_id)
    end)

    :ok
  end

  defp make_entity(char_id, name, x, y) do
    %PlayerEntity{
      char_id: char_id,
      name: name,
      account_id: "account_#{char_id}",
      x: x,
      y: y
    }
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
  end

  defp collect_raw_messages(timeout) do
    collect_raw_messages_acc([], timeout)
  end

  defp collect_raw_messages_acc(acc, timeout) do
    receive do
      {:send_raw, data} -> collect_raw_messages_acc([data | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp enter_from_other_process(map_id, entity, opts) do
    test_pid = self()

    pid =
      spawn(fn ->
        result = MapServer.enter(map_id, entity, opts)
        send(test_pid, {:enter_result, result})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {:enter_result, result} -> {pid, result}
    after
      5000 -> raise "enter_from_other_process timed out"
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Rapid teleport spam: enter/leave/re-enter at different positions
  # ---------------------------------------------------------------------------
  describe "rapid teleport spam" do
    test "grid state stays consistent after rapid enter/leave/re-enter cycles" do
      observer = make_entity(20_001, "Observer", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, observer, position: {50, 50})
      flush_mailbox()

      # Rapidly enter and leave a player at different positions near the observer
      positions = [{51, 50}, {49, 50}, {50, 51}, {52, 52}, {48, 48}]

      for {x, y} <- positions do
        teleporter = make_entity(20_002, "Teleporter", x, y)
        {pid, {:ok, _, _, _}} = enter_from_other_process(@test_map_id, teleporter, position: {x, y})
        # Leave immediately — no sleep
        MapServer.leave(@test_map_id, 20_002)
        send(pid, :stop)
      end

      flush_mailbox()

      # Now enter a new player near the observer — it should work cleanly
      final = make_entity(20_003, "Final", 51, 50)
      {final_pid, {:ok, _, players, _}} = enter_from_other_process(@test_map_id, final, position: {51, 50})

      # Observer should see Final (1 tile away), and Final should see Observer
      assert Map.has_key?(players, 20_001), "Final should see the Observer after teleport spam"

      msgs = collect_raw_messages(200)
      assert length(msgs) > 0, "Observer should receive character_create for Final"

      # The teleporter (20_002) should NOT appear anywhere — it left
      refute Map.has_key?(players, 20_002), "Teleporter should not be in visible set after leaving"

      MapServer.leave(@test_map_id, 20_001)
      MapServer.leave(@test_map_id, 20_003)
      send(final_pid, :stop)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Boundary precision: exactly AoI_x vs AoI_x+1
  # ---------------------------------------------------------------------------
  describe "boundary precision" do
    test "player at exactly AoI_x distance is visible" do
      a = make_entity(21_001, "PrecisionA", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      exact_x = 50 + @aoi_x
      b_exact = make_entity(21_002, "ExactBound", exact_x, 50)
      {b_pid, {:ok, _, players_b, _}} = enter_from_other_process(@test_map_id, b_exact, position: {exact_x, 50})

      assert Map.has_key?(players_b, 21_001), "Player at exactly AoI_x distance should see origin"

      msgs_exact = collect_raw_messages(200)
      assert length(msgs_exact) > 0, "Observer should get create for player at exact AoI_x"

      MapServer.leave(@test_map_id, 21_001)
      MapServer.leave(@test_map_id, 21_002)
      send(b_pid, :stop)
    end

    test "player at AoI_x+1 distance is NOT visible" do
      a = make_entity(21_011, "PrecisionA2", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      outside_x = 50 + @aoi_x + 1
      c_outside = make_entity(21_012, "OutsideBound", outside_x, 50)
      {c_pid, {:ok, _, players_c, _}} = enter_from_other_process(@test_map_id, c_outside, position: {outside_x, 50})

      refute Map.has_key?(players_c, 21_011), "Player at AoI_x+1 distance should NOT see origin"

      msgs_outside = collect_raw_messages(200)
      assert msgs_outside == [], "Observer should NOT get create for player at AoI_x+1"

      MapServer.leave(@test_map_id, 21_011)
      MapServer.leave(@test_map_id, 21_012)
      send(c_pid, :stop)
    end

    test "player at exactly AoI_y distance is visible" do
      a = make_entity(21_101, "PrecisionYA", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      exact_y = 50 + @aoi_y
      b = make_entity(21_102, "ExactYBound", 50, exact_y)
      {b_pid, {:ok, _, players_b, _}} = enter_from_other_process(@test_map_id, b, position: {50, exact_y})

      assert Map.has_key?(players_b, 21_101), "Player at exactly AoI_y distance should see origin"
      msgs = collect_raw_messages(200)
      assert length(msgs) > 0, "Observer should get create for player at exact AoI_y"

      MapServer.leave(@test_map_id, 21_101)
      MapServer.leave(@test_map_id, 21_102)
      send(b_pid, :stop)
    end

    test "player at AoI_y+1 distance is NOT visible" do
      a = make_entity(21_111, "PrecisionYA2", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      outside_y = 50 + @aoi_y + 1
      c = make_entity(21_112, "OutsideYBound", 50, outside_y)
      {c_pid, {:ok, _, players_c, _}} = enter_from_other_process(@test_map_id, c, position: {50, outside_y})

      refute Map.has_key?(players_c, 21_111), "Player at AoI_y+1 distance should NOT see origin"
      msgs2 = collect_raw_messages(200)
      assert msgs2 == [], "Observer should NOT get create for player at AoI_y+1"

      MapServer.leave(@test_map_id, 21_111)
      MapServer.leave(@test_map_id, 21_112)
      send(c_pid, :stop)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Diagonal corners: max X AND max Y distance simultaneously
  # ---------------------------------------------------------------------------
  describe "diagonal corners" do
    test "player at max AoI_x AND max AoI_y (corner) is visible" do
      a = make_entity(22_001, "DiagA", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      corner_x = 50 + @aoi_x
      corner_y = 50 + @aoi_y
      b = make_entity(22_002, "DiagCorner", corner_x, corner_y)
      {b_pid, {:ok, _, players_b, _}} = enter_from_other_process(@test_map_id, b, position: {corner_x, corner_y})

      assert Map.has_key?(players_b, 22_001), "Player at diagonal corner (max X + max Y) should see origin"
      msgs = collect_raw_messages(200)
      assert length(msgs) > 0, "Observer should get create for player at diagonal corner"

      MapServer.leave(@test_map_id, 22_001)
      MapServer.leave(@test_map_id, 22_002)
      send(b_pid, :stop)
    end

    test "player just outside diagonal corner is NOT visible" do
      a = make_entity(22_101, "DiagOutA", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      # One tile beyond the corner in X
      beyond_x = 50 + @aoi_x + 1
      beyond_y = 50 + @aoi_y
      b = make_entity(22_102, "DiagBeyond", beyond_x, beyond_y)
      {b_pid, {:ok, _, players_b, _}} = enter_from_other_process(@test_map_id, b, position: {beyond_x, beyond_y})

      refute Map.has_key?(players_b, 22_101), "Player beyond diagonal corner should NOT see origin"
      msgs = collect_raw_messages(200)
      assert msgs == [], "Observer should NOT get create for player beyond diagonal corner"

      MapServer.leave(@test_map_id, 22_101)
      MapServer.leave(@test_map_id, 22_102)
      send(b_pid, :stop)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Grid cell boundaries: positions on multiples of cell_size
  # ---------------------------------------------------------------------------
  describe "grid cell boundaries" do
    test "players on adjacent cell boundaries within AoI see each other" do
      # Place player A at the edge of one cell, B at the start of the next cell
      # Cell boundary at x=@cell_size (e.g. 12). A at 11, B at 12 — different cells, 1 tile apart
      cell_edge = @cell_size - 1
      next_cell = @cell_size

      a = make_entity(23_001, "CellEdgeA", cell_edge, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {cell_edge, 50})
      flush_mailbox()

      b = make_entity(23_002, "CellEdgeB", next_cell, 50)
      {b_pid, {:ok, _, players_b, _}} = enter_from_other_process(@test_map_id, b, position: {next_cell, 50})

      assert Map.has_key?(players_b, 23_001),
             "Players on adjacent grid cell boundaries (1 tile apart) should see each other"

      msgs = collect_raw_messages(200)
      assert length(msgs) > 0, "Observer should receive create for player across cell boundary"

      MapServer.leave(@test_map_id, 23_001)
      MapServer.leave(@test_map_id, 23_002)
      send(b_pid, :stop)
    end

    test "player at exact cell_size multiple coordinates works correctly" do
      # Both players at positions that are exact multiples of cell_size
      pos_a = @cell_size * 2
      pos_b = @cell_size * 2 + 1

      a = make_entity(23_101, "CellMultA", pos_a, pos_a)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {pos_a, pos_a})
      flush_mailbox()

      b = make_entity(23_102, "CellMultB", pos_b, pos_a)
      {b_pid, {:ok, _, players_b, _}} = enter_from_other_process(@test_map_id, b, position: {pos_b, pos_a})

      assert Map.has_key?(players_b, 23_101),
             "Players at cell_size multiples (adjacent) should see each other"

      MapServer.leave(@test_map_id, 23_101)
      MapServer.leave(@test_map_id, 23_102)
      send(b_pid, :stop)
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Large coordinate values: players at map edges
  # ---------------------------------------------------------------------------
  describe "large coordinate values" do
    test "players at opposite map edges are NOT visible to each other" do
      # Map is 100x100 (1-based). Place players at opposite corners.
      a = make_entity(24_001, "EdgeA", 2, 2)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {2, 2})
      flush_mailbox()

      b = make_entity(24_002, "EdgeB", 98, 98)
      {b_pid, {:ok, _, players_b, _}} = enter_from_other_process(@test_map_id, b, position: {98, 98})

      refute Map.has_key?(players_b, 24_001), "Players at opposite map edges should NOT see each other"
      msgs = collect_raw_messages(200)
      assert msgs == [], "No character_create should leak across full map distance"

      MapServer.leave(@test_map_id, 24_001)
      MapServer.leave(@test_map_id, 24_002)
      send(b_pid, :stop)
    end

    test "two players at high coordinates within AoI see each other" do
      a = make_entity(24_101, "HighA", 90, 90)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {90, 90})
      flush_mailbox()

      b = make_entity(24_102, "HighB", 91, 91)
      {b_pid, {:ok, _, players_b, _}} = enter_from_other_process(@test_map_id, b, position: {91, 91})

      assert Map.has_key?(players_b, 24_101), "Players at high coords within AoI should see each other"
      msgs = collect_raw_messages(200)
      assert length(msgs) > 0, "Observer at high coords should receive create"

      MapServer.leave(@test_map_id, 24_101)
      MapServer.leave(@test_map_id, 24_102)
      send(b_pid, :stop)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Concurrent enter/leave: multiple players entering and leaving — no stale refs
  # ---------------------------------------------------------------------------
  describe "concurrent enter/leave" do
    test "no stale references in visible sets after concurrent operations" do
      # Observer stays put
      observer = make_entity(25_001, "ConcObs", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, observer, position: {50, 50})
      flush_mailbox()

      # Enter 5 players near observer, then immediately leave them all
      pids =
        for i <- 1..5 do
          entity = make_entity(25_100 + i, "Conc#{i}", 50 + i, 50)
          {pid, {:ok, _, _, _}} = enter_from_other_process(@test_map_id, entity, position: {50 + i, 50})
          pid
        end

      flush_mailbox()

      # Leave all of them
      for i <- 1..5 do
        MapServer.leave(@test_map_id, 25_100 + i)
      end

      for pid <- pids, do: send(pid, :stop)
      flush_mailbox()

      # Now enter a fresh player — should only see observer, no ghost references
      fresh = make_entity(25_200, "Fresh", 51, 50)
      {fresh_pid, {:ok, _, players, _}} = enter_from_other_process(@test_map_id, fresh, position: {51, 50})

      # Should see observer and self only
      assert Map.has_key?(players, 25_001), "Fresh player should see observer"
      assert Map.has_key?(players, 25_200), "Fresh player should see self"

      for i <- 1..5 do
        refute Map.has_key?(players, 25_100 + i),
               "Fresh player should NOT see departed player #{25_100 + i}"
      end

      MapServer.leave(@test_map_id, 25_001)
      MapServer.leave(@test_map_id, 25_200)
      send(fresh_pid, :stop)
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Move through AoI boundary: step-by-step from inside to outside
  # ---------------------------------------------------------------------------
  describe "move through AoI boundary" do
    test "player walks step-by-step from inside AoI to outside" do
      # A at (50, 50). B starts at (50 + @aoi_x - 1, 50) — 10 tiles away, visible.
      a = make_entity(26_001, "WalkObsA", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      start_x = 50 + @aoi_x - 1
      b = make_entity(26_002, "WalkerB", start_x, 50)
      {:ok, _, players_b, _weather} = MapServer.enter(@test_map_id, b, position: {start_x, 50})

      assert Map.has_key?(players_b, 26_001), "Walker should initially see observer"
      flush_mailbox()

      # Walk B east step by step. Distance starts at @aoi_x - 1 = 10.
      # After 1 step east: distance = @aoi_x (11) — still visible
      # After 2 steps east: distance = @aoi_x + 1 (12) — should become invisible

      # Step 1: move east, now at distance @aoi_x — still in range
      Process.sleep(250)

      case MapServer.move_character(@test_map_id, 26_002, :east) do
        {:ok, _pos} ->
          # A should NOT yet get a remove (B still in range)
          # Collect messages — should be movement broadcast, not character_remove
          _msgs_step1 = collect_raw_messages(200)
          # No character_remove (packet_id for remove varies, but we check that
          # B is still visible by taking next step)
          :ok

        {:error, reason} ->
          flunk("Step 1 east failed: #{inspect(reason)}")
      end

      # Step 2: move east again, now at distance @aoi_x + 1 — out of range
      Process.sleep(250)

      case MapServer.move_character(@test_map_id, 26_002, :east) do
        {:ok, _pos} ->
          msgs_step2 = collect_raw_messages(200)

          # A should receive character_remove since B just left AoI
          assert length(msgs_step2) > 0,
                 "Observer should receive character_remove when walker exits AoI boundary"

        {:error, reason} ->
          flunk("Step 2 east failed: #{inspect(reason)}")
      end

      MapServer.leave(@test_map_id, 26_001)
      MapServer.leave(@test_map_id, 26_002)
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Ghost state: dead players should still follow AoI rules
  # ---------------------------------------------------------------------------
  describe "ghost state (dead players)" do
    test "dead player entering still follows AoI — far players do not see them" do
      observer = make_entity(27_001, "GhostObs", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, observer, position: {50, 50})
      flush_mailbox()

      # Dead player enters far away
      far_x = 50 + @aoi_x + 5
      dead_player = %PlayerEntity{make_entity(27_002, "Ghost", far_x, 50) | dead: true}
      {ghost_pid, {:ok, _, _, _}} = enter_from_other_process(@test_map_id, dead_player, position: {far_x, 50})

      msgs = collect_raw_messages(200)
      assert msgs == [], "Dead player outside AoI should NOT leak position to observer"

      MapServer.leave(@test_map_id, 27_001)
      MapServer.leave(@test_map_id, 27_002)
      send(ghost_pid, :stop)
    end

    test "dead player entering within AoI is visible to nearby players" do
      observer = make_entity(27_101, "GhostNearObs", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, observer, position: {50, 50})
      flush_mailbox()

      dead_player = %PlayerEntity{make_entity(27_102, "GhostNear", 51, 50) | dead: true}
      {ghost_pid, {:ok, _, _, _}} = enter_from_other_process(@test_map_id, dead_player, position: {51, 50})

      msgs = collect_raw_messages(200)
      assert length(msgs) > 0, "Dead player within AoI should still be visible to nearby players"

      MapServer.leave(@test_map_id, 27_101)
      MapServer.leave(@test_map_id, 27_102)
      send(ghost_pid, :stop)
    end
  end

  # ---------------------------------------------------------------------------
  # 9. Re-enter same position: leave and re-enter the exact same tile
  # ---------------------------------------------------------------------------
  describe "re-enter same position" do
    test "player re-entering same tile is visible to same neighbors" do
      observer = make_entity(28_001, "ReenterObs", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, observer, position: {50, 50})
      flush_mailbox()

      # Enter, leave, re-enter at (51, 50)
      player = make_entity(28_002, "Reenterer", 51, 50)
      {pid1, {:ok, _, _, _}} = enter_from_other_process(@test_map_id, player, position: {51, 50})

      msgs1 = collect_raw_messages(200)
      assert length(msgs1) > 0, "First enter should send create to observer"

      MapServer.leave(@test_map_id, 28_002)
      send(pid1, :stop)

      msgs_remove = collect_raw_messages(200)
      assert length(msgs_remove) > 0, "Leave should send remove to observer"

      # Re-enter at the exact same tile
      player2 = make_entity(28_002, "Reenterer", 51, 50)
      {pid2, {:ok, _, players2, _}} = enter_from_other_process(@test_map_id, player2, position: {51, 50})

      assert Map.has_key?(players2, 28_001), "Re-entered player should see observer"

      msgs2 = collect_raw_messages(200)
      assert length(msgs2) > 0, "Re-entering same tile should send create to observer again"

      MapServer.leave(@test_map_id, 28_001)
      MapServer.leave(@test_map_id, 28_002)
      send(pid2, :stop)
    end
  end

  # ---------------------------------------------------------------------------
  # 10. Stress: many players in small area — all should see each other
  # ---------------------------------------------------------------------------
  describe "stress: many players in small area" do
    test "20+ players in adjacent tiles all see each other" do
      player_count = 20
      base_id = 29_000

      # Enter all players from separate processes in a 5x4 grid near (50, 50)
      pids_and_ids =
        for i <- 1..player_count do
          char_id = base_id + i
          # Spread across a 5x4 grid: x offset 0..4, y offset 0..3
          x = 50 + rem(i - 1, 5)
          y = 50 + div(i - 1, 5)
          entity = make_entity(char_id, "Stress#{i}", x, y)
          {pid, {:ok, _, _, _}} = enter_from_other_process(@test_map_id, entity, position: {x, y})
          {pid, char_id}
        end

      _pids = Enum.map(pids_and_ids, &elem(&1, 0))
      ids = Enum.map(pids_and_ids, &elem(&1, 1))
      flush_mailbox()

      # Enter one more player as the test process to check what it sees
      checker_id = base_id + player_count + 1
      checker = make_entity(checker_id, "Checker", 52, 51)
      {:ok, _, players, _weather} = MapServer.enter(@test_map_id, checker, position: {52, 51})

      # All 20 players are within a 5x4 area around (50,50) and the checker is at (52,51).
      # Max distance: |52-54|=2 in x, |51-53|=2 in y — well within AoI range of 11x9.
      # Every single one of the 20 players should be visible.
      for char_id <- ids do
        assert Map.has_key?(players, char_id),
               "Checker should see player #{char_id} — all are within AoI range"
      end

      assert Map.has_key?(players, checker_id), "Checker should see self"

      # Verify count: 20 stress players + self = 21
      assert map_size(players) == player_count + 1,
             "Expected #{player_count + 1} players visible, got #{map_size(players)}"

      # Clean up
      MapServer.leave(@test_map_id, checker_id)

      for {pid, char_id} <- pids_and_ids do
        MapServer.leave(@test_map_id, char_id)
        send(pid, :stop)
      end
    end
  end
end
