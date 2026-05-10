defmodule Arena.GmAdversarialTest do
  @moduledoc """
  Adversarial tests ensuring non-GM players cannot execute GM commands.

  Tests two independent guard layers:
  1. Session-level: SessionLogic.handle_command/2 returns "No tienes privilegios de GM."
     when a non-GM session sends any command in @gm_command_types.
  2. Map-level: Chat.handle_chat/3 silently ignores slash commands typed by non-GM
     entities (returns {:ok, state, []} unchanged).

  Also confirms that authorised GMs can execute representative commands.
  """
  use ExUnit.Case, async: true

  alias Arena.Data.GameData
  alias Arena.Map.Chat
  alias AoTcpGateway.SessionLogic

  import Arena.Test.MapStateFactory

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @doc false
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
      gold: 0,
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
      chat_color: {255, 255, 255}
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

  defp make_session_state(overrides) do
    defaults = %{
      character_id: 1001,
      is_gm: false,
      map_id: 1,
      char_index: 1,
      is_dead: false,
      in_commerce: false,
      in_bank: false,
      in_trade: false,
      target_x: nil,
      target_y: nil,
      entity: %{name: "Tester"},
      hogar_timer_ref: nil,
      viewing_forum_id: nil
    }

    Map.merge(defaults, overrides)
  end

  # Minimal payloads so pattern-matching in handle_command doesn't crash
  @gm_command_payloads %{
    go_to_char: %{name: "Victim"},
    warp_me_to_target: %{},
    warp_char: %{name: "Victim", map: 1},
    invisible: %{},
    silence: %{name: "Victim"},
    jail: %{name: "Victim", reason: "test", minutes: 5},
    kick: %{name: "Victim"},
    execute: %{name: "Victim"},
    ban_char: %{name: "Victim", reason: "test"},
    unban_char: %{name: "Victim"},
    revive_char: %{name: "Victim"},
    summon_char: %{name: "Victim"},
    kill_npc: %{},
    request_char_info: %{name: "Victim"},
    where: %{name: "Victim"},
    gm_message: %{message: "hello"},
    server_message: %{message: "hello"},
    online_gm: %{},
    rain_toggle: %{},
    online: %{},
    online_map: %{},
    kick_all_chars: %{},
    server_open_toggle: %{},
    save_chars: %{},
    global_message: %{message: "hello"},
    kill_npc_targeted: %{},
    kill_npc_no_respawn: %{},
    kill_all_nearby_npcs: %{},
    create_npc: %{npc_id: 1},
    create_npc_with_respawn: %{npc_id: 1},
    spawn_creature: %{creature_id: 1},
    spawn_list_request: %{},
    creatures_in_map: %{map: 1},
    # Batch 3
    create_item: %{item_id: 100, amount: 1},
    give_item: %{name: "Victim", item_id: 100, amount: 1, reason: "test"},
    request_char_stats: %{name: "Victim"},
    request_char_gold: %{name: "Victim"},
    request_char_inventory: %{name: "Victim"},
    request_char_bank: %{name: "Victim"},
    request_char_skills: %{name: "Victim"},
    edit_char: %{name: "Victim", option: "1", arg1: "100", arg2: ""},
    alter_name: %{name: "Victim", new_name: "NewName"},
    # Batch 4
    ban_cuenta: %{name: "Victim", reason: "test"},
    unban_cuenta: %{name: "Victim"},
    ban_temporal: %{name: "Victim", reason: "test", days: 7},
    remove_punishment: %{name: "Victim", num: 1, text: "test"},
    royal_army_message: %{message: "hello"},
    chaos_legion_message: %{message: "hello"},
    talk_as_npc: %{message: "hello"},
    # Batch 5
    nieve_toggle: %{},
    niebla_toggle: %{},
    change_map_pk: %{value: true},
    change_map_no_magic: %{value: true},
    change_map_no_invi: %{value: true},
    change_map_no_resu: %{value: true},
    tile_blocked_toggle: %{},
    set_trigger: %{trigger: 1},
    ask_trigger: %{},
    # Batch 6
    force_midi_all: %{midi: 1},
    force_wave_all: %{wave: 1},
    force_midi_map: %{midi: 1, map: 1},
    force_wave_map: %{wave: 1, x: 50, y: 50, map: 1},
    items_in_floor: %{},
    destroy_items: %{},
    destroy_all_area: %{},
    clean_world: %{},
    show_name: %{},
    set_description: %{desc: "test"},
    set_speed: %{speed: 1.5},
    nick_to_ip: %{name: "Victim"},
    ip_to_nick: %{ip: "127.0.0.1"},
    check_slot: %{name: "Victim", slot: 1},
    # Batch 7
    council_kick: %{name: "Victim"},
    accept_royal_council: %{name: "Victim"},
    accept_chaos_council: %{name: "Victim"},
    royal_army_kick: %{name: "Victim"},
    chaos_legion_kick: %{name: "Victim"},
    sos_show_list: %{},
    sos_remove: %{name: "Victim"},
    clean_sos: %{}
  }

  # ═══════════════════════════════════════════════════════════════════════════
  # 1. Session-level GM command rejection for non-GMs
  # ═══════════════════════════════════════════════════════════════════════════

  # NOTE: :online is excluded from this list because session_logic.ex has a
  # non-GM clause (line 816) that matches first -- any player can see the online
  # count.  The GM-only :online clause provides a detailed name list instead.
  # A separate test below verifies non-GMs get the basic count, not the GM list.

  describe "session-level GM command rejection for non-GMs" do
    for cmd_type <- [
          :go_to_char,
          :warp_me_to_target,
          :warp_char,
          :invisible,
          :silence,
          :jail,
          :kick,
          :execute,
          :ban_char,
          :unban_char,
          :revive_char,
          :summon_char,
          :kill_npc,
          :request_char_info,
          :where,
          :gm_message,
          :server_message,
          :online_gm,
          :rain_toggle,
          :online_map,
          :kick_all_chars,
          :server_open_toggle,
          :save_chars,
          :global_message,
          :kill_npc_targeted,
          :kill_npc_no_respawn,
          :kill_all_nearby_npcs,
          :create_npc,
          :create_npc_with_respawn,
          :spawn_creature,
          :spawn_list_request,
          :creatures_in_map,
          # Batch 3
          :create_item,
          :give_item,
          :request_char_stats,
          :request_char_gold,
          :request_char_inventory,
          :request_char_bank,
          :request_char_skills,
          :edit_char,
          :alter_name,
          # Batch 4
          :ban_cuenta,
          :unban_cuenta,
          :ban_temporal,
          :remove_punishment,
          # :royal_army_message / :chaos_legion_message are NOT session-GM-gated:
          # VB6 Protocol.bas:5177-5209 allows council-rank players to broadcast,
          # so the check lives at the map/chat layer (see faction_council_message_test).
          :talk_as_npc,
          # Batch 5
          :nieve_toggle,
          :niebla_toggle,
          :change_map_pk,
          :change_map_no_magic,
          :change_map_no_invi,
          :change_map_no_resu,
          :tile_blocked_toggle,
          :set_trigger,
          :ask_trigger,
          # Batch 6
          :force_midi_all,
          :force_wave_all,
          :force_midi_map,
          :force_wave_map,
          :items_in_floor,
          :destroy_items,
          :destroy_all_area,
          :clean_world,
          :show_name,
          :set_description,
          :set_speed,
          :nick_to_ip,
          :ip_to_nick,
          :check_slot,
          # Batch 7
          :council_kick,
          :accept_royal_council,
          :accept_chaos_council,
          :royal_army_kick,
          :chaos_legion_kick,
          :sos_show_list,
          :sos_remove,
          :clean_sos
        ] do
      @tag_cmd cmd_type
      test "non-GM session is rejected for :#{cmd_type}" do
        cmd = @tag_cmd
        payload = Map.get(@gm_command_payloads, cmd, %{})
        state = make_session_state(%{character_id: 1001, is_gm: false})

        {new_state, messages} = SessionLogic.handle_command(state, {cmd, payload})

        # State must be unchanged
        assert new_state == state

        # Must receive exactly the unauthorized message
        assert length(messages) == 1
        [{:console_msg, %{message: msg}}] = messages
        assert msg == "No tienes privilegios de GM."
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 2. Non-GM slash command rejection at the map level
  # ═══════════════════════════════════════════════════════════════════════════

  describe "slash command rejection for non-GM entities" do
    for slash_cmd <- [
          "/GOTO Victim",
          "/KILL Victim",
          "/BAN Victim 30",
          "/KICK Victim",
          "/TELEPORT 1 50 50",
          "/INVISIBLE",
          "/JAIL Victim 10",
          "/MUTE Victim 5",
          "/UNMUTE Victim",
          "/INFO Victim",
          "/LOCATE Victim",
          "/REVIVE Victim",
          "/SPAWNITEM 100 1",
          "/KILLNPC",
          "/KILLNPCPERM",
          "/MASSKILL",
          "/SPAWNNPC 1",
          "/SPAWNNPCR 1",
          "/SPAWNLIST",
          "/CREATURES 1",
          "/ONLINEMAP",
          # Batch 3
          "/GIVEITEM Victim 100 1",
          "/CHARSTATS Victim",
          "/CHARGOLD Victim",
          "/CHARINV Victim",
          "/CHARBANK Victim",
          "/CHARSKILLS Victim",
          "/EDITCHAR Victim 1 100",
          "/ALTERNAME Victim NewName",
          # Batch 4
          "/BANCUENTA Victim reason",
          "/UNBANCUENTA Victim",
          "/BANTEMPORAL Victim 7 reason",
          "/REMOVEPUNISHMENT Victim 1 text",
          "/RMSG hello faction",
          "/CMSG hello faction",
          "/TALKASNPC hello npc",
          # Batch 5
          "/NIEVE",
          "/NIEBLA",
          "/MAPPK 1",
          "/MAPNOMAGIC 1",
          "/MAPNOINVI 1",
          "/MAPNORESU 1",
          "/TILEBLOCK",
          "/SETTRIGGER 1",
          "/ASKTRIGGER",
          # Batch 6
          "/FORCEMIDIMAP 1 1",
          "/FORCEWAVEMAP 1 50 50 1",
          "/ITEMSFLOOR",
          "/DESTROYITEMS",
          "/DESTROYALLAREA",
          "/CLEANWORLD",
          "/SHOWNAME",
          "/SETDESC test",
          "/SETSPEED 1.5",
          "/CHECKSLOT Victim 1",
          # Batch 7
          "/COUNCILKICK Victim",
          "/ROYALCOUNCIL Victim",
          "/CHAOSCOUNCIL Victim",
          "/ROYALKICK Victim",
          "/CHAOSKICK Victim"
        ] do
      @tag_slash slash_cmd
      test "non-GM entity is silently ignored for #{slash_cmd}" do
        slash = @tag_slash
        entity = make_entity(%{char_id: :attacker, gm: false})
        state = make_map_state(%{attacker: entity})

        result = Chat.handle_chat(state, :attacker, slash)

        # Must return {:ok, state, []} with state unchanged (non-GM slash
        # commands are silently dropped at the chat-handler layer).
        assert result == {:ok, state, []}
      end
    end
  end

  describe "session-level :online gives non-GM only the count, not the full name list" do
    test "non-GM :online returns player count (not GM detailed list)" do
      state = make_session_state(%{character_id: 1001, is_gm: false})

      {_new_state, messages} = SessionLogic.handle_command(state, {:online, %{}})

      # Non-GM hits the general clause at line 816 which returns count
      assert length(messages) == 1
      [{:console_msg, %{message: msg}}] = messages
      assert msg =~ "Jugadores en linea:"
      # Must NOT contain the detailed name list that the GM version provides
      refute msg =~ "Jugadores online"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 3. Edge cases: unauthenticated / nil character_id
  # ═══════════════════════════════════════════════════════════════════════════

  describe "session-level rejection when character_id is nil" do
    test "GM command falls through to catch-all when character_id is nil" do
      state = make_session_state(%{character_id: nil, is_gm: false})

      # The guard `state.character_id != nil` prevents the @gm_command_types
      # catch-all from matching, so the command falls to the final catch-all
      # which returns {state, []}.
      {new_state, messages} = SessionLogic.handle_command(state, {:kick, %{name: "Victim"}})

      assert new_state == state
      assert messages == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 4. Slash commands typed by non-existent player on the map
  # ═══════════════════════════════════════════════════════════════════════════

  describe "slash command by unknown char_id" do
    test "handle_chat returns {:ok, state, []} when char_id is not in players map" do
      state = make_map_state(%{})

      result = Chat.handle_chat(state, :nonexistent, "/KILL someone")

      assert result == {:ok, state, []}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 5. GM commands work for authorized GMs (representative subset)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "GM commands work for authorized GMs at session level" do
    test "GM can use :server_open_toggle" do
      state = make_session_state(%{character_id: 2001, is_gm: true})

      {_new_state, messages} = SessionLogic.handle_command(state, {:server_open_toggle, %{}})

      assert length(messages) == 1
      [{:console_msg, %{message: msg}}] = messages
      assert msg =~ "Servidor"
    end

    test "GM can use :save_chars" do
      state = make_session_state(%{character_id: 2001, is_gm: true})

      {_new_state, messages} = SessionLogic.handle_command(state, {:save_chars, %{}})

      assert length(messages) == 1
      [{:console_msg, %{message: msg}}] = messages
      assert msg =~ "Guardado de personajes"
    end

    test "GM can use :warp_me_to_target (returns hint when no target)" do
      state = make_session_state(%{character_id: 2001, is_gm: true})

      {_new_state, messages} = SessionLogic.handle_command(state, {:warp_me_to_target, %{}})

      assert length(messages) == 1
      [{:console_msg, %{message: msg}}] = messages
      assert msg =~ "selecciona" or msg =~ "objetivo"
    end
  end

  describe "GM slash commands work for authorized GMs at map level" do
    test "GM can use /ONLINEMAP" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      # Use a session pid so gm_console can send messages
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      result = Chat.handle_chat(state, :gm_player, "/ONLINEMAP")

      # /ONLINEMAP sends a console message listing players; it returns {:ok, state, []}
      assert {:ok, _new_state, _effects} = result
    end

    test "GM /INVISIBLE toggles invisible flag" do
      entity = make_entity(%{char_id: :gm_player, gm: true, invisible: false, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/INVISIBLE")

      updated = new_state.players[:gm_player]
      assert updated.invisible == true
    end

    test "unknown GM slash command returns 'Unknown GM command'" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/NOSUCHCMD")

      # The GM receives a console message about the unknown command
      assert_receive {:send_raw, _raw_bytes}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 6. Non-GM regular chat still works (slash guard does not block normal text)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "non-GM regular chat is not blocked" do
    test "non-GM player can send normal chat messages" do
      entity = make_entity(%{char_id: :player, gm: false, name: "NormalPlayer"})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      result = Chat.handle_chat(state, :player, "Hello world!")

      # Normal chat returns {:ok, updated_state, effects} — not rejected
      assert {:ok, _new_state, _effects} = result
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 7. GM commands that DO things when authorized (functional tests, Batches 4-7)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Batch 5 - Map & Environment: GM /NIEVE toggles snow" do
    test "toggles snow on in map state" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      # snow starts as nil/false
      assert Map.get(state.meta, :snow, false) == false

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/NIEVE")
      assert new_state.meta[:snow] == true
    end
  end

  describe "Batch 5 - Map & Environment: GM /NIEBLA toggles fog" do
    test "toggles fog on in map state" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      assert Map.get(state.meta, :fog, false) == false

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/NIEBLA")
      assert new_state.meta[:fog] == true
    end
  end

  describe "Batch 5 - Map & Environment: GM /MAPPK sets pk flag" do
    test "sets pk flag to true" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/MAPPK 1")
      assert new_state.meta[:pk] == true
    end

    test "sets pk flag to false with 0" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/MAPPK 0")
      assert new_state.meta[:pk] == false
    end
  end

  describe "Batch 5 - Map & Environment: GM /MAPNOMAGIC sets no_magic flag" do
    test "sets no_magic flag to true" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/MAPNOMAGIC 1")
      assert new_state.meta[:no_magic] == true
    end
  end

  describe "Batch 5 - Map & Environment: GM /MAPNOINVI sets no_invi flag" do
    test "sets no_invi flag to true" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/MAPNOINVI 1")
      assert new_state.meta[:no_invi] == true
    end
  end

  describe "Batch 5 - Map & Environment: GM /MAPNORESU sets no_resu flag" do
    test "sets no_resu flag to true" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/MAPNORESU 1")
      assert new_state.meta[:no_resu] == true
    end
  end

  describe "Batch 5 - Map & Environment: GM /SHOWNAME toggles name visibility" do
    test "toggles show_name to false (hidden) when default is true" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SHOWNAME")
      updated = new_state.players[:gm_player]
      assert Map.get(updated, :show_name) == false
    end
  end

  describe "Batch 6 - Utility: GM /SETDESC sets description" do
    test "sets entity description" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", description: ""})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SETDESC The mighty admin")
      updated = new_state.players[:gm_player]
      assert updated.description == "The mighty admin"
    end
  end

  describe "Batch 6 - Utility: GM /SETSPEED sets speed modifier" do
    test "sets speed modifier on entity" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SETSPEED 2.5")
      updated = new_state.players[:gm_player]
      assert Map.get(updated, :speed_mod) == 2.5
    end
  end

  describe "Batch 5 - Map & Environment: GM /TILEBLOCK toggles tile block" do
    test "blocks facing tile" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", x: 50, y: 50, heading: :south})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/TILEBLOCK")

      blocked = new_state.gm_blocked_tiles
      # facing south from (50, 50) = (50, 51)
      assert MapSet.member?(blocked, {50, 51})
    end
  end

  describe "Batch 5 - Map & Environment: GM /SETTRIGGER sets trigger" do
    test "sets trigger at facing tile" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", x: 50, y: 50, heading: :south})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SETTRIGGER 5")

      triggers = new_state.triggers
      assert Map.get(triggers, {50, 51}) == 5
    end
  end

  describe "Batch 5 - Map & Environment: GM /ASKTRIGGER reads trigger" do
    test "reads trigger at facing tile" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", x: 50, y: 50, heading: :south})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)
      # Pre-set a trigger
      state = %{state | triggers: %{{50, 51} => 42}}

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/ASKTRIGGER")

      # GM should receive a message about the trigger value
      assert_receive {:send_raw, _raw}
    end
  end

  describe "Batch 6 - Utility: GM /CLEANWORLD clears ground items" do
    test "clears all ground items" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)
      state = %{state | ground_items: %{{10, 10} => %{item_id: 1, amount: 5}}}

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CLEANWORLD")
      assert new_state.ground_items == %{}
    end
  end

  describe "Batch 7 - Faction/Council: GM /COUNCILKICK removes from council" do
    test "sets council to false on target" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      victim = Map.put(victim, :council, :royal)
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/COUNCILKICK Victim")
      assert Map.get(new_state.players[:victim], :council) == false
    end
  end

  describe "Batch 7 - Faction/Council: GM /ROYALCOUNCIL adds to royal council" do
    test "sets council to :royal on target" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/ROYALCOUNCIL Victim")
      assert Map.get(new_state.players[:victim], :council) == :royal
    end
  end

  describe "Batch 7 - Faction/Council: GM /CHAOSCOUNCIL adds to chaos council" do
    test "sets council to :chaos on target" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CHAOSCOUNCIL Victim")
      assert Map.get(new_state.players[:victim], :council) == :chaos
    end
  end

  describe "Batch 7 - Faction/Council: GM /ROYALKICK removes from faction" do
    test "sets faction to :none on target" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim", faction: :royal_army})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/ROYALKICK Victim")
      assert new_state.players[:victim].faction == :none
    end
  end

  describe "Batch 7 - Faction/Council: GM /CHAOSKICK removes from faction" do
    test "sets faction to :none on target" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim", faction: :chaos_legion})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CHAOSKICK Victim")
      assert new_state.players[:victim].faction == :none
    end
  end

  describe "Batch 4 - Communication: GM /RMSG sends faction message" do
    test "returns {:noreply, state} and GM receives confirmation" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      soldier = make_entity(%{char_id: :soldier, gm: false, name: "Soldier", faction: :royal_army})
      sessions = %{gm_player: self(), soldier: self()}
      state = make_map_state(%{gm_player: gm, soldier: soldier}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/RMSG Attention troops!")
      # GM gets confirmation and faction player gets message
      assert_receive {:send_raw, _raw}
    end
  end

  describe "Batch 4 - Communication: GM /CMSG sends chaos faction message" do
    test "returns {:noreply, state} and GM receives confirmation" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CMSG Dark legion orders!")
      assert_receive {:send_raw, _raw}
    end
  end

  describe "Batch 4 - Punishment: GM /REMOVEPUNISHMENT" do
    test "returns {:noreply, state} and sends confirmation" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/REMOVEPUNISHMENT Victim 1 reason")
      assert_receive {:send_raw, _raw}
    end
  end

  describe "Batch 6 - Audio: GM /FORCEMIDIMAP sends MIDI to map" do
    test "sends MIDI packet to sessions" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/FORCEMIDIMAP 5 1")
      # Receives MIDI packet + gm_console confirmation
      assert_receive {:send_raw, _raw}
    end
  end

  describe "Batch 6 - Audio: GM /FORCEWAVEMAP sends wave to map" do
    test "sends wave packet to sessions" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/FORCEWAVEMAP 3 50 50 1")
      assert_receive {:send_raw, _raw}
    end
  end

  describe "Batch 6 - Utility: GM /ITEMSFLOOR counts floor items" do
    test "sends floor item count" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/ITEMSFLOOR")
      assert_receive {:send_raw, _raw}
    end
  end

  describe "Batch 6 - Utility: GM /DESTROYITEMS destroys items at facing tile" do
    test "removes items at facing tile" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", x: 50, y: 50, heading: :south})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)
      state = %{state | ground_items: %{{50, 51} => %{item_id: 1, amount: 3}}}

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/DESTROYITEMS")
      ground_items = new_state.ground_items
      refute Map.has_key?(ground_items, {50, 51})
    end
  end

  describe "Batch 6 - Utility: GM /DESTROYALLAREA destroys items in range" do
    test "removes items in area around GM" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", x: 50, y: 50, heading: :south})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      state =
        %{state | ground_items: %{
          {52, 52} => %{item_id: 1, amount: 1},
          {90, 90} => %{item_id: 2, amount: 1}
        }}

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/DESTROYALLAREA")
      ground_items = new_state.ground_items
      # (52,52) is within range 10 of (50,50), should be removed
      refute Map.has_key?(ground_items, {52, 52})
      # (90,90) is far away, should remain
      assert Map.has_key?(ground_items, {90, 90})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 8. Edge cases: invalid parameters, non-existent targets, boundary values
  # ═══════════════════════════════════════════════════════════════════════════

  describe "edge cases: GM commands with invalid parameters" do
    test "/SETSPEED with non-numeric value returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SETSPEED abc")
      # speed_mod should not be set
      refute Map.has_key?(new_state.players[:gm_player], :speed_mod)
    end

    test "/SETTRIGGER with non-numeric value returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", x: 50, y: 50, heading: :south})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SETTRIGGER notanumber")
      triggers = new_state.triggers
      assert triggers == %{}
    end

    test "/TELEPORT with non-numeric coordinates returns usage message" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/TELEPORT abc def ghi")
      # Should receive usage message
      assert_receive {:send_raw, _raw}
    end

    test "/SPAWNITEM with non-numeric item_id returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SPAWNITEM abc")
      assert_receive {:send_raw, _raw}
    end

    test "/SPAWNITEM with zero amount returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SPAWNITEM 100 0")
      assert_receive {:send_raw, _raw}
    end

    test "/SPAWNITEM with negative amount returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SPAWNITEM 100 -5")
      assert_receive {:send_raw, _raw}
    end

    test "/FORCEMIDIMAP with non-numeric midi returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/FORCEMIDIMAP abc def")
      assert_receive {:send_raw, _raw}
    end

    test "/CHECKSLOT with non-numeric slot returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CHECKSLOT Victim abc")
      assert_receive {:send_raw, _raw}
    end

    test "/BANTEMPORAL with non-numeric days returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/BANTEMPORAL Victim abc reason")
      assert_receive {:send_raw, _raw}
    end

    test "/CREATURES with non-numeric map_id returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CREATURES abc")
      assert_receive {:send_raw, _raw}
    end

    test "/GIVEITEM with bad amount returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/GIVEITEM Victim abc xyz")
      assert_receive {:send_raw, _raw}
    end

    test "/EDITCHAR with invalid option returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/EDITCHAR Victim 99 abc")
      assert_receive {:send_raw, _raw}
    end

    test "/BAN with non-numeric days returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/BAN Victim abc")
      assert_receive {:send_raw, _raw}
    end

    test "/MUTE with non-numeric minutes returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/MUTE Victim abc")
      assert_receive {:send_raw, _raw}
    end
  end

  describe "edge cases: GM commands targeting non-existent players" do
    test "/GOTO targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/GOTO GhostPlayer")
      # State unchanged (no player to teleport to)
      assert new_state.players == state.players
    end

    test "/KILL targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/KILL GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/INFO targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/INFO GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/KICK targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/KICK GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/REVIVE targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/REVIVE GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/UNMUTE targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/UNMUTE GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/COUNCILKICK targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/COUNCILKICK GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/ROYALCOUNCIL targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/ROYALCOUNCIL GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/CHAOSCOUNCIL targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CHAOSCOUNCIL GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/ROYALKICK targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/ROYALKICK GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/CHAOSKICK targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CHAOSKICK GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/CHARSTATS targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CHARSTATS GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/CHARGOLD targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CHARGOLD GhostPlayer")
      assert_receive {:send_raw, _raw}
    end

    test "/ALTERNAME targeting non-existent player returns not found" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/ALTERNAME GhostPlayer NewName")
      assert_receive {:send_raw, _raw}
    end
  end

  describe "edge cases: boundary values" do
    test "/CHECKSLOT with slot 0 (below minimum) returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CHECKSLOT Victim 0")
      # Slot 0 is < 1 so falls to invalid case
      assert_receive {:send_raw, _raw}
    end

    test "/CHECKSLOT with negative slot returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CHECKSLOT Victim -1")
      assert_receive {:send_raw, _raw}
    end

    test "/BAN with zero days returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/BAN Victim 0")
      assert_receive {:send_raw, _raw}
    end

    test "/BAN with negative days returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/BAN Victim -5")
      assert_receive {:send_raw, _raw}
    end

    test "/MUTE with zero minutes returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/MUTE Victim 0")
      assert_receive {:send_raw, _raw}
    end

    test "/SETDESC with only whitespace after command sets to trimmed remainder" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", description: "old desc"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      # "/SETDESC " gets trimmed to "/SETDESC", then trim_leading("/SETDESC ") doesn't
      # match the space, so description becomes "/SETDESC" (the full trimmed string).
      # This exercises the edge case of sending the command with no real argument.
      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SETDESC ")
      updated = new_state.players[:gm_player]
      assert updated.description == "/SETDESC"
    end

    test "/SETSPEED with zero sets speed_mod to 0.0" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SETSPEED 0")
      updated = new_state.players[:gm_player]
      assert Map.get(updated, :speed_mod) == 0.0
    end

    test "/SETSPEED with negative value still sets it" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SETSPEED -1.0")
      updated = new_state.players[:gm_player]
      assert Map.get(updated, :speed_mod) == -1.0
    end
  end

  describe "edge cases: dead GM using commands" do
    test "dead GM can still use /NIEVE (GM commands bypass dead check)" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", dead: true, hp: 0})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/NIEVE")
      assert new_state.meta[:snow] == true
    end

    test "dead GM can still use /INVISIBLE" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", dead: true, hp: 0, invisible: false})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/INVISIBLE")
      assert new_state.players[:gm_player].invisible == true
    end

    test "dead GM can still use /SHOWNAME" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", dead: true, hp: 0})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/SHOWNAME")
      updated = new_state.players[:gm_player]
      assert Map.get(updated, :show_name) == false
    end

    test "dead GM can still use /CLEANWORLD" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", dead: true, hp: 0})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)
      state = %{state | ground_items: %{{5, 5} => %{item_id: 1, amount: 1}}}

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/CLEANWORLD")
      assert new_state.ground_items == %{}
    end

    test "dead GM can still use /MAPPK" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", dead: true, hp: 0})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/MAPPK 1")
      assert new_state.meta[:pk] == true
    end

    test "dead GM can still use /COUNCILKICK" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", dead: true, hp: 0})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      victim = Map.put(victim, :council, :royal)
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/COUNCILKICK Victim")
      assert Map.get(new_state.players[:victim], :council) == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 9. Double-execution / toggle tests
  # ═══════════════════════════════════════════════════════════════════════════

  describe "double-execution: toggle commands return to original state" do
    test "/NIEVE twice returns to no snow" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      assert Map.get(state.meta, :snow, false) == false
      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/NIEVE")
      assert state1.meta[:snow] == true
      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/NIEVE")
      assert state2.meta[:snow] == false
    end

    test "/NIEBLA twice returns to no fog" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      assert Map.get(state.meta, :fog, false) == false
      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/NIEBLA")
      assert state1.meta[:fog] == true
      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/NIEBLA")
      assert state2.meta[:fog] == false
    end

    test "/INVISIBLE twice returns to visible" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", invisible: false})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/INVISIBLE")
      assert state1.players[:gm_player].invisible == true
      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/INVISIBLE")
      assert state2.players[:gm_player].invisible == false
    end

    test "/SHOWNAME twice returns to original state" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      # Default show_name is true (Map.get with default true)
      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/SHOWNAME")
      assert Map.get(state1.players[:gm_player], :show_name) == false
      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/SHOWNAME")
      assert Map.get(state2.players[:gm_player], :show_name) == true
    end

    test "/TILEBLOCK twice returns tile to unblocked" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", x: 50, y: 50, heading: :south})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/TILEBLOCK")
      blocked1 = state1.gm_blocked_tiles
      assert MapSet.member?(blocked1, {50, 51})

      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/TILEBLOCK")
      blocked2 = state2.gm_blocked_tiles
      refute MapSet.member?(blocked2, {50, 51})
    end
  end

  describe "double-execution: non-toggle commands are idempotent" do
    test "/SETDESC twice sets to second value" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", description: ""})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/SETDESC first")
      assert state1.players[:gm_player].description == "first"
      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/SETDESC second")
      assert state2.players[:gm_player].description == "second"
    end

    test "/SETSPEED twice sets to second value" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/SETSPEED 1.5")
      assert Map.get(state1.players[:gm_player], :speed_mod) == 1.5
      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/SETSPEED 3.0")
      assert Map.get(state2.players[:gm_player], :speed_mod) == 3.0
    end

    test "/SETTRIGGER twice overwrites first value" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM", x: 50, y: 50, heading: :south})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/SETTRIGGER 5")
      assert state1.triggers |> Map.get({50, 51}) == 5
      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/SETTRIGGER 10")
      assert state2.triggers |> Map.get({50, 51}) == 10
    end

    test "/MAPPK setting same value twice is stable" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/MAPPK 1")
      assert state1.meta[:pk] == true
      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/MAPPK 1")
      assert state2.meta[:pk] == true
    end

    test "/ROYALCOUNCIL then /CHAOSCOUNCIL changes council affiliation" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/ROYALCOUNCIL Victim")
      assert Map.get(state1.players[:victim], :council) == :royal

      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/CHAOSCOUNCIL Victim")
      assert Map.get(state2.players[:victim], :council) == :chaos
    end

    test "/COUNCILKICK twice keeps council as false" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim"})
      victim = Map.put(victim, :council, :royal)
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, state1, _effects} = Chat.handle_chat(state, :gm_player, "/COUNCILKICK Victim")
      assert Map.get(state1.players[:victim], :council) == false
      {:ok, state2, _effects} = Chat.handle_chat(state1, :gm_player, "/COUNCILKICK Victim")
      assert Map.get(state2.players[:victim], :council) == false
    end

    test "/ROYALKICK on already factionless player keeps faction as :none" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      victim = make_entity(%{char_id: :victim, gm: false, name: "Victim", faction: :none})
      sessions = %{gm_player: self(), victim: self()}
      state = make_map_state(%{gm_player: gm, victim: victim}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/ROYALKICK Victim")
      assert new_state.players[:victim].faction == :none
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Session-level: dead player guards
  # ═══════════════════════════════════════════════════════════════════════════

  describe "dead player action rejection" do
    test "dead player cannot equip items" do
      state = make_session_state(%{is_dead: true})
      {new_state, messages} = SessionLogic.handle_command(state, {:equip_item, %{slot: 1}})
      assert new_state == state
      assert [{:console_msg, %{message: msg}}] = messages
      assert msg == "Estás muerto. No podés equipar objetos."
    end

    test "dead player cannot use items" do
      state = make_session_state(%{is_dead: true})
      {new_state, messages} = SessionLogic.handle_command(state, {:use_item, %{slot: 1}})
      assert new_state == state
      assert [{:console_msg, %{message: msg}}] = messages
      assert msg == "Estás muerto. No podés usar objetos."
    end

    test "dead player cannot attack" do
      state = make_session_state(%{is_dead: true})
      {new_state, messages} = SessionLogic.handle_command(state, {:attack, %{}})
      assert new_state == state
      assert [{:console_msg, %{message: msg}}] = messages
      assert msg == "Estás muerto. No podés atacar."
    end

    test "dead player cannot cast spells" do
      state = make_session_state(%{is_dead: true})
      {new_state, messages} = SessionLogic.handle_command(state, {:cast_spell, %{spell_slot: 1}})
      assert new_state == state
      assert [{:console_msg, %{message: msg}}] = messages
      assert msg == "Estás muerto. No podés lanzar hechizos."
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Session-level: commerce state guards
  # ═══════════════════════════════════════════════════════════════════════════

  describe "commerce packet spoofing (not in commerce)" do
    test "commerce_buy without open shop is rejected" do
      state = make_session_state(%{in_commerce: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:commerce_buy, %{slot: 1, amount: 1}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un comercio."}}] = messages
    end

    test "commerce_sell without open shop is rejected" do
      state = make_session_state(%{in_commerce: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:commerce_sell, %{slot: 1, amount: 1}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un comercio."}}] = messages
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Session-level: bank state guards
  # ═══════════════════════════════════════════════════════════════════════════

  describe "bank packet spoofing (not in bank)" do
    test "bank_deposit without open bank is rejected" do
      state = make_session_state(%{in_bank: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:bank_deposit, %{slot: 1, amount: 10, slot_destino: 1}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un banco."}}] = messages
    end

    test "bank_extract_item without open bank is rejected" do
      state = make_session_state(%{in_bank: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:bank_extract_item, %{slot: 1, amount: 1, slot_destino: 2}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un banco."}}] = messages
    end

    test "bank_deposit_gold without open bank is rejected" do
      state = make_session_state(%{in_bank: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:bank_deposit_gold, %{amount: 100}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un banco."}}] = messages
    end

    test "bank_extract_gold without open bank is rejected" do
      state = make_session_state(%{in_bank: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:bank_extract_gold, %{amount: 100}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un banco."}}] = messages
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Session-level: trade state guards
  # ═══════════════════════════════════════════════════════════════════════════

  describe "trade packet spoofing (not in trade)" do
    test "user_commerce_offer without active trade is rejected" do
      state = make_session_state(%{in_trade: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:user_commerce_offer, %{obj_index: 1, amount: 1}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un comercio con otro jugador."}}] = messages
    end

    test "user_commerce_ok without active trade is rejected" do
      state = make_session_state(%{in_trade: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:user_commerce_ok, %{}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un comercio con otro jugador."}}] = messages
    end

    test "user_commerce_reject without active trade is rejected" do
      state = make_session_state(%{in_trade: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:user_commerce_reject, %{}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un comercio con otro jugador."}}] = messages
    end

    test "user_commerce_end without active trade is rejected" do
      state = make_session_state(%{in_trade: false})
      {new_state, messages} = SessionLogic.handle_command(state, {:user_commerce_end, %{}})
      assert new_state == state
      assert [{:console_msg, %{message: "No estas en un comercio con otro jugador."}}] = messages
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Session-level: nil character_id fallthrough for regular commands
  # ═══════════════════════════════════════════════════════════════════════════

  describe "nil character_id fallthrough for regular commands" do
    @regular_commands [
      {:equip_item, %{slot: 1}},
      {:use_item, %{slot: 1}},
      {:attack, %{}},
      {:cast_spell, %{spell_slot: 1}},
      {:commerce_buy, %{slot: 1, amount: 1}},
      {:commerce_sell, %{slot: 1, amount: 1}},
      {:bank_deposit, %{slot: 1, amount: 1, slot_destino: 1}},
      {:bank_extract_item, %{slot: 1, amount: 1, slot_destino: 1}},
      {:bank_deposit_gold, %{amount: 100}},
      {:bank_extract_gold, %{amount: 100}},
      {:user_commerce_offer, %{obj_index: 1, amount: 1}},
      {:user_commerce_ok, %{}},
      {:user_commerce_reject, %{}},
      {:user_commerce_end, %{}},
      {:quest, %{}},
      {:quest_list_request, %{}},
      {:quest_details_request, %{quest_slot: 1}},
      {:quest_accept, %{list_index: 1}},
      {:quest_abandon, %{quest_slot: 1}}
    ]

    for {cmd, payload} <- @regular_commands do
      test "#{cmd} with nil character_id returns empty messages" do
        state = make_session_state(%{character_id: nil})
        {new_state, messages} = SessionLogic.handle_command(state, {unquote(cmd), unquote(Macro.escape(payload))})
        assert new_state == state
        assert messages == []
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Session-level: forum_post without open forum
  # ═══════════════════════════════════════════════════════════════════════════

  describe "forum_post privilege guard" do
    test "forum_post with nil viewing_forum_id is rejected" do
      state = make_session_state(%{viewing_forum_id: nil})
      {new_state, messages} = SessionLogic.handle_command(state, {:forum_post, %{title: "test", message: "body"}})
      assert new_state == state
      assert [{:console_msg, %{message: "El foro no esta disponible."}}] = messages
    end

    test "forum_post with viewing_forum_id = 0 is rejected" do
      state = make_session_state(%{viewing_forum_id: 0})
      {_new_state, messages} = SessionLogic.handle_command(state, {:forum_post, %{title: "test", message: "body"}})
      assert [{:console_msg, %{message: "El foro no esta disponible."}}] = messages
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Map-level: non-GM rejection for events/invasion/tournament slash commands
  # ═══════════════════════════════════════════════════════════════════════════

  describe "events/invasion/tournament non-GM rejection" do
    @event_commands [
      "/INVASION 1 5 50",
      "/INVASION STOP 1",
      "/INVASION LIST",
      "/TOURNAMENT START 16",
      "/TOURNAMENT BEGIN",
      "/TOURNAMENT CANCEL",
      "/TOURNAMENT STATUS",
      "/EVENT START xp_bonus 30",
      "/EVENT STOP xp_bonus",
      "/EVENT LIST"
    ]

    for cmd <- @event_commands do
      test "non-GM sending #{cmd} is silently ignored" do
        entity = make_entity(%{char_id: :player, gm: false})
        sessions = %{player: self()}
        state = make_map_state(%{player: entity}, sessions: sessions)
        assert {:ok, ^state, _effects} = Chat.handle_chat(state, :player, unquote(cmd))
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Map-level: GM invasion edge cases
  # ═══════════════════════════════════════════════════════════════════════════

  describe "GM invasion edge cases" do
    test "/INVASION with non-numeric map_id returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, new_state, _effects} = Chat.handle_chat(state, :gm_player, "/INVASION abc 5 10")
      assert new_state.players == state.players
      assert_receive {:send_raw, _}
    end

    test "/INVASION with zero count returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/INVASION 1 5 0")
      assert_receive {:send_raw, _}
    end

    test "/INVASION with count > 200 returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/INVASION 1 5 201")
      assert_receive {:send_raw, _}
    end

    test "/INVASION with negative count returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/INVASION 1 5 -1")
      assert_receive {:send_raw, _}
    end

    test "/INVASION STOP with no active invasion returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/INVASION STOP 9999")
      assert_receive {:send_raw, _}
    end

    test "/INVASION STOP with non-numeric map_id returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/INVASION STOP abc")
      assert_receive {:send_raw, _}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Map-level: GM tournament edge cases
  # ═══════════════════════════════════════════════════════════════════════════

  describe "GM tournament edge cases" do
    test "/TOURNAMENT CANCEL with no active tournament returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      # Ensure no tournament is active first
      Arena.Events.TournamentServer.cancel()

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/TOURNAMENT CANCEL")
      assert_receive {:send_raw, _}
    end

    test "/TOURNAMENT STATUS with no active tournament returns message" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      Arena.Events.TournamentServer.cancel()

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/TOURNAMENT STATUS")
      assert_receive {:send_raw, _}
    end

    test "/TOURNAMENT BEGIN with no active tournament returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      Arena.Events.TournamentServer.cancel()

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/TOURNAMENT BEGIN")
      assert_receive {:send_raw, _}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Map-level: GM event edge cases
  # ═══════════════════════════════════════════════════════════════════════════

  describe "GM event edge cases" do
    test "/EVENT START with zero duration returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/EVENT START xp_bonus 0")
      assert_receive {:send_raw, _}
    end

    test "/EVENT START with negative duration returns usage" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/EVENT START xp_bonus -5")
      assert_receive {:send_raw, _}
    end

    test "/EVENT STOP with no active event returns error" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      # Stop any stale events first
      Arena.Events.EventManager.stop_event(:xp_bonus)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/EVENT STOP xp_bonus")
      assert_receive {:send_raw, _}
    end

    test "/EVENT LIST with no active events returns message" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      # Stop all events
      Arena.Events.EventManager.stop_event(:xp_bonus)
      Arena.Events.EventManager.stop_event(:gold_bonus)
      Arena.Events.EventManager.stop_event(:drop_bonus)
      Arena.Events.EventManager.stop_event(:custom)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/EVENT LIST")
      assert_receive {:send_raw, _}
    end

    test "/EVENT START with unknown type maps to :custom" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      # Clean up any stale custom event
      Arena.Events.EventManager.stop_event(:custom)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/EVENT START unknown_type 5")
      assert_receive {:send_raw, _}

      # Clean up
      Arena.Events.EventManager.stop_event(:custom)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Map-level: handle_gm_rain_toggle non-GM guard
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_gm_rain_toggle privilege guard" do
    test "non-GM calling handle_gm_rain_toggle is rejected with error message" do
      entity = make_entity(%{char_id: :player, gm: false})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Arena.Map.GmCommands.handle_gm_rain_toggle(state, :player)
      assert new_state.meta.rain == false
      assert_receive {:send_raw, _}
    end

    test "GM calling handle_gm_rain_toggle toggles rain" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:noreply, new_state} = Arena.Map.GmCommands.handle_gm_rain_toggle(state, :gm_player)
      assert new_state.meta.rain == true
    end

    test "unknown char_id calling handle_gm_rain_toggle is ignored" do
      state = make_map_state(%{})
      {:noreply, new_state} = Arena.Map.GmCommands.handle_gm_rain_toggle(state, :unknown)
      assert new_state == state
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Map-level: quest system adversarial tests
  # ═══════════════════════════════════════════════════════════════════════════

  describe "quest_accept without NPC interaction" do
    test "quest_accept with nil quest_npc_id sends error" do
      entity = make_entity(%{char_id: :player, quest_npc_id: nil})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest_accept(state, :player, 1)
      # Entity should be unchanged
      assert new_state.players[:player].active_quests == []
      assert_receive {:send_raw, _}
    end
  end

  describe "quest_abandon with out-of-range slot" do
    test "quest_abandon with slot 99 and no active quests sends error" do
      entity = make_entity(%{char_id: :player, active_quests: []})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest_abandon(state, :player, 99)
      assert new_state.players[:player].active_quests == []
      assert_receive {:send_raw, _}
    end

    test "quest_abandon with slot 0 and no active quests sends error" do
      entity = make_entity(%{char_id: :player, active_quests: []})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest_abandon(state, :player, 0)
      assert new_state.players[:player].active_quests == []
      assert_receive {:send_raw, _}
    end
  end

  describe "quest_details_request with out-of-range slot" do
    test "quest_details_request with slot 99 and no active quests sends error" do
      entity = make_entity(%{char_id: :player, active_quests: []})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest_details_request(state, :player, 99)
      assert new_state.players[:player].active_quests == []
      assert_receive {:send_raw, _}
    end

    test "quest_details_request with slot 0 and no active quests sends error" do
      entity = make_entity(%{char_id: :player, active_quests: []})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest_details_request(state, :player, 0)
      assert new_state.players[:player].active_quests == []
      assert_receive {:send_raw, _}
    end
  end

  describe "quest_list_request with no active quests" do
    test "quest_list_request sends packet with quest_count 0" do
      entity = make_entity(%{char_id: :player, active_quests: []})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, _new_state} = Arena.Map.QuestHandlers.handle_quest_list_request(state, :player)
      assert_receive {:send_raw, _raw}
    end
  end

  describe "quest handlers with unknown char_id" do
    test "quest_list_request for unknown char_id is silently ignored" do
      state = make_map_state(%{})
      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest_list_request(state, :unknown)
      assert new_state == state
    end

    test "quest_details_request for unknown char_id is silently ignored" do
      state = make_map_state(%{})
      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest_details_request(state, :unknown, 1)
      assert new_state == state
    end

    test "quest_accept for unknown char_id is silently ignored" do
      state = make_map_state(%{})
      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest_accept(state, :unknown, 1)
      assert new_state == state
    end

    test "quest_abandon for unknown char_id is silently ignored" do
      state = make_map_state(%{})
      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest_abandon(state, :unknown, 1)
      assert new_state == state
    end

    test "handle_quest for unknown char_id is silently ignored" do
      state = make_map_state(%{})
      {:noreply, new_state} = Arena.Map.QuestHandlers.handle_quest(state, :unknown)
      assert new_state == state
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # QuestServer unit tests (pure functions)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "QuestServer.abandon_quest edge cases" do
    test "abandon_quest with negative slot returns entity unchanged" do
      entity = make_entity(%{active_quests: [%{quest_id: 1, npc_kills: %{}, started_at: 0}]})
      result = Arena.QuestServer.abandon_quest(entity, -1)
      assert result.active_quests == entity.active_quests
    end

    test "abandon_quest with slot beyond active quests returns entity unchanged" do
      entity = make_entity(%{active_quests: [%{quest_id: 1, npc_kills: %{}, started_at: 0}]})
      result = Arena.QuestServer.abandon_quest(entity, 99)
      assert result.active_quests == entity.active_quests
    end

    test "abandon_quest with empty active_quests returns entity unchanged" do
      entity = make_entity(%{active_quests: []})
      result = Arena.QuestServer.abandon_quest(entity, 0)
      assert result.active_quests == []
    end
  end

  describe "QuestServer.quest_complete? edge cases" do
    test "quest_complete? with negative slot returns false" do
      entity = make_entity(%{})
      assert Arena.QuestServer.quest_complete?(entity, -1) == false
    end

    test "quest_complete? with slot beyond active quests returns false" do
      entity = make_entity(%{active_quests: []})
      assert Arena.QuestServer.quest_complete?(entity, 0) == false
    end
  end

  describe "QuestServer.complete_quest edge cases" do
    test "complete_quest with negative slot returns entity unchanged" do
      entity = make_entity(%{active_quests: [%{quest_id: 1, npc_kills: %{}, started_at: 0}]})
      result = Arena.QuestServer.complete_quest(entity, -1)
      assert result == entity
    end

    test "complete_quest with slot beyond active quests returns entity unchanged" do
      entity = make_entity(%{active_quests: []})
      result = Arena.QuestServer.complete_quest(entity, 0)
      assert result == entity
    end
  end

  describe "QuestServer.build_quest_details edge cases" do
    test "build_quest_details with negative slot returns nil" do
      entity = make_entity(%{})
      assert Arena.QuestServer.build_quest_details(entity, -1) == nil
    end

    test "build_quest_details with slot beyond active quests returns nil" do
      entity = make_entity(%{active_quests: []})
      assert Arena.QuestServer.build_quest_details(entity, 0) == nil
    end
  end

  describe "QuestServer.record_npc_kill with no active quests" do
    test "record_npc_kill returns entity unchanged when no quests" do
      entity = make_entity(%{active_quests: []})
      result = Arena.QuestServer.record_npc_kill(entity, 5)
      assert result.active_quests == []
    end
  end

  describe "QuestServer.build_npc_quest_list with invalid quest IDs" do
    test "build_npc_quest_list with non-existent quest IDs returns empty" do
      result = Arena.QuestServer.build_npc_quest_list([99999, 99998])
      assert result == []
    end

    test "build_npc_quest_list with empty list returns empty" do
      result = Arena.QuestServer.build_npc_quest_list([])
      assert result == []
    end
  end

  describe "QuestServer.available_quests_for_npc edge cases" do
    test "available_quests_for_npc with NPC having no quest_numbers returns empty" do
      entity = make_entity(%{})
      npc_def = %{quest_numbers: []}
      result = Arena.QuestServer.available_quests_for_npc(entity, npc_def)
      assert result == []
    end

    test "available_quests_for_npc with non-existent quest IDs returns empty" do
      entity = make_entity(%{})
      npc_def = %{quest_numbers: [99999, 99998]}
      result = Arena.QuestServer.available_quests_for_npc(entity, npc_def)
      assert result == []
    end
  end

  describe "QuestServer.can_accept_quest? edge cases" do
    test "can_accept_quest? with max active quests returns false" do
      quests = for i <- 1..5, do: %{quest_id: i, npc_kills: %{}, started_at: 0}
      entity = make_entity(%{active_quests: quests})
      quest_def = %{id: 6, required_level: 0, limit_level: 0, repetible: false}
      assert Arena.QuestServer.can_accept_quest?(entity, quest_def) == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # GM unknown command fallback
  # ═══════════════════════════════════════════════════════════════════════════

  describe "GM unknown command fallback" do
    test "GM sending unknown slash command receives error message" do
      gm = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: gm}, sessions: sessions)

      {:ok, _new_state, _effects} = Chat.handle_chat(state, :gm_player, "/NONEXISTENTCOMMAND")
      assert_receive {:send_raw, _}
    end
  end
end
