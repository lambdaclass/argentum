defmodule Arena.QuestDriftTest do
  @moduledoc """
  Regression tests for quest system protocol/VB6 drifts:

  Drift Q1 — available_quests_for_npc arguments reversed.
    quest_server.ex defines: def available_quests_for_npc(entity, npc_def)
    npc_interaction.ex:632 and quest_handlers.ex:80 call it with
    (npc_def, entity) — arguments are swapped.

  Drift Q2 — Quest handler contract mismatches (3 sub-bugs).
    a) quest_handlers.ex:44 passes quest-state map to build_quest_details/2,
       but quest_server.ex:98 expects a slot index.
    b) npc_interaction.ex:601 passes quest-state map to quest_complete?/2,
       but quest_server.ex:72 expects a slot index.
    c) npc_interaction.ex:606 expects complete_quest/2 to return
       {:ok, updated_entity, quest_def}, but quest_server.ex:81 returns
       just the updated entity.

  Drift Q3 — Quest abandon off-by-one.
    quest_handlers.ex:109 computes index = quest_slot - 1 for validation,
    then calls abandon_quest(entity, quest_slot) with the original 1-based
    slot instead of the 0-based index.

  Drift Q4 — eQuest packet semantics.
    session_logic.ex:746 routes {:quest, _} to MapServer.quest, which
    calls QuestHandlers.handle_quest, which just returns the active quest
    list. This is a valid "show my quests" feature. Test documents the
    current behavior without changing it.
  """
  use ExUnit.Case, async: false

  import Arena.Test.MapStateFactory

  alias Arena.QuestServer
  alias Arena.Map.QuestHandlers
  alias Arena.Map.NpcInteraction
  alias Arena.Data.QuestDef

  # ── helpers ──

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
      equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
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
      saddle_slot: 0,
      last_clicked_npc_instance_id: nil,
      last_clicked_npc_type: nil,
      punishments: []
    }

    Map.merge(defaults, overrides)
  end

  defp make_map_state(players, opts \\ []) do
    sessions = Keyword.get(opts, :sessions, %{})

    map_state(
      players: players,
      sessions: sessions,
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, snow: false, sin_invi_ocul: false}
    )
  end

  # A fake quest definition for testing (quest_id = 9999)
  defp test_quest_def do
    %QuestDef{
      id: 9999,
      name: "Test Quest",
      desc: "Kill a bandit",
      desc_final: "Well done!",
      required_level: 0,
      limit_level: 0,
      required_npcs: [%{id: 100, amount: 1}],
      required_objs: [],
      reward_exp: 500,
      reward_gld: 200,
      reward_objs: [],
      repetible: false
    }
  end

  # A second fake quest for multi-quest scenarios (quest_id = 9998)
  defp test_quest_def_2 do
    %QuestDef{
      id: 9998,
      name: "Second Quest",
      desc: "Gather herbs",
      desc_final: "Thanks for the herbs!",
      required_level: 0,
      limit_level: 0,
      required_npcs: [],
      required_objs: [],
      reward_exp: 100,
      reward_gld: 50,
      reward_objs: [],
      repetible: false
    }
  end

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Insert test quest definitions into ETS so QuestServer can find them
    :ets.insert(:arena_game_data, {{:quest, 9999}, test_quest_def()})
    :ets.insert(:arena_game_data, {{:quest, 9998}, test_quest_def_2()})

    # Insert a quest NPC definition (npc_type=17) with quest_numbers
    npc_def = %{
      id: 500,
      name: "Quest Giver",
      npc_type: 17,
      quest_numbers: [9999, 9998],
      comercia: false
    }

    :ets.insert(:arena_game_data, {{:npc, 500}, npc_def})

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:quest, 9999})
      :ets.delete(:arena_game_data, {:quest, 9998})
      :ets.delete(:arena_game_data, {:npc, 500})
    end)

    :ok
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift Q1 — available_quests_for_npc arguments reversed
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift Q1: available_quests_for_npc argument order" do
    test "QuestServer.available_quests_for_npc(entity, npc_def) returns available quest IDs" do
      entity = make_entity(%{active_quests: [], completed_quests: MapSet.new()})

      npc_def = %{
        id: 500,
        name: "Quest Giver",
        npc_type: 17,
        quest_numbers: [9999, 9998],
        comercia: false
      }

      # Call with the correct argument order: (entity, npc_def)
      result = QuestServer.available_quests_for_npc(entity, npc_def)

      # Should return the quest IDs from the NPC that the player hasn't done
      assert is_list(result)
      assert 9999 in result
      assert 9998 in result
    end

    test "handle_quest_accept calls available_quests_for_npc with correct arg order" do
      # Player is interacting with NPC 500
      entity =
        make_entity(%{
          char_id: 1,
          quest_npc_id: 500,
          active_quests: [],
          completed_quests: MapSet.new()
        })

      sessions = %{1 => self()}
      state = make_map_state(%{1 => entity}, sessions: sessions)

      # handle_quest_accept should use available_quests_for_npc(entity, npc_def),
      # not available_quests_for_npc(npc_def, entity).
      # list_index=1 means "first quest in the available list" (1-based)
      result = QuestHandlers.handle_quest_accept(state, 1, 1)

      # Should succeed without crashing: the quest gets accepted
      assert {:noreply, new_state} = result

      # Verify quest was actually accepted (not empty due to reversed args)
      updated = new_state.players[1]
      assert length(updated.active_quests) == 1
      assert hd(updated.active_quests).quest_id == 9999
    end

    test "available_quests_for_npc with reversed args returns empty list (demonstrates bug)" do
      # This test proves that calling with reversed args (npc_def, entity) fails:
      # npc_def has no :active_quests or :completed_quests fields, and entity
      # has no :quest_numbers field, so the function returns [].
      entity = make_entity(%{active_quests: [], completed_quests: MapSet.new()})

      npc_def = %{
        id: 500,
        name: "Quest Giver",
        npc_type: 17,
        quest_numbers: [9999, 9998],
        comercia: false
      }

      # Correct order returns quest IDs
      correct = QuestServer.available_quests_for_npc(entity, npc_def)
      assert length(correct) == 2

      # Reversed order: npc_def has no quest_numbers when accessed as entity,
      # and entity has no quest_numbers field → returns []
      reversed = QuestServer.available_quests_for_npc(npc_def, entity)
      assert reversed == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift Q2 — Quest handler contract mismatches
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift Q2a: build_quest_details expects slot index, not quest-state map" do
    test "handle_quest_details_request builds details for quest at slot 1" do
      quest_state = %{quest_id: 9999, npc_kills: %{100 => 0}, started_at: 0}
      entity = make_entity(%{char_id: 1, active_quests: [quest_state]})

      sessions = %{1 => self()}
      state = make_map_state(%{1 => entity}, sessions: sessions)

      # quest_slot=1 (1-based from protocol) should be converted to index=0
      # and passed to build_quest_details(entity, 0)
      result = QuestHandlers.handle_quest_details_request(state, 1, 1)
      assert {:noreply, _} = result

      # Should receive the quest details packet (not "Datos de mision no disponibles.")
      assert_receive {:send_raw, _raw}
    end
  end

  describe "Drift Q2b: quest_complete? expects slot index, not quest-state map" do
    test "quest_complete? works with slot index for a completed quest" do
      # Quest 9998 requires no NPCs and no objects, so it's immediately complete
      quest_state = %{quest_id: 9998, npc_kills: %{}, started_at: 0}
      entity = make_entity(%{char_id: 1, active_quests: [quest_state]})

      # Correct call: slot index 0
      assert QuestServer.quest_complete?(entity, 0) == true

      # Wrong call: passing the quest_state map instead of index.
      # The guard `slot >= 0` would fail on a map, returning false.
      assert QuestServer.quest_complete?(entity, quest_state) == false
    end

    test "NPC double-click completes a ready quest (exercises slot index)" do
      # Quest 9998 has no requirements, so it's immediately completable
      quest_state = %{quest_id: 9998, npc_kills: %{}, started_at: 0}

      entity =
        make_entity(%{
          char_id: 1,
          active_quests: [quest_state],
          completed_quests: MapSet.new()
        })

      npc_instance = %{npc_id: 500, x: 50, y: 50, hp: 100}

      sessions = %{1 => self()}
      npcs_live = %{1001 => npc_instance}
      state = make_map_state(%{1 => entity}, sessions: sessions, npcs_live: npcs_live)

      # NPC click should detect quest 9998 as completable and complete it
      result = NpcInteraction.handle_npc_double_click(state, 1, entity, 1001)
      assert {:noreply, new_state} = result

      # If quest_complete? was called with the map instead of the index,
      # it would return false and skip the completion. Verify the quest
      # was actually completed (removed from active_quests).
      updated_entity = new_state.players[1]
      assert updated_entity.active_quests == []
      assert MapSet.member?(updated_entity.completed_quests, 9998)
    end
  end

  describe "Drift Q2c: complete_quest returns entity, not {:ok, entity, quest_def}" do
    test "QuestServer.complete_quest returns updated entity, not a tuple" do
      quest_state = %{quest_id: 9998, npc_kills: %{}, started_at: 0}

      entity =
        make_entity(%{
          char_id: 1,
          active_quests: [quest_state],
          completed_quests: MapSet.new()
        })

      # complete_quest returns the updated entity directly, not {:ok, entity, quest_def}
      result = QuestServer.complete_quest(entity, 0)
      assert is_map(result)
      refute match?({:ok, _, _}, result)
      assert result.active_quests == []
      assert MapSet.member?(result.completed_quests, 9998)
    end

    test "NPC double-click completes quest and grants rewards correctly" do
      # Quest 9998 has no requirements, immediately completable
      quest_state = %{quest_id: 9998, npc_kills: %{}, started_at: 0}

      entity =
        make_entity(%{
          char_id: 1,
          active_quests: [quest_state],
          completed_quests: MapSet.new()
        })

      npc_instance = %{npc_id: 500, x: 50, y: 50, hp: 100}

      sessions = %{1 => self()}
      npcs_live = %{1001 => npc_instance}
      state = make_map_state(%{1 => entity}, sessions: sessions, npcs_live: npcs_live)

      # This should NOT crash with a match error on {:ok, updated_entity, quest_def}
      result = NpcInteraction.handle_npc_double_click(state, 1, entity, 1001)
      assert {:noreply, new_state} = result

      # Verify quest was completed and rewards were granted
      updated = new_state.players[1]
      assert updated.active_quests == []
      assert MapSet.member?(updated.completed_quests, 9998)
      # reward_exp = 100 from quest 9998
      assert updated.xp == 100
      # reward_gld = 50 from quest 9998; original gold = 1000
      assert updated.gold == 1050
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift Q3 — Quest abandon off-by-one
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift Q3: quest abandon off-by-one" do
    test "handle_quest_abandon with slot=1 removes the FIRST quest (index 0)" do
      quest_a = %{quest_id: 9999, npc_kills: %{}, started_at: 0}
      quest_b = %{quest_id: 9998, npc_kills: %{}, started_at: 0}

      entity =
        make_entity(%{
          char_id: 1,
          active_quests: [quest_a, quest_b]
        })

      sessions = %{1 => self()}
      state = make_map_state(%{1 => entity}, sessions: sessions)

      # Protocol sends quest_slot=1 (1-based). The handler should convert
      # to 0-based index and pass index=0 to abandon_quest.
      # Bug: it passed quest_slot=1 directly, which removes the SECOND quest.
      {:noreply, new_state} = QuestHandlers.handle_quest_abandon(state, 1, 1)

      updated = new_state.players[1]

      # After abandoning slot 1 (first quest), only quest_b should remain
      assert length(updated.active_quests) == 1
      assert hd(updated.active_quests).quest_id == 9998
    end

    test "handle_quest_abandon with slot=2 removes the SECOND quest (index 1)" do
      quest_a = %{quest_id: 9999, npc_kills: %{}, started_at: 0}
      quest_b = %{quest_id: 9998, npc_kills: %{}, started_at: 0}

      entity =
        make_entity(%{
          char_id: 1,
          active_quests: [quest_a, quest_b]
        })

      sessions = %{1 => self()}
      state = make_map_state(%{1 => entity}, sessions: sessions)

      {:noreply, new_state} = QuestHandlers.handle_quest_abandon(state, 1, 2)

      updated = new_state.players[1]

      # After abandoning slot 2 (second quest), only quest_a should remain
      assert length(updated.active_quests) == 1
      assert hd(updated.active_quests).quest_id == 9999
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift Q4 — eQuest packet semantics (document current behavior)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift Q4: handle_quest returns quest list (documenting current behavior)" do
    test "handle_quest delegates to handle_quest_list_request and sends active quest list" do
      quest_state = %{quest_id: 9999, npc_kills: %{}, started_at: 0}

      entity =
        make_entity(%{
          char_id: 1,
          active_quests: [quest_state]
        })

      sessions = %{1 => self()}
      state = make_map_state(%{1 => entity}, sessions: sessions)

      # handle_quest just shows the player's own quest list
      result = QuestHandlers.handle_quest(state, 1)
      assert {:noreply, _} = result

      # Should receive the quest list packet
      assert_receive {:send_raw, _raw}
    end

    test "handle_quest with no active quests sends empty list" do
      entity =
        make_entity(%{
          char_id: 1,
          active_quests: []
        })

      sessions = %{1 => self()}
      state = make_map_state(%{1 => entity}, sessions: sessions)

      result = QuestHandlers.handle_quest(state, 1)
      assert {:noreply, _} = result

      # Should still send a packet (with count=0)
      assert_receive {:send_raw, _raw}
    end
  end
end
