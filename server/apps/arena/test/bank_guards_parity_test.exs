defmodule Arena.BankGuardsParityTest do
  @moduledoc """
  VB6 parity: bank-open guards that exist in the VB6 source but were missing
  from the Elixir implementation.

  In VB6 AO, players cannot open the bank when meditating, navigating (sailing),
  or paralyzed — mirroring the same guards that handle_open_commerce already has.
  """

  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.Bank

  import Arena.Test.MapStateFactory

  @npc_type_banquero 4

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────

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

  defp make_map_state_with_banker(player, opts \\ []) do
    banker = Keyword.get(opts, :banker, %{npc_id: 1, x: 51, y: 50, instance_id: :banker1})

    map_state(
      players: %{player: player},
      sessions: %{player: self()},
      npcs_live: %{banker1: banker},
      occupancy: %{{banker.x, banker.y} => {:npc, :banker1}},
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  defp find_banker_npc_id do
    Enum.find_value(1..2000, fn id ->
      case GameData.get_npc(id) do
        %{npc_type: @npc_type_banquero} -> id
        _ -> nil
      end
    end)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # VB6 parity: meditating player cannot open bank
  # ══════════════════════════════════════════════════════════════════════════

  describe "VB6 parity: meditating guard" do
    test "meditating player cannot open bank" do
      banker_npc_id = find_banker_npc_id()
      # Use real banker NPC id if available, else fallback to injected def
      npc_id =
        if banker_npc_id do
          banker_npc_id
        else
          # Inject a banker NPC def into ETS
          :ets.insert(:arena_game_data, {{:npc, 88801}, %{npc_id: 88801, name: "Banquero", npc_type: @npc_type_banquero, comercia: false, shop_items: [], quest_numbers: [], creatures: []}})
          88801
        end

      banker = %{npc_id: npc_id, x: 51, y: 50, instance_id: :banker1}
      entity = make_entity(%{meditating: true})

      state = make_map_state_with_banker(entity, banker: banker)
      flush_mailbox()

      {:reply, result, _new_state} = Bank.handle_open_bank(state, :player, 51, 50)

      assert result == {:error, :meditating},
             "VB6 parity: meditating player must be blocked from opening bank, got: #{inspect(result)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # VB6 parity: navigating (sailing) player cannot open bank
  # ══════════════════════════════════════════════════════════════════════════

  describe "VB6 parity: navigating guard" do
    test "navigating player cannot open bank" do
      banker_npc_id = find_banker_npc_id()

      npc_id =
        if banker_npc_id do
          banker_npc_id
        else
          :ets.insert(:arena_game_data, {{:npc, 88802}, %{npc_id: 88802, name: "Banquero", npc_type: @npc_type_banquero, comercia: false, shop_items: [], quest_numbers: [], creatures: []}})
          88802
        end

      banker = %{npc_id: npc_id, x: 51, y: 50, instance_id: :banker1}
      entity = make_entity(%{navigating: true})

      state = make_map_state_with_banker(entity, banker: banker)
      flush_mailbox()

      {:reply, result, _new_state} = Bank.handle_open_bank(state, :player, 51, 50)

      assert result == {:error, :navigating},
             "VB6 parity: navigating player must be blocked from opening bank, got: #{inspect(result)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # VB6 parity: paralyzed player cannot open bank
  # ══════════════════════════════════════════════════════════════════════════

  describe "VB6 parity: paralyzed guard" do
    test "paralyzed player cannot open bank" do
      banker_npc_id = find_banker_npc_id()

      npc_id =
        if banker_npc_id do
          banker_npc_id
        else
          :ets.insert(:arena_game_data, {{:npc, 88803}, %{npc_id: 88803, name: "Banquero", npc_type: @npc_type_banquero, comercia: false, shop_items: [], quest_numbers: [], creatures: []}})
          88803
        end

      banker = %{npc_id: npc_id, x: 51, y: 50, instance_id: :banker1}
      entity = make_entity(%{paralyzed: true})

      state = make_map_state_with_banker(entity, banker: banker)
      flush_mailbox()

      {:reply, result, _new_state} = Bank.handle_open_bank(state, :player, 51, 50)

      assert result == {:error, :paralyzed},
             "VB6 parity: paralyzed player must be blocked from opening bank, got: #{inspect(result)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Sanity: non-impaired player CAN still open the bank
  # ══════════════════════════════════════════════════════════════════════════

  describe "sanity: normal player can open bank" do
    test "player with no impairments is not rejected by state guards" do
      banker_npc_id = find_banker_npc_id()

      npc_id =
        if banker_npc_id do
          banker_npc_id
        else
          :ets.insert(:arena_game_data, {{:npc, 88804}, %{npc_id: 88804, name: "Banquero", npc_type: @npc_type_banquero, comercia: false, shop_items: [], quest_numbers: [], creatures: []}})
          88804
        end

      banker = %{npc_id: npc_id, x: 51, y: 50, instance_id: :banker1}
      entity = make_entity(%{meditating: false, navigating: false, paralyzed: false})

      state = make_map_state_with_banker(entity, banker: banker)
      flush_mailbox()

      # The call will pass the guards but then fail on DB access because
      # char_id is an atom (:player) in tests. We catch the Ecto error
      # and verify none of the new guards fired.
      result =
        try do
          Bank.handle_open_bank(state, :player, 51, 50)
        rescue
          Ecto.Query.CastError -> :reached_db
        end

      # If we reached the DB, it means the guards did NOT reject the player
      assert result == :reached_db,
             "Normal player should pass state guards and reach DB, got: #{inspect(result)}"
    end
  end
end
