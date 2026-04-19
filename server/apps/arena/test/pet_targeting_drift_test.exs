defmodule Arena.PetTargetingDriftTest do
  @moduledoc """
  Drift #24: PetStand and PetFollow target all pets instead of selected pet.
  Drift #26: PetFollowAll is missing entirely.

  VB6 reference:
    - Protocol.bas:4052 HandlePetStand — uses TargetNPC, single pet, distance <= 10
    - Protocol.bas:4087 HandlePetFollow — uses TargetNPC, single pet, distance <= 10
    - Protocol.bas:4117 HandlePetFollowAll — loops all MascotasIndex, calls FollowAmo on each
    - PacketId.bas: ePetStand=42, ePetFollow=43, ePetFollowAll=309
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
  # Drift #24: pet_stand must target SINGLE pet, not all
  # ================================================================

  describe "pet_stand targets a single pet (drift #24)" do
    test "standing a specific pet only changes that pet's mode" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :follow)
      pet2 = make_npc(owner_id: 7, instance_id: 2, char_index: 200, pet_mode: :follow)
      pet3 = make_npc(owner_id: 7, instance_id: 3, char_index: 300, pet_mode: :follow)
      owner = make_player(pet_ids: [1, 2, 3])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1, 2 => pet2, 3 => pet3},
          npc_char_indices: %{100 => 1, 200 => 2, 300 => 3}
        )

      # Stand only pet 2
      {:noreply, state} = Pets.handle_pet_stand(state, 7, 2)

      assert state.npcs_live[2].pet_mode == :stand,
        "Target pet should be set to :stand"
      assert state.npcs_live[1].pet_mode == :follow,
        "Other pets should remain in :follow mode"
      assert state.npcs_live[3].pet_mode == :follow,
        "Other pets should remain in :follow mode"
    end

    test "standing a pet not owned by player is rejected" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :follow)
      pet2 = make_npc(owner_id: 99, instance_id: 2, char_index: 200, pet_mode: :follow)
      owner = make_player(pet_ids: [1])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1, 2 => pet2},
          npc_char_indices: %{100 => 1, 200 => 2}
        )

      {:noreply, state} = Pets.handle_pet_stand(state, 7, 2)

      assert state.npcs_live[2].pet_mode == :follow,
        "Non-owned pet's mode should be unchanged"
    end

    test "dead player cannot stand a pet" do
      pet = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :follow)
      owner = make_player(dead: true, pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {:noreply, state} = Pets.handle_pet_stand(state, 7, 1)

      assert state.npcs_live[1].pet_mode == :follow,
        "Dead player's pet mode should be unchanged"
    end
  end

  # ================================================================
  # Drift #24: pet_follow must target SINGLE pet, not all
  # ================================================================

  describe "pet_follow targets a single pet (drift #24)" do
    test "following a specific pet only changes that pet's mode" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :stand)
      pet2 = make_npc(owner_id: 7, instance_id: 2, char_index: 200, pet_mode: :stand)
      pet3 = make_npc(owner_id: 7, instance_id: 3, char_index: 300, pet_mode: :stand)
      owner = make_player(pet_ids: [1, 2, 3])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1, 2 => pet2, 3 => pet3},
          npc_char_indices: %{100 => 1, 200 => 2, 300 => 3}
        )

      # Follow only pet 2
      {:noreply, state} = Pets.handle_pet_follow(state, 7, 2)

      assert state.npcs_live[2].pet_mode == :follow,
        "Target pet should be set to :follow"
      assert state.npcs_live[1].pet_mode == :stand,
        "Other pets should remain in :stand mode"
      assert state.npcs_live[3].pet_mode == :stand,
        "Other pets should remain in :stand mode"
    end

    test "following a pet not owned by player is rejected" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :stand)
      pet2 = make_npc(owner_id: 99, instance_id: 2, char_index: 200, pet_mode: :stand)
      owner = make_player(pet_ids: [1])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1, 2 => pet2},
          npc_char_indices: %{100 => 1, 200 => 2}
        )

      {:noreply, state} = Pets.handle_pet_follow(state, 7, 2)

      assert state.npcs_live[2].pet_mode == :stand,
        "Non-owned pet's mode should be unchanged"
    end

    test "dead player cannot follow a pet" do
      pet = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :stand)
      owner = make_player(dead: true, pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {:noreply, state} = Pets.handle_pet_follow(state, 7, 1)

      assert state.npcs_live[1].pet_mode == :stand,
        "Dead player's pet mode should be unchanged"
    end
  end

  # ================================================================
  # Drift #26: pet_follow_all must exist and affect ALL owned pets
  # ================================================================

  describe "pet_follow_all affects all owned pets (drift #26)" do
    test "makes all owned pets follow" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :stand)
      pet2 = make_npc(owner_id: 7, instance_id: 2, char_index: 200, pet_mode: :stand)
      pet3 = make_npc(owner_id: 7, instance_id: 3, char_index: 300, pet_mode: :stand)
      owner = make_player(pet_ids: [1, 2, 3])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1, 2 => pet2, 3 => pet3},
          npc_char_indices: %{100 => 1, 200 => 2, 300 => 3}
        )

      {:noreply, state} = Pets.handle_pet_follow_all(state, 7)

      assert state.npcs_live[1].pet_mode == :follow,
        "First pet should be set to :follow"
      assert state.npcs_live[2].pet_mode == :follow,
        "Second pet should be set to :follow"
      assert state.npcs_live[3].pet_mode == :follow,
        "Third pet should be set to :follow"
    end

    test "does not affect pets owned by other players" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :stand)
      other_pet = make_npc(owner_id: 99, instance_id: 2, char_index: 200, pet_mode: :stand)
      owner = make_player(pet_ids: [1])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1, 2 => other_pet},
          npc_char_indices: %{100 => 1, 200 => 2}
        )

      {:noreply, state} = Pets.handle_pet_follow_all(state, 7)

      assert state.npcs_live[1].pet_mode == :follow,
        "Owned pet should be set to :follow"
      assert state.npcs_live[2].pet_mode == :stand,
        "Other player's pet should remain unchanged"
    end

    test "dead player cannot use pet_follow_all" do
      pet = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :stand)
      owner = make_player(dead: true, pet_ids: [1])

      state = make_state(players: %{7 => owner}, npcs: %{1 => pet})

      {:noreply, state} = Pets.handle_pet_follow_all(state, 7)

      assert state.npcs_live[1].pet_mode == :stand,
        "Dead player's pets should remain unchanged"
    end

    test "skips nil/missing npcs in pet_ids" do
      pet1 = make_npc(owner_id: 7, instance_id: 1, char_index: 100, pet_mode: :stand)
      # pet_ids lists instance 999 which doesn't exist
      owner = make_player(pet_ids: [1, 999])

      state =
        make_state(
          players: %{7 => owner},
          npcs: %{1 => pet1},
          npc_char_indices: %{100 => 1}
        )

      {:noreply, state} = Pets.handle_pet_follow_all(state, 7)

      assert state.npcs_live[1].pet_mode == :follow,
        "Existing pet should be set to :follow"
    end
  end

  # ================================================================
  # Decoder tests for pet_stand and pet_follow carrying pet_id
  # ================================================================

  describe "decoder: pet_stand (ID 42) reads pet_id" do
    test "decodes pet_stand with Int16 pet_id" do
      # Packet ID 42, followed by Int16 pet_id = 5 (little-endian)
      payload = <<42::little-signed-16, 5::little-signed-16>>
      assert {:ok, {:pet_stand, %{pet_id: 5}}, <<>>} = AoProtocol.Client.Decoder.decode(payload)
    end
  end

  describe "decoder: pet_follow (ID 43) reads pet_id" do
    test "decodes pet_follow with Int16 pet_id" do
      payload = <<43::little-signed-16, 5::little-signed-16>>
      assert {:ok, {:pet_follow, %{pet_id: 5}}, <<>>} = AoProtocol.Client.Decoder.decode(payload)
    end
  end

  describe "decoder: pet_follow_all (ID 309) is bare" do
    test "decodes pet_follow_all with no payload" do
      payload = <<309::little-signed-16>>
      assert {:ok, {:pet_follow_all, %{}}, <<>>} = AoProtocol.Client.Decoder.decode(payload)
    end
  end
end
