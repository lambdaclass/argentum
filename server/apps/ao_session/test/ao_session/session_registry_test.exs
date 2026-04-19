defmodule AoSession.SessionRegistryTest do
  @moduledoc """
  Tests for AoSession register/unregister/lookup/online_count.
  Starts a fresh Registry per test to keep tests isolated.
  """
  use ExUnit.Case, async: false

  setup do
    # Ensure the SessionRegistry is running (may already be started by the app)
    case Process.whereis(AoSession.SessionRegistry) do
      nil ->
        start_supervised!(
          {Registry, keys: :unique, name: AoSession.SessionRegistry},
          id: :session_registry
        )

      _pid ->
        :ok
    end

    # Clear all entries for test isolation.
    # Registry.unregister/2 only removes keys owned by self(), so it cannot
    # clean up entries left by a previous (now-dead) test process.  Instead we
    # flush the Registry partition so it processes any pending :DOWN messages
    # from dead owner processes, which removes their entries automatically.
    registry_pid = Process.whereis(AoSession.SessionRegistry)
    # A synchronous :sys.get_state forces the partition GenServer to handle
    # every message in its mailbox (including :DOWN) before returning.
    :sys.get_state(registry_pid)

    # Now unregister any entries that *this* process might own (e.g. if setup
    # is called between tests in the same process).
    Registry.select(AoSession.SessionRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.each(fn {key, _pid} ->
      Registry.unregister(AoSession.SessionRegistry, key)
    end)

    :ok
  end

  describe "register/3" do
    test "registers a new session successfully" do
      assert :ok == AoSession.register("acct_1", 1, self())
    end

    test "returns {:error, :already_connected} on double registration" do
      assert :ok == AoSession.register("acct_1", 1, self())
      assert {:error, :already_connected} == AoSession.register("acct_1", 1, self())
    end

    test "different char_ids can register simultaneously" do
      assert :ok == AoSession.register("acct_1", 1, self())
      assert :ok == AoSession.register("acct_2", 2, self())
    end

    test "same account_id with different char_id is allowed" do
      assert :ok == AoSession.register("acct_1", 1, self())
      assert :ok == AoSession.register("acct_1", 2, self())
    end

    test "different account trying same char_id gets already_connected" do
      assert :ok == AoSession.register("acct_1", 1, self())
      assert {:error, :already_connected} == AoSession.register("acct_2", 1, self())
    end
  end

  describe "unregister/1" do
    test "unregisters an existing session" do
      :ok = AoSession.register("acct_1", 1, self())
      AoSession.unregister(1)

      assert {:error, :not_found} == AoSession.lookup(1)
    end

    test "unregister allows re-registration of same char_id" do
      :ok = AoSession.register("acct_1", 1, self())
      AoSession.unregister(1)
      assert :ok == AoSession.register("acct_1", 1, self())
    end

    test "unregistering a non-existent char_id does not crash" do
      # Should not raise
      AoSession.unregister(999)
    end
  end

  describe "lookup/1" do
    test "returns {:ok, pid, meta} for a registered session" do
      :ok = AoSession.register("acct_1", 42, self())

      assert {:ok, pid, meta} = AoSession.lookup(42)
      assert pid == self()
      assert meta.account_id == "acct_1"
      assert meta.transport_pid == self()
      assert is_integer(meta.connected_at)
    end

    test "returns {:error, :not_found} for unregistered char_id" do
      assert {:error, :not_found} == AoSession.lookup(999)
    end

    test "returns {:error, :not_found} after unregister" do
      :ok = AoSession.register("acct_1", 1, self())
      AoSession.unregister(1)

      assert {:error, :not_found} == AoSession.lookup(1)
    end
  end

  describe "online_count/0" do
    test "returns 0 when no sessions registered" do
      assert 0 == AoSession.online_count()
    end

    test "increments with each registration" do
      :ok = AoSession.register("acct_1", 1, self())
      assert 1 == AoSession.online_count()

      :ok = AoSession.register("acct_2", 2, self())
      assert 2 == AoSession.online_count()
    end

    test "decrements after unregister" do
      :ok = AoSession.register("acct_1", 1, self())
      :ok = AoSession.register("acct_2", 2, self())
      AoSession.unregister(1)

      assert 1 == AoSession.online_count()
    end
  end

  describe "session metadata" do
    test "connected_at is a monotonic timestamp" do
      before = System.monotonic_time(:millisecond)
      :ok = AoSession.register("acct_1", 1, self())
      after_time = System.monotonic_time(:millisecond)

      {:ok, _pid, meta} = AoSession.lookup(1)
      assert meta.connected_at >= before
      assert meta.connected_at <= after_time
    end

    test "transport_pid is stored correctly" do
      # Spawn a separate process to act as transport
      transport = spawn(fn -> Process.sleep(:infinity) end)

      :ok = AoSession.register("acct_1", 1, transport)
      {:ok, _pid, meta} = AoSession.lookup(1)

      assert meta.transport_pid == transport

      Process.exit(transport, :kill)
    end
  end
end
