defmodule Arena.BankTradeParityDriftTest do
  @moduledoc """
  VB6 parity drift tests for bank deposit stack cap (#10),
  trade instransferible item check (#11), and trade newbie item check (#12).
  """

  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.{Bank, Trade}

  import Arena.Test.MapStateFactory

  # High item IDs unlikely to collide with real game data
  @instransferible_item_id 60_001
  @newbie_item_id 60_002
  @stackable_item_id 60_003

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Register synthetic test items directly in ETS so GameData.get_item/1 returns them.
    :ets.insert(:arena_game_data, {
      {:item, @instransferible_item_id},
      %Arena.Data.ItemDef{
        id: @instransferible_item_id,
        name: "TestInstransferible",
        obj_type: 1,
        grh_index: 1,
        stackable: true,
        instransferible: true,
        newbie: false,
        max_hit: 10_000
      }
    })

    :ets.insert(:arena_game_data, {
      {:item, @newbie_item_id},
      %Arena.Data.ItemDef{
        id: @newbie_item_id,
        name: "TestNewbie",
        obj_type: 1,
        grh_index: 1,
        stackable: true,
        instransferible: false,
        newbie: true,
        max_hit: 10_000
      }
    })

    :ets.insert(:arena_game_data, {
      {:item, @stackable_item_id},
      %Arena.Data.ItemDef{
        id: @stackable_item_id,
        name: "TestStackable",
        obj_type: 1,
        grh_index: 1,
        stackable: true,
        instransferible: false,
        newbie: false,
        max_hit: 500
      }
    })

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})
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
      saddle_slot: 0
    }

    Map.merge(defaults, overrides)
  end

  @banker_npc %{npc_id: 1, x: 51, y: 50, instance_id: :banker1}

  defp make_map_state_for_bank(char_id, entity) do
    map_state(
      players: %{char_id => entity},
      sessions: %{char_id => self()},
      npcs_live: %{banker1: @banker_npc},
      occupancy: %{},
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  defp make_map_state_for_trade(players, sessions) do
    map_state(
      players: players,
      sessions: sessions,
      npcs_live: %{},
      occupancy: %{},
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  defp create_test_character! do
    # Create account first
    unique = System.unique_integer([:positive])
    username = "test_bank_#{unique}"

    {:ok, account} =
      %GameBackend.Account{}
      |> Ecto.Changeset.change(%{username: username, password_hash: "fakehash"})
      |> GameBackend.Repo.insert()

    # Create character
    {:ok, character} =
      %GameBackend.Characters{}
      |> GameBackend.Characters.changeset(%{
        name: "BankChar#{unique}",
        account_id: account.id,
        race: "human",
        class: "warrior",
        gender: "male"
      })
      |> GameBackend.Repo.insert()

    character.id
  end

  # Bank stack cap tests are in bank_stack_cap_parity_test.exs

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift #11: Trade allows instransferible items
  # VB6 blocks instransferible items in user-to-user trade.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift #11: trade rejects instransferible items" do
    test "offering an instransferible item in trade is rejected" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{
        item_id: @instransferible_item_id,
        amount: 10,
        equipped: false,
        elemental_tags: 0
      })

      p1 = make_entity(%{
        char_id: :p1,
        trade_partner_id: :p2,
        trade_offer_items: [],
        trade_accepted: false,
        inventory: inv
      })

      p2 = make_entity(%{
        char_id: :p2,
        trade_partner_id: :p1,
        trade_offer_items: [],
        trade_accepted: false
      })

      sessions = %{p1: self(), p2: self()}
      state = make_map_state_for_trade(%{p1: p1, p2: p2}, sessions)

      {:ok, _state, result, _effects} =
        Trade.handle_user_trade_offer(state, :p1, @instransferible_item_id, 5)

      assert result == {:error, :untradeable},
             "Instransferible items should be rejected from trade, got #{inspect(result)}"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift #12: Trade allows newbie items
  # VB6 blocks newbie items in user-to-user trade.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift #12: trade rejects newbie items" do
    test "offering a newbie item in trade is rejected" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{
        item_id: @newbie_item_id,
        amount: 10,
        equipped: false,
        elemental_tags: 0
      })

      p1 = make_entity(%{
        char_id: :p1,
        trade_partner_id: :p2,
        trade_offer_items: [],
        trade_accepted: false,
        inventory: inv
      })

      p2 = make_entity(%{
        char_id: :p2,
        trade_partner_id: :p1,
        trade_offer_items: [],
        trade_accepted: false
      })

      sessions = %{p1: self(), p2: self()}
      state = make_map_state_for_trade(%{p1: p1, p2: p2}, sessions)

      {:ok, _state, result, _effects} =
        Trade.handle_user_trade_offer(state, :p1, @newbie_item_id, 5)

      assert result == {:error, :newbie_item},
             "Newbie items should be rejected from trade, got #{inspect(result)}"
    end
  end
end
