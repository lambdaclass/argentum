defmodule AoSession.OnlineDirectoryTest do
  @moduledoc """
  Tests for AoSession.OnlineDirectory ETS-based online player lookup.
  Starts the GenServer per test for isolation.
  """
  use ExUnit.Case, async: false

  # OnlineDirectory uses a named ETS table (:ao_online_directory),
  # so tests cannot be async — the table name is global.

  alias AoSession.OnlineDirectory

  setup do
    # Ensure OnlineDirectory is running (may already be started by the app)
    case GenServer.whereis(OnlineDirectory) do
      nil -> start_supervised!(OnlineDirectory)
      pid -> pid
    end

    # Clear the ETS table between tests for isolation
    :ets.delete_all_objects(:ao_online_directory)

    :ok
  end

  describe "register/4 and lookup_by_id/1" do
    test "registers a character and looks it up by id" do
      session_pid = self()
      :ok = OnlineDirectory.register(1, "Gandalf", 100, session_pid)

      assert {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.name == "Gandalf"
      assert info.map_id == 100
      assert info.session_pid == session_pid
    end

    test "overwrites existing entry for same char_id" do
      :ok = OnlineDirectory.register(1, "Gandalf", 100, self())
      :ok = OnlineDirectory.register(1, "Gandalf", 200, self())

      assert {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.map_id == 200
    end

    test "returns :not_found for unregistered char_id" do
      assert :not_found == OnlineDirectory.lookup_by_id(999)
    end
  end

  describe "lookup_by_name/1" do
    test "finds character by name" do
      :ok = OnlineDirectory.register(42, "Aragorn", 10, self())

      assert {:ok, 42, info} = OnlineDirectory.lookup_by_name("Aragorn")
      assert info.name == "Aragorn"
      assert info.map_id == 10
    end

    test "name lookup is case-insensitive" do
      :ok = OnlineDirectory.register(1, "Legolas", 10, self())

      assert {:ok, 1, _info} = OnlineDirectory.lookup_by_name("legolas")
      assert {:ok, 1, _info} = OnlineDirectory.lookup_by_name("LEGOLAS")
      assert {:ok, 1, _info} = OnlineDirectory.lookup_by_name("LeGoLaS")
    end

    test "name lookup trims whitespace" do
      :ok = OnlineDirectory.register(1, "Gimli", 10, self())

      assert {:ok, 1, _info} = OnlineDirectory.lookup_by_name("  Gimli  ")
    end

    test "returns :not_found for unknown name" do
      assert :not_found == OnlineDirectory.lookup_by_name("Nobody")
    end
  end

  describe "unregister/1" do
    test "removes character from both id and name lookups" do
      :ok = OnlineDirectory.register(1, "Frodo", 10, self())
      OnlineDirectory.unregister(1)

      assert :not_found == OnlineDirectory.lookup_by_id(1)
      assert :not_found == OnlineDirectory.lookup_by_name("Frodo")
    end

    test "unregistering non-existent char_id does not crash" do
      # Should return :ok and not raise
      assert :ok == OnlineDirectory.unregister(999)
    end

    test "unregister only removes the targeted character" do
      :ok = OnlineDirectory.register(1, "Sam", 10, self())
      :ok = OnlineDirectory.register(2, "Merry", 10, self())

      OnlineDirectory.unregister(1)

      assert :not_found == OnlineDirectory.lookup_by_id(1)
      assert {:ok, _info} = OnlineDirectory.lookup_by_id(2)
    end
  end

  describe "update_map/2" do
    test "updates map_id for an existing character" do
      :ok = OnlineDirectory.register(1, "Boromir", 10, self())
      :ok = OnlineDirectory.update_map(1, 20)

      assert {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.map_id == 20
      # Other fields preserved
      assert info.name == "Boromir"
    end

    test "update_map on non-existent char_id does not crash" do
      assert :ok == OnlineDirectory.update_map(999, 20)
    end

    test "preserves session_pid after map update" do
      pid = self()
      :ok = OnlineDirectory.register(1, "Pippin", 10, pid)
      :ok = OnlineDirectory.update_map(1, 30)

      assert {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.session_pid == pid
    end
  end

  describe "online_count/0" do
    test "returns 0 when empty" do
      assert 0 == OnlineDirectory.online_count()
    end

    test "counts registered characters" do
      :ok = OnlineDirectory.register(1, "A", 1, self())
      :ok = OnlineDirectory.register(2, "B", 1, self())
      :ok = OnlineDirectory.register(3, "C", 1, self())

      assert 3 == OnlineDirectory.online_count()
    end

    test "decrements after unregister" do
      :ok = OnlineDirectory.register(1, "A", 1, self())
      :ok = OnlineDirectory.register(2, "B", 1, self())
      OnlineDirectory.unregister(1)

      assert 1 == OnlineDirectory.online_count()
    end

    test "does not double-count name index entries" do
      :ok = OnlineDirectory.register(1, "TestName", 1, self())

      # Only 1, not 2 (the :by_name entry should not be counted)
      assert 1 == OnlineDirectory.online_count()
    end
  end

  describe "ip tracking" do
    test "stores the peer ip passed at register time" do
      :ok = OnlineDirectory.register(1, "Elrond", 10, self(), ip: "10.0.0.7")

      assert {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.ip == "10.0.0.7"
    end

    test "defaults to desconocida when no ip is supplied" do
      :ok = OnlineDirectory.register(1, "Anon", 10, self())

      assert {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.ip == "desconocida"
    end

    test "ip survives map and faction updates" do
      :ok = OnlineDirectory.register(1, "Mover", 10, self(), ip: "10.0.0.7")
      :ok = OnlineDirectory.update_map(1, 20)
      :ok = OnlineDirectory.update_faction(1, :royal_army)

      assert {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.ip == "10.0.0.7"
    end

    test "list_names_by_ip returns only players sharing that ip" do
      :ok = OnlineDirectory.register(1, "Alt1", 1, self(), ip: "192.168.1.5")
      :ok = OnlineDirectory.register(2, "Alt2", 1, self(), ip: "192.168.1.5")
      :ok = OnlineDirectory.register(3, "Other", 1, self(), ip: "192.168.1.9")

      assert ["Alt1", "Alt2"] == Enum.sort(OnlineDirectory.list_names_by_ip("192.168.1.5"))
      assert ["Other"] == OnlineDirectory.list_names_by_ip("192.168.1.9")
    end

    test "list_names_by_ip returns [] for an ip with nobody online" do
      :ok = OnlineDirectory.register(1, "Someone", 1, self(), ip: "192.168.1.5")

      assert [] == OnlineDirectory.list_names_by_ip("8.8.8.8")
    end

    test "unregister drops the player from ip lookups" do
      :ok = OnlineDirectory.register(1, "Leaver", 1, self(), ip: "192.168.1.5")
      OnlineDirectory.unregister(1)

      assert [] == OnlineDirectory.list_names_by_ip("192.168.1.5")
    end
  end

  describe "broadcast_all/1" do
    test "sends message to all registered session pids" do
      # Register self under multiple char_ids
      me = self()
      :ok = OnlineDirectory.register(1, "A", 1, me)
      :ok = OnlineDirectory.register(2, "B", 1, me)

      count = OnlineDirectory.broadcast_all({:server_msg, "hello"})

      assert count == 2

      assert_receive {:server_msg, "hello"}
      assert_receive {:server_msg, "hello"}
    end

    test "returns 0 when no players online" do
      assert 0 == OnlineDirectory.broadcast_all(:ping)
    end

    test "sends to spawned processes, not just self" do
      test_pid = self()

      pids =
        for i <- 1..3 do
          spawn(fn ->
            receive do
              msg -> send(test_pid, {:got, i, msg})
            end
          end)
        end

      for {pid, i} <- Enum.with_index(pids, 1) do
        :ok = OnlineDirectory.register(i, "Player#{i}", 1, pid)
      end

      count = OnlineDirectory.broadcast_all(:broadcast_test)
      assert count == 3

      assert_receive {:got, 1, :broadcast_test}
      assert_receive {:got, 2, :broadcast_test}
      assert_receive {:got, 3, :broadcast_test}
    end
  end

  describe "edge cases" do
    test "register with empty name works" do
      :ok = OnlineDirectory.register(1, "", 1, self())
      assert {:ok, _info} = OnlineDirectory.lookup_by_id(1)
      assert {:ok, 1, _info} = OnlineDirectory.lookup_by_name("")
    end

    test "register with unicode name works" do
      :ok = OnlineDirectory.register(1, "Senor", 1, self())
      assert {:ok, 1, _info} = OnlineDirectory.lookup_by_name("senor")
    end

    test "re-register after unregister works" do
      :ok = OnlineDirectory.register(1, "ReconnectPlayer", 10, self())
      OnlineDirectory.unregister(1)
      :ok = OnlineDirectory.register(1, "ReconnectPlayer", 20, self())

      assert {:ok, info} = OnlineDirectory.lookup_by_id(1)
      assert info.map_id == 20
    end

    test "name collision: second register with same name but different char_id overwrites name index" do
      :ok = OnlineDirectory.register(1, "Duplicate", 10, self())
      :ok = OnlineDirectory.register(2, "Duplicate", 20, self())

      # Name index now points to char_id 2
      assert {:ok, 2, info} = OnlineDirectory.lookup_by_name("Duplicate")
      assert info.map_id == 20

      # But char_id 1 is still in the id index
      assert {:ok, old_info} = OnlineDirectory.lookup_by_id(1)
      assert old_info.name == "Duplicate"
    end
  end
end
