defmodule Arena.PetLeaveDriftTest do
  @moduledoc """
  Drift #25: pet_leave removes first pet, not selected pet.

  VB6 behavior: HandlePetLeave uses TargetNPC to identify which pet
  to release. The Elixir server must accept a pet instance ID and
  remove that specific pet — not always the head of pet_ids.
  """
  use ExUnit.Case, async: true

  alias Arena.Entity.NpcEntity
  alias Arena.Map.Pets

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
  # Drift #25: pet_leave must remove the SPECIFIED pet, not first
  # ================================================================

  describe "pet_leave removes the specified pet (drift #25)" do
    test "releasing the second pet keeps the first and third" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100)
      pet2 = make_npc(owner_id: 7, instance_id: 2, char_index: 200)
      pet3 = make_npc(owner_id: 7, instance_id: 3, char_index: 300)
      owner = make_player(pet_ids: [1, 2, 3])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1, 2 => pet2, 3 => pet3},
          npc_char_indices: %{100 => 1, 200 => 2, 300 => 3}
        )

      # Release pet 2 specifically (the middle one)
      {:noreply, state} = Pets.handle_pet_leave(state, 7, 2)

      # Pet 2 should be gone
      refute Map.has_key?(state.npcs_live, 2),
        "Selected pet (instance 2) should be released"

      # Pets 1 and 3 remain
      assert Map.has_key?(state.npcs_live, 1),
        "First pet should remain when second was released"
      assert Map.has_key?(state.npcs_live, 3),
        "Third pet should remain when second was released"

      # pet_ids should be [1, 3]
      assert state.players[7].pet_ids == [1, 3],
        "pet_ids should only have the released pet removed"
    end

    test "releasing the last pet keeps the others" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100)
      pet2 = make_npc(owner_id: 7, instance_id: 2, char_index: 200)
      pet3 = make_npc(owner_id: 7, instance_id: 3, char_index: 300)
      owner = make_player(pet_ids: [1, 2, 3])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1, 2 => pet2, 3 => pet3},
          npc_char_indices: %{100 => 1, 200 => 2, 300 => 3}
        )

      # Release pet 3 (the last one)
      {:noreply, state} = Pets.handle_pet_leave(state, 7, 3)

      refute Map.has_key?(state.npcs_live, 3),
        "Last pet should be released"
      assert state.players[7].pet_ids == [1, 2],
        "Only the released pet should be removed from pet_ids"
    end

    test "releasing a pet not owned by the player is rejected" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100)
      pet2 = make_npc(owner_id: 99, instance_id: 2, char_index: 200)
      owner = make_player(pet_ids: [1])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1, 2 => pet2},
          npc_char_indices: %{100 => 1, 200 => 2}
        )

      # Try to release pet 2, which belongs to another player
      {:noreply, state} = Pets.handle_pet_leave(state, 7, 2)

      # Pet 2 should still exist — not owned by player 7
      assert Map.has_key?(state.npcs_live, 2),
        "Pet not owned by player should not be released"
      assert state.players[7].pet_ids == [1],
        "Player's pet_ids should be unchanged"
    end

    test "releasing a nonexistent pet_id is a no-op" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100)
      owner = make_player(pet_ids: [1])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1},
          npc_char_indices: %{100 => 1}
        )

      # Try to release pet 999 which doesn't exist
      {:noreply, state} = Pets.handle_pet_leave(state, 7, 999)

      assert Map.has_key?(state.npcs_live, 1),
        "Existing pet should remain"
      assert state.players[7].pet_ids == [1],
        "pet_ids should be unchanged"
    end

    test "dead player cannot release a specific pet" do
      pet = make_npc(owner_id: 7, instance_id: 1, pet_mode: :follow)
      owner = make_player(dead: true, pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {:noreply, state} = Pets.handle_pet_leave(state, 7, 1)

      assert Map.has_key?(state.npcs_live, 1),
        "Dead player should not be able to release pets"
      assert state.players[7].pet_ids == [1],
        "Dead player's pet_ids should be unchanged"
    end
  end
end
