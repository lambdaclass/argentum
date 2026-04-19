defmodule Arena.LifecycleExtendedTest do
  @moduledoc """
  Extended lifecycle tests — ROADMAP item #28.

  Covers gaps not exercised by the base lifecycle/autosave/transfer suites:
    - Autosave timing (coalescing under rapid state changes, concurrent flush)
    - Multi-map transfer chains (A→B→C with state mutations between hops)
    - Cleanup DB failure (final save fails, cleanup still completes)
    - Flush timeout (slow DB behaviour)
    - Worker crash and start failure (GenServer survives, next submit works)
    - Stale autosave ordering (latest-wins semantics)
    - Graceful-disconnect final-save failure (entity still removed, session unregistered)
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AoTcpGateway.AutosaveWriter
  alias AoTcpGateway.SessionPersistence
  alias AoTcpGateway.SessionTransfer
  alias Arena.Map.MapServer
  alias AoEntities.PlayerEntity

  @map_a 1
  @map_b 2
  @map_c 3

  # -------------------------------------------------------------------
  # Setup
  # -------------------------------------------------------------------

  setup_all do
    Application.ensure_all_started(:phoenix_pubsub)

    start_if_needed(Arena.MapRegistry, fn ->
      Registry.start_link(keys: :unique, name: Arena.MapRegistry)
    end)

    start_if_needed(Arena.PubSub, fn ->
      Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end)

    start_if_needed(Arena.Data.GameData, fn ->
      Arena.Data.GameData.start_link([])
    end)

    start_if_needed(Arena.Map.MapSupervisor, fn ->
      Arena.Map.MapSupervisor.start_link([])
    end)

    start_if_needed(AoSession.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: AoSession.SessionRegistry)
    end)

    start_if_needed(AoSession.OnlineDirectory, fn ->
      AoSession.OnlineDirectory.start_link()
    end)

    ensure_map_started(@map_a)
    ensure_map_started(@map_b)
    ensure_map_started(@map_c)

    :ok
  end

  setup do
    owner_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GameBackend.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid) end)
    :ok
  end

  # ===================================================================
  # Autosave timing
  # ===================================================================

  describe "autosave timing: coalescing under rapid state changes" do
    test "multiple rapid submits before flush — only final state persists" do
      {char_id, entity} = create_test_character("ExtCoal_#{uid()}")
      on_exit(fn -> cleanup_char(char_id) end)

      test_pid = self()
      handler_id = "ext_coal_#{uid()}"
      coalesce_count = :counters.new(1, [:atomics])

      :telemetry.attach(
        handler_id,
        [:arena, :persistence, :autosave],
        fn _event, _measurements, metadata, _config ->
          if metadata.char_id == char_id and metadata.event == :coalesced do
            :counters.add(coalesce_count, 1, 1)
          end

          if metadata.char_id == char_id and metadata.event in [:ok, :error] do
            send(test_pid, {:write_done, metadata.event})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Submit 20 rapid state changes — first starts write, rest coalesce
      for i <- 1..20 do
        AutosaveWriter.submit(%{entity | gold: i * 100, hp: 50 + i})
      end

      assert :ok == AutosaveWriter.flush(char_id)

      saved = GameBackend.Characters.get(char_id)
      assert saved.gold == 2000
      assert saved.hp == 70

      # At least some coalesces should have happened
      assert :counters.get(coalesce_count, 1) > 0
    end

    test "concurrent flush from different processes both return :ok" do
      {char_id, entity} = create_test_character("ExtConcFlush_#{uid()}")
      on_exit(fn -> cleanup_char(char_id) end)

      AutosaveWriter.submit(%{entity | gold: 4321})

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> AutosaveWriter.flush(char_id) end)
        end

      results = Task.await_many(tasks, 10_000)

      # All flushes must succeed
      assert Enum.all?(results, &(&1 == :ok))

      saved = GameBackend.Characters.get(char_id)
      assert saved.gold == 4321
    end
  end

  # ===================================================================
  # Multi-map transfer chains
  # ===================================================================

  describe "multi-map transfer chains" do
    test "three-map chain A→B→C — entity on C only, cleared from A and B" do
      char_id = uid()
      entity = make_entity(char_id, "Chain3_#{char_id}", %{gold: 500})
      state = make_transfer_state(char_id, @map_a)

      {:ok, idx, _players, _weather} = MapServer.enter(@map_a, entity, position: {50, 50})
      flush_mailbox()
      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @map_a, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # Transfer A → B
      {state_b, _pkts1} = SessionTransfer.transfer(state, @map_b, 30, 30, entity)
      flush_mailbox()
      assert state_b.map_id == @map_b

      # Transfer B → C  (use updated entity from B)
      {:ok, entity_b} = MapServer.snapshot_entity(@map_b, char_id)
      {state_c, _pkts2} = SessionTransfer.transfer(state_b, @map_c, 40, 40, entity_b)
      flush_mailbox()
      assert state_c.map_id == @map_c

      # Entity present only on C
      assert {:ok, snap_c} = MapServer.snapshot_entity(@map_c, char_id)
      assert snap_c.char_id == char_id
      assert snap_c.gold == 500

      # Cleared from A and B
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_a, char_id)
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_b, char_id)

      MapServer.leave(@map_c, char_id)
    end

    test "transfer chain with entity state changes between hops" do
      char_id = uid()
      # Start with gold=100, hp=80
      entity = make_entity(char_id, "ChainMut_#{char_id}", %{gold: 100, hp: 80})
      state = make_transfer_state(char_id, @map_a)

      {:ok, idx, _players, _weather} = MapServer.enter(@map_a, entity, position: {50, 50})
      flush_mailbox()
      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @map_a, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # Transfer A → B carrying a modified gold value (simulates picking up gold before warp)
      entity_with_gold = %{entity | gold: 999}
      {state_b, _pkts1} = SessionTransfer.transfer(state, @map_b, 30, 30, entity_with_gold)
      flush_mailbox()

      {:ok, snap_b} = MapServer.snapshot_entity(@map_b, char_id)
      assert snap_b.gold == 999

      # Transfer B → C carrying a modified HP value (simulates damage between hops)
      entity_with_hp = %{snap_b | hp: 25}
      {_state_c, _pkts2} = SessionTransfer.transfer(state_b, @map_c, 40, 40, entity_with_hp)
      flush_mailbox()

      {:ok, snap_c} = MapServer.snapshot_entity(@map_c, char_id)
      # Both mutations should have carried through the chain
      assert snap_c.gold == 999
      assert snap_c.hp == 25

      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_a, char_id)
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_b, char_id)

      MapServer.leave(@map_c, char_id)
    end

    test "back-to-back rapid transfers without reading intermediate snapshot" do
      char_id = uid()
      entity = make_entity(char_id, "RapidChain_#{char_id}", %{gold: 42})
      state = make_transfer_state(char_id, @map_a)

      {:ok, idx, _players, _weather} = MapServer.enter(@map_a, entity, position: {50, 50})
      flush_mailbox()
      state = %{state | char_index: idx}

      AoSession.OnlineDirectory.register(char_id, entity.name, @map_a, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(char_id) end)

      # Rapid: A → B → C with the original entity (stale) for each hop
      {state_b, _} = SessionTransfer.transfer(state, @map_b, 30, 30, entity)
      flush_mailbox()
      {state_c, _} = SessionTransfer.transfer(state_b, @map_c, 40, 40, entity)
      flush_mailbox()

      assert state_c.map_id == @map_c
      assert {:ok, _} = MapServer.snapshot_entity(@map_c, char_id)
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_a, char_id)
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_b, char_id)

      MapServer.leave(@map_c, char_id)
    end
  end

  # ===================================================================
  # Cleanup DB failure
  # ===================================================================

  describe "cleanup DB failure" do
    test "graceful disconnect where final save fails — cleanup still completes" do
      {char_id, entity} = create_test_character("ExtCleanFail_#{uid()}")

      # Enter the map so MapServer.leave returns {:ok, entity}
      MapServer.enter(@map_a, entity, position: {50, 50})
      flush_mailbox()

      # Register session and directory so cleanup has something to tear down
      account_id = uid()
      :ok = AoSession.register(account_id, char_id, self())
      AoSession.OnlineDirectory.register(char_id, entity.name, @map_a, self())

      # Delete character from DB so save_snapshot will fail with :not_found
      character = GameBackend.Characters.get(char_id)
      GameBackend.Repo.delete(character)

      test_pid = self()
      handler_id = "ext_cleanup_fail_#{uid()}"

      :telemetry.attach(
        handler_id,
        [:arena, :persistence, :cleanup_save_failed],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:cleanup_save_failed, metadata.char_id})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        # Safety net for leftover registrations
        AoSession.OnlineDirectory.unregister(char_id)
        AoSession.unregister(char_id)
      end)

      fake_state = %{character_id: char_id, map_id: @map_a}

      log =
        capture_log(fn ->
          assert :ok == SessionPersistence.cleanup(fake_state)
        end)

      assert log =~ "Final save failed for char #{char_id}"
      assert_received {:cleanup_save_failed, ^char_id}

      # Entity removed from map even though save failed
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_a, char_id)

      # Session unregistered
      assert {:error, :not_found} = AoSession.lookup(char_id)

      # Online directory cleaned
      assert :not_found = AoSession.OnlineDirectory.lookup_by_id(char_id)
    end

    test "session crash with pending autosave writes — no stale data left behind" do
      {char_id, entity} = create_test_character("ExtStaleClean_#{uid()}")
      on_exit(fn -> cleanup_char(char_id) end)

      # Submit autosave with modified state
      AutosaveWriter.submit(%{entity | gold: 7777})

      # Immediately flush (simulates crash cleanup draining pending writes)
      assert :ok == AutosaveWriter.flush(char_id)

      saved = GameBackend.Characters.get(char_id)
      assert saved.gold == 7777

      # Now do cleanup — should not leave stale autosave data
      MapServer.enter(@map_a, %{entity | gold: 7777}, position: {50, 50})
      flush_mailbox()

      fake_state = %{character_id: char_id, map_id: @map_a}
      assert :ok == SessionPersistence.cleanup(fake_state)

      # Verify no pending autosave writes remain for this char_id
      writer_state = :sys.get_state(AutosaveWriter)
      refute Map.has_key?(writer_state.pending, char_id)
      refute Map.has_key?(writer_state.in_flight, char_id)
    end
  end

  # ===================================================================
  # Flush timeout
  # ===================================================================

  describe "flush timeout" do
    test "flush with GenServer call timeout exits" do
      # Create a character so cleanup_char works
      {char_id, _entity} = create_test_character("ExtFlushTO_#{uid()}")
      on_exit(fn -> cleanup_char(char_id) end)

      # Inject fake in-flight state that will never resolve
      # This simulates a slow/stuck DB write
      fake_ref = make_ref()

      :sys.replace_state(AutosaveWriter, fn state ->
        %{
          state
          | in_flight: Map.put(state.in_flight, char_id, true),
            task_monitors: Map.put(state.task_monitors, fake_ref, char_id)
        }
      end)

      # Flush with a tiny timeout — GenServer.call exits on timeout
      assert catch_exit(AutosaveWriter.flush(char_id, 1)) != nil

      # Clean up injected state so it does not leak into other tests
      :sys.replace_state(AutosaveWriter, fn state ->
        %{
          state
          | in_flight: Map.delete(state.in_flight, char_id),
            task_monitors: Map.delete(state.task_monitors, fake_ref),
            flush_waiters: Map.delete(state.flush_waiters, char_id)
        }
      end)
    end
  end

  # ===================================================================
  # Worker crash and start failure
  # ===================================================================

  describe "worker crash — GenServer survives and next submit works" do
    test "worker crash during write does not kill AutosaveWriter" do
      {char_id, entity} = create_test_character("ExtWorkerCrash_#{uid()}")
      on_exit(fn -> cleanup_char(char_id) end)

      fake_ref = make_ref()

      # Inject an in-flight entry for a doomed worker
      :sys.replace_state(AutosaveWriter, fn state ->
        %{
          state
          | in_flight: Map.put(state.in_flight, char_id, true),
            task_monitors: Map.put(state.task_monitors, fake_ref, char_id)
        }
      end)

      # Simulate worker crash with synthetic DOWN
      send(Process.whereis(AutosaveWriter), {:DOWN, fake_ref, :process, self(), :killed})
      Process.sleep(50)

      # GenServer should still be alive
      assert Process.alive?(Process.whereis(AutosaveWriter))

      # Next submit+flush should work fine
      AutosaveWriter.submit(%{entity | gold: 1234})
      assert :ok == AutosaveWriter.flush(char_id)

      saved = GameBackend.Characters.get(char_id)
      assert saved.gold == 1234
    end

    test "worker crash with pending snapshot retries and persists" do
      {char_id, entity} = create_test_character("ExtRetry_#{uid()}")
      on_exit(fn -> cleanup_char(char_id) end)

      fake_ref = make_ref()
      snapshot = AutosaveWriter.snapshot_from_entity(%{entity | gold: 8888})

      # Inject: in-flight + pending snapshot
      :sys.replace_state(AutosaveWriter, fn state ->
        %{
          state
          | in_flight: Map.put(state.in_flight, char_id, true),
            task_monitors: Map.put(state.task_monitors, fake_ref, char_id),
            pending: Map.put(state.pending, char_id, snapshot)
        }
      end)

      # Worker dies — DOWN handler should retry the pending snapshot
      send(Process.whereis(AutosaveWriter), {:DOWN, fake_ref, :process, self(), :killed})

      assert :ok == AutosaveWriter.flush(char_id)

      saved = GameBackend.Characters.get(char_id)
      assert saved.gold == 8888
    end
  end

  # ===================================================================
  # Stale autosave ordering
  # ===================================================================

  describe "stale autosave ordering — latest-wins" do
    test "submit old then new — new state persists" do
      {char_id, entity} = create_test_character("ExtOrder_#{uid()}")
      on_exit(fn -> cleanup_char(char_id) end)

      old_entity = %{entity | gold: 10, level: 1}
      new_entity = %{entity | gold: 9999, level: 50}

      # Submit old, then new — the writer coalesces to the latest-submitted
      AutosaveWriter.submit(old_entity)
      AutosaveWriter.submit(new_entity)
      assert :ok == AutosaveWriter.flush(char_id)

      saved = GameBackend.Characters.get(char_id)
      assert saved.gold == 9999
      assert saved.level == 50
    end

    test "submit new first, sleep to let it start, then submit old — old overwrites (caller ordering)" do
      # This tests the writer's documented behaviour: it keeps the
      # most recently submitted snapshot, not the one with "newer" data.
      # Callers are responsible for ordering.
      {char_id, entity} = create_test_character("ExtOrderRev_#{uid()}")
      on_exit(fn -> cleanup_char(char_id) end)

      new_entity = %{entity | gold: 9999, level: 50}
      old_entity = %{entity | gold: 10, level: 1}

      # Submit new first, let write start
      AutosaveWriter.submit(new_entity)
      Process.sleep(50)

      # Now submit old — it coalesces into pending and will be written last
      AutosaveWriter.submit(old_entity)
      assert :ok == AutosaveWriter.flush(char_id)

      saved = GameBackend.Characters.get(char_id)
      # The "old" entity was submitted last, so it wins
      assert saved.gold == 10
      assert saved.level == 1
    end
  end

  # ===================================================================
  # Graceful-disconnect final-save failure
  # ===================================================================

  describe "graceful-disconnect final-save failure" do
    test "save_snapshot failure still removes entity from map and unregisters session" do
      {char_id, entity} = create_test_character("ExtDiscoFail_#{uid()}")

      # Enter map
      MapServer.enter(@map_a, entity, position: {50, 50})
      flush_mailbox()

      # Register session and directory
      account_id = uid()
      :ok = AoSession.register(account_id, char_id, self())
      AoSession.OnlineDirectory.register(char_id, entity.name, @map_a, self())

      # Delete the DB record so save_snapshot raises/returns error
      character = GameBackend.Characters.get(char_id)
      GameBackend.Repo.delete(character)

      test_pid = self()
      handler_id = "ext_disco_fail_#{uid()}"

      :telemetry.attach(
        handler_id,
        [:arena, :persistence, :cleanup_save_failed],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:disco_save_failed, metadata.char_id})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        AoSession.OnlineDirectory.unregister(char_id)
        AoSession.unregister(char_id)
      end)

      fake_state = %{character_id: char_id, map_id: @map_a}

      log =
        capture_log(fn ->
          assert :ok == SessionPersistence.cleanup(fake_state)
        end)

      assert log =~ "Final save failed"
      assert_received {:disco_save_failed, ^char_id}

      # Entity removed from map
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_a, char_id)

      # Session unregistered
      assert {:error, :not_found} = AoSession.lookup(char_id)

      # Online directory cleaned
      assert :not_found = AoSession.OnlineDirectory.lookup_by_id(char_id)
    end

    test "cleanup where save_snapshot raises still completes teardown" do
      {char_id, entity} = create_test_character("ExtRaiseFail_#{uid()}")

      # Enter map
      MapServer.enter(@map_a, entity, position: {50, 50})
      flush_mailbox()

      # Register session and directory
      account_id = uid()
      :ok = AoSession.register(account_id, char_id, self())
      AoSession.OnlineDirectory.register(char_id, entity.name, @map_a, self())

      # Delete character from DB — save_snapshot will fail
      character = GameBackend.Characters.get(char_id)
      GameBackend.Repo.delete(character)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(char_id)
        AoSession.unregister(char_id)
      end)

      fake_state = %{character_id: char_id, map_id: @map_a}

      # cleanup must return :ok even when save fails
      log =
        capture_log(fn ->
          result = SessionPersistence.cleanup(fake_state)
          assert result == :ok
        end)

      assert log =~ "Final save failed"

      # All teardown must have completed despite the save failure
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_a, char_id)
      assert {:error, :not_found} = AoSession.lookup(char_id)
      assert :not_found = AoSession.OnlineDirectory.lookup_by_id(char_id)
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp uid, do: System.unique_integer([:positive]) + 300_000

  defp make_entity(char_id, name, overrides) do
    Map.merge(
      %PlayerEntity{
        char_id: char_id,
        name: name,
        account_id: uid(),
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
        map_id: @map_a
      },
      overrides
    )
  end

  defp make_transfer_state(char_id, map_id) do
    %{
      character_id: char_id,
      map_id: map_id,
      account_id: uid(),
      entity: nil,
      char_index: 1,
      target_x: nil,
      target_y: nil,
      hogar_timer_ref: nil
    }
  end

  defp create_test_character(name) do
    account = ensure_test_account()

    {:ok, char} =
      GameBackend.Characters.create(%{
        name: name,
        account_id: account.id,
        race: "humano",
        class: "guerrero",
        gender: "male",
        home_city: "ullathorpe",
        head_id: 1,
        body_id: 1,
        pos_x: 50,
        pos_y: 50,
        map_id: 1,
        heading: "south",
        hp: 100,
        max_hp: 100,
        mana: 50,
        max_mana: 50,
        stamina: 100,
        max_stamina: 100,
        hunger: 100,
        thirst: 100,
        level: 1,
        xp: 0,
        gold: 0,
        str: 18,
        agi: 18,
        int: 18,
        con: 18,
        cha: 18,
        skill_points: 0,
        dead: false,
        criminal: false,
        penalty: 0,
        fishing_points: 0,
        faction: "none",
        npcs_killed: 0,
        deaths: 0,
        citizens_killed: 0,
        criminals_killed: 0,
        faction_kills_royal: 0,
        faction_kills_chaos: 0,
        faction_score: 0,
        faction_rank_armada: 0,
        faction_rank_chaos: 0,
        faction_reenlistadas: 0
      })

    entity = GameBackend.Characters.to_entity(char)
    {char.id, entity}
  end

  defp ensure_test_account do
    name = "ext_lifecycle_#{uid()}"
    {:ok, account} = GameBackend.Account.create(name, "test_password")
    account
  end

  defp cleanup_char(char_id) do
    try do
      MapServer.leave(@map_a, char_id)
    catch
      :exit, _ -> :ok
    end

    try do
      MapServer.leave(@map_b, char_id)
    catch
      :exit, _ -> :ok
    end

    try do
      MapServer.leave(@map_c, char_id)
    catch
      :exit, _ -> :ok
    end

    AoSession.OnlineDirectory.unregister(char_id)
    AoSession.unregister(char_id)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
  end

  defp start_if_needed(name, start_fun) do
    case Process.whereis(name) do
      nil -> start_fun.()
      _pid -> :ok
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
end
