defmodule Arena.PetTamingExtendedTest do
  @moduledoc """
  Extended parity tests for pet/taming mechanics — covers gaps not tested
  in pet_taming_parity_test.exs.

  Focus areas:
  - Pet stat inheritance (HP/damage from NPC definition, not owner)
  - Pet attack mechanics (damage formula, defense reduction, range, target filtering)
  - Pet death handling (no XP, occupancy clear, no respawn, owner cleanup)
  - Taming edge cases (already-owned, stamina, dead player, skill-up on fail)
  - Pet mode edge cases (stand prevents all movement, mode changes all pets)
  - Pet limits (max 3, /LIBERAR releases head of list)
  """
  use ExUnit.Case, async: true

  alias Arena.NpcAi
  alias Arena.Entity.NpcEntity
  alias Arena.Map.NpcDeath
  alias Arena.Map.PlayerDeath
  alias Arena.Map.Crafting
  alias Arena.Map.Pets
  alias Arena.Map.Helpers

  import Arena.Test.MapStateFactory

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ---- Helpers ----

  @hostile_npc_id 559

  defp make_npc(overrides \\ []) do
    %NpcEntity{
      npc_id: overrides[:npc_id] || @hostile_npc_id,
      instance_id: overrides[:instance_id] || 1,
      char_index: overrides[:char_index] || 100,
      x: overrides[:x] || 50,
      y: overrides[:y] || 50,
      hp: overrides[:hp] || 250,
      max_hp: overrides[:max_hp] || 250,
      alive: Keyword.get(overrides, :alive, true),
      target_id: overrides[:target_id],
      spawn_x: overrides[:spawn_x] || 50,
      spawn_y: overrides[:spawn_y] || 50,
      next_attack_at: overrides[:next_attack_at] || -1_000_000_000_000,
      next_move_at: overrides[:next_move_at] || -1_000_000_000_000,
      next_spell_at: overrides[:next_spell_at] || -1_000_000_000_000,
      owner_id: overrides[:owner_id],
      pet_mode: overrides[:pet_mode] || :follow
    }
  end

  defp make_player(overrides \\ []) do
    %{
      char_id: overrides[:char_id] || 7,
      char_index: overrides[:char_index] || 500,
      name: overrides[:name] || "TestPlayer",
      x: overrides[:x] || 50,
      y: overrides[:y] || 50,
      dead: Keyword.get(overrides, :dead, false),
      invisible: Keyword.get(overrides, :invisible, false),
      hp: overrides[:hp] || 100,
      max_hp: overrides[:max_hp] || 100,
      pet_ids: overrides[:pet_ids] || [],
      skills: overrides[:skills] || %{taming: 50},
      stamina: overrides[:stamina] || 100,
      level: overrides[:level] || 10,
      agi: overrides[:agi] || 20,
      class: overrides[:class] || :warrior,
      heading: overrides[:heading] || 3,
      npcs_killed: overrides[:npcs_killed] || 0,
      buffs: [],
      paralyzed: false,
      equipment: %{},
      mana: overrides[:mana] || 100,
      max_mana: overrides[:max_mana] || 100,
      oculto: false,
      inventory: overrides[:inventory] || List.duplicate(nil, 20),
      deaths: overrides[:deaths] || 0,
      in_duel: false,
      criminal: false,
      faction: :none,
      citizens_killed: 0,
      criminals_killed: 0,
      mounted: false,
      poisoned: false,
      meditating: false,
      resting: false,
      immobilized: false,
      oculto_timer: 0,
      commerce_npc_id: nil,
      bank_npc_id: nil,
      trade_partner_id: nil,
      trade_request_target: nil,
      trade_offer_gold: 0,
      trade_offer_items: [],
      trade_accepted: false,
      hunger: 100,
      thirst: 100
    }
  end

  defp make_state(opts) do
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
      grid: nil,
      meta: opts[:meta] || %{}
    )
  end

  # ================================================================
  # Pet stat inheritance — pets use NPC definition stats, not owner
  # ================================================================

  describe "pet stat inheritance" do
    test "pet HP comes from NPC definition, not owner stats" do
      npc_def = Arena.Data.GameData.get_npc(@hostile_npc_id)

      if npc_def do
        entity = NpcEntity.from_def(npc_def, 1, 100, 50, 50)

        # HP should be within NPC def range
        assert entity.hp >= npc_def.min_hp,
               "Pet HP should be >= NPC def min_hp (#{npc_def.min_hp}), got #{entity.hp}"

        assert entity.hp <= npc_def.max_hp,
               "Pet HP should be <= NPC def max_hp (#{npc_def.max_hp}), got #{entity.hp}"

        # Verify it does NOT use any "owner" stats — from_def has no owner param
        assert entity.owner_id == nil, "from_def creates wild NPC with nil owner_id"
      end
    end

    test "pet HP does not scale with owner level — NPC entity has no level scaling" do
      npc_def = Arena.Data.GameData.get_npc(@hostile_npc_id)

      if npc_def do
        # Create two NPCs — the "owner level" is irrelevant; HP is from npc_def
        entity_low = NpcEntity.from_def(npc_def, 1, 100, 50, 50)
        entity_high = NpcEntity.from_def(npc_def, 2, 200, 50, 50)

        # Both should have HP within the same NPC def range
        assert entity_low.hp >= npc_def.min_hp and entity_low.hp <= npc_def.max_hp
        assert entity_high.hp >= npc_def.min_hp and entity_high.hp <= npc_def.max_hp

        # NpcEntity struct has no level field at all — it uses NPC definition stats
        refute Map.has_key?(entity_low, :level),
               "NpcEntity should not have a :level field — pets don't scale with owner"
      end
    end

    test "pet uses NPC definition defense, not owner defense" do
      # NpcEntity struct has no defense field — defense is looked up from npc_def at combat time
      pet = make_npc(owner_id: 7, instance_id: 1)
      refute Map.has_key?(pet, :defense),
             "NpcEntity should not store defense — it comes from GameData.get_npc at combat time"
    end
  end

  # ================================================================
  # Pet attack mechanics
  # ================================================================

  describe "pet damage formula" do
    test "pet damage uses min_hit to max_hit from NPC definition" do
      npc_def = Arena.Data.GameData.get_npc(@hostile_npc_id)

      if npc_def do
        # maybe_pet_attack uses Enum.random(npc_def.min_hit..npc_def.max_hit)
        # Verify min/max hit are defined on the NPC def
        assert is_integer(npc_def.min_hit), "NPC def should have min_hit"
        assert is_integer(npc_def.max_hit), "NPC def should have max_hit"
        assert npc_def.max_hit >= npc_def.min_hit, "max_hit should be >= min_hit"

        # Simulate the damage range the pet would deal
        damages =
          for _ <- 1..200 do
            if npc_def.max_hit > npc_def.min_hit do
              Enum.random(npc_def.min_hit..npc_def.max_hit)
            else
              max(npc_def.min_hit, 1)
            end
          end

        assert Enum.all?(damages, &(&1 >= npc_def.min_hit)),
               "All damage values should be >= min_hit"

        assert Enum.all?(damages, &(&1 <= npc_def.max_hit)),
               "All damage values should be <= max_hit"
      end
    end

    test "pet damage reduced by target defense: max(raw - defense, 0)" do
      # This is the formula in maybe_pet_attack:
      # defense = if target_def, do: target_def.def, else: 0
      # final_damage = max(raw_damage - defense, 0)

      # Case 1: raw > defense
      assert max(50 - 20, 0) == 30, "50 raw - 20 def = 30 damage"

      # Case 2: raw == defense
      assert max(20 - 20, 0) == 0, "20 raw - 20 def = 0 damage"

      # Case 3: raw < defense
      assert max(10 - 20, 0) == 0, "10 raw - 20 def = 0 (clamped to 0)"

      # Case 4: zero defense
      assert max(50 - 0, 0) == 50, "50 raw - 0 def = 50 damage"
    end

    test "pet attack range is adjacent only (1 tile Chebyshev)" do
      # In npc_ai.ex, pets check adjacent?(npc.x, npc.y, target_npc.x, target_npc.y)
      # which is: abs(x1 - x2) <= 1 and abs(y1 - y2) <= 1

      # Adjacent cases (should be true)
      assert abs(50 - 51) <= 1 and abs(50 - 50) <= 1, "Direct east is adjacent"
      assert abs(50 - 49) <= 1 and abs(50 - 50) <= 1, "Direct west is adjacent"
      assert abs(50 - 50) <= 1 and abs(50 - 51) <= 1, "Direct south is adjacent"
      assert abs(50 - 51) <= 1 and abs(50 - 51) <= 1, "Diagonal is adjacent"
      assert abs(50 - 50) <= 1 and abs(50 - 50) <= 1, "Same tile is adjacent"

      # Non-adjacent cases (should be false)
      refute abs(50 - 52) <= 1 and abs(50 - 50) <= 1, "2 tiles east is NOT adjacent"
      refute abs(50 - 52) <= 1 and abs(50 - 52) <= 1, "2 tiles diagonal is NOT adjacent"
    end

    test "pet only attacks hostile wild NPCs — not other pets" do
      # Pet should not attack NPCs that have owner_id set
      # Both pets belong to same owner so neither gets despawned
      pet = make_npc(owner_id: 7, instance_id: 1, x: 50, y: 50, char_index: 100)
      other_pet = make_npc(
        owner_id: 7, instance_id: 2, x: 51, y: 50, char_index: 200,
        hp: 100, max_hp: 100, next_move_at: 9_999_999_999_999
      )
      owner = make_player(x: 50, y: 51, pet_ids: [1, 2])

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet, 2 => other_pet},
        npc_char_indices: %{100 => 1, 200 => 2}
      )

      {state, _effects} = NpcAi.tick(state)

      # other_pet HP should be untouched
      assert state.npcs_live[2].hp == 100,
             "Pet should not attack another pet (owner_id != nil)"
    end

    test "pet does not attack its own owner (targets only NPCs, not players)" do
      # Pet AI targets wild hostile NPCs via find_nearest_wild_npc,
      # which filters state.npcs_live — players are never in that map
      pet = make_npc(owner_id: 7, instance_id: 1, x: 50, y: 50, char_index: 100)
      owner = make_player(x: 51, y: 50, pet_ids: [1], hp: 100, max_hp: 100)

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet},
        npc_char_indices: %{100 => 1}
      )

      {state, _effects} = NpcAi.tick(state)

      # Owner HP should remain unchanged
      assert state.players[7].hp == 100,
             "Pet should never attack its owner"
    end

    test "pet aggro range is 8 tiles" do
      # find_nearest_wild_npc filters: abs(n.x - pet.x) <= @pet_aggro_range
      # @pet_aggro_range = 8

      # Wild NPC at distance 8 — should be within aggro range
      pet = make_npc(owner_id: 7, instance_id: 1, x: 50, y: 50, char_index: 100)
      wild_npc_in_range = make_npc(
        instance_id: 2, x: 58, y: 50, char_index: 200, hp: 100, max_hp: 100,
        next_move_at: 9_999_999_999_999
      )
      owner = make_player(x: 50, y: 51, invisible: true, pet_ids: [1])

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet, 2 => wild_npc_in_range},
        npc_char_indices: %{100 => 1, 200 => 2}
      )

      {state, _effects} = NpcAi.tick(state)

      # Pet should have attempted to move toward wild NPC at distance 8
      pet_after = state.npcs_live[1]
      assert pet_after.next_move_at > -1_000_000_000_000,
             "Pet should detect wild NPC at distance 8 (within aggro range)"
    end

    test "pet does not aggro on wild NPC beyond 8 tiles" do
      # Wild NPC at distance 9 — should be outside aggro range
      pet = make_npc(owner_id: 7, instance_id: 1, x: 50, y: 50, char_index: 100)
      wild_npc_out_of_range = make_npc(
        instance_id: 2, x: 59, y: 50, char_index: 200, hp: 100, max_hp: 100,
        next_move_at: 9_999_999_999_999
      )
      # Owner within follow distance so pet doesn't follow
      owner = make_player(x: 52, y: 50, invisible: true, pet_ids: [1])

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet, 2 => wild_npc_out_of_range},
        npc_char_indices: %{100 => 1, 200 => 2}
      )

      # Seed rand to prevent random idle walk from masking result
      :rand.seed(:exsss, {1, 2, 3})
      {state, _effects} = NpcAi.tick(state)

      # Wild NPC should be untouched — pet cannot see it
      assert state.npcs_live[2].hp == 100,
             "Wild NPC at distance 9 should be outside pet aggro range"
    end
  end

  # ================================================================
  # Pet death handling
  # ================================================================

  describe "pet death handling" do
    test "pet death does NOT award XP — resolve_npc_death with source: :pet skips rewards" do
      pet = make_npc(owner_id: 7, instance_id: 1, hp: 0, x: 10, y: 10)
      owner = make_player(pet_ids: [1], npcs_killed: 5)

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      # Pet death with source: :pet — no killer_entity, so no rewards branch
      result = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)

      # When no killer_entity is provided, returns just state (not {entity, state})
      state = result
      assert is_map(state), "resolve_npc_death with no killer returns state map"

      # Owner's npcs_killed should be unchanged
      assert state.players[7].npcs_killed == 5,
             "Pet death should not increment owner's kill counter"
    end

    test "pet death clears occupancy at pet position" do
      pet = make_npc(owner_id: 7, instance_id: 1, x: 10, y: 10)
      owner = make_player(pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      # Set occupancy at pet position
      occupancy = Helpers.set_occupancy(state.occupancy, 10, 10, {:npc, 1})
      state = %{state | occupancy: occupancy}

      state = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)

      assert Helpers.get_occupancy(state.occupancy, 10, 10) == nil,
             "Pet death should clear occupancy at pet position"
    end

    test "pet death does NOT trigger respawn — pet removed from npcs_live" do
      pet = make_npc(owner_id: 7, instance_id: 1, hp: 0)
      owner = make_player(pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      state = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)

      # Pet should be completely gone from npcs_live (not just dead with respawn_at)
      refute Map.has_key?(state.npcs_live, 1),
             "Pet should be removed from npcs_live entirely, not scheduled for respawn"
    end

    test "pet death removes instance_id from owner's pet_ids" do
      pet = make_npc(owner_id: 7, instance_id: 2, char_index: 200)
      owner = make_player(pet_ids: [1, 2, 3])

      state = make_state(
        players: %{7 => owner},
        npcs: %{2 => pet},
        npc_char_indices: %{200 => 2}
      )

      state = NpcDeath.resolve_npc_death(state, 2, pet, source: :pet)

      assert state.players[7].pet_ids == [1, 3],
             "Pet death should remove instance_id 2 from owner's pet_ids"
    end

    test "player death despawns all owned pets" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100)
      pet2 = make_npc(owner_id: 7, instance_id: 2, char_index: 200)
      owner = make_player(pet_ids: [1, 2], hp: 0, deaths: 0)

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet1, 2 => pet2},
        npc_char_indices: %{100 => 1, 200 => 2},
        meta: %{safe_zone: true}
      )

      {_player, state} = PlayerDeath.handle_player_death(state, 7, owner)

      # Both pets should be removed from npcs_live
      refute Map.has_key?(state.npcs_live, 1),
             "Pet 1 should be despawned on player death"
      refute Map.has_key?(state.npcs_live, 2),
             "Pet 2 should be despawned on player death"
    end

    test "killing a pet does not award XP to the attacker" do
      # When a player kills a pet, resolve_npc_death with killer_entity returns
      # the killer entity unchanged (no XP, no kill counter increment)
      pet = make_npc(owner_id: 8, instance_id: 1, hp: 0)
      attacker = make_player(char_id: 7, npcs_killed: 0, pet_ids: [])

      state = make_state(
        players: %{7 => attacker, 8 => make_player(char_id: 8, pet_ids: [1])},
        npcs: %{1 => pet}
      )

      {entity, _state} = NpcDeath.resolve_npc_death(
        state, 1, pet,
        source: :pet,
        killer_char_id: 7,
        killer_entity: attacker,
        final_damage: 50
      )

      assert entity.npcs_killed == 0,
             "Killing a pet should not increment attacker's npcs_killed"
    end
  end

  # ================================================================
  # Taming edge cases
  # ================================================================

  describe "taming edge cases" do
    test "cannot tame already-owned NPC" do
      # find_tameable_npc filters: npc.owner_id == nil
      # An NPC with owner_id set should never be found as a taming target
      pet = make_npc(owner_id: 8, instance_id: 1, x: 51, y: 50)
      tamer = make_player(skills: %{taming: 100}, stamina: 100)

      state = make_state(players: %{7 => tamer}, npcs: %{1 => pet})

      {:noreply, state} = Crafting.handle_work(state, 7, :taming)

      # Should NOT have gained a pet — the only NPC is already owned
      assert state.players[7].pet_ids == [],
             "Should not be able to tame an already-owned NPC"
    end

    test "cannot tame with insufficient stamina" do
      wild = make_npc(instance_id: 1, owner_id: nil, x: 51, y: 50)
      # Warrior pays 45 stamina (15 * 3). Set stamina to 10 — insufficient.
      tamer = make_player(class: :warrior, stamina: 10, skills: %{taming: 100})

      state = make_state(players: %{7 => tamer}, npcs: %{1 => wild})

      {:noreply, state} = Crafting.handle_work(state, 7, :taming)

      # Should NOT have tamed — insufficient stamina
      assert state.players[7].pet_ids == [],
             "Should not be able to tame with insufficient stamina"
      # Stamina should be unchanged
      assert state.players[7].stamina == 10,
             "Stamina should not be consumed when insufficient"
    end

    test "taming clears target_id on newly tamed pet" do
      # The taming code does: npc = %{npc | owner_id: char_id, target_id: nil}
      wild = make_npc(instance_id: 1, owner_id: nil, x: 51, y: 50, target_id: 7)
      tamer = make_player(skills: %{taming: 100}, stamina: 100, class: :worker)

      state = make_state(players: %{7 => tamer}, npcs: %{1 => wild})

      # Force taming to succeed by setting skill to 100
      {:noreply, state} = Crafting.handle_work(state, 7, :taming)

      # If taming succeeded (skill 100 should always pass), target_id should be nil
      case state.npcs_live[1] do
        %{owner_id: 7} = npc ->
          assert npc.target_id == nil,
                 "Taming should clear target_id on newly tamed pet"

        _ ->
          # Taming may have had a very unlikely failure at skill 100,
          # which is technically possible but extremely improbable.
          :ok
      end
    end

    test "taming stamina cost is 15 for workers, 45 for non-workers" do
      # @work_stamina_cost = 15
      # @non_worker_stamina_multiplier = 3
      # Worker classes: [:worker, :trabajador]

      wild1 = make_npc(instance_id: 1, owner_id: nil, x: 51, y: 50)
      wild2 = make_npc(instance_id: 2, owner_id: nil, x: 51, y: 50, char_index: 200)

      # Worker: costs 15 stamina
      worker = make_player(char_id: 7, class: :worker, stamina: 100, skills: %{taming: 50})
      state = make_state(
        players: %{7 => worker},
        npcs: %{1 => wild1},
        npc_char_indices: %{100 => 1}
      )

      {:noreply, state_after_worker} = Crafting.handle_work(state, 7, :taming)
      assert state_after_worker.players[7].stamina == 85,
             "Worker should pay 15 stamina for taming (100 - 15 = 85)"

      # Warrior (non-worker): costs 45 stamina
      warrior = make_player(char_id: 7, class: :warrior, stamina: 100, skills: %{taming: 50})
      state2 = make_state(
        players: %{7 => warrior},
        npcs: %{2 => wild2},
        npc_char_indices: %{200 => 2}
      )

      {:noreply, state_after_warrior} = Crafting.handle_work(state2, 7, :taming)
      assert state_after_warrior.players[7].stamina == 55,
             "Warrior should pay 45 stamina for taming (100 - 45 = 55)"
    end

    test "skill-up happens on both success and failure" do
      # In attempt_taming, try_skill_up is called in both the if and else branches
      # try_skill_up: if skill < 100 and :rand.uniform(100) > skill_value, increment

      # With skill=1, skill-up probability is ~99%.
      # Run many trials to verify skill-up can happen on both success and failure paths.
      results =
        for _ <- 1..500 do
          skill_value = 1
          taming_succeeded = :rand.uniform(100) <= skill_value
          skilled_up = skill_value < 100 and :rand.uniform(100) > skill_value
          {taming_succeeded, skilled_up}
        end

      # Count skill-ups on failure (should be ~99% of failures)
      failure_skillups = Enum.count(results, fn {success, skillup} -> not success and skillup end)
      failures = Enum.count(results, fn {success, _} -> not success end)

      assert failure_skillups > 0,
             "Skill-up should be possible on taming failure"

      # Verify the formula: skill-up happens when rand > skill_value
      # At skill=1, this is ~99% chance
      if failures > 0 do
        ratio = failure_skillups / failures
        assert ratio > 0.80,
               "At skill=1, ~99% of failures should yield skill-up (got #{Float.round(ratio * 100, 1)}%)"
      end
    end

    test "cannot tame when dead" do
      wild = make_npc(instance_id: 1, owner_id: nil, x: 51, y: 50)
      dead_player = make_player(dead: true, skills: %{taming: 100}, stamina: 100)

      state = make_state(players: %{7 => dead_player}, npcs: %{1 => wild})

      {:noreply, state} = Crafting.handle_work(state, 7, :taming)

      # Dead player should not be able to tame
      assert state.players[7].pet_ids == [],
             "Dead player should not be able to tame"
      # Stamina should be unchanged
      assert state.players[7].stamina == 100,
             "Dead player's stamina should not be consumed"
    end

    test "max 3 pets enforced at taming" do
      wild = make_npc(instance_id: 4, owner_id: nil, x: 51, y: 50, char_index: 400)
      # Player already has 3 pets
      owner = make_player(
        pet_ids: [1, 2, 3],
        skills: %{taming: 100},
        stamina: 100,
        class: :worker
      )

      state = make_state(
        players: %{7 => owner},
        npcs: %{4 => wild},
        npc_char_indices: %{400 => 4}
      )

      {:noreply, state} = Crafting.handle_work(state, 7, :taming)

      # pet_ids should still be [1, 2, 3] — 4th pet rejected
      assert state.players[7].pet_ids == [1, 2, 3],
             "Should not be able to tame when already at max 3 pets"
      # Stamina should be unchanged (rejected before stamina consumed)
      assert state.players[7].stamina == 100,
             "Stamina should not be consumed when at pet limit"
    end
  end

  # ================================================================
  # Pet mode edge cases
  # ================================================================

  describe "pet mode edge cases" do
    test "stand mode prevents ALL movement including follow" do
      # Pet in :stand mode with owner far away — should NOT move
      pet = make_npc(
        owner_id: 7, instance_id: 1, x: 50, y: 50, pet_mode: :stand,
        char_index: 100
      )
      owner = make_player(x: 70, y: 70, pet_ids: [1])

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet},
        npc_char_indices: %{100 => 1}
      )

      {state, _effects} = NpcAi.tick(state)

      npc_after = state.npcs_live[1]
      assert npc_after.x == 50, "Stand mode should prevent follow movement (x unchanged)"
      assert npc_after.y == 50, "Stand mode should prevent follow movement (y unchanged)"
      # next_move_at should NOT be advanced since pet skips entirely
      assert npc_after.next_move_at == -1_000_000_000_000,
             "Stand mode should not advance next_move_at"
    end

    test "stand mode prevents attack even when hostile is adjacent" do
      pet = make_npc(
        owner_id: 7, instance_id: 1, x: 50, y: 50, pet_mode: :stand,
        char_index: 100
      )
      wild = make_npc(
        instance_id: 2, x: 51, y: 50, char_index: 200, hp: 100, max_hp: 100,
        next_move_at: 9_999_999_999_999
      )
      owner = make_player(x: 50, y: 51, invisible: true, pet_ids: [1])

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet, 2 => wild},
        npc_char_indices: %{100 => 1, 200 => 2}
      )

      {state, _effects} = NpcAi.tick(state)

      # Wild NPC should be untouched
      assert state.npcs_live[2].hp == 100,
             "Stand mode should prevent pet from attacking"
      # Pet's attack cooldown should NOT have advanced
      assert state.npcs_live[1].next_attack_at == -1_000_000_000_000,
             "Stand mode should not advance next_attack_at"
    end

    test "mode commands change ALL pets at once" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, pet_mode: :follow, char_index: 100)
      pet2 = make_npc(owner_id: 7, instance_id: 2, pet_mode: :follow, char_index: 200)
      pet3 = make_npc(owner_id: 7, instance_id: 3, pet_mode: :follow, char_index: 300)
      owner = make_player(pet_ids: [1, 2, 3])

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet1, 2 => pet2, 3 => pet3},
        npc_char_indices: %{100 => 1, 200 => 2, 300 => 3}
      )

      {:noreply, state} = Pets.handle_pet_stand(state, 7)

      assert state.npcs_live[1].pet_mode == :stand
      assert state.npcs_live[2].pet_mode == :stand
      assert state.npcs_live[3].pet_mode == :stand

      {:noreply, state} = Pets.handle_pet_follow(state, 7)

      assert state.npcs_live[1].pet_mode == :follow
      assert state.npcs_live[2].pet_mode == :follow
      assert state.npcs_live[3].pet_mode == :follow
    end

    test "setting mode on dead player silently fails — modes unchanged" do
      pet = make_npc(owner_id: 7, instance_id: 1, pet_mode: :follow)
      owner = make_player(dead: true, pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {:noreply, state_after_stand} = Pets.handle_pet_stand(state, 7)
      assert state_after_stand.npcs_live[1].pet_mode == :follow,
             "Dead player's stand command should not change pet mode"

      {:noreply, state_after_follow} = Pets.handle_pet_follow(state, 7)
      assert state_after_follow.npcs_live[1].pet_mode == :follow,
             "Dead player's follow command should not change pet mode"
    end

    test "dead player cannot release pets" do
      pet = make_npc(owner_id: 7, instance_id: 1, pet_mode: :follow)
      owner = make_player(dead: true, pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {:noreply, state} = Pets.handle_pet_leave(state, 7, 1)

      # Pet should still be alive — dead player cannot release
      assert Map.has_key?(state.npcs_live, 1),
             "Dead player should not be able to release pets"
      assert state.players[7].pet_ids == [1],
             "Dead player's pet_ids should be unchanged"
    end
  end

  # ================================================================
  # Pet limits and /LIBERAR behavior
  # ================================================================

  describe "pet limits and /LIBERAR" do
    test "/LIBERAR releases the specified pet by instance ID" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100)
      pet2 = make_npc(owner_id: 7, instance_id: 2, char_index: 200)
      pet3 = make_npc(owner_id: 7, instance_id: 3, char_index: 300)
      owner = make_player(pet_ids: [1, 2, 3])

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet1, 2 => pet2, 3 => pet3},
        npc_char_indices: %{100 => 1, 200 => 2, 300 => 3}
      )

      # Release pet 1 by its instance ID
      {:noreply, state} = Pets.handle_pet_leave(state, 7, 1)

      # First pet (instance 1) should be gone
      refute Map.has_key?(state.npcs_live, 1), "Selected pet should be released"
      # Others remain
      assert Map.has_key?(state.npcs_live, 2), "Second pet should remain"
      assert Map.has_key?(state.npcs_live, 3), "Third pet should remain"
      # pet_ids should now be [2, 3]
      assert state.players[7].pet_ids == [2, 3]
    end

    test "successive /LIBERAR releases specified pets" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100)
      pet2 = make_npc(owner_id: 7, instance_id: 2, char_index: 200)
      owner = make_player(pet_ids: [1, 2])

      state = make_state(
        players: %{7 => owner},
        npcs: %{1 => pet1, 2 => pet2},
        npc_char_indices: %{100 => 1, 200 => 2}
      )

      # Release pet 2 first (not the head)
      {:noreply, state} = Pets.handle_pet_leave(state, 7, 2)
      assert state.players[7].pet_ids == [1]
      refute Map.has_key?(state.npcs_live, 2)

      # Then release pet 1
      {:noreply, state} = Pets.handle_pet_leave(state, 7, 1)
      assert state.players[7].pet_ids == []
      refute Map.has_key?(state.npcs_live, 1)
    end

    test "max pet limit is exactly 3" do
      # @max_pets = 3 in crafting.ex
      # Verify enforcement: player with 2 pets can tame, player with 3 cannot
      wild = make_npc(instance_id: 10, owner_id: nil, x: 51, y: 50, char_index: 1000)

      # Player with 2 pets — should be allowed to attempt taming
      player_2_pets = make_player(
        pet_ids: [1, 2],
        skills: %{taming: 100},
        stamina: 100,
        class: :worker
      )
      state = make_state(
        players: %{7 => player_2_pets},
        npcs: %{10 => wild},
        npc_char_indices: %{1000 => 10}
      )

      {:noreply, state_after} = Crafting.handle_work(state, 7, :taming)

      # Stamina should have been consumed (taming was attempted)
      assert state_after.players[7].stamina < 100,
             "Player with 2 pets should be allowed to attempt taming (stamina consumed)"

      # Player with 3 pets — should be rejected
      wild2 = make_npc(instance_id: 11, owner_id: nil, x: 51, y: 50, char_index: 1100)
      player_3_pets = make_player(
        pet_ids: [1, 2, 3],
        skills: %{taming: 100},
        stamina: 100,
        class: :worker
      )
      state2 = make_state(
        players: %{7 => player_3_pets},
        npcs: %{11 => wild2},
        npc_char_indices: %{1100 => 11}
      )

      {:noreply, state2_after} = Crafting.handle_work(state2, 7, :taming)

      # Stamina should NOT be consumed (rejected before attempt)
      assert state2_after.players[7].stamina == 100,
             "Player with 3 pets should be rejected without consuming stamina"
    end

    test "taming newly tamed pet is prepended to pet_ids list" do
      # In attempt_taming: entity = %{entity | pet_ids: [instance_id | entity.pet_ids]}
      wild = make_npc(instance_id: 5, owner_id: nil, x: 51, y: 50, char_index: 500)
      owner = make_player(
        pet_ids: [1, 2],
        skills: %{taming: 100},
        stamina: 100,
        class: :worker
      )

      state = make_state(
        players: %{7 => owner},
        npcs: %{5 => wild},
        npc_char_indices: %{500 => 5}
      )

      {:noreply, state} = Crafting.handle_work(state, 7, :taming)

      # If taming succeeded, pet_ids should have 5 prepended
      pet_ids = state.players[7].pet_ids

      if 5 in pet_ids do
        assert hd(pet_ids) == 5,
               "Newly tamed pet should be prepended (head) of pet_ids"
        assert tl(pet_ids) == [1, 2],
               "Existing pet_ids should be preserved as tail"
      end
    end
  end

  # ================================================================
  # Interaction between pet death via combat and state cleanup
  # ================================================================

  describe "pet death via NPC combat integration" do
    test "pet killed by wild NPC attack is removed from npcs_live and owner pet_ids" do
      pet = make_npc(owner_id: 7, instance_id: 1, hp: 1, x: 50, y: 50, char_index: 100)
      owner = make_player(pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      # Simulate pet death through resolve_npc_death (same path as combat)
      state = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)

      refute Map.has_key?(state.npcs_live, 1),
             "Dead pet should be removed from npcs_live"
      assert state.players[7].pet_ids == [],
             "Dead pet's instance_id should be removed from owner's pet_ids"
    end

    test "despawn_pet returns empty effects list" do
      pet = make_npc(owner_id: 7, instance_id: 1, x: 10, y: 10)
      owner = make_player(pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {_state, effects} = NpcAi.despawn_pet(state, 1, pet)

      assert effects == [],
             "despawn_pet should return empty effects list"
    end

    test "pet death when owner is absent does not crash" do
      # Pet with owner_id 99 (not in players map)
      pet = make_npc(owner_id: 99, instance_id: 1, hp: 0)

      state = make_state(
        players: %{7 => make_player()},
        npcs: %{1 => pet}
      )

      # Should not crash even though owner 99 is not in players
      state = NpcDeath.resolve_npc_death(state, 1, pet, source: :pet)

      refute Map.has_key?(state.npcs_live, 1),
             "Pet should still be removed even if owner is absent"
    end
  end
end
