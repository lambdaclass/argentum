defmodule Arena.ChatAnticheatTest do
  @moduledoc "Adversarial tests for chat anti-cheat: yell muting, cooldown, filter."
  use ExUnit.Case, async: true

  import Arena.Test.MapStateFactory

  alias Arena.Map.Chat

  defp make_entity(overrides) do
    defaults = %{
      char_id: :player,
      name: "Tester",
      account_id: "acc_test",
      x: 50, y: 50,
      heading: :south,
      body_id: 1, base_body_id: 1, head_id: 1,
      hp: 100, max_hp: 100,
      mana: 200, max_mana: 200,
      stamina: 100, max_stamina: 100,
      hunger: 100, thirst: 100,
      level: 25, xp: 0,
      class: :warrior, race: :human, gender: :male,
      str: 18, agi: 18, int: 18, con: 18, cha: 18,
      gold: 0,
      inventory: List.duplicate(nil, 24),
      equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
      skills: %{magic: 80},
      spells: [1],
      buffs: [],
      min_hit: 0, max_hit: 0,
      str_buff: 0, agi_buff: 0,
      dead: false, poisoned: false, criminal: false,
      invisible: false, oculto: false, oculto_timer: 0,
      no_detectable: false, paralyzed: false, immobilized: false,
      meditating: false, resting: false, safe_mode: false, navigating: false,
      gm: false,
      faction: :none,
      next_move_at: -1_000_000_000_000,
      next_attack_at: -1_000_000_000_000,
      next_spell_at: -1_000_000_000_000,
      next_item_use_at: -1_000_000_000_000,
      spell_cooldowns: %{},
      char_index: 1, map_id: 1,
      npcs_killed: 0, deaths: 0, penalty: 0, skill_points: 0,
      home_city: :ullathorpe,
      faction_kills_royal: 0, faction_kills_chaos: 0,
      citizens_killed: 0, criminals_killed: 0,
      faction_score: 0, faction_rank_armada: 0, faction_rank_chaos: 0,
      faction_reenlistadas: 0, fishing_points: 0,
      last_step_at: -1_000_000_000_000,
      speed_hack_counter: 0.0, speeding: 1.0,
      commerce_npc_id: nil, bank_npc_id: nil, bank_gold: 0,
      trade_request_target: nil, trade_partner_id: nil,
      trade_offer_gold: 0, trade_offer_items: [],
      trade_accepted: false, pet_ids: [],
      description: "", muted_until: 0,
      last_chat_at: -1_000_000_000_000,
      spouse_id: 0, marriage_proposal_target: nil,
      in_duel: false, duel_opponent_id: nil,
      gamble_wins: 0, gamble_losses: 0, gamble_plays: 0,
      active_quests: [], completed_quests: MapSet.new(),
      quest_npc_id: nil, mounted: false,
      saddle_obj_index: 0, saddle_slot: 0
    }
    Map.merge(defaults, overrides)
  end

  defp make_state(players, opts \\ []) do
    sessions = Keyword.get(opts, :sessions, %{})
    map_state(
      players: players,
      sessions: sessions,
      meta: %{rain: false, snow: false, sin_invi_ocul: false}
    )
  end

  describe "handle_yell muting" do
    test "muted player cannot yell" do
      # muted_until is in the future (wall clock ms)
      muted_until = System.system_time(:millisecond) + 60_000
      entity = make_entity(%{muted_until: muted_until})
      state = make_state(%{1 => entity})

      {:noreply, new_state} = Chat.handle_yell(state, 1, "Hello world!")

      # State should be unchanged (yell was blocked)
      assert new_state == state
    end

    test "expired mute allows yell" do
      # muted_until is in the past (wall clock ms)
      entity = make_entity(%{muted_until: 1})
      state = make_state(%{1 => entity})

      {:noreply, new_state} = Chat.handle_yell(state, 1, "Hello world!")

      # State should change (last_chat_at updated)
      player = Map.get(new_state.players, 1)
      assert player.last_chat_at > entity.last_chat_at
    end

    test "unmuted player (muted_until: 0) can yell" do
      entity = make_entity(%{muted_until: 0})
      state = make_state(%{1 => entity})

      {:noreply, new_state} = Chat.handle_yell(state, 1, "Hello world!")

      player = Map.get(new_state.players, 1)
      assert player.last_chat_at > entity.last_chat_at
    end
  end

  describe "handle_yell cooldown" do
    test "yell blocked by cooldown" do
      # last_chat_at is very recent (within cooldown)
      now = System.monotonic_time(:millisecond)
      entity = make_entity(%{last_chat_at: now})
      state = make_state(%{1 => entity})

      {:noreply, new_state} = Chat.handle_yell(state, 1, "Spam!")

      # State unchanged — cooldown blocked
      assert new_state == state
    end

    test "yell allowed after cooldown expires" do
      # last_chat_at is far in the past
      entity = make_entity(%{last_chat_at: -1_000_000_000_000})
      state = make_state(%{1 => entity})

      {:noreply, new_state} = Chat.handle_yell(state, 1, "Hello!")

      player = Map.get(new_state.players, 1)
      assert player.last_chat_at > -1_000_000_000_000
    end
  end

  describe "handle_yell dead check" do
    test "dead player cannot yell" do
      entity = make_entity(%{dead: true})
      state = make_state(%{1 => entity})

      {:noreply, new_state} = Chat.handle_yell(state, 1, "Help!")

      assert new_state == state
    end
  end

  describe "handle_yell with nonexistent player" do
    test "returns state unchanged" do
      state = make_state(%{})

      {:noreply, new_state} = Chat.handle_yell(state, 999, "Hello!")

      assert new_state == state
    end
  end

  describe "handle_chat muting" do
    test "muted player cannot chat" do
      muted_until = System.system_time(:millisecond) + 60_000
      entity = make_entity(%{muted_until: muted_until})
      state = make_state(%{1 => entity})

      {:noreply, new_state} = Chat.handle_chat(state, 1, "Hello!")

      assert new_state == state
    end

    test "chat cooldown blocks rapid messages" do
      now = System.monotonic_time(:millisecond)
      entity = make_entity(%{last_chat_at: now})
      state = make_state(%{1 => entity})

      {:noreply, new_state} = Chat.handle_chat(state, 1, "Spam!")

      assert new_state == state
    end
  end

  describe "adversarial chat scenarios" do
    test "muted player cannot bypass mute by alternating chat and yell" do
      muted_until = System.system_time(:millisecond) + 60_000
      entity = make_entity(%{muted_until: muted_until})
      state = make_state(%{1 => entity})

      {:noreply, state1} = Chat.handle_chat(state, 1, "Chat attempt")
      {:noreply, state2} = Chat.handle_yell(state1, 1, "Yell attempt")
      {:noreply, state3} = Chat.handle_chat(state2, 1, "Chat again")

      # All should be blocked — state unchanged
      assert state3 == state
    end

    test "rapid yell spam is rate limited" do
      entity = make_entity(%{last_chat_at: -1_000_000_000_000})
      state = make_state(%{1 => entity})

      # First yell should go through
      {:noreply, state1} = Chat.handle_yell(state, 1, "First yell")
      player1 = Map.get(state1.players, 1)
      assert player1.last_chat_at > -1_000_000_000_000

      # Second immediate yell should be blocked by cooldown
      {:noreply, state2} = Chat.handle_yell(state1, 1, "Second yell")
      player2 = Map.get(state2.players, 1)
      # last_chat_at should NOT have changed (yell was blocked)
      assert player2.last_chat_at == player1.last_chat_at
    end
  end
end
