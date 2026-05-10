defmodule Arena.Adversarial.TradeAuthorityTest do
  @moduledoc """
  Adversarial tests for the player-to-player trade system.

  Verifies that the server correctly rejects or safely handles:
  - Trading with yourself
  - Starting a trade while already in one
  - Trading with a dead player
  - Trading with someone too far away
  - Offering items you don't have
  - Offering more items than you own
  - Accepting a trade after the partner disconnected
  - Trading while in combat (recently attacked)
  - Offering items from slots that don't exist
  """
  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.{Commerce, Trade}

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

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

  defp make_map_state(players, opts \\ []) do
    occupancy_map = Keyword.get(opts, :occupancy, %{})
    sessions = Keyword.get(opts, :sessions, %{})

    map_state(
      players: players,
      sessions: sessions,
      occupancy: occupancy_map,
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  defp make_inventory_with_item(obj_index, amount, slot \\ 0) do
    inv = List.duplicate(nil, 24)
    List.replace_at(inv, slot, %{item_id: obj_index, amount: amount, equipped: false, elemental_tags: 0})
  end

  defp setup_trading_pair(overrides_a \\ %{}, overrides_b \\ %{}) do
    alice = make_entity(Map.merge(%{name: "Alice", x: 50, y: 50, char_index: 1, trade_partner_id: 2002}, overrides_a))
    bob = make_entity(Map.merge(%{name: "Bob", x: 51, y: 50, char_index: 2, trade_partner_id: 1001}, overrides_b))

    players = %{1001 => alice, 2002 => bob}
    state = make_map_state(players, occupancy: %{{50, 50} => {:player, 1001}, {51, 50} => {:player, 2002}})
    {state, 1001, 2002}
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 1. Trade with yourself
  # ═══════════════════════════════════════════════════════════════════════════

  describe "trade with yourself" do
    test "open_commerce targeting own tile is rejected" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      players = %{1001 => alice}
      state = make_map_state(players, occupancy: %{{50, 50} => {:player, 1001}})

      # Player clicks on their own tile to open commerce
      result = Commerce.handle_open_commerce(state, 1001, 50, 50)

      # The occupancy lookup returns {:player, 1001} for char_id 1001.
      # The guard `target_id != char_id` should prevent self-trade.
      # If this passes through, it reveals a missing self-trade validation.
      case result do
        {:ok, _state, {:error, reason}, _effects} ->
          assert reason in [:no_target, :target_not_found, :self_trade],
                 "Self-trade should be rejected, got error: #{inspect(reason)}"

        {:ok, new_state, :ok, _effects} ->
          # If it succeeds, the player must NOT be trading with themselves
          player = Map.get(new_state.players, 1001)
          refute player.trade_partner_id == 1001,
                 "VULNERABILITY: Player successfully started a trade with themselves"
      end
    end

    test "start_user_trade_request with self as target is rejected" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      players = %{1001 => alice}
      state = make_map_state(players, occupancy: %{{50, 50} => {:player, 1001}})

      result = Trade.start_user_trade_request(state, 1001, alice, 1001)

      case result do
        {:ok, _state, {:error, reason}, _effects} ->
          assert reason in [:self_trade, :target_not_found, :invalid_target],
                 "Self-trade request should be rejected, got: #{inspect(reason)}"

        {:ok, new_state, :ok, _effects} ->
          player = Map.get(new_state.players, 1001)
          refute player.trade_partner_id == 1001,
                 "VULNERABILITY: Player started trade request with themselves"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 2. Start a trade while already in a trade
  # ═══════════════════════════════════════════════════════════════════════════

  describe "trade while already trading" do
    test "cannot start new trade request when already trading with someone" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1, trade_partner_id: 2002})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2, trade_partner_id: 1001})
      charlie = make_entity(%{name: "Charlie", x: 52, y: 50, char_index: 3})

      players = %{1001 => alice, 2002 => bob, 3003 => charlie}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {51, 50} => {:player, 2002},
        {52, 50} => {:player, 3003}
      })

      result = Trade.start_user_trade_request(state, 1001, alice, 3003)

      assert {:ok, _state, {:error, :already_trading}, _effects} = result
    end

    test "cannot open commerce with another player when already in trade" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1, trade_partner_id: 2002})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2, trade_partner_id: 1001})
      charlie = make_entity(%{name: "Charlie", x: 52, y: 50, char_index: 3})

      players = %{1001 => alice, 2002 => bob, 3003 => charlie}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {51, 50} => {:player, 2002},
        {52, 50} => {:player, 3003}
      })

      result = Commerce.handle_open_commerce(state, 1001, 52, 50)
      assert {:ok, _state, {:error, :already_trading}, _effects} = result
    end

    test "target already in a trade rejects new trade request" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2, trade_partner_id: 3003})
      charlie = make_entity(%{name: "Charlie", x: 52, y: 50, char_index: 3, trade_partner_id: 2002})

      players = %{1001 => alice, 2002 => bob, 3003 => charlie}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {51, 50} => {:player, 2002},
        {52, 50} => {:player, 3003}
      })

      result = Trade.start_user_trade_request(state, 1001, alice, 2002)
      assert {:ok, _state, {:error, :target_busy}, _effects} = result
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 3. Trade with a dead player
  # ═══════════════════════════════════════════════════════════════════════════

  describe "trade with dead player" do
    test "cannot initiate trade with a dead target via open_commerce" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2, dead: true})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {51, 50} => {:player, 2002}
      })

      result = Commerce.handle_open_commerce(state, 1001, 51, 50)
      assert {:ok, _state, {:error, :target_dead}, _effects} = result
    end

    test "dead player cannot offer trade items" do
      alice = make_entity(%{
        name: "Alice", x: 50, y: 50, char_index: 1,
        dead: true, trade_partner_id: 2002,
        inventory: make_inventory_with_item(100, 5)
      })
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2, trade_partner_id: 1001})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players)

      result = Trade.handle_user_trade_offer(state, 1001, 100, 1)
      assert {:ok, _state, {:error, :dead}, _effects} = result
    end

    test "dead player cannot accept trade" do
      alice = make_entity(%{
        name: "Alice", x: 50, y: 50, char_index: 1,
        dead: true, trade_partner_id: 2002
      })
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2, trade_partner_id: 1001})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players)

      result = Trade.handle_user_trade_accept(state, 1001)
      assert {:ok, _state, {:error, :dead}, _effects} = result
    end

    test "start_user_trade_request rejects dead target" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2, dead: true})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {51, 50} => {:player, 2002}
      })

      result = Trade.start_user_trade_request(state, 1001, alice, 2002)
      assert {:ok, _state, {:error, :target_dead}, _effects} = result
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 4. Trade with someone too far away
  # ═══════════════════════════════════════════════════════════════════════════

  describe "trade distance check" do
    test "cannot trade with player more than 3 tiles away in X" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      bob = make_entity(%{name: "Bob", x: 54, y: 50, char_index: 2})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {54, 50} => {:player, 2002}
      })

      result = Commerce.handle_open_commerce(state, 1001, 54, 50)
      assert {:ok, _state, {:error, :too_far}, _effects} = result
    end

    test "cannot trade with player more than 3 tiles away in Y" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      bob = make_entity(%{name: "Bob", x: 50, y: 54, char_index: 2})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {50, 54} => {:player, 2002}
      })

      result = Commerce.handle_open_commerce(state, 1001, 50, 54)
      assert {:ok, _state, {:error, :too_far}, _effects} = result
    end

    test "trade at exactly distance 3 is allowed" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      bob = make_entity(%{name: "Bob", x: 53, y: 50, char_index: 2})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {53, 50} => {:player, 2002}
      })

      result = Commerce.handle_open_commerce(state, 1001, 53, 50)

      # Should succeed (first request) or at least not be :too_far
      case result do
        {:ok, _state, {:error, :too_far}, _effects} ->
          flunk("Distance 3 should be within trade range")

        _ ->
          assert true
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 5. Offer items you don't have
  # ═══════════════════════════════════════════════════════════════════════════

  describe "offer items not in inventory" do
    test "offering an item not in inventory is rejected" do
      {state, alice_id, _bob_id} = setup_trading_pair(
        %{inventory: List.duplicate(nil, 24)},
        %{}
      )

      # obj_index 999 is not in Alice's inventory
      result = Trade.handle_user_trade_offer(state, alice_id, 999, 1)
      assert {:ok, _state, {:error, :invalid_offer}, _effects} = result
    end

    test "offering an equipped item is rejected" do
      inv = List.duplicate(nil, 24)
      inv = List.replace_at(inv, 0, %{item_id: 100, amount: 1, equipped: true, elemental_tags: 0})

      {state, alice_id, _bob_id} = setup_trading_pair(%{inventory: inv}, %{})

      result = Trade.handle_user_trade_offer(state, alice_id, 100, 1)
      assert {:ok, _state, {:error, :invalid_offer}, _effects} = result
    end

    test "offering zero amount is rejected" do
      inv = make_inventory_with_item(100, 5)

      {state, alice_id, _bob_id} = setup_trading_pair(%{inventory: inv}, %{})

      result = Trade.handle_user_trade_offer(state, alice_id, 100, 0)
      assert {:ok, _state, {:error, :invalid_offer}, _effects} = result
    end

    test "offering negative amount is rejected" do
      inv = make_inventory_with_item(100, 5)

      {state, alice_id, _bob_id} = setup_trading_pair(%{inventory: inv}, %{})

      result = Trade.handle_user_trade_offer(state, alice_id, 100, -1)
      assert {:ok, _state, {:error, :invalid_offer}, _effects} = result
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 6. Offer more items than you have
  # ═══════════════════════════════════════════════════════════════════════════

  describe "offer more items than owned" do
    test "offering more than inventory amount is rejected" do
      inv = make_inventory_with_item(100, 5)

      {state, alice_id, _bob_id} = setup_trading_pair(%{inventory: inv}, %{})

      result = Trade.handle_user_trade_offer(state, alice_id, 100, 10)
      assert {:ok, _state, {:error, :invalid_offer}, _effects} = result
    end

    test "cumulative offers exceeding inventory amount are rejected" do
      inv = make_inventory_with_item(100, 5)

      {state, alice_id, _bob_id} = setup_trading_pair(%{inventory: inv}, %{})

      # First offer of 3 should succeed
      {:ok, state, :ok, _effects} = Trade.handle_user_trade_offer(state, alice_id, 100, 3)

      # Second offer of 3 would total 6, but only 5 in inventory
      result = Trade.handle_user_trade_offer(state, alice_id, 100, 3)
      assert {:ok, _state, {:error, :invalid_offer}, _effects} = result
    end

    test "offering exactly the inventory amount succeeds" do
      inv = make_inventory_with_item(100, 5)

      {state, alice_id, _bob_id} = setup_trading_pair(%{inventory: inv}, %{})

      result = Trade.handle_user_trade_offer(state, alice_id, 100, 5)
      assert {:ok, _state, :ok, _effects} = result
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 7. Accept trade after partner disconnected
  # ═══════════════════════════════════════════════════════════════════════════

  describe "accept trade after partner disconnected" do
    test "accepting when partner no longer exists in players map" do
      # Alice is still in trade state but Bob has been removed (disconnected)
      alice = make_entity(%{
        name: "Alice", x: 50, y: 50, char_index: 1,
        trade_partner_id: 2002, trade_accepted: false
      })

      # Bob is NOT in the players map (disconnected)
      players = %{1001 => alice}
      state = make_map_state(players)

      result = Trade.handle_user_trade_accept(state, 1001)

      case result do
        {:ok, _state, {:error, reason}, _effects} ->
          assert reason in [:partner_disconnected, :not_trading, :invalid_trade],
                 "Should reject trade accept when partner is gone, got: #{inspect(reason)}"

        {:ok, new_state, :ok, _effects} ->
          # If it "succeeds", the trade must not actually execute
          player = Map.get(new_state.players, 1001)
          # The trade should not have completed (gold/items should not have changed)
          assert player.gold == 1000,
                 "VULNERABILITY: Trade accepted with disconnected partner may have caused state corruption"
      end
    end

    test "both accept but partner removed between accept calls" do
      # Alice has already accepted, Bob is "gone" but Alice's state still references him
      alice = make_entity(%{
        name: "Alice", x: 50, y: 50, char_index: 1,
        trade_partner_id: 2002, trade_accepted: true,
        trade_offer_gold: 500
      })

      # Bob does not exist in players (disconnected after accepting)
      players = %{1001 => alice}
      state = make_map_state(players)

      # Simulate Bob trying to accept (he's not in the map)
      result = Trade.handle_user_trade_accept(state, 2002)
      assert {:ok, _state, {:error, :not_on_map}, _effects} = result
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 8. Trade while in combat (recently attacked)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "trade while in combat" do
    test "player who is navigating cannot open commerce" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1, navigating: true})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {51, 50} => {:player, 2002}
      })

      result = Commerce.handle_open_commerce(state, 1001, 51, 50)

      # Navigating players should not be able to trade.
      # If this succeeds, it reveals a missing combat/navigation check.
      case result do
        {:ok, _state, {:error, reason}, _effects} ->
          assert reason in [:navigating, :in_combat, :busy],
                 "Navigating player should be blocked from trading, got: #{inspect(reason)}"

        {:ok, _state, :ok, _effects} ->
          # NOTE: This may indicate a missing validation for navigating players
          # in the commerce/trade flow. The VB6 original blocks trades during navigation.
          flunk("MISSING VALIDATION: Navigating player was allowed to initiate trade")
      end
    end

    test "paralyzed player cannot open commerce" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1, paralyzed: true})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {51, 50} => {:player, 2002}
      })

      result = Commerce.handle_open_commerce(state, 1001, 51, 50)

      case result do
        {:ok, _state, {:error, reason}, _effects} ->
          assert reason in [:paralyzed, :in_combat, :busy],
                 "Paralyzed player should be blocked from trading, got: #{inspect(reason)}"

        {:ok, _state, :ok, _effects} ->
          flunk("MISSING VALIDATION: Paralyzed player was allowed to initiate trade")
      end
    end

    test "meditating player cannot open commerce" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1, meditating: true})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2})

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players, occupancy: %{
        {50, 50} => {:player, 1001},
        {51, 50} => {:player, 2002}
      })

      result = Commerce.handle_open_commerce(state, 1001, 51, 50)

      case result do
        {:ok, _state, {:error, reason}, _effects} ->
          assert reason in [:meditating, :busy],
                 "Meditating player should be blocked from trading, got: #{inspect(reason)}"

        {:ok, _state, :ok, _effects} ->
          flunk("MISSING VALIDATION: Meditating player was allowed to initiate trade")
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 9. Offer items from slots that don't exist
  # ═══════════════════════════════════════════════════════════════════════════

  describe "offer items from nonexistent slots" do
    test "offering item with obj_index 0 (null item) is rejected" do
      {state, alice_id, _bob_id} = setup_trading_pair(
        %{inventory: List.duplicate(nil, 24)},
        %{}
      )

      result = Trade.handle_user_trade_offer(state, alice_id, 0, 1)
      assert {:ok, _state, {:error, :invalid_offer}, _effects} = result
    end

    test "offering item with very large obj_index is rejected" do
      {state, alice_id, _bob_id} = setup_trading_pair(
        %{inventory: List.duplicate(nil, 24)},
        %{}
      )

      result = Trade.handle_user_trade_offer(state, alice_id, 999_999, 1)
      assert {:ok, _state, {:error, :invalid_offer}, _effects} = result
    end

    test "offering item with negative obj_index is rejected" do
      {state, alice_id, _bob_id} = setup_trading_pair(
        %{inventory: List.duplicate(nil, 24)},
        %{}
      )

      result = Trade.handle_user_trade_offer(state, alice_id, -1, 1)
      assert {:ok, _state, {:error, :invalid_offer}, _effects} = result
    end

    test "player not in trade cannot offer items" do
      alice = make_entity(%{
        name: "Alice", x: 50, y: 50, char_index: 1,
        trade_partner_id: nil,
        inventory: make_inventory_with_item(100, 5)
      })

      players = %{1001 => alice}
      state = make_map_state(players)

      result = Trade.handle_user_trade_offer(state, 1001, 100, 1)
      assert {:ok, _state, {:error, :not_trading}, _effects} = result
    end

    test "player not on map cannot offer items" do
      state = make_map_state(%{})

      result = Trade.handle_user_trade_offer(state, 9999, 100, 1)
      assert {:ok, _state, {:error, :not_on_map}, _effects} = result
    end

    test "exceeding max trade item slots (6) does not crash" do
      inv =
        Enum.reduce(0..7, List.duplicate(nil, 24), fn i, acc ->
          List.replace_at(acc, i, %{item_id: 100 + i, amount: 10, equipped: false, elemental_tags: 0})
        end)

      {state, alice_id, _bob_id} = setup_trading_pair(%{inventory: inv}, %{})

      # Offer 7 different items -- the 7th should be silently ignored (max is 6)
      state =
        Enum.reduce(0..6, state, fn i, acc_state ->
          case Trade.handle_user_trade_offer(acc_state, alice_id, 100 + i, 1) do
            {:ok, new_state, :ok, _effects} -> new_state
            {:ok, same_state, {:error, _}, _effects} -> same_state
          end
        end)

      alice = Map.get(state.players, alice_id)
      assert length(alice.trade_offer_items) <= 6,
             "Trade offer should not exceed max of 6 item slots"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 10. Additional edge cases
  # ═══════════════════════════════════════════════════════════════════════════

  describe "trade gold validation" do
    test "execute_trade rejects when player offered more gold than they have" do
      alice = make_entity(%{
        name: "Alice", x: 50, y: 50, char_index: 1,
        trade_partner_id: 2002, trade_accepted: true,
        trade_offer_gold: 5000, gold: 1000
      })
      bob = make_entity(%{
        name: "Bob", x: 51, y: 50, char_index: 2,
        trade_partner_id: 1001, trade_accepted: true,
        trade_offer_gold: 0, gold: 1000
      })

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players)

      {new_state, _effects} = Trade.execute_trade(state, 1001, 2002)

      # After failed trade, both should have their trade state cleared
      alice_after = Map.get(new_state.players, 1001)
      assert alice_after.trade_partner_id == nil, "Trade should have been cancelled"
      assert alice_after.gold == 1000, "Gold should not have changed after failed trade"
    end
  end

  describe "trade reject and end" do
    test "rejecting a trade that doesn't exist is harmless" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      players = %{1001 => alice}
      state = make_map_state(players)

      result = Trade.handle_user_trade_reject(state, 1001)
      assert {:ok, _state, :ok, _effects} = result
    end

    test "ending a trade cleans up both players" do
      {state, alice_id, bob_id} = setup_trading_pair()

      {:ok, new_state, :ok, _effects} = Trade.handle_user_trade_end(state, alice_id)

      alice_after = Map.get(new_state.players, alice_id)
      bob_after = Map.get(new_state.players, bob_id)

      assert alice_after.trade_partner_id == nil
      assert bob_after.trade_partner_id == nil
      assert alice_after.trade_offer_items == []
      assert bob_after.trade_offer_items == []
    end

    test "player not on map gets error for trade_end" do
      state = make_map_state(%{})

      result = Trade.handle_user_trade_end(state, 9999)
      assert {:ok, _state, {:error, :not_on_map}, _effects} = result
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 11. Safe-zone trade block
  # ═══════════════════════════════════════════════════════════════════════════

  describe "safe zone trade block" do
    test "player-to-player trade initiation is rejected in safe zone" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2})

      players = %{1001 => alice, 2002 => bob}

      state = map_state(
        players: players,
        sessions: %{},
        occupancy: %{{50, 50} => {:player, 1001}, {51, 50} => {:player, 2002}},
        meta: %{rain: false, sin_invi_ocul: false, safe_zone: true}
      )

      result = Commerce.handle_open_commerce(state, 1001, 51, 50)
      assert {:ok, _state, {:error, :safe_zone}, _effects} = result
    end

    test "player-to-player trade allowed when safe_zone is false" do
      alice = make_entity(%{name: "Alice", x: 50, y: 50, char_index: 1})
      bob = make_entity(%{name: "Bob", x: 51, y: 50, char_index: 2})

      players = %{1001 => alice, 2002 => bob}

      state = map_state(
        players: players,
        sessions: %{},
        occupancy: %{{50, 50} => {:player, 1001}, {51, 50} => {:player, 2002}},
        meta: %{rain: false, sin_invi_ocul: false, safe_zone: false}
      )

      result = Commerce.handle_open_commerce(state, 1001, 51, 50)
      # Should succeed (first request) — at least not be :safe_zone
      refute match?({:ok, _state, {:error, :safe_zone}, _effects}, result),
             "Trade should be allowed when safe_zone is false"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 12. Distance recheck on trade execution
  # ═══════════════════════════════════════════════════════════════════════════

  describe "distance recheck on trade execution" do
    test "handle_user_trade_accept rejects when players walked apart after first accept" do
      # Alice already accepted. Bob is far away and now accepts too.
      # The system should detect they are too far apart and reject.
      alice = make_entity(%{
        name: "Alice", x: 50, y: 50, char_index: 1,
        trade_partner_id: 2002, trade_accepted: true,
        trade_offer_gold: 100, gold: 1000
      })

      bob = make_entity(%{
        name: "Bob", x: 60, y: 60, char_index: 2,
        trade_partner_id: 1001, trade_accepted: false,
        trade_offer_gold: 100, gold: 1000
      })

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players)

      # Bob accepts — at this point both have accepted, but they're >3 tiles apart
      result = Trade.handle_user_trade_accept(state, 2002)

      case result do
        {:ok, new_state, {:error, :too_far}, _effects} ->
          # Correctly rejected for distance
          alice_after = Map.get(new_state.players, 1001)
          bob_after = Map.get(new_state.players, 2002)
          assert alice_after.trade_partner_id == nil
          assert bob_after.trade_partner_id == nil

        {:ok, new_state, :ok, _effects} ->
          # If trade went through, gold should NOT have been exchanged
          alice_after = Map.get(new_state.players, 1001)
          bob_after = Map.get(new_state.players, 2002)

          # The critical assertion: if no distance check exists, the trade
          # would attempt to execute (gold transfer). If gold changed, the
          # distance check is missing.
          assert alice_after.gold == 1000 and bob_after.gold == 1000,
                 "VULNERABILITY: Trade executed despite players being >3 tiles apart. " <>
                 "Alice gold: #{alice_after.gold}, Bob gold: #{bob_after.gold}"
          # Even if gold didn't change (due to DB error), the trade should
          # have been explicitly rejected with :too_far, not accidentally saved
          # by a DB failure.
          flunk("MISSING VALIDATION: Trade accept should return {:error, :too_far} " <>
                "when players are more than 3 tiles apart, but returned :ok")

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "handle_user_trade_accept succeeds when players are within range" do
      alice = make_entity(%{
        name: "Alice", x: 50, y: 50, char_index: 1,
        trade_partner_id: 2002, trade_accepted: true,
        trade_offer_gold: 0, gold: 1000
      })

      bob = make_entity(%{
        name: "Bob", x: 52, y: 51, char_index: 2,
        trade_partner_id: 1001, trade_accepted: false,
        trade_offer_gold: 0, gold: 1000
      })

      players = %{1001 => alice, 2002 => bob}
      state = make_map_state(players)

      # Bob accepts — both within range, trade should proceed
      result = Trade.handle_user_trade_accept(state, 2002)

      # Should not return :too_far
      refute match?({:ok, _, {:error, :too_far}, _}, result),
             "Trade should succeed when players are within 3 tiles"
    end
  end
end
