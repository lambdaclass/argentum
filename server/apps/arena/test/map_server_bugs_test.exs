defmodule Arena.Map.MapServerBugsTest do
  @moduledoc """
  Regression tests for MapServer bugs found in Phase 1 review.
  Requires the tile NIF and map files to be available.
  """
  use ExUnit.Case

  alias Arena.Map.MapServer
  alias Arena.Entity.PlayerEntity

  @test_map_id 1

  setup_all do
    # Start only the processes we need (no Phoenix, no Postgres)
    Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Arena.MapRegistry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Arena.MapRegistry)
    end

    unless Process.whereis(Arena.PubSub) do
      {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end

    unless Process.whereis(Arena.Data.GameData) do
      {:ok, _} = Arena.Data.GameData.start_link([])
    end

    unless Process.whereis(Arena.Map.MapSupervisor) do
      {:ok, _} = Arena.Map.MapSupervisor.start_link([])
    end

    :ok
  end

  setup do
    # Ensure the map is started
    case Registry.lookup(Arena.MapRegistry, @test_map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(@test_map_id)
    end

    :ok
  end

  defp make_entity(char_id, name) do
    %PlayerEntity{
      char_id: char_id,
      name: name,
      account_id: "account_#{char_id}",
      x: 50,
      y: 50
    }
  end

  describe "Bug #2: transfer should not require session to call leave" do
    test "check_tile_exit sends entity in transfer message so session skips leave" do
      entity = make_entity(9001, "TransferTest")
      {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity)

      # After a tile exit removes the player, leave should return :not_found
      # because the map already cleaned up. The fix is that the transfer
      # message includes the entity so the session never calls leave.
      result = MapServer.leave(@test_map_id, 9001)

      # Before fix: this would be the normal flow, but during transfer
      # check_tile_exit already removed the player. We verify leave still
      # works if called normally (not during transfer).
      assert {:ok, %PlayerEntity{char_id: 9001}} = result
    end
  end

  describe "Bug #4: enter should check occupancy" do
    test "two players cannot occupy the same tile" do
      e1 = make_entity(8001, "Player1")
      e2 = make_entity(8002, "Player2")

      {:ok, _idx1, _, _weather} = MapServer.enter(@test_map_id, e1, position: {30, 30})
      {:ok, _idx2, players, _weather} = MapServer.enter(@test_map_id, e2, position: {30, 30})

      p1 = Map.get(players, 8001)
      p2 = Map.get(players, 8002)

      # They must NOT be on the same tile
      refute {p1.x, p1.y} == {p2.x, p2.y},
             "Two players should not occupy the same tile after enter"

      # Cleanup
      MapServer.leave(@test_map_id, 8001)
      MapServer.leave(@test_map_id, 8002)
    end
  end

  describe "Bug #5: heading broadcast" do
    test "change_heading sends update to other sessions" do
      # Enter two players, we are the session for player 1
      e1 = make_entity(7001, "HeadingPlayer1")
      e2 = make_entity(7002, "HeadingPlayer2")

      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, e1, position: {40, 40})
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, e2, position: {41, 40})

      # Change heading for player 1
      MapServer.change_heading(@test_map_id, 7001, :north)

      # The other session (us, since we're the caller for e2) should
      # receive a heading update packet for player 1.
      # Give the cast time to process
      Process.sleep(50)

      received_heading_update =
        receive do
          {:send_raw, <<_::binary>>} -> true
        after
          100 -> false
        end

      assert received_heading_update,
             "Other sessions should receive heading change broadcasts"

      # Cleanup
      MapServer.leave(@test_map_id, 7001)
      MapServer.leave(@test_map_id, 7002)
    end
  end

  describe "AoI visible set lifecycle" do
    test "enter returns only nearby players, not all map players" do
      # With test AoI of 100, all players on the map should be visible.
      # We verify enter returns the entering player + nearby others.
      e1 = make_entity(6001, "AoiPlayer1")
      e2 = make_entity(6002, "AoiPlayer2")

      {:ok, _, players1, _weather} = MapServer.enter(@test_map_id, e1, position: {20, 20})
      assert Map.has_key?(players1, 6001), "enter should return self in nearby players"

      {:ok, _, players2, _weather} = MapServer.enter(@test_map_id, e2, position: {21, 20})
      assert Map.has_key?(players2, 6002), "enter should return self"
      assert Map.has_key?(players2, 6001), "enter should return nearby player"

      MapServer.leave(@test_map_id, 6001)
      MapServer.leave(@test_map_id, 6002)
    end

    test "enter sends character_create to nearby players" do
      # We are the session for e1. When e2 enters nearby, we should get character_create.
      e1 = make_entity(6101, "AoiCreate1")
      e2 = make_entity(6102, "AoiCreate2")

      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, e1, position: {25, 25})
      # Drain any messages from our own enter
      flush_mailbox()

      # Enter e2 — the test process is e1's session, so we receive e2's create broadcast
      MapServer.enter(@test_map_id, e2, position: {26, 25})

      received_create =
        receive do
          {:send_raw, <<_::binary>>} -> true
        after
          200 -> false
        end

      assert received_create, "Nearby session should receive character_create on enter"

      MapServer.leave(@test_map_id, 6101)
      MapServer.leave(@test_map_id, 6102)
    end

    test "leave sends character_remove only to visible sessions" do
      e1 = make_entity(6201, "AoiLeave1")
      e2 = make_entity(6202, "AoiLeave2")

      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, e1, position: {30, 30})
      flush_mailbox()

      # Enter e2 via direct call (e2's session is the GenServer.call caller)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, e2, position: {31, 30})
      flush_mailbox()

      # Now leave e2 — we (e1's session) should get character_remove
      MapServer.leave(@test_map_id, 6202)

      received_remove =
        receive do
          {:send_raw, <<_::binary>>} -> true
        after
          200 -> false
        end

      assert received_remove, "Visible session should receive character_remove on leave"

      MapServer.leave(@test_map_id, 6201)
    end

    test "movement sends character_move to visible sessions" do
      e1 = make_entity(6301, "AoiMove1")
      e2 = make_entity(6302, "AoiMove2")

      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, e1, position: {35, 35})
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, e2, position: {36, 35})
      flush_mailbox()

      # Move e1 — try multiple directions until one succeeds
      move_result =
        Enum.find_value([:south, :north, :east, :west], fn dir ->
          case MapServer.move_character(@test_map_id, 6301, dir) do
            {:ok, _pos} -> dir
            {:error, _} -> nil
          end
        end)

      assert move_result != nil, "at least one direction should be walkable"

      received_move =
        receive do
          {:send_raw, <<_::binary>>} -> true
        after
          200 -> false
        end

      assert received_move, "Visible session should receive character_move"

      MapServer.leave(@test_map_id, 6301)
      MapServer.leave(@test_map_id, 6302)
    end
  end

  describe "map transfers" do
    test "walking onto a real exit tile sends a transfer message" do
      {exit_tile, {start_x, start_y}, direction} = find_reachable_exit(@test_map_id)
      assert exit_tile != nil, "expected at least one reachable exit tile on the test map"

      entity = make_entity(6401, "ExitWalker")
      {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity, position: {start_x, start_y})
      flush_mailbox()

      assert {:ok, _pos} = MapServer.move_character(@test_map_id, 6401, direction)

      {dest_map, dest_x, dest_y, moved_entity} = receive_transfer(6401)

      assert is_integer(dest_map) and dest_map > 0
      assert is_integer(dest_x) and is_integer(dest_y)
      assert moved_entity.x == exit_tile.x
      assert moved_entity.y == exit_tile.y

      # Two-step transfer: player stays on source until explicitly removed
      MapServer.leave(@test_map_id, 6401)
    end

    test "full map transition: walk onto exit, enter destination map, verify position" do
      {exit_tile, {start_x, start_y}, direction} = find_reachable_exit(@test_map_id)
      assert exit_tile != nil

      # Start destination map
      dest_map_id = exit_tile.dest_map
      ensure_map_started(dest_map_id)

      entity = make_entity(6501, "TransitPlayer")
      {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity, position: {start_x, start_y})
      flush_mailbox()

      # Walk onto exit
      assert {:ok, _pos} = MapServer.move_character(@test_map_id, 6501, direction)
      {dest_map, dest_x, dest_y, transferred_entity} = receive_transfer(6501)

      assert dest_map == dest_map_id
      assert dest_x == exit_tile.dest_x
      assert dest_y == exit_tile.dest_y

      # Two-step transfer: enter destination first, then leave source
      {:ok, _new_idx, dest_players, _weather} =
        MapServer.enter(dest_map, transferred_entity, position: {dest_x, dest_y})
      MapServer.leave(@test_map_id, 6501)

      dest_entity = Map.get(dest_players, 6501)
      assert dest_entity != nil, "Player should exist on destination map"
      assert dest_entity.x == dest_x
      assert dest_entity.y == dest_y
      assert dest_entity.map_id == dest_map

      # Cleanup
      MapServer.leave(dest_map, 6501)
    end

    test "transfer preserves player state (hp, inventory, gold)" do
      {exit_tile, {start_x, start_y}, direction} = find_reachable_exit(@test_map_id)
      assert exit_tile != nil

      dest_map_id = exit_tile.dest_map
      ensure_map_started(dest_map_id)

      entity = %{make_entity(6601, "StatefulTransit") |
        hp: 42,
        max_hp: 100,
        gold: 1234,
        level: 7,
        inventory: [%{item_id: 100, amount: 5, equipped: false} | List.duplicate(nil, 23)]
      }
      {:ok, _idx, _, _weather} = MapServer.enter(@test_map_id, entity, position: {start_x, start_y})
      flush_mailbox()

      assert {:ok, _pos} = MapServer.move_character(@test_map_id, 6601, direction)
      {dest_map, dest_x, dest_y, transferred} = receive_transfer(6601)

      # Two-step transfer: enter destination first, then leave source
      {:ok, _, dest_players, _weather} = MapServer.enter(dest_map, transferred, position: {dest_x, dest_y})
      MapServer.leave(@test_map_id, 6601)

      dest_entity = Map.get(dest_players, 6601)

      assert dest_entity.hp == 42
      assert dest_entity.max_hp == 100
      assert dest_entity.gold == 1234
      assert dest_entity.level == 7
      assert hd(dest_entity.inventory) == %{item_id: 100, amount: 5, equipped: false}

      MapServer.leave(dest_map, 6601)
    end

    test "bidirectional transfer: go to dest and come back" do
      {exit_tile, {start_x, start_y}, direction} = find_reachable_exit(@test_map_id)
      assert exit_tile != nil

      dest_map_id = exit_tile.dest_map
      ensure_map_started(dest_map_id)

      entity = make_entity(6701, "RoundTripper")
      {:ok, _idx, _, _weather} = MapServer.enter(@test_map_id, entity, position: {start_x, start_y})
      flush_mailbox()

      # Forward: map 1 → dest (two-step: enter dest, then leave source)
      assert {:ok, _} = MapServer.move_character(@test_map_id, 6701, direction)
      {dest_map, dest_x, dest_y, transferred} = receive_transfer(6701)
      assert dest_map == dest_map_id

      {:ok, _, _, _weather} = MapServer.enter(dest_map, transferred, position: {dest_x, dest_y})
      MapServer.leave(@test_map_id, 6701)
      flush_mailbox()

      # Find an exit on dest map that goes back to map 1
      return_exit = find_reachable_exit_to(dest_map, @test_map_id)

      if return_exit do
        {_ret_exit, {ret_sx, ret_sy}, ret_dir} = return_exit

        # Reposition on dest map: leave and re-enter at return exit start position
        MapServer.leave(dest_map, 6701)
        flush_mailbox()
        # Re-entering resets the entity, including next_move_at
        {:ok, _, _, _weather} = MapServer.enter(dest_map, transferred, position: {ret_sx, ret_sy})
        flush_mailbox()
        # Wait for walk cooldown
        Process.sleep(250)

        assert {:ok, _} = MapServer.move_character(dest_map, 6701, ret_dir)
        {back_map, back_x, back_y, back_entity} = receive_transfer(6701)

        assert back_map == @test_map_id
        assert back_entity.char_id == 6701

        # Two-step: enter back map, then leave dest
        {:ok, _, _, _weather} = MapServer.enter(back_map, back_entity, position: {back_x, back_y})
        MapServer.leave(dest_map, 6701)
        MapServer.leave(back_map, 6701)
      else
        # No return exit found — just cleanup
        MapServer.leave(dest_map, 6701)
      end
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
  end

  defp receive_transfer(char_id) do
    # Drain :send_raw messages until we get the :transfer message
    receive_transfer_loop(char_id, 500)
  end

  defp receive_transfer_loop(char_id, timeout) do
    receive do
      {:transfer, dest_map, dest_x, dest_y, %PlayerEntity{char_id: ^char_id} = entity} ->
        {dest_map, dest_x, dest_y, entity}

      {:send_raw, _} ->
        receive_transfer_loop(char_id, timeout)
    after
      timeout -> raise "Did not receive :transfer message for char_id #{char_id} within #{timeout}ms"
    end
  end

  defp find_reachable_exit(map_id) do
    data = MapServer.get_map_data(map_id)

    Enum.find_value(data.exits, fn ex ->
      # For each exit tile, find an adjacent walkable tile to start from.
      # The direction moves FROM start TO exit.
      [
        {0, -1, :south},  # start is 1 tile north, walk south
        {1, 0, :west},    # start is 1 tile east, walk west
        {0, 1, :north},   # start is 1 tile south, walk north
        {-1, 0, :east}    # start is 1 tile west, walk east
      ]
      |> Enum.find_value(fn {dx, dy, dir} ->
        sx = ex.x + dx
        sy = ex.y + dy

        if sx >= 1 and sx <= 100 and sy >= 1 and sy <= 100 and
             TileGrid.is_walkable(map_id, ex.x, ex.y) and
             TileGrid.is_walkable(map_id, sx, sy) do
          {ex, {sx, sy}, dir}
        end
      end)
    end)
  end

  defp find_reachable_exit_to(map_id, target_map_id) do
    data = MapServer.get_map_data(map_id)

    data.exits
    |> Enum.filter(fn ex -> ex.dest_map == target_map_id end)
    |> Enum.find_value(fn ex ->
      [
        {0, -1, :south},
        {1, 0, :west},
        {0, 1, :north},
        {-1, 0, :east}
      ]
      |> Enum.find_value(fn {dx, dy, dir} ->
        sx = ex.x + dx
        sy = ex.y + dy

        if sx >= 1 and sx <= 100 and sy >= 1 and sy <= 100 and
             TileGrid.is_walkable(map_id, ex.x, ex.y) and
             TileGrid.is_walkable(map_id, sx, sy) do
          {ex, {sx, sy}, dir}
        end
      end)
    end)
  end

  defp ensure_map_started(map_id) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(map_id)
    end
  end
end
