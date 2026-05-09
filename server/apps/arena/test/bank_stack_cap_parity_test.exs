defmodule Arena.BankStackCapParityTest do
  @moduledoc """
  VB6 parity: bank deposit stack cap enforcement.

  In VB6 (modBanco.bas:227-261), bank stacks are capped by GetMaxInvOBJ()
  (default 10,000). There are three enforcement points:

  1. find_bank_slot must skip a matching slot whose amount + deposit > max_stack
     (VB6 lines 227-228, 235-236)
  2. upsert_bank_item must reject when existing.amount + amount > max_stack
     (VB6 line 261)
  3. BankItems.upsert must cap the stored amount at max_stack
     (defense in depth at DB layer)

  The Elixir code was missing ALL THREE checks, allowing bank stacks to grow
  without limit.
  """

  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.Bank
  alias GameBackend.BankItems

  import Arena.Test.MapStateFactory

  @max_stack 10_000
  @banker_npc %{npc_id: 1, x: 51, y: 50, instance_id: :banker1}

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp make_entity(overrides) do
    defaults = %{
      char_id: nil,
      name: "BankCapTester",
      account_id: "acc_cap_test",
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
      skills: %{magic: 80},
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
      bank_npc_id: :banker1,
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
      saddle_slot: 0
    }

    Map.merge(defaults, overrides)
  end

  defp create_character! do
    {:ok, account} = GameBackend.Account.create("bankcap_acc_#{:erlang.unique_integer([:positive])}", "password123")

    {:ok, char} =
      GameBackend.Characters.create(%{
        name: "bankcap_#{:erlang.unique_integer([:positive])}",
        account_id: account.id
      })

    char.id
  end

  defp make_state(char_id, entity) do
    map_state(
      players: %{char_id => entity},
      sessions: %{char_id => self()},
      npcs_live: %{banker1: @banker_npc},
      occupancy: %{},
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Test 1: BankItems.upsert must cap at max_stack (DB layer)
  # ══════════════════════════════════════════════════════════════════════════

  describe "BankItems.upsert caps at max_stack" do
    test "adding to existing slot does not exceed max_stack" do
      char_id = create_character!()

      # Seed bank slot 1 with 9_995 of item 100
      {:ok, _} = BankItems.upsert(char_id, 1, 100, 9_995)

      # Now upsert 10 more — total would be 10_005, should be capped at 10_000
      {:ok, bi} = BankItems.upsert(char_id, 1, 100, 10)

      assert bi.amount == @max_stack,
             "VB6 parity: bank stack must be capped at #{@max_stack}, got #{bi.amount}"
    end

    test "inserting a fresh slot caps amount at max_stack" do
      char_id = create_character!()

      # Insert 15_000 directly — should be capped at 10_000
      {:ok, bi} = BankItems.upsert(char_id, 1, 100, 15_000)

      assert bi.amount <= @max_stack,
             "VB6 parity: bank stack must be capped at #{@max_stack}, got #{bi.amount}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Test 2: find_bank_slot skips full stacks
  # ══════════════════════════════════════════════════════════════════════════

  describe "find_bank_slot skips full stacks" do
    test "returns empty slot when existing stack is already at max" do
      char_id = create_character!()

      # Fill slot 1 to max_stack
      {:ok, _} = BankItems.upsert(char_id, 1, 100, @max_stack)

      # find_bank_slot should NOT return slot 1 (it's full);
      # it should return slot 2 (first empty)
      slot = Bank.find_bank_slot(char_id, 100, 0)

      assert slot != 1,
             "VB6 parity: find_bank_slot must skip full stacks (slot 1 at max), got slot #{slot}"

      assert slot == 2,
             "VB6 parity: find_bank_slot should return first empty slot (2), got #{slot}"
    end

    test "returns matching slot when it still has room" do
      char_id = create_character!()

      # Slot 1 with 5000 of item 100 — still has room
      {:ok, _} = BankItems.upsert(char_id, 1, 100, 5_000)

      slot = Bank.find_bank_slot(char_id, 100, 0)

      assert slot == 1,
             "find_bank_slot should return matching slot when not full, got #{slot}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Test 3: handle_bank_deposit rejects when bank stack would overflow
  # ══════════════════════════════════════════════════════════════════════════

  describe "handle_bank_deposit rejects overflow" do
    test "deposit to specific bank slot that would exceed max_stack falls through to auto-search" do
      char_id = create_character!()

      # Seed bank slot 1 with 9_999 items
      {:ok, _} = BankItems.upsert(char_id, 1, 100, 9_999)

      # Player has 5 of item 100 in inv slot 1
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false, elemental_tags: 0})
      entity = make_entity(%{char_id: char_id, inventory: inv})
      state = make_state(char_id, entity)

      flush_mailbox()

      # Try to deposit 5 to bank slot 1 (9999 + 5 = 10004 > 10000).
      # VB6 parity (modBanco.bas:227-253): when slotdestino would overflow,
      # the code falls through to auto-search and places items in the next
      # available slot (slot 2 in this case).
      {:ok, new_state, result, _effects} = Bank.handle_bank_deposit(state, char_id, 1, 5, 1)

      assert result == :ok,
             "VB6 parity: deposit should succeed via auto-search fallback, got: #{inspect(result)}"

      # Inventory should be decremented
      inv_slot = Enum.at(new_state.players[char_id].inventory, 0)
      assert inv_slot == nil, "Inventory slot should be empty after deposit"

      # Bank slot 1 should remain at 9999 (untouched)
      bank = BankItems.get_bank(char_id)
      slot1 = Enum.find(bank, fn bi -> bi.slot == 1 end)
      assert slot1.amount == 9_999, "Slot 1 must remain at 9999, got #{slot1.amount}"

      # Bank slot 2 should have 5
      slot2 = Enum.find(bank, fn bi -> bi.slot == 2 end)
      assert slot2 != nil, "Slot 2 should exist with the overflow items"
      assert slot2.amount == 5, "Slot 2 should have 5 items, got #{slot2.amount}"
    end

    test "deposit rejected when ALL bank slots are full at max_stack" do
      char_id = create_character!()

      # Fill all 40 bank slots with max_stack of item 100
      for slot <- 1..40 do
        {:ok, _} = BankItems.upsert(char_id, slot, 100, @max_stack)
      end

      # Player has 5 of item 100 in inv slot 1
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false, elemental_tags: 0})
      entity = make_entity(%{char_id: char_id, inventory: inv})
      state = make_state(char_id, entity)

      flush_mailbox()

      # Try to deposit — all slots are full, no room anywhere
      {:ok, new_state, result, _effects} = Bank.handle_bank_deposit(state, char_id, 1, 5, 0)

      assert result == {:error, :stack_full},
             "VB6 parity: deposit must be rejected when all bank slots are full, got: #{inspect(result)}"

      # Inventory must be unchanged
      assert Enum.at(new_state.players[char_id].inventory, 0).amount == 5,
             "Inventory must be unchanged when deposit is rejected"
    end

    test "deposit to auto-found slot when all matching stacks are full goes to empty slot" do
      char_id = create_character!()

      # Fill slot 1 with max_stack of item 100
      {:ok, _} = BankItems.upsert(char_id, 1, 100, @max_stack)

      # Player has 5 of item 100
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false, elemental_tags: 0})
      entity = make_entity(%{char_id: char_id, inventory: inv})
      state = make_state(char_id, entity)

      flush_mailbox()

      # Deposit 5 with slot_destino=0 (auto-find)
      {:ok, new_state, result, _effects} = Bank.handle_bank_deposit(state, char_id, 1, 5, 0)

      assert result == :ok,
             "Auto-find deposit should succeed by using empty slot 2, got: #{inspect(result)}"

      # Inventory should be decremented
      inv_slot = Enum.at(new_state.players[char_id].inventory, 0)

      assert inv_slot == nil || inv_slot.amount == 0 || false,
             "Inventory should have been decremented"

      # Bank slot 1 should still be at max_stack
      bank = BankItems.get_bank(char_id)
      slot1 = Enum.find(bank, fn bi -> bi.slot == 1 end)
      assert slot1.amount == @max_stack, "Slot 1 must remain at max_stack"

      # Bank slot 2 should have 5
      slot2 = Enum.find(bank, fn bi -> bi.slot == 2 end)
      assert slot2 != nil, "Slot 2 should exist with the overflow items"
      assert slot2.amount == 5, "Slot 2 should have 5 items"
    end
  end
end
