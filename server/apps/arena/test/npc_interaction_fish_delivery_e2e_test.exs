defmodule Arena.Map.NpcInteractionFishDeliveryE2ETest do
  @moduledoc """
  End-to-end tests for the fish-delivery NPC double-click flow through
  `Arena.Map.MapServer.handle_cast({:double_click, ...}, state)`. Pins the
  slice 4 effects migration of `Arena.Map.NpcInteraction.handle_fish_delivery/4`.

  The handler now returns `{:ok, state, effects}` and the switchboard branch
  for `@npc_type_entrega_pesca` wraps it in `Arena.Map.Effects.run_handler/2`.
  Per-slot inventory packets, `update_gold`, and the summary console message
  all flow through `AoSession.Egress.enqueue/2` and arrive in the test pid's
  mailbox as `{:egress, %{payload: <<...>>}}` envelopes — never via
  `{:send_raw, _}`.

  Pattern mirrors `npc_interaction_arena_entry_e2e_test.exs`.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.{MapServer, NpcInteraction}
  alias Arena.Data.GameData
  alias Arena.Data.ItemDef

  import Arena.Test.MapStateFactory

  # VB6: NpcType=20 = entrega pesca
  @npc_type_entrega_pesca 20

  # Test NPC + items
  @fish_npc_id 99_701
  @fish_def %{
    id: @fish_npc_id,
    npc_id: @fish_npc_id,
    name: "EntregaPesca",
    npc_type: @npc_type_entrega_pesca,
    comercia: false,
    shop_items: [],
    quest_numbers: [],
    creatures: []
  }

  @fish_item_id 70_001
  @fish_item_def %ItemDef{
    id: @fish_item_id,
    name: "Pez Especial",
    obj_type: 1,
    grh_index: 1,
    valor: 50,
    puntos_pesca: 10
  }

  @big_fish_item_id 70_002
  @big_fish_item_def %ItemDef{
    id: @big_fish_item_id,
    name: "Pez Gigante",
    obj_type: 1,
    grh_index: 1,
    valor: 200,
    puntos_pesca: 30
  }

  # An item that has puntos_pesca=0 — should never be consumed.
  @nonfish_item_id 70_003
  @nonfish_item_def %ItemDef{
    id: @nonfish_item_id,
    name: "Espada",
    obj_type: 2,
    grh_index: 1,
    valor: 100,
    puntos_pesca: 0
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
      class: :trabajador,
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
    :ets.insert(:arena_game_data, {{:npc, @fish_npc_id}, @fish_def})
    :ets.insert(:arena_game_data, {{:item, @fish_item_id}, @fish_item_def})
    :ets.insert(:arena_game_data, {{:item, @big_fish_item_id}, @big_fish_item_def})
    :ets.insert(:arena_game_data, {{:item, @nonfish_item_id}, @nonfish_item_def})

    drain()

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:npc, @fish_npc_id})
      :ets.delete(:arena_game_data, {:item, @fish_item_id})
      :ets.delete(:arena_game_data, {:item, @big_fish_item_id})
      :ets.delete(:arena_game_data, {:item, @nonfish_item_id})
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

  defp fish_npc, do: %{npc_id: @fish_npc_id, x: 51, y: 50, instance_id: :fish_inst}

  defp build_inventory(items) do
    Enum.reduce(items, List.duplicate(nil, 24), fn {idx, item}, acc ->
      List.replace_at(acc, idx, item)
    end)
  end

  defp state_with(entity_overrides, opts \\ []) do
    entity = make_entity(entity_overrides)

    occupancy = Keyword.get(opts, :occupancy, %{{51, 50} => {:npc, :fish_inst}})

    map_state(
      players: %{player: entity},
      sessions: Keyword.get(opts, :sessions, %{player: self()}),
      npcs_live: Keyword.get(opts, :npcs_live, %{fish_inst: fish_npc()}),
      occupancy: occupancy
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:double_click, _}) — successful fish delivery
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:double_click, ...}) → fish delivery — successful path" do
    test "trabajador with multiple fish: inventory cleared, fishing_points/gold updated, packets fanned in order" do
      inv =
        build_inventory([
          {0, %{item_id: @fish_item_id, amount: 2, equipped: false}},
          {1, %{item_id: @big_fish_item_id, amount: 1, equipped: false}},
          {2, %{item_id: @nonfish_item_id, amount: 1, equipped: false}}
        ])

      state = state_with(%{class: :trabajador, gold: 1_000, fishing_points: 0, inventory: inv})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]

      # 2 fish * 10 + 1 big_fish * 30 = 50 fishing_points
      assert player.fishing_points == 50
      # 2 * 50 + 1 * 200 = 300 gold added
      assert player.gold == 1_300
      assert Enum.at(player.inventory, 0) == nil, "fish slot 0 must be cleared"
      assert Enum.at(player.inventory, 1) == nil, "fish slot 1 must be cleared"

      assert Enum.at(player.inventory, 2) == %{
               item_id: @nonfish_item_id,
               amount: 1,
               equipped: false
             },
             "non-fish slot must NOT be cleared"

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      # Effect ordering: per-slot inventory packets BEFORE update_gold BEFORE
      # the summary console message.
      assert_receive {:egress,
                      %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = console_payload
                      }}

      assert :binary.match(console_payload, "Has entregado peces.") != :nomatch
      assert :binary.match(console_payload, "+50") != :nomatch
      assert :binary.match(console_payload, "+300") != :nomatch

      # Slice 4: legacy shim must NOT appear.
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Adversarial coverage
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_cast({:double_click, ...}) → fish delivery — adversarial" do
    test "wrong class (warrior): rejected with class-restriction message, no mutation" do
      inv =
        build_inventory([{0, %{item_id: @fish_item_id, amount: 1, equipped: false}}])

      state =
        state_with(%{class: :warrior, gold: 1_000, fishing_points: 0, inventory: inv})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert player.gold == 1_000, "gold must NOT change"
      assert player.fishing_points == 0
      assert Enum.at(player.inventory, 0) == %{
               item_id: @fish_item_id,
               amount: 1,
               equipped: false
             }

      console_id = AoProtocol.PacketIds.Server.console_msg()
      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      assert :binary.match(payload, "Solo los trabajadores pueden entregar peces.") != :nomatch

      refute_receive {:egress, %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:send_raw, _}, 50
    end

    test "trabajador with no fish: 'No tienes peces especiales' message, no mutation" do
      inv =
        build_inventory([{0, %{item_id: @nonfish_item_id, amount: 1, equipped: false}}])

      state =
        state_with(%{class: :trabajador, gold: 1_000, fishing_points: 0, inventory: inv})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert player.gold == 1_000
      assert player.fishing_points == 0
      assert player.inventory == inv, "inventory must NOT mutate"

      console_id = AoProtocol.PacketIds.Server.console_msg()
      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert_receive {:egress,
                      %{
                        payload:
                          <<^console_id::little-signed-integer-16, _::binary>> = payload
                      }}

      assert :binary.match(payload, "No tienes peces especiales para entregar.") != :nomatch

      refute_receive {:egress, %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}},
                     50

      refute_receive {:send_raw, _}, 50
    end

    test "mixed inventory: only fish slots cleared, non-fish stays untouched" do
      inv =
        build_inventory([
          {0, %{item_id: @nonfish_item_id, amount: 5, equipped: false}},
          {3, %{item_id: @fish_item_id, amount: 2, equipped: false}},
          {7, %{item_id: @nonfish_item_id, amount: 1, equipped: false}}
        ])

      state =
        state_with(%{class: :trabajador, gold: 1_000, fishing_points: 0, inventory: inv})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert Enum.at(player.inventory, 0) == %{
               item_id: @nonfish_item_id,
               amount: 5,
               equipped: false
             }

      assert Enum.at(player.inventory, 3) == nil
      assert Enum.at(player.inventory, 7) == %{
               item_id: @nonfish_item_id,
               amount: 1,
               equipped: false
             }

      assert player.fishing_points == 20
      assert player.gold == 1_100
    end

    test "item with puntos_pesca == 0: not consumed even if class permits" do
      # nonfish has puntos_pesca: 0 — should be excluded from delivery.
      inv =
        build_inventory([{0, %{item_id: @nonfish_item_id, amount: 3, equipped: false}}])

      state =
        state_with(%{class: :trabajador, gold: 1_000, fishing_points: 0, inventory: inv})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]
      assert player.fishing_points == 0
      assert player.gold == 1_000
      assert player.inventory == inv

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "No tienes peces especiales para entregar.") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "player not in state.players: handler returns {:ok, state, []}" do
      # Direct-call check against the raw handler — this is the only branch
      # the switchboard never enters (the switchboard fetches the entity
      # before dispatch), so we test the contract directly.
      entity = make_entity(%{class: :trabajador})
      state = map_state(players: %{}, sessions: %{player: self()})

      assert {:ok, ^state, []} =
               NpcInteraction.handle_fish_delivery(state, :player, entity, @fish_def)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "effect ordering pinned: per-slot inventory packets, then update_gold, then console" do
      inv =
        build_inventory([
          {2, %{item_id: @fish_item_id, amount: 1, equipped: false}},
          {5, %{item_id: @big_fish_item_id, amount: 1, equipped: false}}
        ])

      state =
        state_with(%{class: :trabajador, gold: 1_000, fishing_points: 0, inventory: inv})

      assert {:noreply, _new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      gold_id = AoProtocol.PacketIds.Server.update_gold()
      console_id = AoProtocol.PacketIds.Server.console_msg()

      # First two messages: inventory packets (one per cleared slot).
      assert_receive {:egress, %{payload: <<id1::little-signed-integer-16, _::binary>>}}
      assert id1 == inv_id, "first envelope must be a change_inventory_slot"

      assert_receive {:egress, %{payload: <<id2::little-signed-integer-16, _::binary>>}}
      assert id2 == inv_id, "second envelope must be a change_inventory_slot"

      # Third: update_gold.
      assert_receive {:egress, %{payload: <<id3::little-signed-integer-16, _::binary>>}}
      assert id3 == gold_id, "third envelope must be update_gold"

      # Fourth: summary console.
      assert_receive {:egress,
                      %{
                        payload: <<id4::little-signed-integer-16, _::binary>> = console_payload
                      }}

      assert id4 == console_id, "fourth envelope must be console_msg"
      assert :binary.match(console_payload, "Has entregado peces.") != :nomatch
    end

    test "stale session (state.sessions[char_id] missing): mutation still happens, no packets land" do
      inv =
        build_inventory([{0, %{item_id: @fish_item_id, amount: 1, equipped: false}}])

      state =
        state_with(
          %{class: :trabajador, gold: 1_000, fishing_points: 0, inventory: inv},
          sessions: %{}
        )

      assert {:noreply, new_state} =
               MapServer.handle_cast({:double_click, :player, 51, 50}, state)

      player = new_state.players[:player]

      # Mutation MUST still happen — handler is char_id-keyed and doesn't
      # depend on the sessions map. The runner is what silently drops the
      # outgoing packets when the session pid is missing.
      assert player.fishing_points == 10
      assert player.gold == 1_050
      assert Enum.at(player.inventory, 0) == nil

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end
end
