defmodule Arena.NpcAiEffectsTest do
  @moduledoc """
  Adversarial and edge-case tests for the NPC AI effects system.
  Focuses on verifying the effect tuples returned by tick/1 and
  the robustness of dispatch_effects/2.
  """
  use ExUnit.Case, async: true

  alias Arena.NpcAi
  alias Arena.Entity.NpcEntity
  alias Arena.Data.NpcDef

  import Arena.Test.MapStateFactory

  @test_map_id 998

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Insert a hostile, mobile NPC definition for testing
    test_npc_def = %NpcDef{
      id: 560,
      name: "TestEffectsNpc",
      hostile: true,
      attackable: true,
      movement: 2,
      min_hp: 100,
      max_hp: 100,
      min_hit: 10,
      max_hit: 20,
      def: 0,
      give_exp: 50,
      intervalo_ataque: 500,
      intervalo_movimiento: 200,
      intervalo_respawn: 60,
      poder_ataque: 999,
      lanza_spells: 0,
      spells: []
    }

    # Insert a static, non-hostile NPC definition
    passive_npc_def = %NpcDef{
      id: 561,
      name: "TestPassiveNpc",
      hostile: false,
      attackable: false,
      movement: 1,
      min_hp: 100,
      max_hp: 100,
      min_hit: 0,
      max_hit: 0,
      def: 0,
      give_exp: 0,
      intervalo_ataque: 2000,
      intervalo_movimiento: 500,
      intervalo_respawn: 60,
      poder_ataque: 0,
      lanza_spells: 0,
      spells: []
    }

    :ets.insert(:arena_game_data, {{:npc, 560}, test_npc_def})
    :ets.insert(:arena_game_data, {{:npc, 561}, passive_npc_def})

    # Load a fully-walkable 100x100 test map into TileGrid NIF
    tiles = List.duplicate(0, 100 * 100)
    TileGrid.load_map(@test_map_id, tiles)

    on_exit(fn -> TileGrid.unload_map(@test_map_id) end)

    :ok
  end

  # ---- Helpers ----

  defp make_npc(overrides) do
    %NpcEntity{
      npc_id: Keyword.get(overrides, :npc_id, 560),
      instance_id: Keyword.get(overrides, :instance_id, 1),
      char_index: Keyword.get(overrides, :char_index, 100),
      x: Keyword.get(overrides, :x, 50),
      y: Keyword.get(overrides, :y, 50),
      hp: Keyword.get(overrides, :hp, 100),
      max_hp: Keyword.get(overrides, :max_hp, 100),
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
      buffs: []
    }
  end

  # ---- Tests: tick/1 effect tuples ----

  describe "tick/1 with empty NPC map" do
    test "returns {state, []} with no NPCs" do
      state = map_state(map_id: @test_map_id, npcs_live: %{}, players: %{})
      {new_state, effects} = NpcAi.tick(state)

      assert effects == []
      assert new_state.npcs_live == %{}
    end

    test "returns {state, []} with no NPCs but some players" do
      player = make_player([])
      state = map_state(map_id: @test_map_id, npcs_live: %{}, players: %{7 => player}, sessions: %{7 => self()})
      {_state, effects} = NpcAi.tick(state)

      assert effects == []
    end
  end

  describe "tick/1 respawn effects" do
    test "dead NPC with expired respawn_at produces broadcast_visible effect" do
      now = System.monotonic_time(:millisecond)

      npc = make_npc(alive: false, respawn_at: now - 1000, x: 50, y: 50, spawn_x: 50, spawn_y: 50)
      # No players — respawns still happen via process_respawns short-circuit path
      state = map_state(map_id: @test_map_id, npcs_live: %{1 => npc}, players: %{})

      {new_state, effects} = NpcAi.tick(state)

      # NPC should be alive again
      assert new_state.npcs_live[1].alive == true
      # Should have at least one broadcast_visible effect (the NPC creation packet)
      assert Enum.any?(effects, fn
        {:broadcast_visible, _x, _y, _raw} -> true
        _ -> false
      end), "Expected at least one broadcast_visible effect for NPC respawn, got: #{inspect(effects)}"
    end

    test "dead NPC with future respawn_at produces no effects" do
      now = System.monotonic_time(:millisecond)

      npc = make_npc(alive: false, respawn_at: now + 60_000)
      state = map_state(map_id: @test_map_id, npcs_live: %{1 => npc}, players: %{})

      {new_state, effects} = NpcAi.tick(state)

      assert effects == []
      assert new_state.npcs_live[1].alive == false
    end

    test "dead NPC with nil respawn_at (pet-style) produces no effects" do
      npc = make_npc(alive: false, respawn_at: nil)
      state = map_state(map_id: @test_map_id, npcs_live: %{1 => npc}, players: %{})

      {_state, effects} = NpcAi.tick(state)
      assert effects == []
    end
  end

  describe "tick/1 movement effects" do
    test "NPC chasing target produces broadcast_visible movement effect" do
      # Place NPC 3 tiles away from player (within aggro range, not adjacent)
      npc = make_npc(x: 50, y: 50, spawn_x: 50, spawn_y: 50)
      player = make_player(x: 53, y: 50)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      {new_state, effects} = NpcAi.tick(state)

      # NPC should have moved (x should increase toward player)
      assert new_state.npcs_live[1].x > 50, "NPC should have moved toward player"

      # There should be a broadcast_visible effect for the movement
      move_effects = Enum.filter(effects, fn
        {:broadcast_visible, _x, _y, _raw} -> true
        _ -> false
      end)

      assert length(move_effects) >= 1, "Expected at least one broadcast_visible for movement"
    end

    test "NPC that cannot move (blocked next_move_at) produces no movement effects" do
      far_future = System.monotonic_time(:millisecond) + 999_999_999

      npc = make_npc(x: 50, y: 50, next_move_at: far_future)
      player = make_player(x: 53, y: 50)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      {new_state, effects} = NpcAi.tick(state)

      # NPC should NOT have moved
      assert new_state.npcs_live[1].x == 50

      # No broadcast_visible movement effects (may have swing if adjacent — but it's not)
      move_effects = Enum.filter(effects, fn
        {:broadcast_visible, _x, _y, _raw} -> true
        _ -> false
      end)

      assert move_effects == []
    end
  end

  describe "tick/1 attack effects" do
    test "NPC attacking adjacent player produces swing broadcast and send_to_session on hit" do
      # Seed RNG for determinism — ensures the hit roll succeeds
      :rand.seed(:exsss, {1, 2, 3})

      # NPC adjacent to player, ready to attack (next_attack_at in far past)
      # Use high poder_ataque (999) to guarantee hit (clamped to 90%)
      npc = make_npc(x: 50, y: 50, target_id: 7)
      player = make_player(x: 51, y: 50, hp: 300, max_hp: 300, agi: 1, level: 1)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      # Single tick — NPC has next_attack_at in far past, so it will attack once
      {_new_state, effects} = NpcAi.tick(state)

      # Should always have a swing broadcast_visible effect
      swing_effects = Enum.filter(effects, fn
        {:broadcast_visible, _x, _y, _raw} -> true
        _ -> false
      end)

      assert length(swing_effects) >= 1, "Expected swing broadcast_visible effect from NPC attack"

      # With seeded RNG and 90% hit chance, we expect send_to_session effects
      session_effects = Enum.filter(effects, fn
        {:send_to_session, 7, _raw} -> true
        _ -> false
      end)

      assert length(session_effects) > 0,
             "Expected send_to_session effects for damage/hp update"
    end

    test "NPC swing always produces broadcast_visible even on miss" do
      # Seed RNG to force a miss (find a seed where uniform(100) > 90)
      # With 90% hit rate, we just check that swing broadcast always appears
      npc = make_npc(x: 50, y: 50, target_id: 7)
      player = make_player(x: 51, y: 50, hp: 300, max_hp: 300, agi: 1, level: 1)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      {_new_state, effects} = NpcAi.tick(state)

      # Swing broadcast should always appear regardless of hit/miss
      broadcast_effects = Enum.filter(effects, fn
        {:broadcast_visible, _x, _y, _raw} -> true
        _ -> false
      end)

      assert length(broadcast_effects) >= 1, "Swing broadcast_visible should always appear"
    end
  end

  describe "dispatch_effects/2" do
    test "empty effects list does not crash and returns :ok" do
      state = map_state(map_id: @test_map_id, players: %{}, sessions: %{})

      # dispatch_effects returns the result of Enum.each, which is :ok
      result = NpcAi.dispatch_effects(state, [])
      assert result == :ok
    end

    test "mixed effects list is processed without error" do
      player = make_player([])

      state =
        map_state(
          map_id: @test_map_id,
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      # Only use effect types that don't require full entity fields.
      # broadcast_character_change requires body_id etc. — test it separately.
      effects = [
        {:broadcast_visible, 50, 50, <<1, 2, 3>>},
        {:send_to_session, 7, <<4, 5, 6>>}
      ]

      # Should not raise
      result = NpcAi.dispatch_effects(state, effects)
      assert result == :ok
    end

    test "broadcast_character_change effect is processed without error" do
      # Build a player-like entity with all fields needed by broadcast_character_change
      entity = %{
        char_index: 200,
        x: 50,
        y: 50,
        body_id: 1,
        head_id: 1,
        heading: 3,
        weapon_id: 0,
        shield_id: 0,
        helmet_id: 0,
        hp: 100,
        max_hp: 100,
        name: "TestPlayer",
        criminal: false,
        privileges: 0,
        dead: false,
        invisible: false,
        equipment: %{}
      }

      state =
        map_state(
          map_id: @test_map_id,
          players: %{7 => make_player([])},
          sessions: %{7 => self()}
        )

      result = NpcAi.dispatch_effects(state, [{:broadcast_character_change, entity}])
      assert result == :ok
    end

    test "send_to_session delivers message to the session process" do
      player = make_player([])

      state =
        map_state(
          map_id: @test_map_id,
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      raw = <<99, 100, 101>>
      NpcAi.dispatch_effects(state, [{:send_to_session, 7, raw}])

      assert_receive {:send_raw, ^raw}, 500
    end

    test "send_to_session with missing char_id does not crash" do
      state = map_state(map_id: @test_map_id, players: %{}, sessions: %{})

      # char_id 999 does not exist in sessions
      result = NpcAi.dispatch_effects(state, [{:send_to_session, 999, <<1, 2, 3>>}])
      assert result == :ok
    end
  end

  describe "edge: NPC with no target" do
    test "tick does not produce attack effects when NPC has no target" do
      npc = make_npc(x: 50, y: 50, target_id: nil)
      # Player far enough that aggro won't trigger (beyond aggro_range of 10)
      player = make_player(x: 80, y: 80)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      {_state, effects} = NpcAi.tick(state)

      # No send_to_session effects (which indicate attacks)
      session_effects = Enum.filter(effects, fn
        {:send_to_session, _, _} -> true
        _ -> false
      end)

      assert session_effects == [], "No attack effects expected when NPC has no target and player out of range"
    end

    test "passive NPC never acquires target or produces attack effects" do
      npc = make_npc(npc_id: 561, x: 50, y: 50)
      player = make_player(x: 51, y: 50)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      {new_state, effects} = NpcAi.tick(state)

      assert new_state.npcs_live[1].target_id == nil, "Passive NPC should not acquire a target"

      session_effects = Enum.filter(effects, fn
        {:send_to_session, _, _} -> true
        _ -> false
      end)

      assert session_effects == [], "Passive NPC should not produce attack effects"
    end
  end

  describe "edge: NPC with invalid target_id (player left map)" do
    test "NPC clears target when player is not on map" do
      # NPC has target_id pointing to a player that doesn't exist in state
      npc = make_npc(x: 50, y: 50, target_id: 999)
      player = make_player(char_id: 7, x: 80, y: 80)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      {new_state, effects} = NpcAi.tick(state)

      # Target should be cleared since player 999 doesn't exist
      assert new_state.npcs_live[1].target_id != 999,
             "NPC should clear invalid target_id, got: #{inspect(new_state.npcs_live[1].target_id)}"

      # Should not crash, and should not produce attack effects for the invalid target
      invalid_session_effects = Enum.filter(effects, fn
        {:send_to_session, 999, _} -> true
        _ -> false
      end)

      assert invalid_session_effects == [], "No effects should be sent to nonexistent player 999"
    end

    test "NPC does not crash with target_id of recently departed player" do
      # NPC targeting player 42 who is no longer in state at all
      npc = make_npc(x: 50, y: 50, target_id: 42)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{},
          sessions: %{}
        )

      # With no players, tick short-circuits to process_respawns only.
      # But the NPC is alive so it won't be processed in respawns.
      # This should return cleanly with no effects.
      {new_state, effects} = NpcAi.tick(state)

      # NPC is still alive, target_id is unchanged (since no player processing occurred)
      assert new_state.npcs_live[1].alive == true
      assert effects == []
    end

    test "NPC clears stale target and re-acquires on next tick" do
      # NPC targets player 999 (gone), but player 7 is within aggro range
      npc = make_npc(x: 50, y: 50, target_id: 999)
      player = make_player(char_id: 7, x: 52, y: 50)

      state =
        map_state(
          map_id: @test_map_id,
          npcs_live: %{1 => npc},
          players: %{7 => player},
          sessions: %{7 => self()}
        )

      # First tick: clears invalid target 999
      {state_after_1, _effects} = NpcAi.tick(state)
      npc_after_1 = state_after_1.npcs_live[1]
      assert npc_after_1.target_id != 999,
             "NPC should clear invalid target 999, got: #{inspect(npc_after_1.target_id)}"

      # Second tick: hostile NPC should re-acquire player 7 within aggro range
      {state_after_2, _effects} = NpcAi.tick(state_after_1)
      npc_after_2 = state_after_2.npcs_live[1]
      assert npc_after_2.target_id == 7,
             "NPC should re-acquire nearby player 7 on next tick, got: #{inspect(npc_after_2.target_id)}"
    end
  end
end
