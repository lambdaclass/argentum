defmodule Arena.TradePersistenceTest do
  @moduledoc """
  Tests that the trade commit boundary persists both players' state
  atomically to DB before mutating in-memory state.

  Failure-path tests verify that on DB failure, both players' gold
  and inventory remain unchanged.
  """
  use ExUnit.Case, async: false

  alias Arena.Map.Trade
  alias Arena.Data.GameData

  import Arena.Test.MapStateFactory

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
      saddle_slot: 0
    }

    Map.merge(defaults, overrides)
  end

  defp make_map_state(players) do
    map_state(
      players: players,
      sessions: %{},
      occupancy: %{},
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  defp make_inventory_with_item(obj_index, amount, slot \\ 0) do
    inv = List.duplicate(nil, 24)
    List.replace_at(inv, slot, %{item_id: obj_index, amount: amount, equipped: false, elemental_tags: 0})
  end

  defp create_test_character(name, gold) do
    account = ensure_test_account()

    {:ok, char} =
      GameBackend.Characters.create(%{
        name: name,
        account_id: account.id,
        race: "humano",
        class: "guerrero",
        gender: "male",
        home_city: "ullathorpe",
        head_id: 1,
        body_id: 1,
        pos_x: 50,
        pos_y: 50,
        map_id: 1,
        heading: "south",
        hp: 100,
        max_hp: 100,
        mana: 50,
        max_mana: 50,
        stamina: 100,
        max_stamina: 100,
        hunger: 100,
        thirst: 100,
        level: 25,
        xp: 0,
        gold: gold,
        str: 18,
        agi: 18,
        int: 18,
        con: 18,
        cha: 18,
        skill_points: 0,
        dead: false,
        criminal: false,
        penalty: 0,
        fishing_points: 0,
        faction: "none",
        npcs_killed: 0,
        deaths: 0,
        citizens_killed: 0,
        criminals_killed: 0,
        faction_kills_royal: 0,
        faction_kills_chaos: 0,
        faction_score: 0,
        faction_rank_armada: 0,
        faction_rank_chaos: 0,
        faction_reenlistadas: 0
      })

    entity = GameBackend.Characters.to_entity(char)
    {char.id, entity}
  end

  defp ensure_test_account do
    name = "trade_test_#{System.unique_integer([:positive])}"
    {:ok, account} = GameBackend.Account.create(name, "test_password")
    account
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Failure-path: one-side DB failure (player doesn't exist in DB)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "one-side DB failure" do
    test "when one player has no DB record, trade is rejected and both inventories unchanged" do
      # Alice exists in DB, Bob does not (char_id = -999)
      {alice_id, alice_entity} = create_test_character("TradeAlice_#{System.unique_integer([:positive])}", 5000)

      bob_entity = make_entity(%{
        char_id: -999,
        name: "GhostBob",
        gold: 3000,
        inventory: make_inventory_with_item(100, 10),
        trade_partner_id: alice_id,
        trade_accepted: true,
        trade_offer_items: [{100, 5, 0}],
        trade_offer_gold: 0
      })

      alice_entity = %{alice_entity |
        trade_partner_id: -999,
        trade_accepted: true,
        trade_offer_items: [],
        trade_offer_gold: 0
      }

      players = %{alice_id => alice_entity, -999 => bob_entity}
      state = make_map_state(players)

      {new_state, _effects} = Trade.execute_trade(state, alice_id, -999)

      # Both players' gold and inventory should be unchanged
      alice_after = Map.get(new_state.players, alice_id)
      bob_after = Map.get(new_state.players, -999)

      assert alice_after.gold == 5000, "Alice's gold should be unchanged after failed trade commit"
      assert bob_after.gold == 3000, "Bob's gold should be unchanged after failed trade commit"
      assert bob_after.inventory == bob_entity.inventory,
        "Bob's inventory should be unchanged after failed trade commit"

      # Trade state should be cleared (trade ended)
      assert alice_after.trade_partner_id == nil
      assert bob_after.trade_partner_id == nil
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Failure-path: both accepted, commit fails
  # ═══════════════════════════════════════════════════════════════════════════

  describe "both accepted, DB commit fails" do
    test "when DB transaction fails, neither player's inventory or gold changes" do
      # Both players have no DB backing (synthetic IDs)
      alice_entity = make_entity(%{
        char_id: -1001,
        name: "NoDBAlice",
        gold: 5000,
        inventory: make_inventory_with_item(100, 10),
        trade_partner_id: -2002,
        trade_accepted: true,
        trade_offer_items: [{100, 3, 0}],
        trade_offer_gold: 0
      })

      bob_entity = make_entity(%{
        char_id: -2002,
        name: "NoDBBob",
        gold: 3000,
        inventory: make_inventory_with_item(200, 5),
        trade_partner_id: -1001,
        trade_accepted: true,
        trade_offer_items: [{200, 2, 0}],
        trade_offer_gold: 0
      })

      players = %{-1001 => alice_entity, -2002 => bob_entity}
      state = make_map_state(players)

      {new_state, _effects} = Trade.execute_trade(state, -1001, -2002)

      alice_after = Map.get(new_state.players, -1001)
      bob_after = Map.get(new_state.players, -2002)

      # Neither player should have gained the other's items
      assert alice_after.gold == 5000
      assert bob_after.gold == 3000

      # Inventories unchanged
      assert alice_after.inventory == alice_entity.inventory
      assert bob_after.inventory == bob_entity.inventory

      # Trade ended
      assert alice_after.trade_partner_id == nil
      assert bob_after.trade_partner_id == nil
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Success path: trade persists to DB immediately
  # ═══════════════════════════════════════════════════════════════════════════

  describe "successful trade persists to DB" do
    test "after a successful trade, both players' DB state reflects the trade" do
      {alice_id, alice_entity} = create_test_character("TradeOkA_#{System.unique_integer([:positive])}", 5000)
      {bob_id, bob_entity} = create_test_character("TradeOkB_#{System.unique_integer([:positive])}", 3000)

      # Give Alice item 100 in slot 0 (need to save to DB first)
      alice_inv = make_inventory_with_item(100, 10)
      GameBackend.Characters.save_snapshot(alice_id, %{gold: 5000},
        inventory: alice_inv, equipment: alice_entity.equipment,
        skills: %{}, spells: [])

      alice_entity = %{alice_entity |
        gold: 5000,
        inventory: alice_inv,
        trade_partner_id: bob_id,
        trade_accepted: true,
        trade_offer_items: [{100, 3, 0}],
        trade_offer_gold: 0
      }

      bob_entity = %{bob_entity |
        gold: 3000,
        trade_partner_id: alice_id,
        trade_accepted: true,
        trade_offer_items: [],
        trade_offer_gold: 0
      }

      players = %{alice_id => alice_entity, bob_id => bob_entity}
      state = make_map_state(players)

      {new_state, _effects} = Trade.execute_trade(state, alice_id, bob_id)

      alice_after = Map.get(new_state.players, alice_id)
      bob_after = Map.get(new_state.players, bob_id)

      # In-memory state should reflect trade
      assert alice_after.gold == 5000
      assert bob_after.gold == 3000

      # Alice should have 7 of item 100 (gave 3 to Bob)
      alice_item = Enum.find(alice_after.inventory, & &1 && &1.item_id == 100)
      assert alice_item.amount == 7

      # Bob should have item 100 with amount 3
      bob_item = Enum.find(bob_after.inventory, & &1 && &1.item_id == 100)
      assert bob_item != nil
      assert bob_item.amount == 3

      # DB should reflect the same state (sync persistence)
      alice_db = GameBackend.Characters.get(alice_id)
      bob_db = GameBackend.Characters.get(bob_id)

      assert alice_db.gold == 5000
      assert bob_db.gold == 3000

      # DB inventory should show Alice lost 3 and Bob gained 3
      alice_db_item = Enum.find(alice_db.inventory_slots, & &1.item_id == 100)
      assert alice_db_item.amount == 7

      bob_db_item = Enum.find(bob_db.inventory_slots, & &1.item_id == 100)
      assert bob_db_item != nil
      assert bob_db_item.amount == 3
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Replay/double-accept
  # ═══════════════════════════════════════════════════════════════════════════

  describe "replay / double-accept" do
    test "second accept after trade already executed is harmless" do
      {alice_id, alice_entity} = create_test_character("TradeReplayA_#{System.unique_integer([:positive])}", 5000)
      {bob_id, bob_entity} = create_test_character("TradeReplayB_#{System.unique_integer([:positive])}", 3000)

      alice_inv = make_inventory_with_item(100, 10)
      GameBackend.Characters.save_snapshot(alice_id, %{gold: 5000},
        inventory: alice_inv, equipment: alice_entity.equipment,
        skills: %{}, spells: [])

      alice_entity = %{alice_entity |
        gold: 5000,
        inventory: alice_inv,
        trade_partner_id: bob_id,
        trade_accepted: true,
        trade_offer_items: [{100, 3, 0}],
        trade_offer_gold: 0
      }

      bob_entity = %{bob_entity |
        gold: 3000,
        trade_partner_id: alice_id,
        trade_accepted: true,
        trade_offer_items: [],
        trade_offer_gold: 0
      }

      players = %{alice_id => alice_entity, bob_id => bob_entity}
      state = make_map_state(players)

      # First accept triggers execute_trade
      {:ok, state_after_first, :ok, _effects} =
        Trade.handle_user_trade_accept(state, alice_id)

      # After the trade, both should have trade_partner_id = nil
      alice_after = Map.get(state_after_first.players, alice_id)
      assert alice_after.trade_partner_id == nil

      # A second accept should be a no-op (:not_trading)
      result = Trade.handle_user_trade_accept(state_after_first, alice_id)
      assert {:ok, _state, {:error, :not_trading}, _effects} = result

      # DB should still show the correct post-trade state (not doubled)
      alice_db = GameBackend.Characters.get(alice_id)
      alice_db_item = Enum.find(alice_db.inventory_slots, & &1.item_id == 100)
      assert alice_db_item.amount == 7
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Reconnect shows pre-trade state after failed commit
  # ═══════════════════════════════════════════════════════════════════════════

  describe "reconnect after failed trade commit" do
    test "DB state is unchanged when trade commit fails, so reconnect sees pre-trade state" do
      {alice_id, alice_entity} = create_test_character("TradeRecoA_#{System.unique_integer([:positive])}", 5000)

      alice_inv = make_inventory_with_item(100, 10)
      GameBackend.Characters.save_snapshot(alice_id, %{gold: 5000},
        inventory: alice_inv, equipment: alice_entity.equipment,
        skills: %{}, spells: [])

      # Bob has no DB record — commit will fail
      bob_entity = make_entity(%{
        char_id: -777,
        name: "GhostBob",
        gold: 3000,
        inventory: make_inventory_with_item(200, 5),
        trade_partner_id: alice_id,
        trade_accepted: true,
        trade_offer_items: [{200, 2, 0}],
        trade_offer_gold: 0
      })

      alice_entity = %{alice_entity |
        gold: 5000,
        inventory: alice_inv,
        trade_partner_id: -777,
        trade_accepted: true,
        trade_offer_items: [{100, 3, 0}],
        trade_offer_gold: 0
      }

      players = %{alice_id => alice_entity, -777 => bob_entity}
      state = make_map_state(players)

      {_new_state, _effects} = Trade.execute_trade(state, alice_id, -777)

      # Alice's DB state should be unchanged (as if she reconnected)
      alice_db = GameBackend.Characters.get(alice_id)
      assert alice_db.gold == 5000

      alice_db_item = Enum.find(alice_db.inventory_slots, & &1.item_id == 100)
      assert alice_db_item.amount == 10, "DB should show pre-trade inventory after failed commit"
    end
  end
end
