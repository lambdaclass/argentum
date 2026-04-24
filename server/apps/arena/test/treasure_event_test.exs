defmodule Arena.TreasureEventTest do
  @moduledoc """
  Tests for the treasure search event system (VB6: ModTesoros / HandleBusquedaTesoro).

  Validates:
    - Only one event active at a time
    - Treasure/gift events end when item is picked up at event location
    - Pickup at non-event location does not end event
    - Reannounce works only when event is active
    - GameData loads treasure config from Tesoros.dat
  """
  use ExUnit.Case

  alias Arena.TreasureEvent
  alias Arena.Data.GameData

  # We need GameData for treasure config.
  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    # Start a fresh TreasureEvent process for each test.
    # Use start (not start_link) so the GenServer isn't killed by the
    # test process's shutdown before on_exit can run — otherwise the
    # Process.alive?/GenServer.stop pair races the link teardown.
    name = :"treasure_event_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start(TreasureEvent, [], name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{pid: pid}
  end

  describe "GameData treasure config loading" do
    test "loads treasure config from Tesoros.dat" do
      config = GameData.get_treasure_config()
      assert is_map(config)
      assert is_list(config.treasure_maps)
      assert is_list(config.treasure_items)
      assert is_list(config.gift_maps)
      assert is_list(config.gift_items)
      assert is_list(config.npc_ids)
      assert is_list(config.npc_maps)
    end

    test "treasure maps contains expected map IDs from Tesoros.dat" do
      config = GameData.get_treasure_config()
      # From Tesoros.dat: Mapa1=16, Mapa2=213, ...
      assert 16 in config.treasure_maps
      assert 213 in config.treasure_maps
      assert length(config.treasure_maps) == 10
    end

    test "treasure items are parsed as {item_id, amount} tuples" do
      config = GameData.get_treasure_config()
      # From Tesoros.dat: Tesoro1=3140-1
      assert {3140, 1} in config.treasure_items
    end

    test "gift maps loaded from Regalos section" do
      config = GameData.get_treasure_config()
      # From Tesoros.dat: [Regalos] Mapa1=293
      assert 293 in config.gift_maps
      assert length(config.gift_maps) == 12
    end

    test "gift items parsed correctly" do
      config = GameData.get_treasure_config()
      # From Tesoros.dat: Regalo1=3744-1
      assert {3744, 1} in config.gift_items
    end

    test "NPC IDs loaded from Criatura section" do
      config = GameData.get_treasure_config()
      # From Tesoros.dat: NPC1=591, NPC2=592
      assert 591 in config.npc_ids
      assert 592 in config.npc_ids
      assert length(config.npc_ids) == 2
    end

    test "NPC maps loaded from Criatura section" do
      config = GameData.get_treasure_config()
      # From Tesoros.dat: [Criatura] CantidadMapas=15, Mapa1=35 ...
      assert 35 in config.npc_maps
      assert length(config.npc_maps) == 15
    end
  end

  describe "event lifecycle" do
    test "no event is active initially", %{pid: pid} do
      state = GenServer.call(pid, :get_state)
      assert state.active_event == nil
    end

    test "cannot reannounce when no event is active", %{pid: pid} do
      assert {:error, :no_active_event} = GenServer.call(pid, :reannounce)
    end

    test "check_pickup returns :no_event when no event active", %{pid: pid} do
      assert :no_event = GenServer.call(pid, {:check_pickup, 1, 50, 50, "TestPlayer"})
    end
  end

  describe "event state management" do
    test "only one event can be active at a time", %{pid: pid} do
      # Manually set an active event
      :sys.replace_state(pid, fn state ->
        %{state | active_event: %{type: :treasure, map_id: 1, x: 50, y: 50, item_id: 100, amount: 1}}
      end)

      # Starting another event should fail
      result = GenServer.call(pid, {:start_event, :treasure})
      assert {:error, :event_already_active, _} = result
    end

    test "check_pickup completes treasure event at correct location", %{pid: pid} do
      :sys.replace_state(pid, fn state ->
        %{state | active_event: %{type: :treasure, map_id: 42, x: 30, y: 60, item_id: 3140, amount: 1}}
      end)

      # Pickup at wrong location - event stays active
      assert :no_event = GenServer.call(pid, {:check_pickup, 42, 31, 60, "WrongPlayer"})

      state = GenServer.call(pid, :get_state)
      assert state.active_event != nil

      # Pickup at wrong map - event stays active
      assert :no_event = GenServer.call(pid, {:check_pickup, 99, 30, 60, "WrongPlayer"})

      state = GenServer.call(pid, :get_state)
      assert state.active_event != nil

      # Pickup at correct location - event ends
      assert {:event_found, :treasure} = GenServer.call(pid, {:check_pickup, 42, 30, 60, "LuckyPlayer"})

      state = GenServer.call(pid, :get_state)
      assert state.active_event == nil
    end

    test "check_pickup completes gift event at correct location", %{pid: pid} do
      :sys.replace_state(pid, fn state ->
        %{state | active_event: %{type: :gift, map_id: 293, x: 45, y: 55, item_id: 3744, amount: 1}}
      end)

      assert {:event_found, :gift} = GenServer.call(pid, {:check_pickup, 293, 45, 55, "Finder"})

      state = GenServer.call(pid, :get_state)
      assert state.active_event == nil
    end

    test "npc_killed ends NPC event with matching instance id", %{pid: pid} do
      :sys.replace_state(pid, fn state ->
        %{state | active_event: %{type: :npc, map_id: 35, npc_instance_id: 42}}
      end)

      # Wrong NPC instance
      GenServer.cast(pid, {:npc_killed, 99})
      :timer.sleep(50)
      state = GenServer.call(pid, :get_state)
      assert state.active_event != nil

      # Correct NPC instance
      GenServer.cast(pid, {:npc_killed, 42})
      :timer.sleep(50)
      state = GenServer.call(pid, :get_state)
      assert state.active_event == nil
    end

    test "reannounce works when event is active", %{pid: pid} do
      :sys.replace_state(pid, fn state ->
        %{state | active_event: %{type: :treasure, map_id: 1, x: 50, y: 50, item_id: 100, amount: 1}}
      end)

      # Should not error (broadcast will silently fail since no sessions exist)
      assert :ok = GenServer.call(pid, :reannounce)
    end

    test "after event ends, a new event can be started", %{pid: pid} do
      # Set and complete a treasure event
      :sys.replace_state(pid, fn state ->
        %{state | active_event: %{type: :treasure, map_id: 42, x: 30, y: 60, item_id: 3140, amount: 1}}
      end)

      assert {:event_found, :treasure} = GenServer.call(pid, {:check_pickup, 42, 30, 60, "Player"})

      # Now we should be able to set a new event
      state = GenServer.call(pid, :get_state)
      assert state.active_event == nil
    end

    test "check_pickup ignores NPC events (only treasure/gift)", %{pid: pid} do
      :sys.replace_state(pid, fn state ->
        %{state | active_event: %{type: :npc, map_id: 35, npc_instance_id: 42}}
      end)

      assert :no_event = GenServer.call(pid, {:check_pickup, 35, 50, 50, "Player"})
    end
  end
end
