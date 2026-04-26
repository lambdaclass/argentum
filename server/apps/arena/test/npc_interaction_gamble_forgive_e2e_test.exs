defmodule Arena.Map.NpcInteractionGambleForgiveE2ETest do
  @moduledoc """
  End-to-end tests for the `{:gamble, ...}` and `{:forgive, ...}` casts through
  `Arena.Map.MapServer.handle_cast/2`. Pins the slice 2 effects migration of
  `Arena.Map.NpcInteraction.handle_gamble/4` and `handle_forgive/3`.

  Both handlers now return `{:ok, state, effects}` and the casts route through
  `Arena.Map.Effects.run_handler/2` → `Effects.run/2` → `Helpers.send_outbound/3`
  → `AoSession.Egress.enqueue/2`. The legacy `{:send_raw, _}` shim must NOT
  appear on the receiving session pid's mailbox; instead, an
  `{:egress, %{payload: <<...>>}}` envelope is delivered.

  Pattern mirrors `npc_interaction_information_e2e_test.exs` (slice 1's e2e file)
  and `effects_e2e_test.exs` (rest/meditate/resucitate).

  Includes adversarial coverage: despawned `last_clicked_npc_instance_id`,
  out-of-range NPC, wrong NPC type, faction member rejection, insufficient
  donation, gamble bounds (amount <= 0, > 5000, insufficient gold), dead
  player on either handler, and effect ordering on a successful gamble.

  Gamble RNG is seeded deterministically via `:rand.seed(:exsss, {1, 2, 3})`
  (first roll = 27 → loss) and `:rand.seed(:exsss, {2, 3, 4})` (first roll = 8
  → win) so win/loss outcomes are pinned per-test.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.MapServer
  alias Arena.Data.GameData

  import Arena.Test.MapStateFactory

  # NPC types
  @npc_type_revividor 1
  @npc_type_banquero 4
  @npc_type_resucitador_newbie 9
  @npc_type_timbero 10

  # Test NPCs
  @timbero_npc_id 99_991
  @priest_npc_id 99_992
  @banker_npc_id 99_993
  @newbie_priest_npc_id 99_994

  @timbero_def %{
    npc_id: @timbero_npc_id,
    name: "Timbero",
    npc_type: @npc_type_timbero,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  @priest_def %{
    npc_id: @priest_npc_id,
    name: "Sacerdote",
    npc_type: @npc_type_revividor,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  @banker_def %{
    npc_id: @banker_npc_id,
    name: "Banquero",
    npc_type: @npc_type_banquero,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  @newbie_priest_def %{
    npc_id: @newbie_priest_npc_id,
    name: "Sacerdote Newbie",
    npc_type: @npc_type_resucitador_newbie,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

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
      gold: 50_000,
      inventory: List.duplicate(nil, 24),
      equipment: %{
        weapon: nil,
        armor: nil,
        shield: nil,
        helmet: nil,
        ring: nil,
        municion: nil,
        saddle: nil
      },
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
      saddle_slot: 0,
      last_clicked_npc_instance_id: nil,
      last_clicked_npc_type: nil
    }

    Map.merge(defaults, overrides)
  end

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    :ets.insert(:arena_game_data, {{:npc, @timbero_npc_id}, @timbero_def})
    :ets.insert(:arena_game_data, {{:npc, @priest_npc_id}, @priest_def})
    :ets.insert(:arena_game_data, {{:npc, @banker_npc_id}, @banker_def})
    :ets.insert(:arena_game_data, {{:npc, @newbie_priest_npc_id}, @newbie_priest_def})

    drain()

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, @timbero_npc_id})
      :ets.delete(:arena_game_data, {:npc, @priest_npc_id})
      :ets.delete(:arena_game_data, {:npc, @banker_npc_id})
      :ets.delete(:arena_game_data, {:npc, @newbie_priest_npc_id})
    end)

    :ok
  end

  defp drain do
    receive do
      _ -> drain()
    after
      10 -> :ok
    end
  end

  defp gamble_state_with(entity_overrides, npcs_live) do
    entity =
      make_entity(
        Map.merge(
          %{
            last_clicked_npc_instance_id: :timbero_inst,
            last_clicked_npc_type: @npc_type_timbero
          },
          entity_overrides
        )
      )

    map_state(
      players: %{player: entity},
      sessions: %{player: self()},
      npcs_live: npcs_live
    )
  end

  defp forgive_state_with(entity_overrides, npcs_live) do
    entity =
      make_entity(
        Map.merge(
          %{
            criminal: true,
            last_clicked_npc_instance_id: :priest_inst,
            last_clicked_npc_type: @npc_type_revividor
          },
          entity_overrides
        )
      )

    map_state(
      players: %{player: entity},
      sessions: %{player: self()},
      npcs_live: npcs_live
    )
  end

  defp timbero_npc, do: %{npc_id: @timbero_npc_id, x: 51, y: 50, instance_id: :timbero_inst}

  defp priest_npc, do: %{npc_id: @priest_npc_id, x: 52, y: 50, instance_id: :priest_inst}

  defp banker_npc, do: %{npc_id: @banker_npc_id, x: 51, y: 50, instance_id: :banker_inst}

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:gamble, _, _}) — full effects pipeline
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:gamble, char_id, amount}) — successful path" do
    test "deterministic loss seed: gold drops, update_gold + console envelopes arrive in order" do
      # Seed `{1, 2, 3}` → first :rand.uniform(100) = 27 → 27 > 10 → LOSS.
      :rand.seed(:exsss, {1, 2, 3})

      state = gamble_state_with(%{gold: 5000}, %{timbero_inst: timbero_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:gamble, :player, 100}, state)

      player = new_state.players[:player]
      assert player.gold == 4900, "100 gold should be deducted on a loss"
      assert player.gamble_losses == 1
      assert player.gamble_wins == 0
      assert player.gamble_plays == 1

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      # Effect ordering: update_gold envelope arrives BEFORE the console message.
      assert_receive {:egress,
                      %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = console_payload
                      }}

      assert :binary.match(console_payload, "perdido") != :nomatch,
             "loss console message must say 'perdido'"

      refute_receive {:send_raw, _}, 50
    end

    test "deterministic win seed: gold rises, update_gold + console envelopes arrive in order" do
      # Seed `{2, 3, 4}` → first :rand.uniform(100) = 8 → 8 <= 10 → WIN.
      :rand.seed(:exsss, {2, 3, 4})

      state = gamble_state_with(%{gold: 5000}, %{timbero_inst: timbero_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:gamble, :player, 100}, state)

      player = new_state.players[:player]
      assert player.gold == 5100, "100 gold should be added on a win"
      assert player.gamble_wins == 1
      assert player.gamble_losses == 0
      assert player.gamble_plays == 1

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = console_payload
                      }}

      assert :binary.match(console_payload, "ganado") != :nomatch,
             "win console message must say 'ganado'"

      refute_receive {:send_raw, _}, 50
    end
  end

  describe "MapServer.handle_cast({:gamble, ...}) — adversarial: handler degrades gracefully" do
    test "despawned last_clicked_npc_instance_id: graceful 'No hay un timbero cerca.', no mutation" do
      :rand.seed(:exsss, {1, 2, 3})

      # Entity points at a stale instance id; npcs_live does NOT contain it.
      entity =
        make_entity(%{
          gold: 5000,
          last_clicked_npc_instance_id: 9999,
          last_clicked_npc_type: @npc_type_timbero
        })

      state = map_state(players: %{player: entity}, sessions: %{player: self()}, npcs_live: %{})

      assert {:noreply, new_state} = MapServer.handle_cast({:gamble, :player, 100}, state)

      assert new_state.players[:player].gold == 5000, "gold must NOT mutate"
      assert new_state.players[:player].gamble_plays == 0

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      assert :binary.match(payload, "No hay un timbero cerca.") != :nomatch

      # Stat-update packet must NOT have been emitted.
      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "selected timbero out of range (>10 tiles): graceful 'no nearby' message, no mutation" do
      :rand.seed(:exsss, {1, 2, 3})

      # Timbero at (62, 50) — 12 tiles away from player at (50, 50).
      far_timbero = %{npc_id: @timbero_npc_id, x: 62, y: 50, instance_id: :timbero_inst}
      state = gamble_state_with(%{gold: 5000}, %{timbero_inst: far_timbero})

      assert {:noreply, new_state} = MapServer.handle_cast({:gamble, :player, 100}, state)

      assert new_state.players[:player].gold == 5000
      assert new_state.players[:player].gamble_plays == 0

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      assert :binary.match(payload, "No hay un timbero cerca.") != :nomatch

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "selected NPC is wrong type (banker, not timbero): graceful 'no nearby' message" do
      :rand.seed(:exsss, {1, 2, 3})

      entity =
        make_entity(%{
          gold: 5000,
          last_clicked_npc_instance_id: :banker_inst,
          last_clicked_npc_type: @npc_type_banquero
        })

      state =
        map_state(
          players: %{player: entity},
          sessions: %{player: self()},
          npcs_live: %{banker_inst: banker_npc()}
        )

      assert {:noreply, new_state} = MapServer.handle_cast({:gamble, :player, 100}, state)

      assert new_state.players[:player].gold == 5000
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      assert :binary.match(payload, "No hay un timbero cerca.") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "amount > 5000: rejected, gold NOT deducted, no update_gold" do
      state = gamble_state_with(%{gold: 50_000}, %{timbero_inst: timbero_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:gamble, :player, 5001}, state)

      assert new_state.players[:player].gold == 50_000
      assert new_state.players[:player].gamble_plays == 0

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "maxima es 5000") != :nomatch

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "amount <= 0: rejected, gold NOT deducted, no update_gold" do
      state = gamble_state_with(%{gold: 50_000}, %{timbero_inst: timbero_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:gamble, :player, 0}, state)

      assert new_state.players[:player].gold == 50_000
      assert new_state.players[:player].gamble_plays == 0

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "mayor a 0") != :nomatch
      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "insufficient gold: rejected, no mutation, no update_gold" do
      state = gamble_state_with(%{gold: 50}, %{timbero_inst: timbero_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:gamble, :player, 100}, state)

      assert new_state.players[:player].gold == 50

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "No tienes suficiente oro") != :nomatch
      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "dead player: rejected, no mutation, no update_gold" do
      state = gamble_state_with(%{gold: 5000, dead: true}, %{timbero_inst: timbero_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:gamble, :player, 100}, state)

      assert new_state.players[:player].gold == 5000

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "muerto") != :nomatch
      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:forgive, _, _}) — full effects pipeline
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:forgive, char_id, gold_amount}) — successful path" do
    test "criminal near priest with sufficient donation: criminal cleared, gold deducted, envelopes arrive in order" do
      state =
        forgive_state_with(
          %{gold: 50_000, citizens_killed: 0},
          %{priest_inst: priest_npc()}
        )

      assert {:noreply, new_state} = MapServer.handle_cast({:forgive, :player, 2500}, state)

      player = new_state.players[:player]
      refute player.criminal, "criminal flag must be cleared"
      assert player.gold == 47_500, "gold must drop by donation amount"

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = console_payload
                      }}

      assert :binary.match(console_payload, "Has sido perdonado.") != :nomatch
      refute_receive {:send_raw, _}, 50
    end
  end

  describe "MapServer.handle_cast({:forgive, ...}) — adversarial: handler degrades gracefully" do
    test "despawned last_clicked_npc_instance_id: graceful 'Necesitas estar cerca de un sacerdote.', no mutation" do
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          last_clicked_npc_instance_id: 9999,
          last_clicked_npc_type: @npc_type_revividor
        })

      state = map_state(players: %{player: entity}, sessions: %{player: self()}, npcs_live: %{})

      assert {:noreply, new_state} = MapServer.handle_cast({:forgive, :player, 5000}, state)

      assert new_state.players[:player].criminal == true, "criminal flag must NOT be cleared"
      assert new_state.players[:player].gold == 50_000, "gold must NOT mutate"

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "Necesitas estar cerca de un sacerdote.") != :nomatch

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "selected priest out of range (>3 tiles): graceful 'no nearby priest', no mutation" do
      far_priest = %{npc_id: @priest_npc_id, x: 54, y: 50, instance_id: :priest_inst}

      state =
        forgive_state_with(
          %{gold: 50_000},
          %{priest_inst: far_priest}
        )

      assert {:noreply, new_state} = MapServer.handle_cast({:forgive, :player, 5000}, state)

      assert new_state.players[:player].criminal == true
      assert new_state.players[:player].gold == 50_000

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "Necesitas estar cerca de un sacerdote.") != :nomatch

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "selected NPC is wrong type (banker, not priest): graceful 'no nearby priest'" do
      entity =
        make_entity(%{
          criminal: true,
          gold: 50_000,
          last_clicked_npc_instance_id: :banker_inst,
          last_clicked_npc_type: @npc_type_banquero
        })

      state =
        map_state(
          players: %{player: entity},
          sessions: %{player: self()},
          npcs_live: %{banker_inst: banker_npc()}
        )

      assert {:noreply, new_state} = MapServer.handle_cast({:forgive, :player, 5000}, state)

      assert new_state.players[:player].criminal == true
      assert new_state.players[:player].gold == 50_000

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "Necesitas estar cerca de un sacerdote.") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "faction member (royal_army): rejected with 'No puedo aceptar tu donacion en este momento.'" do
      state =
        forgive_state_with(
          %{gold: 50_000, faction: :royal_army},
          %{priest_inst: priest_npc()}
        )

      assert {:noreply, new_state} = MapServer.handle_cast({:forgive, :player, 5000}, state)

      assert new_state.players[:player].criminal == true
      assert new_state.players[:player].gold == 50_000

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "No puedo aceptar tu donacion en este momento.") != :nomatch
      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "faction member (chaos_legion): rejected even when criminal and near priest" do
      state =
        forgive_state_with(
          %{gold: 50_000, faction: :chaos_legion},
          %{priest_inst: priest_npc()}
        )

      assert {:noreply, new_state} = MapServer.handle_cast({:forgive, :player, 5000}, state)

      assert new_state.players[:player].criminal == true
      assert new_state.players[:player].gold == 50_000

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "No puedo aceptar tu donacion en este momento.") != :nomatch
      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "insufficient donation: gold NOT deducted, criminal flag NOT cleared, no update_gold" do
      state =
        forgive_state_with(
          %{gold: 50_000, citizens_killed: 0},
          %{priest_inst: priest_npc()}
        )

      # Donation 100 < 2500 threshold (citizens_killed = 0 → costo / 2 = 2500).
      assert {:noreply, new_state} = MapServer.handle_cast({:forgive, :player, 100}, state)

      assert new_state.players[:player].criminal == true
      assert new_state.players[:player].gold == 50_000

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "avara") != :nomatch
      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "dead player on forgive: rejected, no mutation, no update_gold" do
      state =
        forgive_state_with(
          %{gold: 50_000, dead: true},
          %{priest_inst: priest_npc()}
        )

      assert {:noreply, new_state} = MapServer.handle_cast({:forgive, :player, 5000}, state)

      assert new_state.players[:player].criminal == true
      assert new_state.players[:player].gold == 50_000

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "muerto") != :nomatch
      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "non-criminal forgive attempt: rejected with 'No eres un criminal.', no mutation" do
      state =
        forgive_state_with(
          %{gold: 50_000, criminal: false},
          %{priest_inst: priest_npc()}
        )

      assert {:noreply, new_state} = MapServer.handle_cast({:forgive, :player, 5000}, state)

      assert new_state.players[:player].gold == 50_000

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "No eres un criminal.") != :nomatch
      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:send_raw, _}, 50
    end
  end
end
