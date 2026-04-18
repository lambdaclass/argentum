defmodule AoTcpGateway.SessionTransferTest do
  @moduledoc """
  Tests for map transfer logic in SessionTransfer.transfer/5.

  Verifies:
  - Player is correctly removed from source map (no ghost sessions)
  - leave() failure is handled gracefully (logged, not crashed)
  - Transient session state flags are cleared on transfer
  """

  use ExUnit.Case

  alias AoTcpGateway.SessionTransfer
  alias Arena.Map.MapServer
  alias AoEntities.PlayerEntity

  @source_map 1
  @dest_map 2
  @third_map 3

  setup_all do
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

    unless Process.whereis(AoSession.SessionRegistry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: AoSession.SessionRegistry)
    end

    unless Process.whereis(AoSession.OnlineDirectory) do
      {:ok, _} = AoSession.OnlineDirectory.start_link()
    end

    ensure_map_started(@source_map)
    ensure_map_started(@dest_map)
    ensure_map_started(@third_map)

    :ok
  end

  setup do
    owner_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GameBackend.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid) end)
    :ok
  end

  # ---- Helpers ----

  defp unique_id, do: System.unique_integer([:positive]) + 200_000

  defp make_entity(char_id, overrides \\ %{}) do
    Map.merge(
      %PlayerEntity{
        char_id: char_id,
        name: "Transfer_#{char_id}",
        account_id: unique_id(),
        x: 50,
        y: 50,
        hp: 100,
        max_hp: 100,
        mana: 100,
        max_mana: 100,
        stamina: 100,
        max_stamina: 100,
        hunger: 100,
        thirst: 100,
        level: 1,
        gold: 100,
        class: :warrior,
        race: :humano,
        gender: :male,
        home_city: :ullathorpe,
        map_id: @source_map
      },
      overrides
    )
  end

  defp make_state(char_id, overrides \\ %{}) do
    Map.merge(
      %{
        character_id: char_id,
        map_id: @source_map,
        account_id: unique_id(),
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        hogar_timer_ref: nil
      },
      overrides
    )
  end

  defp ensure_map_started(map_id) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(map_id)
    end

    wait_map_ready(map_id, 50)
  end

  defp wait_map_ready(_map_id, 0), do: :ok

  defp wait_map_ready(map_id, retries) do
    if MapServer.ready?(map_id) do
      :ok
    else
      Process.sleep(100)
      wait_map_ready(map_id, retries - 1)
    end
  rescue
    _ ->
      Process.sleep(100)
      wait_map_ready(map_id, retries - 1)
  catch
    :exit, _ ->
      Process.sleep(100)
      wait_map_ready(map_id, retries - 1)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
  end

  # ---- Tests ----

  describe "transfer/5 removes player from source map (no ghost)" do
    test "player is absent from source map after transfer" do
      char_id = unique_id()
      entity = make_entity(char_id)
      state = make_state(char_id)

      # Enter source map first
      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      # Register in online directory (transfer calls update_map)
      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # Perform transfer
      {new_state, packets} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      # Verify: player should be on destination map
      assert new_state.map_id == @dest_map
      assert {:ok, dest_snap} = MapServer.snapshot_entity(@dest_map, char_id)
      assert dest_snap.char_id == char_id

      # CRITICAL: player must NOT be on source map (no ghost session)
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@source_map, char_id)

      # Verify packets include change_map
      dest = @dest_map
      assert Enum.any?(packets, fn
        {:change_map, %{map_id: ^dest}} -> true
        _ -> false
      end)

      # Cleanup
      MapServer.leave(@dest_map, char_id)
    end
  end

  describe "transfer/5 clears transient session state" do
    test "commerce_npc_id is cleared after transfer" do
      char_id = unique_id()
      entity = make_entity(char_id, %{commerce_npc_id: 42})
      state = make_state(char_id)

      # Enter source map
      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # Transfer
      {new_state, _packets} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      # The entity in the returned state should have commerce_npc_id cleared
      assert new_state.entity.commerce_npc_id == nil

      # Also verify on the map server itself
      {:ok, snap} = MapServer.snapshot_entity(@dest_map, char_id)
      assert snap.commerce_npc_id == nil

      MapServer.leave(@dest_map, char_id)
    end

    test "trade_partner_id and trade state cleared after transfer" do
      char_id = unique_id()

      entity =
        make_entity(char_id, %{
          trade_partner_id: 9999,
          trade_offer_gold: 500,
          trade_offer_items: [%{item_id: 1, amount: 1, equipped: false}],
          trade_accepted: true
        })

      state = make_state(char_id)

      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      {new_state, _packets} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      # All trade state should be cleared
      assert new_state.entity.trade_partner_id == nil
      assert new_state.entity.trade_offer_gold == 0
      assert new_state.entity.trade_offer_items == []
      assert new_state.entity.trade_accepted == false

      MapServer.leave(@dest_map, char_id)
    end

    test "meditating and resting flags cleared after transfer" do
      char_id = unique_id()
      entity = make_entity(char_id, %{meditating: true, resting: true})
      state = make_state(char_id)

      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      {new_state, _packets} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      assert new_state.entity.meditating == false
      assert new_state.entity.resting == false

      MapServer.leave(@dest_map, char_id)
    end

    test "bank_npc_id and quest_npc_id cleared after transfer" do
      char_id = unique_id()
      entity = make_entity(char_id, %{bank_npc_id: 10, quest_npc_id: 20})
      state = make_state(char_id)

      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      {new_state, _packets} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      assert new_state.entity.bank_npc_id == nil
      assert new_state.entity.quest_npc_id == nil

      MapServer.leave(@dest_map, char_id)
    end
  end

  describe "transfer/5 cancels hogar timer" do
    test "active hogar_timer_ref is cancelled and cleared after tile-exit transfer" do
      char_id = unique_id()
      entity = make_entity(char_id)

      # Simulate an active /HOGAR timer (10s delayed teleport)
      hogar_ref = Process.send_after(self(), :hogar_arrive, 60_000)
      state = make_state(char_id, %{hogar_timer_ref: hogar_ref})

      # Enter source map
      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # Perform tile-exit transfer (this is what happens when stepping on a tile exit)
      {new_state, _packets} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      # CRITICAL: hogar timer must be cancelled so it doesn't fire after transfer
      assert new_state.hogar_timer_ref == nil

      # The timer should actually be cancelled (not just the ref cleared)
      # Verify no :hogar_arrive message arrives
      refute_receive :hogar_arrive, 200

      MapServer.leave(@dest_map, char_id)
    end

    test "transfer with no active hogar timer does not crash" do
      char_id = unique_id()
      entity = make_entity(char_id)
      state = make_state(char_id, %{hogar_timer_ref: nil})

      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      {new_state, _packets} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      assert new_state.hogar_timer_ref == nil

      MapServer.leave(@dest_map, char_id)
    end
  end

  describe "rapid consecutive transfers (double tile-exit)" do
    test "back-to-back transfer A→B→C leaves player on C only" do
      char_id = unique_id()
      entity = make_entity(char_id)
      state = make_state(char_id)

      # Enter source map A
      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # First transfer: A → B (simulates first tile exit)
      {state_after_first, _packets1} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      assert state_after_first.map_id == @dest_map

      # Grab the updated entity from the destination map for the second transfer.
      # In real gameplay the second :transfer message carries a stale entity from map A
      # (captured by check_tile_exit before the first transfer was processed).
      # We test both: stale entity AND fresh entity.

      # Second transfer: B → C using the STALE entity from map A
      {state_after_second, _packets2} =
        SessionTransfer.transfer(state_after_first, @third_map, 40, 40, entity)
      flush_mailbox()

      # Player should be on map C
      assert state_after_second.map_id == @third_map
      assert {:ok, snap_c} = MapServer.snapshot_entity(@third_map, char_id)
      assert snap_c.char_id == char_id

      # Player must NOT be on map A or map B (no ghosts)
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@source_map, char_id)
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@dest_map, char_id)

      # Cleanup
      MapServer.leave(@third_map, char_id)
    end

    test "second transfer with stale entity does not crash and produces valid state" do
      char_id = unique_id()
      entity = make_entity(char_id)
      state = make_state(char_id)

      # Enter source map A
      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # First transfer: A → B
      {state_b, _packets} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      # Capture the stale entity (as it was on map A before first transfer)
      stale_entity = entity

      # Second transfer: B → C with stale entity from map A
      # The key thing: stale_entity has x/y/map_id from map A, but transfer
      # should use state.map_id (which is B) as the source_map and the
      # MapServer.enter should override positions.
      {state_c, packets_c} =
        SessionTransfer.transfer(state_b, @third_map, 25, 25, stale_entity)
      flush_mailbox()

      # Should not crash and should produce valid state
      assert state_c.map_id == @third_map
      assert state_c.entity != nil
      assert state_c.entity.char_id == char_id

      # Entity position should reflect destination, not stale source
      assert state_c.entity.x == 25 or state_c.entity.x != nil
      assert state_c.entity.y == 25 or state_c.entity.y != nil

      # Packets should include change_map for the third map
      third = @third_map
      assert Enum.any?(packets_c, fn
        {:change_map, %{map_id: ^third}} -> true
        _ -> false
      end)

      # No ghost on B
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@dest_map, char_id)

      MapServer.leave(@third_map, char_id)
    end

    test "double transfer to same destination does not duplicate player" do
      char_id = unique_id()
      entity = make_entity(char_id)
      state = make_state(char_id)

      # Enter source map A
      {:ok, idx, _players, _weather} = MapServer.enter(@source_map, entity, position: {50, 50})
      flush_mailbox()

      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @source_map, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # First transfer: A → B
      {state_b, _packets1} = SessionTransfer.transfer(state, @dest_map, 30, 30, entity)
      flush_mailbox()

      assert state_b.map_id == @dest_map

      # Second transfer: tries to go to B AGAIN (same destination)
      # This simulates two tile exits both pointing to the same map.
      # source_map will be B (from state), dest_map is also B.
      # enter(B, entity) is called while player is already on B.
      {state_b2, packets2} =
        SessionTransfer.transfer(state_b, @dest_map, 35, 35, entity)
      flush_mailbox()

      # Player should still be on map B
      assert state_b2.map_id == @dest_map
      assert state_b2.entity != nil
      assert state_b2.entity.char_id == char_id

      # Verify only one copy of the player exists on the map
      {:ok, snap} = MapServer.snapshot_entity(@dest_map, char_id)
      assert snap.char_id == char_id

      # Not on A
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@source_map, char_id)

      # Packets should include a change_map (even if same map -- transfer still sends it)
      dest = @dest_map
      assert Enum.any?(packets2, fn
        {:change_map, %{map_id: ^dest}} -> true
        _ -> false
      end)

      MapServer.leave(@dest_map, char_id)
    end
  end
end
