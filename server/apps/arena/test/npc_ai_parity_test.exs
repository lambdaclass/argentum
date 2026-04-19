defmodule Arena.NpcAiParityTest do
  @moduledoc """
  ROADMAP item #7: NPC AI edge-case parity tests.

  Tests for VB6 behaviors that are missing or incorrect in the current
  NPC AI implementation. Each test is written to FAIL against the current
  code, then the corresponding fix is applied.

  ## Gaps identified by code analysis

  1. **NPC poison on melee hit** — NpcDef.veneno is parsed but never used.
     VB6: NPCs with veneno > 0 poison the player on a successful melee hit.

  2. **NPC diagonal movement** — direction_toward() only moves on one axis.
     VB6: NPCs move diagonally toward their target when both dx and dy != 0.

  3. **Nearest-player tie-breaking** — find_nearest_player uses Manhattan
     distance for min_by but Chebyshev for range. VB6 uses Chebyshev for both.
  """
  use ExUnit.Case, async: true

  alias Arena.NpcAi
  alias Arena.Entity.NpcEntity
  alias Arena.Data.NpcDef

  import Arena.Test.MapStateFactory

  @test_map_id 997

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Hostile NPC with veneno (poison on melee hit)
    poison_npc_def = %NpcDef{
      id: 570,
      name: "TestPoisonNpc",
      hostile: true,
      attackable: true,
      movement: 2,
      min_hp: 200,
      max_hp: 200,
      min_hit: 10,
      max_hit: 20,
      def: 0,
      give_exp: 50,
      intervalo_ataque: 500,
      intervalo_movimiento: 200,
      intervalo_respawn: 60,
      poder_ataque: 999,
      veneno: 5,
      lanza_spells: 0,
      spells: []
    }

    # Hostile NPC without veneno (control)
    clean_npc_def = %NpcDef{
      id: 571,
      name: "TestCleanNpc",
      hostile: true,
      attackable: true,
      movement: 2,
      min_hp: 200,
      max_hp: 200,
      min_hit: 10,
      max_hit: 20,
      def: 0,
      give_exp: 50,
      intervalo_ataque: 500,
      intervalo_movimiento: 200,
      intervalo_respawn: 60,
      poder_ataque: 999,
      veneno: 0,
      lanza_spells: 0,
      spells: []
    }

    # Hostile mobile NPC for movement tests
    mobile_npc_def = %NpcDef{
      id: 572,
      name: "TestMobileNpc",
      hostile: true,
      attackable: true,
      movement: 2,
      min_hp: 200,
      max_hp: 200,
      min_hit: 10,
      max_hit: 20,
      def: 0,
      give_exp: 50,
      intervalo_ataque: 2000,
      intervalo_movimiento: 200,
      intervalo_respawn: 60,
      poder_ataque: 50,
      veneno: 0,
      lanza_spells: 0,
      spells: []
    }

    :ets.insert(:arena_game_data, {{:npc, 570}, poison_npc_def})
    :ets.insert(:arena_game_data, {{:npc, 571}, clean_npc_def})
    :ets.insert(:arena_game_data, {{:npc, 572}, mobile_npc_def})

    # Load a fully-walkable 100x100 test map into TileGrid NIF
    tiles = List.duplicate(0, 100 * 100)
    TileGrid.load_map(@test_map_id, tiles)

    on_exit(fn -> TileGrid.unload_map(@test_map_id) end)

    :ok
  end

  # ---- Helpers ----

  defp make_npc(overrides) do
    %NpcEntity{
      npc_id: Keyword.get(overrides, :npc_id, 571),
      instance_id: Keyword.get(overrides, :instance_id, 1),
      char_index: Keyword.get(overrides, :char_index, 100),
      x: Keyword.get(overrides, :x, 50),
      y: Keyword.get(overrides, :y, 50),
      hp: Keyword.get(overrides, :hp, 200),
      max_hp: Keyword.get(overrides, :max_hp, 200),
      alive: Keyword.get(overrides, :alive, true),
      target_id: Keyword.get(overrides, :target_id, nil),
      spawn_x: Keyword.get(overrides, :spawn_x, 50),
      spawn_y: Keyword.get(overrides, :spawn_y, 50),
      next_attack_at: Keyword.get(overrides, :next_attack_at, -1_000_000_000_000),
      next_move_at: Keyword.get(overrides, :next_move_at, -1_000_000_000_000),
      next_spell_at: Keyword.get(overrides, :next_spell_at, -1_000_000_000_000),
      respawn_at: Keyword.get(overrides, :respawn_at, nil),
      owner_id: Keyword.get(overrides, :owner_id, nil),
      returning_to_spawn: Keyword.get(overrides, :returning_to_spawn, false),
      exp_count: Keyword.get(overrides, :exp_count, 50)
    }
  end

  defp make_player(overrides) do
    %{
      char_id: Keyword.get(overrides, :char_id, 7),
      char_index: Keyword.get(overrides, :char_index, 200),
      name: "TestPlayer",
      x: Keyword.get(overrides, :x, 55),
      y: Keyword.get(overrides, :y, 50),
      dead: Keyword.get(overrides, :dead, false),
      invisible: Keyword.get(overrides, :invisible, false),
      oculto: false,
      hp: Keyword.get(overrides, :hp, 300),
      max_hp: Keyword.get(overrides, :max_hp, 300),
      level: Keyword.get(overrides, :level, 1),
      class: Keyword.get(overrides, :class, :warrior),
      agi: Keyword.get(overrides, :agi, 1),
      skills: %{combat_tactics: 1},
      equipment: %{},
      paralyzed: false,
      poisoned: Keyword.get(overrides, :poisoned, false),
      buffs: Keyword.get(overrides, :buffs, [])
    }
  end

  # ================================================================
  # Gap 1: NPC poison on melee hit (veneno field)
  # ================================================================

  describe "NPC poison on melee hit (VB6 veneno)" do
    test "NPC with veneno > 0 poisons player on successful melee hit" do
      # Seed RNG for deterministic hit (poder_ataque: 999 guarantees ~90% hit)
      :rand.seed(:exsss, {1, 2, 3})

      # Poison NPC (veneno: 5) adjacent to player, ready to attack
      npc = make_npc(npc_id: 570, x: 50, y: 50, target_id: 7)
      player = make_player(x: 51, y: 50, hp: 300, max_hp: 300, poisoned: false, buffs: [])

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      # Run multiple ticks to ensure at least one hit lands
      state =
        Enum.reduce(1..10, state, fn _, s ->
          {s, _effects} = NpcAi.tick(s)
          s
        end)

      player_after = state.players[7]

      # VB6: NPC with veneno > 0 poisons the player on melee hit
      assert player_after.poisoned == true,
             "Player should be poisoned after being hit by an NPC with veneno > 0"

      # Verify there's a poison buff with expiry
      poison_buff = Enum.find(player_after.buffs, &(&1.type == :poisoned))

      assert poison_buff != nil,
             "Player should have a :poisoned buff after NPC melee hit with veneno > 0"
    end

    test "NPC with veneno == 0 does NOT poison player on melee hit" do
      :rand.seed(:exsss, {1, 2, 3})

      # Clean NPC (veneno: 0) adjacent to player
      npc = make_npc(npc_id: 571, x: 50, y: 50, target_id: 7)
      player = make_player(x: 51, y: 50, hp: 300, max_hp: 300, poisoned: false, buffs: [])

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      # Run multiple ticks
      state =
        Enum.reduce(1..10, state, fn _, s ->
          {s, _effects} = NpcAi.tick(s)
          s
        end)

      player_after = state.players[7]

      refute player_after.poisoned,
             "Player should NOT be poisoned by an NPC with veneno == 0"
    end

    test "NPC poison sends console message to poisoned player" do
      :rand.seed(:exsss, {1, 2, 3})

      npc = make_npc(npc_id: 570, x: 50, y: 50, target_id: 7)
      player = make_player(x: 51, y: 50, hp: 300, max_hp: 300, poisoned: false, buffs: [])

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      # Run ticks and collect effects
      {_state, effects} =
        Enum.reduce(1..10, {state, []}, fn _, {s, acc_effects} ->
          {s, new_effects} = NpcAi.tick(s)
          {s, acc_effects ++ new_effects}
        end)

      # Look for a send_to_session effect with a poison message
      poison_msg_effects =
        Enum.filter(effects, fn
          {:send_to_session, 7, raw} when is_binary(raw) ->
            # The raw packet should contain "envenenado" or poison-related text
            String.contains?(raw, "envenenado") or String.contains?(raw, "veneno")

          _ ->
            false
        end)

      assert length(poison_msg_effects) > 0,
             "Should send a poison notification to the player via effects"
    end
  end

  # ================================================================
  # Gap 2: NPC diagonal movement
  # ================================================================

  describe "NPC diagonal movement (VB6 parity)" do
    test "NPC moves diagonally toward target when both dx and dy are nonzero" do
      # NPC at (50,50), target at (55,55) — 5 tiles diagonal
      # VB6: NPC should move to (51,51) — one step diagonally
      # Current: NPC moves to (51,50) or (50,51) — only one axis
      npc = make_npc(npc_id: 572, x: 50, y: 50, target_id: 7, spawn_x: 50, spawn_y: 50)
      player = make_player(x: 55, y: 55)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      {state, _effects} = NpcAi.tick(state)
      npc_after = state.npcs_live[1]

      # VB6 diagonal: both x and y should change in a single step
      assert npc_after.x == 51 and npc_after.y == 51,
             "NPC should move diagonally toward target. " <>
               "Expected (51,51), got (#{npc_after.x},#{npc_after.y})"
    end

    test "NPC moves only on one axis when target is axis-aligned" do
      # NPC at (50,50), target at (55,50) — target is directly east
      npc = make_npc(npc_id: 572, x: 50, y: 50, target_id: 7, spawn_x: 50, spawn_y: 50)
      player = make_player(x: 55, y: 50)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      {state, _effects} = NpcAi.tick(state)
      npc_after = state.npcs_live[1]

      # When target is on the same axis, movement should be axis-aligned
      assert npc_after.x == 51 and npc_after.y == 50,
             "NPC should move east when target is directly east. " <>
               "Expected (51,50), got (#{npc_after.x},#{npc_after.y})"
    end

    test "NPC reaches diagonal target faster with diagonal movement" do
      # NPC at (50,50), target at (55,55)
      # With diagonal: 5 moves to reach adjacent.
      # Without (axis-only): 9 moves to reach adjacent.
      # Since tick uses System.monotonic_time and movement has a cooldown,
      # we reset next_move_at before each tick to simulate enough time passing.
      npc = make_npc(npc_id: 572, x: 50, y: 50, target_id: 7, spawn_x: 50, spawn_y: 50)
      player = make_player(x: 55, y: 55)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      # Run 5 ticks, resetting next_move_at before each to bypass cooldown
      state =
        Enum.reduce(1..5, state, fn _, s ->
          npc_cur = s.npcs_live[1]
          npc_cur = %{npc_cur | next_move_at: -1_000_000_000_000}
          s = put_in(s.npcs_live[1], npc_cur)
          {s, _effects} = NpcAi.tick(s)
          s
        end)

      npc_after = state.npcs_live[1]

      # With diagonal movement, NPC should be at or adjacent to (55,55) after 5 moves
      dist = max(abs(npc_after.x - 55), abs(npc_after.y - 55))

      assert dist <= 1,
             "With diagonal movement, NPC should reach target in ~5 moves. " <>
               "NPC at (#{npc_after.x},#{npc_after.y}), distance #{dist}"
    end
  end

  # ================================================================
  # Gap 3: Nearest-player Chebyshev tie-breaking
  # ================================================================

  describe "nearest player uses Chebyshev distance (VB6 parity)" do
    test "NPC targets closer-Chebyshev player over closer-Manhattan player" do
      # Player A at (54,54): Chebyshev=4, Manhattan=8
      # Player B at (57,50): Chebyshev=7, Manhattan=7
      # Manhattan sorting: B wins (7 < 8) => targets player B (char_id 8)
      # Chebyshev sorting: A wins (4 < 7) => targets player A (char_id 7)
      # VB6 uses Chebyshev, so the correct target is player A.

      npc = make_npc(npc_id: 572, x: 50, y: 50, target_id: nil, spawn_x: 50, spawn_y: 50)
      player_a = make_player(char_id: 7, x: 54, y: 54)
      player_b = make_player(char_id: 8, char_index: 201, x: 57, y: 50)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player_a, 8 => player_b},
          sessions: %{7 => self(), 8 => self()}
        )

      {state, _effects} = NpcAi.tick(state)
      npc_after = state.npcs_live[1]

      # With Chebyshev distance, player A at (54,54) is closer (distance 4)
      # than player B at (57,50) (distance 7)
      assert npc_after.target_id == 7,
             "NPC should target player at Chebyshev distance 4 over player at Manhattan distance 7. " <>
               "Got target: #{inspect(npc_after.target_id)}"
    end

    test "NPC targets closer-Chebyshev player in asymmetric scenario" do
      # Player A at (53,53): Chebyshev=3, Manhattan=6
      # Player B at (55,50): Chebyshev=5, Manhattan=5
      # Manhattan sorting: B wins (5 < 6) => targets player B (char_id 8)
      # Chebyshev sorting: A wins (3 < 5) => targets player A (char_id 7)

      npc = make_npc(npc_id: 572, x: 50, y: 50, target_id: nil, spawn_x: 50, spawn_y: 50)
      player_a = make_player(char_id: 7, x: 53, y: 53)
      player_b = make_player(char_id: 8, char_index: 201, x: 55, y: 50)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player_a, 8 => player_b},
          sessions: %{7 => self(), 8 => self()}
        )

      {state, _effects} = NpcAi.tick(state)
      npc_after = state.npcs_live[1]

      assert npc_after.target_id == 7,
             "NPC should target player at Chebyshev distance 3 over player at distance 5. " <>
               "Got target: #{inspect(npc_after.target_id)}"
    end
  end
end
