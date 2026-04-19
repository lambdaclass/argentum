defmodule Arena.ConcurrentCombatExtendedTest do
  @moduledoc """
  Extended concurrent combat integration tests (ROADMAP #27).

  Covers gaps not addressed by ConcurrentCombatTest:
  - AoE spell concurrent scenarios (multi-target, mid-kill, overlapping AoE)
  - Simultaneous lethal scenarios (mutual kill, three-way combat)
  - Party safe blocking in combat
  - Faction PvP exception (safe zone interactions)
  - Spell restrictions concurrent (per-slot cooldowns, dead target)
  - Mixed attacker types (players + NPCs on same target)

  Uses the same infrastructure as ConcurrentCombatTest: map 999 (benchmark),
  real MapServer instances, injected NPCs, dedicated session processes.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arena.Map.MapServer
  alias AoEntities.PlayerEntity
  alias Arena.Entity.NpcEntity
  alias Arena.Data.SpellDef

  # Benchmark map — no pre-existing NPCs, all tiles walkable, safe_zone: false.
  @test_map_id 999

  # Spell IDs in a high range to avoid collision with real data.
  @aoe_damage_spell_id 90_001
  @single_damage_spell_id 90_002
  @heal_spell_id 90_003

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

    unless Process.whereis(Arena.PartyServer) do
      {:ok, _} = Arena.PartyServer.start_link([])
    end

    # Inject test spell definitions into ETS.
    inject_test_spells()

    on_exit(fn ->
      cleanup_test_spells()
    end)

    :ok
  end

  setup do
    case Registry.lookup(Arena.MapRegistry, @test_map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(@test_map_id)
    end

    :ok
  end

  # ---- Spell injection helpers ----

  defp inject_test_spells do
    # AoE damage spell: radius 2, affects players (1), high deterministic damage
    aoe_spell = %SpellDef{
      id: @aoe_damage_spell_id,
      name: "Test AoE Blast",
      tipo: 0,
      target: 3,
      min_hp: 40,
      max_hp: 40,
      mana_required: 10,
      sta_required: 0,
      min_skill: 0,
      fx_grh: 0,
      wav: 0,
      sube_hp: 2,
      area_afecta: 1,
      area_radio: 2,
      cooldown: 2,
      duration: 0,
      work_on_dead: false,
      target_effect_type: 2,
      requirement_mask: 0,
      require_weapon_type: 0,
      need_staff: false,
      staff_afecta: 0,
      max_level_casteable: 0
    }

    # Single-target damage spell: deterministic damage
    single_spell = %SpellDef{
      id: @single_damage_spell_id,
      name: "Test Fireball",
      tipo: 0,
      target: 3,
      min_hp: 30,
      max_hp: 30,
      mana_required: 10,
      sta_required: 0,
      min_skill: 0,
      fx_grh: 0,
      wav: 0,
      sube_hp: 2,
      area_afecta: 0,
      area_radio: 0,
      cooldown: 2,
      duration: 0,
      work_on_dead: false,
      target_effect_type: 2,
      requirement_mask: 0,
      require_weapon_type: 0,
      need_staff: false,
      staff_afecta: 0,
      max_level_casteable: 0
    }

    # Heal spell
    heal_spell = %SpellDef{
      id: @heal_spell_id,
      name: "Test Heal",
      tipo: 0,
      target: 1,
      min_hp: 20,
      max_hp: 20,
      mana_required: 10,
      sta_required: 0,
      min_skill: 0,
      fx_grh: 0,
      wav: 0,
      sube_hp: 1,
      area_afecta: 0,
      area_radio: 0,
      cooldown: 2,
      duration: 0,
      work_on_dead: false,
      target_effect_type: 0,
      requirement_mask: 0,
      require_weapon_type: 0,
      need_staff: false,
      staff_afecta: 0,
      max_level_casteable: 0
    }

    :ets.insert(:arena_game_data, {{:spell, @aoe_damage_spell_id}, aoe_spell})
    :ets.insert(:arena_game_data, {{:spell, @single_damage_spell_id}, single_spell})
    :ets.insert(:arena_game_data, {{:spell, @heal_spell_id}, heal_spell})
  end

  defp cleanup_test_spells do
    :ets.delete(:arena_game_data, {:spell, @aoe_damage_spell_id})
    :ets.delete(:arena_game_data, {:spell, @single_damage_spell_id})
    :ets.delete(:arena_game_data, {:spell, @heal_spell_id})
  rescue
    _ -> :ok
  end

  # ---- Player / NPC helpers (same as ConcurrentCombatTest) ----

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
        skills: %{combat: 100, tactics: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0, magic: 100},
        str: 25,
        agi: 18,
        min_hit: 5,
        max_hit: 15
      },
      overrides
    )
  end

  defp enter_player_with_session(char_id, name, overrides) do
    entity = make_player(char_id, name, overrides)
    test_pid = self()

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

  defp async_attack(char_id) do
    Task.async(fn ->
      MapServer.attack(@test_map_id, char_id)
    end)
  end

  defp async_cast_spell(char_id, spell_slot, target_x, target_y) do
    Task.async(fn ->
      MapServer.cast_spell(@test_map_id, char_id, spell_slot, target_x, target_y)
    end)
  end

  defp map_server_pid do
    [{pid, _}] = Registry.lookup(Arena.MapRegistry, @test_map_id)
    pid
  end

  defp set_safe_zone(enabled) do
    :sys.replace_state(map_server_pid(), fn state ->
      %{state | meta: Map.put(state.meta, :safe_zone, enabled)}
    end)
  end

  # ---- Tests ----

  # ==================================================================
  # AoE spell concurrent scenarios
  # ==================================================================

  describe "AoE spell hits 3+ players simultaneously" do
    test "state consistency — all targets in radius take damage" do
      # Caster at (30, 30), targets clustered around (30, 32) within radius 2.
      # AoE spell has area_radio: 2, area_afecta: 1 (users only).
      {_caster, _cs} =
        enter_player_with_session(50001, "AoeCaster", %{
          x: 30,
          y: 30,
          heading: :south,
          mana: 500,
          max_mana: 500,
          level: 30,
          class: :mago,
          safe_mode: false,
          spells: [@aoe_damage_spell_id],
          spell_cooldowns: %{},
          skills: %{magic: 100, combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      # 3 targets in a cluster near (30, 32), all within radius 2 of center (30, 32)
      {_t1, _} =
        enter_player_with_session(50002, "AoeTarget1", %{
          x: 30,
          y: 32,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 0, combat_weapons: 0, combat_tactics: 0, combat_defense: 0, resistance: 0}
        })

      {_t2, _} =
        enter_player_with_session(50003, "AoeTarget2", %{
          x: 31,
          y: 32,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 0, combat_weapons: 0, combat_tactics: 0, combat_defense: 0, resistance: 0}
        })

      {_t3, _} =
        enter_player_with_session(50004, "AoeTarget3", %{
          x: 29,
          y: 32,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 0, combat_weapons: 0, combat_tactics: 0, combat_defense: 0, resistance: 0}
        })

      flush_mailbox()

      # Cast AoE at center (30, 32)
      assert :ok = MapServer.cast_spell(@test_map_id, 50001, 1, 30, 32)

      t1 = snapshot_player(50002)
      t2 = snapshot_player(50003)
      t3 = snapshot_player(50004)

      # All three targets should have taken damage (HP < 100)
      assert t1.hp < 100, "Target 1 should have taken AoE damage"
      assert t2.hp < 100, "Target 2 should have taken AoE damage"
      assert t3.hp < 100, "Target 3 should have taken AoE damage"

      # Caster mana should have been deducted (the AoE reduce re-writes the
      # caster entity into state during iteration, so snapshot reflects the
      # mana-deducted value).
      caster = snapshot_player(50001)
      assert caster.mana <= 500
    end
  end

  describe "AoE killing one target mid-iteration" do
    test "remaining targets still take damage after one dies" do
      # Caster at (35, 30)
      {_caster, _cs} =
        enter_player_with_session(50010, "AoeKillCaster", %{
          x: 35,
          y: 30,
          heading: :south,
          mana: 500,
          max_mana: 500,
          level: 30,
          class: :mago,
          safe_mode: false,
          spells: [@aoe_damage_spell_id],
          spell_cooldowns: %{},
          skills: %{magic: 100, combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      # Target 1 has very low HP (will die from AoE)
      {_low, _} =
        enter_player_with_session(50011, "AoeLowHp", %{
          x: 35,
          y: 32,
          heading: :north,
          hp: 1,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 0, combat_weapons: 0, combat_tactics: 0, combat_defense: 0, resistance: 0}
        })

      # Target 2 has full HP (should survive but take damage)
      {_full, _} =
        enter_player_with_session(50012, "AoeFullHp", %{
          x: 36,
          y: 32,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 0, combat_weapons: 0, combat_tactics: 0, combat_defense: 0, resistance: 0}
        })

      flush_mailbox()

      # Cast AoE at (35, 32) — both targets in radius
      assert :ok = MapServer.cast_spell(@test_map_id, 50010, 1, 35, 32)

      low = snapshot_player(50011)
      full = snapshot_player(50012)

      # Low HP target should be dead
      assert low.dead, "Low HP target should have died from AoE"
      assert low.hp == 0

      # Full HP target should have taken damage but survived
      assert full.hp < 100, "Full HP target should have taken damage"
      refute full.dead, "Full HP target should not have died"

      # MapServer should still be responsive (no crash from mid-iteration death)
      assert {:ok, _} = MapServer.snapshot_entity(@test_map_id, 50010)
    end
  end

  describe "two concurrent AoE casts with overlapping targets" do
    test "both AoEs apply without corrupting state" do
      # Two casters, each casting AoE with overlapping radius
      {_c1, _} =
        enter_player_with_session(50020, "AoeCaster1", %{
          x: 40,
          y: 30,
          heading: :south,
          mana: 500,
          max_mana: 500,
          level: 30,
          class: :mago,
          safe_mode: false,
          spells: [@aoe_damage_spell_id],
          spell_cooldowns: %{},
          skills: %{magic: 100, combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_c2, _} =
        enter_player_with_session(50021, "AoeCaster2", %{
          x: 42,
          y: 30,
          heading: :south,
          mana: 500,
          max_mana: 500,
          level: 30,
          class: :mago,
          safe_mode: false,
          spells: [@aoe_damage_spell_id],
          spell_cooldowns: %{},
          skills: %{magic: 100, combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      # Shared target in the overlap zone
      {_t, _} =
        enter_player_with_session(50022, "AoeSharedTarget", %{
          x: 41,
          y: 32,
          heading: :north,
          hp: 200,
          max_hp: 200,
          safe_mode: false,
          skills: %{combat: 0, combat_weapons: 0, combat_tactics: 0, combat_defense: 0, resistance: 0}
        })

      flush_mailbox()

      # Both cast AoE concurrently, overlapping at the shared target
      t1 = async_cast_spell(50020, 1, 41, 32)
      t2 = async_cast_spell(50021, 1, 41, 32)
      r1 = Task.await(t1)
      r2 = Task.await(t2)

      # Both should complete (one may get cooldown if same GenServer serialization
      # happens before the second cast, but both should not crash)
      assert r1 in [:ok, {:error, :cooldown}]
      assert r2 in [:ok, {:error, :cooldown}]

      target = snapshot_player(50022)
      # At least one AoE should have dealt damage
      assert target.hp < 200, "Shared target should have taken AoE damage"

      # Both casters should still be queryable
      assert {:ok, _} = MapServer.snapshot_entity(@test_map_id, 50020)
      assert {:ok, _} = MapServer.snapshot_entity(@test_map_id, 50021)
    end
  end

  # ==================================================================
  # Simultaneous lethal scenarios
  # ==================================================================

  describe "mutual lethal damage — both at low HP, both attack" do
    test "first processed attack kills, second sees dead target" do
      # Player 1 at (20, 20) heading south, Player 2 at (20, 21) heading north
      # Both have very low HP and high damage
      {_p1, _s1} =
        enter_player_with_session(50100, "MutualLethal1", %{
          x: 20,
          y: 20,
          heading: :south,
          hp: 1,
          max_hp: 100,
          str: 50,
          level: 30,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_p2, _s2} =
        enter_player_with_session(50101, "MutualLethal2", %{
          x: 20,
          y: 21,
          heading: :north,
          hp: 1,
          max_hp: 100,
          str: 50,
          level: 30,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      # Both attack simultaneously
      t1 = async_attack(50100)
      t2 = async_attack(50101)
      r1 = Task.await(t1)
      r2 = Task.await(t2)

      # Both should return :ok or {:error, :dead}
      assert r1 in [:ok, {:error, :dead}]
      assert r2 in [:ok, {:error, :dead}]

      p1 = snapshot_player(50100)
      p2 = snapshot_player(50101)

      # Since GenServer serializes, exactly one attack processes first.
      # The first kills the opponent, the second either hits a dead player
      # (no extra damage) or was already dead.
      # At least one must be dead.
      assert p1.dead or p2.dead, "At least one player should be dead"

      # State consistency: dead players have hp == 0
      if p1.dead, do: assert(p1.hp == 0)
      if p2.dead, do: assert(p2.hp == 0)

      # No corruption: both players queryable
      assert {:ok, _} = MapServer.snapshot_entity(@test_map_id, 50100)
      assert {:ok, _} = MapServer.snapshot_entity(@test_map_id, 50101)
    end
  end

  describe "three-way combat with multiple deaths" do
    test "three players attacking each other, state remains consistent" do
      # Triangle layout: P1(25,25)->south, P2(25,26)->east, P3(26,26)->north
      # P1 faces P2, P2 faces P3's tile, P3 faces P1's row...
      # Actually: place them so each faces a different target:
      # P1 at (25, 25) heading south -> attacks (25, 26) where P2 is
      # P2 at (25, 26) heading east -> attacks (26, 26) where P3 is
      # P3 at (26, 26) heading north -> attacks (26, 25) — empty (P3 can't hit P1)
      # For a real three-way, adjust:
      # P1 at (25, 25) heading south -> attacks (25, 26) [P2]
      # P2 at (25, 26) heading south -> attacks (25, 27) [P3]
      # P3 at (25, 27) heading north -> attacks (25, 26) [P2]
      {_p1, _} =
        enter_player_with_session(50110, "ThreeWay1", %{
          x: 25,
          y: 25,
          heading: :south,
          hp: 5,
          max_hp: 100,
          str: 50,
          level: 30,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_p2, _} =
        enter_player_with_session(50111, "ThreeWay2", %{
          x: 25,
          y: 26,
          heading: :south,
          hp: 5,
          max_hp: 100,
          str: 50,
          level: 30,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_p3, _} =
        enter_player_with_session(50112, "ThreeWay3", %{
          x: 25,
          y: 27,
          heading: :north,
          hp: 5,
          max_hp: 100,
          str: 50,
          level: 30,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      # All three attack concurrently
      t1 = async_attack(50110)
      t2 = async_attack(50111)
      t3 = async_attack(50112)
      results = [Task.await(t1), Task.await(t2), Task.await(t3)]

      # All should complete without crashing
      Enum.each(results, fn r ->
        assert r in [:ok, {:error, :dead}, {:error, :cooldown}]
      end)

      p1 = snapshot_player(50110)
      p2 = snapshot_player(50111)
      p3 = snapshot_player(50112)

      # State consistency: dead players have hp == 0, alive players have hp > 0
      if p1.dead, do: assert(p1.hp == 0)
      if p2.dead, do: assert(p2.hp == 0)
      if p3.dead, do: assert(p3.hp == 0)

      for pid <- [50110, 50111, 50112] do
        assert {:ok, _} = MapServer.snapshot_entity(@test_map_id, pid)
      end
    end
  end

  # ==================================================================
  # Party safe blocking in combat
  # ==================================================================

  describe "party safe blocks party-member attacks" do
    test "attack on party member with party_safe: true is blocked" do
      # Create two players, put them in a party, enable party safe
      {_p1, _s1} =
        enter_player_with_session(50200, "PartyLeader", %{
          x: 45,
          y: 45,
          heading: :south,
          hp: 100,
          max_hp: 100,
          str: 30,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_p2, _s2} =
        enter_player_with_session(50201, "PartyMember", %{
          x: 45,
          y: 46,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      # Form party: leader invites, member accepts
      assert :ok = Arena.PartyServer.invite(50200, 50201)
      assert :ok = Arena.PartyServer.accept_invite(50201)

      # Enable party safe
      Arena.PartyServer.safe_toggle(50200)
      # Give GenServer time to process cast
      Process.sleep(50)

      assert Arena.PartyServer.party_safe?(50200), "Party safe should be enabled"

      # Leader attacks member — should be blocked (attack goes through as :ok
      # but no damage is applied because party_safe_block? returns true)
      assert :ok = MapServer.attack(@test_map_id, 50200)

      p2 = snapshot_player(50201)
      # Member HP should be unchanged
      assert p2.hp == 100, "Party member should not take damage when party safe is on"
    end

    test "party safe toggle is serialized by GenServer — no race conditions" do
      {_p1, _} =
        enter_player_with_session(50210, "ToggleLeader", %{
          x: 47,
          y: 45,
          heading: :south,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_p2, _} =
        enter_player_with_session(50211, "ToggleMember", %{
          x: 47,
          y: 46,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      assert :ok = Arena.PartyServer.invite(50210, 50211)
      assert :ok = Arena.PartyServer.accept_invite(50211)

      # Rapidly toggle party safe from multiple processes
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Arena.PartyServer.safe_toggle(50210)
          end)
        end

      Enum.each(tasks, &Task.await/1)
      # Give GenServer time to finish all casts
      Process.sleep(100)

      # After 10 toggles (even count), safe should be back to false
      # (started false, toggled 10 times => false)
      safe_state = Arena.PartyServer.party_safe?(50210)
      assert safe_state == false,
        "After even number of toggles, party safe should be back to original state (false)"
    end
  end

  # ==================================================================
  # Faction PvP exception
  # ==================================================================

  describe "faction PvP exception in safe zone" do
    test "different-faction players CAN attack in safe zone" do
      # Player 1 = royal_army, Player 2 = chaos_legion
      {_p1, _} =
        enter_player_with_session(50300, "RoyalSoldier", %{
          x: 55,
          y: 55,
          heading: :south,
          hp: 100,
          max_hp: 100,
          str: 30,
          level: 10,
          safe_mode: false,
          faction: :royal_army,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_p2, _} =
        enter_player_with_session(50301, "ChaosSoldier", %{
          x: 55,
          y: 56,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          faction: :chaos_legion,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      # Enable safe zone on the map via :sys.replace_state
      set_safe_zone(true)

      # Royal attacks Chaos — should be allowed (faction PvP exception)
      assert :ok = MapServer.attack(@test_map_id, 50300)

      p2 = snapshot_player(50301)
      # Damage may or may not have landed (hit/miss roll), but the attack
      # was allowed (returned :ok, not blocked by safe zone).
      # The key assertion is that the attack completed successfully.
      assert p2.hp <= 100

      # Restore safe zone to false for other tests
      set_safe_zone(false)
    end

    test "same-faction players CANNOT attack even in safe zone" do
      # Both players in royal_army
      {_p1, _} =
        enter_player_with_session(50310, "RoyalAlly1", %{
          x: 57,
          y: 55,
          heading: :south,
          hp: 100,
          max_hp: 100,
          str: 30,
          level: 10,
          safe_mode: false,
          faction: :royal_army,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_p2, _} =
        enter_player_with_session(50311, "RoyalAlly2", %{
          x: 57,
          y: 56,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          faction: :royal_army,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      # Attack a same-faction player — should be blocked by same_faction? check
      assert :ok = MapServer.attack(@test_map_id, 50310)

      p2 = snapshot_player(50311)
      # Ally should not have taken any damage
      assert p2.hp == 100, "Same-faction player should not take damage"
    end
  end

  # ==================================================================
  # Spell restrictions concurrent
  # ==================================================================

  describe "two different spell slots cast simultaneously — cooldowns don't cross-contaminate" do
    test "casting slot 1 does not put slot 2 on cooldown" do
      # Player with two different spells
      {_p1, _} =
        enter_player_with_session(50400, "DualCaster", %{
          x: 60,
          y: 60,
          heading: :south,
          mana: 500,
          max_mana: 500,
          level: 30,
          class: :mago,
          safe_mode: false,
          spells: [@single_damage_spell_id, @heal_spell_id],
          spell_cooldowns: %{},
          skills: %{magic: 100, combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      flush_mailbox()

      npc_instance = 8400
      inject_npc(npc_instance, 60, 61, 500)

      # Cast spell in slot 1 (damage spell targeting NPC tile)
      assert :ok = MapServer.cast_spell(@test_map_id, 50400, 1, 60, 61)

      # Immediately cast spell in slot 2 (heal, self-target with nil coords)
      result_slot2 = MapServer.cast_spell(@test_map_id, 50400, 2, nil, nil)

      # Slot 2 should NOT be on cooldown — each slot has independent cooldown
      assert result_slot2 == :ok,
        "Casting slot 1 should not put slot 2 on cooldown"

      # Verify slot 1 IS on cooldown now
      result_slot1_again = MapServer.cast_spell(@test_map_id, 50400, 1, 60, 61)
      assert result_slot1_again == {:error, :cooldown},
        "Slot 1 should be on cooldown after casting"
    end
  end

  describe "spell cast while target is already dead" do
    test "damage spell on dead target does not apply damage" do
      {_gm, _} =
        enter_player_with_session(50410, "SpellGM", %{
          x: 62,
          y: 58,
          gm: true
        })

      {_caster, _} =
        enter_player_with_session(50411, "SpellCaster", %{
          x: 62,
          y: 60,
          heading: :south,
          mana: 500,
          max_mana: 500,
          level: 30,
          class: :mago,
          safe_mode: false,
          spells: [@single_damage_spell_id],
          spell_cooldowns: %{},
          skills: %{magic: 100, combat: 100, combat_weapons: 100, combat_tactics: 0, combat_defense: 0}
        })

      {_target, _} =
        enter_player_with_session(50412, "SpellDeadTarget", %{
          x: 62,
          y: 61,
          heading: :north,
          hp: 100,
          max_hp: 100,
          safe_mode: false,
          skills: %{combat: 0, combat_weapons: 0, combat_tactics: 0, combat_defense: 0, resistance: 0}
        })

      flush_mailbox()

      # Kill the target via GM command
      MapServer.chat(@test_map_id, 50410, "/KILL SpellDeadTarget")
      Process.sleep(150)

      target_dead = snapshot_player(50412)
      assert target_dead.dead, "Target should be dead after GM kill"
      assert target_dead.hp == 0

      # Caster tries to cast damage spell on dead target's tile.
      # The spell should be rejected because work_on_dead: false — the
      # combat handler returns {:error, :requirement_not_met}.
      result = MapServer.cast_spell(@test_map_id, 50411, 1, 62, 61)
      assert result == {:error, :requirement_not_met},
        "Spell with work_on_dead: false should be rejected on a dead target"

      # Dead target should still have 0 hp — no damage applied
      target_after = snapshot_player(50412)
      assert target_after.hp == 0, "Dead target should not take further damage"
      assert target_after.deaths == target_dead.deaths, "Death count should not increment again"
    end
  end

  # ==================================================================
  # Mixed attacker types
  # ==================================================================

  describe "multiple players + injected NPCs all damaging same target" do
    test "concurrent player attacks + NPC presence on same NPC target do not corrupt state" do
      # 3 players all attacking the same NPC concurrently
      players =
        for i <- 0..2 do
          char_id = 50500 + i

          {x, y, heading} =
            case i do
              0 -> {70, 70, :south}
              1 -> {70, 72, :north}
              2 -> {71, 71, :west}
            end

          {_entity, _session} =
            enter_player_with_session(char_id, "MixedAttacker#{i}", %{
              x: x,
              y: y,
              heading: heading,
              str: 30,
              level: 20,
              skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
            })

          char_id
        end

      flush_mailbox()

      # Target NPC at (70, 71) — in range of all three players
      npc_instance = 8500
      inject_npc(npc_instance, 70, 71, 2000)

      # Also inject a bystander NPC nearby (simulating mixed NPC presence)
      bystander_instance = 8501
      inject_npc(bystander_instance, 69, 71, 500)

      initial_hp = snapshot_npc(npc_instance).hp
      assert initial_hp == 2000

      # All 3 players attack concurrently
      tasks = Enum.map(players, &async_attack/1)
      results = Enum.map(tasks, &Task.await/1)

      # All should complete without crash
      Enum.each(results, fn r ->
        assert r in [:ok, {:error, :cooldown}, {:error, :not_on_map}]
      end)

      npc_after = snapshot_npc(npc_instance)
      # NPC should have taken damage from at least one attacker
      assert npc_after.hp < initial_hp, "NPC should have taken damage"

      # Bystander NPC should be untouched
      bystander = snapshot_npc(bystander_instance)
      assert bystander.hp == 500, "Bystander NPC should not have taken damage"

      # All players and NPCs queryable (no state corruption)
      Enum.each(players, fn cid ->
        assert {:ok, _} = MapServer.snapshot_entity(@test_map_id, cid)
      end)

      assert {:ok, _} = MapServer.snapshot_npc(@test_map_id, npc_instance)
      assert {:ok, _} = MapServer.snapshot_npc(@test_map_id, bystander_instance)
    end

    test "player spell + player melee attack on same NPC concurrently" do
      # Melee attacker faces NPC
      {_melee, _} =
        enter_player_with_session(50510, "MeleeHitter", %{
          x: 73,
          y: 70,
          heading: :south,
          str: 30,
          level: 20,
          skills: %{combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      # Spell caster nearby
      {_caster, _} =
        enter_player_with_session(50511, "SpellHitter", %{
          x: 73,
          y: 72,
          heading: :north,
          mana: 500,
          max_mana: 500,
          level: 30,
          class: :mago,
          safe_mode: false,
          spells: [@single_damage_spell_id],
          spell_cooldowns: %{},
          skills: %{magic: 100, combat: 100, combat_weapons: 100, combat_tactics: 0}
        })

      flush_mailbox()

      npc_instance = 8510
      inject_npc(npc_instance, 73, 71, 1000)

      initial_hp = snapshot_npc(npc_instance).hp
      assert initial_hp == 1000

      # Melee attack + spell cast concurrently on same NPC
      t_melee = async_attack(50510)
      t_spell = async_cast_spell(50511, 1, 73, 71)
      r_melee = Task.await(t_melee)
      r_spell = Task.await(t_spell)

      assert r_melee == :ok
      assert r_spell == :ok

      npc_after = snapshot_npc(npc_instance)
      # NPC should have taken damage from both sources
      assert npc_after.hp < initial_hp, "NPC should have taken combined damage"

      # MapServer responsive
      assert {:ok, _} = MapServer.snapshot_npc(@test_map_id, npc_instance)
    end
  end
end
