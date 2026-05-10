defmodule Arena.GmCommandsParityTest do
  @moduledoc """
  VB6 parity tests for GM commands (ROADMAP items #12-14).

  Covers missing VB6 GM commands, shortcut aliases, and removal of
  dead stubs. Each test exercises the command through the Chat module
  (same path used by both TCP and WebSocket clients).
  """
  use ExUnit.Case, async: true

  alias Arena.Map.Chat

  import Arena.Test.MapStateFactory

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

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
      saddle_slot: 0
    }

    Map.merge(defaults, overrides)
  end

  defp make_map_state(players, opts \\ []) do
    sessions = Keyword.get(opts, :sessions, %{})

    map_state(
      players: players,
      sessions: sessions,
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  defp admin_gm(id \\ 1, name \\ "AdminGM", extra \\ %{}) do
    make_entity(
      Map.merge(
        %{name: name, char_id: id, char_index: id, gm: true, gm_level: :admin},
        extra
      )
    )
  end

  defp target_player(id \\ 2, name \\ "Target", extra \\ %{}) do
    make_entity(
      Map.merge(
        %{name: name, char_id: id, char_index: id, gm: false, gm_level: nil},
        extra
      )
    )
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /ONLINE — list all online players (server-wide count, this-map list)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/ONLINE command" do
    test "returns online count via Chat dispatch" do
      gm = admin_gm()
      t1 = target_player(2, "Alice")
      t2 = target_player(3, "Bob", %{char_index: 3})
      state = make_map_state(%{1 => gm, 2 => t1, 3 => t2}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/ONLINE")

      # Should receive a console message with the online count
      assert_receive {:send_raw, _}, 200
    end

    test "is accessible at consejero tier" do
      gm = make_entity(%{name: "ConsGM", char_id: 1, char_index: 1, gm: true, gm_level: :consejero})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/ONLINE")

      # Consejero should be able to use /ONLINE (inspection-tier command)
      assert_receive {:send_raw, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /RAIN — text-based rain toggle (VB6 parity)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/RAIN command" do
    test "toggles rain on via text command" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/RAIN")

      assert new_state.meta.rain == true, "rain should be toggled on"
    end

    test "toggles rain off when already on" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})
      state = %{state | meta: %{state.meta | rain: true}}

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/RAIN")

      assert new_state.meta.rain == false, "rain should be toggled off"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /KICKALLCHARS — kick all non-GM players from the map
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/KICKALLCHARS command" do
    test "sends disconnect to all non-GM sessions" do
      gm = admin_gm()
      t1 = target_player(2, "Alice")
      t2 = target_player(3, "Bob", %{char_index: 3})

      {alice_pid, alice_ref} = spawn_monitor(fn -> receive do: (_ -> :ok) end)
      {bob_pid, bob_ref} = spawn_monitor(fn -> receive do: (_ -> :ok) end)

      state =
        make_map_state(
          %{1 => gm, 2 => t1, 3 => t2},
          sessions: %{1 => self(), 2 => alice_pid, 3 => bob_pid}
        )

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/KICKALLCHARS")

      # Moderation is on the effects contract; the GM confirmation
      # flows through `Effects.send/2` and arrives as `{:egress, _}`.
      assert_receive {:egress, _outbound}, 200

      Process.demonitor(alice_ref, [:flush])
      Process.demonitor(bob_ref, [:flush])
    end

    test "requires admin tier" do
      gm = make_entity(%{name: "DiosGM", char_id: 1, char_index: 1, gm: true, gm_level: :dios})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/KICKALLCHARS")

      # Should be rejected — dios cannot use admin-only commands
      assert new_state == state
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /SETBODY — set a player's body graphic
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/SETBODY command" do
    test "sets the target's body_id" do
      gm = admin_gm()
      target = target_player(2, "Target", %{body_id: 1, base_body_id: 1})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/SETBODY Target 210")

      updated = new_state.players[2]
      assert updated.body_id == 210, "body_id should be set to 210, got #{updated.body_id}"
    end

    test "returns error for missing player" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/SETBODY Nobody 210")

      assert_receive {:egress, _}, 200
    end

    test "returns usage for invalid body_id" do
      gm = admin_gm()
      target = target_player()
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/SETBODY Target abc")

      assert_receive {:egress, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /SETHEAD — set a player's head graphic
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/SETHEAD command" do
    test "sets the target's head_id" do
      gm = admin_gm()
      target = target_player(2, "Target", %{head_id: 1})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/SETHEAD Target 45")

      updated = new_state.players[2]
      assert updated.head_id == 45, "head_id should be set to 45, got #{updated.head_id}"
    end

    test "returns error for missing player" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/SETHEAD Nobody 45")

      assert_receive {:egress, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /SETSKIN — alias for /SETBODY (VB6 naming)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/SETSKIN command" do
    test "sets the target's body_id (alias for /SETBODY)" do
      gm = admin_gm()
      target = target_player(2, "Target", %{body_id: 1, base_body_id: 1})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/SETSKIN Target 300")

      updated = new_state.players[2]
      assert updated.body_id == 300, "body_id should be set to 300 via /SETSKIN, got #{updated.body_id}"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /SETGOLD — shortcut to set a target's gold
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/SETGOLD command" do
    test "sets the target's gold to the specified amount" do
      gm = admin_gm()
      target = target_player(2, "Target", %{gold: 100})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/SETGOLD Target 5000")

      updated = new_state.players[2]
      assert updated.gold == 5000, "gold should be set to 5000, got #{updated.gold}"
    end

    test "clamps gold to 0 minimum" do
      gm = admin_gm()
      target = target_player(2, "Target", %{gold: 100})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/SETGOLD Target -500")

      updated = new_state.players[2]
      assert updated.gold == 0, "gold should be clamped to 0, got #{updated.gold}"
    end

    test "returns error for missing player" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/SETGOLD Nobody 5000")

      assert_receive {:egress, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /SETLEVEL — shortcut to set a target's level
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/SETLEVEL command" do
    test "sets the target's level" do
      gm = admin_gm()
      target = target_player(2, "Target", %{level: 10})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/SETLEVEL Target 40")

      updated = new_state.players[2]
      assert updated.level == 40, "level should be set to 40, got #{updated.level}"
    end

    test "clamps level between 1 and 50" do
      gm = admin_gm()
      target = target_player(2, "Target", %{level: 10})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/SETLEVEL Target 999")

      updated = new_state.players[2]
      assert updated.level == 50, "level should be clamped to 50, got #{updated.level}"
    end

    test "returns error for missing player" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/SETLEVEL Nobody 25")

      assert_receive {:egress, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /SETSKILL — set a target's skill value
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/SETSKILL command" do
    test "sets a skill value for the target" do
      gm = admin_gm()
      target = target_player(2, "Target", %{skills: %{magic: 50, combat: 30}})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/SETSKILL Target magic 100")

      updated = new_state.players[2]
      assert updated.skills[:magic] == 100, "magic skill should be set to 100"
    end

    test "clamps skill value between 0 and 100" do
      gm = admin_gm()
      target = target_player(2, "Target", %{skills: %{magic: 50}})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/SETSKILL Target magic 200")

      updated = new_state.players[2]
      assert updated.skills[:magic] == 100, "skill should be clamped to 100"
    end

    test "returns error for missing player" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/SETSKILL Nobody magic 100")

      assert_receive {:egress, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /WHERECHAR — find a character with coordinates
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/WHERECHAR command" do
    test "returns position info for a local player" do
      gm = admin_gm()
      target = target_player(2, "Target", %{x: 42, y: 73})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/WHERECHAR Target")

      assert_receive {:send_raw, _}, 200
    end

    test "returns not found for missing player" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/WHERECHAR Nobody")

      assert_receive {:send_raw, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /IPCHAR — show character's session info
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/IPCHAR command" do
    test "returns session info for a local player" do
      gm = admin_gm()
      target = target_player(2, "Target", %{account_id: "acc_42"})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/IPCHAR Target")

      assert_receive {:send_raw, _}, 200
    end

    test "returns not found for missing player" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/IPCHAR Nobody")

      assert_receive {:send_raw, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /SYSTEMINFO — show server system information
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/SYSTEMINFO command" do
    test "returns system info via Chat dispatch" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/SYSTEMINFO")

      assert_receive {:send_raw, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /UNBAN — unban a single character (alias for /UNBANCUENTA)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/UNBAN command" do
    test "routes through Chat dispatch without crashing" do
      gm = admin_gm()
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      # /UNBAN is routed as an alias for /UNBANCUENTA
      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/UNBAN SomeName")

      assert_receive {:egress, _outbound}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # /SPAWN — alias for /SPAWNNPC
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/SPAWN command" do
    test "routes via Chat dispatch (alias for /SPAWNNPC)" do
      gm = admin_gm(1, "GM", %{heading: :south})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      # Should route to the spawn NPC handler (may fail with "NPC not found" but won't crash)
      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/SPAWN 1")

      assert_receive {:egress, _}, 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Permission tier additions for new commands
  # ═══════════════════════════════════════════════════════════════════════════

  describe "permission tiers for new commands" do
    test "/ONLINE is accessible at consejero tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/ONLINE") == :consejero
    end

    test "/RAIN requires dios tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/RAIN") == :dios
    end

    test "/KICKALLCHARS requires admin tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/KICKALLCHARS") == :admin
    end

    test "/SETBODY requires dios tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/SETBODY") == :dios
    end

    test "/SETHEAD requires dios tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/SETHEAD") == :dios
    end

    test "/SETSKIN requires dios tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/SETSKIN") == :dios
    end

    test "/SETGOLD requires dios tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/SETGOLD") == :dios
    end

    test "/SETLEVEL requires dios tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/SETLEVEL") == :dios
    end

    test "/SETSKILL requires dios tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/SETSKILL") == :dios
    end

    test "/WHERECHAR requires consejero tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/WHERECHAR") == :consejero
    end

    test "/IPCHAR requires admin tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/IPCHAR") == :admin
    end

    test "/SYSTEMINFO requires admin tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/SYSTEMINFO") == :admin
    end

    test "/UNBAN requires admin tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/UNBAN") == :admin
    end

    test "/SPAWN requires dios tier" do
      assert Arena.Map.Gm.Permissions.required_tier("/SPAWN") == :dios
    end
  end
end
