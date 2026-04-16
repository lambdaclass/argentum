defmodule AoSession.SessionMonitorTest do
  @moduledoc """
  Tests for AoSession.SessionMonitor — auto-cleanup of stale sessions
  when a transport process dies without calling cleanup().
  """
  use ExUnit.Case, async: false

  alias AoSession.OnlineDirectory

  setup do
    # Ensure the SessionRegistry is running
    case Process.whereis(AoSession.SessionRegistry) do
      nil ->
        start_supervised!(
          {Registry, keys: :unique, name: AoSession.SessionRegistry},
          id: :session_registry
        )

      _pid ->
        :ok
    end

    # Ensure OnlineDirectory is running
    case GenServer.whereis(OnlineDirectory) do
      nil -> start_supervised!(OnlineDirectory)
      _pid -> :ok
    end

    # Ensure SessionMonitor is running
    case GenServer.whereis(AoSession.SessionMonitor) do
      nil -> start_supervised!(AoSession.SessionMonitor)
      _pid -> :ok
    end

    # Clear all Registry entries for test isolation
    Registry.select(AoSession.SessionRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.each(fn {key, _pid} -> Registry.unregister(AoSession.SessionRegistry, key) end)

    # Clear OnlineDirectory ETS
    :ets.delete_all_objects(:ao_online_directory)

    :ok
  end

  describe "stale session cleanup when transport dies" do
    test "stale session is cleaned up when transport dies" do
      char_id = 1001
      account_id = "acct_monitor_1"

      # Spawn a process to act as the transport (it calls register so Registry tracks it)
      transport =
        spawn(fn ->
          AoSession.register(account_id, char_id, self())
          OnlineDirectory.register(char_id, "MonitorTest", 1, self())
          receive do: (:stop -> :ok)
        end)

      # Give it time to register
      Process.sleep(50)

      # Verify registered
      assert {:ok, _pid, _meta} = AoSession.lookup(char_id)
      assert {:ok, _info} = OnlineDirectory.lookup_by_id(char_id)

      # Kill the transport (simulate crash without cleanup)
      Process.exit(transport, :kill)

      # Wait for the monitor to fire and clean up
      Process.sleep(100)

      # Both Registry and OnlineDirectory should be cleaned up
      assert {:error, :not_found} = AoSession.lookup(char_id)
      assert :not_found = OnlineDirectory.lookup_by_id(char_id)

      # Re-registration should succeed
      new_transport =
        spawn(fn ->
          AoSession.register(account_id, char_id, self())
          receive do: (:stop -> :ok)
        end)

      Process.sleep(50)
      assert {:ok, _pid, _meta} = AoSession.lookup(char_id)

      Process.exit(new_transport, :kill)
      Process.sleep(100)
    end

    test "normal unregister still works" do
      char_id = 2001

      :ok = AoSession.register("acct_2", char_id, self())
      OnlineDirectory.register(char_id, "NormalUnreg", 1, self())

      AoSession.unregister(char_id)
      OnlineDirectory.unregister(char_id)

      assert {:error, :not_found} = AoSession.lookup(char_id)
      assert :not_found = OnlineDirectory.lookup_by_id(char_id)
    end

    test "process exit with :normal reason triggers cleanup" do
      char_id = 3001
      account_id = "acct_normal_exit"

      transport =
        spawn(fn ->
          AoSession.register(account_id, char_id, self())
          OnlineDirectory.register(char_id, "NormalExit", 1, self())
          receive do: (:stop -> :ok)
        end)

      Process.sleep(50)
      assert {:ok, _pid, _meta} = AoSession.lookup(char_id)

      # Exit normally
      send(transport, :stop)
      Process.sleep(100)

      assert {:error, :not_found} = AoSession.lookup(char_id)
      assert :not_found = OnlineDirectory.lookup_by_id(char_id)
    end

    test "concurrent registrations with crashing transports" do
      transports =
        for i <- 1..10 do
          char_id = 4000 + i

          pid =
            spawn(fn ->
              AoSession.register("acct_concurrent_#{i}", char_id, self())
              OnlineDirectory.register(char_id, "Concurrent#{i}", 1, self())
              receive do: (:stop -> :ok)
            end)

          {char_id, pid}
        end

      Process.sleep(50)

      # Verify all registered
      for {char_id, _pid} <- transports do
        assert {:ok, _, _} = AoSession.lookup(char_id)
        assert {:ok, _} = OnlineDirectory.lookup_by_id(char_id)
      end

      # Kill all transports
      for {_char_id, pid} <- transports do
        Process.exit(pid, :kill)
      end

      Process.sleep(200)

      # Verify all cleaned up
      for {char_id, _pid} <- transports do
        assert {:error, :not_found} = AoSession.lookup(char_id)
        assert :not_found = OnlineDirectory.lookup_by_id(char_id)
      end

      # Verify all can be re-registered
      for {char_id, _pid} <- transports do
        new_pid =
          spawn(fn ->
            AoSession.register("acct_reregister", char_id, self())
            receive do: (:stop -> :ok)
          end)

        Process.sleep(10)
        assert {:ok, _, _} = AoSession.lookup(char_id)
        Process.exit(new_pid, :kill)
      end

      Process.sleep(200)
    end
  end

  describe "adversarial: rapid register-crash-reregister cycle" do
    test "20 rapid cycles of register-crash-reregister" do
      char_id = 5001

      for i <- 1..20 do
        transport =
          spawn(fn ->
            AoSession.register("acct_rapid_#{i}", char_id, self())
            OnlineDirectory.register(char_id, "Rapid#{i}", 1, self())
            receive do: (:stop -> :ok)
          end)

        Process.sleep(20)
        Process.exit(transport, :kill)
        Process.sleep(50)

        # After cleanup, should be re-registerable
        assert {:error, :not_found} = AoSession.lookup(char_id),
               "Lookup should return not_found after cycle #{i}"

        assert :not_found = OnlineDirectory.lookup_by_id(char_id),
               "OnlineDirectory should return not_found after cycle #{i}"
      end
    end
  end

  describe "adversarial: monitor doesn't interfere with normal cleanup" do
    test "normal cleanup then pid kill causes no errors" do
      char_id = 6001

      transport =
        spawn(fn ->
          AoSession.register("acct_double", char_id, self())
          OnlineDirectory.register(char_id, "DoubleCleanup", 1, self())
          receive do: (:stop -> :ok)
        end)

      Process.sleep(50)

      # Do normal cleanup (unregister explicitly)
      AoSession.unregister(char_id)
      OnlineDirectory.unregister(char_id)

      # Now kill the pid — monitor fires but session is already gone
      Process.exit(transport, :kill)
      Process.sleep(100)

      # No crash, still cleaned up
      assert {:error, :not_found} = AoSession.lookup(char_id)
      assert :not_found = OnlineDirectory.lookup_by_id(char_id)

      # SessionMonitor should still be alive and functional
      assert Process.alive?(GenServer.whereis(AoSession.SessionMonitor))
    end
  end
end
