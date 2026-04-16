defmodule Arena.GmAuditLogTest do
  @moduledoc "Tests that all state-modifying GM commands produce audit log entries."
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Arena.Test.MapStateFactory

  alias Arena.Data.GameData
  alias Arena.Map.Gm.{Moderation, Teleport, CharEdit, Events, World}

  setup do
    Arena.Events.TournamentServer.cancel()

    for type <- [:xp_bonus, :gold_bonus, :drop_bonus, :custom] do
      Arena.Events.EventManager.stop_event(type)
    end

    on_exit(fn ->
      Arena.Events.TournamentServer.cancel()

      for type <- [:xp_bonus, :gold_bonus, :drop_bonus, :custom] do
        Arena.Events.EventManager.stop_event(type)
      end
    end)

    :ok
  end

  # Entity helper — COPY this exact entity map from the test files
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
      gm: true,
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

  defp make_map_state(players, opts \\ []) do
    sessions = Keyword.get(opts, :sessions, %{})
    map_state(
      players: players,
      sessions: sessions,
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, snow: false, sin_invi_ocul: false}
    )
  end

  defp find_valid_npc_id do
    Enum.find_value(1..10_000, fn npc_id ->
      case GameData.get_npc(npc_id) do
        nil -> nil
        _npc -> npc_id
      end
    end) || flunk("expected at least one NPC definition in GameData")
  end

  # ── Moderation ──

  describe "Moderation audit logging" do
    test "gm_kick logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "BadPlayer", gm: false, char_index: 2})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Moderation.gm_kick(state, 1, "BadPlayer")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "kick"
      assert log =~ "BadPlayer"
    end

    test "gm_mute logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "Spammer", gm: false, char_index: 2})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Moderation.gm_mute(state, 1, "Spammer", "10")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "mute"
    end

    test "gm_unmute logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "Unmuted", gm: false, char_index: 2, muted_until: 999_999_999_999})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Moderation.gm_unmute(state, 1, "Unmuted")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "unmute"
    end

    test "gm_jail logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "Jailed", gm: false, char_index: 2})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Moderation.gm_jail(state, 1, "Jailed", 30)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "jail"
    end

    test "gm_kill logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "Victim", gm: false, char_index: 2})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Moderation.gm_kill(state, 1, "Victim")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "kill"
    end

    test "gm_kick does NOT log when target not found" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        Moderation.gm_kick(state, 1, "NonexistentPlayer")
      end)

      refute log =~ "[AUDIT] gm_action"
    end

    test "gm_council_kick logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "CouncilMember", gm: false, char_index: 2, council: :royal})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Moderation.gm_council_kick(state, 1, "CouncilMember")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "council_kick"
    end

    test "gm_faction_kick logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "Soldier", gm: false, char_index: 2, faction: :royal_army})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Moderation.gm_faction_kick(state, 1, "Soldier", :royal_army)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "faction_kick"
    end
  end

  # ── Teleport ──

  describe "Teleport audit logging" do
    test "gm_teleport logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        Teleport.gm_teleport(state, 1, gm, "5", "10", "20")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "teleport"
    end

    test "gm_goto logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "TargetPlayer", gm: false, char_index: 2})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Teleport.gm_goto(state, 1, gm, "TargetPlayer")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "goto"
    end
  end

  # ── CharEdit ──

  describe "CharEdit audit logging" do
    test "gm_alter_name logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "OldName", gm: false, char_index: 2})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        CharEdit.gm_alter_name(state, 1, "OldName", "NewName")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "alter_name"
      assert log =~ "OldName"
      assert log =~ "NewName"
    end

    test "gm_revive logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "DeadPlayer", gm: false, char_index: 2, dead: true, hp: 0})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        CharEdit.gm_revive(state, 1, "DeadPlayer")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "revive"
    end

    test "gm_edit_char gold logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "Rich", gm: false, char_index: 2})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        CharEdit.gm_edit_char(state, 1, "Rich", "1", "999999")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "edit_char"
    end

    test "gm_show_name logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        CharEdit.gm_show_name(state, 1, gm)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "show_name"
    end

    test "gm_set_speed logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        CharEdit.gm_set_speed(state, 1, gm, "2.0")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "set_speed"
    end
  end

  # ── World ──

  describe "World audit logging" do
    test "gm_toggle_weather logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        World.gm_toggle_weather(state, 1, :snow)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "toggle_weather"
    end

    test "gm_tile_block_toggle logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        World.gm_tile_block_toggle(state, 1, gm)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "tile_block"
    end

    test "gm_set_trigger logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        World.gm_set_trigger(state, 1, gm, "5")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "set_trigger"
    end

    test "gm_clean_world logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        World.gm_clean_world(state, 1)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "clean_world"
    end

    test "gm_invisible logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        World.gm_invisible(state, 1, gm)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "invisible"
    end

    test "gm_destroy_items logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        World.gm_destroy_items(state, 1, gm)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "destroy_items"
    end

    test "gm_destroy_all_area logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        World.gm_destroy_all_area(state, 1, gm)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "destroy_all_area"
    end

    test "gm_change_map_flag logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        World.gm_change_map_flag(state, 1, :pk_enabled, "1")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "change_map_flag"
    end
  end

  # ── Events ──

  describe "Events audit logging" do
    test "gm_tournament_start logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        Events.gm_tournament_start(state, 1, gm, "8")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "tournament_start"
    end

    test "gm_tournament_cancel logs audit entry when a tournament exists" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})
      :ok = Arena.Events.TournamentServer.start_tournament(8, gm.name)

      log = capture_log(fn ->
        Events.gm_tournament_cancel(state, 1)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "tournament_cancel"
    end

    test "gm_event_start logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})

      log = capture_log(fn ->
        Events.gm_event_start(state, 1, gm, "xp_bonus", "5")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "event_start"
    end

    test "gm_event_stop logs audit entry when an event exists" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      state = make_map_state(%{1 => gm})
      :ok = Arena.Events.EventManager.start_event(:xp_bonus, 5, gm.name)

      log = capture_log(fn ->
        Events.gm_event_stop(state, 1, "xp_bonus")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "event_stop"
    end

    test "gm_faction_message logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      soldier = make_entity(%{name: "Soldier", gm: false, char_index: 2, faction: :royal_army})
      state = make_map_state(%{1 => gm, 2 => soldier}, sessions: %{1 => self(), 2 => self()})

      log = capture_log(fn ->
        Events.gm_faction_message(state, 1, :royal_army, "Form up")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "faction_message"
    end

    test "gm_talk_as_npc logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      npc_id = find_valid_npc_id()

      npc = %{
        npc_id: npc_id,
        char_index: 9,
        x: gm.x + 1,
        y: gm.y,
        alive: true
      }

      state =
        make_map_state(%{1 => gm}, sessions: %{1 => self()})
        |> Map.put(:npcs_live, %{77 => npc})

      log = capture_log(fn ->
        Events.gm_talk_as_npc(state, 1, gm, "Escuchen")
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "talk_as_npc"
    end

    test "gm_accept_council logs audit entry" do
      gm = make_entity(%{name: "GM_Admin", gm: true})
      target = make_entity(%{name: "CouncilHopeful", gm: false, char_index: 2})
      state = make_map_state(%{1 => gm, 2 => target})

      log = capture_log(fn ->
        Events.gm_accept_council(state, 1, "CouncilHopeful", :royal)
      end)

      assert log =~ "[AUDIT] gm_action"
      assert log =~ "accept_council"
    end
  end
end
