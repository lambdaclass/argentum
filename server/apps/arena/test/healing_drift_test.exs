defmodule Arena.HealingDriftTest do
  @moduledoc """
  VB6 parity drift tests for the healing system (rest, meditate, heal, resurrect).
  Each test reproduces a verified drift identified from VB6 source comparison.
  """
  use ExUnit.Case, async: false

  alias Arena.Data.NpcDef
  alias Arena.Map.Healing

  import Arena.Test.MapStateFactory

  # VB6: Revividor NPC type
  @npc_type_revividor 1
  # VB6: FOGATA object id (obj_index 21 in VB6)
  @fogata_obj_index 21
  # VB6: jail map id (MAP_HOME_IN_JAIL = 66)
  @jail_map_id 66

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
      hp: 50,
      max_hp: 100,
      mana: 50,
      max_mana: 200,
      stamina: 100,
      max_stamina: 100,
      hunger: 100,
      thirst: 100,
      level: 25,
      xp: 0,
      class: :mage,
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

  defp make_state(entity_overrides, opts \\ []) do
    entity = make_entity(entity_overrides)
    sessions = %{player: self()}

    map_state(
      players: %{player: entity},
      sessions: sessions,
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      map_id: Keyword.get(opts, :map_id, 1),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      ground_items: Keyword.get(opts, :ground_items, %{})
    )
  end

  defp revividor_npc_def(id) do
    %NpcDef{
      id: id,
      npc_type: @npc_type_revividor,
      name: "Sacerdote",
      faccion: 0,
      body: 1,
      head: 0,
      heading: 3,
      comercia: false,
      quest_numbers: [],
      creatures: []
    }
  end

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    unless Process.whereis(Arena.Data.GameData) do
      {:ok, _} = Arena.Data.GameData.start_link([])
    end

    # Insert a revividor NPC def into ETS for tests that need it
    :ets.insert(:arena_game_data, {{:npc, 500}, revividor_npc_def(500)})

    # Drain any leftover messages from session pid
    drain_mailbox()
    :ok
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      10 -> :ok
    end
  end

  # ==================================================================
  # Drift #19: Meditate missing mounted restriction
  # VB6: If .flags.Montado = 1 Then → "No podes meditar estando montado"
  # ==================================================================
  describe "Drift #19: meditate blocks mounted players" do
    test "mounted player cannot meditate" do
      state = make_state(%{mounted: true, class: :mage, mana: 50, max_mana: 200})

      {:noreply, new_state} = Healing.handle_meditate(state, :player)

      entity = new_state.players[:player]
      # VB6: mounted player should NOT start meditating
      refute entity.meditating, "mounted player should not be allowed to meditate"
    end

    test "unmounted player can meditate normally" do
      state = make_state(%{mounted: false, class: :mage, mana: 50, max_mana: 200})

      {:noreply, new_state} = Healing.handle_meditate(state, :player)

      entity = new_state.players[:player]
      assert entity.meditating, "unmounted mage should be able to meditate"
    end
  end

  # ==================================================================
  # Drift #22: Heal in jail missing restriction
  # VB6: If .pos.Map = MAP_HOME_IN_JAIL And NpcList(...).npcType = Revividor
  #   Then Exit Sub
  # ==================================================================
  describe "Drift #22: heal blocked in jail map" do
    test "heal requires selected priest even when one is nearby" do
      revividor_npc = %{npc_id: 500, x: 51, y: 50, instance_id: :rev1}

      state =
        make_state(
          %{hp: 50, max_hp: 100, map_id: 1},
          npcs_live: %{rev1: revividor_npc},
          map_id: 1
        )

      {:noreply, new_state} = Healing.handle_heal(state, :player)

      assert new_state.players[:player].hp == 50,
             "heal should reject when priest is nearby but not selected"
    end

    test "revividor NPC heal is blocked when player is on jail map" do
      # Jail map is map_id 66 (from Arena.Map.Gm.Moderation @jail_map_id)
      revividor_npc = %{npc_id: 500, x: 51, y: 50, instance_id: :rev1}

      state =
        make_state(
          %{
            hp: 50,
            max_hp: 100,
            map_id: @jail_map_id,
            last_clicked_npc_instance_id: :rev1,
            last_clicked_npc_type: @npc_type_revividor
          },
          npcs_live: %{rev1: revividor_npc},
          map_id: @jail_map_id
        )

      {:noreply, new_state} = Healing.handle_heal(state, :player)

      entity = new_state.players[:player]
      # VB6: heal should NOT work in jail
      assert entity.hp == 50, "player should not be healed in jail map"
    end

    test "revividor NPC heal works on non-jail maps" do
      revividor_npc = %{npc_id: 500, x: 51, y: 50, instance_id: :rev1}

      state =
        make_state(
          %{
            hp: 50,
            max_hp: 100,
            map_id: 1,
            last_clicked_npc_instance_id: :rev1,
            last_clicked_npc_type: @npc_type_revividor
          },
          npcs_live: %{rev1: revividor_npc},
          map_id: 1
        )

      {:noreply, new_state} = Healing.handle_heal(state, :player)

      entity = new_state.players[:player]
      # Normal map: heal should work
      assert entity.hp == 100, "player should be healed on normal map"
    end
  end

  # ==================================================================
  # Bug: handle_heal wrongly blocks non-newbies from ResucitadorNewbie
  # VB6 HandleHeal (Protocol.bas:4408) has NO EsNewbie check — any player
  # can be healed by ResucitadorNewbie. Only HandleResucitate restricts it.
  # ==================================================================
  describe "VB6 parity: ResucitadorNewbie can heal non-newbie players" do
    test "non-newbie player (level 25) is healed by ResucitadorNewbie" do
      newbie_priest_def = %NpcDef{
        id: 501,
        npc_type: 9,
        name: "Sacerdote Newbie",
        faccion: 0,
        body: 1,
        head: 0,
        heading: 3,
        comercia: false,
        quest_numbers: [],
        creatures: []
      }

      :ets.insert(:arena_game_data, {{:npc, 501}, newbie_priest_def})

      newbie_priest_npc = %{npc_id: 501, x: 51, y: 50, instance_id: :newbie_rev1}

      state =
        make_state(
          %{
            hp: 50,
            max_hp: 100,
            level: 25,
            last_clicked_npc_instance_id: :newbie_rev1,
            last_clicked_npc_type: 9
          },
          npcs_live: %{newbie_rev1: newbie_priest_npc}
        )

      {:noreply, new_state} = Healing.handle_heal(state, :player)

      entity = new_state.players[:player]
      assert entity.hp == 100,
             "VB6: ResucitadorNewbie can heal ANY player, not just newbies"
    end
  end

  # ==================================================================
  # Drift #23: Priest resurrection wrongly zeroes mana
  # VB6: Only zeroes mana for SPELL-based revive, not NPC/priest revive
  # ==================================================================
  describe "Drift #23: NPC resurrect preserves mana" do
    test "NPC resurrection does not zero mana" do
      revividor_npc = %{npc_id: 500, x: 51, y: 50, instance_id: :rev1}

      state =
        make_state(
          %{
            dead: true,
            hp: 0,
            max_hp: 100,
            mana: 150,
            max_mana: 200,
            last_clicked_npc_instance_id: :rev1,
            last_clicked_npc_type: @npc_type_revividor
          },
          npcs_live: %{rev1: revividor_npc}
        )

      {:noreply, new_state} = Healing.handle_resucitate(state, :player)

      entity = new_state.players[:player]
      refute entity.dead, "player should be resurrected"
      assert entity.hp == 100, "hp should be restored to max"
      # VB6: NPC resurrect preserves mana (only spell resurrect zeroes it)
      assert entity.mana == 150, "NPC resurrect should preserve mana, not zero it"
    end
  end

  # ==================================================================
  # Drift #18: Rest missing campfire check
  # VB6: If HayOBJarea(.pos, FOGATA) Then — requires nearby campfire
  # The fogata is a ground object with obj_index 21 in VB6.
  # ==================================================================
  describe "Drift #18: rest requires nearby campfire" do
    test "rest without nearby campfire should be blocked" do
      # Player at (50,50), no campfire on the ground
      state = make_state(%{hp: 50, max_hp: 100, resting: false})

      {:ok, new_state, _effects} = Healing.handle_rest(state, :player)

      entity = new_state.players[:player]
      # VB6: resting requires a campfire nearby; without one, player cannot rest
      refute entity.resting, "rest should require a nearby campfire (fogata)"
    end

    test "rest with nearby campfire should succeed" do
      # Player at (50,50), campfire (fogata) on the ground nearby at (50,51)
      fogata_item = %{item_id: @fogata_obj_index, amount: 1, elemental_tags: 0}

      state =
        make_state(
          %{hp: 50, max_hp: 100, resting: false},
          ground_items: %{{50, 51} => fogata_item}
        )

      {:ok, new_state, _effects} = Healing.handle_rest(state, :player)

      entity = new_state.players[:player]
      assert entity.resting, "rest should succeed when campfire is nearby"
    end

    test "rest with campfire too far away should be blocked" do
      # Player at (50,50), campfire at (60,60) — more than 8 tiles away
      fogata_item = %{item_id: @fogata_obj_index, amount: 1, elemental_tags: 0}

      state =
        make_state(
          %{hp: 50, max_hp: 100, resting: false},
          ground_items: %{{60, 60} => fogata_item}
        )

      {:ok, new_state, _effects} = Healing.handle_rest(state, :player)

      entity = new_state.players[:player]
      refute entity.resting, "rest should fail if campfire is too far away"
    end
  end
end
