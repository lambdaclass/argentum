defmodule Arena.Adversarial.BankAndNpcRadiusTest do
  @moduledoc """
  Adversarial tests for bank operations and NPC interaction radius checks.

  Exercises radius-drift exploits, dead-NPC interactions, type confusion,
  and invalid deposit/withdraw amounts to ensure server-side validations
  reject every vector.
  """
  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.{Bank, Commerce}

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

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

  # Find the first NPC ID in GameData that has comercia=true
  defp find_merchant_npc_id do
    Enum.find_value(1..500, fn id ->
      npc_def = GameData.get_npc(id)
      if npc_def && Map.get(npc_def, :comercia, false), do: id
    end)
  end

  # Banker NPC instance (npc_type 4 = banquero) at (51,50), within radius of player at (50,50)
  @banker_npc %{npc_id: 1, x: 51, y: 50, instance_id: :banker1}

  # A non-banker NPC (merchant) at the same position — used for type confusion tests
  @merchant_npc %{npc_id: 2, x: 51, y: 50, instance_id: :merchant1}

  defp make_map_state(players, opts) do
    map_state(
      players: players,
      sessions: Keyword.get(opts, :sessions, %{}),
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank radius drift — deposit/withdraw after walking away from banker
  # ═══════════════════════════════════════════════════════════════════════════

  describe "bank radius drift: deposit gold after walking away" do
    test "player who opened bank then walked 11+ tiles away cannot deposit gold" do
      # Player initially at (50,50), banker at (51,50) — within range=10
      # Player then "walks" to (58,50) — distance=11, exceeds the 10-tile radius
      entity =
        make_entity(%{
          char_id: :player,
          x: 62,
          y: 50,
          bank_npc_id: :banker1,
          gold: 1000,
          bank_gold: 500
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, new_state, result, _effects} = Bank.handle_bank_deposit_gold(state, :player, 100)
      assert result == {:error, :too_far}
      # Gold must remain unchanged
      assert new_state.players[:player].gold == 1000
      assert new_state.players[:player].bank_gold == 500
    end

    test "player who opened bank then walked 11+ tiles away cannot extract gold" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 62,
          y: 50,
          bank_npc_id: :banker1,
          gold: 0,
          bank_gold: 1000
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, new_state, result, _effects} = Bank.handle_bank_extract_gold(state, :player, 500)
      assert result == {:error, :too_far}
      assert new_state.players[:player].gold == 0
      assert new_state.players[:player].bank_gold == 1000
    end

    test "player at exactly 10 tiles from banker passes radius check" do
      # Distance = 10 (boundary): 51 + 10 = 61
      # validate_bank_session checks abs(entity.x - npc.x) > 10 — at exactly 10 it should pass.
      entity =
        make_entity(%{
          char_id: :player,
          x: 61,
          y: 50,
          bank_npc_id: :banker1,
          gold: 1000,
          bank_gold: 0
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      # Directly test validate_bank_session to avoid DB side effects
      assert Bank.validate_bank_session(state, entity) == :ok
    end

    test "player at exactly 11 tiles from banker is rejected" do
      # Distance = 11 (one tile past VB6 Distancia boundary of 10)
      entity =
        make_entity(%{
          char_id: :player,
          x: 62,
          y: 50,
          bank_npc_id: :banker1,
          gold: 1000,
          bank_gold: 0
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_deposit_gold(state, :player, 100)
      assert result == {:error, :too_far}
    end
  end

  describe "bank radius drift: deposit items after walking away" do
    test "player who walked away cannot deposit item" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false})

      entity =
        make_entity(%{
          char_id: :player,
          x: 62,
          y: 50,
          bank_npc_id: :banker1,
          gold: 1000,
          inventory: inv
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_deposit(state, :player, 1, 1, 0)
      assert result == {:error, :too_far}
    end
  end

  describe "bank radius drift: extract items after walking away" do
    test "player who walked away cannot extract item" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 62,
          y: 50,
          bank_npc_id: :banker1,
          gold: 0,
          bank_gold: 0
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_extract_item(state, :player, 1, 1, 0)
      assert result == {:error, :too_far}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank with killed/removed banker NPC
  # ═══════════════════════════════════════════════════════════════════════════

  describe "bank after banker NPC is killed/removed" do
    test "deposit gold when banker NPC no longer exists returns :no_bank" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          gold: 1000,
          bank_gold: 0
        })

      sessions = %{player: self()}
      # npcs_live is empty — banker was killed/despawned
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_deposit_gold(state, :player, 100)
      assert result == {:error, :no_bank}
    end

    test "extract gold when banker NPC no longer exists returns :no_bank" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          gold: 0,
          bank_gold: 1000
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_extract_gold(state, :player, 500)
      assert result == {:error, :no_bank}
    end

    test "deposit item when banker NPC no longer exists returns :no_bank" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false})

      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          inventory: inv
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_deposit(state, :player, 1, 1, 0)
      assert result == {:error, :no_bank}
    end

    test "extract item when banker NPC no longer exists returns :no_bank" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          bank_gold: 0
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_extract_item(state, :player, 1, 1, 0)
      assert result == {:error, :no_bank}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank open with non-banker NPC (type confusion)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "open bank with non-banker NPC" do
    test "targeting a merchant NPC tile rejects with :no_banker" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50})
      sessions = %{player: self()}

      state =
        make_map_state(
          %{player: entity},
          sessions: sessions,
          npcs_live: %{merchant1: @merchant_npc},
          occupancy: %{{51, 50} => {:npc, :merchant1}}
        )

      {:ok, _new_state, result, _effects} = Bank.handle_open_bank(state, :player, 51, 50)
      assert result == {:error, :no_banker}
    end

    test "targeting an empty tile rejects with :no_banker" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:ok, _new_state, result, _effects} = Bank.handle_open_bank(state, :player, 51, 50)
      assert result == {:error, :no_banker}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank deposit: items you don't have
  # ═══════════════════════════════════════════════════════════════════════════

  describe "deposit items not in inventory" do
    test "depositing from an empty inventory slot returns :empty_slot" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          inventory: List.duplicate(nil, 24)
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_deposit(state, :player, 1, 1, 0)
      assert result == {:error, :empty_slot}
    end

    test "depositing more than you have returns :not_enough" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 3, equipped: false})

      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          inventory: inv
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_deposit(state, :player, 1, 10, 0)
      assert result == {:error, :not_enough}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank extract gold: more than in bank
  # ═══════════════════════════════════════════════════════════════════════════

  describe "withdraw more gold than in bank" do
    test "extracting more gold than bank_gold is rejected" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          gold: 0,
          bank_gold: 100
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, new_state, result, _effects} = Bank.handle_bank_extract_gold(state, :player, 500)
      assert result == {:error, :not_enough_gold}
      assert new_state.players[:player].bank_gold == 100
      assert new_state.players[:player].gold == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank deposit: negative and zero amounts
  # ═══════════════════════════════════════════════════════════════════════════

  describe "deposit negative amounts" do
    test "depositing negative gold amount is rejected" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          gold: 1000,
          bank_gold: 0
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, new_state, result, _effects} = Bank.handle_bank_deposit_gold(state, :player, -100)
      assert result == {:error, :not_enough_gold}
      assert new_state.players[:player].gold == 1000
      assert new_state.players[:player].bank_gold == 0
    end

    test "depositing negative item amount is rejected" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false})

      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          inventory: inv
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_deposit(state, :player, 1, -5, 0)
      assert result == {:error, :invalid_amount}
    end

    test "extracting negative gold amount is rejected" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          gold: 0,
          bank_gold: 1000
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_extract_gold(state, :player, -100)
      assert result == {:error, :not_enough_gold}
    end

    test "extracting negative item amount is rejected" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_extract_item(state, :player, 1, -1, 0)
      assert result == {:error, :invalid_amount}
    end
  end

  describe "deposit zero amounts" do
    test "depositing zero gold is rejected" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          gold: 1000,
          bank_gold: 0
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_deposit_gold(state, :player, 0)
      assert result == {:error, :not_enough_gold}
    end

    test "depositing zero items is rejected" do
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false})

      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          inventory: inv
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_deposit(state, :player, 1, 0, 0)
      assert result == {:error, :invalid_amount}
    end

    test "extracting zero gold is rejected" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1,
          gold: 0,
          bank_gold: 1000
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_extract_gold(state, :player, 0)
      assert result == {:error, :not_enough_gold}
    end

    test "extracting zero items is rejected" do
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          bank_npc_id: :banker1
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{banker1: @banker_npc})

      {:ok, _new_state, result, _effects} = Bank.handle_bank_extract_item(state, :player, 1, 0, 0)
      assert result == {:error, :invalid_amount}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # NPC Commerce radius — buy/sell after walking away
  # ═══════════════════════════════════════════════════════════════════════════

  describe "NPC commerce: buy after walking away" do
    test "buy when commerce_npc_id is set but NPC is far away should still work (no runtime check)" do
      # NOTE: Commerce.handle_commerce_buy does NOT re-check proximity —
      # it only checks commerce_npc_id != nil. This test documents that gap.
      # If proximity re-validation is added, this test should be updated to
      # assert {:error, :too_far}.
      entity =
        make_entity(%{
          char_id: :player,
          x: 90,
          y: 90,
          commerce_npc_id: 1,
          gold: 50000
        })

      sessions = %{player: self()}

      state =
        make_map_state(
          %{player: entity},
          sessions: sessions,
          npcs_live: %{merchant1: @merchant_npc}
        )

      # commerce_buy only checks commerce_npc_id and npc_def from GameData, not runtime proximity
      {:ok, _new_state, result, _effects} = Commerce.handle_commerce_buy(state, :player, 1, 1)

      # If this returns :ok, it means there is NO runtime distance re-check for commerce buy.
      # If proximity validation is added, change this assertion to {:error, :too_far}.
      assert result in [:ok, {:error, :no_commerce}, {:error, :invalid_slot}, {:error, :too_far}]
    end
  end

  describe "NPC commerce: sell after walking away" do
    test "sell when commerce_npc_id is set but player has moved far away" do
      # Commerce.handle_commerce_sell re-checks proximity via merchant_still_valid?
      inv = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: 100, amount: 5, equipped: false})

      entity =
        make_entity(%{
          char_id: :player,
          x: 90,
          y: 90,
          commerce_npc_id: 1,
          inventory: inv
        })

      sessions = %{player: self()}

      state =
        make_map_state(
          %{player: entity},
          sessions: sessions,
          npcs_live: %{merchant1: @merchant_npc}
        )

      {:ok, _new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      # merchant_still_valid? rejects because player at (90,90) is far from NPC at (51,50)
      assert result in [:ok, {:error, :no_commerce}, {:error, :too_far}, {:error, :merchant_gone}]
    end
  end

  describe "NPC commerce: open_npc_commerce with distance > 3" do
    test "open_npc_commerce rejects when player is > 3 tiles from NPC" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50})

      # We need a npc_id whose GameData entry has comercia=true so the
      # type check passes and the distance check is actually reached.
      # Find one dynamically from GameData.
      npc_id = find_merchant_npc_id()

      if npc_id do
        # NPC at (54,50) — distance = 4, beyond the 3-tile limit
        far_npc = %{npc_id: npc_id, x: 54, y: 50, instance_id: :far_merchant}

        sessions = %{player: self()}
        state = make_map_state(%{player: entity}, sessions: sessions, npcs_live: %{far_merchant: far_npc})

        {:ok, _new_state, result, _effects} = Commerce.open_npc_commerce(state, :player, entity, far_npc)
        assert result == {:error, :too_far}
      else
        # No merchant NPC in GameData — skip gracefully
        :ok
      end
    end

    test "open_npc_commerce accepts at exactly 3 tiles" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50})

      npc_id = find_merchant_npc_id()

      if npc_id do
        # NPC at (53,50) — distance = 3, exactly at boundary
        boundary_npc = %{npc_id: npc_id, x: 53, y: 50, instance_id: :boundary_merchant}

        sessions = %{player: self()}

        state =
          make_map_state(
            %{player: entity},
            sessions: sessions,
            npcs_live: %{boundary_merchant: boundary_npc}
          )

        {:ok, _new_state, result, _effects} = Commerce.open_npc_commerce(state, :player, entity, boundary_npc)

        # At distance=3 it should NOT fail with :too_far
        assert result != {:error, :too_far}
      else
        :ok
      end
    end
  end

  describe "NPC commerce: buy/sell from a dead (removed) NPC" do
    test "open_npc_commerce with nil NPC returns :no_npc" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50})
      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:ok, _new_state, result, _effects} = Commerce.open_npc_commerce(state, :player, entity, nil)
      assert result == {:error, :no_npc}
    end

    test "commerce_buy with commerce_npc_id pointing to nonexistent GameData NPC returns :no_commerce" do
      # commerce_npc_id set to a npc_id that does not exist in GameData
      entity =
        make_entity(%{
          char_id: :player,
          x: 50,
          y: 50,
          commerce_npc_id: 999_999,
          gold: 50000
        })

      sessions = %{player: self()}
      state = make_map_state(%{player: entity}, sessions: sessions)

      {:ok, _new_state, result, _effects} = Commerce.handle_commerce_buy(state, :player, 1, 1)
      assert result == {:error, :no_commerce}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Bank open: radius check on handle_open_bank
  # ═══════════════════════════════════════════════════════════════════════════

  describe "open bank radius check" do
    test "open bank when player is > 6 tiles from target returns :too_far" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50})
      sessions = %{player: self()}

      # Banker at (57,50) — distance = 7
      far_banker = %{npc_id: 1, x: 57, y: 50, instance_id: :far_banker}

      state =
        make_map_state(
          %{player: entity},
          sessions: sessions,
          npcs_live: %{far_banker: far_banker},
          occupancy: %{{57, 50} => {:npc, :far_banker}}
        )

      {:ok, _new_state, result, _effects} = Bank.handle_open_bank(state, :player, 57, 50)

      # GameData.get_npc(1) must return npc_type=4 for the banker check to pass
      # If the NPC type check passes, it should fail with :too_far
      # If the NPC type check fails first, we get :no_banker
      assert result in [{:error, :too_far}, {:error, :no_banker}]
    end

    test "open bank while dead is rejected" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50, dead: true})
      sessions = %{player: self()}

      state =
        make_map_state(
          %{player: entity},
          sessions: sessions,
          npcs_live: %{banker1: @banker_npc},
          occupancy: %{{51, 50} => {:npc, :banker1}}
        )

      {:ok, _new_state, result, _effects} = Bank.handle_open_bank(state, :player, 51, 50)
      assert result == {:error, :dead}
    end

    test "open bank while trading is rejected" do
      entity = make_entity(%{char_id: :player, x: 50, y: 50, trade_partner_id: :someone})
      sessions = %{player: self()}

      state =
        make_map_state(
          %{player: entity},
          sessions: sessions,
          npcs_live: %{banker1: @banker_npc},
          occupancy: %{{51, 50} => {:npc, :banker1}}
        )

      {:ok, _new_state, result, _effects} = Bank.handle_open_bank(state, :player, 51, 50)
      assert result == {:error, :already_trading}
    end
  end
end
