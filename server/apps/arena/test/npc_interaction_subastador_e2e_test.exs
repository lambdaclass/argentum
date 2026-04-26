defmodule Arena.Map.NpcInteractionSubastadorE2ETest do
  @moduledoc """
  End-to-end tests for the auctioneer NPC double-click flow through
  `Arena.Map.MapServer.handle_cast({:double_click, ...}, state)`. Pins the
  slice 4 effects migration of `Arena.Map.NpcInteraction.handle_subastador_click/4`.

  The handler now returns `{:ok, state, effects}`. The `:ok` branch removes
  the player's ground item from `state.ground_items` BEFORE the runner fires
  `Effects.broadcast_visible_all/3` for the `object_delete` packet — visibility
  lookups in the runner happen against post-handler state. All console
  messages flow as `Effects.send/3` envelopes via `AoSession.Egress.enqueue/2`.

  Pattern mirrors `npc_interaction_arena_entry_e2e_test.exs`.

  The shared `Arena.Auction` GenServer is reset between tests via
  `:sys.replace_state/2` so each test starts from a clean state.
  """

  use ExUnit.Case, async: false

  alias Arena.Auction
  alias Arena.Map.{MapServer, NpcInteraction}
  alias Arena.Data.GameData

  import Arena.Test.MapStateFactory

  # VB6: NpcType=16 = subastador
  @npc_type_subastador 16

  @subastador_npc_id 99_801
  @subastador_def %{
    id: @subastador_npc_id,
    npc_id: @subastador_npc_id,
    name: "Subastador",
    npc_type: @npc_type_subastador,
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
      gold: 1_000,
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
    :ets.insert(:arena_game_data, {{:npc, @subastador_npc_id}, @subastador_def})

    # Reset the singleton auction's state so each test starts from idle.
    reset_auction()

    drain()

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, @subastador_npc_id})
      reset_auction()
    end)

    :ok
  end

  defp reset_auction do
    case Process.whereis(Arena.Auction) do
      nil ->
        :ok

      pid ->
        :sys.replace_state(pid, fn state ->
          if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
          if state.initiate_timer_ref, do: Process.cancel_timer(state.initiate_timer_ref)

          %{
            state
            | active: false,
              pending: false,
              item_id: nil,
              item_amount: nil,
              initial_offer: nil,
              best_offer: 0,
              seller_id: nil,
              buyer_id: nil,
              had_bid: false,
              time_remaining: 0,
              possible_cancel: false,
              timer_ref: nil,
              initiate_timer_ref: nil
          }
        end)

        :ok
    end
  end

  defp drain do
    receive do
      _ -> drain()
    after
      10 -> :ok
    end
  end

  defp subastador_npc, do: %{npc_id: @subastador_npc_id, x: 51, y: 50, instance_id: :sub_inst}

  defp ground_item, do: %{item_id: 42, amount: 1, elemental_tags: 0}

  defp state_with(entity_overrides, opts \\ []) do
    entity = make_entity(entity_overrides)

    occupancy = Keyword.get(opts, :occupancy, %{{51, 50} => {:npc, :sub_inst}})

    map_state(
      players: %{player: entity},
      sessions: Keyword.get(opts, :sessions, %{player: self()}),
      npcs_live: Keyword.get(opts, :npcs_live, %{sub_inst: subastador_npc()}),
      ground_items: Keyword.get(opts, :ground_items, %{{50, 50} => ground_item()}),
      occupancy: occupancy,
      visibility_mode: :global
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:double_click, _}) — successful auction initiate
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:double_click, ...}) → subastador — successful path" do
    test ":ok branch: ground item removed, broadcast_visible_all delete fires, console arrives" do
      state = state_with(%{})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      assert Map.get(new_state.ground_items, {50, 50}) == nil,
             "ground item must be removed from state.ground_items"

      delete_id = AoProtocol.PacketIds.Server.object_delete()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      # Effect ordering: state mutation already applied; broadcast_visible_all
      # for object_delete fires first, then the console message.
      assert_receive {:egress,
                      %{payload: <<^delete_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = console_payload
                      }}

      assert :binary.match(console_payload, "/OFERTAINICIAL") != :nomatch
      assert :binary.match(console_payload, "15 segundos") != :nomatch

      refute_receive {:send_raw, _}, 50
    end

    test "broadcast_object_delete fans to peers via Egress (option (b) wiring)" do
      origin = self()

      peer_pid =
        spawn_link(fn ->
          loop = fn loop ->
            receive do
              {:egress, env} ->
                Kernel.send(origin, {:peer_egress, env})
                loop.(loop)

              other ->
                Kernel.send(origin, {:peer_other, other})
                loop.(loop)
            end
          end

          loop.(loop)
        end)

      entity = make_entity(%{})
      peer = make_entity(%{char_id: :peer, char_index: 2, x: 49, y: 50})

      state =
        map_state(
          players: %{player: entity, peer: peer},
          sessions: %{player: origin, peer: peer_pid},
          npcs_live: %{sub_inst: subastador_npc()},
          ground_items: %{{50, 50} => ground_item()},
          occupancy: %{{51, 50} => {:npc, :sub_inst}},
          visibility_mode: :global
        )

      assert {:noreply, _} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      delete_id = AoProtocol.PacketIds.Server.object_delete()

      # Origin gets the broadcast_visible_all (broadcast_visible_all includes
      # origin) and the unicast console.
      assert_receive {:egress,
                      %{payload: <<^delete_id::little-signed-integer-16, _::binary>>}}

      # Peer also gets the broadcast_visible_all delete envelope via Egress.
      assert_receive {:peer_egress,
                      %{payload: <<^delete_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:peer_other, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Adversarial / failure modes
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:double_click, ...}) → subastador — adversarial" do
    test ":auction_in_progress: console message, ground item NOT removed, no broadcast" do
      # Pre-seed: another seller already pending with a different char_id.
      :ok = Auction.initiate(:other_seller, %{item_id: 99, amount: 1})

      state = state_with(%{})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      assert Map.get(new_state.ground_items, {50, 50}) == ground_item(),
             "ground item must NOT be removed when auction is in progress"

      delete_id = AoProtocol.PacketIds.Server.object_delete()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "espera tu turno") != :nomatch

      refute_receive {:egress, %{payload: <<^delete_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:send_raw, _}, 50
    end

    test ":already_initiating: same player initiated twice, console message, no mutation" do
      # First click: enters pending state.
      state = state_with(%{})
      assert {:noreply, mid_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      # Drain envelopes from the first click before the second.
      drain()

      # Second click — same seller, ground item already removed but the
      # auction is still pending → :already_initiating branch.
      # Re-add a ground item to confirm it's NOT removed by the second click.
      mid_state = %{mid_state | ground_items: %{{50, 50} => ground_item()}}

      assert {:noreply, after_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, mid_state)

      assert Map.get(after_state.ground_items, {50, 50}) == ground_item(),
             "ground item must NOT be removed on :already_initiating branch"

      delete_id = AoProtocol.PacketIds.Server.object_delete()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "Ya estas preparando una subasta") != :nomatch

      refute_receive {:egress, %{payload: <<^delete_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:send_raw, _}, 50
    end

    test ":no_item: 'Bribon!' message, no mutation, no broadcast" do
      # No ground items at all — Auction.initiate returns {:error, :no_item}.
      state = state_with(%{}, ground_items: %{})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      assert new_state.ground_items == %{}

      delete_id = AoProtocol.PacketIds.Server.object_delete()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "Bribon!") != :nomatch

      refute_receive {:egress, %{payload: <<^delete_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:send_raw, _}, 50
    end

    test "effect ordering: state mutation precedes the broadcast_visible_all delete" do
      # Direct-call check on the handler so we can inspect the returned
      # effects list shape. This pins that the ground item is removed
      # in the returned state BEFORE the broadcast effect fires.
      state =
        state_with(%{})

      entity = state.players[:player]

      assert {:ok, new_state, effects} =
               NpcInteraction.handle_subastador_click(state, :player, entity, @subastador_def)

      # State mutation: ground item gone.
      assert Map.get(new_state.ground_items, {50, 50}) == nil

      # The first effect is the broadcast_visible_all carrying object_delete,
      # the second is the unicast console message.
      assert [
               {:broadcast_visible_all, 50, 50, %{payload: bv_payload}},
               {:send, :player, %{payload: console_payload}}
             ] = effects

      delete_id = AoProtocol.PacketIds.Server.object_delete()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert <<^delete_id::little-signed-integer-16, _::binary>> = bv_payload
      assert <<^console_id::little-signed-integer-16, _::binary>> = console_payload
    end

    test "player not in state.players: handler returns {:ok, state, []}" do
      # Direct-call check — the switchboard never enters this branch (it
      # fetches the entity beforehand), so we test the handler contract.
      entity = make_entity(%{})
      state = map_state(players: %{}, sessions: %{player: self()})

      assert {:ok, ^state, []} =
               NpcInteraction.handle_subastador_click(
                 state,
                 :player,
                 entity,
                 @subastador_def
               )

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end
end
