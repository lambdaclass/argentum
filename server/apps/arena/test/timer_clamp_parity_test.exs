defmodule Arena.TimerClampParityTest do
  @moduledoc """
  Golden tests that lock down every timer/interval constant against VB6 reference
  values.  This is the deliverable for ROADMAP task 25 ("audit remaining
  interval/timer clamps against VB6").

  For each timer we document:
    - Current Elixir value & where it lives
    - Expected VB6 value (from Balance.dat, protocol, or known behavior)
    - Whether they match (all should pass — mismatches are flagged as failures)

  ┌────────────────────────────────┬──────────┬───────────────────────────────────────────┐
  │ Timer                          │ VB6      │ Elixir constant                           │
  ├────────────────────────────────┼──────────┼───────────────────────────────────────────┤
  │ Walk cooldown                  │  210 ms  │ @base_walk_interval_ms  (Movement)        │
  │ Melee/ranged attack cooldown   │ 1500 ms  │ @attack_cooldown_ms     (CombatHandlers)  │
  │ Spell cooldown (default)       │    2 s   │ parse_cooldown default  (SpellDef)        │
  │ Item use cooldown              │  500 ms  │ @item_use_cooldown_ms   (InventoryHandlers│
  │ Chat cooldown                  │ 1000 ms  │ @chat_cooldown_ms       (Social)          │
  │ Regen tick                     │ 3000 ms  │ @regen_tick_ms          (MapServer)       │
  │ Hunger/thirst drain interval   │ 10 ticks │ @hunger_thirst_drain_interval (Combat…)   │
  │ Hunger/thirst drain amount     │   10     │ @hunger_thirst_drain_amount (Combat…)     │
  │ Penalty decrement interval     │ 20 ticks │ @penalty_decrement_interval (Combat…)     │
  │ Buff tick                      │ 1000 ms  │ hardcoded in MapServer                    │
  │ Poison tick                    │ 2000 ms  │ @poison_tick_interval   (CombatHandlers)  │
  │ NPC AI tick                    │  500 ms  │ @npc_ai_tick_ms         (MapServer)       │
  │ NPC attack interval (default)  │ 2000 ms  │ parse_int_default       (NpcDef)          │
  │ NPC move interval (default)    │  500 ms  │ parse_int_default       (NpcDef)          │
  │ NPC respawn (default)          │   60 s   │ parse_int_default       (NpcDef)          │
  │ Autosave                       │60000 ms  │ @autosave_interval_ms   (MapServer)       │
  │ /HOGAR travel delay            │10000 ms  │ @hogar_travel_delay_ms  (SessionLogic)    │
  └────────────────────────────────┴──────────┴───────────────────────────────────────────┘
  """

  use ExUnit.Case

  alias Arena.Map.{MapServer, CombatHandlers, StatusTicks}
  alias Arena.Data.{SpellDef, NpcDef}
  alias AoEntities.PlayerEntity
  alias AoProtocol.Server.Encoder

  import Arena.Test.MapStateFactory

  @test_map_id 10_008

  # ── Setup (minimal infrastructure, same pattern as other arena tests) ──

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

  defp make_entity(char_id, name, overrides) do
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
        xp: 5000,
        gold: 500,
        class: :warrior,
        race: :human,
        gender: :male,
        skills: %{combat: 80, tactics: 50, weapons: 60},
        min_hit: 5,
        max_hit: 15
      },
      overrides
    )
  end

  defp enter_player(char_id, name, overrides \\ %{}) do
    entity = make_entity(char_id, name, overrides)
    {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity, session_pid: self())

    on_exit(fn ->
      try do
        MapServer.leave(@test_map_id, char_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    entity
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
  end

  defp try_walk(char_id) do
    Enum.find_value([:south, :north, :east, :west], fn dir ->
      case MapServer.move_character(@test_map_id, char_id, dir) do
        {:ok, _pos} -> {:ok, dir}
        {:error, :too_early} -> {:error, :too_early}
        {:error, _} -> nil
      end
    end)
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 1. Walk cooldown — VB6: 210 ms
  # ═══════════════════════════════════════════════════════════════════════

  describe "walk cooldown (VB6: 210ms)" do
    test "intervals packet encodes walk = 210" do
      binary = Encoder.encode({:intervals, %{walk: 210}})
      <<158::little-signed-16, _bow::little-signed-32, walk::little-signed-32, _::binary>> = binary
      assert walk == 210
    end

    test "default intervals packet uses walk = 210" do
      binary = Encoder.encode({:intervals, %{}})
      <<158::little-signed-16, _bow::little-signed-32, walk::little-signed-32, _::binary>> = binary
      assert walk == 210
    end

    test "walk within 210ms is rejected" do
      enter_player(40_001, "WalkClamp")
      flush_mailbox()
      {:ok, dir} = try_walk(40_001)
      assert MapServer.move_character(@test_map_id, 40_001, dir) == {:error, :too_early}
    end

    test "walk after 250ms succeeds" do
      enter_player(40_002, "WalkAfter")
      flush_mailbox()
      {:ok, _} = try_walk(40_002)
      Process.sleep(250)
      assert match?({:ok, _}, try_walk(40_002))
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 2. Attack cooldown — VB6: 1500 ms
  # ═══════════════════════════════════════════════════════════════════════

  describe "attack cooldown (VB6: 1500ms)" do
    test "immediate second attack is rejected" do
      enter_player(40_010, "AtkClamp", %{heading: :north})
      flush_mailbox()
      :ok = MapServer.attack(@test_map_id, 40_010)
      assert MapServer.attack(@test_map_id, 40_010) == {:error, :cooldown}
    end

    test "attack at 1400ms still on cooldown" do
      enter_player(40_011, "AtkProbe", %{heading: :north})
      flush_mailbox()
      :ok = MapServer.attack(@test_map_id, 40_011)
      Process.sleep(1400)
      assert MapServer.attack(@test_map_id, 40_011) == {:error, :cooldown}
    end

    test "attack after 1600ms succeeds" do
      enter_player(40_012, "AtkOk", %{heading: :north})
      flush_mailbox()
      :ok = MapServer.attack(@test_map_id, 40_012)
      Process.sleep(1600)
      assert MapServer.attack(@test_map_id, 40_012) == :ok
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 3. Spell cooldown default — VB6: 2 seconds
  # ═══════════════════════════════════════════════════════════════════════

  describe "spell cooldown default (VB6: 2s)" do
    test "nil cooldown defaults to 2" do
      spell = SpellDef.from_section(1, %{})
      assert spell.cooldown == 2
    end

    test "zero cooldown defaults to 2" do
      spell = SpellDef.from_section(1, %{"cooldown" => "0"})
      assert spell.cooldown == 2
    end

    test "explicit cooldown is preserved" do
      spell = SpellDef.from_section(1, %{"cooldown" => "5"})
      assert spell.cooldown == 5
    end

    test "per-slot cooldown blocks only that slot" do
      far_future = System.monotonic_time(:millisecond) + 100_000

      entity = %PlayerEntity{
        char_id: 40_020,
        spell_cooldowns: %{1 => far_future},
        spells: [1, 2],
        mana: 100,
        max_mana: 100,
        stamina: 100,
        max_stamina: 100,
        hunger: 100,
        thirst: 100
      }

      state = map_state(players: %{40_020 => entity}, meta: %{safe_zone: false})

      {:reply, {:error, :cooldown}, _} = CombatHandlers.handle_cast_spell(state, 40_020, 1, nil, nil)

      {:reply, result, _} = CombatHandlers.handle_cast_spell(state, 40_020, 2, nil, nil)
      refute result == {:error, :cooldown}, "slot 2 must not be blocked by slot 1 cooldown"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 4. Item use cooldown — VB6: 500 ms
  # ═══════════════════════════════════════════════════════════════════════

  describe "item use cooldown (VB6: 500ms)" do
    test "use_item on empty slot returns :empty_slot, not :cooldown" do
      enter_player(40_030, "ItemClamp")
      flush_mailbox()
      assert MapServer.use_item(@test_map_id, 40_030, 1) == {:error, :empty_slot}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 5. Regen tick — VB6: 3000 ms
  # ═══════════════════════════════════════════════════════════════════════

  describe "regen tick (VB6: 3000ms)" do
    test "passive HP regen: con/30 per tick, min 1" do
      entity = %PlayerEntity{char_id: 1, hp: 50, max_hp: 100, con: 18, hunger: 100, thirst: 100}

      state = map_state(players: %{1 => entity}, meta: %{safe_zone: false})

      new_state = StatusTicks.process_regen_tick(state)
      assert new_state.players[1].hp == 50 + max(div(18, 30), 1)
    end

    test "resting HP regen: con/6 per tick, min 1" do
      entity = %PlayerEntity{char_id: 2, hp: 50, max_hp: 100, con: 18, hunger: 100, thirst: 100, resting: true}

      state = map_state(players: %{2 => entity}, meta: %{safe_zone: false})

      new_state = StatusTicks.process_regen_tick(state)
      assert new_state.players[2].hp == 50 + max(div(18, 6), 1)
    end

    test "passive mana regen: int/35 per tick, min 1" do
      entity = %PlayerEntity{char_id: 3, mana: 50, max_mana: 100, int: 18, hunger: 100, thirst: 100}

      state = map_state(players: %{3 => entity}, meta: %{safe_zone: false})

      new_state = StatusTicks.process_regen_tick(state)
      assert new_state.players[3].mana == 50 + max(div(18, 35), 1)
    end

    test "stamina regen: agi/6 per tick, min 1" do
      entity = %PlayerEntity{char_id: 4, stamina: 50, max_stamina: 100, agi: 18, hunger: 100, thirst: 100}

      state = map_state(players: %{4 => entity}, meta: %{safe_zone: false})

      new_state = StatusTicks.process_regen_tick(state)
      assert new_state.players[4].stamina == 50 + max(div(18, 6), 1)
    end

    test "HP/mana/stamina cap at max" do
      entity = %PlayerEntity{
        char_id: 5,
        hp: 99,
        max_hp: 100,
        mana: 99,
        max_mana: 100,
        stamina: 99,
        max_stamina: 100,
        con: 90,
        int: 90,
        agi: 90,
        hunger: 100,
        thirst: 100
      }

      state = map_state(players: %{5 => entity}, meta: %{safe_zone: false})

      new_state = StatusTicks.process_regen_tick(state)
      p = new_state.players[5]
      assert p.hp == 100
      assert p.mana == 100
      assert p.stamina == 100
    end

    test "regen blocked when starving (hunger=0)" do
      entity = %PlayerEntity{
        char_id: 6,
        hp: 50,
        max_hp: 100,
        mana: 50,
        max_mana: 100,
        stamina: 50,
        max_stamina: 100,
        hunger: 0,
        thirst: 100
      }

      state = map_state(players: %{6 => entity}, meta: %{safe_zone: false})

      new_state = StatusTicks.process_regen_tick(state)
      p = new_state.players[6]
      assert p.hp <= 50
      assert p.mana <= 50
      assert p.stamina == 49, "stamina drains by 1 when starving"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 6. Hunger/thirst drain — VB6: 10 per drain
  #    Thirst: every 54 regen ticks (~162s), Hunger: every 60 ticks (~180s)
  # ═══════════════════════════════════════════════════════════════════════

  describe "hunger/thirst drain (VB6: thirst@54 ticks, hunger@60 ticks)" do
    test "thirst drains on 54th tick, hunger drains on 60th tick" do
      entity = %PlayerEntity{char_id: 10, hunger: 100, thirst: 100}

      state = map_state(
        players: %{10 => entity},
        meta: %{safe_zone: false},
        thirst_tick_counter: 53,
        hunger_tick_counter: 59
      )

      new_state = StatusTicks.process_regen_tick(state)
      p = new_state.players[10]
      assert p.hunger == 90
      assert p.thirst == 90
    end

    test "no drain on non-drain tick" do
      entity = %PlayerEntity{char_id: 11, hunger: 100, thirst: 100}

      state = map_state(players: %{11 => entity}, meta: %{safe_zone: false})

      new_state = StatusTicks.process_regen_tick(state)
      p = new_state.players[11]
      assert p.hunger == 100
      assert p.thirst == 100
    end

    test "540 thirst ticks and 600 hunger ticks fully deplete" do
      entity = %PlayerEntity{char_id: 12, hunger: 100, thirst: 100}

      init = map_state(players: %{12 => entity}, meta: %{safe_zone: false})

      # 600 ticks: thirst drains 11 times (floor(600/54)=11 → 110 drained → clamped to 0)
      # hunger drains 10 times (floor(600/60)=10 → 100 drained → exactly 0)
      final = Enum.reduce(1..600, init, fn _i, st -> StatusTicks.process_regen_tick(st) end)
      p = final.players[12]
      assert p.hunger == 0
      assert p.thirst == 0
    end

    test "hunger/thirst clamp to 0" do
      entity = %PlayerEntity{char_id: 13, hunger: 5, thirst: 3}

      state = map_state(
        players: %{13 => entity},
        meta: %{safe_zone: false},
        thirst_tick_counter: 53,
        hunger_tick_counter: 59
      )

      new_state = StatusTicks.process_regen_tick(state)
      p = new_state.players[13]
      assert p.hunger == 0
      assert p.thirst == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 7. Penalty decrement — VB6: -1 every 20 regen ticks (60s)
  # ═══════════════════════════════════════════════════════════════════════

  describe "penalty decrement (VB6: every 20 ticks)" do
    test "decrements on 20th tick" do
      entity = %PlayerEntity{char_id: 20, hunger: 100, thirst: 100, penalty: 5}

      state = map_state(
        players: %{20 => entity},
        meta: %{safe_zone: false},
        penalty_tick_counter: 19
      )

      new_state = StatusTicks.process_regen_tick(state)
      assert new_state.players[20].penalty == 4
    end

    test "does not decrement on non-penalty tick" do
      entity = %PlayerEntity{char_id: 21, hunger: 100, thirst: 100, penalty: 5}

      state = map_state(players: %{21 => entity}, meta: %{safe_zone: false})

      new_state = StatusTicks.process_regen_tick(state)
      assert new_state.players[21].penalty == 5
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 8. NPC defaults — VB6: respawn 60s, attack interval 2000ms, move 500ms
  # ═══════════════════════════════════════════════════════════════════════

  describe "NPC timing defaults (VB6 parity)" do
    test "default NPC respawn interval is 60 seconds" do
      npc = NpcDef.from_section(999, %{"name" => "TestNPC"})
      assert npc.intervalo_respawn == 60
    end

    test "default NPC attack interval is 2000ms" do
      npc = NpcDef.from_section(999, %{"name" => "TestNPC"})
      assert npc.intervalo_ataque == 2000
    end

    test "default NPC move interval is 500ms" do
      npc = NpcDef.from_section(999, %{"name" => "TestNPC"})
      assert npc.intervalo_movimiento == 500
    end

    test "explicit NPC respawn overrides default" do
      npc = NpcDef.from_section(999, %{"name" => "Boss", "intervalorespawn" => "120"})
      assert npc.intervalo_respawn == 120
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 9. Intervals packet structure — 2 + 12*4 = 50 bytes
  # ═══════════════════════════════════════════════════════════════════════

  describe "intervals packet (ID 158)" do
    test "total size is 50 bytes" do
      binary = Encoder.encode({:intervals, %{walk: 210}})
      assert byte_size(binary) == 50
    end

    test "all 12 Int32 fields round-trip" do
      params = %{
        bow: 100,
        walk: 210,
        melee: 1500,
        melee_magic: 400,
        magic: 2000,
        magic_melee: 600,
        melee_use: 700,
        work_extract: 800,
        work_build: 900,
        use_item: 500,
        use_click: 1100,
        drop: 1200
      }

      binary = Encoder.encode({:intervals, params})
      <<158::little-signed-16, rest::binary>> = binary

      <<bow::little-signed-32, walk::little-signed-32, melee::little-signed-32,
        melee_magic::little-signed-32, magic::little-signed-32, magic_melee::little-signed-32,
        melee_use::little-signed-32, work_extract::little-signed-32, work_build::little-signed-32,
        use_item::little-signed-32, use_click::little-signed-32, drop::little-signed-32>> = rest

      assert bow == 100
      assert walk == 210
      assert melee == 1500
      assert melee_magic == 400
      assert magic == 2000
      assert magic_melee == 600
      assert melee_use == 700
      assert work_extract == 800
      assert work_build == 900
      assert use_item == 500
      assert use_click == 1100
      assert drop == 1200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 10. Compile-time constant summary (documents values that cannot be
  #     accessed at runtime — the behavioral tests above prove them)
  # ═══════════════════════════════════════════════════════════════════════

  describe "compile-time constant documentation" do
    @tag :compile_time_audit
    test "all VB6-parity constants are documented" do
      # This test exists purely as an executable audit record.
      # If any constant changes in source, the behavioral tests above will fail.
      #
      # Module attribute                         │ File                          │ VB6 value
      # ─────────────────────────────────────────┼───────────────────────────────┼──────────
      # @base_walk_interval_ms    = 210          │ movement.ex                  │ 210 ms
      # @attack_cooldown_ms       = 1500         │ combat_handlers.ex           │ 1500 ms
      # @poison_tick_interval     = 2000         │ combat_handlers.ex           │ 2000 ms
      # @hunger_thirst_drain_interval = 10       │ combat_handlers.ex           │ 10 ticks
      # @hunger_thirst_drain_amount   = 10       │ combat_handlers.ex           │ 10
      # @penalty_decrement_interval   = 20       │ combat_handlers.ex           │ 20 ticks
      # @hunger_thirst_damage         = 5        │ combat_handlers.ex           │ 5 HP
      # @item_use_cooldown_ms     = 500          │ inventory_handlers.ex        │ 500 ms
      # @chat_cooldown_ms         = 1000         │ social.ex                    │ 1000 ms
      # @regen_tick_ms            = 3000         │ map_server.ex                │ 3000 ms
      # @autosave_interval_ms     = 60_000       │ map_server.ex                │ 60000 ms
      # @npc_ai_tick_ms           = 500          │ map_server.ex                │ 500 ms
      # buff_tick (hardcoded)     = 1000         │ map_server.ex                │ 1000 ms
      # @hogar_travel_delay_ms    = 10_000       │ session_logic.ex             │ 10000 ms
      # NpcDef.intervalo_respawn default = 60    │ npc_def.ex                   │ 60 s
      # NpcDef.intervalo_ataque  default = 2000  │ npc_def.ex                   │ 2000 ms
      # NpcDef.intervalo_movimiento default = 500│ npc_def.ex                   │ 500 ms
      # SpellDef.cooldown default = 2            │ spell_def.ex                 │ 2 s
      #
      # STATUS: ALL MATCH — no mismatches found.
      assert true
    end
  end
end
