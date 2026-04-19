defmodule Arena.GamblePerdonDriftTest do
  @moduledoc """
  VB6 parity drift tests for gambling and /PERDON mechanics.

  Drift #17 — Gambling win rate is wrong.
    Current: 50/50 (:rand.uniform(2) == 1)
    VB6:     10% win rate (RandomNumber(1, 100) <= 10)

  Drift #16 — /PERDON is the wrong mechanic.
    Current: Clears criminal for free near any priest, no gold required.
    VB6:     Requires gold donation, range <= 3, faction checks,
             donation threshold based on ciudadanosMatados, gold deduction.
  """
  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.NpcInteraction

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp make_entity(overrides \\ %{}) do
    Map.merge(
      %{
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
        gold: 50_000,
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
        gm_level: nil,
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
        saddle_slot: 0,
        guild_id: 0,
        guild_level: 0,
        last_clicked_npc_instance_id: nil,
        last_clicked_npc_type: nil
      },
      overrides
    )
  end

  defp make_map_state_from(players, opts \\ []) do
    map_state(
      players: players,
      sessions: Keyword.get(opts, :sessions, %{}),
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  # Timbero NPC for gambling tests
  @timbero_npc %{npc_id: 99999, x: 51, y: 50, instance_id: :timbero_inst}
  @timbero_def %{
    npc_id: 99999,
    name: "Timbero",
    npc_type: 6,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  # Priest NPC for forgive tests — within range 3
  @priest_npc %{npc_id: 99998, x: 52, y: 50, instance_id: :priest_inst}
  @priest_def %{
    npc_id: 99998,
    name: "Sacerdote",
    npc_type: 1,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  # Priest NPC far away — at range 4 (> 3)
  @priest_npc_far %{npc_id: 99998, x: 54, y: 50, instance_id: :priest_far_inst}

  setup do
    :ets.insert(:arena_game_data, {{:npc, 99999}, @timbero_def})
    :ets.insert(:arena_game_data, {{:npc, 99998}, @priest_def})
    flush_mailbox()
    :ok
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # ==================================================================
  # Drift #17: Gambling win rate is 50% instead of VB6's 10%
  # ==================================================================

  describe "Drift #17: gambling win rate must be ~10%, not 50%" do
    test "gamble is rejected when timbero is nearby but not selected" do
      entity = make_entity(%{gold: 5_000})

      state =
        make_map_state_from(
          %{player: entity},
          sessions: %{player: self()},
          npcs_live: %{timbero_inst: @timbero_npc}
        )

      {:noreply, new_state} = NpcInteraction.handle_gamble(state, :player, 100, nil)

      assert new_state.players[:player].gold == 5_000
      assert new_state.players[:player].gamble_plays == 0
    end

    test "over 1000 gambles, win rate is approximately 10% (not 50%)" do
      entity =
        make_entity(%{
          gold: 5_000_000,
          last_clicked_npc_instance_id: :timbero_inst,
          last_clicked_npc_type: 6
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{timbero_inst: @timbero_npc}
      )

      # Run 1000 gambles and count wins
      :rand.seed(:exsss, {42, 84, 126})

      {wins, _} =
        Enum.reduce(1..1000, {0, state}, fn _i, {win_count, s} ->
          flush_mailbox()
          {:noreply, new_state} = NpcInteraction.handle_gamble(s, :player, 100, nil)
          new_gold = new_state.players[:player].gold
          old_gold = s.players[:player].gold

          won = new_gold > old_gold

          # Reset gold for next iteration so we don't run out
          reset_entity = %{new_state.players[:player] | gold: 5_000_000}
          reset_state = %{new_state | players: Map.put(new_state.players, :player, reset_entity)}

          {if(won, do: win_count + 1, else: win_count), reset_state}
        end)

      win_rate = wins / 1000

      # VB6 = 10% win rate. With 1000 trials, expect ~100 wins.
      # Allow range 5%-18% to be safe against random variance.
      assert win_rate >= 0.05 and win_rate <= 0.18,
             "Win rate #{Float.round(win_rate * 100, 1)}% should be ~10% (VB6 parity), not ~50%"
    end
  end

  # ==================================================================
  # Drift #16: /PERDON clears criminal for free, missing gold/checks
  # ==================================================================

  describe "Drift #16: /PERDON requires gold donation (not free)" do
    test "handle_forgive requires gold amount argument" do
      # VB6 HandleDonateGold takes a gold amount. The Elixir handler
      # must now accept (state, char_id, gold_amount).
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          citizens_killed: 0,
          last_clicked_npc_instance_id: :priest_inst,
          last_clicked_npc_type: 1
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{priest_inst: @priest_npc}
      )

      # The 3-arity call should work; old 2-arity should no longer exist
      # or should reject with a message since no gold is provided.
      # VB6 CostoPerdonPorCiudadano = 5000, no citizens killed → donation = 5000/2 = 2500
      {:noreply, new_state} = NpcInteraction.handle_forgive(state, :player, 2500)
      assert new_state.players[:player].criminal == false,
             "Criminal should be cleared when sufficient gold is donated"
    end

    test "forgive deducts gold from player" do
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          citizens_killed: 0,
          last_clicked_npc_instance_id: :priest_inst,
          last_clicked_npc_type: 1
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{priest_inst: @priest_npc}
      )

      {:noreply, new_state} = NpcInteraction.handle_forgive(state, :player, 3000)
      # VB6: gold is deducted by the donated amount
      assert new_state.players[:player].gold == 50_000 - 3000
    end

    test "forgive rejected when donated gold is below threshold (citizens_killed > 0)" do
      # VB6: donation = citizens_killed * GoldMult * CostoPerdonPorCiudadano
      # With citizens_killed = 5, GoldMult = 1, CostoPorCiudadano = 5000 → 25000 required
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          citizens_killed: 5,
          last_clicked_npc_instance_id: :priest_inst,
          last_clicked_npc_type: 1
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{priest_inst: @priest_npc}
      )

      # Donate less than threshold
      {:noreply, new_state} = NpcInteraction.handle_forgive(state, :player, 1000)
      assert new_state.players[:player].criminal == true,
             "Criminal should NOT be cleared when donation is below threshold"
      # Gold should not be deducted either
      assert new_state.players[:player].gold == 50_000
    end

    test "forgive rejected when donated gold is below threshold (citizens_killed == 0)" do
      # VB6: donation = CostoPerdonPorCiudadano / 2 = 2500
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          citizens_killed: 0,
          last_clicked_npc_instance_id: :priest_inst,
          last_clicked_npc_type: 1
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{priest_inst: @priest_npc}
      )

      {:noreply, new_state} = NpcInteraction.handle_forgive(state, :player, 100)
      assert new_state.players[:player].criminal == true,
             "Criminal should NOT be cleared when donation is below 2500 threshold"
      assert new_state.players[:player].gold == 50_000
    end

    test "forgive rejected when player has insufficient gold" do
      entity =
        make_entity(%{
          criminal: true,
          gold: 100,
          citizens_killed: 0,
          last_clicked_npc_instance_id: :priest_inst,
          last_clicked_npc_type: 1
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{priest_inst: @priest_npc}
      )

      {:noreply, new_state} = NpcInteraction.handle_forgive(state, :player, 2500)
      assert new_state.players[:player].criminal == true
      assert new_state.players[:player].gold == 100
    end

    test "forgive blocked for :royal_army faction" do
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          faction: :royal_army,
          last_clicked_npc_instance_id: :priest_inst,
          last_clicked_npc_type: 1
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{priest_inst: @priest_npc}
      )

      {:noreply, new_state} = NpcInteraction.handle_forgive(state, :player, 5000)
      assert new_state.players[:player].criminal == true,
             "Royal army members cannot be forgiven via /PERDON"
    end

    test "forgive blocked for :chaos_legion faction" do
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          faction: :chaos_legion,
          last_clicked_npc_instance_id: :priest_inst,
          last_clicked_npc_type: 1
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{priest_inst: @priest_npc}
      )

      {:noreply, new_state} = NpcInteraction.handle_forgive(state, :player, 5000)
      assert new_state.players[:player].criminal == true,
             "Chaos legion members cannot be forgiven via /PERDON"
    end

    test "forgive blocked when priest is too far (range > 3)" do
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          citizens_killed: 0,
          last_clicked_npc_instance_id: :priest_far_inst,
          last_clicked_npc_type: 1
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{priest_far_inst: @priest_npc_far}
      )

      {:noreply, new_state} = NpcInteraction.handle_forgive(state, :player, 5000)
      assert new_state.players[:player].criminal == true,
             "Priest at distance 4 should be too far for /PERDON (VB6 range <= 3)"
    end

    test "forgive works when priest is within range 3" do
      # Priest at (52, 50), player at (50, 50) → distance 2, within range 3
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          citizens_killed: 0,
          last_clicked_npc_instance_id: :priest_inst,
          last_clicked_npc_type: 1
        })
      state = make_map_state_from(
        %{player: entity},
        sessions: %{player: self()},
        npcs_live: %{priest_inst: @priest_npc}
      )

      {:noreply, new_state} = NpcInteraction.handle_forgive(state, :player, 2500)
      assert new_state.players[:player].criminal == false
    end
  end
end
