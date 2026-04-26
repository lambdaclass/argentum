defmodule Arena.InformationQuestDriftTest do
  @moduledoc """
  VB6 parity drift tests for eInformation and eQuest packet routing.

  Drift INFO — eInformation routes to double_click instead of enlistador info flow.
    Current: session_logic.ex:469 maps {:information, _} to MapServer.double_click
    VB6 (Protocol.bas:4567-4598): HandleInformation is an enlistador-specific flow:
      1. Validates TargetNPC is selected
      2. Checks NPC type is Enlistador
      3. Checks player alive
      4. Distance <= 4
      5. Shows faction-specific messages based on NPC faction (Royal Army vs Chaos Legion)

  Drift QUEST — eQuest routes to quest-list instead of NPC quest interaction.
    Current: session_logic.ex:746 maps {:quest, _} to QuestHandlers.handle_quest
             which calls handle_quest_list_request (shows player's active quests).
    VB6 (Protocol.bas:7010-7031): HandleQuest validates TargetNPC, checks distance <= 5,
             then shows that NPC's available quests.
  """
  use ExUnit.Case, async: false

  alias Arena.Map.NpcInteraction
  alias Arena.Map.QuestHandlers
  alias Arena.Data.GameData

  import Arena.Test.MapStateFactory

  # ── helpers ──

  defp make_entity(overrides \\ %{}) do
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
      last_clicked_npc_instance_id: nil,
      last_clicked_npc_type: nil,
      punishments: []
    }

    Map.merge(defaults, overrides)
  end

  defp make_map_state(players, opts \\ []) do
    map_state(
      players: players,
      sessions: Keyword.get(opts, :sessions, %{}),
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, snow: false, sin_invi_ocul: false}
    )
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # Royal Army enlistador NPC (faccion=3 means royal_army)
  @enlistador_royal_npc %{npc_id: 88801, x: 51, y: 50, hp: 100}
  @enlistador_royal_def %{
    id: 88801,
    npc_id: 88801,
    name: "Enlistador Real",
    npc_type: 5,
    faccion: 3,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  # Chaos Legion enlistador NPC (faccion=2 means chaos_legion)
  @enlistador_chaos_npc %{npc_id: 88802, x: 51, y: 50, hp: 100}
  @enlistador_chaos_def %{
    id: 88802,
    npc_id: 88802,
    name: "Enlistador Caos",
    npc_type: 5,
    faccion: 2,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  # Enlistador far away (distance > 4)
  @enlistador_far_npc %{npc_id: 88801, x: 55, y: 50, hp: 100}

  # Quest NPC definition
  @quest_npc %{npc_id: 88810, x: 51, y: 50, hp: 100}
  @quest_npc_def %{
    id: 88810,
    npc_id: 88810,
    name: "Quest Giver",
    npc_type: 17,
    comercia: false,
    shop_items: [],
    quest_numbers: [88901, 88902],
    creatures: []
  }

  # Quest NPC far away (distance > 5)
  @quest_npc_far %{npc_id: 88810, x: 56, y: 50, hp: 100}

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    :ets.insert(:arena_game_data, {{:npc, 88801}, @enlistador_royal_def})
    :ets.insert(:arena_game_data, {{:npc, 88802}, @enlistador_chaos_def})
    :ets.insert(:arena_game_data, {{:npc, 88810}, @quest_npc_def})

    # Insert test quest definitions
    :ets.insert(:arena_game_data, {{:quest, 88901}, %Arena.Data.QuestDef{
      id: 88901,
      name: "Test Quest A",
      desc: "Kill goblins",
      desc_final: "Well done!",
      required_level: 0,
      limit_level: 0,
      required_npcs: [],
      required_objs: [],
      reward_exp: 100,
      reward_gld: 50,
      reward_objs: [],
      repetible: false
    }})

    :ets.insert(:arena_game_data, {{:quest, 88902}, %Arena.Data.QuestDef{
      id: 88902,
      name: "Test Quest B",
      desc: "Gather herbs",
      desc_final: "Thanks!",
      required_level: 0,
      limit_level: 0,
      required_npcs: [],
      required_objs: [],
      reward_exp: 50,
      reward_gld: 25,
      reward_objs: [],
      repetible: false
    }})

    flush_mailbox()

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, 88801})
      :ets.delete(:arena_game_data, {:npc, 88802})
      :ets.delete(:arena_game_data, {:npc, 88810})
      :ets.delete(:arena_game_data, {:quest, 88901})
      :ets.delete(:arena_game_data, {:quest, 88902})
    end)

    :ok
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift INFO — eInformation must route to enlistador info flow
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift INFO: eInformation is enlistador-specific, not double_click" do
    test "handle_information near royal army enlistador shows royal faction message" do
      entity = make_entity(%{faction: :royal_army})

      state = make_map_state(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{enl_inst: @enlistador_royal_npc}
      )

      {:ok, _new_state, effects} = NpcInteraction.handle_information(state, :player)

      # VB6: royal army enlistador shows duty message about criminals
      assert effect_payload_contains?(effects, "criminales")
    end

    test "handle_information near chaos enlistador shows chaos faction message" do
      entity = make_entity(%{faction: :chaos_legion})

      state = make_map_state(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{enl_inst: @enlistador_chaos_npc}
      )

      {:ok, _new_state, effects} = NpcInteraction.handle_information(state, :player)

      # VB6: chaos enlistador shows duty message about citizens
      assert effect_payload_contains?(effects, "ciudadanos")
    end

    test "handle_information rejects dead player" do
      entity = make_entity(%{dead: true, faction: :royal_army})

      state = make_map_state(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{enl_inst: @enlistador_royal_npc}
      )

      {:ok, _state, effects} = NpcInteraction.handle_information(state, :player)

      # Dead player should get an error, not faction info
      assert effect_payload_contains?(effects, "muerto")
    end

    test "handle_information rejects when no enlistador nearby" do
      entity = make_entity(%{faction: :royal_army})

      state = make_map_state(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{}
      )

      {:ok, _state, effects} = NpcInteraction.handle_information(state, :player)

      # No enlistador → no faction message
      assert effects == []
    end

    test "handle_information rejects when enlistador is too far (distance > 4)" do
      entity = make_entity(%{faction: :royal_army})

      state = make_map_state(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{enl_inst: @enlistador_far_npc}
      )

      {:ok, _state, effects} = NpcInteraction.handle_information(state, :player)

      # Enlistador at distance 5 should be too far (VB6 range <= 4)
      assert effects == []
    end

    test "handle_information when player not in matching faction shows rejection" do
      # Player is in chaos but near royal enlistador
      entity = make_entity(%{faction: :chaos_legion})

      state = make_map_state(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{enl_inst: @enlistador_royal_npc}
      )

      {:ok, _state, effects} = NpcInteraction.handle_information(state, :player)

      assert effect_payload_contains?(effects, "No perteneces")
    end
  end

  # Helper that searches an effect list for a `{:send, _, %{payload: bin}}` entry
  # whose payload binary contains `needle`. The effects-tuple shape is the
  # `Arena.Map.Effects.send/2` constructor output post-migration.
  defp effect_payload_contains?(effects, needle) do
    Enum.any?(effects, fn
      {:send, _char_id, %{payload: payload}} when is_binary(payload) ->
        :binary.match(payload, needle) != :nomatch

      _ ->
        false
    end)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift QUEST — eQuest must route to NPC quest interaction, not quest list
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift QUEST: eQuest routes to NPC quest interaction, not quest list" do
    test "handle_quest near quest NPC shows NPC's available quests (not player's active list)" do
      entity = make_entity(%{active_quests: [], completed_quests: MapSet.new()})

      state = make_map_state(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{quest_inst: @quest_npc}
      )

      {:noreply, new_state} = QuestHandlers.handle_quest(state, :player)

      # VB6: eQuest should show the NPC's available quests, not the player's active quest list.
      # After the fix, the player should have quest_npc_id set (indicating NPC interaction)
      # and receive an npc_quest_list_send packet (not quest_list_send).
      assert new_state.players[:player].quest_npc_id == 88810
    end

    test "handle_quest with no nearby quest NPC sends error message" do
      entity = make_entity(%{active_quests: [], completed_quests: MapSet.new()})

      state = make_map_state(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{}
      )

      {:noreply, _state} = QuestHandlers.handle_quest(state, :player)

      # Should get "no quest NPC nearby" message
      assert_receive {:send_raw, raw}
      msg = IO.iodata_to_binary(raw)
      assert msg =~ "NPC"
    end

    test "handle_quest with quest NPC too far (> 5) sends error" do
      entity = make_entity(%{active_quests: [], completed_quests: MapSet.new()})

      state = make_map_state(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{quest_inst: @quest_npc_far}
      )

      {:noreply, new_state} = QuestHandlers.handle_quest(state, :player)

      # NPC at distance 6 should be too far
      assert new_state.players[:player].quest_npc_id == nil
    end
  end
end
