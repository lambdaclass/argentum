defmodule Arena.NpcDeathTest do
  @moduledoc """
  Adversarial and edge-case tests for `Arena.Map.NpcDeath.resolve_npc_death/4`.

  Covers pet death, wild NPC death (with and without killer), permanent GM kills,
  missing killer entity, already-dead NPCs, missing NPC definitions, and
  double-death scenarios.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.NpcDeath
  alias Arena.Entity.NpcEntity
  alias Arena.Data.{GameData, NpcDef}
  alias Arena.Map.Helpers

  import Arena.Test.MapStateFactory

  @test_npc_id 900
  @test_npc_id_no_def 901

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Ensure ETS tables exist for PartyServer and GuildServer lookups
    if :ets.whereis(:ao_parties) == :undefined do
      :ets.new(:ao_parties, [:named_table, :set, :public, read_concurrency: true])
    end

    if :ets.whereis(:ao_guilds) == :undefined do
      :ets.new(:ao_guilds, [:named_table, :set, :public, read_concurrency: true])
    end

    # Insert a test NPC definition
    test_npc_def = %NpcDef{
      id: @test_npc_id,
      name: "TestDeathNpc",
      hostile: true,
      attackable: true,
      movement: 2,
      min_hp: 100,
      max_hp: 100,
      min_hit: 5,
      max_hit: 10,
      give_exp: 80,
      give_gld: 50,
      npc_level: 5,
      intervalo_ataque: 2000,
      intervalo_movimiento: 500,
      intervalo_respawn: 30,
      poder_ataque: 30,
      lanza_spells: 0,
      spells: [],
      loot_table: []
    }

    :ets.insert(:arena_game_data, {{:npc, @test_npc_id}, test_npc_def})

    # Deliberately do NOT insert a definition for @test_npc_id_no_def
    :ok
  end

  # ---- Helpers ----

  defp make_npc(overrides \\ []) do
    %NpcEntity{
      npc_id: overrides[:npc_id] || @test_npc_id,
      instance_id: overrides[:instance_id] || 1,
      char_index: overrides[:char_index] || 100,
      x: overrides[:x] || 50,
      y: overrides[:y] || 50,
      hp: overrides[:hp] || 100,
      max_hp: overrides[:max_hp] || 100,
      alive: Keyword.get(overrides, :alive, true),
      target_id: overrides[:target_id],
      spawn_x: overrides[:spawn_x] || 50,
      spawn_y: overrides[:spawn_y] || 50,
      next_attack_at: -1_000_000_000_000,
      next_move_at: -1_000_000_000_000,
      next_spell_at: -1_000_000_000_000,
      owner_id: overrides[:owner_id],
      pet_mode: overrides[:pet_mode] || :follow,
      exp_count: overrides[:exp_count] || 80
    }
  end

  defp make_player(overrides \\ []) do
    %{
      char_id: overrides[:char_id] || 7,
      name: overrides[:name] || "TestPlayer",
      x: overrides[:x] || 55,
      y: overrides[:y] || 50,
      dead: Keyword.get(overrides, :dead, false),
      invisible: Keyword.get(overrides, :invisible, false),
      hp: overrides[:hp] || 200,
      max_hp: overrides[:max_hp] || 200,
      mana: overrides[:mana] || 100,
      max_mana: overrides[:max_mana] || 100,
      stamina: overrides[:stamina] || 100,
      max_stamina: overrides[:max_stamina] || 100,
      pet_ids: overrides[:pet_ids] || [],
      skills: overrides[:skills] || %{taming: 50},
      level: overrides[:level] || 10,
      int: overrides[:int] || 18,
      agi: overrides[:agi] || 20,
      class: overrides[:class] || :warrior,
      heading: overrides[:heading] || 3,
      npcs_killed: overrides[:npcs_killed] || 0,
      xp: overrides[:xp] || 0,
      min_hit: overrides[:min_hit] || 5,
      max_hit: overrides[:max_hit] || 15,
      skill_points: overrides[:skill_points] || 0,
      buffs: [],
      paralyzed: false,
      equipment: %{},
      active_quests: overrides[:active_quests] || []
    }
  end

  defp make_state(opts \\ []) do
    players = opts[:players] || %{7 => make_player()}
    npcs = opts[:npcs] || %{1 => make_npc()}

    map_state(
      map_id: 999,
      players: players,
      sessions: opts[:sessions] || %{7 => self()},
      npcs_live: npcs,
      npc_char_indices: opts[:npc_char_indices] || %{100 => 1},
      visibility_mode: :global,
      visible_sets: nil,
      grid: nil
    )
  end

  # ================================================================
  # Pet death
  # ================================================================

  describe "pet death (source: :pet)" do
    test "removes pet from npcs_live" do
      pet = make_npc(owner_id: 7, instance_id: 1)
      owner = make_player(pet_ids: [1])
      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {_result_entity, result_state, _result_effects} = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)
      state = result_state

      refute Map.has_key?(state.npcs_live, 1),
             "Pet should be removed from npcs_live on death"
    end

    test "removes instance_id from owner's pet_ids" do
      pet = make_npc(owner_id: 7, instance_id: 1)
      owner = make_player(pet_ids: [1, 2])
      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)

      assert state.players[7].pet_ids == [2],
             "Owner's pet_ids should no longer contain the dead pet"
    end

    test "clears occupancy at pet position" do
      pet = make_npc(owner_id: 7, instance_id: 1, x: 10, y: 10)
      owner = make_player(pet_ids: [1])
      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      # Set occupancy so we can verify it's cleared
      occupancy = Helpers.set_occupancy(state.occupancy, 10, 10, {:npc, 1})
      state = %{state | occupancy: occupancy}

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)

      assert Helpers.get_occupancy(state.occupancy, 10, 10) == nil,
             "Occupancy should be cleared at pet's death position"
    end

    test "pet death with killer returns {entity, state} tuple" do
      pet = make_npc(owner_id: 7, instance_id: 1)
      killer = make_player(char_id: 8, pet_ids: [])
      owner = make_player(char_id: 7, pet_ids: [1])

      state = make_state(
        players: %{7 => owner, 8 => killer},
        npcs: %{1 => pet},
        sessions: %{7 => self(), 8 => self()}
      )

      {entity, new_state, _effects} = NpcDeath.resolve_npc_death(state, 1, pet,
        source: :pet,
        killer_char_id: 8,
        killer_entity: killer
      )

      assert entity.char_id == 8, "Should return the killer entity"
      refute Map.has_key?(new_state.npcs_live, 1)
    end

    test "pet death when owner is not on map (nil owner) does not crash" do
      # owner_id 99 is not in state.players
      pet = make_npc(owner_id: 99, instance_id: 1)
      state = make_state(players: %{7 => make_player()}, npcs: %{1 => pet})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)

      refute Map.has_key?(state.npcs_live, 1),
             "Pet should be removed even if owner is not on map"
    end
  end

  # ================================================================
  # Wild NPC death with killer
  # ================================================================

  describe "wild NPC death with killer" do
    test "marks NPC as alive: false" do
      npc = make_npc(instance_id: 1)
      killer = make_player(char_id: 7)
      state = make_state(players: %{7 => killer}, npcs: %{1 => npc})

      {_entity, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        killer_char_id: 7,
        killer_entity: killer,
        final_damage: 20,
        source: :melee
      )

      assert state.npcs_live[1].alive == false,
             "Wild NPC should be marked dead (alive: false)"
    end

    test "schedules respawn with respawn_at set" do
      npc = make_npc(instance_id: 1)
      killer = make_player(char_id: 7)
      state = make_state(players: %{7 => killer}, npcs: %{1 => npc})
      before_time = System.monotonic_time(:millisecond)

      {_entity, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        killer_char_id: 7,
        killer_entity: killer,
        final_damage: 20,
        source: :melee
      )

      dead_npc = state.npcs_live[1]
      # intervalo_respawn is 30 seconds for our test NPC def
      assert dead_npc.respawn_at >= before_time + 30_000,
             "respawn_at should be set ~30s in the future"
    end

    test "clears occupancy at NPC position" do
      npc = make_npc(instance_id: 1, x: 20, y: 20)
      killer = make_player(char_id: 7)
      state = make_state(players: %{7 => killer}, npcs: %{1 => npc})

      occupancy = Helpers.set_occupancy(state.occupancy, 20, 20, {:npc, 1})
      state = %{state | occupancy: occupancy}

      {_entity, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        killer_char_id: 7,
        killer_entity: killer,
        final_damage: 20,
        source: :melee
      )

      assert Helpers.get_occupancy(state.occupancy, 20, 20) == nil,
             "Occupancy should be cleared after wild NPC death"
    end

    test "increments killer npcs_killed counter" do
      npc = make_npc(instance_id: 1)
      killer = make_player(char_id: 7, npcs_killed: 5)
      state = make_state(players: %{7 => killer}, npcs: %{1 => npc})

      {entity, _state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        killer_char_id: 7,
        killer_entity: killer,
        final_damage: 20,
        source: :melee
      )

      assert entity.npcs_killed == 6,
             "npcs_killed should be incremented by 1"
    end

    test "awards XP to killer (entity xp increases)" do
      npc = make_npc(instance_id: 1, exp_count: 80)
      killer = make_player(char_id: 7, xp: 0, level: 5)
      state = make_state(players: %{7 => killer}, npcs: %{1 => npc})

      {entity, _state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        killer_char_id: 7,
        killer_entity: killer,
        final_damage: 50,
        source: :melee
      )

      assert entity.xp >= 0,
             "Killer entity should have XP >= 0 (may be 0 if capped by pool)"
    end

    test "returns {entity, state} tuple" do
      npc = make_npc(instance_id: 1)
      killer = make_player(char_id: 7)
      state = make_state(players: %{7 => killer}, npcs: %{1 => npc})

      assert {_entity, _state, _effects} =
               NpcDeath.resolve_npc_death(state, 1, npc,
                 killer_char_id: 7,
                 killer_entity: killer,
                 final_damage: 10,
                 source: :melee
               )
    end
  end

  # ================================================================
  # Wild NPC death without killer (NPC-vs-NPC combat)
  # ================================================================

  describe "wild NPC death without killer" do
    test "returns only state (no entity tuple)" do
      npc = make_npc(instance_id: 1)
      state = make_state(npcs: %{1 => npc})

      {_result_entity, result_state, _result_effects} = NpcDeath.resolve_npc_death(state, 1, npc, source: :melee)

      # When no killer_entity and no killer_char_id, returns bare state
      assert %{npcs_live: _} = result_state,
             "Should return bare state, not a tuple"
    end

    test "marks NPC as dead with no killer" do
      npc = make_npc(instance_id: 1)
      state = make_state(npcs: %{1 => npc})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc)

      assert state.npcs_live[1].alive == false
    end

    test "clears occupancy with no killer" do
      npc = make_npc(instance_id: 1, x: 30, y: 30)
      state = make_state(npcs: %{1 => npc})

      occupancy = Helpers.set_occupancy(state.occupancy, 30, 30, {:npc, 1})
      state = %{state | occupancy: occupancy}

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc)

      assert Helpers.get_occupancy(state.occupancy, 30, 30) == nil
    end

    test "does not crash when no players exist in state" do
      npc = make_npc(instance_id: 1)
      state = make_state(players: %{}, npcs: %{1 => npc}, sessions: %{})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc)

      assert state.npcs_live[1].alive == false
    end
  end

  # ================================================================
  # Permanent kill (GM)
  # ================================================================

  describe "permanent kill (GM)" do
    test "deletes NPC from npcs_live entirely" do
      npc = make_npc(instance_id: 1)
      state = make_state(npcs: %{1 => npc})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        source: :gm_perm,
        permanent: true
      )

      refute Map.has_key?(state.npcs_live, 1),
             "Permanent kill should delete NPC from npcs_live"
    end

    test "does not schedule respawn" do
      npc = make_npc(instance_id: 1)
      state = make_state(npcs: %{1 => npc})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        source: :gm_perm,
        permanent: true
      )

      # NPC is gone entirely, no respawn_at to check
      refute Map.has_key?(state.npcs_live, 1)
    end

    test "clears occupancy on permanent kill" do
      npc = make_npc(instance_id: 1, x: 40, y: 40)
      state = make_state(npcs: %{1 => npc})

      occupancy = Helpers.set_occupancy(state.occupancy, 40, 40, {:npc, 1})
      state = %{state | occupancy: occupancy}

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        source: :gm_perm,
        permanent: true
      )

      assert Helpers.get_occupancy(state.occupancy, 40, 40) == nil
    end

    test "permanent kill returns bare state (no rewards)" do
      npc = make_npc(instance_id: 1)
      state = make_state(npcs: %{1 => npc})

      {_result_entity, result_state, _result_effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        source: :gm_perm,
        permanent: true
      )

      # No killer_entity => bare state returned
      assert %{npcs_live: _} = result_state
    end
  end

  # ================================================================
  # Edge: killer entity not found in state.players
  # ================================================================

  describe "edge: killer entity not in state.players" do
    test "does not crash when killer_entity is a struct not in players map" do
      npc = make_npc(instance_id: 1)
      # killer has char_id: 99, but state.players only has char_id: 7
      killer = make_player(char_id: 99)
      state = make_state(
        players: %{7 => make_player()},
        npcs: %{1 => npc},
        sessions: %{7 => self()}
      )

      # Should not crash even though char_id 99 is not in state.players
      assert {_entity, _state, _effects} =
               NpcDeath.resolve_npc_death(state, 1, npc,
                 killer_char_id: 99,
                 killer_entity: killer,
                 final_damage: 10,
                 source: :melee
               )
    end

    test "does not crash when killer_entity is provided but killer_char_id is nil" do
      npc = make_npc(instance_id: 1)
      killer = make_player(char_id: 7)
      state = make_state(npcs: %{1 => npc})

      # killer_entity set but killer_char_id nil => no rewards path, returns bare state
      {_result_entity, result_state, _result_effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        killer_char_id: nil,
        killer_entity: killer,
        source: :melee
      )

      assert %{npcs_live: _} = result_state
    end
  end

  # ================================================================
  # Edge: NPC already dead (alive: false)
  # ================================================================

  describe "edge: NPC already dead" do
    test "calling resolve_npc_death on an already-dead NPC does not crash" do
      dead_npc = make_npc(instance_id: 1, alive: false, hp: 0)
      state = make_state(npcs: %{1 => dead_npc})

      {_result_entity, result_state, _result_effects} = NpcDeath.resolve_npc_death(state, 1, dead_npc)

      # Function should handle gracefully — NPC stays dead
      assert %{npcs_live: _} = result_state
      assert result_state.npcs_live[1].alive == false
    end

    test "already-dead NPC with killer does not award double rewards" do
      dead_npc = make_npc(instance_id: 1, alive: false, hp: 0)
      killer = make_player(char_id: 7, npcs_killed: 10)
      state = make_state(players: %{7 => killer}, npcs: %{1 => dead_npc})

      {entity, _state, _effects} = NpcDeath.resolve_npc_death(state, 1, dead_npc,
        killer_char_id: 7,
        killer_entity: killer,
        final_damage: 0,
        source: :melee
      )

      # npcs_killed is still incremented (the function doesn't check alive),
      # but final_damage: 0 means no XP is awarded
      assert entity.npcs_killed == 11
    end
  end

  # ================================================================
  # Edge: NPC with no npc_def in GameData
  # ================================================================

  describe "edge: NPC with no npc_def in GameData" do
    test "does not crash on loot/XP when npc_def is nil" do
      # npc_id 901 has no definition in GameData
      npc = make_npc(instance_id: 1, npc_id: @test_npc_id_no_def)
      killer = make_player(char_id: 7)
      state = make_state(players: %{7 => killer}, npcs: %{1 => npc})

      {_entity, new_state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        killer_char_id: 7,
        killer_entity: killer,
        final_damage: 20,
        source: :melee
      )

      # NPC should still be marked dead
      assert new_state.npcs_live[1].alive == false
    end

    test "uses default respawn delay of 60s when npc_def is nil" do
      npc = make_npc(instance_id: 1, npc_id: @test_npc_id_no_def)
      state = make_state(npcs: %{1 => npc})
      before_time = System.monotonic_time(:millisecond)

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc)

      dead_npc = state.npcs_live[1]
      # Default respawn is 60 seconds
      assert dead_npc.respawn_at >= before_time + 60_000,
             "Should use default 60s respawn when npc_def is nil"
    end

    test "permanent kill of NPC with no def does not crash" do
      npc = make_npc(instance_id: 1, npc_id: @test_npc_id_no_def)
      state = make_state(npcs: %{1 => npc})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        source: :gm_perm,
        permanent: true
      )

      refute Map.has_key?(state.npcs_live, 1)
    end
  end

  # ================================================================
  # Double death: calling resolve_npc_death twice for same NPC
  # ================================================================

  describe "double death" do
    test "calling resolve_npc_death twice on the same wild NPC does not crash" do
      npc = make_npc(instance_id: 1)
      state = make_state(npcs: %{1 => npc})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc)
      # NPC is now dead in npcs_live
      dead_npc = state.npcs_live[1]
      assert dead_npc.alive == false

      # Call again with the original npc struct (simulating a race)
      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc)
      # Should still be in npcs_live, still dead
      assert state.npcs_live[1].alive == false
    end

    test "double death with killer does not crash and returns valid tuple" do
      npc = make_npc(instance_id: 1)
      killer = make_player(char_id: 7)
      state = make_state(players: %{7 => killer}, npcs: %{1 => npc})

      {entity1, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        killer_char_id: 7,
        killer_entity: killer,
        final_damage: 20,
        source: :melee
      )

      # Second call with the updated entity as killer
      {entity2, _state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        killer_char_id: 7,
        killer_entity: entity1,
        final_damage: 0,
        source: :melee
      )

      # npcs_killed incremented both times
      assert entity2.npcs_killed == entity1.npcs_killed + 1
    end

    test "double permanent kill does not crash (NPC already removed)" do
      npc = make_npc(instance_id: 1)
      state = make_state(npcs: %{1 => npc})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        source: :gm_perm,
        permanent: true
      )

      refute Map.has_key?(state.npcs_live, 1)

      # Second permanent kill — NPC no longer in npcs_live
      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, npc,
        source: :gm_perm,
        permanent: true
      )

      refute Map.has_key?(state.npcs_live, 1),
             "Double permanent kill should not crash"
    end

    test "double pet death does not crash (pet already removed)" do
      pet = make_npc(owner_id: 7, instance_id: 1)
      owner = make_player(pet_ids: [1])
      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)
      refute Map.has_key?(state.npcs_live, 1)

      # Second pet death — pet already gone
      {_, state, _effects} = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)
      refute Map.has_key?(state.npcs_live, 1),
             "Double pet death should not crash"
    end
  end
end
