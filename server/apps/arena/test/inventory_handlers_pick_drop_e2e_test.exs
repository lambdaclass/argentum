defmodule Arena.Map.InventoryHandlersPickDropE2ETest do
  @moduledoc """
  End-to-end tests for the pick-up and drop flows through
  `Arena.Map.MapServer.handle_call/3`. Pins the roadmap #4 effects
  migration of `Arena.Map.InventoryHandlers.handle_pick_up/2` and
  `handle_drop_item/4`.

  Both handlers now return `{:ok, state, effects}` and the MapServer
  call branch dispatches via `Arena.Map.Effects.run_handler_call/2`,
  which always replies `:ok` regardless of rejection. Per-slot
  inventory packets, `update_gold`, `object_create` / `object_delete`
  broadcasts, and console messages all flow through
  `AoSession.Egress.enqueue/2` and arrive in the test pid mailbox as
  `{:egress, %AoSession.Outbound{payload: <<...>>}}` envelopes — never
  via the legacy `{:send_raw, _}` shim.

  Pattern mirrors `npc_interaction_fish_delivery_e2e_test.exs`.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.{InventoryHandlers, MapServer}
  alias Arena.Data.{GameData, ItemDef}
  alias AoEntities.PlayerEntity

  import Arena.Test.MapStateFactory

  # ── Test items ─────────────────────────────────────────────────────────

  # Stackable, droppable, non-newbie consumable.
  @apple_id 80_001
  @apple_def %ItemDef{
    id: @apple_id,
    name: "ManzanaTest",
    obj_type: 8,
    grh_index: 100,
    stackable: true,
    valor: 5,
    min_ham: 30,
    intirable: false,
    instransferible: false,
    newbie: false,
    destruye: false
  }

  # Newbie item — drop should be blocked with newbie message.
  @newbie_id 80_002
  @newbie_def %ItemDef{
    id: @newbie_id,
    name: "NewbieTest",
    obj_type: 8,
    grh_index: 101,
    stackable: false,
    valor: 1,
    newbie: true
  }

  # Intirable item — drop blocked with not-throwable message.
  @intirable_id 80_003
  @intirable_def %ItemDef{
    id: @intirable_id,
    name: "IntirableTest",
    obj_type: 2,
    grh_index: 102,
    stackable: false,
    valor: 1,
    intirable: true
  }

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    :ets.insert(:arena_game_data, {{:item, @apple_id}, @apple_def})
    :ets.insert(:arena_game_data, {{:item, @newbie_id}, @newbie_def})
    :ets.insert(:arena_game_data, {{:item, @intirable_id}, @intirable_def})

    drain()

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:item, @apple_id})
      :ets.delete(:arena_game_data, {:item, @newbie_id})
      :ets.delete(:arena_game_data, {:item, @intirable_id})
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

  defp make_player(overrides \\ %{}) do
    defaults = %{
      char_id: :player,
      name: "Tester",
      account_id: "acc_test",
      x: 50,
      y: 50,
      char_index: 1,
      map_id: 1,
      hp: 100,
      max_hp: 100,
      inventory: List.duplicate(nil, 24),
      gold: 0
    }

    struct!(PlayerEntity, Map.merge(defaults, overrides))
  end

  defp build_inventory(items) do
    Enum.reduce(items, List.duplicate(nil, 24), fn {idx, item}, acc ->
      List.replace_at(acc, idx, item)
    end)
  end

  defp state_with(player, opts \\ []) do
    map_state(
      players: %{player.char_id => player},
      sessions: Keyword.get(opts, :sessions, %{player.char_id => self()}),
      ground_items: Keyword.get(opts, :ground_items, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{{player.x, player.y} => {:player, player.char_id}})
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:pick_up, _}) — happy path
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_call({:pick_up, ...}) — successful path" do
    test "pick up gold: gold added, ground cleared, update_gold + object_delete fanned" do
      player = make_player(%{gold: 100})

      state =
        state_with(player,
          ground_items: %{{50, 50} => %{item_id: 12, amount: 250, elemental_tags: 0}}
        )

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:pick_up, :player}, :from, state)

      assert new_state.players[:player].gold == 350
      assert new_state.ground_items == %{}

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      delete_id = AoProtocol.PacketIds.Server.object_delete()

      assert_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<^delete_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
    end

    test "pick up regular item: inventory updated, change_inventory_slot + object_delete fanned" do
      player = make_player()

      state =
        state_with(player,
          ground_items: %{
            {50, 50} => %{item_id: @apple_id, amount: 3, elemental_tags: 0}
          }
        )

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:pick_up, :player}, :from, state)

      inv = new_state.players[:player].inventory
      slot0 = Enum.at(inv, 0)
      assert slot0.item_id == @apple_id
      assert slot0.amount == 3
      assert slot0.equipped == false
      assert new_state.ground_items == %{}

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      delete_id = AoProtocol.PacketIds.Server.object_delete()

      assert_receive {:egress, %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<^delete_id::little-signed-integer-16, _::binary>>}}
    end

    test "effect ordering pinned: change_inventory_slot BEFORE object_delete on item pickup" do
      player = make_player()

      state =
        state_with(player,
          ground_items: %{
            {50, 50} => %{item_id: @apple_id, amount: 1, elemental_tags: 0}
          }
        )

      assert {:reply, :ok, _} =
               MapServer.handle_call({:pick_up, :player}, :from, state)

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      delete_id = AoProtocol.PacketIds.Server.object_delete()

      assert_receive {:egress, %{payload: <<id1::little-signed-integer-16, _::binary>>}}
      assert id1 == inv_id, "first envelope must be change_inventory_slot"

      assert_receive {:egress, %{payload: <<id2::little-signed-integer-16, _::binary>>}}
      assert id2 == delete_id, "second envelope must be object_delete"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:pick_up, _}) — adversarial
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_call({:pick_up, ...}) — adversarial" do
    test "nothing on tile: silent no-op, no packets" do
      player = make_player()
      state = state_with(player, ground_items: %{})

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:pick_up, :player}, :from, state)

      assert new_state == state
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "dead player: silent no-op, no packets" do
      player = make_player(%{dead: true})

      state =
        state_with(player,
          ground_items: %{{50, 50} => %{item_id: @apple_id, amount: 1, elemental_tags: 0}}
        )

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:pick_up, :player}, :from, state)

      assert new_state.ground_items == %{{50, 50} => %{item_id: @apple_id, amount: 1, elemental_tags: 0}}
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:reply, :ok, ^state} =
               MapServer.handle_call({:pick_up, :ghost}, :from, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "inventory full: console message emitted, ground item left in place" do
      full_inv =
        for _slot <- 0..23 do
          %{item_id: @intirable_id, amount: 1, equipped: false}
        end

      player = make_player(%{inventory: full_inv})

      ground = %{{50, 50} => %{item_id: @apple_id, amount: 1, elemental_tags: 0}}
      state = state_with(player, ground_items: ground)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:pick_up, :player}, :from, state)

      assert new_state.ground_items == ground
      assert new_state.players[:player].inventory == full_inv

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "espacio") != :nomatch

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      delete_id = AoProtocol.PacketIds.Server.object_delete()
      refute_receive {:egress, %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}}, 50
      refute_receive {:egress, %{payload: <<^delete_id::little-signed-integer-16, _::binary>>}}, 50
    end

    test "stale session (sessions map missing pid): mutation still happens, no packets land" do
      player = make_player()

      state =
        state_with(player,
          ground_items: %{{50, 50} => %{item_id: @apple_id, amount: 1, elemental_tags: 0}},
          sessions: %{}
        )

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:pick_up, :player}, :from, state)

      # Mutation must still happen; runner silently drops without a session pid.
      slot0 = Enum.at(new_state.players[:player].inventory, 0)
      assert slot0.item_id == @apple_id
      assert slot0.amount == 1
      assert slot0.equipped == false

      assert new_state.ground_items == %{}

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:drop_item, _, _, _}) — happy path
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_call({:drop_item, ...}) — successful path" do
    test "drop item from empty tile: change_inventory_slot + object_create fanned" do
      inv = build_inventory([{0, %{item_id: @apple_id, amount: 5, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 0, 2}, :from, state)

      # 2 of 5 dropped; 3 remain.
      assert Enum.at(new_state.players[:player].inventory, 0) == %{
               item_id: @apple_id,
               amount: 3,
               equipped: false
             }

      ground = Map.get(new_state.ground_items, {50, 50})
      assert ground.item_id == @apple_id
      assert ground.amount == 2

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      create_id = AoProtocol.PacketIds.Server.object_create()

      assert_receive {:egress, %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<^create_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
    end

    test "drop gold (slot 200): update_gold + object_create fanned, gold deducted" do
      player = make_player(%{gold: 5_000})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 200, 1_000}, :from, state)

      assert new_state.players[:player].gold == 4_000

      ground = Map.get(new_state.ground_items, {50, 50})
      assert ground.item_id == 12
      assert ground.amount == 1_000

      gold_id = AoProtocol.PacketIds.Server.update_gold()
      create_id = AoProtocol.PacketIds.Server.object_create()

      assert_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<^create_id::little-signed-integer-16, _::binary>>}}
    end

    test "drop effect ordering pinned: change_inventory_slot BEFORE object_create" do
      inv = build_inventory([{2, %{item_id: @apple_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, _} =
               MapServer.handle_call({:drop_item, :player, 2, 1}, :from, state)

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      create_id = AoProtocol.PacketIds.Server.object_create()

      assert_receive {:egress, %{payload: <<id1::little-signed-integer-16, _::binary>>}}
      assert id1 == inv_id, "first envelope must be change_inventory_slot"

      assert_receive {:egress, %{payload: <<id2::little-signed-integer-16, _::binary>>}}
      assert id2 == create_id, "second envelope must be object_create"
    end

    test "drop more than slot has: clamped to slot amount, fully clears slot" do
      inv = build_inventory([{0, %{item_id: @apple_id, amount: 3, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 0, 100}, :from, state)

      assert Enum.at(new_state.players[:player].inventory, 0) == nil
      ground = Map.get(new_state.ground_items, {50, 50})
      assert ground.amount == 3, "drop amount clamped to inventory amount"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:drop_item, _, _, _}) — adversarial
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_call({:drop_item, ...}) — adversarial" do
    test "drop empty slot: silent no-op (no console, no ground, no inventory packet)" do
      player = make_player()
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 5, 1}, :from, state)

      assert new_state.players[:player].inventory == player.inventory
      assert new_state.ground_items == %{}

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "drop newbie item: blocked with newbie message" do
      inv = build_inventory([{0, %{item_id: @newbie_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 0, 1}, :from, state)

      assert new_state.players[:player].inventory == inv
      assert new_state.ground_items == %{}

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "newbies") != :nomatch
    end

    test "drop intirable item: blocked with not-throwable message" do
      inv = build_inventory([{0, %{item_id: @intirable_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 0, 1}, :from, state)

      assert new_state.players[:player].inventory == inv
      assert new_state.ground_items == %{}

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "no se puede tirar") != :nomatch
    end

    test "drop while dead: silent no-op" do
      inv = build_inventory([{0, %{item_id: @apple_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv, dead: true})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 0, 1}, :from, state)

      assert new_state == state
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "drop while trading: blocked with comerciar message, inventory untouched" do
      inv = build_inventory([{0, %{item_id: @apple_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv, trade_partner_id: 999})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 0, 1}, :from, state)

      assert new_state.players[:player].inventory == inv
      assert new_state.ground_items == %{}

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "comercias") != :nomatch
    end

    test "drop while mounted: blocked with montura message" do
      inv = build_inventory([{0, %{item_id: @apple_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv, mounted: true})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 0, 1}, :from, state)

      assert new_state.players[:player].inventory == inv
      assert new_state.ground_items == %{}

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "montura") != :nomatch
    end

    test "drop gold with insufficient gold: blocked with no-gold console" do
      player = make_player(%{gold: 50})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 200, 100}, :from, state)

      assert new_state.players[:player].gold == 50
      assert new_state.ground_items == %{}

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "suficiente oro") != :nomatch
    end

    test "drop onto tile already holding a different item: blocked with otro objeto message" do
      inv = build_inventory([{0, %{item_id: @apple_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv})

      state =
        state_with(player,
          ground_items: %{
            # Tile is occupied by a different item
            {50, 50} => %{item_id: @intirable_id, amount: 1, elemental_tags: 0}
          }
        )

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:drop_item, :player, 0, 1}, :from, state)

      # Inventory untouched; ground unchanged.
      assert new_state.players[:player].inventory == inv
      assert Map.get(new_state.ground_items, {50, 50}).item_id == @intirable_id

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "Ya hay otro objeto") != :nomatch
    end

    test "drop with missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{:ghost => self()})

      assert {:reply, :ok, ^state} =
               MapServer.handle_call({:drop_item, :ghost, 0, 1}, :from, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "direct handler call returns {:ok, state, []} when player is missing" do
      state = map_state(players: %{}, sessions: %{})

      assert {:ok, ^state, []} = InventoryHandlers.handle_drop_item(state, :ghost, 0, 1)
      assert {:ok, ^state, []} = InventoryHandlers.handle_pick_up(state, :ghost)
    end
  end
end
