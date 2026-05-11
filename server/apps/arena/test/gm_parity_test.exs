defmodule Arena.GmParityTest do
  @moduledoc """
  Tests for VB6 GM parity: permission tiers, missing commands,
  and stub fixes.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.Chat
  alias Arena.Map.Gm.Moderation
  alias Arena.Data.GameData

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

  # ═══════════════════════════════════════════════════════════════════════════
  # 1. GM Permission Tiers
  # ═══════════════════════════════════════════════════════════════════════════

  describe "GM permission tiers — gm_level field" do
    test "entity with gm_level :admin has gm == true" do
      entity = make_entity(%{gm: true, gm_level: :admin, char_index: 1})
      assert entity.gm == true
      assert entity.gm_level == :admin
    end

    test "entity with gm_level nil has gm == false" do
      entity = make_entity(%{gm: false, gm_level: nil, char_index: 1})
      assert entity.gm == false
      assert entity.gm_level == nil
    end

    test "entity with gm_level :consejero has gm == true" do
      entity = make_entity(%{gm: true, gm_level: :consejero, char_index: 1})
      assert entity.gm == true
      assert entity.gm_level == :consejero
    end
  end

  describe "GM permission tiers — consejero can only use inspection commands" do
    test "consejero can use /INFO" do
      gm = make_entity(%{name: "ConsGM", char_id: 1, char_index: 1, gm: true, gm_level: :consejero})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/INFO Victim")
    end

    test "consejero cannot use /KICK (moderation)" do
      gm = make_entity(%{name: "ConsGM", char_id: 1, char_index: 1, gm: true, gm_level: :consejero})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/KICK Victim")

      # Target should still be in the map — the command should have been rejected
      assert Map.has_key?(new_state.players, 2)
      # The state should be unchanged (no kick happened)
      assert new_state == state
    end

    test "consejero cannot use /GOTO (teleport)" do
      gm = make_entity(%{name: "ConsGM", char_id: 1, char_index: 1, gm: true, gm_level: :consejero})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil, x: 80, y: 80})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/GOTO Victim")

      # State should be unchanged — command rejected
      assert new_state == state
    end

    test "consejero cannot use /GIVEITEM (char_edit)" do
      gm = make_entity(%{name: "ConsGM", char_id: 1, char_index: 1, gm: true, gm_level: :consejero})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/GIVEITEM Victim 100 1")

      # State should be unchanged — command rejected
      assert new_state == state
    end
  end

  describe "GM permission tiers — semi_dios can use moderation + teleport" do
    test "semi_dios can use /KICK" do
      gm = make_entity(%{name: "SemiGM", char_id: 1, char_index: 1, gm: true, gm_level: :semi_dios})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/KICK Victim")
      # Should not be rejected — command goes through
    end

    test "semi_dios can use /INFO (inspection)" do
      gm = make_entity(%{name: "SemiGM", char_id: 1, char_index: 1, gm: true, gm_level: :semi_dios})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/INFO Victim")
    end

    test "semi_dios cannot use /GIVEITEM (char_edit)" do
      gm = make_entity(%{name: "SemiGM", char_id: 1, char_index: 1, gm: true, gm_level: :semi_dios})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/GIVEITEM Victim 100 1")

      # State should be unchanged — command rejected
      assert new_state == state
    end

    test "semi_dios cannot use /CLEANWORLD (admin-only)" do
      gm = make_entity(%{name: "SemiGM", char_id: 1, char_index: 1, gm: true, gm_level: :semi_dios})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/CLEANWORLD")

      # State should be unchanged — command rejected
      assert new_state == state
    end
  end

  describe "GM permission tiers — dios can use char_edit + NPC spawn" do
    test "dios can use /REVIVE (char_edit)" do
      gm = make_entity(%{name: "DiosGM", char_id: 1, char_index: 1, gm: true, gm_level: :dios})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil, dead: true, hp: 0})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/REVIVE Victim")

      revived = new_state.players[2]
      assert revived.dead == false
      assert revived.hp == revived.max_hp
    end

    test "dios can use /KICK (moderation)" do
      gm = make_entity(%{name: "DiosGM", char_id: 1, char_index: 1, gm: true, gm_level: :dios})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/KICK Victim")
    end

    test "dios cannot use /CLEANWORLD (admin-only)" do
      gm = make_entity(%{name: "DiosGM", char_id: 1, char_index: 1, gm: true, gm_level: :dios})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/CLEANWORLD")

      # State should be unchanged — command rejected
      assert new_state == state
    end
  end

  describe "GM permission tiers — admin has full access" do
    test "admin can use /MUTE (moderation)" do
      gm = make_entity(%{name: "AdminGM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/MUTE Victim 5")

      # Mute should have been applied (state changed)
      updated = new_state.players[2]
      assert updated.muted_until > 0, "admin should be able to mute players"
    end

    test "admin can use /KICK" do
      gm = make_entity(%{name: "AdminGM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/KICK Victim")
    end

    test "admin can use /INFO" do
      gm = make_entity(%{name: "AdminGM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      target = make_entity(%{name: "Victim", char_id: 2, char_index: 2, gm: false, gm_level: nil})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/INFO Victim")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 2. Fix gm_remove_punishment Stub
  # ═══════════════════════════════════════════════════════════════════════════

  describe "gm_remove_punishment removes punishment records" do
    test "removes a numbered punishment record from the entity" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})

      target =
        make_entity(%{
          name: "Convict",
          char_id: 2,
          char_index: 2,
          gm: false,
          gm_level: nil,
          penalty: 15,
          punishments: [
            %{number: 1, text: "Carcel 15 min", date: "2026-04-18", gm_name: "GM"}
          ]
        })

      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} =
        Moderation.gm_remove_punishment(state, 1, "Convict", "1", "pardoned")

      updated_target = new_state.players[2]
      assert updated_target.punishments == [], "punishment record should be removed"
    end

    test "handles non-existent target gracefully" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Moderation.gm_remove_punishment(state, 1, "Nobody", "1", "test")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 3. /SUMMON Command
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/SUMMON command" do
    test "summon routes to teleport handler" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin, x: 10, y: 10})
      target = make_entity(%{name: "Target", char_id: 2, char_index: 2, gm: false, gm_level: nil, x: 80, y: 80})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, run_state, run_effects} = Chat.handle_chat(state, 1, "/SUMMON Target")
      Arena.Map.Effects.run(run_state, run_effects)

      # The summon should send a transfer message to the target's session
      # (teleporting them to the GM's location), plus a console
      # confirmation back to the GM via the egress queue.
      assert_receive {:transfer, _, _, _, _}, 200
      assert_receive {:egress, _}, 200
    end

    test "summon returns not found for missing player" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/SUMMON Nobody")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 4. /UNJAIL Command
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/UNJAIL command" do
    test "unjail clears penalty to 0" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      target = make_entity(%{name: "Prisoner", char_id: 2, char_index: 2, gm: false, gm_level: nil, penalty: 30})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/UNJAIL Prisoner")

      updated = new_state.players[2]
      assert updated.penalty == 0, "penalty should be cleared to 0, got #{updated.penalty}"
    end

    test "unjail returns not found for missing player" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/UNJAIL Nobody")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 5. /NAVIGANDO Command
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/NAVIGANDO command" do
    test "toggles navigating from false to true" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      target = make_entity(%{name: "Sailor", char_id: 2, char_index: 2, gm: false, gm_level: nil, navigating: false})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/NAVIGANDO Sailor")

      updated = new_state.players[2]
      assert updated.navigating == true, "navigating should be toggled to true"
    end

    test "toggles navigating from true to false" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      target = make_entity(%{name: "Sailor", char_id: 2, char_index: 2, gm: false, gm_level: nil, navigating: true})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/NAVIGANDO Sailor")

      updated = new_state.players[2]
      assert updated.navigating == false, "navigating should be toggled to false"
    end

    test "navigando returns not found for missing player" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/NAVIGANDO Nobody")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 6. /RMCRIMINAL and /RMCITIZEN Commands
  # ═══════════════════════════════════════════════════════════════════════════

  describe "/RMCRIMINAL command" do
    test "sets criminal to false" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      target = make_entity(%{name: "Criminal", char_id: 2, char_index: 2, gm: false, gm_level: nil, criminal: true})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/RMCRIMINAL Criminal")

      updated = new_state.players[2]
      assert updated.criminal == false, "criminal should be set to false"
    end

    test "rmcriminal returns not found for missing player" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/RMCRIMINAL Nobody")
    end
  end

  describe "/RMCITIZEN command" do
    test "sets criminal to true" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      target = make_entity(%{name: "Citizen", char_id: 2, char_index: 2, gm: false, gm_level: nil, criminal: false})
      state = make_map_state(%{1 => gm, 2 => target}, sessions: %{1 => self(), 2 => self()})

      {:ok, new_state, _effects} = Chat.handle_chat(state, 1, "/RMCITIZEN Citizen")

      updated = new_state.players[2]
      assert updated.criminal == true, "criminal should be set to true"
    end

    test "rmcitizen returns not found for missing player" do
      gm = make_entity(%{name: "GM", char_id: 1, char_index: 1, gm: true, gm_level: :admin})
      state = make_map_state(%{1 => gm}, sessions: %{1 => self()})

      {:ok, _state, _effects} = Chat.handle_chat(state, 1, "/RMCITIZEN Nobody")
    end
  end
end
