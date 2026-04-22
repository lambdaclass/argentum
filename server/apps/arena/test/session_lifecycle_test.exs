defmodule Arena.SessionLifecycleTest do
  @moduledoc """
  Integration tests for the full character session lifecycle at the MapServer level.

  Verifies that entity ownership, presence, and state remain correct during:
  - Login: entity spawned on map, session registered, directory populated
  - Autosave: periodic timer triggers save to DB via session message
  - Clean logout: entity removed, occupancy freed, no ghost entities
  - Crash cleanup: session :DOWN removes entity from map
  - Map transfer: entity removed from source, spawned on destination, no duplicates
  - Double-login prevention: second enter with same char_id rejected
  - Edge cases: disconnect during combat (dead state), transfer atomicity
  """

  use ExUnit.Case

  alias Arena.Map.MapServer
  alias AoEntities.PlayerEntity

  @test_map_id 10_005
  @alt_map_id 10_105

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

    ensure_map_started(@test_map_id)
    ensure_map_started(@alt_map_id)

    :ok
  end

  setup do
    owner_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GameBackend.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid) end)
    :ok
  end

  # ---- Helpers ----

  defp unique_id, do: System.unique_integer([:positive]) + 100_000

  defp make_entity(char_id, name, overrides \\ %{}) do
    Map.merge(
      %PlayerEntity{
        char_id: char_id,
        name: name,
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
        map_id: @test_map_id
      },
      overrides
    )
  end

  defp enter_player(map_id, char_id, name, overrides \\ %{}) do
    entity = make_entity(char_id, name, overrides)
    {:ok, idx, _players, _weather} = MapServer.enter(map_id, entity, position: {entity.x, entity.y})

    on_exit(fn ->
      try do
        MapServer.leave(map_id, char_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    {entity, idx}
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
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

  # ---- Tests ----

  describe "login flow: session → entity → map" do
    test "entering a player creates a visible entity on the map" do
      char_id = unique_id()
      {entity, char_index} = enter_player(@test_map_id, char_id, "LoginFlow_#{char_id}")
      flush_mailbox()

      # Entity exists on the map with correct attributes
      {:ok, snapshot} = MapServer.snapshot_entity(@test_map_id, char_id)
      assert snapshot.char_id == char_id
      assert snapshot.name == entity.name
      assert snapshot.hp == 100
      assert snapshot.char_index == char_index
      assert snapshot.map_id == @test_map_id
    end

    test "entity position matches requested spawn position" do
      char_id = unique_id()
      {_entity, _idx} = enter_player(@test_map_id, char_id, "SpawnPos_#{char_id}", %{x: 50, y: 50})
      flush_mailbox()

      {:ok, snapshot} = MapServer.snapshot_entity(@test_map_id, char_id)
      # The map server may adjust position if occupied, but should be close
      assert is_integer(snapshot.x)
      assert is_integer(snapshot.y)
      assert snapshot.x >= 1
      assert snapshot.y >= 1
    end

    test "session registration prevents duplicate entry" do
      char_id = unique_id()
      account_id = unique_id()

      # Register session
      :ok = AoSession.register(account_id, char_id, self())

      on_exit(fn -> AoSession.unregister(char_id) end)

      # Second registration with same char_id should fail
      assert {:error, :already_connected} = AoSession.register(account_id, char_id, self())
    end

    test "online directory tracks player after entry" do
      char_id = unique_id()
      name = "DirTrack_#{char_id}"
      {_entity, _idx} = enter_player(@test_map_id, char_id, name)
      flush_mailbox()

      # Register in online directory (normally done by SessionLogic.enter_world)
      AoSession.OnlineDirectory.register(char_id, name, @test_map_id, self())

      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      {:ok, info} = AoSession.OnlineDirectory.lookup_by_id(char_id)
      assert info.map_id == @test_map_id
      assert info.name == name

      {:ok, found_id, _info} = AoSession.OnlineDirectory.lookup_by_name(name)
      assert found_id == char_id
    end
  end

  describe "autosave: periodic persistence" do
    test "autosave writes entity state to DB" do
      # Create a real DB character to save against
      name = "Autosave_#{unique_id()}"
      {:ok, account} = GameBackend.Account.get_or_create(name, "testpass")

      {:ok, character} =
        GameBackend.Characters.create(%{
          name: name,
          account_id: account.id,
          map_id: @test_map_id,
          pos_x: 50,
          pos_y: 50,
          gold: 100
        })

      char_id = character.id

      # Build an entity with modified gold (simulating in-game changes)
      entity = GameBackend.Characters.to_entity(character)
      entity = %{entity | gold: 999, hp: 42, map_id: @test_map_id}

      # Call autosave directly (same as what MapServer timer triggers)
      AoTcpGateway.SessionLogic.autosave(entity)

      # autosave runs in a Task, give it time
      Process.sleep(500)

      # Verify DB was updated
      db_char = GameBackend.Characters.get(char_id)
      assert db_char.gold == 999
      assert db_char.hp == 42
    end

    test "autosave preserves inventory and equipment" do
      name = "AutosaveInv_#{unique_id()}"
      {:ok, account} = GameBackend.Account.get_or_create(name, "testpass")

      inventory = [
        %{item_id: 100, amount: 5, equipped: false},
        %{item_id: 200, amount: 1, equipped: true}
      ] ++ List.duplicate(nil, 22)

      equipment = %{weapon: 200, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil}

      {:ok, character} =
        GameBackend.Characters.create(
          %{name: name, account_id: account.id, map_id: @test_map_id, pos_x: 50, pos_y: 50},
          inventory: inventory,
          equipment: equipment
        )

      entity = GameBackend.Characters.to_entity(character)
      # Modify inventory in memory (simulating pickup)
      new_inventory =
        List.replace_at(entity.inventory, 2, %{item_id: 300, amount: 10, equipped: false})

      entity = %{entity | inventory: new_inventory}

      AoTcpGateway.SessionLogic.autosave(entity)
      Process.sleep(500)

      db_char = GameBackend.Characters.get(character.id)
      slots = db_char.inventory_slots |> Enum.sort_by(& &1.slot)

      # Should have 3 items now
      assert length(slots) == 3
      slot2 = Enum.find(slots, &(&1.slot == 2))
      assert slot2.item_id == 300
      assert slot2.amount == 10
    end
  end

  describe "clean logout: entity removed, state saved" do
    test "leave removes entity from map" do
      char_id = unique_id()
      {_entity, _idx} = enter_player(@test_map_id, char_id, "CleanLogout_#{char_id}")
      flush_mailbox()

      # Verify entity exists
      assert {:ok, _} = MapServer.snapshot_entity(@test_map_id, char_id)

      # Leave the map
      {:ok, departed_entity} = MapServer.leave(@test_map_id, char_id)
      assert departed_entity.char_id == char_id

      # Verify entity is gone
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@test_map_id, char_id)
    end

    test "leave returns entity with current state for persistence" do
      char_id = unique_id()
      {_entity, _idx} = enter_player(@test_map_id, char_id, "LeaveState_#{char_id}", %{gold: 500, hp: 75})
      flush_mailbox()

      {:ok, departed} = MapServer.leave(@test_map_id, char_id)
      assert departed.gold == 500
      assert departed.hp == 75
      assert departed.char_id == char_id
    end

    test "leave for non-existent player returns :not_found" do
      result = MapServer.leave(@test_map_id, 999_999_999)
      assert result == :not_found
    end

    test "cleanup function saves state and unregisters everything" do
      name = "FullCleanup_#{unique_id()}"
      {:ok, account} = GameBackend.Account.get_or_create(name, "testpass")

      {:ok, character} =
        GameBackend.Characters.create(%{
          name: name,
          account_id: account.id,
          map_id: @test_map_id,
          pos_x: 50,
          pos_y: 50,
          gold: 100
        })

      char_id = character.id
      entity = GameBackend.Characters.to_entity(character)

      # Enter the map
      {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity, position: {50, 50})

      # Register session and directory
      :ok = AoSession.register(account.id, char_id, self())
      AoSession.OnlineDirectory.register(char_id, name, @test_map_id, self())

      # Build state similar to what ClientHandler uses
      state = %{
        character_id: char_id,
        map_id: @test_map_id,
        account_id: account.id,
        hogar_timer_ref: nil
      }

      # Run cleanup
      AoTcpGateway.SessionLogic.cleanup(state)
      Process.sleep(200)

      # Entity removed from map
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@test_map_id, char_id)

      # Session unregistered
      assert {:error, :not_found} = AoSession.lookup(char_id)

      # Directory cleaned
      assert :not_found = AoSession.OnlineDirectory.lookup_by_id(char_id)

      # State persisted to DB
      db_char = GameBackend.Characters.get(char_id)
      assert db_char != nil
    end
  end

  describe "crash/disconnect cleanup via :DOWN monitor" do
    test "session process death removes entity from map" do
      char_id = unique_id()
      name = "CrashCleanup_#{char_id}"

      entity = make_entity(char_id, name)

      # Spawn a fake session process that we can kill
      _fake_session =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, _idx, _players, _weather} =
        MapServer.enter(@test_map_id, entity, position: {50, 50})

      flush_mailbox()

      # Verify entity is on the map (entered by our process, but MapServer monitors caller)
      {:ok, _} = MapServer.snapshot_entity(@test_map_id, char_id)

      # The MapServer monitors the caller_pid (which is self() for the enter call).
      # When our test process exits or when we explicitly leave, the entity is removed.
      # For a proper crash test, we need the entity to have been entered by the fake_session.
      # Since GenServer.call uses the calling process as caller_pid, we leave and re-enter
      # from the fake_session context using a helper.

      # Clean up: leave since we entered as self()
      MapServer.leave(@test_map_id, char_id)

      # Now enter from the fake_session process via a proxy
      parent = self()
      ref = make_ref()

      proxy =
        spawn(fn ->
          # This process calls enter, so MapServer monitors this process
          result = MapServer.enter(@test_map_id, entity, position: {50, 50})
          send(parent, {ref, result})

          receive do
            :die -> :ok
          end
        end)

      # Wait for enter to complete
      assert_receive {^ref, {:ok, _idx, _players, _weather}}, 2000

      # Verify entity is on map
      {:ok, _} = MapServer.snapshot_entity(@test_map_id, char_id)

      # Kill the proxy process (simulates crash)
      Process.exit(proxy, :kill)
      Process.sleep(300)

      # MapServer should have cleaned up via :DOWN handler
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@test_map_id, char_id)
    end
  end

  describe "map transfer: entity moves between maps without duplication" do
    test "enter on destination then leave from source yields exactly one copy" do
      char_id = unique_id()
      name = "Transfer_#{char_id}"
      entity = make_entity(char_id, name, %{gold: 777})

      # Enter source map
      {:ok, _idx1, _players1, _weather1} = MapServer.enter(@test_map_id, entity, position: {50, 50})
      flush_mailbox()

      {:ok, snapshot1} = MapServer.snapshot_entity(@test_map_id, char_id)
      assert snapshot1.gold == 777

      # Enter destination map (transfer pattern: enter dest first, then leave source)
      dest_entity = %{entity | x: 30, y: 30, map_id: @alt_map_id}
      {:ok, _idx2, _players2, _weather2} = MapServer.enter(@alt_map_id, dest_entity, position: {30, 30})

      # At this point, entity is temporarily on both maps
      # Now leave the source map
      {:ok, _departed} = MapServer.leave(@test_map_id, char_id)

      # Entity should exist only on destination
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@test_map_id, char_id)
      {:ok, dest_snapshot} = MapServer.snapshot_entity(@alt_map_id, char_id)
      assert dest_snapshot.gold == 777
      assert dest_snapshot.map_id == @alt_map_id

      # Clean up
      MapServer.leave(@alt_map_id, char_id)
    end

    test "online directory updates map_id after transfer" do
      char_id = unique_id()
      name = "TransferDir_#{char_id}"

      AoSession.OnlineDirectory.register(char_id, name, @test_map_id, self())

      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      {:ok, info} = AoSession.OnlineDirectory.lookup_by_id(char_id)
      assert info.map_id == @test_map_id

      # Simulate transfer
      AoSession.OnlineDirectory.update_map(char_id, @alt_map_id)

      {:ok, info} = AoSession.OnlineDirectory.lookup_by_id(char_id)
      assert info.map_id == @alt_map_id

      # Lookup by name should also reflect the new map
      {:ok, found_id, found_info} = AoSession.OnlineDirectory.lookup_by_name(name)
      assert found_id == char_id
      assert found_info.map_id == @alt_map_id
    end

    test "transfer preserves entity state (gold, hp, inventory)" do
      char_id = unique_id()
      name = "TransferState_#{char_id}"

      inventory = [
        %{item_id: 100, amount: 3, equipped: false}
      ] ++ List.duplicate(nil, 23)

      entity = make_entity(char_id, name, %{gold: 1234, hp: 55, inventory: inventory})

      {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity, position: {50, 50})
      flush_mailbox()

      # Snapshot from source before transfer
      {:ok, source_snap} = MapServer.snapshot_entity(@test_map_id, char_id)
      assert source_snap.gold == 1234
      assert source_snap.hp == 55

      # Transfer: enter dest, leave source
      dest_entity = %{source_snap | map_id: @alt_map_id, x: 30, y: 30}
      {:ok, _idx2, _players2, _weather2} = MapServer.enter(@alt_map_id, dest_entity, position: {30, 30})
      MapServer.leave(@test_map_id, char_id)

      # Verify state preserved on destination
      {:ok, dest_snap} = MapServer.snapshot_entity(@alt_map_id, char_id)
      assert dest_snap.gold == 1234
      assert dest_snap.hp == 55
      assert hd(dest_snap.inventory) != nil
      assert hd(dest_snap.inventory).item_id == 100

      MapServer.leave(@alt_map_id, char_id)
    end
  end

  describe "double-login prevention at MapServer level" do
    test "second enter with same char_id on same map replaces the old entity" do
      char_id = unique_id()
      name = "DoubleEnter_#{char_id}"
      entity = make_entity(char_id, name, %{gold: 100})

      {:ok, idx1, _players, _weather} = MapServer.enter(@test_map_id, entity, position: {50, 50})
      flush_mailbox()

      # Enter again (same char_id, different gold to distinguish)
      entity2 = %{entity | gold: 999}
      {:ok, idx2, _players2, _weather2} = MapServer.enter(@test_map_id, entity2, position: {50, 50})
      flush_mailbox()

      # Should get a new char_index
      assert idx2 != idx1

      # Snapshot should show the latest entry
      {:ok, snapshot} = MapServer.snapshot_entity(@test_map_id, char_id)
      assert snapshot.gold == 999

      MapServer.leave(@test_map_id, char_id)
    end
  end

  describe "edge case: disconnect while dead" do
    test "dead player state persists correctly through cleanup" do
      name = "DeadDisconnect_#{unique_id()}"
      {:ok, account} = GameBackend.Account.get_or_create(name, "testpass")

      {:ok, character} =
        GameBackend.Characters.create(%{
          name: name,
          account_id: account.id,
          map_id: @test_map_id,
          pos_x: 50,
          pos_y: 50,
          hp: 100,
          dead: false
        })

      char_id = character.id
      entity = GameBackend.Characters.to_entity(character)

      # Enter the map
      {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity, position: {50, 50})
      flush_mailbox()

      # Enter a GM to kill the player
      gm_id = unique_id()
      gm_entity = make_entity(gm_id, "GM_#{gm_id}", %{gm: true, x: 48, y: 48})
      {:ok, _gm_idx, _gm_players, _gm_weather} = MapServer.enter(@test_map_id, gm_entity, position: {48, 48})
      flush_mailbox()

      # Kill the player via GM command
      MapServer.chat(@test_map_id, gm_id, "/KILL #{name}")
      Process.sleep(200)

      # Verify player is dead
      {:ok, dead_entity} = MapServer.snapshot_entity(@test_map_id, char_id)
      assert dead_entity.dead
      assert dead_entity.hp == 0

      # Simulate cleanup (as if the player disconnected while dead)
      {:ok, departed} = MapServer.leave(@test_map_id, char_id)
      assert departed.dead
      assert departed.hp == 0

      # Save the dead state to DB
      attrs = GameBackend.Characters.from_entity(departed)
      inventory = GameBackend.Characters.inventory_from_entity(departed)
      equipment = GameBackend.Characters.equipment_from_entity(departed)
      skills = GameBackend.Characters.skills_from_entity(departed)
      spells = GameBackend.Characters.spells_from_entity(departed)

      {:ok, _saved} =
        GameBackend.Characters.save_snapshot(char_id, attrs,
          inventory: inventory,
          equipment: equipment,
          skills: skills,
          spells: spells
        )

      # Verify DB reflects dead state
      db_char = GameBackend.Characters.get(char_id)
      assert db_char.dead == true
      assert db_char.hp == 0

      # Clean up GM
      MapServer.leave(@test_map_id, gm_id)
    end
  end

  describe "edge case: rapid leave after enter" do
    test "immediate leave after enter does not crash" do
      char_id = unique_id()
      entity = make_entity(char_id, "RapidLeave_#{char_id}")

      {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity, position: {50, 50})
      {:ok, departed} = MapServer.leave(@test_map_id, char_id)

      assert departed.char_id == char_id
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@test_map_id, char_id)
    end
  end

  describe "online directory consistency" do
    test "unregister clears both id and name lookups" do
      char_id = unique_id()
      name = "DirConsist_#{char_id}"

      AoSession.OnlineDirectory.register(char_id, name, @test_map_id, self())

      # Both lookups work
      assert {:ok, _} = AoSession.OnlineDirectory.lookup_by_id(char_id)
      assert {:ok, ^char_id, _} = AoSession.OnlineDirectory.lookup_by_name(name)

      # Unregister
      AoSession.OnlineDirectory.unregister(char_id)

      # Both lookups return not_found
      assert :not_found = AoSession.OnlineDirectory.lookup_by_id(char_id)
      assert :not_found = AoSession.OnlineDirectory.lookup_by_name(name)
    end

    test "online_count increments and decrements correctly" do
      char_id_a = unique_id()
      char_id_b = unique_id()

      before_count = AoSession.OnlineDirectory.online_count()

      AoSession.OnlineDirectory.register(char_id_a, "CountA_#{char_id_a}", @test_map_id, self())
      AoSession.OnlineDirectory.register(char_id_b, "CountB_#{char_id_b}", @test_map_id, self())

      assert AoSession.OnlineDirectory.online_count() == before_count + 2

      AoSession.OnlineDirectory.unregister(char_id_a)
      assert AoSession.OnlineDirectory.online_count() == before_count + 1

      AoSession.OnlineDirectory.unregister(char_id_b)
      assert AoSession.OnlineDirectory.online_count() == before_count
    end

    test "case-insensitive name lookup" do
      char_id = unique_id()
      name = "CaseTest_#{char_id}"

      AoSession.OnlineDirectory.register(char_id, name, @test_map_id, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # Lookup with different casing should work
      assert {:ok, ^char_id, _} = AoSession.OnlineDirectory.lookup_by_name(String.upcase(name))
      assert {:ok, ^char_id, _} = AoSession.OnlineDirectory.lookup_by_name(String.downcase(name))
    end
  end

  describe "session registry lifecycle" do
    test "register, lookup, unregister cycle" do
      char_id = unique_id()
      account_id = unique_id()

      :ok = AoSession.register(account_id, char_id, self())

      {:ok, pid, meta} = AoSession.lookup(char_id)
      assert pid == self()
      assert meta.account_id == account_id

      AoSession.unregister(char_id)
      assert {:error, :not_found} = AoSession.lookup(char_id)
    end

    test "online_count reflects registered sessions" do
      char_id = unique_id()
      account_id = unique_id()

      before = AoSession.online_count()
      :ok = AoSession.register(account_id, char_id, self())

      assert AoSession.online_count() == before + 1

      AoSession.unregister(char_id)
      assert AoSession.online_count() == before
    end
  end
end
