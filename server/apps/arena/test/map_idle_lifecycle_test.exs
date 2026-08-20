defmodule Arena.MapIdleLifecycleTest do
  @moduledoc """
  What a map process does when nobody is standing on it.

  Every map in the world is loaded and stays loaded. The timers stay armed. What
  changes is that a tick with no players returns immediately instead of doing
  per-player work for nobody, and that the process compacts its own heap at the
  transitions where no player can be waiting on it.

  The reason this exists: BEAM's collector is generational, `fullsweep_after`
  defaults to 65535 minor collections, and a map process manages a handful of
  minor collections an hour. The old generation therefore accumulates every
  intermediate that happened to be reachable when a young heap filled, and is
  never swept. Measured on a dev world: 842 map processes holding 1849 MB, of
  which forcing a fullsweep freed 1054 MB; an idle server reached 86 GB RSS in
  two days.

  Deliberately not tested here, because it is deliberately not done: setting
  `fullsweep_after: 0` on the process. That would full-sweep a crowded map's much
  larger live state on every collection, during combat. Compaction happens only
  when the map is empty.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.MapServer
  alias AoEntities.PlayerEntity
  import Arena.Test.MapStateFactory

  # A synthetic map: no map file, no real NPCs. Distinct from the ids other test
  # modules use so a shared registry cannot leak state between them.
  @map_id 10_071

  # A production-shaped id, for the handlers whose bodies test maps skip entirely.
  @live_map_id 1

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

    :ok
  end

  setup do
    pid =
      case Registry.lookup(Arena.MapRegistry, @map_id) do
        [{pid, _}] ->
          pid

        [] ->
          {:ok, pid} = Arena.Map.MapSupervisor.start_map(@map_id)
          pid
      end

    # Loading is a continuation, so wait for it rather than racing it.
    true = MapServer.ready?(@map_id)
    %{pid: pid}
  end

  defp entity(char_id, name) do
    %PlayerEntity{
      char_id: char_id,
      name: name,
      account_id: "account_#{char_id}",
      x: 50,
      y: 50,
      hp: 100,
      max_hp: 100,
      mana: 100,
      max_mana: 100,
      stamina: 100,
      max_stamina: 100
    }
  end

  defp enter(char_id, name) do
    parent = self()

    session =
      spawn(fn ->
        reply = GenServer.call(MapServer.via(@map_id), {:enter, entity(char_id, name), []}, 10_000)
        send(parent, {:entered, reply})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:entered, {:ok, _char_index, _players, _weather}}, 10_000
    session
  end

  defp leave(char_id) do
    GenServer.call(MapServer.via(@map_id), {:leave, char_id})
  end

  # The monitor message a crashed session produces is asynchronous, so wait for the
  # map to have acted on it rather than assuming it already has.
  defp await(pid, fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      state = :sys.get_state(pid)

      if fun.(state) or System.monotonic_time(:millisecond) > deadline do
        state
      else
        Process.sleep(20)
        nil
      end
    end)
    |> Enum.find(& &1)
  end

  defp state_of(pid), do: :sys.get_state(pid)

  describe "an empty map" do
    test "has compacted its heap by the time it is ready", %{pid: pid} do
      # Parsing and building a map leaves a heap full of intermediates. The map is
      # empty the instant it finishes loading, which is the cheapest moment there is
      # to reclaim them.
      #
      # The compaction is a message the loader sends itself, not something it does in
      # its own frame — in its own frame the parsed map data is still reachable and a
      # fullsweep copies it instead of freeing it. `ready?` is a call, so it queues
      # behind that message: if this is true, the compaction has already happened.
      assert MapServer.ready?(@map_id)
      assert state_of(pid).idle_compacted
    end

    test "answers a regen tick without doing any work, and stays armed" do
      state = map_state(map_id: @live_map_id, players: %{})

      assert {:noreply, after_tick} = MapServer.handle_info(:regen_tick, state)

      # The same term, not merely an equal one: the handler did not rebuild the
      # state to advance counters nobody is subject to.
      assert after_tick === state
      assert_receive :regen_tick, 5_000
      refute_receive :regen_tick, 100
    end

    test "answers a buff tick without doing any work, and stays armed" do
      state = map_state(map_id: @live_map_id, players: %{})

      assert {:noreply, after_tick} = MapServer.handle_info(:buff_tick, state)

      assert after_tick === state
      assert_receive :buff_tick, 5_000
      refute_receive :buff_tick, 100
    end

    test "answers an NPC AI tick without scanning respawns, and stays armed" do
      state = map_state(map_id: @live_map_id, players: %{})

      assert {:noreply, after_tick} = MapServer.handle_info(:npc_ai_tick, state)

      assert after_tick === state
      assert_receive :npc_ai_tick, 5_000
      refute_receive :npc_ai_tick, 100
    end

    test "keeps its heap compact on autosave, and leaves a small heap alone" do
      # Autosave is where an empty map is *kept* compact rather than merely made
      # compact once. A first version compacted at each transition and then never
      # again, and 842 empty maps drifted back to 2.39 MB each within ten minutes —
      # the gen_server loop and the timer messages, promoted and never swept.
      #
      # Measured inside a process of its own, because the compaction is of whichever
      # process handles the message.
      parent = self()
      state = map_state(map_id: @live_map_id, players: %{})

      spawn(fn ->
        # Something worth reclaiming: a big term on the process heap, unreachable the
        # moment it is built. Binaries would not do — large ones live off-heap, and it
        # is the heap block that this is about.
        _ = length(Enum.to_list(1..300_000))
        {:total_heap_size, before} = Process.info(self(), :total_heap_size)
        {:noreply, compacted} = MapServer.handle_info(:autosave, state)
        {:total_heap_size, after_gc} = Process.info(self(), :total_heap_size)

        # And again, now that there is nothing left to reclaim.
        {:noreply, _} = MapServer.handle_info(:autosave, compacted)
        {:total_heap_size, twice} = Process.info(self(), :total_heap_size)

        send(parent, {:heaps, before, after_gc, twice, compacted.idle_compacted})
      end)

      assert_receive {:heaps, before, after_gc, twice, flagged}, 30_000

      assert before > 64 * 1024, "the test did not manage to grow a heap worth compacting"
      assert after_gc < before, "autosave on an empty map did not reclaim anything"
      assert flagged, "the compaction was not recorded on the state"

      # The second pass is below the threshold and does nothing: no fullsweep a minute
      # for the rest of the server's life.
      assert twice <= after_gc * 2
    end

    test "keeps ticking with a heap that does not grow" do
      # The claim this whole change exists for, measured rather than asserted: a
      # process doing nothing but empty ticks does not accumulate a heap. Run in a
      # process of its own, because the test process has its own allocations.
      parent = self()
      state = map_state(map_id: @live_map_id, players: %{})

      pid =
        spawn(fn ->
          Enum.reduce(1..3_000, state, fn _, acc ->
            {:noreply, acc} = MapServer.handle_info(:regen_tick, acc)
            {:noreply, acc} = MapServer.handle_info(:buff_tick, acc)
            {:noreply, acc} = MapServer.handle_info(:npc_ai_tick, acc)
            acc
          end)

          send(parent, {:heap, Process.info(self(), :total_heap_size)})
        end)

      assert_receive {:heap, {:total_heap_size, words}}, 30_000
      bytes = words * :erlang.system_info(:wordsize)

      # 9000 empty ticks. The state itself is around 100 KB on a real map and this
      # synthetic one is smaller; anything under a megabyte proves the ticks are not
      # accumulating. Before the fast paths, the same loop grew without bound.
      assert bytes < 1_048_576, "#{div(bytes, 1024)} KB of heap after 9000 empty ticks"
      refute Process.alive?(pid), "the measuring process should have finished"
    end
  end

  describe "a populated map" do
    test "does the work when somebody is standing on it" do
      state =
        map_state(
          map_id: @live_map_id,
          players: %{1 => entity(1, "Aldar")},
          sessions: %{1 => self()}
        )

      assert {:noreply, after_tick} = MapServer.handle_info(:regen_tick, state)

      # The counters advanced, which is how the body announces it ran at all.
      assert after_tick.thirst_tick_counter == state.thirst_tick_counter + 1
      assert after_tick.hunger_tick_counter == state.hunger_tick_counter + 1
      assert after_tick.penalty_tick_counter == state.penalty_tick_counter + 1
    end

    test "does the work with several players and rearms exactly one timer" do
      state =
        map_state(
          map_id: @live_map_id,
          players: %{
            1 => entity(1, "Aldar"),
            2 => entity(2, "Nithal"),
            3 => entity(3, "Borzug")
          },
          sessions: %{1 => self(), 2 => self(), 3 => self()}
        )

      assert {:noreply, after_tick} = MapServer.handle_info(:buff_tick, state)
      assert map_size(after_tick.players) == 3

      assert_receive :buff_tick, 5_000
      refute_receive :buff_tick, 100
    end
  end

  describe "entering and leaving" do
    test "the first player clears the idle flag", %{pid: pid} do
      assert state_of(pid).idle_compacted

      session = enter(101, "Aldar")
      refute state_of(pid).idle_compacted

      Process.exit(session, :kill)
    end

    test "the last player leaving compacts, and an earlier one does not", %{pid: pid} do
      s1 = enter(102, "Aldar")
      s2 = enter(103, "Nithal")

      {:ok, _} = leave(102)
      state = state_of(pid)
      assert map_size(state.players) == 1
      refute state.idle_compacted, "compacted while somebody was still standing there"

      {:ok, _} = leave(103)
      state = state_of(pid)
      assert map_size(state.players) == 0
      assert state.idle_compacted

      Process.exit(s1, :kill)
      Process.exit(s2, :kill)
    end

    test "a crashed session empties the map and compacts it", %{pid: pid} do
      # No `leave` call at all: the client is gone and the map finds out through the
      # monitor it took when the session entered. This is the path that made the
      # autosave catch-all necessary in the first place.
      session = enter(104, "Aldar")
      refute state_of(pid).idle_compacted

      Process.exit(session, :kill)

      state = await(pid, &(map_size(&1.players) == 0))
      assert map_size(state.players) == 0, "a crashed session left its player on the map"
      assert state.idle_compacted
      assert Process.alive?(pid), "the map process died with its session"
    end

    test "leaving and re-entering repeatedly leaves one player and one flag", %{pid: pid} do
      for round <- 1..5 do
        session = enter(200 + round, "Aldar#{round}")
        refute state_of(pid).idle_compacted
        {:ok, _} = leave(200 + round)
        assert state_of(pid).idle_compacted
        Process.exit(session, :kill)
      end

      state = state_of(pid)
      assert map_size(state.players) == 0
      assert map_size(state.sessions) == 0
      assert map_size(state.monitors) == 0
      assert Process.alive?(pid)
    end

    test "the map process survives all of it", %{pid: pid} do
      assert Process.alive?(pid)
      assert MapServer.ready?(@map_id), "a loaded map must stay loaded"
    end
  end

  describe "respawn reconciliation" do
    test "a deadline that passed while the map was empty is caught up on entry" do
      # Absolute deadlines, so an empty map that never scanned them loses nothing:
      # one pass restores everything due. Without this, an entering player is sent an
      # NPC snapshot that is missing creatures, and watches them appear later.
      npc = %Arena.Entity.NpcEntity{
        instance_id: 1,
        npc_id: 1,
        char_index: 500,
        x: 50,
        y: 51,
        spawn_x: 50,
        spawn_y: 51,
        alive: false,
        respawn_at: Arena.Clock.now_ms() - 60_000,
        owner_id: nil,
        max_hp: 10,
        hp: 0
      }

      state =
        map_state(
          map_id: @live_map_id,
          players: %{},
          npcs_live: %{1 => npc},
          npc_char_indices: %{500 => 1}
        )

      {reconciled, _effects} = Arena.NpcAi.reconcile_respawns(state)

      assert reconciled.npcs_live[1].alive, "an expired respawn was not caught up"
      assert reconciled.npcs_live[1].hp > 0
    end

    test "a deadline still in the future is left alone" do
      npc = %Arena.Entity.NpcEntity{
        instance_id: 2,
        npc_id: 1,
        char_index: 501,
        x: 50,
        y: 52,
        spawn_x: 50,
        spawn_y: 52,
        alive: false,
        respawn_at: Arena.Clock.now_ms() + 600_000,
        owner_id: nil,
        max_hp: 10,
        hp: 0
      }

      state = map_state(map_id: @live_map_id, players: %{}, npcs_live: %{2 => npc})

      {reconciled, effects} = Arena.NpcAi.reconcile_respawns(state)

      refute reconciled.npcs_live[2].alive
      assert effects == []
    end
  end
end
