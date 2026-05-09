defmodule Arena.BankPersistenceTest do
  @moduledoc """
  Tests that bank operations enforce DB-first persistence:
  in-memory state is only modified after the DB write succeeds.
  When DB writes fail, in-memory state remains unchanged.

  Uses a synthetic char_id (99_999) with no DB backing so all
  persistence calls fail, verifying the failure path.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arena.Map.Bank
  alias Arena.Data.GameData

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @banker_npc %{npc_id: 1, x: 51, y: 50, instance_id: :banker1}

  defp make_entity(overrides) do
    defaults = %{
      char_id: 99_999,
      name: "BankTester",
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
      bank_npc_id: :banker1,
      bank_gold: 500,
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

  defp make_state(entity) do
    map_state(
      players: %{99_999 => entity},
      sessions: %{99_999 => self()},
      npcs_live: %{banker1: @banker_npc},
      occupancy: %{},
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  # ── Gold deposit: DB failure preserves in-memory state ───────────────────

  describe "gold deposit with DB failure" do
    test "in-memory gold unchanged when save_bank_gold fails" do
      entity = make_entity(%{gold: 1000, bank_gold: 500})
      state = make_state(entity)

      log =
        capture_log(fn ->
          {:ok, new_state, result, _effects} = Bank.handle_bank_deposit_gold(state, 99_999, 200)
          assert result == {:error, :db_error}

          # In-memory state must be unchanged
          assert new_state.players[99_999].gold == 1000
          assert new_state.players[99_999].bank_gold == 500
        end)

      assert log =~ "Bank gold deposit failed"
    end
  end

  # ── Gold extract: DB failure preserves in-memory state ───────────────────

  describe "gold extract with DB failure" do
    test "in-memory gold unchanged when save_bank_gold fails" do
      entity = make_entity(%{gold: 100, bank_gold: 1000})
      state = make_state(entity)

      log =
        capture_log(fn ->
          {:ok, new_state, result, _effects} = Bank.handle_bank_extract_gold(state, 99_999, 500)
          assert result == {:error, :db_error}

          # In-memory state must be unchanged
          assert new_state.players[99_999].gold == 100
          assert new_state.players[99_999].bank_gold == 1000
        end)

      assert log =~ "Bank gold extract failed"
    end
  end

  # ── Item deposit: DB failure preserves inventory ─────────────────────────

  describe "item deposit with DB failure" do
    test "inventory unchanged when upsert_bank_item fails" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 10, equipped: false})
      entity = make_entity(%{inventory: inv})
      state = make_state(entity)

      log =
        capture_log(fn ->
          {:ok, new_state, result, _effects} = Bank.handle_bank_deposit(state, 99_999, 1, 5, 1)
          assert result == {:error, :db_error}

          # Inventory must still have the full 10 items
          assert Enum.at(new_state.players[99_999].inventory, 0).amount == 10
        end)

      assert log =~ "Bank deposit failed"
    end
  end

  # ── Item extract: DB failure preserves inventory ─────────────────────────

  describe "item extract with DB failure" do
    test "inventory unchanged when bank_withdraw fails" do
      entity = make_entity(%{})
      state = make_state(entity)

      log =
        capture_log(fn ->
          # Extract from bank slot 1 — since char_id is fake, withdraw will fail
          {:ok, new_state, result, _effects} = Bank.handle_bank_extract_item(state, 99_999, 1, 5, 0)

          # Should get an error — either :empty_bank_slot (because get_bank returns [])
          # or :db_error if the get_bank call itself fails
          assert result in [{:error, :db_error}, {:error, :empty_bank_slot}]

          # Inventory must remain unchanged (all nils)
          assert new_state.players[99_999].inventory == List.duplicate(nil, 24)
        end)

      # May or may not log depending on which path fails
      _ = log
    end
  end

  # ── Multiple failures don't corrupt state ────────────────────────────────

  describe "sequential failures" do
    test "multiple failed bank operations leave state pristine" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 20, equipped: false})
      entity = make_entity(%{gold: 5000, bank_gold: 3000, inventory: inv})
      state = make_state(entity)

      capture_log(fn ->
        {:ok, state, _, _effects} = Bank.handle_bank_deposit_gold(state, 99_999, 1000)
        {:ok, state, _, _effects} = Bank.handle_bank_extract_gold(state, 99_999, 500)
        {:ok, state, _, _effects} = Bank.handle_bank_deposit(state, 99_999, 1, 5, 1)

        # All operations should have failed — state pristine
        assert state.players[99_999].gold == 5000
        assert state.players[99_999].bank_gold == 3000
        assert Enum.at(state.players[99_999].inventory, 0).amount == 20
      end)
    end
  end
end
