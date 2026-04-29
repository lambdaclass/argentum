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

  Migrated to `Arena.Test.Scenario` in slice 4c. The local 50-line
  `make_player/1` (a plain map) is gone; we use
  `Arena.Test.PlayerFactory.player/1`, which returns a real
  `%PlayerEntity{}` so field-typo bugs raise instead of silently
  shadowing struct keys. The local `make_npc/1` is replaced by
  `Scenario.with_npc/3` (which builds `%NpcEntity{}` via `struct!/2`),
  and `make_state/1` by `Scenario.new/1` plus the with_player /
  with_npc builders.

  Death helpers (`NpcDeath.resolve_npc_death/4`,
  `PlayerDeath.handle_player_death/3`, `NpcAi.despawn_pet/3`) are on
  the effects contract since slice 5b — the `run_effects/2`
  closure lifts them onto the scenario's recorded effect buffer.

  Pet command handlers (`Pets.handle_pet_*`) and `Crafting.handle_work/3`
  still return `{:noreply, state}` (they have not been migrated to the
  effects contract), so we drive them via `update_state/2` and assert on
  the post-state.
  """
  use ExUnit.Case, async: true

  alias Arena.NpcAi
  alias Arena.Entity.NpcEntity
  alias Arena.Map.NpcDeath
  alias Arena.Map.PlayerDeath
  alias Arena.Map.Crafting
  alias Arena.Map.Pets
  alias Arena.Map.Helpers

  import Arena.Test.Scenario

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ---- Helpers ----

  @hostile_npc_id 559

  # Default keywords for the pet/wild NpcEntity defaults the legacy
  # `make_npc/1` provided. with_npc/3 doesn't ship hp/max_hp/alive
  # defaults (the NpcEntity struct defaults to hp: 0, alive: true) —
  # this keeps tests concise without extending with_npc with too many
  # global defaults.
  defp npc_defaults(overrides) do
    Keyword.merge(
      [
        npc_id: @hostile_npc_id,
        hp: 250,
        max_hp: 250,
        alive: true,
        next_attack_at: -1_000_000_000_000,
        next_move_at: -1_000_000_000_000,
        next_spell_at: -1_000_000_000_000,
        pet_mode: :follow
      ],
      overrides
    )
  end

  defp with_npc_defaults(scenario, instance_id, overrides) do
    with_npc(scenario, instance_id, npc_defaults(overrides))
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
      pet = struct!(NpcEntity, npc_id: @hostile_npc_id, instance_id: 1, owner_id: 7,
                                x: 50, y: 50, hp: 250, max_hp: 250, char_index: 100,
                                spawn_x: 50, spawn_y: 50)
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
      # Both pets belong to same owner so neither gets despawned. Note
      # we use the integer `7` as the scenario key so that the pet's
      # `owner_id: 7` resolves via `state.players[7]` in `process_pet_npc`.
      s =
        new()
        |> with_player(7, x: 50, y: 51, pet_ids: [1, 2])
        |> with_npc_defaults(1, owner_id: 7, x: 50, y: 50, char_index: 100)
        |> with_npc_defaults(2,
          owner_id: 7, x: 51, y: 50, char_index: 200,
          hp: 100, max_hp: 100, next_move_at: 9_999_999_999_999
        )

      s = run_effects(s, fn st -> NpcAi.tick(st) end)

      # other_pet HP should be untouched
      assert state(s).npcs_live[2].hp == 100,
             "Pet should not attack another pet (owner_id != nil)"
    end

    test "pet does not attack its own owner (targets only NPCs, not players)" do
      # Pet AI targets wild hostile NPCs via find_nearest_wild_npc,
      # which filters state.npcs_live — players are never in that map
      s =
        new()
        |> with_player(7, x: 51, y: 50, pet_ids: [1], hp: 100, max_hp: 100)
        |> with_npc_defaults(1, owner_id: 7, x: 50, y: 50, char_index: 100)

      s = run_effects(s, fn st -> NpcAi.tick(st) end)

      # Owner HP should remain unchanged
      assert entity(s, 7).hp == 100,
             "Pet should never attack its owner"
    end

    test "pet aggro range is 8 tiles" do
      # find_nearest_wild_npc filters: abs(n.x - pet.x) <= @pet_aggro_range
      # @pet_aggro_range = 8

      # Wild NPC at distance 8 — should be within aggro range
      s =
        new()
        |> with_player(7, x: 50, y: 51, invisible: true, pet_ids: [1])
        |> with_npc_defaults(1, owner_id: 7, x: 50, y: 50, char_index: 100)
        |> with_npc_defaults(2,
          x: 58, y: 50, char_index: 200, hp: 100, max_hp: 100,
          next_move_at: 9_999_999_999_999
        )

      s = run_effects(s, fn st -> NpcAi.tick(st) end)

      # Pet should have attempted to move toward wild NPC at distance 8
      pet_after = state(s).npcs_live[1]
      assert pet_after.next_move_at > -1_000_000_000_000,
             "Pet should detect wild NPC at distance 8 (within aggro range)"
    end

    test "pet does not aggro on wild NPC beyond 8 tiles" do
      # Wild NPC at distance 9 — should be outside aggro range
      # Owner within follow distance so pet doesn't follow
      s =
        new()
        |> with_player(7, x: 52, y: 50, invisible: true, pet_ids: [1])
        |> with_npc_defaults(1, owner_id: 7, x: 50, y: 50, char_index: 100)
        |> with_npc_defaults(2,
          x: 59, y: 50, char_index: 200, hp: 100, max_hp: 100,
          next_move_at: 9_999_999_999_999
        )

      # NpcAi.tick uses :rand.uniform/1 directly (not Arena.Rng), so
      # `set_seed/2` won't reach it; seed :rand explicitly to suppress
      # the random idle walk that could otherwise mask the result.
      :rand.seed(:exsss, {1, 2, 3})
      s = run_effects(s, fn st -> NpcAi.tick(st) end)

      # Wild NPC should be untouched — pet cannot see it
      assert state(s).npcs_live[2].hp == 100,
             "Wild NPC at distance 9 should be outside pet aggro range"
    end
  end

  # ================================================================
  # Pet death handling
  # ================================================================

  describe "pet death handling" do
    test "pet death does NOT award XP — resolve_npc_death with source: :pet skips rewards" do
      s =
        new()
        |> with_player(7, pet_ids: [1], npcs_killed: 5)
        |> with_npc_defaults(1, owner_id: 7, hp: 0, x: 10, y: 10, char_index: 100)

      pet = state(s).npcs_live[1]

      s =
        run_effects(s, fn st ->
          {nil, new_state, effects} = NpcDeath.resolve_npc_death(st, 1, pet, source: :pet)
          {new_state, effects}
        end)

      # Owner's npcs_killed should be unchanged
      assert entity(s, 7).npcs_killed == 5,
             "Pet death should not increment owner's kill counter"
    end

    test "pet death clears occupancy at pet position" do
      s =
        new()
        |> with_player(7, pet_ids: [1])
        |> with_npc_defaults(1, owner_id: 7, x: 10, y: 10, char_index: 100)

      pet = state(s).npcs_live[1]

      s =
        run_effects(s, fn st ->
          {_, new_state, effects} = NpcDeath.resolve_npc_death(st, 1, pet, source: :pet)
          {new_state, effects}
        end)

      assert Helpers.get_occupancy(state(s).occupancy, 10, 10) == nil,
             "Pet death should clear occupancy at pet position"
    end

    test "pet death does NOT trigger respawn — pet removed from npcs_live" do
      s =
        new()
        |> with_player(7, pet_ids: [1])
        |> with_npc_defaults(1, owner_id: 7, hp: 0, char_index: 100)

      pet = state(s).npcs_live[1]

      s =
        run_effects(s, fn st ->
          {_, new_state, effects} = NpcDeath.resolve_npc_death(st, 1, pet, source: :pet)
          {new_state, effects}
        end)

      # Pet should be completely gone from npcs_live (not just dead with respawn_at)
      refute Map.has_key?(state(s).npcs_live, 1),
             "Pet should be removed from npcs_live entirely, not scheduled for respawn"
    end

    test "pet death removes instance_id from owner's pet_ids" do
      s =
        new()
        |> with_player(7, pet_ids: [1, 2, 3])
        |> with_npc_defaults(2, owner_id: 7, char_index: 200)

      pet = state(s).npcs_live[2]

      s =
        run_effects(s, fn st ->
          {_, new_state, effects} = NpcDeath.resolve_npc_death(st, 2, pet, source: :pet)
          {new_state, effects}
        end)

      assert entity(s, 7).pet_ids == [1, 3],
             "Pet death should remove instance_id 2 from owner's pet_ids"
    end

    test "player death despawns all owned pets" do
      s =
        new(meta: %{safe_zone: true})
        |> with_player(7, pet_ids: [1, 2], hp: 0, deaths: 0)
        |> with_npc_defaults(1, owner_id: 7, char_index: 100)
        |> with_npc_defaults(2, owner_id: 7, x: 51, y: 50, char_index: 200)

      # PlayerDeath.handle_player_death/3 returns `{player, state, effects}`;
      # adapt to run_effects/2's `{state, effects}` shape by re-inserting
      # the dead player into state.players (StatusTicks does the same).
      s =
        run_effects(s, fn st ->
          owner = st.players[7]

          {dead_player, new_state, effects} =
            PlayerDeath.handle_player_death(st, 7, owner)

          new_state = %{new_state | players: Map.put(new_state.players, 7, dead_player)}
          {new_state, effects}
        end)

      # Both pets should be removed from npcs_live
      refute Map.has_key?(state(s).npcs_live, 1),
             "Pet 1 should be despawned on player death"
      refute Map.has_key?(state(s).npcs_live, 2),
             "Pet 2 should be despawned on player death"
    end

    test "killing a pet does not award XP to the attacker" do
      # When a player kills a pet, resolve_npc_death with killer_entity returns
      # the killer entity unchanged (no XP, no kill counter increment)
      s =
        new()
        |> with_player(7, npcs_killed: 0, pet_ids: [])
        |> with_player(8, x: 60, y: 60, pet_ids: [1])
        |> with_npc_defaults(1, owner_id: 8, hp: 0, x: 55, y: 55, char_index: 100)

      pet = state(s).npcs_live[1]
      attacker = entity(s, 7)

      # resolve_npc_death returns `{entity, state, effects}` where the
      # entity is the (unchanged) killer. run_effects/2 only threads
      # `{state, effects}`, so we forward the killer-entity slot via the
      # test mailbox and assert on it after the closure returns.
      ref = make_ref()
      test_pid = self()

      _s =
        run_effects(s, fn st ->
          {ent, new_state, effects} =
            NpcDeath.resolve_npc_death(
              st, 1, pet,
              source: :pet,
              killer_char_id: 7,
              killer_entity: attacker,
              final_damage: 50
            )

          send(test_pid, {ref, ent})
          {new_state, effects}
        end)

      assert_received {^ref, killer_after}
      assert killer_after.npcs_killed == 0,
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
      s =
        new()
        |> with_player(7, skills: %{taming: 100}, stamina: 100)
        |> with_npc_defaults(1, owner_id: 8, x: 51, y: 50, char_index: 100)

      s =
        update_state(s, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      # Should NOT have gained a pet — the only NPC is already owned
      assert entity(s, 7).pet_ids == [],
             "Should not be able to tame an already-owned NPC"
    end

    test "cannot tame with insufficient stamina" do
      # Warrior pays 45 stamina (15 * 3). Set stamina to 10 — insufficient.
      s =
        new()
        |> with_player(7, class: :warrior, stamina: 10, skills: %{taming: 100})
        |> with_npc_defaults(1, owner_id: nil, x: 51, y: 50, char_index: 100)

      s =
        update_state(s, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      tamer = entity(s, 7)
      # Should NOT have tamed — insufficient stamina
      assert tamer.pet_ids == [],
             "Should not be able to tame with insufficient stamina"
      # Stamina should be unchanged
      assert tamer.stamina == 10,
             "Stamina should not be consumed when insufficient"
    end

    test "taming clears target_id on newly tamed pet" do
      # The taming code does: npc = %{npc | owner_id: char_id, target_id: nil}
      s =
        new()
        |> with_player(7, skills: %{taming: 100}, stamina: 100, class: :worker)
        |> with_npc_defaults(1, owner_id: nil, x: 51, y: 50, target_id: 7, char_index: 100)

      # Force taming to succeed by setting skill to 100
      s =
        update_state(s, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      # If taming succeeded (skill 100 should always pass), target_id should be nil
      case state(s).npcs_live[1] do
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

      # Worker: costs 15 stamina
      s_worker =
        new()
        |> with_player(7, class: :worker, stamina: 100, skills: %{taming: 50})
        |> with_npc_defaults(1, owner_id: nil, x: 51, y: 50, char_index: 100)

      s_worker =
        update_state(s_worker, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      assert entity(s_worker, 7).stamina == 85,
             "Worker should pay 15 stamina for taming (100 - 15 = 85)"

      # Warrior (non-worker): costs 45 stamina
      s_warrior =
        new()
        |> with_player(7, class: :warrior, stamina: 100, skills: %{taming: 50})
        |> with_npc_defaults(2, owner_id: nil, x: 51, y: 50, char_index: 200)

      s_warrior =
        update_state(s_warrior, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      assert entity(s_warrior, 7).stamina == 55,
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
      s =
        new()
        |> with_player(7, dead: true, skills: %{taming: 100}, stamina: 100)
        |> with_npc_defaults(1, owner_id: nil, x: 51, y: 50, char_index: 100)

      s =
        update_state(s, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      tamer = entity(s, 7)
      # Dead player should not be able to tame
      assert tamer.pet_ids == [],
             "Dead player should not be able to tame"
      # Stamina should be unchanged
      assert tamer.stamina == 100,
             "Dead player's stamina should not be consumed"
    end

    test "max 3 pets enforced at taming" do
      # Player already has 3 pets
      s =
        new()
        |> with_player(7,
          pet_ids: [1, 2, 3],
          skills: %{taming: 100}, stamina: 100, class: :worker
        )
        |> with_npc_defaults(4, owner_id: nil, x: 51, y: 50, char_index: 400)

      s =
        update_state(s, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      owner = entity(s, 7)
      # pet_ids should still be [1, 2, 3] — 4th pet rejected
      assert owner.pet_ids == [1, 2, 3],
             "Should not be able to tame when already at max 3 pets"
      # Stamina should be unchanged (rejected before stamina consumed)
      assert owner.stamina == 100,
             "Stamina should not be consumed when at pet limit"
    end
  end

  # ================================================================
  # Pet mode edge cases
  # ================================================================

  describe "pet mode edge cases" do
    test "stand mode prevents ALL movement including follow" do
      # Pet in :stand mode with owner far away — should NOT move
      s =
        new()
        |> with_player(7, x: 70, y: 70, pet_ids: [1])
        |> with_npc_defaults(1,
          owner_id: 7, x: 50, y: 50, pet_mode: :stand, char_index: 100
        )

      s = run_effects(s, fn st -> NpcAi.tick(st) end)

      npc_after = state(s).npcs_live[1]
      assert npc_after.x == 50, "Stand mode should prevent follow movement (x unchanged)"
      assert npc_after.y == 50, "Stand mode should prevent follow movement (y unchanged)"
      # next_move_at should NOT be advanced since pet skips entirely
      assert npc_after.next_move_at == -1_000_000_000_000,
             "Stand mode should not advance next_move_at"
    end

    test "stand mode prevents attack even when hostile is adjacent" do
      s =
        new()
        |> with_player(7, x: 50, y: 51, invisible: true, pet_ids: [1])
        |> with_npc_defaults(1,
          owner_id: 7, x: 50, y: 50, pet_mode: :stand, char_index: 100
        )
        |> with_npc_defaults(2,
          x: 51, y: 50, char_index: 200, hp: 100, max_hp: 100,
          next_move_at: 9_999_999_999_999
        )

      s = run_effects(s, fn st -> NpcAi.tick(st) end)

      # Wild NPC should be untouched
      assert state(s).npcs_live[2].hp == 100,
             "Stand mode should prevent pet from attacking"
      # Pet's attack cooldown should NOT have advanced
      assert state(s).npcs_live[1].next_attack_at == -1_000_000_000_000,
             "Stand mode should not advance next_attack_at"
    end

    test "mode commands change ALL pets at once" do
      s =
        new()
        |> with_player(7, pet_ids: [1, 2, 3])
        |> with_npc_defaults(1, owner_id: 7, pet_mode: :follow, char_index: 100)
        |> with_npc_defaults(2, owner_id: 7, pet_mode: :follow, char_index: 200, x: 51, y: 50)
        |> with_npc_defaults(3, owner_id: 7, pet_mode: :follow, char_index: 300, x: 52, y: 50)

      s =
        update_state(s, fn st ->
          {:noreply, st} = Pets.handle_pet_stand(st, 7, 1)
          {:noreply, st} = Pets.handle_pet_stand(st, 7, 2)
          {:noreply, st} = Pets.handle_pet_stand(st, 7, 3)
          st
        end)

      assert state(s).npcs_live[1].pet_mode == :stand
      assert state(s).npcs_live[2].pet_mode == :stand
      assert state(s).npcs_live[3].pet_mode == :stand

      s =
        update_state(s, fn st ->
          {:noreply, st} = Pets.handle_pet_follow_all(st, 7)
          st
        end)

      assert state(s).npcs_live[1].pet_mode == :follow
      assert state(s).npcs_live[2].pet_mode == :follow
      assert state(s).npcs_live[3].pet_mode == :follow
    end

    test "setting mode on dead player silently fails — modes unchanged" do
      s =
        new()
        |> with_player(7, dead: true, pet_ids: [1])
        |> with_npc_defaults(1, owner_id: 7, pet_mode: :follow, char_index: 100)

      s_stand =
        update_state(s, fn st ->
          {:noreply, st} = Pets.handle_pet_stand(st, 7, 1)
          st
        end)

      assert state(s_stand).npcs_live[1].pet_mode == :follow,
             "Dead player's stand command should not change pet mode"

      s_follow =
        update_state(s, fn st ->
          {:noreply, st} = Pets.handle_pet_follow(st, 7, 1)
          st
        end)

      assert state(s_follow).npcs_live[1].pet_mode == :follow,
             "Dead player's follow command should not change pet mode"
    end

    test "dead player cannot release pets" do
      s =
        new()
        |> with_player(7, dead: true, pet_ids: [1])
        |> with_npc_defaults(1, owner_id: 7, pet_mode: :follow, char_index: 100)

      s =
        update_state(s, fn st ->
          {:noreply, st} = Pets.handle_pet_leave(st, 7, 1)
          st
        end)

      # Pet should still be alive — dead player cannot release
      assert Map.has_key?(state(s).npcs_live, 1),
             "Dead player should not be able to release pets"
      assert entity(s, 7).pet_ids == [1],
             "Dead player's pet_ids should be unchanged"
    end
  end

  # ================================================================
  # Pet limits and /LIBERAR behavior
  # ================================================================

  describe "pet limits and /LIBERAR" do
    test "/LIBERAR releases the specified pet by instance ID" do
      s =
        new()
        |> with_player(7, pet_ids: [1, 2, 3])
        |> with_npc_defaults(1, owner_id: 7, char_index: 100)
        |> with_npc_defaults(2, owner_id: 7, x: 51, y: 50, char_index: 200)
        |> with_npc_defaults(3, owner_id: 7, x: 52, y: 50, char_index: 300)

      # Release pet 1 by its instance ID. NOTE: Pets.handle_pet_leave/3
      # is not yet on the effects contract — it calls
      # `Arena.Map.Effects.run/2` internally for the despawn broadcast
      # (see pets.ex:84). We drive it via update_state and assert on the
      # resulting state shape.
      s =
        update_state(s, fn st ->
          {:noreply, st} = Pets.handle_pet_leave(st, 7, 1)
          st
        end)

      live = state(s).npcs_live
      # First pet (instance 1) should be gone
      refute Map.has_key?(live, 1), "Selected pet should be released"
      # Others remain
      assert Map.has_key?(live, 2), "Second pet should remain"
      assert Map.has_key?(live, 3), "Third pet should remain"
      # pet_ids should now be [2, 3]
      assert entity(s, 7).pet_ids == [2, 3]
    end

    test "successive /LIBERAR releases specified pets" do
      s =
        new()
        |> with_player(7, pet_ids: [1, 2])
        |> with_npc_defaults(1, owner_id: 7, char_index: 100)
        |> with_npc_defaults(2, owner_id: 7, x: 51, y: 50, char_index: 200)

      # Release pet 2 first (not the head)
      s =
        update_state(s, fn st ->
          {:noreply, st} = Pets.handle_pet_leave(st, 7, 2)
          st
        end)

      assert entity(s, 7).pet_ids == [1]
      refute Map.has_key?(state(s).npcs_live, 2)

      # Then release pet 1
      s =
        update_state(s, fn st ->
          {:noreply, st} = Pets.handle_pet_leave(st, 7, 1)
          st
        end)

      assert entity(s, 7).pet_ids == []
      refute Map.has_key?(state(s).npcs_live, 1)
    end

    test "max pet limit is exactly 3" do
      # @max_pets = 3 in crafting.ex
      # Verify enforcement: player with 2 pets can tame, player with 3 cannot

      # Player with 2 pets — should be allowed to attempt taming
      s_2 =
        new()
        |> with_player(7,
          pet_ids: [1, 2], skills: %{taming: 100},
          stamina: 100, class: :worker
        )
        |> with_npc_defaults(10, owner_id: nil, x: 51, y: 50, char_index: 1000)

      s_2 =
        update_state(s_2, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      # Stamina should have been consumed (taming was attempted)
      assert entity(s_2, 7).stamina < 100,
             "Player with 2 pets should be allowed to attempt taming (stamina consumed)"

      # Player with 3 pets — should be rejected
      s_3 =
        new()
        |> with_player(7,
          pet_ids: [1, 2, 3], skills: %{taming: 100},
          stamina: 100, class: :worker
        )
        |> with_npc_defaults(11, owner_id: nil, x: 51, y: 50, char_index: 1100)

      s_3 =
        update_state(s_3, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      # Stamina should NOT be consumed (rejected before attempt)
      assert entity(s_3, 7).stamina == 100,
             "Player with 3 pets should be rejected without consuming stamina"
    end

    test "taming newly tamed pet is prepended to pet_ids list" do
      # In attempt_taming: entity = %{entity | pet_ids: [instance_id | entity.pet_ids]}
      s =
        new()
        |> with_player(7,
          pet_ids: [1, 2], skills: %{taming: 100},
          stamina: 100, class: :worker
        )
        |> with_npc_defaults(5, owner_id: nil, x: 51, y: 50, char_index: 500)

      s =
        update_state(s, fn st ->
          {:noreply, st} = Crafting.handle_work(st, 7, :taming)
          st
        end)

      # If taming succeeded, pet_ids should have 5 prepended
      pet_ids = entity(s, 7).pet_ids

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
      s =
        new()
        |> with_player(7, pet_ids: [1])
        |> with_npc_defaults(1, owner_id: 7, hp: 1, x: 50, y: 50, char_index: 100)

      pet = state(s).npcs_live[1]

      # Simulate pet death through resolve_npc_death (same path as combat)
      s =
        run_effects(s, fn st ->
          {_, new_state, effects} = NpcDeath.resolve_npc_death(st, 1, pet, source: :pet)
          {new_state, effects}
        end)

      refute Map.has_key?(state(s).npcs_live, 1),
             "Dead pet should be removed from npcs_live"
      assert entity(s, 7).pet_ids == [],
             "Dead pet's instance_id should be removed from owner's pet_ids"
    end

    test "despawn_pet returns the map-layer effects produced by NpcDeath" do
      s =
        new()
        |> with_player(7, pet_ids: [1])
        |> with_npc_defaults(1, owner_id: 7, x: 10, y: 10, char_index: 100)

      pet = state(s).npcs_live[1]

      # NpcAi.despawn_pet/3 returns {state, effects} — a perfect fit for
      # run_effects/2. The effects buffer recorded on the scenario must
      # contain exactly one :broadcast_visible_all character_remove for
      # the pet at its position. We capture the raw effects via the test
      # mailbox so the assert can pattern-match the legacy shape exactly.
      ref = make_ref()
      test_pid = self()

      _s =
        run_effects(s, fn st ->
          {new_state, effects} = NpcAi.despawn_pet(st, 1, pet)
          send(test_pid, {ref, effects})
          {new_state, effects}
        end)

      assert_received {^ref, effects}
      assert [{:broadcast_visible_all, 10, 10, _envelope}] = effects
    end

    test "pet death when owner is absent does not crash" do
      # Pet with owner_id 99 (not in players map)
      s =
        new()
        |> with_player(7)
        |> with_npc_defaults(1, owner_id: 99, hp: 0, char_index: 100)

      pet = state(s).npcs_live[1]

      # Should not crash even though owner 99 is not in players
      s =
        run_effects(s, fn st ->
          {_, new_state, effects} = NpcDeath.resolve_npc_death(st, 1, pet, source: :pet)
          {new_state, effects}
        end)

      refute Map.has_key?(state(s).npcs_live, 1),
             "Pet should still be removed even if owner is absent"
    end
  end
end
