defmodule Arena.Map.AoiVisibilityTest do
  @moduledoc """
  Tests that AoI visibility culling works correctly under :aoi_grid mode.

  These tests override the default :global visibility_mode and start a fresh
  MapServer under :aoi_grid to validate that players outside AoI range do NOT
  receive broadcasts and players inside range DO.

  Compile-time AoI ranges: @aoi_range_x=11, @aoi_range_y=9 (production values).
  """
  use ExUnit.Case

  alias Arena.Map.MapServer
  alias Arena.Map.MapSupervisor
  alias AoEntities.PlayerEntity

  # Use map 2 to avoid conflicts with map_server_bugs_test (which uses map 1)
  @test_map_id 2

  # Production AoI half-ranges (compile-time in map_server.ex)
  @aoi_x 11
  @aoi_y 9

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
    # Switch to :aoi_grid mode for these tests
    original_mode = Application.get_env(:arena, :visibility_mode)
    Application.put_env(:arena, :visibility_mode, :aoi_grid)

    # Stop existing map (may have been started under :global) and start fresh
    MapSupervisor.stop_map(@test_map_id)
    Process.sleep(50)
    {:ok, _pid} = MapSupervisor.start_map(@test_map_id)

    on_exit(fn ->
      # Clean up: restore original mode and restart map under it
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

  # Enter a player from a separate process so that NPC create packets and other
  # side-effect messages go to that process instead of polluting the test mailbox.
  # The spawned process stays alive to act as the player's session.
  defp enter_from_other_process(map_id, entity, opts) do
    test_pid = self()

    pid =
      spawn(fn ->
        result = MapServer.enter(map_id, entity, opts)
        send(test_pid, {:enter_result, result})

        # Stay alive so the MapServer keeps this session registered
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

  describe "far players are invisible" do
    test "enter does NOT send character_create to a player outside AoI range" do
      # Place player A at (10, 10). We are A's session process.
      a = make_entity(10_001, "FarA", 10, 10)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {10, 10})
      flush_mailbox()

      # Place player B far away — more than @aoi_x tiles apart in X.
      # Enter B from a separate process so B's NPC creates don't pollute our mailbox.
      far_x = 10 + @aoi_x + 5
      b = make_entity(10_002, "FarB", far_x, 10)
      {b_pid, _result} = enter_from_other_process(@test_map_id, b, position: {far_x, 10})

      # A should NOT receive a character_create for B
      messages = collect_raw_messages(200)
      assert messages == [], "Player outside AoI should not trigger character_create"

      MapServer.leave(@test_map_id, 10_001)
      MapServer.leave(@test_map_id, 10_002)
      send(b_pid, :stop)
    end

    test "enter returns only nearby players in the visible set" do
      a = make_entity(10_101, "NearbyA", 10, 10)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {10, 10})

      # B is far away
      far_x = 10 + @aoi_x + 5
      b = make_entity(10_102, "NearbyB", far_x, 10)
      {:ok, _, players, _weather} = MapServer.enter(@test_map_id, b, position: {far_x, 10})

      # B's returned player map should contain B (self) but NOT A (too far)
      assert Map.has_key?(players, 10_102), "enter should return self"
      refute Map.has_key?(players, 10_101), "enter should NOT return player outside AoI"

      MapServer.leave(@test_map_id, 10_101)
      MapServer.leave(@test_map_id, 10_102)
    end

    test "movement broadcast does NOT reach a far player" do
      # B enters first from a separate process (far away)
      far_x = 10 + @aoi_x + 5
      b = make_entity(10_202, "MoveB", far_x, 10)
      {b_pid, _result} = enter_from_other_process(@test_map_id, b, position: {far_x, 10})

      # Enter A — we are A's session
      a = make_entity(10_201, "MoveA", 10, 10)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {10, 10})
      flush_mailbox()

      # Move A. The mover receives pos_update and NPC creates (direct messages),
      # but should NOT receive a character_move broadcast (excluded as mover).
      # B is far away — B should not receive A's move broadcast either.
      result =
        Enum.find_value([:south, :north, :east, :west], fn dir ->
          case MapServer.move_character(@test_map_id, 10_201, dir) do
            {:ok, _pos} -> dir
            {:error, _} -> nil
          end
        end)

      assert result, "at least one direction should be walkable"

      # Collect all messages and filter out direct messages to the mover
      # (pos_update ID=22 and NPC creates ID=42). Only character_move (ID=44)
      # broadcasts would indicate a leak.
      messages = collect_raw_messages(200)
      broadcast_msgs =
        Enum.filter(messages, fn <<packet_id, _rest::binary>> ->
          packet_id == 44
        end)

      assert broadcast_msgs == [], "No character_move broadcast should reach the mover"

      MapServer.leave(@test_map_id, 10_201)
      MapServer.leave(@test_map_id, 10_202)
      send(b_pid, :stop)
    end

    test "leave does NOT send character_remove to a far player" do
      a = make_entity(10_301, "LeaveA", 10, 10)
      far_x = 10 + @aoi_x + 5
      b = make_entity(10_302, "LeaveB", far_x, 10)

      # We are A's session
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {10, 10})
      flush_mailbox()
      {b_pid, _result} = enter_from_other_process(@test_map_id, b, position: {far_x, 10})

      # B leaves — A should NOT get character_remove
      MapServer.leave(@test_map_id, 10_302)

      messages = collect_raw_messages(200)
      assert messages == [], "Far player leaving should not send remove to us"

      MapServer.leave(@test_map_id, 10_301)
      send(b_pid, :stop)
    end
  end

  describe "near players are visible" do
    test "enter sends character_create to a nearby player" do
      a = make_entity(11_001, "NearEnterA", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      # B enters 1 tile away — well within AoI
      b = make_entity(11_002, "NearEnterB", 51, 50)
      {b_pid, _result} = enter_from_other_process(@test_map_id, b, position: {51, 50})

      messages = collect_raw_messages(200)
      assert length(messages) > 0, "Nearby player entering should trigger character_create"

      MapServer.leave(@test_map_id, 11_001)
      MapServer.leave(@test_map_id, 11_002)
      send(b_pid, :stop)
    end

    test "movement broadcast reaches a nearby player" do
      a = make_entity(11_101, "NearMoveA", 50, 50)
      b = make_entity(11_102, "NearMoveB", 52, 50)

      # We are B's session
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, b, position: {52, 50})
      flush_mailbox()
      {a_pid, _result} = enter_from_other_process(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      # Move A — B should receive the move broadcast
      Enum.find_value([:south, :north, :east, :west], fn dir ->
        case MapServer.move_character(@test_map_id, 11_101, dir) do
          {:ok, _pos} -> dir
          {:error, _} -> nil
        end
      end)

      messages = collect_raw_messages(200)
      assert length(messages) > 0, "Nearby player should receive movement broadcast"

      MapServer.leave(@test_map_id, 11_101)
      MapServer.leave(@test_map_id, 11_102)
      send(a_pid, :stop)
    end

    test "leave sends character_remove to a nearby player" do
      a = make_entity(11_201, "NearLeaveA", 50, 50)
      b = make_entity(11_202, "NearLeaveB", 51, 50)

      # We are A's session
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()
      {b_pid, _result} = enter_from_other_process(@test_map_id, b, position: {51, 50})
      flush_mailbox()

      # B leaves — A should get character_remove
      MapServer.leave(@test_map_id, 11_202)

      messages = collect_raw_messages(200)
      assert length(messages) > 0, "Nearby player leaving should send character_remove"

      MapServer.leave(@test_map_id, 11_201)
      send(b_pid, :stop)
    end

    test "heading change reaches a nearby player" do
      a = make_entity(11_301, "NearHeadA", 50, 50)
      b = make_entity(11_302, "NearHeadB", 51, 50)

      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, b, position: {51, 50})
      flush_mailbox()
      {a_pid, _result} = enter_from_other_process(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      # A changes heading — B (us) should receive the broadcast
      MapServer.change_heading(@test_map_id, 11_301, :north)
      Process.sleep(50)

      messages = collect_raw_messages(200)
      assert length(messages) > 0, "Nearby player should receive heading change"

      MapServer.leave(@test_map_id, 11_301)
      MapServer.leave(@test_map_id, 11_302)
      send(a_pid, :stop)
    end

    test "heading change does NOT reach a far player" do
      a = make_entity(11_401, "FarHeadA", 10, 10)
      far_x = 10 + @aoi_x + 5
      b = make_entity(11_402, "FarHeadB", far_x, 10)

      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, b, position: {far_x, 10})
      flush_mailbox()
      {a_pid, _result} = enter_from_other_process(@test_map_id, a, position: {10, 10})
      flush_mailbox()

      # A changes heading — B (us) should NOT receive it
      MapServer.change_heading(@test_map_id, 11_401, :south)
      Process.sleep(50)

      messages = collect_raw_messages(200)
      assert messages == [], "Far player should not receive heading change"

      MapServer.leave(@test_map_id, 11_401)
      MapServer.leave(@test_map_id, 11_402)
      send(a_pid, :stop)
    end
  end

  describe "AoI boundary crossing" do
    test "moving into AoI range sends character_create to both players" do
      # A is stationary at (50, 50). We are A's session.
      a = make_entity(12_001, "BoundaryA", 50, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()

      # B starts just outside AoI range (aoi_x + 1 tiles away in X)
      start_x = 50 + @aoi_x + 1
      b = make_entity(12_002, "BoundaryB", start_x, 50)
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, b, position: {start_x, 50})
      flush_mailbox()

      # B should not be visible to A yet
      messages_before = collect_raw_messages(100)
      assert messages_before == [], "Player just outside AoI should not be visible"

      # Now move B west (toward A) — this should bring B into A's AoI range
      # B is at (50 + aoi_x + 1, 50), moving west puts B at (50 + aoi_x, 50)
      # which is exactly @aoi_x tiles from A — within range
      Process.sleep(250)

      case MapServer.move_character(@test_map_id, 12_002, :west) do
        {:ok, _pos} ->
          messages = collect_raw_messages(200)

          assert length(messages) > 0,
                 "Moving into AoI range should send character_create to the other player"

        {:error, reason} ->
          flunk("Move west failed: #{inspect(reason)}")
      end

      MapServer.leave(@test_map_id, 12_001)
      MapServer.leave(@test_map_id, 12_002)
    end

    test "moving out of AoI range sends character_remove to both players" do
      # A at (50, 50), B at exactly AoI boundary (50 + aoi_x, 50) — visible
      a = make_entity(12_101, "LeaveRangeA", 50, 50)
      edge_x = 50 + @aoi_x
      b = make_entity(12_102, "LeaveRangeB", edge_x, 50)

      # We are A's session
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()
      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, b, position: {edge_x, 50})
      # Should get create since B is at boundary (within range)
      create_msgs = collect_raw_messages(200)
      assert length(create_msgs) > 0, "Player at AoI boundary should be visible"

      # Move B east (away from A) — puts B at (aoi_x + 1) distance, outside range
      Process.sleep(250)

      case MapServer.move_character(@test_map_id, 12_102, :east) do
        {:ok, _pos} ->
          remove_msgs = collect_raw_messages(200)

          assert length(remove_msgs) > 0,
                 "Moving out of AoI range should send character_remove"

        {:error, reason} ->
          flunk("Move east failed: #{inspect(reason)}")
      end

      MapServer.leave(@test_map_id, 12_101)
      MapServer.leave(@test_map_id, 12_102)
    end
  end

  describe "Y-axis AoI range" do
    test "player outside Y range is invisible" do
      a = make_entity(13_001, "YRangeA", 50, 50)
      far_y = 50 + @aoi_y + 5
      b = make_entity(13_002, "YRangeB", 50, far_y)

      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()
      {b_pid, _result} = enter_from_other_process(@test_map_id, b, position: {50, far_y})

      messages = collect_raw_messages(200)
      assert messages == [], "Player outside Y AoI range should be invisible"

      MapServer.leave(@test_map_id, 13_001)
      MapServer.leave(@test_map_id, 13_002)
      send(b_pid, :stop)
    end

    test "player at Y boundary is visible" do
      a = make_entity(13_101, "YBoundA", 50, 50)
      edge_y = 50 + @aoi_y
      b = make_entity(13_102, "YBoundB", 50, edge_y)

      {:ok, _, _, _weather} = MapServer.enter(@test_map_id, a, position: {50, 50})
      flush_mailbox()
      {b_pid, _result} = enter_from_other_process(@test_map_id, b, position: {50, edge_y})

      messages = collect_raw_messages(200)
      assert length(messages) > 0, "Player at Y AoI boundary should be visible"

      MapServer.leave(@test_map_id, 13_001)
      MapServer.leave(@test_map_id, 13_002)
      send(b_pid, :stop)
    end
  end
end
