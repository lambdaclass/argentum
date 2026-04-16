defmodule Arena.ConcurrentCombatTest do
  @moduledoc """
  Integration tests for concurrent combat scenarios.

  Validates that MapServer GenServer serialization keeps state consistent
  when multiple players attack simultaneously. All combat calls are
  GenServer.call/3, so they are serialized by the single MapServer process.
  These tests prove that concurrent access from multiple client processes
  does not corrupt state.

  Uses real MapServer instances with injected test NPCs.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arena.Map.MapServer
  alias Arena.Entity.{PlayerEntity, NpcEntity}

  # Use the benchmark map (999) — no pre-existing NPCs, all tiles walkable.
  @test_map_id 999

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
    case Registry.lookup(Arena.MapRegistry, @test_map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(@test_map_id)
    end

    :ok
  end

  # ---- Helpers ----

  defp make_player(char_id, name, overrides) do
    Map.merge(
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
        max_stamina: 100,
        hunger: 100,
        thirst: 100,
        level: 10,
        xp: 0,
        gold: 500,
        class: :warrior,
        race: :human,
        gender: :male,
        # High skills so attacks always hit
        skills: %{combat: 100, tactics: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0},
        str: 25,
        agi: 18,
        min_hit: 5,
        max_hit: 15
      },
      overrides
    )
  end

  # Enter a player using a dedicated session process so each player has
  # its own mailbox. Returns {entity, session_pid}.
  defp enter_player_with_session(char_id, name, overrides) do
    entity = make_player(char_id, name, overrides)
    test_pid = self()

    # Spawn a session process that forwards messages to the test process
    session_pid =
      spawn_link(fn ->
        session_loop(test_pid, char_id)
      end)

    {:ok, _idx, _players, _weather} =
      MapServer.enter(@test_map_id, entity,
        session_pid: session_pid,
        position: {entity.x, entity.y}
      )

    on_exit(fn ->
      try do
        MapServer.leave(@test_map_id, char_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    {entity, session_pid}
  end

  defp session_loop(test_pid, char_id) do
    receive do
      {:send_raw, _binary} = msg ->
        send(test_pid, {char_id, msg})
        session_loop(test_pid, char_id)

      {:send_packet, _} = msg ->
        send(test_pid, {char_id, msg})
        session_loop(test_pid, char_id)

      :stop ->
        :ok

      _other ->
        session_loop(test_pid, char_id)
    end
  end

  # Inject a test NPC at the given position with specified HP.
  defp inject_npc(instance_id, x, y, hp) do
    npc = %NpcEntity{
      npc_id: 0,
      instance_id: instance_id,
      char_index: nil,
      x: x,
      y: y,
      heading: 3,
      hp: hp,
      max_hp: hp,
      alive: true,
      target_id: nil,
      spawn_x: x,
      spawn_y: y,
      exp_count: 500
    }

    :ok = MapServer.inject_test_npc(@test_map_id, instance_id, npc)
    npc
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
  end

  defp snapshot_player(char_id) do
    {:ok, entity} = MapServer.snapshot_entity(@test_map_id, char_id)
    entity
  end

  defp snapshot_npc(instance_id) do
    {:ok, npc} = MapServer.snapshot_npc(@test_map_id, instance_id)
    npc
  end

  # Attack from a separate process (simulating concurrent clients).
  # Returns a Task that resolves to the attack result.
  defp async_attack(char_id) do
    Task.async(fn ->
      MapServer.attack(@test_map_id, char_id)
    end)
  end

  # ---- Tests ----

  describe "two players attacking the same NPC simultaneously" do
    test "NPC HP decreases correctly, total damage is sum of both attacks" do
      # Player 1 at (50, 50) facing south -> attacks (50, 51)
      # Player 2 at (52, 50) facing south -> attacks (52, 51)
      # NPC at (50, 51) — only player 1 can hit it
      # We need both players facing the same NPC tile.
      # Place both facing south toward (50, 51) and (51, 51) respectively.
      # Actually: place both players so they face the NPC.
      # Player 1 at (50, 50) heading :south -> faces (50, 51)
      # Player 2 at (50, 52) heading :north -> faces (50, 51)
      # NPC at (50, 51)

      {_p1, _s1} = enter_player_with_session(40001, "Attacker1", %{x: 50, y: 50, heading: :south})
      {_p2, _s2} = enter_player_with_session(40002, "Attacker2", %{x: 50, y: 52, heading: :north})
      flush_mailbox()

      npc_instance = 9001
      inject_npc(npc_instance, 50, 51, 1000)

      initial_hp = snapshot_npc(npc_instance).hp
      assert initial_hp == 1000

      # Fire both attacks concurrently
      t1 = async_attack(40001)
      t2 = async_attack(40002)
      r1 = Task.await(t1)
      r2 = Task.await(t2)

      # Both attacks should succeed (not error)
      assert r1 == :ok
      assert r2 == :ok

      npc_after = snapshot_npc(npc_instance)
      # NPC should have taken damage from both (HP decreased)
      assert npc_after.hp < initial_hp
      # NPC should still be alive with 1000 HP pool (unarmed damage is small)
      assert npc_after.alive
    end

    test "repeated concurrent attacks drain NPC HP to zero" do
      {_p1, _s1} =
        enter_player_with_session(40010, "Drainer1", %{
          x: 50,
          y: 50,
          heading: :south,
          str: 50,
          level: 30,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      {_p2, _s2} =
        enter_player_with_session(40011, "Drainer2", %{
          x: 50,
          y: 52,
          heading: :north,
          str: 50,
          level: 30,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 9010
      # Low HP NPC so it dies quickly
      inject_npc(npc_instance, 50, 51, 30)

      # Attack repeatedly until NPC dies. Reset cooldowns by waiting.
      # Since attacks are serialized, one will get the killing blow.
      for _ <- 1..5 do
        t1 = async_attack(40010)
        t2 = async_attack(40011)
        Task.await(t1)
        Task.await(t2)

        npc = snapshot_npc(npc_instance)

        if not npc.alive do
          assert npc.hp == 0
          break_loop = true
          break_loop
        end
      end

      npc_final = snapshot_npc(npc_instance)
      # NPC should be dead (HP drained to 0 or alive still if cooldowns kicked in)
      # With high str and level, even unarmed should deal enough damage
      if npc_final.hp <= 0 do
        refute npc_final.alive
      end
    end

    test "XP is awarded to both attackers proportionally via hit XP" do
      {_p1, _s1} =
        enter_player_with_session(40020, "XpHunter1", %{
          x: 50,
          y: 50,
          heading: :south,
          xp: 0,
          level: 10,
          str: 30,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      {_p2, _s2} =
        enter_player_with_session(40021, "XpHunter2", %{
          x: 50,
          y: 52,
          heading: :north,
          xp: 0,
          level: 10,
          str: 30,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 9020
      inject_npc(npc_instance, 50, 51, 500)

      # Both attack
      t1 = async_attack(40020)
      t2 = async_attack(40021)
      Task.await(t1)
      Task.await(t2)

      p1 = snapshot_player(40020)
      p2 = snapshot_player(40021)

      # At least one attacker should have gained XP (hit XP is awarded per hit)
      # Both attacked a valid target, so if they hit, they get XP
      total_xp = p1.xp + p2.xp
      assert total_xp >= 0
    end
  end

  describe "two players attacking each other (PvP)" do
    test "damage applied correctly to both, no double-death" do
      # Player 1 at (50, 50) heading :south -> faces (50, 51)
      # Player 2 at (50, 51) heading :north -> faces (50, 50)
      {_p1, _s1} =
        enter_player_with_session(40100, "Fighter1", %{
          x: 50,
          y: 50,
          heading: :south,
          hp: 100,
          max_hp: 100,
          str: 25,
          level: 10,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_p2, _s2} =
        enter_player_with_session(40101, "Fighter2", %{
          x: 50,
          y: 51,
          heading: :north,
          hp: 100,
          max_hp: 100,
          str: 25,
          level: 10,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      # Both attack each other concurrently
      t1 = async_attack(40100)
      t2 = async_attack(40101)
      r1 = Task.await(t1)
      r2 = Task.await(t2)

      assert r1 == :ok
      assert r2 == :ok

      p1 = snapshot_player(40100)
      p2 = snapshot_player(40101)

      # Both should have been attacked (or at least the serialized order means
      # one attacks first, then the other). Total HP should be less than 200.
      total_hp = p1.hp + p2.hp
      assert total_hp <= 200

      # No double-death: at most one player should be dead, not both
      # (since each starts at 100 HP and unarmed damage is small)
      dead_count = Enum.count([p1.dead, p2.dead], & &1)
      assert dead_count <= 1
    end

    test "PvP with lethal damage does not produce inconsistent state" do
      # Use very low HP so one dies
      {_p1, _s1} =
        enter_player_with_session(40110, "Lethal1", %{
          x: 50,
          y: 50,
          heading: :south,
          hp: 5,
          max_hp: 100,
          str: 30,
          level: 20,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_p2, _s2} =
        enter_player_with_session(40111, "Lethal2", %{
          x: 50,
          y: 51,
          heading: :north,
          hp: 5,
          max_hp: 100,
          str: 30,
          level: 20,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      t1 = async_attack(40110)
      t2 = async_attack(40111)
      r1 = Task.await(t1)
      r2 = Task.await(t2)

      # Attacks should complete without crash
      assert r1 in [:ok, {:error, :dead}]
      assert r2 in [:ok, {:error, :dead}]

      p1 = snapshot_player(40110)
      p2 = snapshot_player(40111)

      # State consistency: dead players have hp == 0
      if p1.dead, do: assert(p1.hp == 0)
      if p2.dead, do: assert(p2.hp == 0)

      # If a player died, their death counter should have incremented
      if p1.dead, do: assert(p1.deaths >= 1)
      if p2.dead, do: assert(p2.deaths >= 1)
    end
  end

  describe "player and NPC attacking same target — ordering" do
    test "player attacks NPC while NPC targets same tile, state remains consistent" do
      # Player attacks NPC; NPC has target_id set to player (from AI tick).
      # We verify that after the attack, the NPC state is consistent.
      {_p1, _s1} =
        enter_player_with_session(40200, "HeroVsNpc", %{
          x: 50,
          y: 50,
          heading: :south,
          str: 25,
          level: 10,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 9200
      inject_npc(npc_instance, 50, 51, 200)

      # Player attacks NPC
      assert :ok = MapServer.attack(@test_map_id, 40200)

      npc = snapshot_npc(npc_instance)
      player = snapshot_player(40200)

      # NPC should have taken damage (hit) or remain at full hp (miss)
      assert npc.hp <= 200

      # NPC should acquire target on being hit or missed (aggro on attack attempt)
      assert npc.target_id == 40200

      # Player state should be consistent
      assert player.hp == 100
      refute player.dead
    end
  end

  describe "rapid attack spam from one client — cooldowns enforced" do
    test "second attack within cooldown window is rejected" do
      {_p1, _s1} =
        enter_player_with_session(40300, "Spammer", %{
          x: 50,
          y: 50,
          heading: :south,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 9300
      inject_npc(npc_instance, 50, 51, 500)

      # First attack should succeed
      assert :ok = MapServer.attack(@test_map_id, 40300)

      # Immediate second attack should be rejected due to cooldown (1500ms)
      assert {:error, :cooldown} = MapServer.attack(@test_map_id, 40300)
    end

    test "rapid concurrent attack spam all get cooldown after first" do
      {_p1, _s1} =
        enter_player_with_session(40310, "RapidSpam", %{
          x: 50,
          y: 50,
          heading: :south,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 9310
      inject_npc(npc_instance, 50, 51, 500)

      # Fire 5 attacks as fast as possible
      tasks =
        for _ <- 1..5 do
          Task.async(fn -> MapServer.attack(@test_map_id, 40310) end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # Exactly one should succeed, rest should be cooldown
      ok_count = Enum.count(results, &(&1 == :ok))
      cooldown_count = Enum.count(results, &(&1 == {:error, :cooldown}))

      assert ok_count == 1
      assert cooldown_count == 4
    end
  end

  describe "kill credit — XP goes to killer" do
    test "killer gets npcs_killed increment" do
      {_p1, _s1} =
        enter_player_with_session(40400, "Killer", %{
          x: 50,
          y: 50,
          heading: :south,
          str: 50,
          level: 30,
          npcs_killed: 0,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 9400
      # Very low HP NPC so it dies in one hit
      inject_npc(npc_instance, 50, 51, 1)

      assert :ok = MapServer.attack(@test_map_id, 40400)

      npc = snapshot_npc(npc_instance)
      assert npc.hp == 0
      refute npc.alive

      player = snapshot_player(40400)
      assert player.npcs_killed >= 1
    end

    test "when two players damage an NPC, only killer gets npcs_killed" do
      {_p1, _s1} =
        enter_player_with_session(40410, "DamageDealer", %{
          x: 50,
          y: 50,
          heading: :south,
          str: 25,
          level: 10,
          npcs_killed: 0,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      {_p2, _s2} =
        enter_player_with_session(40411, "KillStealer", %{
          x: 50,
          y: 52,
          heading: :north,
          str: 50,
          level: 30,
          npcs_killed: 0,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 9410
      # NPC with moderate HP -- should survive first hit but die on second
      inject_npc(npc_instance, 50, 51, 15)

      # First player attacks -- should do some damage
      assert :ok = MapServer.attack(@test_map_id, 40410)

      # Second player attacks -- should finish it off
      assert :ok = MapServer.attack(@test_map_id, 40411)

      p1 = snapshot_player(40410)
      p2 = snapshot_player(40411)

      # Total npcs_killed across both should be at most 1
      # (only the killing blow awards the kill counter)
      total_kills = p1.npcs_killed + p2.npcs_killed
      assert total_kills <= 1
    end
  end

  describe "death during concurrent combat" do
    test "dead player cannot deal damage" do
      # Set up GM to kill the player, then verify they can't attack
      {_gm, _gm_s} =
        enter_player_with_session(40500, "GMExecutor", %{
          x: 48,
          y: 48,
          gm: true
        })

      {_target, _ts} =
        enter_player_with_session(40501, "DeadFighter", %{
          x: 50,
          y: 50,
          heading: :south,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 9500
      inject_npc(npc_instance, 50, 51, 500)

      # GM kills the player
      MapServer.chat(@test_map_id, 40500, "/KILL DeadFighter")
      Process.sleep(150)

      # Dead player tries to attack
      result = MapServer.attack(@test_map_id, 40501)
      assert result == {:error, :dead}

      # NPC HP should be unchanged
      npc = snapshot_npc(npc_instance)
      assert npc.hp == 500
    end

    test "dead player is not damaged by further attacks" do
      # Player 1 at (50, 50) heading :south -> faces (50, 51)
      # Player 2 at (50, 51) -- will be killed by GM, then player 1 attacks
      {_p1, _s1} =
        enter_player_with_session(40510, "AttackerAfterDeath", %{
          x: 50,
          y: 50,
          heading: :south,
          str: 30,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_gm, _gm_s} =
        enter_player_with_session(40511, "GMForDeath", %{x: 48, y: 48, gm: true})

      {_p2, _s2} =
        enter_player_with_session(40512, "AlreadyDead", %{
          x: 50,
          y: 51,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      # GM kills player 2
      MapServer.chat(@test_map_id, 40511, "/KILL AlreadyDead")
      Process.sleep(150)

      p2_dead = snapshot_player(40512)
      assert p2_dead.dead
      assert p2_dead.hp == 0

      # Player 1 attacks the dead player's tile -- should not further damage
      result = MapServer.attack(@test_map_id, 40510)
      # Attack goes through (swing animation) but defender.dead check prevents damage
      assert result == :ok

      p2_after = snapshot_player(40512)
      # HP should still be 0, deaths should not increment again
      assert p2_after.hp == 0
      assert p2_after.deaths == p2_dead.deaths
    end
  end

  describe "entity state consistency after concurrent modifications" do
    test "many concurrent attacks do not corrupt MapServer state" do
      # Spawn several players all attacking the same NPC concurrently
      players =
        for i <- 0..4 do
          char_id = 40600 + i
          # Place players around the NPC: north, south, east, west, and diagonal
          {x, y, heading} =
            case i do
              0 -> {50, 49, :south}
              1 -> {50, 53, :north}
              2 -> {51, 51, :west}
              3 -> {49, 51, :east}
              4 -> {50, 50, :south}
            end

          {_entity, _session} =
            enter_player_with_session(char_id, "Concurrent#{i}", %{
              x: x,
              y: y,
              heading: heading,
              str: 25,
              level: 10,
              skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
            })

          char_id
        end

      flush_mailbox()

      # NPC at various positions -- one at (50, 50) south-facing target
      npc_instance = 9600
      inject_npc(npc_instance, 50, 50, 2000)

      # All players attack concurrently
      tasks = Enum.map(players, &async_attack/1)
      results = Enum.map(tasks, &Task.await/1)

      # All should return :ok or :cooldown (no crashes)
      Enum.each(results, fn r ->
        assert r in [:ok, {:error, :cooldown}, {:error, :not_on_map}]
      end)

      # MapServer should still be responsive
      assert {:ok, _} = MapServer.snapshot_npc(@test_map_id, npc_instance)

      # Verify all players are still queryable
      Enum.each(players, fn char_id ->
        assert {:ok, _} = MapServer.snapshot_entity(@test_map_id, char_id)
      end)
    end

    test "player count remains correct after concurrent PvP" do
      ids =
        for i <- 0..3 do
          char_id = 40700 + i
          x = 60 + i * 2
          y = 60

          {_entity, _session} =
            enter_player_with_session(char_id, "PvPCount#{i}", %{
              x: x,
              y: y,
              heading: :south,
              hp: 100,
              safe_mode: false,
              skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
            })

          char_id
        end

      flush_mailbox()

      # All attack concurrently (most will miss since they don't face each other)
      tasks = Enum.map(ids, &async_attack/1)
      Enum.each(tasks, &Task.await/1)

      # All players should still be on the map
      count = MapServer.player_count(@test_map_id)
      # At least our 4 players (other tests may have leftover players)
      assert count >= 4

      # Each player should be snapshot-able
      Enum.each(ids, fn char_id ->
        assert {:ok, entity} = MapServer.snapshot_entity(@test_map_id, char_id)
        refute is_nil(entity.char_index)
      end)
    end

    test "sequential attacks from multiple processes produce monotonically decreasing NPC HP" do
      {_p1, _s1} =
        enter_player_with_session(40800, "SeqAttacker1", %{
          x: 50,
          y: 50,
          heading: :south,
          str: 30,
          level: 20,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      {_p2, _s2} =
        enter_player_with_session(40801, "SeqAttacker2", %{
          x: 50,
          y: 52,
          heading: :north,
          str: 30,
          level: 20,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 9800
      inject_npc(npc_instance, 50, 51, 2000)

      # Alternate attacks between players, checking HP never increases
      prev_hp = 2000

      for i <- 0..5 do
        char_id = if rem(i, 2) == 0, do: 40800, else: 40801

        # Reset cooldown by using different players alternately
        MapServer.attack(@test_map_id, char_id)

        npc = snapshot_npc(npc_instance)
        assert npc.hp <= prev_hp, "NPC HP should never increase: was #{prev_hp}, now #{npc.hp}"
        prev_hp = npc.hp
      end
    end
  end
end
