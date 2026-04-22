defmodule Arena.TreasureNpcDriftTest do
  @moduledoc """
  Drift #32: Treasure NPC event must actually spawn the NPC on the map.

  VB6 reference (ModTesoros / Protocol.bas line ~6450):
    npc_index_evento = SpawnNpc(TesoroNPC(RandomNumber(1, UBound(TesoroNPC))), pos, True, False, True)
    BusquedaNpcActiva = True

  The Elixir code was returning npc_instance_id: nil without calling MapServer,
  so notify_npc_killed could never match and the event could never end organically.
  """
  use ExUnit.Case

  alias Arena.TreasureEvent
  alias Arena.Map.MapServer
  alias Arena.Data.GameData

  # Use map 1 which is always available in test data
  @test_map_id 10_009

  setup_all do
    # Start only the processes we need (same pattern as map_server_bugs_test)
    Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Arena.MapRegistry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Arena.MapRegistry)
    end

    unless Process.whereis(Arena.PubSub) do
      {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end

    unless Process.whereis(GameData) do
      {:ok, _} = GameData.start_link([])
    end

    unless Process.whereis(Arena.Map.MapSupervisor) do
      {:ok, _} = Arena.Map.MapSupervisor.start_link([])
    end

    # Start the test map if not already running
    case Registry.lookup(Arena.MapRegistry, @test_map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(@test_map_id)
    end

    # Wait for map to be fully loaded
    wait_for_map_ready(@test_map_id, 50, 100)

    :ok
  end

  setup do
    # Override treasure config to use our test map with a known NPC
    original_config = GameData.get_treasure_config()
    npc_id = List.first(original_config.npc_ids) || 591

    :ets.insert(:arena_game_data, {:treasure_config, %{
      treasure_maps: [@test_map_id],
      treasure_items: [{100, 1}],
      gift_maps: [@test_map_id],
      gift_items: [{200, 1}],
      npc_ids: [npc_id],
      npc_maps: [@test_map_id]
    }})

    # Ensure the TreasureEvent GenServer exists.
    # If the application started it, just reset its state.
    # Otherwise start a fresh one.
    pid =
      case Process.whereis(TreasureEvent) do
        nil ->
          {:ok, p} = TreasureEvent.start_link([])
          p

        existing_pid ->
          :sys.replace_state(existing_pid, fn _state ->
            %{active_event: nil, ttl_timer_ref: nil}
          end)

          existing_pid
      end

    on_exit(fn ->
      # Clear any active event so other tests are not affected
      if Process.alive?(pid) do
        :sys.replace_state(pid, fn _state -> %{active_event: nil, ttl_timer_ref: nil} end)
      end

      # Restore original treasure config
      try do
        :ets.insert(:arena_game_data, {:treasure_config, original_config})
      rescue
        ArgumentError -> :ok
      end
    end)

    %{pid: pid, npc_id: npc_id}
  end

  describe "Drift #32: NPC event spawns real NPC" do
    test "start_event(:npc) stores a non-nil npc_instance_id", %{pid: pid} do
      assert :ok = GenServer.call(pid, {:start_event, :npc})

      state = GenServer.call(pid, :get_state)
      event = state.active_event

      assert event != nil
      assert event.type == :npc
      assert event.map_id == @test_map_id
      # This is the critical assertion: the NPC must actually be spawned
      assert event.npc_instance_id != nil,
             "npc_instance_id should not be nil — the NPC must be spawned via MapServer"
    end

    test "spawned NPC exists on the MapServer", %{pid: pid} do
      assert :ok = GenServer.call(pid, {:start_event, :npc})

      state = GenServer.call(pid, :get_state)
      instance_id = state.active_event.npc_instance_id

      # The NPC should actually exist on the map
      assert instance_id != nil
      {:ok, npc_snapshot} = MapServer.snapshot_npc(@test_map_id, instance_id)
      assert npc_snapshot != nil
    end

    test "notify_npc_killed ends event when NPC is killed", %{pid: pid} do
      assert :ok = GenServer.call(pid, {:start_event, :npc})

      state = GenServer.call(pid, :get_state)
      instance_id = state.active_event.npc_instance_id

      assert instance_id != nil

      # Simulate the NPC being killed
      GenServer.cast(pid, {:npc_killed, instance_id})
      :timer.sleep(50)

      state = GenServer.call(pid, :get_state)
      assert state.active_event == nil,
             "Event should be cleared after the spawned NPC is killed"
    end

    test "notify_npc_killed with wrong id does NOT end event", %{pid: pid} do
      assert :ok = GenServer.call(pid, {:start_event, :npc})

      state = GenServer.call(pid, :get_state)
      instance_id = state.active_event.npc_instance_id
      assert instance_id != nil

      # Kill with a wrong instance id
      GenServer.cast(pid, {:npc_killed, instance_id + 9999})
      :timer.sleep(50)

      state = GenServer.call(pid, :get_state)
      assert state.active_event != nil,
             "Event should NOT be cleared when a different NPC is killed"
    end
  end

  describe "Drift: NPC event timeout cleanup" do
    test "start_event(:npc) stores a TTL timer ref in state", %{pid: pid} do
      assert :ok = GenServer.call(pid, {:start_event, :npc})

      state = GenServer.call(pid, :get_state)
      assert state.ttl_timer_ref != nil,
             "ttl_timer_ref must be set when an NPC event starts"
    end

    test "npc_event_timeout despawns NPC and clears the event", %{pid: pid} do
      assert :ok = GenServer.call(pid, {:start_event, :npc})

      state = GenServer.call(pid, :get_state)
      event = state.active_event
      assert event != nil
      assert event.npc_instance_id != nil

      map_id = event.map_id
      instance_id = event.npc_instance_id

      # Verify the NPC exists on the map before timeout
      {:ok, npc_snapshot} = MapServer.snapshot_npc(map_id, instance_id)
      assert npc_snapshot != nil

      # Simulate the timeout message
      send(pid, :npc_event_timeout)
      :timer.sleep(100)

      # The event should be cleared
      state = GenServer.call(pid, :get_state)
      assert state.active_event == nil,
             "Event should be cleared after NPC timeout"
      assert state.ttl_timer_ref == nil,
             "ttl_timer_ref should be nil after timeout cleanup"

      # The NPC should be removed from the map
      result = MapServer.snapshot_npc(map_id, instance_id)
      assert result == {:ok, nil} or match?({:error, _}, result),
             "NPC should be despawned from MapServer after timeout"
    end

    test "npc_event_timeout is a no-op when no event is active", %{pid: pid} do
      # No event started — sending the timeout should not crash
      send(pid, :npc_event_timeout)
      :timer.sleep(50)

      assert Process.alive?(pid), "TreasureEvent should survive a stale timeout"
      state = GenServer.call(pid, :get_state)
      assert state.active_event == nil
    end

    test "npc_killed cancels the TTL timer", %{pid: pid} do
      assert :ok = GenServer.call(pid, {:start_event, :npc})

      state = GenServer.call(pid, :get_state)
      instance_id = state.active_event.npc_instance_id
      timer_ref = state.ttl_timer_ref
      assert timer_ref != nil

      # Simulate NPC killed
      GenServer.cast(pid, {:npc_killed, instance_id})
      :timer.sleep(50)

      state = GenServer.call(pid, :get_state)
      assert state.active_event == nil
      assert state.ttl_timer_ref == nil,
             "ttl_timer_ref should be cleared when NPC is killed"

      # The timer should have been cancelled (no late timeout crash)
      # Verify the process stays alive after the original timer would fire
      assert Process.alive?(pid)
    end
  end

  describe "Drift: NPC event cleanup on GenServer terminate" do
    test "terminate/2 despawns the NPC from MapServer", %{pid: _pid} do
      # Start a fresh TreasureEvent so we can stop it cleanly
      {:ok, fresh_pid} = GenServer.start_link(Arena.TreasureEvent, [], [])

      assert :ok = GenServer.call(fresh_pid, {:start_event, :npc})

      state = GenServer.call(fresh_pid, :get_state)
      event = state.active_event
      assert event != nil
      map_id = event.map_id
      instance_id = event.npc_instance_id
      assert instance_id != nil

      # Verify NPC exists
      {:ok, npc_snapshot} = MapServer.snapshot_npc(map_id, instance_id)
      assert npc_snapshot != nil

      # Stop the GenServer (triggers terminate/2)
      GenServer.stop(fresh_pid, :normal)
      :timer.sleep(100)

      # The NPC should have been cleaned up from the map
      result = MapServer.snapshot_npc(map_id, instance_id)
      assert result == {:ok, nil} or match?({:error, _}, result),
             "NPC should be despawned from MapServer when TreasureEvent terminates"
    end
  end

  defp wait_for_map_ready(_map_id, 0, _interval), do: :ok

  defp wait_for_map_ready(map_id, attempts, interval) do
    try do
      if MapServer.ready?(map_id) do
        :ok
      else
        Process.sleep(interval)
        wait_for_map_ready(map_id, attempts - 1, interval)
      end
    catch
      :exit, _ ->
        Process.sleep(interval)
        wait_for_map_ready(map_id, attempts - 1, interval)
    end
  end
end
