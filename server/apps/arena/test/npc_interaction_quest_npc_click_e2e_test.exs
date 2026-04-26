defmodule Arena.Map.NpcInteractionQuestNpcClickE2ETest do
  @moduledoc """
  End-to-end tests for the quest-NPC double-click flow through
  `Arena.Map.MapServer.handle_cast({:double_click, ...}, state)`. Pins the
  slice 4 effects migration of `Arena.Map.NpcInteraction.handle_quest_npc_click/5`.

  The handler now returns `{:ok, state, effects}`. Quest completion side
  effects (desc_final, gold reward console + update_gold packet, exp reward
  console) flow through `AoSession.Egress.enqueue/2` as `{:egress, _}`
  envelopes. The `npc_quest_list_send` packet for the "available quests"
  branch also flows through Egress.

  Pattern mirrors `npc_interaction_arena_entry_e2e_test.exs`.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.{MapServer, NpcInteraction}
  alias Arena.Data.{GameData, QuestDef}

  import Arena.Test.MapStateFactory

  # VB6: NpcType=17 = quest giver
  @npc_type_quest 17

  @quest_npc_id 99_901
  @quest_npc_def %{
    id: @quest_npc_id,
    npc_id: @quest_npc_id,
    name: "QuestGiver",
    npc_type: @npc_type_quest,
    comercia: false,
    shop_items: [],
    quest_numbers: [11_001, 11_002, 11_003, 11_004],
    creatures: []
  }

  # Quest with all rewards.
  @full_quest_id 11_001
  @full_quest_def %QuestDef{
    id: @full_quest_id,
    name: "Full Reward Quest",
    desc: "kill stuff",
    desc_final: "Bien hecho!",
    required_level: 0,
    limit_level: 0,
    required_npcs: [],
    required_objs: [],
    reward_exp: 100,
    reward_gld: 50,
    reward_objs: [],
    repetible: false
  }

  # Quest with reward_gld == 0.
  @no_gold_quest_id 11_002
  @no_gold_quest_def %QuestDef{
    id: @no_gold_quest_id,
    name: "No Gold Quest",
    desc: "no gold",
    desc_final: "Sin oro!",
    required_level: 0,
    limit_level: 0,
    required_npcs: [],
    required_objs: [],
    reward_exp: 75,
    reward_gld: 0,
    reward_objs: [],
    repetible: false
  }

  # Quest with reward_exp == 0.
  @no_exp_quest_id 11_003
  @no_exp_quest_def %QuestDef{
    id: @no_exp_quest_id,
    name: "No Exp Quest",
    desc: "no exp",
    desc_final: "Sin experiencia!",
    required_level: 0,
    limit_level: 0,
    required_npcs: [],
    required_objs: [],
    reward_exp: 0,
    reward_gld: 60,
    reward_objs: [],
    repetible: false
  }

  # Quest with empty desc_final.
  @no_desc_quest_id 11_004
  @no_desc_quest_def %QuestDef{
    id: @no_desc_quest_id,
    name: "No Desc Quest",
    desc: "no desc",
    desc_final: "",
    required_level: 0,
    limit_level: 0,
    required_npcs: [],
    required_objs: [],
    reward_exp: 25,
    reward_gld: 30,
    reward_objs: [],
    repetible: false
  }

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
      gold: 1_000,
      inventory: List.duplicate(nil, 24),
      equipment: %{
        weapon: nil,
        armor: nil,
        shield: nil,
        helmet: nil,
        ring: nil,
        municion: nil,
        saddle: nil
      },
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
      last_clicked_npc_type: nil
    }

    Map.merge(defaults, overrides)
  end

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    :ets.insert(:arena_game_data, {{:npc, @quest_npc_id}, @quest_npc_def})
    :ets.insert(:arena_game_data, {{:quest, @full_quest_id}, @full_quest_def})
    :ets.insert(:arena_game_data, {{:quest, @no_gold_quest_id}, @no_gold_quest_def})
    :ets.insert(:arena_game_data, {{:quest, @no_exp_quest_id}, @no_exp_quest_def})
    :ets.insert(:arena_game_data, {{:quest, @no_desc_quest_id}, @no_desc_quest_def})

    drain()

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, @quest_npc_id})
      :ets.delete(:arena_game_data, {:quest, @full_quest_id})
      :ets.delete(:arena_game_data, {:quest, @no_gold_quest_id})
      :ets.delete(:arena_game_data, {:quest, @no_exp_quest_id})
      :ets.delete(:arena_game_data, {:quest, @no_desc_quest_id})
    end)

    :ok
  end

  defp drain do
    receive do
      _ -> drain()
    after
      10 -> :ok
    end
  end

  defp quest_npc, do: %{npc_id: @quest_npc_id, x: 51, y: 50, instance_id: :quest_inst}

  defp state_with(entity_overrides, opts \\ []) do
    entity = make_entity(entity_overrides)

    occupancy = Keyword.get(opts, :occupancy, %{{51, 50} => {:npc, :quest_inst}})

    map_state(
      players: %{player: entity},
      sessions: Keyword.get(opts, :sessions, %{player: self()}),
      npcs_live: Keyword.get(opts, :npcs_live, %{quest_inst: quest_npc()}),
      occupancy: occupancy
    )
  end

  defp active_quest(quest_id),
    do: %{quest_id: quest_id, npc_kills: %{}, started_at: 0}

  # ════════════════════════════════════════════════════════════════════════
  # Successful path #1 — completable quest with all rewards
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:double_click, ...}) → quest NPC — completable" do
    test "completable quest with all rewards: desc_final → gold console → update_gold → exp console" do
      state =
        state_with(%{
          gold: 1_000,
          xp: 0,
          active_quests: [active_quest(@full_quest_id)]
        })

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert player.active_quests == [], "completed quest must be removed from active_quests"
      assert MapSet.member?(player.completed_quests, @full_quest_id)
      assert player.gold == 1_050, "+50 gold from quest reward"
      assert player.xp == 100, "+100 xp from quest reward"

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      # Effect ordering: desc_final console → gold console → update_gold → exp console.
      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = p1}}

      assert :binary.match(p1, "Bien hecho!") != :nomatch,
             "first envelope must be the desc_final console"

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = p2}}

      assert :binary.match(p2, "monedas de oro") != :nomatch,
             "second envelope must be the gold reward console"

      assert_receive {:egress,
                      %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = p4}}

      assert :binary.match(p4, "puntos de experiencia") != :nomatch,
             "fourth envelope must be the exp reward console"

      refute_receive {:send_raw, _}, 50
    end

    test "quest with reward_gld == 0: no update_gold packet emitted, no gold-reward console" do
      state =
        state_with(%{
          gold: 1_000,
          xp: 0,
          active_quests: [active_quest(@no_gold_quest_id)]
        })

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert player.gold == 1_000, "no gold reward → gold unchanged"
      assert player.xp == 75

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      # Receives desc_final and exp messages, but NOT update_gold and NOT
      # the gold-reward console.
      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = p1}}

      assert :binary.match(p1, "Sin oro!") != :nomatch

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = p2}}

      assert :binary.match(p2, "puntos de experiencia") != :nomatch

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:send_raw, _}, 50
    end

    test "quest with reward_exp == 0: no exp reward console" do
      state =
        state_with(%{
          gold: 1_000,
          xp: 0,
          active_quests: [active_quest(@no_exp_quest_id)]
        })

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert player.xp == 0, "no xp reward → xp unchanged"
      assert player.gold == 1_060

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      # desc_final → gold console → update_gold; NO exp console.
      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = p1}}

      assert :binary.match(p1, "Sin experiencia!") != :nomatch

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = p2}}

      assert :binary.match(p2, "monedas de oro") != :nomatch

      assert_receive {:egress,
                      %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, "Recibiste"::binary,
                                    _::binary>>}},
                     50

      refute_receive {:send_raw, _}, 50
    end

    test "quest with empty desc_final: no desc_final console (other rewards still emit)" do
      state =
        state_with(%{
          gold: 1_000,
          xp: 0,
          active_quests: [active_quest(@no_desc_quest_id)]
        })

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert player.gold == 1_030
      assert player.xp == 25

      # First console should be the gold-reward (no desc_final precedes it).
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = p1}}

      assert :binary.match(p1, "monedas de oro") != :nomatch,
             "first console must be gold reward (no desc_final precedes)"

      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Successful path #2 — available quests, no completable
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:double_click, ...}) → quest NPC — available quests" do
    test "available quests, no completable: npc_quest_list_send packet sent, quest_npc_id set" do
      state =
        state_with(%{
          gold: 1_000,
          xp: 0,
          active_quests: [],
          completed_quests: MapSet.new()
        })

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert player.quest_npc_id == @quest_npc_id

      list_id = AoProtocol.PacketIds.Server.npc_quest_list_send()

      assert_receive {:egress,
                      %{payload: <<^list_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Successful path #3 — no completable, no available
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:double_click, ...}) → quest NPC — no quests" do
    test "no completable, no available: 'No tengo misiones disponibles' console" do
      # Player has already completed every quest the NPC offers.
      state =
        state_with(%{
          gold: 1_000,
          xp: 0,
          active_quests: [],
          completed_quests:
            MapSet.new([
              @full_quest_id,
              @no_gold_quest_id,
              @no_exp_quest_id,
              @no_desc_quest_id
            ])
        })

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert player.quest_npc_id == nil, "quest_npc_id must NOT be set on the no-quests branch"

      console_id = AoProtocol.PacketIds.Server.console_msg()
      list_id = AoProtocol.PacketIds.Server.npc_quest_list_send()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "No tengo misiones disponibles") != :nomatch

      refute_receive {:egress, %{payload: <<^list_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Adversarial coverage
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:double_click, ...}) → quest NPC — adversarial" do
    test "multiple completable quests: only the FIRST one in active_quests is completed" do
      # Adversarial: when more than one active quest is completable for
      # the same NPC, the handler must complete exactly ONE (the head of
      # the filtered list, i.e. the lowest-slot active quest). The other
      # remains untouched in active_quests.
      state =
        state_with(%{
          gold: 1_000,
          xp: 0,
          # Two completable quests under the same NPC.
          active_quests: [active_quest(@full_quest_id), active_quest(@no_gold_quest_id)]
        })

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]

      # Only the head (full_quest_id) should be completed — no_gold remains.
      assert player.active_quests == [active_quest(@no_gold_quest_id)],
             "second completable quest must NOT auto-complete in the same click"

      assert MapSet.member?(player.completed_quests, @full_quest_id)
      refute MapSet.member?(player.completed_quests, @no_gold_quest_id)

      # Reward arithmetic must reflect ONLY the full quest.
      assert player.gold == 1_050
      assert player.xp == 100
    end

    test "player not in state.players: handler returns {:ok, state, []}" do
      # Direct-call check on the handler — switchboard never enters this
      # branch (it fetches entity beforehand).
      entity = make_entity(%{})
      state = map_state(players: %{}, sessions: %{player: self()})

      assert {:ok, ^state, []} =
               NpcInteraction.handle_quest_npc_click(
                 state,
                 :player,
                 entity,
                 :quest_inst,
                 @quest_npc_def
               )

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end
end
