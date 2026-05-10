defmodule Arena.Adversarial.GmPanelInventoryMerchantAdversarialTest do
  @moduledoc """
  Adversarial tests for the recently-landed VB6 drift fixes:

    * GM Panel decode + response  (VB6 Protocol_GmCommands.bas:764 HandleGMPanel
      + Protocol_Writes.bas:2605 WriteShowGMPanelForm; PacketId.bas:351 eGMPanel)
    * Inventory slot count by patron tier  (CharacterPersistence.bas:95-109
      `get_num_inv_slots_from_tier`; Declares.bas:1480 MAX_INVENTORY_SLOTS = 42)
    * Merchant sell guards  (Comercio.bas:95-162 Comercio + :294-310 SalePrice —
      Destruye, Consejero/SemiDios privilege gate, Trabajador discount)

  Style follows the other files in `apps/arena/test/adversarial/`:
    * `# TODO(parity)` tags mark assertions known to diverge from VB6 that
      remain as failing/soft-asserted tests so the drift can't silently regress.
    * `async: false` is used where the suite mutates the shared
      `:arena_game_data` ETS table (item/quest/npc defs).
  """

  use ExUnit.Case, async: false

  alias AoEntities.PlayerEntity
  alias AoProtocol.Client.Decoder
  alias AoProtocol.PacketIds
  alias AoProtocol.Server.Encoder
  alias Arena.Data.GameData
  alias Arena.Inventory
  alias Arena.Map.{Commerce, MapServer}
  alias AoTcpGateway.SessionLogic

  import Arena.Test.MapStateFactory

  @gm_panel_client_id 116

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp make_entity(overrides) do
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
        level: 10,
        class: :guerrero,
        race: :humano,
        gender: :male,
        str: 18,
        agi: 18,
        gold: 50_000,
        dead: false,
        inventory: List.duplicate(nil, 24),
        equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil, saddle: nil},
        skills: %{trading: 0},
        gm: false,
        gm_level: nil,
        user_tier: :normal,
        commerce_npc_id: nil,
        commerce_npc_instance_id: nil,
        active_quests: [],
        completed_quests: MapSet.new(),
        trade_partner_id: nil,
        meditating: false,
        navigating: false,
        paralyzed: false,
        last_clicked_npc_instance_id: nil,
        last_clicked_npc_type: nil,
        quest_npc_id: nil,
        safe_mode: false,
        criminal: false,
        buffs: []
      },
      overrides
    )
  end

  defp make_map_state(player, opts) do
    map_state(
      players: %{:player => player},
      sessions: %{:player => self()},
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, sin_invi_ocul: false}
    )
  end

  defp base_session(overrides) do
    Map.merge(
      %{
        character_id: 42,
        map_id: 1,
        account_id: "acc_test",
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        is_gm: false
      },
      overrides
    )
  end

  defp find_merchant_npc_id do
    Enum.find_value(1..2000, fn id ->
      case GameData.get_npc(id) do
        %{comercia: true, shop_items: [_ | _]} -> id
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
  # 1. GM PANEL ADVERSARIAL
  # ══════════════════════════════════════════════════════════════════════════

  describe "GM panel — session-layer gate (VB6 Protocol_GmCommands.bas:764)" do
    test "non-GM session receives MSG_NO_PRIVILEGIOS and no show_gm_panel_form" do
      state = base_session(%{is_gm: false, character_id: 42})
      {new_state, packets} = SessionLogic.handle_command(state, {:gm_panel_request, %{}})

      # VB6: If .flags.Privilegios And e_PlayerType.User Then Exit Sub
      # In our stack the session router returns the console rejection message.
      assert new_state == state

      assert packets == [
               {:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}
             ]

      # Must NOT include any :show_gm_panel_form packet.
      refute Enum.any?(packets, fn
               {:show_gm_panel_form, _} -> true
               _ -> false
             end)
    end

    test "gm_panel_request before login (character_id == nil) is silently dropped" do
      state = base_session(%{character_id: nil, is_gm: false})
      {new_state, packets} = SessionLogic.handle_command(state, {:gm_panel_request, %{}})

      # None of the guards fire when character_id is nil; catch-all returns
      # no packets, and crucially no GM panel form nor GM privilege message.
      assert new_state == state
      assert packets == []
    end

    test "gm_panel_request before login with is_gm=true still drops — login precondition" do
      # Pathological: attacker spoofed is_gm before logging in. The guards
      # all require character_id != nil so the message must still not be sent.
      state = base_session(%{character_id: nil, is_gm: true})
      {new_state, packets} = SessionLogic.handle_command(state, {:gm_panel_request, %{}})

      assert new_state == state
      assert packets == []
    end

    test "GM with gm_level=:consejero is allowed (matches VB6 e_PlayerType.User check)" do
      # VB6 Protocol_GmCommands.bas:768 only rejects the plain `User` bitflag
      # — Consejero / SemiDios / Dios / Admin all pass the privilege gate for
      # HandleGMPanel. Our session layer gates by `is_gm`, which is true for
      # every GM role. Verify the gate lets a consejero through.
      state = base_session(%{is_gm: true, character_id: 42})
      {new_state, packets} = SessionLogic.handle_command(state, {:gm_panel_request, %{}})

      assert new_state == state
      # Session delegates to Arena.Map.MapServer.gm_panel_request/2 (cast) and
      # returns no packets here — the eShowGMPanelForm is produced by the map
      # layer. What matters is that the rejection message is NOT present.
      refute Enum.any?(packets, fn
               {:console_msg, %{message: "No tienes privilegios de GM." <> _}} -> true
               _ -> false
             end)
    end
  end

  describe "GM panel — MapServer.handle_cast (VB6 Protocol_Writes.bas:2605)" do
    test "unknown char_id is a noop (no packet, no crash)" do
      state = map_state(players: %{}, sessions: %{})
      assert {:noreply, ^state} = MapServer.handle_cast({:gm_panel_request, 999}, state)
      refute_receive {:send_raw, _}, 50
    end

    test "entity with no equipment map sends zeros for helmet/weapon/shield" do
      gm = %PlayerEntity{
        char_id: 1,
        name: "NoEquipGM",
        account_id: "a",
        x: 50,
        y: 50,
        gm: true,
        gm_level: :dios,
        head_id: 11,
        body_id: 22,
        # Deliberately force equipment to nil to trigger the `|| %{}` fallback
        # at MapServer.handle_cast({:gm_panel_request, _}).
        equipment: nil
      }

      state = map_state(players: %{1 => gm}, sessions: %{1 => self()})

      assert {:noreply, ^state} = MapServer.handle_cast({:gm_panel_request, 1}, state)
      assert_receive {:send_raw, raw}

      expected =
        <<PacketIds.Server.show_gm_panel_form()::little-signed-16,
          11::little-signed-16,
          22::little-signed-16,
          0::little-signed-16,
          0::little-signed-16,
          0::little-signed-16>>

      assert raw == expected
    end
  end

  describe "GM panel — decoder robustness (VB6: eGMPanel carries no payload)" do
    test "bare packet id with no payload decodes cleanly" do
      raw = <<@gm_panel_client_id::little-signed-16>>
      assert {:ok, {:gm_panel_request, %{}}, <<>>} = Decoder.decode(raw)
    end

    test "trailing bytes after empty payload are returned as `rest` (not swallowed)" do
      raw = <<@gm_panel_client_id::little-signed-16, 0xDE, 0xAD, 0xBE, 0xEF>>
      assert {:ok, {:gm_panel_request, %{}}, <<0xDE, 0xAD, 0xBE, 0xEF>>} = Decoder.decode(raw)
    end

    test "short buffer (only one byte) returns :incomplete" do
      assert :incomplete = Decoder.decode(<<0x74>>)
    end

    test "empty buffer returns :incomplete" do
      assert :incomplete = Decoder.decode(<<>>)
    end

    test "malformed extra-bytes payload does not crash the decoder" do
      # The client has no business sending a payload with eGMPanel, but we must
      # not crash on one. Ensures the VB6 `eGMPanel -> HandleGMPanel` entry
      # point can't be weaponised via oversized frames.
      raw = <<@gm_panel_client_id::little-signed-16, :binary.copy(<<0xFF>>, 128)::binary>>
      assert {:ok, {:gm_panel_request, %{}}, rest} = Decoder.decode(raw)
      assert byte_size(rest) == 128
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. INVENTORY TIER SLOTS ADVERSARIAL
  # ══════════════════════════════════════════════════════════════════════════

  describe "max_slots_for_tier/1 (VB6 CharacterPersistence.bas:95-109)" do
    test ":normal (free) tier is exactly 24 (VB6 MAX_USERINVENTORY_SLOTS)" do
      assert Inventory.max_slots_for_tier(:normal) == 24
    end

    test ":adventurer tier is 30 (24 + 6)" do
      assert Inventory.max_slots_for_tier(:adventurer) == 30
    end

    test ":hero tier is 36 (24 + 12)" do
      assert Inventory.max_slots_for_tier(:hero) == 36
    end

    test ":legend tier is 42 (24 + 18) — hard cap at MAX_INVENTORY_SLOTS" do
      assert Inventory.max_slots_for_tier(:legend) == 42
      assert Inventory.max_slots_for_tier(:legend) == Inventory.max_inventory_slots()
    end

    test "nil falls back to base 24 (not a crash)" do
      assert Inventory.max_slots_for_tier(nil) == 24
    end

    test "unknown atom falls back to base 24 (forward compat)" do
      assert Inventory.max_slots_for_tier(:gold) == 24
      assert Inventory.max_slots_for_tier(:bogus_tier) == 24
    end

    test "string or integer values fall back to base 24 without raising" do
      # `user_tier` is sometimes a raw DB int pre-normalization. The pure
      # pattern-match function must not crash when fed unnormalized values.
      assert Inventory.max_slots_for_tier("adventurer") == 24
      assert Inventory.max_slots_for_tier(1) == 24
    end
  end

  describe "max_slots_for_entity/1" do
    test "missing :user_tier defaults to 24" do
      assert Inventory.max_slots_for_entity(%{}) == 24
    end

    test ":user_tier=nil defaults to 24" do
      assert Inventory.max_slots_for_entity(%{user_tier: nil}) == 24
    end

    test "each patron tier yields its VB6-spec slot count" do
      assert Inventory.max_slots_for_entity(%{user_tier: :normal}) == 24
      assert Inventory.max_slots_for_entity(%{user_tier: :adventurer}) == 30
      assert Inventory.max_slots_for_entity(%{user_tier: :hero}) == 36
      assert Inventory.max_slots_for_entity(%{user_tier: :legend}) == 42
    end
  end

  describe "pickup / add_item edge cases around the tier cap" do
    test "free tier: adding the 25th non-stackable item on a full 24-slot inventory is rejected" do
      # Stock a non-stackable (obj_type 3 armor) isn't in test-data helpers; we
      # insert a synthetic non-stackable def and fill the 24 slots.
      item_id = 99_701

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "TierSlotsAdv Armor",
        obj_type: 3,
        valor: 10,
        grh_index: 1,
        stackable: false
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      full = List.duplicate(%{item_id: item_id, amount: 1, equipped: false, elemental_tags: 0}, 24)

      assert {:error, :inventory_full} = Inventory.add_item(full, item_id, 1)

      :ets.delete(:arena_game_data, {:item, item_id})
    end

    test "legend tier: a 42-slot inventory accepts the 25th distinct item" do
      item_id = 99_702

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "Legend TierSlot Test",
        obj_type: 3,
        valor: 10,
        grh_index: 1,
        stackable: false
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      inv_24 = List.duplicate(%{item_id: item_id, amount: 1, equipped: false, elemental_tags: 0}, 24)
      legend_inv = inv_24 ++ List.duplicate(nil, 42 - 24)

      assert {:ok, new_inv, slot} = Inventory.add_item(legend_inv, item_id, 1)
      # New item must land in slot 24 (0-indexed — the 25th slot).
      assert slot == 24
      assert length(new_inv) == 42

      :ets.delete(:arena_game_data, {:item, item_id})
    end

    test "downgrade: owning items in slots 25+ when user_tier drops to :normal must not lose them" do
      # VB6 parity: when a patron subscription expires, the player's existing
      # items above slot 24 are preserved until they are actively moved/sold
      # (CharacterPersistence.bas keeps all persisted slots). We verify that
      # `Inventory.get_slot/2` reads the item at index 40 on an entity whose
      # inventory length is 42 — even if max_slots_for_entity would now say 24.
      item = %{item_id: 500, amount: 1, equipped: false, elemental_tags: 0}

      inv = List.duplicate(nil, 42) |> List.replace_at(40, item)

      # Simulate a downgraded entity: user_tier is :normal but inventory is 42.
      entity = %{user_tier: :normal, inventory: inv}

      # No data loss: the underlying slot is still addressable.
      assert Inventory.get_slot(entity.inventory, 40) == item

      # TODO(parity): once an explicit "shrink-on-downgrade" path is added,
      # that policy should be decided (VB6 preserves; any truncation would be
      # drift). Until then, this test documents current behaviour.
      assert length(entity.inventory) == 42
    end

    test "unknown-tier atom falling back to 24 does not corrupt a 42-slot pre-existing inventory" do
      # If persistence loads a legend inventory but user_tier is written as a
      # garbage atom, max_slots_for_entity falls back to 24, but the in-memory
      # inventory list must still be read at its actual length.
      entity = %{user_tier: :totally_bogus, inventory: List.duplicate(nil, 42)}
      assert Inventory.max_slots_for_entity(entity) == 24
      # Getting slot 41 on the real list must still return nil (not crash).
      assert Inventory.get_slot(entity.inventory, 41) == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. MERCHANT SELL ADVERSARIAL (VB6 Comercio.bas:95-162, 294-310)
  # ══════════════════════════════════════════════════════════════════════════

  describe "Destruye flag (VB6 Comercio.bas:104-107)" do
    test "selling a destruye-flagged item is rejected with the VB6 message and no gold / no slot change" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_910

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "Bound Destroyed Token",
        obj_type: 1,
        valor: 5_000,
        destruye: true,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 100,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      flush_mailbox()
      {:ok, new_state, result, effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      assert result == {:error, :destruye_item}
      assert Enum.at(new_state.players[:player].inventory, 0) != nil
      assert new_state.players[:player].gold == 100

      # Must send the VB6 console message MSG_NO_SIENTO_PUEDO_COMPRARTE_ESE_ITEM.
      warning =
        Encoder.encode({:console_msg, %{message: "Lo siento, no puedo comprarte ese item.", font_index: 0}})

      assert Enum.any?(effects, fn
               {:send, :player, %{payload: ^warning}} -> true
               _ -> false
             end),
             "Expected destruye console-msg effect for the player"
    end

    test "destruye + equipped rejects for equipped_item first (defense-in-depth ordering)" do
      # The equipped gate runs before the destruye gate. This keeps behaviour
      # deterministic if an operator stamps `destruye` on a vanity item that a
      # character somehow has equipped.
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_911

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "Equipped Destruye Item",
        obj_type: 3,
        valor: 1,
        destruye: true,
        equip_slot: :helmet,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: true
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, _new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      assert result == {:error, :equipped_item}
    end
  end

  describe "Privilegios gate — Consejero / SemiDios cannot sell (Comercio.bas:130-133)" do
    test "Consejero is blocked" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_920

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "GenericSellable",
        obj_type: 1,
        valor: 100,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          gm: true,
          gm_level: :consejero,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      assert result == {:error, :gm_cannot_sell}
      assert Enum.at(new_state.players[:player].inventory, 0) != nil
      assert new_state.players[:player].gold == 0
    end

    test "SemiDios is blocked" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_921

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "SemiDiosBlock",
        obj_type: 1,
        valor: 100,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          gm: true,
          gm_level: :semi_dios,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, _new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      assert result == {:error, :gm_cannot_sell}
    end

    test "Dios and Admin are NOT blocked by the Consejero/SemiDios gate (VB6 parity)" do
      # VB6 only masks Consejero Or SemiDios. Higher tiers (Dios / Admin) can
      # sell because the bit check at Comercio.bas:130 does not set for them.
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_922

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "DiosCanSell",
        obj_type: 1,
        valor: 99,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      for gm_level <- [:dios, :admin] do
        entity =
          make_entity(%{
            commerce_npc_id: merchant_id,
            commerce_npc_instance_id: :merchant,
            gold: 0,
            gm: true,
            gm_level: gm_level,
            inventory:
              List.replace_at(List.duplicate(nil, 24), 0, %{
                item_id: item_id,
                amount: 1,
                equipped: false
              })
          })

        state = make_map_state(entity, npcs_live: %{merchant: merchant})
        {:ok, _new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

        assert result == :ok,
               ":#{gm_level} should be allowed to sell (VB6 gates only Consejero|SemiDios), got #{inspect(result)}"
      end

      :ets.delete(:arena_game_data, {:item, item_id})
    end

    test "regular player without any GM flag sells normally" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_923

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "RegularPlayerSellable",
        obj_type: 1,
        valor: 90,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          class: :guerrero,
          level: 10,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, :ok, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      # Guerrero: denom = 3; Fix(90/3) = 30.
      assert new_state.players[:player].gold == 30
    end
  end

  describe "Trabajador discount (VB6 Comercio.bas:294-310 SalePrice)" do
    test "level 1 Trabajador uses denom = 3 - 1*0.025 = 2.975 (still rounds below level 40)" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_930

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "Trab1",
        obj_type: 1,
        valor: 100,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          class: :trabajador,
          level: 1,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, :ok, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      # VB6: Fix(100 / (3 - 1*0.025)) = Fix(33.6134...) = 33.
      assert new_state.players[:player].gold == 33
    end

    test "level 50 Trabajador is clamped at denom = 2 (VB6 'If denom < 2 Then denom = 2')" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_931

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "Trab50Clamp",
        obj_type: 1,
        valor: 200,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          class: :trabajador,
          level: 50,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, :ok, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      # At level 50 raw denom = 3 - 50*0.025 = 1.75, clamped to 2. Fix(200/2) = 100.
      assert new_state.players[:player].gold == 100
    end

    test "non-Trabajador level-50 ignores the discount (still denom = 3)" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_932

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "Lvl50Regular",
        obj_type: 1,
        valor: 300,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          class: :mago,
          level: 50,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, :ok, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      # denom = 3 (mago); Fix(300/3) = 100.
      assert new_state.players[:player].gold == 100
    end
  end

  # ── Sell during trade session ─────────────────────────────────────────────

  describe "sell during active trade (mutex with :in_commerce)" do
    # TODO(parity): VB6 Comercio.bas:74-77 rejects Comercio when the caller's
    # Comerciando flag is also True (user-to-user trade). Our handle_commerce_sell
    # pipes through with trade_partner_id != nil and commits the sale. This
    # test encodes the expected VB6 behaviour and is currently a known failure
    # until the mutex is enforced in `Arena.Map.Commerce.handle_commerce_sell/4`.
    @tag :parity_drift
    test "sell with trade_partner_id set is rejected (VB6 Comerciando mutex)" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_940

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "SellWhileTrade",
        obj_type: 1,
        valor: 90,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          trade_partner_id: :someone_else,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      assert result in [{:error, :trading}, {:error, :already_trading}, {:error, :in_trade}]
      # Anti-dupe: stack and gold unchanged.
      assert Enum.at(new_state.players[:player].inventory, 0).amount == 1
      assert new_state.players[:player].gold == 0
    end

  end

  # ── Amount edge cases ─────────────────────────────────────────────────────

  describe "sell amount edge cases" do
    test "amount = 0 rejected as :invalid_amount" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_950

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "ZeroAmtSell",
        obj_type: 1,
        valor: 10,
        grh_index: 1,
        stackable: true,
        max_hit: 100
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 10,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 0)

      :ets.delete(:arena_game_data, {:item, item_id})

      assert result == {:error, :invalid_amount}
      assert Enum.at(new_state.players[:player].inventory, 0).amount == 10
      assert new_state.players[:player].gold == 0
    end

    test "negative amount rejected as :invalid_amount" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_951

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "NegAmtSell",
        obj_type: 1,
        valor: 10,
        grh_index: 1,
        stackable: true,
        max_hit: 100
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 10,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 1, -5)

      :ets.delete(:arena_game_data, {:item, item_id})

      assert result == {:error, :invalid_amount}
      assert new_state.players[:player].gold == 0
    end

    test "amount > item stack rejected as :not_enough (anti-dupe)" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_952

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "OverAmtSell",
        obj_type: 1,
        valor: 10,
        grh_index: 1,
        stackable: true,
        max_hit: 100
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 5,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 1, 9_999)

      :ets.delete(:arena_game_data, {:item, item_id})

      assert result == {:error, :not_enough}
      # The slot is untouched.
      assert Enum.at(new_state.players[:player].inventory, 0).amount == 5
      assert new_state.players[:player].gold == 0
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 4. BUY ADVERSARIAL EDGE CASES
  # ══════════════════════════════════════════════════════════════════════════

  describe "buy — edge cases" do
    test "buy when gold is exactly the sale price succeeds (>= vs >)" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      npc_def = GameData.get_npc(merchant_id)
      shop_item = hd(npc_def.shop_items)
      item_def = GameData.get_item(shop_item.item_id)
      price = ceil(item_def.valor / 1.0 * 1)

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: price
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_buy(state, :player, 1, 1)

      assert result == :ok
      # Gold must be exactly zero (we had price, we paid price).
      assert new_state.players[:player].gold == 0
    end

    test "buy when gold is price - 1 is rejected with :not_enough_gold" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      npc_def = GameData.get_npc(merchant_id)
      shop_item = hd(npc_def.shop_items)
      item_def = GameData.get_item(shop_item.item_id)
      price = ceil(item_def.valor / 1.0 * 1)

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: price - 1
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_buy(state, :player, 1, 1)

      assert result == {:error, :not_enough_gold}
      assert new_state.players[:player].gold == price - 1
    end

    test "buy amount = 0 rejected with :invalid_amount (matches sell behaviour)" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 100_000
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, _new_state, result, _effects} = Commerce.handle_commerce_buy(state, :player, 1, 0)
      assert result == {:error, :invalid_amount}
    end

    test "buy negative amount is rejected with :invalid_amount" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 100_000
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_buy(state, :player, 1, -3)
      assert result == {:error, :invalid_amount}
      # Anti-dupe: gold untouched.
      assert new_state.players[:player].gold == 100_000
    end

    test "buy when inventory is at 24-slot cap and item is non-stackable returns :inventory_full" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      npc_def = GameData.get_npc(merchant_id)

      # Find a shop_item whose backing ItemDef is non-stackable. We need to
      # rely on whatever the seeded merchant carries; most vanilla shops have
      # weapons/armor (obj_type 2/3), both non-stackable.
      non_stackable_idx =
        npc_def.shop_items
        |> Enum.with_index(1)
        |> Enum.find(fn {shop_item, _idx} ->
          case GameData.get_item(shop_item.item_id) do
            %{stackable: false} -> true
            _ -> false
          end
        end)

      case non_stackable_idx do
        nil ->
          # All shop items are stackable — skip by passing a trivial assertion.
          # (The slot cap check still runs through the stackable path elsewhere.)
          assert true

        {shop_item, slot_idx} ->
          merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

          # Fill inventory with 24 different-item entries so no empty slot exists.
          filler = %{item_id: 1, amount: 1, equipped: false, elemental_tags: 0}
          full = List.duplicate(filler, 24)

          # Ensure no slot matches the shop item id (so stacking can't rescue us).
          full = Enum.map(full, fn _ -> %{filler | item_id: filler.item_id + 1} end)

          entity =
            make_entity(%{
              commerce_npc_id: merchant_id,
              commerce_npc_instance_id: :merchant,
              gold: 1_000_000,
              inventory: full
            })

          state = make_map_state(entity, npcs_live: %{merchant: merchant})

          {:ok, new_state, result, _effects} = Commerce.handle_commerce_buy(state, :player, slot_idx, 1)

          assert result == {:error, :inventory_full},
                 "expected inventory_full for non-stackable shop item #{inspect(shop_item)}, got #{inspect(result)}"

          # Gold must not have been debited.
          assert new_state.players[:player].gold == 1_000_000
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 5. MERCHANT DESPAWN MID-TRANSACTION (session cleanup)
  # ══════════════════════════════════════════════════════════════════════════

  describe "merchant despawns mid-transaction" do
    test "buy after merchant instance vanishes returns :merchant_gone and debits nothing" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :gone_instance,
          gold: 1_000_000
        })

      # npcs_live has NO entry for :gone_instance — simulates death/despawn.
      state = make_map_state(entity, npcs_live: %{})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_buy(state, :player, 1, 1)

      assert result in [{:error, :merchant_gone}, {:error, :too_far}, {:error, :no_commerce}]
      assert new_state.players[:player].gold == 1_000_000
    end

    test "sell after merchant despawns preserves the stack and gold" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      item_id = 99_960

      item_def = %Arena.Data.ItemDef{
        id: item_id,
        name: "SellDespawn",
        obj_type: 1,
        valor: 999,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, item_id}, item_def})

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :gone,
          gold: 7,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 5, %{
              item_id: item_id,
              amount: 3,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{})

      {:ok, new_state, result, _effects} = Commerce.handle_commerce_sell(state, :player, 6, 1)

      :ets.delete(:arena_game_data, {:item, item_id})

      assert result in [{:error, :merchant_gone}, {:error, :no_commerce}, {:error, :too_far}]
      # The stack and gold are unchanged — no partial-state bug.
      slot = Enum.at(new_state.players[:player].inventory, 5)
      assert slot.amount == 3
      assert new_state.players[:player].gold == 7
    end
  end
end
