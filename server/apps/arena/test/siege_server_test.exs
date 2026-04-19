defmodule Arena.Events.SiegeServerTest do
  @moduledoc """
  Tests for the SiegeServer — castle siege event system.

  Tests the SiegeServer GenServer in isolation (no MapServer, no sessions).
  Uses injected spawner_fn and broadcaster_fn to avoid side effects.
  """

  use ExUnit.Case, async: true

  alias Arena.Events.SiegeServer
  alias Arena.Events.SiegeServer.{SpawnBox, ScoreEntry}

  @map_id 1
  @wall_hp 1000
  @duration 300

  @spawn_box %SpawnBox{
    top_left: {10, 10},
    bottom_right: {20, 20},
    heading: :north,
    wall_coord: {15, 5}
  }

  @spawn_box_2 %SpawnBox{
    top_left: {30, 30},
    bottom_right: {40, 40},
    heading: :south,
    wall_coord: {35, 45}
  }

  # Helper to build default siege options
  defp default_opts(overrides \\ []) do
    # Counter to generate unique NPC IDs per wave
    counter = :counters.new(1, [:atomics])

    spawner_fn = fn _map_id, _npc_type, _box ->
      n = :counters.get(counter, 1) + 1
      :counters.put(counter, 1, n)
      [n * 1000 + 1, n * 1000 + 2, n * 1000 + 3]
    end

    base = [
      wall_hp: @wall_hp,
      npc_types: [101, 102],
      spawn_boxes: [@spawn_box],
      duration_seconds: @duration,
      spawn_interval_ms: 60_000,
      max_npcs: 50,
      total_waves: 3,
      gold_mult: 1,
      gm_name: "TestGM",
      spawner_fn: spawner_fn,
      broadcaster_fn: fn _msg -> :ok end
    ]

    Keyword.merge(base, overrides)
  end

  setup do
    name = :"siege_server_#{System.unique_integer([:positive])}"
    {:ok, pid} = SiegeServer.start_link(name: name)
    %{server: name, pid: pid}
  end

  # ── Siege start and initial state ──────────────────────────────────────

  describe "start_siege/3" do
    test "starts a siege and returns initial state", %{server: s} do
      assert {:ok, info} = SiegeServer.start_siege(s, @map_id, default_opts())
      assert info.map_id == @map_id
      assert info.wall_hp == @wall_hp
      assert info.max_wall_hp == @wall_hp
      assert info.wall_health_percent == 100
      assert info.total_spawned == 0
      assert info.total_killed == 0
      assert info.waves_spawned == 0
      assert info.total_waves == 3
      assert info.started_by == "TestGM"
    end

    test "rejects duplicate siege on same map", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts())
      assert {:error, :siege_already_active} = SiegeServer.start_siege(s, @map_id, default_opts())
    end

    test "allows sieges on different maps", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, 1, default_opts())
      assert {:ok, _} = SiegeServer.start_siege(s, 2, default_opts())
    end

    test "rejects zero wall HP", %{server: s} do
      assert {:error, :invalid_wall_hp} =
               SiegeServer.start_siege(s, @map_id, default_opts(wall_hp: 0))
    end

    test "rejects negative wall HP", %{server: s} do
      assert {:error, :invalid_wall_hp} =
               SiegeServer.start_siege(s, @map_id, default_opts(wall_hp: -100))
    end

    test "rejects zero duration", %{server: s} do
      assert {:error, :invalid_duration} =
               SiegeServer.start_siege(s, @map_id, default_opts(duration_seconds: 0))
    end

    test "rejects empty npc_types", %{server: s} do
      assert {:error, :no_npc_types} =
               SiegeServer.start_siege(s, @map_id, default_opts(npc_types: []))
    end

    test "rejects empty spawn_boxes", %{server: s} do
      assert {:error, :no_spawn_boxes} =
               SiegeServer.start_siege(s, @map_id, default_opts(spawn_boxes: []))
    end

    test "rejects missing required options", %{server: s} do
      assert {:error, {:missing_options, missing}} =
               SiegeServer.start_siege(s, @map_id, [])

      assert :wall_hp in missing
      assert :npc_types in missing
      assert :spawn_boxes in missing
      assert :duration_seconds in missing
    end

    test "broadcasts start message", %{server: s} do
      test_pid = self()

      opts =
        default_opts(
          broadcaster_fn: fn msg -> send(test_pid, {:broadcast, msg}) end
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)

      assert_receive {:broadcast, msg}
      assert msg =~ "TestGM"
      assert msg =~ "asedio"
      assert msg =~ "#{@map_id}"
    end
  end

  # ── Wall damage and HP tracking ────────────────────────────────────────

  describe "damage_wall/3" do
    test "reduces wall HP", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts())

      assert {:ok, 800} = SiegeServer.damage_wall(s, @map_id, 200)
      assert {:ok, info} = SiegeServer.siege_status(s, @map_id)
      assert info.wall_hp == 800
    end

    test "wall HP does not go below zero", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts(wall_hp: 100))

      result = SiegeServer.damage_wall(s, @map_id, 500)
      assert {:siege_ended, %{outcome: :attackers_win, wall_hp: 0}} = result
    end

    test "returns error for non-existent siege", %{server: s} do
      assert {:error, :no_siege} = SiegeServer.damage_wall(s, 999, 100)
    end

    test "wall health percent updates correctly", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts())

      SiegeServer.damage_wall(s, @map_id, 500)
      assert {:ok, 50} = SiegeServer.wall_health_percent(s, @map_id)
    end
  end

  # ── Wall destruction triggers attacker victory ─────────────────────────

  describe "wall destruction (attacker victory)" do
    test "wall reaching zero triggers attackers_win", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts(wall_hp: 100))

      result = SiegeServer.damage_wall(s, @map_id, 100)
      assert {:siege_ended, %{outcome: :attackers_win}} = result
    end

    test "siege is removed after attacker victory", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts(wall_hp: 50))

      SiegeServer.damage_wall(s, @map_id, 50)
      assert {:error, :no_siege} = SiegeServer.siege_status(s, @map_id)
    end

    test "no rewards on attacker victory", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts(wall_hp: 10))

      {:siege_ended, result} = SiegeServer.damage_wall(s, @map_id, 10)
      assert result.rewards == []
    end

    test "broadcasts end message on wall destruction", %{server: s} do
      test_pid = self()

      opts =
        default_opts(
          wall_hp: 10,
          broadcaster_fn: fn msg -> send(test_pid, {:broadcast, msg}) end
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      # Clear the start broadcast
      assert_receive {:broadcast, _}

      SiegeServer.damage_wall(s, @map_id, 10)
      assert_receive {:broadcast, msg}
      assert msg =~ "atacantes"
    end
  end

  # ── Duration timeout triggers attacker victory ─────────────────────────

  describe "duration timeout (attacker victory)" do
    test "siege ends on timeout with attackers_win", %{server: s} do
      # Use a very short duration so the timer fires quickly
      opts = default_opts(duration_seconds: 1, spawn_interval_ms: 500_000)
      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)

      # Wait for the timeout
      Process.sleep(1_200)

      assert {:error, :no_siege} = SiegeServer.siege_status(s, @map_id)
    end
  end

  # ── All NPCs killed triggers defender victory ──────────────────────────

  describe "defender victory (all NPCs killed)" do
    test "killing all NPCs after all waves triggers defenders_win", %{server: s} do
      # Create a spawner that returns predictable IDs
      spawner_fn = fn _map_id, _npc_type, _box -> [1001] end

      opts =
        default_opts(
          total_waves: 1,
          spawn_interval_ms: 50,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)

      # Wait for the first (and only) wave to spawn
      Process.sleep(100)

      # Kill the spawned NPC
      result = SiegeServer.record_kill(s, @map_id, 1, "Hero", 1001)
      assert {:siege_ended, %{outcome: :defenders_win}} = result
    end

    test "rewards are distributed on defender victory", %{server: s} do
      spawner_fn = fn _map_id, _npc_type, _box -> [2001] end

      opts =
        default_opts(
          total_waves: 1,
          spawn_interval_ms: 50,
          gold_mult: 2,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      Process.sleep(100)

      {:siege_ended, result} = SiegeServer.record_kill(s, @map_id, 1, "Hero", 2001)
      assert result.outcome == :defenders_win
      assert length(result.rewards) == 1
      [reward] = result.rewards
      assert reward.char_id == 1
      assert reward.gold == 50_000 * 2
    end

    test "broadcasts defender victory message", %{server: s} do
      test_pid = self()

      spawner_fn = fn _map_id, _npc_type, _box -> [3001] end

      opts =
        default_opts(
          total_waves: 1,
          spawn_interval_ms: 50,
          spawner_fn: spawner_fn,
          broadcaster_fn: fn msg -> send(test_pid, {:broadcast, msg}) end
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      assert_receive {:broadcast, _start_msg}

      Process.sleep(100)
      SiegeServer.record_kill(s, @map_id, 1, "Hero", 3001)

      assert_receive {:broadcast, msg}
      assert msg =~ "defensores"
    end
  end

  # ── Top-10 scoreboard insertion and ranking ────────────────────────────

  describe "scoreboard" do
    test "records kills and maintains sorted order", %{server: s} do
      # Spawn NPCs we can kill
      counter = :counters.new(1, [:atomics])

      spawner_fn = fn _map_id, _npc_type, _box ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        [n * 100 + 1, n * 100 + 2, n * 100 + 3]
      end

      opts =
        default_opts(
          total_waves: 5,
          spawn_interval_ms: 30,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)

      # Wait for wave(s) to spawn
      Process.sleep(100)

      # Player A kills 1 NPC
      {:ok, _} = SiegeServer.record_kill(s, @map_id, 1, "PlayerA", 201)

      # Player B kills 2 NPCs
      {:ok, _} = SiegeServer.record_kill(s, @map_id, 2, "PlayerB", 202)
      {:ok, _} = SiegeServer.record_kill(s, @map_id, 2, "PlayerB", 203)

      {:ok, scoreboard} = SiegeServer.get_scoreboard(s, @map_id)
      assert length(scoreboard) == 2

      # Player B should be first (higher score)
      [first, second] = scoreboard
      assert first.char_id == 2
      assert first.score == 2
      assert second.char_id == 1
      assert second.score == 1
    end

    test "scoreboard is limited to 10 entries", %{server: s} do
      counter = :counters.new(1, [:atomics])

      spawner_fn = fn _map_id, _npc_type, _box ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        Enum.map(1..2, fn i -> n * 100 + i end)
      end

      opts =
        default_opts(
          total_waves: 10,
          spawn_interval_ms: 10,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      Process.sleep(200)

      # Have 12 different players each kill one NPC
      # Waves generate IDs: 201,202, 301,302, 401,402, ...
      npc_ids = for w <- 2..11, i <- 1..2, do: w * 100 + i
      # Take first 12 unique NPC IDs
      ids_to_use = Enum.take(npc_ids, 12)

      for {npc_id, player_idx} <- Enum.with_index(ids_to_use, 1) do
        SiegeServer.record_kill(s, @map_id, player_idx, "Player#{player_idx}", npc_id)
      end

      {:ok, scoreboard} = SiegeServer.get_scoreboard(s, @map_id)
      assert length(scoreboard) == 10
    end

    test "empty scoreboard returns empty list", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts())
      assert {:ok, []} = SiegeServer.get_scoreboard(s, @map_id)
    end

    test "duplicate kills by same player accumulate score", %{server: s} do
      counter = :counters.new(1, [:atomics])

      spawner_fn = fn _map_id, _npc_type, _box ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        [n * 100 + 1, n * 100 + 2]
      end

      opts =
        default_opts(
          total_waves: 5,
          spawn_interval_ms: 20,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      Process.sleep(200)

      {:ok, _} = SiegeServer.record_kill(s, @map_id, 1, "Hero", 201)
      {:ok, _} = SiegeServer.record_kill(s, @map_id, 1, "Hero", 202)
      {:ok, _} = SiegeServer.record_kill(s, @map_id, 1, "Hero", 301)

      {:ok, [entry]} = SiegeServer.get_scoreboard(s, @map_id)
      assert entry.char_id == 1
      assert entry.score == 3
    end

    test "recording kill for NPC not in siege returns error", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts())

      assert {:error, :npc_not_in_siege} =
               SiegeServer.record_kill(s, @map_id, 1, "Hero", 99999)
    end
  end

  # ── Reward calculation ─────────────────────────────────────────────────

  describe "reward calculation" do
    test "rewards are 50000 * gold_mult per top-10 player", %{server: s} do
      spawner_fn = fn _map_id, _npc_type, _box -> [5001, 5002] end

      opts =
        default_opts(
          total_waves: 1,
          spawn_interval_ms: 30,
          gold_mult: 3,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      Process.sleep(80)

      # Two players each kill one NPC
      {:ok, _} = SiegeServer.record_kill(s, @map_id, 10, "Alpha", 5001)
      {:siege_ended, result} = SiegeServer.record_kill(s, @map_id, 20, "Beta", 5002)

      assert result.outcome == :defenders_win
      assert length(result.rewards) == 2

      for reward <- result.rewards do
        assert reward.gold == 50_000 * 3
      end
    end

    test "no rewards on attacker victory (wall destroyed)", %{server: s} do
      spawner_fn = fn _map_id, _npc_type, _box -> [6001, 6002] end

      opts =
        default_opts(
          wall_hp: 50,
          total_waves: 2,
          spawn_interval_ms: 30,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      Process.sleep(80)

      # Record a kill to get someone on scoreboard, then destroy wall
      {:ok, _} = SiegeServer.record_kill(s, @map_id, 10, "Alpha", 6001)
      {:siege_ended, result} = SiegeServer.damage_wall(s, @map_id, 50)

      assert result.outcome == :attackers_win
      assert result.rewards == []
    end
  end

  # ── Wave spawn logic ──────────────────────────────────────────────────

  describe "wave spawning" do
    test "spawns waves at intervals", %{server: s} do
      call_count = :counters.new(1, [:atomics])

      spawner_fn = fn _map_id, _npc_type, _box ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)
        [n * 1000]
      end

      opts =
        default_opts(
          total_waves: 3,
          spawn_interval_ms: 50,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)

      # Wait long enough for all waves
      Process.sleep(300)

      {:ok, info} = SiegeServer.siege_status(s, @map_id)
      assert info.waves_spawned == 3
      assert info.total_spawned == 3
      assert info.alive_npcs == 3
    end

    test "respects max_npcs limit", %{server: s} do
      call_count = :counters.new(1, [:atomics])

      spawner_fn = fn _map_id, _npc_type, _box ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)
        # Each wave spawns 5 NPCs
        Enum.map(1..5, fn i -> n * 1000 + i end)
      end

      opts =
        default_opts(
          total_waves: 5,
          max_npcs: 5,
          spawn_interval_ms: 50,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)

      # After first wave, 5 alive = max_npcs, so next waves should be skipped
      Process.sleep(200)

      {:ok, info} = SiegeServer.siege_status(s, @map_id)
      # Only wave 1 should have actually spawned (5 NPCs = max)
      # Subsequent waves should skip because alive_count >= max_npcs
      assert info.alive_npcs == 5
      # waves_spawned increments only when NPCs are actually spawned
      assert info.waves_spawned == 1
    end

    test "stops spawning after total_waves reached", %{server: s} do
      call_count = :counters.new(1, [:atomics])

      spawner_fn = fn _map_id, _npc_type, _box ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)
        [n * 1000]
      end

      opts =
        default_opts(
          total_waves: 2,
          spawn_interval_ms: 30,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)

      # Wait more than enough for all waves + extras
      Process.sleep(200)

      {:ok, info} = SiegeServer.siege_status(s, @map_id)
      assert info.waves_spawned == 2
      assert info.total_spawned == 2
    end
  end

  # ── GM commands: start, stop, status ───────────────────────────────────

  describe "GM commands" do
    test "stop_siege cancels an active siege", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts())
      assert :ok = SiegeServer.stop_siege(s, @map_id)
      assert {:error, :no_siege} = SiegeServer.siege_status(s, @map_id)
    end

    test "stop_siege on non-existent siege returns error", %{server: s} do
      assert {:error, :no_siege} = SiegeServer.stop_siege(s, 999)
    end

    test "siege_status returns current info", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts())
      assert {:ok, info} = SiegeServer.siege_status(s, @map_id)
      assert info.map_id == @map_id
      assert info.wall_hp == @wall_hp
    end

    test "siege_status on non-existent siege returns error", %{server: s} do
      assert {:error, :no_siege} = SiegeServer.siege_status(s, 999)
    end

    test "list_sieges returns all active sieges", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, 1, default_opts())
      {:ok, _} = SiegeServer.start_siege(s, 2, default_opts())

      {:ok, sieges} = SiegeServer.list_sieges(s)
      assert length(sieges) == 2
      map_ids = Enum.map(sieges, & &1.map_id) |> Enum.sort()
      assert map_ids == [1, 2]
    end

    test "list_sieges returns empty when no sieges active", %{server: s} do
      assert {:ok, []} = SiegeServer.list_sieges(s)
    end

    test "stop_siege broadcasts message", %{server: s} do
      test_pid = self()

      opts =
        default_opts(
          broadcaster_fn: fn msg -> send(test_pid, {:broadcast, msg}) end
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      assert_receive {:broadcast, _start}

      SiegeServer.stop_siege(s, @map_id)
      assert_receive {:broadcast, msg}
      assert msg =~ "detenido"
    end

    test "new siege can be started after previous one ends", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts(wall_hp: 10))
      SiegeServer.damage_wall(s, @map_id, 10)

      # Siege ended, should be able to start a new one
      assert {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts())
    end
  end

  # ── Progress info ──────────────────────────────────────────────────────

  describe "progress info" do
    test "wall_health_percent returns correct percentage", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts(wall_hp: 200))

      assert {:ok, 100} = SiegeServer.wall_health_percent(s, @map_id)

      SiegeServer.damage_wall(s, @map_id, 50)
      assert {:ok, 75} = SiegeServer.wall_health_percent(s, @map_id)

      SiegeServer.damage_wall(s, @map_id, 100)
      assert {:ok, 25} = SiegeServer.wall_health_percent(s, @map_id)
    end

    test "wall_health_percent returns error for no siege", %{server: s} do
      assert {:error, :no_siege} = SiegeServer.wall_health_percent(s, 999)
    end

    test "time_percent returns error for no siege", %{server: s} do
      assert {:error, :no_siege} = SiegeServer.time_percent(s, 999)
    end

    test "time_percent returns value between 0 and 100", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts(duration_seconds: 600))
      {:ok, pct} = SiegeServer.time_percent(s, @map_id)
      # Should be close to 0 since we just started
      assert pct >= 0 and pct <= 100
    end
  end

  # ── Edge cases ─────────────────────────────────────────────────────────

  describe "edge cases" do
    test "damage_wall with zero amount does not change HP", %{server: s} do
      {:ok, _} = SiegeServer.start_siege(s, @map_id, default_opts())
      assert {:ok, @wall_hp} = SiegeServer.damage_wall(s, @map_id, 0)
    end

    test "multiple spawn boxes are used", %{server: s} do
      boxes_used = :counters.new(2, [:atomics])

      spawner_fn = fn _map_id, _npc_type, box ->
        if box == @spawn_box do
          :counters.add(boxes_used, 1, 1)
        else
          :counters.add(boxes_used, 2, 1)
        end

        [:rand.uniform(100_000)]
      end

      opts =
        default_opts(
          spawn_boxes: [@spawn_box, @spawn_box_2],
          total_waves: 100,
          spawn_interval_ms: 5,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      Process.sleep(1000)

      # With 100 waves and random selection, both boxes should have been used
      box1_count = :counters.get(boxes_used, 1)
      box2_count = :counters.get(boxes_used, 2)
      assert box1_count > 0
      assert box2_count > 0
    end

    test "scoreboard with custom score values", %{server: s} do
      counter = :counters.new(1, [:atomics])

      spawner_fn = fn _map_id, _npc_type, _box ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        [n * 100 + 1, n * 100 + 2]
      end

      opts =
        default_opts(
          total_waves: 5,
          spawn_interval_ms: 20,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      Process.sleep(100)

      # Player 1 kills NPC with score 5
      {:ok, _} = SiegeServer.record_kill(s, @map_id, 1, "Fighter", 201, 5)
      # Player 2 kills NPC with score 10
      {:ok, _} = SiegeServer.record_kill(s, @map_id, 2, "Mage", 202, 10)

      {:ok, [first, second]} = SiegeServer.get_scoreboard(s, @map_id)
      assert first.char_id == 2
      assert first.score == 10
      assert second.char_id == 1
      assert second.score == 5
    end

    test "record_kill on non-existent siege returns error", %{server: s} do
      assert {:error, :no_siege} =
               SiegeServer.record_kill(s, 999, 1, "Hero", 1001)
    end

    test "get_scoreboard on non-existent siege returns error", %{server: s} do
      assert {:error, :no_siege} = SiegeServer.get_scoreboard(s, 999)
    end

    test "spawner_fn returning empty list does not crash", %{server: s} do
      spawner_fn = fn _map_id, _npc_type, _box -> [] end

      opts =
        default_opts(
          total_waves: 2,
          spawn_interval_ms: 30,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      Process.sleep(100)

      {:ok, info} = SiegeServer.siege_status(s, @map_id)
      assert info.waves_spawned == 2
      assert info.total_spawned == 0
      assert info.alive_npcs == 0
    end

    test "siege end result includes full state snapshot", %{server: s} do
      spawner_fn = fn _map_id, _npc_type, _box -> [7001] end

      opts =
        default_opts(
          total_waves: 1,
          spawn_interval_ms: 30,
          wall_hp: 500,
          spawner_fn: spawner_fn
        )

      {:ok, _} = SiegeServer.start_siege(s, @map_id, opts)
      Process.sleep(80)

      {:siege_ended, result} = SiegeServer.record_kill(s, @map_id, 1, "Hero", 7001)

      assert result.outcome == :defenders_win
      assert result.map_id == @map_id
      assert result.wall_hp == 500
      assert result.max_wall_hp == 500
      assert result.total_killed == 1
      assert result.total_spawned == 1
      assert length(result.scoreboard) == 1
      assert length(result.rewards) == 1
    end
  end
end
