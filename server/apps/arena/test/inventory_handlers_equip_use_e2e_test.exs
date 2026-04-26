defmodule Arena.Map.InventoryHandlersEquipUseE2ETest do
  @moduledoc """
  End-to-end tests for the equip and use flows through
  `Arena.Map.MapServer.handle_call/3`. Pins the roadmap #4 effects
  migration of `Arena.Map.InventoryHandlers.handle_equip_item/3` and
  `handle_use_item/3,5`.

  Both handlers now return `{:ok, state, effects}` and the MapServer
  call branches dispatch via `Arena.Map.Effects.run_handler_call/2`,
  which always replies `:ok` regardless of rejection. Per-slot
  inventory packets, `character_change` broadcasts, hp/mana/stamina
  updates, hunger/thirst updates, and console rejection messages all
  flow through `AoSession.Egress.enqueue/2` and arrive in the test pid
  mailbox as `{:egress, %AoSession.Outbound{payload: <<...>>}}`
  envelopes — never via the legacy `{:send_raw, _}` shim.

  Pattern mirrors `inventory_handlers_pick_drop_e2e_test.exs`.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.{InventoryHandlers, MapServer}
  alias Arena.Data.{GameData, ItemDef}
  alias AoEntities.PlayerEntity

  import Arena.Test.MapStateFactory

  # ── Test items ─────────────────────────────────────────────────────────

  # Equippable sword (no level / class restrictions).
  @sword_id 81_001
  @sword_def %ItemDef{
    id: @sword_id,
    name: "EspadaTest",
    obj_type: 2,
    grh_index: 200,
    equip_slot: :weapon,
    valor: 100,
    min_elv: 0
  }

  # Equippable shield (used to pin two-handed unequip behavior).
  @shield_id 81_002
  @shield_def %ItemDef{
    id: @shield_id,
    name: "EscudoTest",
    obj_type: 4,
    grh_index: 201,
    equip_slot: :shield,
    valor: 50
  }

  # Two-handed weapon — equipping should auto-unequip the shield.
  @two_handed_id 81_003
  @two_handed_def %ItemDef{
    id: @two_handed_id,
    name: "EspadaDosManosTest",
    obj_type: 2,
    grh_index: 202,
    equip_slot: :weapon,
    dos_manos: true,
    valor: 200
  }

  # High-level item: requires level 50.
  @high_level_id 81_004
  @high_level_def %ItemDef{
    id: @high_level_id,
    name: "EquipoEliteTest",
    obj_type: 2,
    grh_index: 203,
    equip_slot: :weapon,
    min_elv: 50
  }

  # Non-equippable junk (no equip_slot).
  @junk_id 81_005
  @junk_def %ItemDef{
    id: @junk_id,
    name: "PiedraTest",
    obj_type: 2,
    grh_index: 204,
    equip_slot: nil
  }

  # HP potion.
  @hp_potion_id 82_001
  @hp_potion_def %ItemDef{
    id: @hp_potion_id,
    name: "PocionVidaTest",
    obj_type: 1,
    grh_index: 300,
    tipo_pocion: 1,
    min_modificador: 30,
    max_modificador: 30,
    valor: 10
  }

  # Food.
  @food_id 82_002
  @food_def %ItemDef{
    id: @food_id,
    name: "ComidaTest",
    obj_type: 8,
    grh_index: 301,
    min_ham: 25,
    valor: 5,
    stackable: true
  }

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    items = [
      {@sword_id, @sword_def},
      {@shield_id, @shield_def},
      {@two_handed_id, @two_handed_def},
      {@high_level_id, @high_level_def},
      {@junk_id, @junk_def},
      {@hp_potion_id, @hp_potion_def},
      {@food_id, @food_def}
    ]

    for {id, def_} <- items, do: :ets.insert(:arena_game_data, {{:item, id}, def_})

    drain()

    on_exit(fn ->
      for {id, _} <- items, do: :ets.delete(:arena_game_data, {:item, id})
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
      level: 25,
      class: :warrior,
      race: :human,
      gender: :male,
      hp: 80,
      max_hp: 100,
      mana: 50,
      max_mana: 100,
      stamina: 80,
      max_stamina: 100,
      hunger: 50,
      thirst: 50,
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
      body_id: 1,
      base_body_id: 1,
      paralyzed: false,
      dead: false,
      str_buff: 0,
      agi_buff: 0,
      duracion_efecto: 0,
      next_item_use_at: -1_000_000_000_000
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
      occupancy: Keyword.get(opts, :occupancy, %{{player.x, player.y} => {:player, player.char_id}})
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:equip_item, _, _}) — happy path
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_call({:equip_item, ...}) — successful path" do
    test "equip a sword: equipment updated, change_inventory_slot + character_change fanned" do
      inv = build_inventory([{0, %{item_id: @sword_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:equip_item, :player, 0}, :from, state)

      updated = new_state.players[:player]
      assert updated.equipment[:weapon] == @sword_id
      assert Enum.at(updated.inventory, 0).equipped == true

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      char_change_id = AoProtocol.PacketIds.Server.character_change()

      assert_receive {:egress, %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<^char_change_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
    end

    test "toggle: equipping then equipping again unequips the item" do
      inv = build_inventory([{0, %{item_id: @sword_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, state2} =
               MapServer.handle_call({:equip_item, :player, 0}, :from, state)

      assert state2.players[:player].equipment[:weapon] == @sword_id

      assert {:reply, :ok, state3} =
               MapServer.handle_call({:equip_item, :player, 0}, :from, state2)

      assert state3.players[:player].equipment[:weapon] == nil
      assert Enum.at(state3.players[:player].inventory, 0).equipped == false
    end

    test "two-handed weapon auto-unequips shield: two inventory_slot effects + character_change" do
      inv =
        build_inventory([
          {0, %{item_id: @two_handed_id, amount: 1, equipped: false}},
          {1, %{item_id: @shield_id, amount: 1, equipped: true}}
        ])

      player =
        make_player(%{
          inventory: inv,
          equipment: %{
            weapon: nil,
            armor: nil,
            shield: @shield_id,
            helmet: nil,
            ring: nil,
            municion: nil,
            saddle: nil
          }
        })

      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:equip_item, :player, 0}, :from, state)

      updated = new_state.players[:player]
      assert updated.equipment[:weapon] == @two_handed_id
      assert updated.equipment[:shield] == nil
      assert Enum.at(updated.inventory, 0).equipped == true
      assert Enum.at(updated.inventory, 1).equipped == false

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      char_change_id = AoProtocol.PacketIds.Server.character_change()

      # Two slot updates (weapon slot + shield slot) BEFORE the character_change
      # broadcast.
      assert_receive {:egress, %{payload: <<id1::little-signed-integer-16, _::binary>>}}
      assert id1 == inv_id

      assert_receive {:egress, %{payload: <<id2::little-signed-integer-16, _::binary>>}}
      assert id2 == inv_id

      assert_receive {:egress, %{payload: <<id3::little-signed-integer-16, _::binary>>}}
      assert id3 == char_change_id, "character_change must fan AFTER the per-slot packets"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:equip_item, _, _}) — adversarial
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_call({:equip_item, ...}) — adversarial" do
    test "empty slot: rejected with empty-slot console, no mutation, no character_change" do
      player = make_player()
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:equip_item, :player, 0}, :from, state)

      assert new_state == state

      console_id = AoProtocol.PacketIds.Server.console_msg()
      char_change_id = AoProtocol.PacketIds.Server.character_change()

      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "No hay nada en ese slot") != :nomatch

      refute_receive {:egress, %{payload: <<^char_change_id::little-signed-integer-16, _::binary>>}}, 50
    end

    test "non-equippable item: rejected with not-equippable console" do
      inv = build_inventory([{0, %{item_id: @junk_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:equip_item, :player, 0}, :from, state)

      assert Enum.at(new_state.players[:player].inventory, 0).equipped == false

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "No puedes equipar") != :nomatch
    end

    test "level too low: rejected with level console, equipment untouched" do
      inv = build_inventory([{0, %{item_id: @high_level_id, amount: 1, equipped: false}}])
      player = make_player(%{level: 10, inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:equip_item, :player, 0}, :from, state)

      assert new_state.players[:player].equipment[:weapon] == nil

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "nivel") != :nomatch
    end

    test "dead player: silent no-op" do
      inv = build_inventory([{0, %{item_id: @sword_id, amount: 1, equipped: false}}])
      player = make_player(%{dead: true, inventory: inv})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:equip_item, :player, 0}, :from, state)

      assert new_state == state
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{:ghost => self()})

      assert {:reply, :ok, ^state} =
               MapServer.handle_call({:equip_item, :ghost, 0}, :from, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "stale session: mutation still happens, no packets land" do
      inv = build_inventory([{0, %{item_id: @sword_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player, sessions: %{})

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:equip_item, :player, 0}, :from, state)

      assert new_state.players[:player].equipment[:weapon] == @sword_id
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:use_item, _, _, _, _}) — happy path
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_call({:use_item, ...}) — successful path" do
    test "use HP potion: hp restored, slot consumed, change_inventory + update_hp/mana/sta fan" do
      inv = build_inventory([{0, %{item_id: @hp_potion_id, amount: 2, equipped: false}}])
      player = make_player(%{inventory: inv, hp: 50})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 0, nil, nil}, :from, state)

      updated = new_state.players[:player]
      assert updated.hp == 80, "HP must be restored by potion modificador (30)"
      assert Enum.at(updated.inventory, 0).amount == 1, "potion stack decremented"

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()

      # Effect ordering: change_inventory_slot, then update_hp/mana/stamina.
      assert_receive {:egress, %{payload: <<id1::little-signed-integer-16, _::binary>>}}
      assert id1 == inv_id, "first envelope must be change_inventory_slot"

      # Three update_* packets follow (hp, mana, stamina).
      assert_receive {:egress, %{payload: <<_id2::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<_id3::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<_id4::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
    end

    test "use food: hunger restored, hunger_and_thirst update fanned" do
      inv = build_inventory([{0, %{item_id: @food_id, amount: 3, equipped: false}}])
      player = make_player(%{inventory: inv, hunger: 50})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 0, nil, nil}, :from, state)

      updated = new_state.players[:player]
      assert updated.hunger == 75, "hunger restored by min_ham (25)"
      assert Enum.at(updated.inventory, 0).amount == 2

      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()
      assert_receive {:egress, %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}}
      # follow-up update_hunger_and_thirst
      assert_receive {:egress, _}
    end

    test "next_item_use_at advanced after successful use" do
      inv = build_inventory([{0, %{item_id: @hp_potion_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv})
      state = state_with(player)
      before = System.monotonic_time(:millisecond)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 0, nil, nil}, :from, state)

      cooldown = Arena.Settings.get(:item_use_cooldown_ms)
      assert new_state.players[:player].next_item_use_at >= before + cooldown - 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:use_item, _, _, _, _}) — adversarial
  # ════════════════════════════════════════════════════════════════════════

  describe "MapServer.handle_call({:use_item, ...}) — adversarial" do
    test "empty slot: silent no-op" do
      player = make_player()
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 5, nil, nil}, :from, state)

      assert new_state.players[:player].inventory == player.inventory
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "dead player: silent no-op" do
      inv = build_inventory([{0, %{item_id: @hp_potion_id, amount: 1, equipped: false}}])
      player = make_player(%{dead: true, inventory: inv, hp: 1})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 0, nil, nil}, :from, state)

      assert new_state == state
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "cooldown active (next_item_use_at in future): silent no-op, slot untouched" do
      future = System.monotonic_time(:millisecond) + 1_000_000
      inv = build_inventory([{0, %{item_id: @hp_potion_id, amount: 2, equipped: false}}])
      player = make_player(%{inventory: inv, next_item_use_at: future, hp: 50})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 0, nil, nil}, :from, state)

      # Slot must NOT be consumed; HP must NOT change.
      assert Enum.at(new_state.players[:player].inventory, 0).amount == 2
      assert new_state.players[:player].hp == 50

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "paralyzed player drinking non-potion (food): silent no-op" do
      inv = build_inventory([{0, %{item_id: @food_id, amount: 1, equipped: false}}])
      player = make_player(%{paralyzed: true, inventory: inv, hunger: 30})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 0, nil, nil}, :from, state)

      # Food should NOT be consumed when paralyzed (only obj_type 1 potions
      # can bypass the paralysis gate).
      assert new_state.players[:player].hunger == 30
      assert Enum.at(new_state.players[:player].inventory, 0).amount == 1

      refute_receive {:egress, _}, 50
    end

    test "paralyzed player CAN drink HP potion (VB6 potion gate skip)" do
      inv = build_inventory([{0, %{item_id: @hp_potion_id, amount: 1, equipped: false}}])
      player = make_player(%{paralyzed: true, inventory: inv, hp: 50})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 0, nil, nil}, :from, state)

      assert new_state.players[:player].hp == 80
      assert Enum.at(new_state.players[:player].inventory, 0) == nil
    end

    test "DivineBlood blocks HP potion: console message, item NOT consumed" do
      inv = build_inventory([{0, %{item_id: @hp_potion_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv, hp: 50, divine_blood: 1})
      state = state_with(player)

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 0, nil, nil}, :from, state)

      # Drift #16: HP and slot stay untouched, console fires.
      assert new_state.players[:player].hp == 50
      assert Enum.at(new_state.players[:player].inventory, 0).amount == 1

      console_id = AoProtocol.PacketIds.Server.console_msg()
      assert_receive {:egress, %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}
      assert :binary.match(payload, "sangre divina") != :nomatch
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{:ghost => self()})

      assert {:reply, :ok, ^state} =
               MapServer.handle_call({:use_item, :ghost, 0, nil, nil}, :from, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "stale session: HP still mutated, no packets land" do
      inv = build_inventory([{0, %{item_id: @hp_potion_id, amount: 1, equipped: false}}])
      player = make_player(%{inventory: inv, hp: 50})
      state = state_with(player, sessions: %{})

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:use_item, :player, 0, nil, nil}, :from, state)

      assert new_state.players[:player].hp == 80
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "direct handler call returns {:ok, state, []} when player is missing" do
      state = map_state(players: %{}, sessions: %{})

      assert {:ok, ^state, []} = InventoryHandlers.handle_equip_item(state, :ghost, 0)
      assert {:ok, ^state, []} = InventoryHandlers.handle_use_item(state, :ghost, 0)
    end
  end
end
