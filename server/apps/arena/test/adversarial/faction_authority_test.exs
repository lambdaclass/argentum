defmodule Arena.Adversarial.FactionAuthorityTest do
  @moduledoc """
  Adversarial tests for the faction system.

  Verifies that the server correctly rejects or safely handles attempts to:
  - Enlist while already in a faction
  - Leave a faction while not in one
  - Enlist while dead
  - Enlist from far away from the enlistador NPC
  - Use faction chat while not in a faction
  - Enlist in an invalid/unknown faction
  - Leave a faction while in combat (no nearby enlistador)
  """
  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.Faction

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Arena.Settings.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    Arena.Settings.reset_all()
    :ok
  end

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
    map_state(
      players: players,
      sessions: Keyword.get(opts, :sessions, %{}),
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  # A fake NPC def that looks like an enlistador for :royal_army (faccion 3)
  defp royal_enlistador_npc_def do
    %{name: "Enlistador Real", npc_type: 5, faccion: 3}
  end

  defp chaos_enlistador_npc_def do
    %{name: "Enlistador Caos", npc_type: 5, faccion: 2}
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Enlist while already in a faction
  # ═══════════════════════════════════════════════════════════════════════════

  describe "enlist while already in a faction" do
    test "clicking enlistador while already in same faction does not re-enlist" do
      entity = make_entity(%{char_id: :player, faction: :royal_army, faction_rank_armada: 1})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      # Click on royal army enlistador while already in royal army
      # Should attempt rank up, not re-enlist
      {:noreply, new_state} = Faction.handle_enlistador_click(state, :player, entity, royal_enlistador_npc_def())

      # Faction should remain unchanged (rank up logic handles this path)
      assert new_state.players[:player].faction == :royal_army
    end

    test "clicking enemy enlistador while in a faction is rejected" do
      entity = make_entity(%{char_id: :player, faction: :royal_army, faction_rank_armada: 1})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      # Try to enlist in chaos while already in royal army
      {:noreply, new_state} = Faction.handle_enlistador_click(state, :player, entity, chaos_enlistador_npc_def())

      # Must remain in royal army — cannot switch without /RENUNCIAR
      assert new_state.players[:player].faction == :royal_army
    end

    test "handle_enlist_faction for player already in faction stays unchanged (no nearby enlistador)" do
      entity = make_entity(%{char_id: :player, faction: :chaos_legion})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_enlist_faction(state, :player, :royal_army)

      # No enlistador nearby → rejected; faction unchanged
      assert new_state.players[:player].faction == :chaos_legion
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Enlist while dead
  # ═══════════════════════════════════════════════════════════════════════════

  describe "enlist while dead" do
    test "dead player clicking enlistador is rejected" do
      entity = make_entity(%{char_id: :player, dead: true, faction: :none})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_enlistador_click(state, :player, entity, royal_enlistador_npc_def())

      # Dead players must not be able to enlist
      assert new_state.players[:player].faction == :none
    end

    test "dead player using handle_enlist_faction stays factionless" do
      entity = make_entity(%{char_id: :player, dead: true, faction: :none})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_enlist_faction(state, :player, :royal_army)

      assert new_state.players[:player].faction == :none
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Leave faction while not in one
  # ═══════════════════════════════════════════════════════════════════════════

  describe "leave faction while not in one" do
    test "player with no faction cannot leave" do
      entity = make_entity(%{char_id: :player, faction: :none, faction_reenlistadas: 0})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      assert new_state.players[:player].faction == :none
      assert new_state.players[:player].faction_reenlistadas == 0
    end

    test "leave for nonexistent player is a no-op" do
      state = make_map_state(%{})

      {:noreply, new_state} = Faction.handle_leave_faction(state, :ghost)

      assert new_state == state
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Leave faction while in combat (no nearby enlistador simulates this)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "leave faction without nearby enlistador (combat / remote)" do
    test "leaving without nearby enlistador is rejected" do
      # Player is in a faction but nowhere near an enlistador NPC
      entity = make_entity(%{char_id: :player, faction: :royal_army, faction_reenlistadas: 0})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      # Without a nearby enlistador, faction must remain unchanged
      assert new_state.players[:player].faction == :royal_army
      assert new_state.players[:player].faction_reenlistadas == 0
    end

    test "leaving chaos legion without nearby enlistador is rejected" do
      entity = make_entity(%{char_id: :player, faction: :chaos_legion, faction_reenlistadas: 1})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      assert new_state.players[:player].faction == :chaos_legion
      assert new_state.players[:player].faction_reenlistadas == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Enlist from far away from enlistador NPC
  # ═══════════════════════════════════════════════════════════════════════════

  describe "enlist from far away" do
    test "handle_enlist_faction with no NPCs on map is rejected" do
      entity = make_entity(%{char_id: :player, faction: :none})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_enlist_faction(state, :player, :royal_army)

      assert new_state.players[:player].faction == :none
    end

    test "handle_enlist_faction with enlistador far away is rejected" do
      # Player at (50, 50), enlistador NPC at (200, 200) — well beyond 5-tile range
      far_npc = %{npc_id: 900, x: 200, y: 200, instance_id: :far_enl}
      entity = make_entity(%{char_id: :player, faction: :none, x: 50, y: 50})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{far_enl: far_npc})

      {:noreply, new_state} = Faction.handle_enlist_faction(state, :player, :royal_army)

      # Too far from enlistador — must remain factionless
      assert new_state.players[:player].faction == :none
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Faction chat while not in a faction
  # ═══════════════════════════════════════════════════════════════════════════

  describe "faction chat while not in a faction" do
    test "factionless player cannot use faction chat" do
      entity = make_entity(%{char_id: :player, faction: :none})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_faction_chat(state, :player, "hello faction")

      # State should not change (no last_chat_at update since message was rejected)
      assert new_state.players[:player].faction == :none
    end

    test "dead player cannot use faction chat" do
      entity = make_entity(%{char_id: :player, faction: :royal_army, dead: true})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_faction_chat(state, :player, "hello from grave")

      # Dead players are silently rejected — last_chat_at should not update
      assert new_state.players[:player].last_chat_at == entity.last_chat_at
    end

    test "faction chat for nonexistent player is a no-op" do
      state = make_map_state(%{})

      {:noreply, new_state} = Faction.handle_faction_chat(state, :ghost, "hello")

      assert new_state == state
    end

    test "muted player cannot use faction chat" do
      # muted_until is a wall-clock timestamp in the future
      future = System.system_time(:millisecond) + 60_000
      entity = make_entity(%{char_id: :player, faction: :royal_army, muted_until: future})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_faction_chat(state, :player, "trying to speak")

      # Muted — last_chat_at should not update
      assert new_state.players[:player].last_chat_at == entity.last_chat_at
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Enlist in an invalid faction
  # ═══════════════════════════════════════════════════════════════════════════

  describe "enlist in an invalid faction" do
    test "clicking NPC with faccion 0 (none) is rejected" do
      npc_def = %{name: "Random NPC", npc_type: 5, faccion: 0}
      entity = make_entity(%{char_id: :player, faction: :none})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_enlistador_click(state, :player, entity, npc_def)

      assert new_state.players[:player].faction == :none
    end

    test "clicking NPC with faccion 99 (unknown) is rejected" do
      npc_def = %{name: "Bogus NPC", npc_type: 5, faccion: 99}
      entity = make_entity(%{char_id: :player, faction: :none})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_enlistador_click(state, :player, entity, npc_def)

      assert new_state.players[:player].faction == :none
    end

    test "handle_enlist_faction with invalid atom raises or is rejected" do
      entity = make_entity(%{char_id: :player, faction: :none})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      # Passing an invalid faction atom to handle_enlist_faction should either
      # raise a FunctionClauseError (pattern match failure in find_nearby_enlistador)
      # or be safely rejected. Either way, the player must not end up in a faction.
      result =
        try do
          Faction.handle_enlist_faction(state, :player, :bogus_faction)
        rescue
          FunctionClauseError -> :raised
          MatchError -> :raised
          CaseClauseError -> :raised
        end

      case result do
        :raised ->
          # Good — invalid faction is not accepted
          :ok

        {:noreply, new_state} ->
          # Also acceptable if it's a no-op
          assert new_state.players[:player].faction == :none
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Criminal trying to enlist in royal army
  # ═══════════════════════════════════════════════════════════════════════════

  describe "criminal restrictions" do
    test "criminal cannot enlist in royal army" do
      entity = make_entity(%{char_id: :player, faction: :none, criminal: true})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_enlistador_click(state, :player, entity, royal_enlistador_npc_def())

      assert new_state.players[:player].faction == :none
    end

    test "player who killed citizens cannot enlist in royal army" do
      entity = make_entity(%{char_id: :player, faction: :none, citizens_killed: 5})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_enlistador_click(state, :player, entity, royal_enlistador_npc_def())

      assert new_state.players[:player].faction == :none
    end

    test "thief class cannot enlist in royal army" do
      entity = make_entity(%{char_id: :player, faction: :none, class: :thief})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:noreply, new_state} = Faction.handle_enlistador_click(state, :player, entity, royal_enlistador_npc_def())

      assert new_state.players[:player].faction == :none
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Leave faction rejected when only wrong-faction enlistador is nearby
  # ═══════════════════════════════════════════════════════════════════════════

  describe "leave faction with wrong-faction enlistador" do
    setup do
      # Insert test NPC defs into ETS so GameData.get_npc works
      royal_npc_def = %Arena.Data.NpcDef{
        id: 9901,
        name: "Enlistador Real Test",
        npc_type: 5,
        faccion: 3
      }

      chaos_npc_def = %Arena.Data.NpcDef{
        id: 9902,
        name: "Enlistador Caos Test",
        npc_type: 5,
        faccion: 2
      }

      :ets.insert(:arena_game_data, {{:npc, 9901}, royal_npc_def})
      :ets.insert(:arena_game_data, {{:npc, 9902}, chaos_npc_def})

      on_exit(fn ->
        :ets.delete(:arena_game_data, {:npc, 9901})
        :ets.delete(:arena_game_data, {:npc, 9902})
      end)

      :ok
    end

    test "royal army player cannot leave at chaos enlistador" do
      # Player is in royal army, only a chaos enlistador is nearby
      entity = make_entity(%{char_id: :player, faction: :royal_army, x: 50, y: 50, faction_reenlistadas: 0})
      chaos_npc = %{npc_id: 9902, x: 51, y: 51, instance_id: :chaos_enl}
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{chaos_enl: chaos_npc})

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      # Must NOT leave — the nearby enlistador belongs to the wrong faction
      assert new_state.players[:player].faction == :royal_army
      assert new_state.players[:player].faction_reenlistadas == 0
    end

    test "chaos legion player cannot leave at royal enlistador" do
      # Player is in chaos legion, only a royal army enlistador is nearby
      entity = make_entity(%{char_id: :player, faction: :chaos_legion, x: 50, y: 50, faction_reenlistadas: 0})
      royal_npc = %{npc_id: 9901, x: 52, y: 50, instance_id: :royal_enl}
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{royal_enl: royal_npc})

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      # Must NOT leave — the nearby enlistador belongs to the wrong faction
      assert new_state.players[:player].faction == :chaos_legion
      assert new_state.players[:player].faction_reenlistadas == 0
    end

    test "royal army player CAN leave at royal enlistador" do
      # Player is in royal army, a royal army enlistador is nearby — should succeed
      entity = make_entity(%{char_id: :player, faction: :royal_army, x: 50, y: 50, faction_reenlistadas: 0})
      royal_npc = %{npc_id: 9901, x: 51, y: 51, instance_id: :royal_enl}
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{royal_enl: royal_npc})

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      # SHOULD leave successfully at own faction's enlistador
      assert new_state.players[:player].faction == :none
      assert new_state.players[:player].faction_reenlistadas == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Leave faction rejected when player is in an aligned guild
  # ═══════════════════════════════════════════════════════════════════════════

  describe "leave faction rejected when in aligned guild" do
    setup do
      # Insert test enlistador NPC defs
      royal_npc_def = %Arena.Data.NpcDef{
        id: 9901,
        name: "Enlistador Real Test",
        npc_type: 5,
        faccion: 3
      }

      chaos_npc_def = %Arena.Data.NpcDef{
        id: 9902,
        name: "Enlistador Caos Test",
        npc_type: 5,
        faccion: 2
      }

      :ets.insert(:arena_game_data, {{:npc, 9901}, royal_npc_def})
      :ets.insert(:arena_game_data, {{:npc, 9902}, chaos_npc_def})

      # Set up GuildServer ETS table for guild membership checks
      # GuildServer uses :ao_guilds table
      guild_table_existed = :ets.whereis(:ao_guilds) != :undefined

      unless guild_table_existed do
        :ets.new(:ao_guilds, [:named_table, :set, :public])
      end

      on_exit(fn ->
        :ets.delete(:arena_game_data, {:npc, 9901})
        :ets.delete(:arena_game_data, {:npc, 9902})
        # Clean up guild entries
        :ets.delete(:ao_guilds, {:member, :player})
        :ets.delete(:ao_guilds, {:guild, 999})

        unless guild_table_existed do
          :ets.delete(:ao_guilds)
        end
      end)

      :ok
    end

    test "royal army player in armada-aligned guild cannot leave faction" do
      # Player is in royal army and belongs to an armada-aligned guild
      entity = make_entity(%{char_id: :player, faction: :royal_army, x: 50, y: 50, faction_reenlistadas: 0})
      royal_npc = %{npc_id: 9901, x: 51, y: 51, instance_id: :royal_enl}
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{royal_enl: royal_npc})

      # Set up guild membership: player is in an armada-aligned guild
      armada_guild = %{
        id: 999,
        name: "Royal Guard",
        leader: :player,
        founder_id: :player,
        created_at: ~U[2024-01-01 00:00:00Z],
        members: [:player],
        level: 1,
        current_exp: 0,
        description: "",
        news: "",
        url: "",
        alignment: Arena.GuildAlignment.armada()
      }

      :ets.insert(:ao_guilds, {{:guild, 999}, armada_guild})
      :ets.insert(:ao_guilds, {{:member, :player}, 999})

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      # Must NOT leave — leaving would make alignment ciudadana, incompatible with armada guild
      assert new_state.players[:player].faction == :royal_army
      assert new_state.players[:player].faction_reenlistadas == 0
    end

    test "chaos legion player in caotica-aligned guild cannot leave faction" do
      entity = make_entity(%{char_id: :player, faction: :chaos_legion, x: 50, y: 50, faction_reenlistadas: 0})
      chaos_npc = %{npc_id: 9902, x: 51, y: 51, instance_id: :chaos_enl}
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{chaos_enl: chaos_npc})

      # Set up guild membership: player is in a caotica-aligned guild
      caotica_guild = %{
        id: 999,
        name: "Dark Legion",
        leader: :player,
        founder_id: :player,
        created_at: ~U[2024-01-01 00:00:00Z],
        members: [:player],
        level: 1,
        current_exp: 0,
        description: "",
        news: "",
        url: "",
        alignment: Arena.GuildAlignment.caotica()
      }

      :ets.insert(:ao_guilds, {{:guild, 999}, caotica_guild})
      :ets.insert(:ao_guilds, {{:member, :player}, 999})

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      # Must NOT leave — leaving would make alignment ciudadana, incompatible with caotica guild
      assert new_state.players[:player].faction == :chaos_legion
      assert new_state.players[:player].faction_reenlistadas == 0
    end

    test "faction player in neutral guild CAN leave faction" do
      # Player is in royal army and belongs to a neutral guild — should be allowed to leave
      entity = make_entity(%{char_id: :player, faction: :royal_army, x: 50, y: 50, faction_reenlistadas: 0})
      royal_npc = %{npc_id: 9901, x: 51, y: 51, instance_id: :royal_enl}
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{royal_enl: royal_npc})

      # Set up guild membership: player is in a neutral guild
      neutral_guild = %{
        id: 999,
        name: "Adventurers",
        leader: :player,
        founder_id: :player,
        created_at: ~U[2024-01-01 00:00:00Z],
        members: [:player],
        level: 1,
        current_exp: 0,
        description: "",
        news: "",
        url: "",
        alignment: Arena.GuildAlignment.neutral()
      }

      :ets.insert(:ao_guilds, {{:guild, 999}, neutral_guild})
      :ets.insert(:ao_guilds, {{:member, :player}, 999})

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      # SHOULD leave — neutral guilds accept any alignment
      assert new_state.players[:player].faction == :none
      assert new_state.players[:player].faction_reenlistadas == 1
    end

    test "faction player not in any guild CAN leave faction" do
      # Player is in royal army, not in any guild, at own enlistador
      entity = make_entity(%{char_id: :player, faction: :royal_army, x: 50, y: 50, faction_reenlistadas: 0})
      royal_npc = %{npc_id: 9901, x: 51, y: 51, instance_id: :royal_enl}
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{royal_enl: royal_npc})

      # No guild entries in ETS — player is not in a guild

      {:noreply, new_state} = Faction.handle_leave_faction(state, :player)

      # SHOULD leave — no guild restriction
      assert new_state.players[:player].faction == :none
      assert new_state.players[:player].faction_reenlistadas == 1
    end
  end
end
