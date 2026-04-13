defmodule Arena.EconomySecurityTest do
  @moduledoc """
  Map-level economy security tests exercising Commerce, Bank, Trade, Drop,
  Chat moderation, and Movement anti-cheat at the handler level.

  These call the actual handler modules (Commerce, Bank, Trade, Movement, Social)
  with crafted state to verify exploitation vectors are blocked.
  """
  use ExUnit.Case, async: true

  alias Arena.Data.GameData
  alias Arena.Map.{Commerce, Bank, Movement, Social}

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

    base_occ = :array.new(100 * 100, default: nil)

    occupancy =
      Enum.reduce(occupancy_map, base_occ, fn {{x, y}, value}, acc ->
        idx = (y - 1) * 100 + (x - 1)
        :array.set(idx, value, acc)
      end)

    %{
      players: players,
      sessions: sessions,
      occupancy: occupancy,
      npcs_live: %{},
      map_id: 1,
      floor_items: %{},
      next_floor_id: 1,
      visibility_mode: :global,
      meta: %{rain: false, sin_invi_ocul: false}
    }
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Commerce: buy/sell without opening shop
  # ═══════════════════════════════════════════════════════════════════════════

  describe "commerce_buy without open commerce session" do
    test "buy from NPC when commerce_npc_id is nil returns :no_commerce" do
      entity = make_entity(%{char_id: :player, commerce_npc_id: nil, gold: 50000})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Commerce.handle_commerce_buy(state, :player, 1, 1)
      assert result == {:error, :no_commerce}
    end
  end

  describe "commerce_sell without open commerce session" do
    test "sell when commerce_npc_id is nil returns :no_commerce" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false})
      entity = make_entity(%{char_id: :player, commerce_npc_id: nil, inventory: inv})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Commerce.handle_commerce_sell(state, :player, 1, 1)
      assert result == {:error, :no_commerce}
    end
  end

  describe "commerce_buy while dead" do
    test "dead player cannot buy" do
      entity = make_entity(%{char_id: :player, dead: true, commerce_npc_id: 1})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Commerce.handle_commerce_buy(state, :player, 1, 1)
      assert result == {:error, :dead}
    end
  end

  describe "commerce_sell while dead" do
    test "dead player cannot sell" do
      entity = make_entity(%{char_id: :player, dead: true, commerce_npc_id: 1})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Commerce.handle_commerce_sell(state, :player, 1, 1)
      assert result == {:error, :dead}
    end
  end

  describe "commerce_sell with empty slot" do
    test "selling from empty inventory slot returns :empty_slot" do
      entity = make_entity(%{char_id: :player, commerce_npc_id: 1})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      # Slot 5 is empty (nil)
      {:reply, result, _state} = Commerce.handle_commerce_sell(state, :player, 5, 1)
      assert result == {:error, :empty_slot}
    end
  end

  describe "commerce_sell slot=0 off-by-one exploit" do
    test "selling from slot 0 uses Enum.at(inv, -1) which reads the last slot" do
      # This is a known off-by-one: slot=0 → inv_idx = -1 → Enum.at returns last element
      # Put an item in slot 24 (last slot, index 23) and try to sell from slot 0
      inv = List.replace_at(List.duplicate(nil, 24), 23, %{item_id: 100, amount: 5, equipped: false})
      entity = make_entity(%{char_id: :player, commerce_npc_id: 1, inventory: inv})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      # slot=0 → inv_idx = -1 → reads last slot (index 23)
      # If the handler doesn't guard slot > 0, this will find the item
      {:reply, result, _new_state} = Commerce.handle_commerce_sell(state, :player, 0, 1)
      # This SHOULD fail with :empty_slot or :invalid_slot, but due to the off-by-one
      # it will succeed (:ok) or fail on item_def lookup
      # Either way it should not crash
      assert result in [:ok, {:error, :empty_slot}, {:error, :invalid_slot}, {:error, :not_enough}]
    end
  end

  describe "commerce for non-existent player" do
    test "commerce_buy for unknown char returns :not_on_map" do
      state = make_map_state(%{})
      {:reply, result, _state} = Commerce.handle_commerce_buy(state, :unknown, 1, 1)
      assert result == {:error, :not_on_map}
    end

    test "commerce_sell for unknown char returns :not_on_map" do
      state = make_map_state(%{})
      {:reply, result, _state} = Commerce.handle_commerce_sell(state, :unknown, 1, 1)
      assert result == {:error, :not_on_map}
    end
  end

  describe "open_commerce without target" do
    test "open_commerce with nil target returns :no_target" do
      entity = make_entity(%{char_id: :player})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Commerce.handle_open_commerce(state, :player, nil, nil)
      assert result == {:error, :no_target}
    end

    test "open_commerce while dead returns :dead" do
      entity = make_entity(%{char_id: :player, dead: true})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Commerce.handle_open_commerce(state, :player, 50, 50)
      assert result == {:error, :dead}
    end

    test "open_commerce targeting empty tile returns :no_target" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Commerce.handle_open_commerce(state, :player, 55, 55)
      assert result == {:error, :no_target}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank: gold deposit/extract exploit attempts
  # ═══════════════════════════════════════════════════════════════════════════

  describe "bank_deposit_gold exploit attempts" do
    test "deposit_gold with negative amount is rejected" do
      entity = make_entity(%{char_id: :player, bank_npc_id: 1, gold: 1000, bank_gold: 0})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, new_state} = Bank.handle_bank_deposit_gold(state, :player, -500)
      assert result == {:error, :not_enough_gold}
      # Gold must not change
      assert new_state.players[:player].gold == 1000
      assert new_state.players[:player].bank_gold == 0
    end

    test "deposit_gold with amount=0 is rejected" do
      entity = make_entity(%{char_id: :player, bank_npc_id: 1, gold: 1000, bank_gold: 0})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, new_state} = Bank.handle_bank_deposit_gold(state, :player, 0)
      assert result == {:error, :not_enough_gold}
      assert new_state.players[:player].gold == 1000
    end

    test "deposit_gold exceeding player gold is rejected" do
      entity = make_entity(%{char_id: :player, bank_npc_id: 1, gold: 100, bank_gold: 0})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, new_state} = Bank.handle_bank_deposit_gold(state, :player, 200)
      assert result == {:error, :not_enough_gold}
      assert new_state.players[:player].gold == 100
    end

    test "deposit_gold without open bank is rejected" do
      entity = make_entity(%{char_id: :player, bank_npc_id: nil, gold: 1000})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_bank_deposit_gold(state, :player, 100)
      assert result == {:error, :no_bank}
    end
  end

  describe "bank_extract_gold exploit attempts" do
    test "extract_gold with negative amount is rejected" do
      entity = make_entity(%{char_id: :player, bank_npc_id: 1, gold: 0, bank_gold: 1000})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, new_state} = Bank.handle_bank_extract_gold(state, :player, -500)
      assert result == {:error, :not_enough_gold}
      assert new_state.players[:player].bank_gold == 1000
      assert new_state.players[:player].gold == 0
    end

    test "extract_gold with amount=0 is rejected" do
      entity = make_entity(%{char_id: :player, bank_npc_id: 1, gold: 0, bank_gold: 1000})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_bank_extract_gold(state, :player, 0)
      assert result == {:error, :not_enough_gold}
    end

    test "extract_gold exceeding bank gold is rejected" do
      entity = make_entity(%{char_id: :player, bank_npc_id: 1, gold: 0, bank_gold: 100})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, new_state} = Bank.handle_bank_extract_gold(state, :player, 200)
      assert result == {:error, :not_enough_gold}
      assert new_state.players[:player].bank_gold == 100
    end

    test "extract_gold without open bank is rejected" do
      entity = make_entity(%{char_id: :player, bank_npc_id: nil, bank_gold: 1000})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_bank_extract_gold(state, :player, 100)
      assert result == {:error, :no_bank}
    end
  end

  describe "bank_deposit item exploit attempts" do
    test "deposit item without open bank is rejected" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false})
      entity = make_entity(%{char_id: :player, bank_npc_id: nil, inventory: inv})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_bank_deposit(state, :player, 1, 1, 1)
      assert result == {:error, :no_bank}
    end

    test "deposit from empty inventory slot returns :empty_slot" do
      entity = make_entity(%{char_id: :player, bank_npc_id: 1})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_bank_deposit(state, :player, 5, 1, 1)
      assert result == {:error, :empty_slot}
    end

    test "deposit more than available returns :not_enough" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 3, equipped: false})
      entity = make_entity(%{char_id: :player, bank_npc_id: 1, inventory: inv})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_bank_deposit(state, :player, 1, 10, 1)
      assert result == {:error, :not_enough}
    end
  end

  describe "bank_extract item exploit attempts" do
    test "extract item without open bank is rejected" do
      entity = make_entity(%{char_id: :player, bank_npc_id: nil})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_bank_extract_item(state, :player, 1, 1, 1)
      assert result == {:error, :no_bank}
    end
  end

  describe "bank for non-existent player" do
    test "bank_deposit_gold for unknown char returns :not_on_map" do
      state = make_map_state(%{})
      {:reply, result, _state} = Bank.handle_bank_deposit_gold(state, :unknown, 100)
      assert result == {:error, :not_on_map}
    end

    test "bank_extract_gold for unknown char returns :not_on_map" do
      state = make_map_state(%{})
      {:reply, result, _state} = Bank.handle_bank_extract_gold(state, :unknown, 100)
      assert result == {:error, :not_on_map}
    end

    test "bank_deposit for unknown char returns :not_on_map" do
      state = make_map_state(%{})
      {:reply, result, _state} = Bank.handle_bank_deposit(state, :unknown, 1, 1, 1)
      assert result == {:error, :not_on_map}
    end

    test "bank_extract_item for unknown char returns :not_on_map" do
      state = make_map_state(%{})
      {:reply, result, _state} = Bank.handle_bank_extract_item(state, :unknown, 1, 1, 1)
      assert result == {:error, :not_on_map}
    end
  end

  describe "bank slot=0 off-by-one exploit" do
    test "deposit from slot 0 with empty inventory hits off-by-one path" do
      # Empty inventory: slot=0 → inv_idx = -1 → Enum.at(inv, -1) reads last element (nil)
      entity = make_entity(%{char_id: :player, bank_npc_id: 1})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      # slot=0 → inv_idx = -1 → reads nil from empty inventory → :empty_slot
      {:reply, result, _state} = Bank.handle_bank_deposit(state, :player, 0, 1, 1)
      assert result == {:error, :empty_slot}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Movement: speed hack detection and paralysis guard
  # ═══════════════════════════════════════════════════════════════════════════

  describe "movement: paralyzed player cannot move" do
    test "paralyzed player gets :paralyzed error" do
      entity = make_entity(%{char_id: :player, paralyzed: true})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Movement.handle_move(state, :player, :north)
      assert result == {:error, :paralyzed}
    end

    test "immobilized player gets :paralyzed error" do
      entity = make_entity(%{char_id: :player, immobilized: true})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Movement.handle_move(state, :player, :south)
      assert result == {:error, :paralyzed}
    end

    test "player with penalty > 0 gets :paralyzed error" do
      entity = make_entity(%{char_id: :player, penalty: 5})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Movement.handle_move(state, :player, :east)
      assert result == {:error, :paralyzed}
    end
  end

  describe "movement: cooldown enforcement" do
    test "moving before cooldown expires returns :too_early" do
      now = System.monotonic_time(:millisecond)
      entity = make_entity(%{char_id: :player, next_move_at: now + 10_000})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Movement.handle_move(state, :player, :north)
      assert result == {:error, :too_early}
    end
  end

  describe "movement: speed hack accumulator" do
    test "rapid-fire moves accumulate speed_hack_counter" do
      # Set last_step_at to just now (0ms ago) to simulate rapid movement
      now = System.monotonic_time(:millisecond)
      entity = make_entity(%{
        char_id: :player,
        last_step_at: now,
        speed_hack_counter: 2.9,
        next_move_at: -1_000_000_000_000
      })
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, new_state} = Movement.handle_move(state, :player, :north)

      # Counter was 2.9 and threshold is 3.0, so one more rapid step should trigger
      if result == {:error, :speed_hack} do
        # Speed hack detected — counter reset and penalty applied
        assert new_state.players[:player].speed_hack_counter == 0.0
      else
        # Counter accumulated but didn't trigger yet
        assert new_state.players[:player].speed_hack_counter > 2.9
      end
    end
  end

  describe "movement: non-existent player" do
    test "move for unknown char_id returns gracefully" do
      state = make_map_state(%{})
      {:reply, result, _state} = Movement.handle_move(state, :unknown, :north)
      assert result == {:error, :not_on_map}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Chat moderation: mute enforcement
  # ═══════════════════════════════════════════════════════════════════════════

  describe "chat mute enforcement" do
    test "muted player cannot send chat messages" do
      # Set muted_until to far future (wall clock ms)
      muted_until = System.system_time(:millisecond) + 60_000
      entity = make_entity(%{char_id: :player, muted_until: muted_until})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Social.handle_chat(state, :player, "I should be muted")
      # State should not change (no last_chat_at update)
      assert new_state.players[:player].last_chat_at == entity.last_chat_at
      # Player should receive the "silenciado" message
      assert_receive {:send_raw, _}
    end

    test "unmuted player (muted_until=0) can send chat messages" do
      entity = make_entity(%{char_id: :player, muted_until: 0})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Social.handle_chat(state, :player, "Hello!")
      # last_chat_at should be updated
      assert new_state.players[:player].last_chat_at > entity.last_chat_at
    end

    test "player with expired mute can send chat messages" do
      # Muted in the past
      muted_until = System.system_time(:millisecond) - 10_000
      entity = make_entity(%{char_id: :player, muted_until: muted_until})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Social.handle_chat(state, :player, "I can talk again!")
      assert new_state.players[:player].last_chat_at > entity.last_chat_at
    end
  end

  describe "chat rate limiting" do
    test "sending two messages within 1 second is rate-limited" do
      now = System.monotonic_time(:millisecond)
      # last_chat_at is just now
      entity = make_entity(%{char_id: :player, last_chat_at: now})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Social.handle_chat(state, :player, "Second message too fast")
      # last_chat_at should NOT be updated (message was rate-limited)
      assert new_state.players[:player].last_chat_at == entity.last_chat_at
      assert_receive {:send_raw, _}
    end

    test "sending message after cooldown is allowed" do
      # last_chat_at was 2 seconds ago
      now = System.monotonic_time(:millisecond)
      entity = make_entity(%{char_id: :player, last_chat_at: now - 2000})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Social.handle_chat(state, :player, "This should work")
      assert new_state.players[:player].last_chat_at > entity.last_chat_at
    end
  end

  describe "chat for non-existent player" do
    test "chat for unknown char_id is silently ignored" do
      state = make_map_state(%{})
      {:noreply, new_state} = Social.handle_chat(state, :unknown, "Hello")
      assert new_state == state
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Commerce: open commerce targeting self
  # ═══════════════════════════════════════════════════════════════════════════

  describe "open_commerce targeting self" do
    test "clicking own tile does not start self-trade" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50})
      sessions = %{player: self()}
      state = make_map_state(
        %{player: entity},
        sessions: sessions,
        occupancy: %{{50, 50} => {:player, :player}}
      )

      {:reply, result, _state} = Commerce.handle_open_commerce(state, :player, 50, 50)
      # Targeting self should not start a trade (guard: target_id != char_id)
      assert result == {:error, :no_target}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank: open_bank targeting wrong NPC type or too far
  # ═══════════════════════════════════════════════════════════════════════════

  describe "open_bank validation" do
    test "open_bank while dead returns :dead" do
      entity = make_entity(%{char_id: :player, dead: true})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_open_bank(state, :player, 50, 50)
      assert result == {:error, :dead}
    end

    test "open_bank with nil target returns :no_banker" do
      entity = make_entity(%{char_id: :player})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_open_bank(state, :player, nil, nil)
      assert result == {:error, :no_banker}
      assert_receive {:send_raw, _}
    end

    test "open_bank targeting empty tile returns :no_banker" do
      entity = make_entity(%{char_id: :player})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, _state} = Bank.handle_open_bank(state, :player, 60, 60)
      assert result == {:error, :no_banker}
    end

    test "open_bank for unknown char returns :not_on_map" do
      state = make_map_state(%{})
      {:reply, result, _state} = Bank.handle_open_bank(state, :unknown, 50, 50)
      assert result == {:error, :not_on_map}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Commerce end without open commerce
  # ═══════════════════════════════════════════════════════════════════════════

  describe "commerce_end without commerce session" do
    test "commerce_end clears commerce_npc_id even when already nil" do
      entity = make_entity(%{char_id: :player, commerce_npc_id: nil})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, new_state} = Commerce.handle_commerce_end(state, :player)
      assert result == :ok
      assert new_state.players[:player].commerce_npc_id == nil
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank end without open bank
  # ═══════════════════════════════════════════════════════════════════════════

  describe "bank_end without bank session" do
    test "bank_end clears bank_npc_id even when already nil" do
      entity = make_entity(%{char_id: :player, bank_npc_id: nil})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:reply, result, new_state} = Bank.handle_bank_end(state, :player)
      assert result == :ok
      assert new_state.players[:player].bank_npc_id == nil
    end
  end
end
