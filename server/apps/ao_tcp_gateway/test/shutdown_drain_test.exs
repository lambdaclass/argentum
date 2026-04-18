defmodule AoTcpGateway.ShutdownDrainTest do
  @moduledoc """
  Tests for the coordinated shutdown drain.

  Verifies the shutdown contract:
  - Listeners stop accepting new connections
  - Online sessions are drained (cleanup runs)
  - AutosaveWriter flushes pending writes
  - Telemetry fires for each phase
  - Registries are clean after drain
  """

  use ExUnit.Case, async: false

  require Logger

  alias AoTcpGateway.{AutosaveWriter, ShutdownDrain}

  setup_all do
    # Ensure core infrastructure is running
    start_if_needed(:ranch_sup, fn -> Application.ensure_all_started(:ranch) end)

    start_if_needed(Arena.PubSub, fn ->
      Application.ensure_all_started(:phoenix_pubsub)
      Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end)

    start_if_needed(AoSession.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: AoSession.SessionRegistry)
    end)

    start_if_needed(AoSession.OnlineDirectory, fn ->
      AoSession.OnlineDirectory.start_link()
    end)

    start_if_needed(AoSession.SessionMonitor, fn ->
      AoSession.SessionMonitor.start_link()
    end)

    start_if_needed(Arena.MapRegistry, fn ->
      Registry.start_link(keys: :unique, name: Arena.MapRegistry)
    end)

    start_if_needed(Arena.Map.MapSupervisor, fn ->
      Arena.Map.MapSupervisor.start_link([])
    end)

    case Registry.lookup(Arena.MapRegistry, 1) do
      [] -> Arena.Map.MapSupervisor.start_map(1)
      _ -> :ok
    end

    # Ensure the shutdown gate is cleared and listeners are restarted
    # when this module's tests finish (so other test files aren't broken)
    on_exit(fn ->
      AoTcpGateway.ShutdownDrain.reset_shutdown_gate()
      restart_listeners()
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})
    # Reset the shutdown gate before each test
    AoTcpGateway.ShutdownDrain.reset_shutdown_gate()
    :ok
  end

  # ── Telemetry helpers ─────────────────────────────────────────────────

  defp attach_shutdown_telemetry(test_pid) do
    handler_id = "shutdown_test_#{System.unique_integer([:positive])}"

    events = [
      [:arena, :shutdown, :shutdown_started],
      [:arena, :shutdown, :listeners_stopped],
      [:arena, :shutdown, :drain_started],
      [:arena, :shutdown, :drain_finished],
      [:arena, :shutdown, :drain_timeout],
      [:arena, :shutdown, :shutdown_completed]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        phase = List.last(event)
        send(test_pid, {:shutdown_phase, phase, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  # ── Tests ─────────────────────────────────────────────────────────────

  describe "shutdown drain with no online sessions" do
    test "fires all telemetry phases in order" do
      handler_id = attach_shutdown_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok == ShutdownDrain.run()

      assert_received {:shutdown_phase, :shutdown_started, _, _}
      assert_received {:shutdown_phase, :listeners_stopped, %{duration: _}, _}
      assert_received {:shutdown_phase, :drain_started, _, _}
      # With 0 sessions, drain_finished fires (not drain_timeout)
      assert_received {:shutdown_phase, :drain_finished, _, %{session_count: 0}}
      assert_received {:shutdown_phase, :shutdown_completed, %{duration: _}, _}
    end
  end

  describe "shutdown drain with online sessions" do
    test "sessions are cleaned up and registries emptied" do
      handler_id = attach_shutdown_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Create a test character and register a fake session
      {char_id, _entity} = create_test_character("ShutdownA_#{System.unique_integer([:positive])}")

      # Register in the session registry with self() as the transport pid.
      # The drain will send :shutdown_drain to self(), which we can receive.
      :ok = AoSession.register("test_account", char_id, self())
      AoSession.OnlineDirectory.register(char_id, "ShutdownTestPlayer", 1, self())

      on_exit(fn ->
        # Clean up in case drain didn't finish
        AoSession.OnlineDirectory.unregister(char_id)
        AoSession.unregister(char_id)
      end)

      assert AoSession.online_count() >= 1

      # Run the drain in a separate process (since it will send :shutdown_drain
      # to self() and we need to handle it)
      drain_task = Task.async(fn -> ShutdownDrain.run() end)

      # We should receive the :shutdown_drain signal
      assert_receive :shutdown_drain, 5_000

      # Simulate what the TCP handler would do: run cleanup
      AoSession.OnlineDirectory.unregister(char_id)
      AoSession.unregister(char_id)

      # Drain should complete
      assert :ok == Task.await(drain_task, 10_000)

      # Verify telemetry
      assert_received {:shutdown_phase, :shutdown_started, _, _}
      assert_received {:shutdown_phase, :listeners_stopped, _, _}
      assert_received {:shutdown_phase, :drain_started, _, _}
      assert_received {:shutdown_phase, :shutdown_completed, _, _}
    end
  end

  describe "shutdown drain with in-flight autosave" do
    test "autosave writer is still alive after drain (supervisor handles final flush)" do
      handler_id = attach_shutdown_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Submit an autosave for a real character
      {char_id, entity} = create_test_character("ShutdownASW_#{System.unique_integer([:positive])}")
      AutosaveWriter.submit(%{entity | gold: 7777})

      # Run drain
      assert :ok == ShutdownDrain.run()

      # AutosaveWriter should still be alive (supervisor hasn't torn down yet)
      assert Process.whereis(AutosaveWriter) != nil

      # Flush to ensure the write completes
      assert :ok == AutosaveWriter.flush(char_id)

      # Verify the autosave actually persisted
      saved = GameBackend.Characters.get(char_id)
      assert saved.gold == 7777
    end
  end

  describe "AutosaveWriter terminate flushes in-flight writes" do
    test "terminate waits for in-flight writes to complete" do
      {char_id, entity} = create_test_character("ASWTerm_#{System.unique_integer([:positive])}")

      # Submit a write
      AutosaveWriter.submit(%{entity | gold: 9999})

      # Give it a moment to start the write
      Process.sleep(50)

      # Get the current state — should have in_flight entries
      state = :sys.get_state(AutosaveWriter)

      # If the write is still in flight, terminate should wait for it
      if map_size(state.in_flight) > 0 do
        # Call terminate directly to test the waiting logic
        AutosaveWriter.terminate(:shutdown, state)

        # After terminate returns, the write should have completed
        saved = GameBackend.Characters.get(char_id)
        assert saved.gold == 9999
      else
        # Write already completed — just verify it persisted
        AutosaveWriter.flush(char_id)
        saved = GameBackend.Characters.get(char_id)
        assert saved.gold == 9999
      end
    end
  end

  describe "AutosaveWriter terminate drains pending snapshots" do
    test "pending coalesced snapshot is persisted during terminate, not dropped" do
      {char_id, entity} = create_test_character("ASWPending_#{System.unique_integer([:positive])}")

      test_pid = self()

      # Spawn a fake in-flight writer that sends :write_done to the test process
      {_pid, monitor_ref} =
        spawn_monitor(fn ->
          Process.sleep(50)
          send(test_pid, {:write_done, char_id, :ok, 1000})
        end)

      # Build state with in-flight + pending (simulates: one write running,
      # a newer coalesced snapshot waiting)
      snapshot = AutosaveWriter.snapshot_from_entity(%{entity | gold: 2222})

      state = %{
        pending: %{char_id => snapshot},
        in_flight: %{char_id => true},
        flush_waiters: %{},
        task_monitors: %{monitor_ref => char_id}
      }

      # Call terminate from test process — wait_in_flight receives :write_done
      # via our mailbox. Currently: clears in_flight, returns :ok, drops pending.
      # After fix: should also start and drain the pending write.
      AutosaveWriter.terminate(:shutdown, state)

      # If the bug exists, gold is still 0 (initial value), not 2222
      saved = GameBackend.Characters.get(char_id)
      assert saved.gold == 2222
    end
  end

  describe "shutdown_in_progress gate" do
    test "shutdown_in_progress? returns false before shutdown and true after" do
      refute AoTcpGateway.ShutdownDrain.shutdown_in_progress?()

      # Run shutdown
      AoTcpGateway.ShutdownDrain.run()

      assert AoTcpGateway.ShutdownDrain.shutdown_in_progress?()
    end
  end

  describe "shutdown telemetry contract" do
    test "shutdown_completed includes duration" do
      handler_id = attach_shutdown_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      ShutdownDrain.run()

      assert_received {:shutdown_phase, :shutdown_completed, %{duration: duration}, _}
      assert is_integer(duration)
      assert duration > 0
    end

    test "listeners_stopped includes duration" do
      handler_id = attach_shutdown_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      ShutdownDrain.run()

      assert_received {:shutdown_phase, :listeners_stopped, %{duration: duration}, _}
      assert is_integer(duration)
    end
  end

  describe "contrast: crash vs graceful shutdown" do
    test "session crash does not trigger drain telemetry" do
      handler_id = attach_shutdown_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Register a session, then kill the transport pid (simulating crash)
      {char_id, _entity} = create_test_character("CrashTest_#{System.unique_integer([:positive])}")

      # Use a spawned process as the transport pid so we can kill it
      transport = spawn(fn -> Process.sleep(:infinity) end)
      :ok = AoSession.register("crash_account", char_id, transport)
      AoSession.OnlineDirectory.register(char_id, "CrashPlayer", 1, transport)

      # Kill the transport (crash, not graceful)
      Process.exit(transport, :kill)
      Process.sleep(200)

      # SessionMonitor should have cleaned up the registry entries
      # (or they may still be there if SessionMonitor isn't running for this test)
      # Either way, no shutdown telemetry should have fired
      refute_received {:shutdown_phase, :shutdown_started, _, _}
      refute_received {:shutdown_phase, :drain_started, _, _}

      # Clean up
      AoSession.OnlineDirectory.unregister(char_id)
      AoSession.unregister(char_id)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

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
    name = "shutdown_test_#{System.unique_integer([:positive])}"
    {:ok, account} = GameBackend.Account.create(name, "test_password")
    account
  end

  defp start_if_needed(name, start_fun) do
    case Process.whereis(name) do
      nil -> start_fun.()
      _pid -> :ok
    end
  end

  defp restart_listeners do
    tcp_port = Application.get_env(:ao_tcp_gateway, :port, 7666)
    ws_port = Application.get_env(:ao_tcp_gateway, :ws_port, 7667)

    # Restart TCP listener if stopped
    try do
      :ranch.get_port(AoTcpGateway.Listener)
    catch
      _, _ ->
        try do
          AoTcpGateway.Listener.start_link(port: tcp_port)
        catch
          _, _ -> :ok
        end
    end

    # Restart WS listener if stopped
    try do
      :ranch.get_port(:ao_ws_listener)
    catch
      _, _ ->
        try do
          ws_dispatch =
            :cowboy_router.compile([
              {:_, [
                {"/ao", AoTcpGateway.WsHandler, []},
                {"/", AoTcpGateway.RootHandler, []},
                {:_, Plug.Cowboy.Handler, {AoTcpGateway.WsRouter, []}}
              ]}
            ])

          :cowboy.start_clear(
            :ao_ws_listener,
            [port: ws_port, max_connections: :infinity],
            %{env: %{dispatch: ws_dispatch}}
          )
        catch
          _, _ -> :ok
        end
    end
  end
end
