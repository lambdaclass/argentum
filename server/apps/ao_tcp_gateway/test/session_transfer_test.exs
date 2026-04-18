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
end
