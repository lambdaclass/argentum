defmodule Arena.MerchantParityTest do
  @moduledoc """
  VB6 merchant parity tests: timbero message format, quest-item sell block,
  stack-size enforcement, and normal-item sell control test.
  """

  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.{Commerce, NpcInteraction}
  alias Arena.Inventory

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp make_entity(overrides \\ %{}) do
    Map.merge(
      %{
        char_id: :player,
        x: 50,
        y: 50,
        dead: false,
        gold: 50_000,
        commerce_npc_id: nil,
        commerce_npc_instance_id: nil,
        inventory: List.duplicate(nil, 24),
        gamble_wins: 0,
        gamble_losses: 0,
        gamble_plays: 0,
        last_clicked_npc_instance_id: nil,
        last_clicked_npc_type: nil,
        active_quests: [],
        completed_quests: MapSet.new(),
        quest_npc_id: nil,
        skills: %{trading: 0},
        meditating: false,
        navigating: false,
        paralyzed: false,
        trade_partner_id: nil,
        safe_mode: false,
        criminal: false,
        level: 10,
        class: :guerrero,
        skill_points: 0
      },
      overrides
    )
  end

  defp make_map_state(player, opts \\ []) do
    map_state(
      players: %{player: player},
      sessions: %{player: self()},
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, sin_invi_ocul: false}
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

  defp find_sellable_item_id do
    Enum.find_value(1..4000, fn id ->
      case GameData.get_item(id) do
        %{valor: valor} = item when valor > 0 and id != 12 ->
          if Map.get(item, :newbie, false) or Map.get(item, :instransferible, false),
            do: nil,
            else: id

        _ ->
          nil
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

  defp collect_messages do
    collect_messages([])
  end

  defp collect_messages(acc) do
    receive do
      msg -> collect_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 1. Timbero message format: must use "Timbero te dice:" prefix
  # ══════════════════════════════════════════════════════════════════════════

  describe "timbero message format" do
    test "gamble win message uses 'Timbero te dice:' NPC speech prefix" do
      # Seed random so we always win
      :rand.seed(:exsss, {1, 2, 3})

      # Create a timbero NPC nearby
      timbero_npc = %{npc_id: 99999, x: 50, y: 51, instance_id: :timbero_inst}

      # We need an NPC def that has npc_type 10 (timbero/apostador in shipped data)
      # Insert a mock timbero NPC def into ETS
      timbero_def = %{
        npc_id: 99999,
        name: "Timbero",
        npc_type: 10,
        comercia: false,
        shop_items: [],
        quest_numbers: [],
        creatures: []
      }

      :ets.insert(:arena_game_data, {{:npc, 99999}, timbero_def})

      entity =
        make_entity(%{
          gold: 5000,
          last_clicked_npc_instance_id: :timbero_inst,
          last_clicked_npc_type: 10
        })

      state = make_map_state(entity, npcs_live: %{timbero_inst: timbero_npc})

      # Try many times to get at least one win and one loss
      flush_mailbox()

      # Force a win by trying with known seed
      :rand.seed(:exsss, {100, 200, 300})
      {:noreply, _state} = NpcInteraction.handle_gamble(state, :player, 100, :timbero_inst)

      messages = collect_messages()

      # Extract console messages
      assert Enum.any?(messages, fn
               {:send_raw, _} -> true
               _ -> false
             end),
             "Expected at least one message to be sent"

      flush_mailbox()
      :rand.seed(:exsss, {100, 200, 300})
      {:noreply, _state2} = NpcInteraction.handle_gamble(state, :player, 100, :timbero_inst)

      all_raw =
        collect_messages()
        |> Enum.filter(fn
          {:send_raw, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {:send_raw, data} -> data end)

      # Concatenate all raw binary data into a string for inspection
      combined = Enum.join(all_raw)

      assert String.contains?(combined, "Timbero te dice:"),
             "Expected gamble message to contain 'Timbero te dice:' but got messages: #{inspect(all_raw)}"
    end

    test "gamble loss message uses 'Timbero te dice:' NPC speech prefix" do
      timbero_npc = %{npc_id: 99999, x: 50, y: 51, instance_id: :timbero_inst}

      timbero_def = %{
        npc_id: 99999,
        name: "Timbero",
        npc_type: 10,
        comercia: false,
        shop_items: [],
        quest_numbers: [],
        creatures: []
      }

      :ets.insert(:arena_game_data, {{:npc, 99999}, timbero_def})

      entity =
        make_entity(%{
          gold: 5000,
          last_clicked_npc_instance_id: :timbero_inst,
          last_clicked_npc_type: 10
        })

      state = make_map_state(entity, npcs_live: %{timbero_inst: timbero_npc})

      # Run gamble many times to guarantee at least one loss
      flush_mailbox()

      results =
        for seed <- 1..20 do
          flush_mailbox()
          :rand.seed(:exsss, {seed, seed * 2, seed * 3})
          {:noreply, _s} = NpcInteraction.handle_gamble(state, :player, 100, :timbero_inst)

          msgs = collect_messages()

          combined =
            msgs
            |> Enum.filter(fn
              {:send_raw, _} -> true
              _ -> false
            end)
            |> Enum.map(fn {:send_raw, data} -> data end)
            |> Enum.join()

          combined
        end

      # At least one should contain a loss message with the VB6 prefix
      has_timbero_prefix = Enum.any?(results, fn combined -> String.contains?(combined, "Timbero te dice:") end)

      assert has_timbero_prefix,
             "Expected at least one gamble message to contain 'Timbero te dice:' prefix"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. Quest item sell block
  # ══════════════════════════════════════════════════════════════════════════

  describe "quest item sell block" do
    test "cannot sell item that is an active quest objective" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil, "Need at least one merchant NPC in game data"

      # Use a specific quest objective item. We'll create a synthetic quest.
      quest_item_id = find_sellable_item_id()
      assert quest_item_id != nil, "Need at least one sellable item in game data"

      # Insert a fake quest that requires this item
      quest_def = %Arena.Data.QuestDef{
        id: 99999,
        name: "Test Quest",
        desc: "Collect items",
        desc_final: "Done!",
        required_objs: [%{id: quest_item_id, amount: 5}],
        required_npcs: [],
        reward_exp: 100,
        reward_gld: 50,
        reward_objs: []
      }

      :ets.insert(:arena_game_data, {{:quest, 99999}, quest_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 100,
          active_quests: [
            %{quest_id: 99999, npc_kills: %{}, started_at: 0}
          ],
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: quest_item_id,
              amount: 5,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:reply, result, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 3)

      assert result == {:error, :quest_item},
             "Expected sell to be rejected for quest objective item, got: #{inspect(result)}"

      # Inventory must be unchanged
      assert Enum.at(new_state.players[:player].inventory, 0) != nil
      assert new_state.players[:player].gold == 100
    end

    test "can sell item that is NOT a quest objective" do
      merchant_id = find_merchant_npc_id()
      item_id = find_sellable_item_id()
      assert merchant_id != nil
      assert item_id != nil

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 100,
          active_quests: [],
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:reply, result, _new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      assert result == :ok,
             "Expected normal item sell to succeed, got: #{inspect(result)}"
    end

    # Drift #9 — VB6 Comercio.bas:130-133 rejects selling when the caller's
    # Privilegios include Consejero or SemiDios ("MSG_NO_PODES_VENDER_ITEMS").
    test "Consejero cannot sell items (VB6 parity)" do
      merchant_id = find_merchant_npc_id()
      item_id = find_sellable_item_id()
      assert merchant_id != nil and item_id != nil

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 100,
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

      {:reply, result, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      assert result == {:error, :gm_cannot_sell},
             "Expected Consejero sell to be rejected, got: #{inspect(result)}"

      assert Enum.at(new_state.players[:player].inventory, 0) != nil
    end

    test "SemiDios cannot sell items (VB6 parity)" do
      merchant_id = find_merchant_npc_id()
      item_id = find_sellable_item_id()
      assert merchant_id != nil and item_id != nil

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 100,
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

      {:reply, result, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      assert result == {:error, :gm_cannot_sell},
             "Expected SemiDios sell to be rejected, got: #{inspect(result)}"

      assert Enum.at(new_state.players[:player].inventory, 0) != nil
    end

    # Drift #8 — VB6 Comercio.bas:294-310 (SalePrice) applies a per-level
    # sell-price discount for Trabajador characters:
    #   denom = 3 - level * 0.025 (clamped at 2)
    #   sell_price = Fix(valor / denom) * amount
    test "Trabajador level 40 gets Fix(valor/2) per unit (VB6 parity)" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      custom_item_id = 99801

      item_def = %Arena.Data.ItemDef{
        id: custom_item_id,
        name: "Trabajador Discount Test",
        obj_type: 1,
        valor: 100,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, custom_item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          class: :trabajador,
          level: 40,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: custom_item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:reply, result, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, custom_item_id})

      assert result == :ok
      # Level 40 Trabajador: denom = 3 - 40 * 0.025 = 2, Fix(100/2) = 50
      assert new_state.players[:player].gold == 50,
             "Expected Trabajador lvl 40 sell_price=50 (valor/2), got #{new_state.players[:player].gold}"
    end

    test "Trabajador level 20 gets Fix(valor/2.5) per unit" do
      merchant_id = find_merchant_npc_id()
      custom_item_id = 99802

      item_def = %Arena.Data.ItemDef{
        id: custom_item_id,
        name: "Trab20",
        obj_type: 1,
        valor: 100,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, custom_item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          class: :trabajador,
          level: 20,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: custom_item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:reply, :ok, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, custom_item_id})

      # denom = 3 - 20 * 0.025 = 2.5; Fix(100/2.5) = 40
      assert new_state.players[:player].gold == 40
    end

    test "non-Trabajador class still sells at valor/3" do
      merchant_id = find_merchant_npc_id()
      custom_item_id = 99803

      item_def = %Arena.Data.ItemDef{
        id: custom_item_id,
        name: "NonTrab",
        obj_type: 1,
        valor: 100,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, custom_item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 0,
          class: :guerrero,
          level: 40,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: custom_item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:reply, :ok, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, custom_item_id})

      # Guerrero: denom = 3 fixed; Fix(100/3) = 33
      assert new_state.players[:player].gold == 33
    end

    # Drift #7 — VB6 Comercio.bas:104-107 blocks items flagged Destruye=1
    # from being sold ("Lo siento, no puedo comprarte ese item.").
    test "selling item flagged destruye is rejected (VB6 parity)" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      destruye_item_id = 99900

      item_def = %Arena.Data.ItemDef{
        id: destruye_item_id,
        name: "Bound Trinket",
        obj_type: 1,
        valor: 1000,
        destruye: true,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, destruye_item_id}, item_def})

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 100,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: destruye_item_id,
              amount: 1,
              equipped: false
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:reply, result, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      :ets.delete(:arena_game_data, {:item, destruye_item_id})

      assert result == {:error, :destruye_item},
             "Expected destruye-flagged item sell to be rejected, got: #{inspect(result)}"

      assert Enum.at(new_state.players[:player].inventory, 0) != nil
      assert new_state.players[:player].gold == 100
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. Max stack size enforcement
  # ══════════════════════════════════════════════════════════════════════════

  describe "max stack size enforcement" do
    test "adding to existing stack is capped at item-specific max_hit limit" do
      # Create a stackable item with max_hit = 100 (VB6 uses max_hit for max stack)
      item_def = %Arena.Data.ItemDef{
        id: 99998,
        name: "Test Potion",
        obj_type: 1,
        stackable: true,
        max_hit: 100,
        valor: 10,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, 99998}, item_def})

      # Create inventory with 90 already stacked
      inventory = List.duplicate(nil, 24)
      inventory = List.replace_at(inventory, 0, %{item_id: 99998, amount: 90, equipped: false, elemental_tags: 0})

      # Try to add 50 more — should be capped at 100 total (max_hit), not 140
      result = Inventory.add_item(inventory, 99998, 50)

      assert {:ok, new_inventory, 0} = result
      slot = Enum.at(new_inventory, 0)
      assert slot.amount == 100,
             "Expected stack to be capped at 100 (item max_hit), got: #{slot.amount}"
    end

    test "adding to existing stack is capped at default 10000 when max_hit is 0" do
      # Create a stackable item with max_hit = 0 (should use default 10_000)
      item_def = %Arena.Data.ItemDef{
        id: 99997,
        name: "Generic Stack Item",
        obj_type: 1,
        stackable: true,
        max_hit: 0,
        valor: 5,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, 99997}, item_def})

      inventory = List.duplicate(nil, 24)
      inventory = List.replace_at(inventory, 0, %{item_id: 99997, amount: 9990, equipped: false, elemental_tags: 0})

      result = Inventory.add_item(inventory, 99997, 50)

      assert {:ok, new_inventory, 0} = result
      slot = Enum.at(new_inventory, 0)
      assert slot.amount == 10_000,
             "Expected stack to be capped at 10000 (default), got: #{slot.amount}"
    end

    test "new stack from empty slot is also capped at item max_hit" do
      item_def = %Arena.Data.ItemDef{
        id: 99996,
        name: "Small Stack Potion",
        obj_type: 1,
        stackable: true,
        max_hit: 50,
        valor: 10,
        grh_index: 1
      }

      :ets.insert(:arena_game_data, {{:item, 99996}, item_def})

      inventory = List.duplicate(nil, 24)

      # Try to add 200 of an item with max_hit = 50
      result = Inventory.add_item(inventory, 99996, 200)

      assert {:ok, new_inventory, 0} = result
      slot = Enum.at(new_inventory, 0)
      assert slot.amount == 50,
             "Expected new stack to be capped at 50 (item max_hit), got: #{slot.amount}"
    end
  end
end
