defmodule Arena.GmAdversarialTest do
  @moduledoc """
  Adversarial tests ensuring non-GM players cannot execute GM commands.

  Tests two independent guard layers:
  1. Session-level: SessionLogic.handle_command/2 returns "No tienes privilegios de GM."
     when a non-GM session sends any command in @gm_command_types.
  2. Map-level: Social.handle_chat/3 silently ignores slash commands typed by non-GM
     entities (returns {:noreply, state} unchanged).

  Also confirms that authorised GMs can execute representative commands.
  """
  use ExUnit.Case, async: true

  alias Arena.Data.GameData
  alias Arena.Map.Social
  alias AoTcpGateway.SessionLogic

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
      marriage_proposal_target: nil
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
          :royal_army_message,
          :chaos_legion_message,
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

        result = Social.handle_chat(state, :attacker, slash)

        # Must return {:noreply, state} with state unchanged
        assert result == {:noreply, state}
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
    test "handle_chat returns {:noreply, state} when char_id is not in players map" do
      state = make_map_state(%{})

      result = Social.handle_chat(state, :nonexistent, "/KILL someone")

      assert result == {:noreply, state}
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
      assert msg =~ "Server open/close toggle"
    end

    test "GM can use :save_chars" do
      state = make_session_state(%{character_id: 2001, is_gm: true})

      {_new_state, messages} = SessionLogic.handle_command(state, {:save_chars, %{}})

      assert length(messages) == 1
      [{:console_msg, %{message: msg}}] = messages
      assert msg =~ "Guardado de personajes"
    end

    test "GM can use :warp_me_to_target (returns hint message)" do
      state = make_session_state(%{character_id: 2001, is_gm: true})

      {_new_state, messages} = SessionLogic.handle_command(state, {:warp_me_to_target, %{}})

      assert length(messages) == 1
      [{:console_msg, %{message: msg}}] = messages
      assert msg =~ "/GOTO"
    end
  end

  describe "GM slash commands work for authorized GMs at map level" do
    test "GM can use /ONLINEMAP" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      # Use a session pid so gm_console can send messages
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      result = Social.handle_chat(state, :gm_player, "/ONLINEMAP")

      # /ONLINEMAP sends a console message listing players; it returns {:noreply, state}
      assert {:noreply, _new_state} = result
    end

    test "GM /INVISIBLE toggles invisible flag" do
      entity = make_entity(%{char_id: :gm_player, gm: true, invisible: false, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:noreply, new_state} = Social.handle_chat(state, :gm_player, "/INVISIBLE")

      updated = new_state.players[:gm_player]
      assert updated.invisible == true
    end

    test "unknown GM slash command returns 'Unknown GM command'" do
      entity = make_entity(%{char_id: :gm_player, gm: true, name: "AdminGM"})
      sessions = %{gm_player: self()}
      state = make_map_state(%{gm_player: entity}, sessions: sessions)

      {:noreply, _new_state} = Social.handle_chat(state, :gm_player, "/NOSUCHCMD")

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

      result = Social.handle_chat(state, :player, "Hello world!")

      # Normal chat returns {:noreply, updated_state} — not rejected
      assert {:noreply, _new_state} = result
    end
  end
end
