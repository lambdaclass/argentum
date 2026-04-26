defmodule Arena.Map.NpcInteractionArenaEntryE2ETest do
  @moduledoc """
  End-to-end tests for the `{:arena_entry, _}` cast through
  `Arena.Map.MapServer.handle_cast/2`. Pins the slice 3 effects migration of
  `Arena.Map.NpcInteraction.handle_arena_entry/2`.

  The handler now returns `{:ok, state, effects}` and the cast routes through
  `Arena.Map.Effects.run_handler/2`. The `:send` effect for `update_gold` flows
  via `Helpers.send_outbound/3` → `AoSession.Egress.enqueue/2` and arrives as
  an `{:egress, %{payload: <<...>>}}` envelope, while the `:transfer` effect
  bypasses Egress and the runner forwards the bare
  `{:transfer, dest_map, dest_x, dest_y, entity}` tuple expected by the
  TCP/WS gateway session handlers.

  Pattern mirrors `npc_interaction_gamble_forgive_e2e_test.exs` and
  `npc_interaction_information_e2e_test.exs`.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.MapServer
  alias Arena.Data.GameData

  import Arena.Test.MapStateFactory

  # VB6: ArenaGuard=24
  @npc_type_arena_guard 24

  # Test NPC ids
  @arena_guard_npc_id 99_801
  @arena_guard_disabled_npc_id 99_802
  @arena_guard_free_npc_id 99_803

  @arena_guard_def %{
    id: @arena_guard_npc_id,
    npc_id: @arena_guard_npc_id,
    name: "ArenaGuard",
    npc_type: @npc_type_arena_guard,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: [],
    arena_enabled: true,
    map_entry_price: 100,
    map_target_entry: 200,
    map_target_entry_x: 50,
    map_target_entry_y: 50
  }

  @arena_guard_disabled_def %{
    id: @arena_guard_disabled_npc_id,
    npc_id: @arena_guard_disabled_npc_id,
    name: "ArenaGuardOff",
    npc_type: @npc_type_arena_guard,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: [],
    arena_enabled: false,
    map_entry_price: 100,
    map_target_entry: 200,
    map_target_entry_x: 50,
    map_target_entry_y: 50
  }

  @arena_guard_free_def %{
    id: @arena_guard_free_npc_id,
    npc_id: @arena_guard_free_npc_id,
    name: "ArenaGuardFree",
    npc_type: @npc_type_arena_guard,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: [],
    arena_enabled: true,
    map_entry_price: 0,
    map_target_entry: 200,
    map_target_entry_x: 50,
    map_target_entry_y: 50
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
    :ets.insert(:arena_game_data, {{:npc, @arena_guard_npc_id}, @arena_guard_def})
    :ets.insert(:arena_game_data, {{:npc, @arena_guard_disabled_npc_id}, @arena_guard_disabled_def})
    :ets.insert(:arena_game_data, {{:npc, @arena_guard_free_npc_id}, @arena_guard_free_def})

    drain()

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, @arena_guard_npc_id})
      :ets.delete(:arena_game_data, {:npc, @arena_guard_disabled_npc_id})
      :ets.delete(:arena_game_data, {:npc, @arena_guard_free_npc_id})
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

  defp arena_guard_npc, do: %{npc_id: @arena_guard_npc_id, x: 51, y: 50, instance_id: :guard_inst}

  defp arena_guard_disabled_npc,
    do: %{npc_id: @arena_guard_disabled_npc_id, x: 51, y: 50, instance_id: :guard_inst}

  defp arena_guard_free_npc,
    do: %{npc_id: @arena_guard_free_npc_id, x: 51, y: 50, instance_id: :guard_inst}

  defp state_with(entity_overrides, npcs_live, opts \\ []) do
    entity = make_entity(entity_overrides)

    map_state(
      players: %{player: entity},
      sessions: Keyword.get(opts, :sessions, %{player: self()}),
      npcs_live: npcs_live
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:arena_entry, _}) — successful path
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:arena_entry, char_id}) — successful path" do
    test "deducts gold, emits update_gold envelope, then bare :transfer tuple in order" do
      state = state_with(%{gold: 5000}, %{guard_inst: arena_guard_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:arena_entry, :player}, state)

      player = new_state.players[:player]
      assert player.gold == 4900, "100 gold must be deducted on successful arena entry"

      gold_id = AoProtocol.PacketIds.Server.update_gold()

      # Effect ordering: update_gold envelope MUST arrive before the bare
      # :transfer tuple. This pins the post-mutation order in the effects
      # list (slice 3 contract).
      assert_receive {:egress,
                      %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}

      # The runner strips char_id and forwards the bare 5-tuple expected by
      # AoTcpGateway.WsHandler / AoTcpGateway.ClientHandler. Note: the entity
      # carried in the tuple is the post-mutation entity (gold already
      # deducted to 4900).
      assert_receive {:transfer, 200, 50, 50, transferred_entity}
      assert transferred_entity.gold == 4900,
             "transferred entity must reflect the post-deduction gold"

      # Pin the legacy shim out — slice 3 must NOT route via {:send_raw, _}.
      refute_receive {:send_raw, _}, 50
    end

    test "free arena (map_entry_price == 0): still succeeds and transfers" do
      state = state_with(%{gold: 100}, %{guard_inst: arena_guard_free_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:arena_entry, :player}, state)

      assert new_state.players[:player].gold == 100,
             "free arena must not change gold (gold - 0 == gold)"

      gold_id = AoProtocol.PacketIds.Server.update_gold()

      # Free arena STILL emits an update_gold packet (success branch is
      # unconditional on price). The :transfer must still fire.
      assert_receive {:egress,
                      %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:transfer, 200, 50, 50, _entity}
      refute_receive {:send_raw, _}, 50
    end

    test "effect ordering: update_gold envelope strictly precedes :transfer tuple" do
      state = state_with(%{gold: 5000}, %{guard_inst: arena_guard_npc()})

      assert {:noreply, _new_state} = MapServer.handle_cast({:arena_entry, :player}, state)

      gold_id = AoProtocol.PacketIds.Server.update_gold()

      # First mailbox message must be the egress envelope.
      assert_receive {:egress,
                      %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}

      # Second must be the bare transfer tuple.
      assert_receive {:transfer, 200, 50, 50, _entity}
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:arena_entry, _}) — adversarial / failure modes
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:arena_entry, _}) — adversarial: handler degrades gracefully" do
    test "no arena guard nearby: graceful console message, no gold deduction, no :transfer" do
      state = state_with(%{gold: 5000}, %{})

      assert {:noreply, new_state} = MapServer.handle_cast({:arena_entry, :player}, state)

      assert new_state.players[:player].gold == 5000, "gold must NOT mutate"

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      assert :binary.match(payload, "No hay un guardia de arena cerca.") != :nomatch

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:transfer, _, _, _, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "arena guard with arena_enabled=false: rejected even though NPC type matches" do
      # The when-guard `npc_def.arena_enabled` in handle_arena_entry filters
      # out guards that exist but are toggled off. resolve_nearby_npc itself
      # does NOT filter on arena_enabled — it only matches npc_type.
      state = state_with(%{gold: 5000}, %{guard_inst: arena_guard_disabled_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:arena_entry, :player}, state)

      assert new_state.players[:player].gold == 5000, "gold must NOT mutate"

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      assert :binary.match(payload, "No hay un guardia de arena cerca.") != :nomatch

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:transfer, _, _, _, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "dead player: rejected with 'Estas muerto!', no gold deduction, no :transfer" do
      state = state_with(%{gold: 5000, dead: true}, %{guard_inst: arena_guard_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:arena_entry, :player}, state)

      assert new_state.players[:player].gold == 5000

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      assert :binary.match(payload, "muerto") != :nomatch

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:transfer, _, _, _, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "insufficient gold: rejected with price message, no deduction, no :transfer" do
      state = state_with(%{gold: 50}, %{guard_inst: arena_guard_npc()})

      assert {:noreply, new_state} = MapServer.handle_cast({:arena_entry, :player}, state)

      assert new_state.players[:player].gold == 50

      console_id = AoProtocol.PacketIds.Server.console_msg()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      assert :binary.match(payload, "Necesitas 100 monedas de oro para entrar.") != :nomatch

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:transfer, _, _, _, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "player not in state.players: returns {:ok, state, []}, no envelopes, no :transfer" do
      # Empty players map → handler hits :error branch → empty effects list.
      state =
        map_state(
          players: %{},
          sessions: %{player: self()},
          npcs_live: %{guard_inst: arena_guard_npc()}
        )

      assert {:noreply, ^state} = MapServer.handle_cast({:arena_entry, :player}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:transfer, _, _, _, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "no session pid for char_id (stale state.sessions): gold deducted, no :transfer delivered" do
      # The state mutation must still happen — the handler is char_id-keyed
      # and unaware of the session map. The runner is what silently drops the
      # transfer when `state.sessions[char_id]` returns nil.
      state =
        state_with(
          %{gold: 5000},
          %{guard_inst: arena_guard_npc()},
          # No session entry for :player.
          sessions: %{}
        )

      assert {:noreply, new_state} = MapServer.handle_cast({:arena_entry, :player}, state)

      assert new_state.players[:player].gold == 4900,
             "gold deduction MUST still happen — handler doesn't depend on sessions"

      # The :send for update_gold also has no destination, so nothing arrives
      # at this test pid; refute everything.
      refute_receive {:egress, _}, 50
      refute_receive {:transfer, _, _, _, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end
end
