defmodule AoSession.SessionStateTransitionsTest do
  @moduledoc """
  Tests for session-state transitions and protocol invariants.

  Covers:
  - Session lifecycle: register → lookup → unregister → gone
  - Duplicate login prevention (same char_id from different processes)
  - Cleanup on disconnect (SessionMonitor auto-cleanup)
  - Token/metadata validation (connected_at, transport_pid, account_id)
  - OnlineDirectory lookup consistency after register/unregister cycles
  - Concurrent session operations and race conditions
  - Faction tracking through session lifecycle
  - GM vs non-GM broadcast isolation
  """
  use ExUnit.Case, async: false

  alias AoSession.OnlineDirectory

  setup do
    # Ensure SessionRegistry is running
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

    # Clear Registry entries
    Registry.select(AoSession.SessionRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.each(fn {key, _pid} -> Registry.unregister(AoSession.SessionRegistry, key) end)

    # Clear OnlineDirectory ETS
    :ets.delete_all_objects(:ao_online_directory)

    :ok
  end

  # ── Full lifecycle: register → connected → playing → disconnect → gone ──

  describe "full session lifecycle" do
    test "register → lookup confirms connected → unregister → lookup returns not_found" do
      char_id = 10_001
      account_id = "acct_lifecycle"

      # Phase 1: register
      assert :ok == AoSession.register(account_id, char_id, self())

      # Phase 2: lookup confirms connected
      assert {:ok, pid, meta} = AoSession.lookup(char_id)
      assert pid == self()
      assert meta.account_id == account_id
      assert meta.transport_pid == self()
      assert is_integer(meta.connected_at)

      # Phase 3: online_count reflects the session
      assert AoSession.online_count() >= 1

      # Phase 4: unregister (disconnect)
      AoSession.unregister(char_id)

      # Phase 5: gone
      assert {:error, :not_found} == AoSession.lookup(char_id)
    end

    test "full lifecycle with OnlineDirectory parallel registration" do
      char_id = 10_002
      account_id = "acct_full"

      # Register in both systems
      assert :ok == AoSession.register(account_id, char_id, self())
      assert :ok == OnlineDirectory.register(char_id, "TestPlayer", 1, self())

      # Both should be queryable
      assert {:ok, _pid, _meta} = AoSession.lookup(char_id)
      assert {:ok, info} = OnlineDirectory.lookup_by_id(char_id)
      assert info.name == "TestPlayer"
      assert {:ok, ^char_id, _info} = OnlineDirectory.lookup_by_name("TestPlayer")

      # Unregister both
      AoSession.unregister(char_id)
      OnlineDirectory.unregister(char_id)

      # Both should be gone
      assert {:error, :not_found} == AoSession.lookup(char_id)
      assert :not_found == OnlineDirectory.lookup_by_id(char_id)
      assert :not_found == OnlineDirectory.lookup_by_name("TestPlayer")
    end
  end

  # ── Duplicate login prevention ──────────────────────────────────────────

  describe "duplicate login prevention" do
    test "same char_id cannot register twice from same process" do
      char_id = 20_001
      assert :ok == AoSession.register("acct_a", char_id, self())
      assert {:error, :already_connected} == AoSession.register("acct_a", char_id, self())
    end

    test "same char_id cannot register from a different process" do
      char_id = 20_002
      me = self()

      # First registration from a spawned process
      other =
        spawn(fn ->
          AoSession.register("acct_b", char_id, self())
          send(me, :registered)
          receive do: (:stop -> :ok)
        end)

      assert_receive :registered, 200

      # Second registration from test process should fail
      assert {:error, :already_connected} == AoSession.register("acct_c", char_id, self())

      Process.exit(other, :kill)
      Process.sleep(100)
    end

    test "same char_id cannot register from a different account" do
      char_id = 20_003
      assert :ok == AoSession.register("acct_x", char_id, self())
      assert {:error, :already_connected} == AoSession.register("acct_y", char_id, self())
    end

    test "after unregister, the char_id can be re-claimed by a new session" do
      char_id = 20_004

      assert :ok == AoSession.register("acct_first", char_id, self())
      AoSession.unregister(char_id)

      # Now a different account can claim it
      assert :ok == AoSession.register("acct_second", char_id, self())

      {:ok, _pid, meta} = AoSession.lookup(char_id)
      assert meta.account_id == "acct_second"
    end
  end

  # ── Cleanup on disconnect (SessionMonitor auto-cleanup) ─────────────────

  describe "cleanup on disconnect via SessionMonitor" do
    test "killing transport pid cleans up both Registry and OnlineDirectory" do
      char_id = 30_001
      me = self()

      transport =
        spawn(fn ->
          AoSession.register("acct_cleanup", char_id, self())
          OnlineDirectory.register(char_id, "CleanupTest", 5, self())
          send(me, :ready)
          receive do: (:stop -> :ok)
        end)

      assert_receive :ready, 200

      # Verify both are registered
      assert {:ok, _pid, _meta} = AoSession.lookup(char_id)
      assert {:ok, _info} = OnlineDirectory.lookup_by_id(char_id)

      # Kill transport
      Process.exit(transport, :kill)
      Process.sleep(150)

      # Auto-cleanup should have fired
      assert {:error, :not_found} = AoSession.lookup(char_id)
      assert :not_found = OnlineDirectory.lookup_by_id(char_id)
    end

    test "normal exit also triggers cleanup" do
      char_id = 30_002
      me = self()

      transport =
        spawn(fn ->
          AoSession.register("acct_normal_exit", char_id, self())
          OnlineDirectory.register(char_id, "NormalExitTest", 5, self())
          send(me, :ready)
          receive do: (:done -> :ok)
        end)

      assert_receive :ready, 200
      assert {:ok, _, _} = AoSession.lookup(char_id)

      # Normal exit
      send(transport, :done)
      Process.sleep(150)

      assert {:error, :not_found} = AoSession.lookup(char_id)
      assert :not_found = OnlineDirectory.lookup_by_id(char_id)
    end

    test "double cleanup: explicit unregister then transport dies" do
      char_id = 30_003
      me = self()

      transport =
        spawn(fn ->
          AoSession.register("acct_double_clean", char_id, self())
          OnlineDirectory.register(char_id, "DoubleClean", 5, self())
          send(me, :ready)
          receive do: (:stop -> :ok)
        end)

      assert_receive :ready, 200

      # Explicitly unregister first
      AoSession.unregister(char_id)
      OnlineDirectory.unregister(char_id)

      # Then kill transport - monitor fires but nothing to clean
      Process.exit(transport, :kill)
      Process.sleep(150)

      # No crash, still gone
      assert {:error, :not_found} = AoSession.lookup(char_id)
      assert :not_found = OnlineDirectory.lookup_by_id(char_id)

      # SessionMonitor should still be alive
      assert Process.alive?(GenServer.whereis(AoSession.SessionMonitor))
    end
  end

  # ── Token/metadata validation ───────────────────────────────────────────

  describe "session metadata invariants" do
    test "connected_at is monotonically increasing for sequential registrations" do
      :ok = AoSession.register("acct_1", 40_001, self())
      {:ok, _, meta1} = AoSession.lookup(40_001)
      AoSession.unregister(40_001)

      Process.sleep(1)

      :ok = AoSession.register("acct_2", 40_002, self())
      {:ok, _, meta2} = AoSession.lookup(40_002)

      assert meta2.connected_at >= meta1.connected_at
    end

    test "transport_pid correctly distinguishes different transport processes" do
      t1 = spawn(fn -> receive do: (:stop -> :ok) end)
      t2 = spawn(fn -> receive do: (:stop -> :ok) end)

      :ok = AoSession.register("acct_t1", 40_003, t1)
      :ok = AoSession.register("acct_t2", 40_004, t2)

      {:ok, _, meta1} = AoSession.lookup(40_003)
      {:ok, _, meta2} = AoSession.lookup(40_004)

      assert meta1.transport_pid == t1
      assert meta2.transport_pid == t2
      assert meta1.transport_pid != meta2.transport_pid

      Process.exit(t1, :kill)
      Process.exit(t2, :kill)
      Process.sleep(100)
    end

    test "account_id is preserved through session lifetime" do
      :ok = AoSession.register("unique_acct_42", 40_005, self())
      {:ok, _, meta} = AoSession.lookup(40_005)
      assert meta.account_id == "unique_acct_42"
    end
  end

  # ── OnlineDirectory lookup consistency ──────────────────────────────────

  describe "OnlineDirectory consistency across operations" do
    test "update_map preserves all other fields" do
      pid = self()
      :ok = OnlineDirectory.register(50_001, "MapTest", 10, pid, is_gm: true, faction: :royal_army)
      :ok = OnlineDirectory.update_map(50_001, 99)

      {:ok, info} = OnlineDirectory.lookup_by_id(50_001)
      assert info.map_id == 99
      assert info.name == "MapTest"
      assert info.session_pid == pid
      assert info.is_gm == true
      assert info.faction == :royal_army
    end

    test "update_faction preserves all other fields" do
      pid = self()
      :ok = OnlineDirectory.register(50_002, "FactionTest", 10, pid, is_gm: false, faction: :none)
      :ok = OnlineDirectory.update_faction(50_002, :chaos_legion)

      {:ok, info} = OnlineDirectory.lookup_by_id(50_002)
      assert info.faction == :chaos_legion
      assert info.name == "FactionTest"
      assert info.map_id == 10
      assert info.session_pid == pid
      assert info.is_gm == false
    end

    test "list_by_faction returns only matching faction members" do
      :ok = OnlineDirectory.register(50_010, "Royal1", 1, self(), faction: :royal_army)
      :ok = OnlineDirectory.register(50_011, "Royal2", 1, self(), faction: :royal_army)
      :ok = OnlineDirectory.register(50_012, "Chaos1", 1, self(), faction: :chaos_legion)
      :ok = OnlineDirectory.register(50_013, "Neutral", 1, self(), faction: :none)

      royals = OnlineDirectory.list_by_faction(:royal_army)
      assert length(royals) == 2
      names = Enum.map(royals, & &1.name) |> Enum.sort()
      assert names == ["Royal1", "Royal2"]

      chaos = OnlineDirectory.list_by_faction(:chaos_legion)
      assert length(chaos) == 1
      assert hd(chaos).name == "Chaos1"

      nones = OnlineDirectory.list_by_faction(:none)
      assert length(nones) == 1
      assert hd(nones).name == "Neutral"
    end

    test "list_all_names returns all registered character names" do
      :ok = OnlineDirectory.register(50_020, "Alpha", 1, self())
      :ok = OnlineDirectory.register(50_021, "Beta", 1, self())
      :ok = OnlineDirectory.register(50_022, "Gamma", 1, self())

      names = OnlineDirectory.list_all_names() |> Enum.sort()
      assert names == ["Alpha", "Beta", "Gamma"]
    end

    test "name lookup after update_map still resolves" do
      :ok = OnlineDirectory.register(50_030, "Traveler", 1, self())
      assert {:ok, 50_030, _} = OnlineDirectory.lookup_by_name("Traveler")

      :ok = OnlineDirectory.update_map(50_030, 42)
      assert {:ok, 50_030, info} = OnlineDirectory.lookup_by_name("Traveler")
      assert info.map_id == 42
    end

    test "register-unregister-register cycle with different data" do
      :ok = OnlineDirectory.register(50_040, "FirstLife", 1, self(), faction: :royal_army)
      OnlineDirectory.unregister(50_040)

      :ok = OnlineDirectory.register(50_040, "SecondLife", 2, self(), faction: :chaos_legion)
      {:ok, info} = OnlineDirectory.lookup_by_id(50_040)
      assert info.name == "SecondLife"
      assert info.map_id == 2
      assert info.faction == :chaos_legion

      # Old name should not resolve
      assert :not_found == OnlineDirectory.lookup_by_name("FirstLife")
      # New name should resolve
      assert {:ok, 50_040, _} = OnlineDirectory.lookup_by_name("SecondLife")
    end
  end

  # ── GM broadcast isolation ──────────────────────────────────────────────

  describe "broadcast_to_gms isolation" do
    test "only GMs receive GM broadcast" do
      test_pid = self()

      gm_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:gm_got, msg})
          end
        end)

      player_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:player_got, msg})
          after
            200 -> send(test_pid, :player_timeout)
          end
        end)

      :ok = OnlineDirectory.register(60_001, "AdminGuy", 1, gm_pid, is_gm: true)
      :ok = OnlineDirectory.register(60_002, "NormalGuy", 1, player_pid, is_gm: false)

      count = OnlineDirectory.broadcast_to_gms({:gm_alert, "server restart"})
      assert count == 1

      assert_receive {:gm_got, {:gm_alert, "server restart"}}
      assert_receive :player_timeout, 500
    end

    test "broadcast_all reaches both GMs and normal players" do
      test_pid = self()

      gm_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:gm_got, msg})
          end
        end)

      player_pid =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:player_got, msg})
          end
        end)

      :ok = OnlineDirectory.register(60_010, "Admin2", 1, gm_pid, is_gm: true)
      :ok = OnlineDirectory.register(60_011, "Player2", 1, player_pid, is_gm: false)

      count = OnlineDirectory.broadcast_all(:server_msg)
      assert count == 2

      assert_receive {:gm_got, :server_msg}
      assert_receive {:player_got, :server_msg}
    end
  end

  # ── Concurrent operations ───────────────────────────────────────────────

  describe "concurrent session operations" do
    test "10 simultaneous registrations from different processes succeed" do
      me = self()

      pids =
        for i <- 1..10 do
          spawn(fn ->
            char_id = 70_000 + i
            result = AoSession.register("acct_conc_#{i}", char_id, self())
            send(me, {:result, i, result})
            receive do: (:stop -> :ok)
          end)
        end

      results =
        for _ <- 1..10 do
          receive do
            {:result, i, result} -> {i, result}
          after
            500 -> flunk("Timed out waiting for registration result")
          end
        end

      for {_i, result} <- results do
        assert result == :ok
      end

      assert AoSession.online_count() >= 10

      for pid <- pids, do: Process.exit(pid, :kill)
      Process.sleep(200)
    end

    test "rapid register-unregister cycles don't leak sessions" do
      for i <- 1..20 do
        char_id = 80_000 + i
        :ok = AoSession.register("acct_rapid_#{i}", char_id, self())
        AoSession.unregister(char_id)
      end

      # All should be cleaned up
      for i <- 1..20 do
        char_id = 80_000 + i
        assert {:error, :not_found} == AoSession.lookup(char_id)
      end
    end
  end

  # ── OnlineDirectory edge cases ──────────────────────────────────────────

  describe "OnlineDirectory protocol edge cases" do
    test "update_faction on non-existent char_id does not crash" do
      assert :ok == OnlineDirectory.update_faction(99_999, :royal_army)
    end

    test "broadcast_to_gms returns 0 when no GMs online" do
      :ok = OnlineDirectory.register(90_001, "Player", 1, self(), is_gm: false)
      assert 0 == OnlineDirectory.broadcast_to_gms(:alert)
    end

    test "list_by_faction returns empty list when no match" do
      :ok = OnlineDirectory.register(90_010, "OnlyRoyal", 1, self(), faction: :royal_army)
      assert [] == OnlineDirectory.list_by_faction(:chaos_legion)
    end

    test "online_count is consistent with register/unregister" do
      assert 0 == OnlineDirectory.online_count()

      :ok = OnlineDirectory.register(90_020, "A", 1, self())
      assert 1 == OnlineDirectory.online_count()

      :ok = OnlineDirectory.register(90_021, "B", 1, self())
      assert 2 == OnlineDirectory.online_count()

      OnlineDirectory.unregister(90_020)
      assert 1 == OnlineDirectory.online_count()

      OnlineDirectory.unregister(90_021)
      assert 0 == OnlineDirectory.online_count()
    end

    test "session Registry count matches register/unregister cycle" do
      assert 0 == AoSession.online_count()

      :ok = AoSession.register("a1", 90_030, self())
      assert 1 == AoSession.online_count()

      :ok = AoSession.register("a2", 90_031, self())
      assert 2 == AoSession.online_count()

      AoSession.unregister(90_030)
      assert 1 == AoSession.online_count()

      AoSession.unregister(90_031)
      assert 0 == AoSession.online_count()
    end
  end
end
