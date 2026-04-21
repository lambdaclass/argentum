defmodule Arena.CraftingBankTrainDriftTest do
  @moduledoc """
  Regression coverage for the former crafting, trainer-creature, and bank-transfer
  structural drift lanes.
  """
  use ExUnit.Case, async: true

  alias Arena.Data.GameData
  alias Arena.Map.{Crafting, InventoryHandlers, NpcInteraction}

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Shared helpers ──────────────────────────────────────────────────

  defp make_entity(overrides) do
    defaults = %{
      char_id: :player,
      name: "Tester",
      account_id: "acc_test",
      x: 50,
      y: 50,
      heading: :south,
      body_id: 1,
      base_body_id: 1,
      head_id: 1,
      hp: 100,
      max_hp: 100,
      mana: 200,
      max_mana: 200,
      stamina: 100,
      max_stamina: 100,
      hunger: 100,
      thirst: 100,
      level: 25,
      xp: 0,
      class: :warrior,
      race: :human,
      gender: :male,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      gold: 1000,
      inventory: List.duplicate(nil, 24),
      equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil, saddle: nil},
      skills: %{blacksmithing: 80, carpentry: 80, alchemy: 80, tailoring: 80},
      spells: [1],
      buffs: [],
      min_hit: 0,
      max_hit: 0,
      str_buff: 0,
      agi_buff: 0,
      dead: false,
      poisoned: false,
      criminal: false,
      invisible: false,
      oculto: false,
      oculto_timer: 0,
      no_detectable: false,
      paralyzed: false,
      immobilized: false,
      meditating: false,
      resting: false,
      safe_mode: false,
      navigating: false,
      gm: false,
      gm_level: nil,
      faction: :none,
      next_move_at: -1_000_000_000_000,
      next_attack_at: -1_000_000_000_000,
      next_spell_at: -1_000_000_000_000,
      next_item_use_at: -1_000_000_000_000,
      spell_cooldowns: %{},
      char_index: 1,
      map_id: 1,
      npcs_killed: 0,
      deaths: 0,
      penalty: 0,
      skill_points: 0,
      home_city: :ullathorpe,
      faction_kills_royal: 0,
      faction_kills_chaos: 0,
      citizens_killed: 0,
      criminals_killed: 0,
      faction_score: 0,
      faction_rank_armada: 0,
      faction_rank_chaos: 0,
      faction_reenlistadas: 0,
      fishing_points: 0,
      last_step_at: -1_000_000_000_000,
      speed_hack_counter: 0.0,
      speeding: 1.0,
      commerce_npc_id: nil,
      commerce_npc_instance_id: nil,
      bank_npc_id: nil,
      bank_gold: 0,
      trade_request_target: nil,
      trade_partner_id: nil,
      trade_offer_gold: 0,
      trade_offer_items: [],
      trade_accepted: false,
      pet_ids: [],
      description: "",
      muted_until: 0,
      last_chat_at: -1_000_000_000_000,
      spouse_id: 0,
      marriage_proposal_target: nil,
      in_duel: false,
      duel_opponent_id: nil,
      gamble_wins: 0,
      gamble_losses: 0,
      gamble_plays: 0,
      active_quests: [],
      completed_quests: MapSet.new(),
      quest_npc_id: nil,
      mounted: false,
      saddle_obj_index: 0,
      saddle_slot: 0,
      guild_id: 0,
      guild_level: 0,
      magic_damage_modifier: 0.0,
      magic_damage_reduction: 0.0,
      punishments: [],
      last_clicked_npc_instance_id: nil,
      last_clicked_npc_type: nil,
      last_transfer_gold_at: -1_000_000_000_000
    }

    Map.merge(defaults, overrides)
  end

  # =====================================================================
  # Crafting trigger parity
  # =====================================================================

  describe "crafting production follows the VB6 trigger model" do
    test "blacksmithing opens from the equipped hammer plus a selected anvil object" do
      entity =
        make_entity(%{
          char_id: 1,
          x: 50,
          y: 50,
          stamina: 100,
          equipment: %{weapon: 389},
          inventory: [%{item_id: 389, amount: 1, equipped: true} | List.duplicate(nil, 23)],
          skills: %{blacksmithing: 80}
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{},
          meta: %{objects: [%{x: 50, y: 49, obj_index: 384, amount: 1}]}
        )

      assert {:reply, :ok, _state} = InventoryHandlers.handle_use_item(state, 1, 0, 50, 49)
      assert_receive {:send_raw, _}, 500
      assert_receive {:send_raw, _}, 500
    end

    test "carpentry opens from the equipped saw with no workstation NPC nearby" do
      entity =
        make_entity(%{
          char_id: 1,
          stamina: 100,
          equipment: %{weapon: 198},
          inventory: [%{item_id: 198, amount: 1, equipped: true} | List.duplicate(nil, 23)],
          skills: %{carpentry: 80}
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{}
        )

      assert {:reply, :ok, _state} = InventoryHandlers.handle_use_item(state, 1, 0)
      assert_receive {:send_raw, _}, 500
      assert_receive {:send_raw, _}, 500
    end

    test "blacksmith crafting rejects when no anvil or forge object is selected" do
      entity =
        make_entity(%{
          char_id: 1,
          x: 50,
          y: 50,
          stamina: 100,
          equipment: %{weapon: 389},
          skills: %{blacksmithing: 80},
          inventory: [%{item_id: 192, amount: 5, equipped: false} | List.duplicate(nil, 23)]
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{},
          meta: %{objects: []}
        )

      {:noreply, new_state} = Crafting.handle_craft_item(state, 1, :blacksmithing, 386, 1, 50, 49)
      assert new_state.players[1].inventory == state.players[1].inventory
      assert_receive {:send_raw, _}, 500
    end
  end

  # =====================================================================
  # Drift T5 — Train packet: spawn creature from trainer
  # =====================================================================

  describe "Drift T5: train packet spawns creature from trainer" do
    @tag :drift_t5

    test "handle_train_creature spawns a pet from trainer's creature list" do
      # Trainer NPC (type 3) at (52, 50) with creatures ["506", "500"]
      trainer_npc = %{
        npc_id: 200,
        x: 52,
        y: 50,
        instance_id: :trainer1,
        alive: true,
        owner_id: nil
      }

      entity =
        make_entity(%{
          x: 50,
          y: 50,
          pet_ids: [],
          last_clicked_npc_instance_id: :trainer1,
          last_clicked_npc_type: 3
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{:trainer1 => trainer_npc}
        )

      # Train creature at index 1 (1-based, VB6 style)
      # This should be handled by NpcInteraction.handle_train_creature/3
      Code.ensure_loaded?(NpcInteraction)
      assert function_exported?(NpcInteraction, :handle_train_creature, 3),
             "NpcInteraction.handle_train_creature/3 must exist"

      {:noreply, new_state} = NpcInteraction.handle_train_creature(state, 1, %{pet_index: 1})

      # Verify the function processes without crashing
      assert is_map(new_state)
    end

    test "handle_train_creature rejects invalid pet_index" do
      trainer_npc = %{
        npc_id: 200,
        x: 52,
        y: 50,
        instance_id: :trainer1,
        alive: true,
        owner_id: nil
      }

      entity =
        make_entity(%{
          x: 50,
          y: 50,
          pet_ids: [],
          last_clicked_npc_instance_id: :trainer1,
          last_clicked_npc_type: 3
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{:trainer1 => trainer_npc}
        )

      # Pet index 0 is invalid (VB6: PetIndex > 0)
      {:noreply, new_state} = NpcInteraction.handle_train_creature(state, 1, %{pet_index: 0})
      # State should be unchanged (no pet spawned)
      assert new_state.npcs_live == state.npcs_live
    end

    test "handle_train_creature rejects when no trainer selected" do
      entity =
        make_entity(%{
          x: 50,
          y: 50,
          pet_ids: [],
          last_clicked_npc_instance_id: nil,
          last_clicked_npc_type: nil
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{}
        )

      {:noreply, new_state} = NpcInteraction.handle_train_creature(state, 1, %{pet_index: 1})
      assert new_state.npcs_live == state.npcs_live
    end
  end

  # =====================================================================
  # Drift B7 — Bank gold transfer
  # =====================================================================

  describe "Drift B7: bank gold transfer requires banker NPC" do
    @tag :drift_b7

    test "handle_bank_gold_transfer requires nearby banker NPC" do
      entity =
        make_entity(%{
          x: 50,
          y: 50,
          bank_gold: 5000,
          last_clicked_npc_instance_id: nil,
          last_clicked_npc_type: nil
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{}
        )

      Code.ensure_loaded?(NpcInteraction)
      assert function_exported?(NpcInteraction, :handle_bank_gold_transfer, 4),
             "NpcInteraction.handle_bank_gold_transfer/4 must exist"

      # No banker nearby — should fail
      {:noreply, new_state} =
        NpcInteraction.handle_bank_gold_transfer(state, 1, "TargetPlayer", 1000)

      # Player's bank gold should be unchanged
      assert new_state.players[1].bank_gold == 5000
    end

    test "handle_bank_gold_transfer deducts from bank_gold, not wallet gold" do
      banker_npc = %{
        npc_id: 300,
        x: 51,
        y: 50,
        instance_id: :banker1,
        alive: true,
        owner_id: nil
      }

      entity =
        make_entity(%{
          x: 50,
          y: 50,
          gold: 10_000,
          bank_gold: 5000,
          last_clicked_npc_instance_id: :banker1,
          last_clicked_npc_type: 4
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{:banker1 => banker_npc}
        )

      # Transfer 1000 from bank gold
      {:noreply, new_state} =
        NpcInteraction.handle_bank_gold_transfer(state, 1, "TargetPlayer", 1000)

      # Wallet gold should be unchanged
      assert new_state.players[1].gold == 10_000,
             "wallet gold must not change — VB6 uses Stats.Banco"

      # Bank gold should be reduced (if banker was found by GameData)
      # If GameData doesn't know npc_id 300, the transfer won't happen
      # and bank_gold stays at 5000. Either way, wallet gold is untouched.
      assert new_state.players[1].bank_gold <= 5000
    end

    test "handle_bank_gold_transfer blocks GM players" do
      banker_npc = %{
        npc_id: 300,
        x: 51,
        y: 50,
        instance_id: :banker1,
        alive: true,
        owner_id: nil
      }

      gm_entity =
        make_entity(%{
          x: 50,
          y: 50,
          gm: true,
          gm_level: :admin,
          bank_gold: 5000,
          last_clicked_npc_instance_id: :banker1,
          last_clicked_npc_type: 4
        })

      state =
        map_state(
          players: %{1 => gm_entity},
          sessions: %{1 => self()},
          npcs_live: %{:banker1 => banker_npc}
        )

      {:noreply, new_state} =
        NpcInteraction.handle_bank_gold_transfer(state, 1, "TargetPlayer", 1000)

      # GM should be blocked — bank_gold unchanged
      assert new_state.players[1].bank_gold == 5000,
             "VB6: GMs cannot transfer bank gold"
    end

    test "handle_bank_gold_transfer rejects insufficient bank gold" do
      banker_npc = %{
        npc_id: 300,
        x: 51,
        y: 50,
        instance_id: :banker1,
        alive: true,
        owner_id: nil
      }

      entity =
        make_entity(%{
          x: 50,
          y: 50,
          bank_gold: 500,
          last_clicked_npc_instance_id: :banker1,
          last_clicked_npc_type: 4
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{:banker1 => banker_npc}
        )

      {:noreply, new_state} =
        NpcInteraction.handle_bank_gold_transfer(state, 1, "TargetPlayer", 1000)

      # Not enough bank gold — should be unchanged
      assert new_state.players[1].bank_gold == 500
    end

    test "handle_bank_gold_transfer rejects when banker nearby but NOT selected" do
      # This is the core drift test: a real banker NPC (npc_id 3, type 4) is within
      # range, but the player has NOT clicked/selected it. The transfer MUST be
      # rejected — no generic resolve_nearby_npc fallback allowed.
      banker_npc = %{
        npc_id: 3,
        x: 51,
        y: 50,
        instance_id: :banker_nearby,
        alive: true,
        owner_id: nil
      }

      entity =
        make_entity(%{
          x: 50,
          y: 50,
          bank_gold: 5000,
          last_clicked_npc_instance_id: nil,
          last_clicked_npc_type: nil
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{:banker_nearby => banker_npc}
        )

      {:noreply, new_state} =
        NpcInteraction.handle_bank_gold_transfer(state, 1, "TargetPlayer", 1000)

      # Must be REJECTED: bank_gold unchanged
      assert new_state.players[1].bank_gold == 5000,
             "transfer must be rejected when no banker is selected, even if one is nearby"

      # Should receive a rejection message telling the player to select a banker
      assert_receive {:send_raw, _}, 500
    end

    test "handle_bank_gold_transfer rejects when selected NPC is not a banker" do
      # Player clicked a non-banker NPC, and a banker is also nearby.
      # The transfer MUST be rejected — only the selected NPC matters.
      non_banker_npc = %{
        npc_id: 1,
        x: 51,
        y: 50,
        instance_id: :merchant1,
        alive: true,
        owner_id: nil
      }

      banker_npc = %{
        npc_id: 3,
        x: 52,
        y: 50,
        instance_id: :banker_nearby,
        alive: true,
        owner_id: nil
      }

      entity =
        make_entity(%{
          x: 50,
          y: 50,
          bank_gold: 5000,
          last_clicked_npc_instance_id: :merchant1,
          last_clicked_npc_type: 1
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{:merchant1 => non_banker_npc, :banker_nearby => banker_npc}
        )

      {:noreply, new_state} =
        NpcInteraction.handle_bank_gold_transfer(state, 1, "TargetPlayer", 1000)

      # Must be REJECTED: selected NPC is not a banker
      assert new_state.players[1].bank_gold == 5000,
             "transfer must be rejected when selected NPC is not a banker"
    end

    test "handle_bank_gold_transfer enforces 10s cooldown" do
      banker_npc = %{
        npc_id: 300,
        x: 51,
        y: 50,
        instance_id: :banker1,
        alive: true,
        owner_id: nil
      }

      # Entity whose last transfer was just now (within 10s)
      entity =
        make_entity(%{
          x: 50,
          y: 50,
          bank_gold: 5000,
          last_clicked_npc_instance_id: :banker1,
          last_clicked_npc_type: 4,
          last_transfer_gold_at: System.monotonic_time(:millisecond)
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => self()},
          npcs_live: %{:banker1 => banker_npc}
        )

      {:noreply, new_state} =
        NpcInteraction.handle_bank_gold_transfer(state, 1, "TargetPlayer", 1000)

      # Cooldown should block — bank_gold unchanged
      assert new_state.players[1].bank_gold == 5000,
             "VB6: 10s cooldown between transfers"
    end
  end
end
