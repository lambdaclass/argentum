defmodule Arena.Adversarial.MerchantSessionAuthorityTest do
  @moduledoc """
  Adversarial tests for stale merchant sessions.

  Opening commerce should not grant indefinite authority to buy or sell after the
  merchant despawns or after the player walks far away.
  """

  use ExUnit.Case, async: false

  alias Arena.Data.GameData
  alias Arena.Map.Commerce

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp make_entity(overrides \\ %{}) do
    Map.merge(
      %{
        char_id: :player,
        x: 50,
        y: 50,
        dead: false,
        gold: 50_000,
        commerce_npc_id: nil,
        inventory: List.duplicate(nil, 24)
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
          if Map.get(item, :newbie, false) or Map.get(item, :instransferible, false), do: nil, else: id

        _ ->
          nil
      end
    end)
  end

  describe "buy after stale merchant session" do
    test "buy is rejected after the merchant despawns" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      entity = make_entity(%{commerce_npc_id: merchant_id, gold: 50_000})
      state = make_map_state(entity)

      {:reply, result, _new_state} = Commerce.handle_commerce_buy(state, :player, 1, 1)

      assert result in [{:error, :merchant_gone}, {:error, :too_far}, {:error, :no_commerce}]
    end

    test "buy is rejected after walking far away from the merchant" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      merchant = %{npc_id: merchant_id, x: 51, y: 50, instance_id: :merchant}
      entity = make_entity(%{
        commerce_npc_id: merchant_id,
        commerce_npc_instance_id: :merchant,
        x: 60,
        y: 50,
        gold: 50_000
      })
      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:reply, result, _new_state} = Commerce.handle_commerce_buy(state, :player, 1, 1)

      assert result in [{:error, :too_far}, {:error, :merchant_gone}, {:error, :no_commerce}]
    end

    test "buy is rejected when the original merchant despawns but another merchant with the same npc_id is nearby" do
      merchant_id = find_merchant_npc_id()
      assert merchant_id != nil

      replacement_merchant = %{npc_id: merchant_id, x: 51, y: 50, instance_id: :replacement}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :original,
          x: 50,
          y: 50,
          gold: 50_000
        })

      state = make_map_state(entity, npcs_live: %{replacement: replacement_merchant})

      {:reply, result, _new_state} = Commerce.handle_commerce_buy(state, :player, 1, 1)

      assert result in [{:error, :merchant_gone}, {:error, :too_far}, {:error, :no_commerce}]
    end
  end

  describe "sell after stale merchant session" do
    test "sell is rejected after the merchant despawns" do
      merchant_id = find_merchant_npc_id()
      item_id = find_sellable_item_id()
      assert merchant_id != nil
      assert item_id != nil

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          gold: 100,
          inventory: List.replace_at(List.duplicate(nil, 24), 0, %{item_id: item_id, amount: 1, equipped: false})
        })

      state = make_map_state(entity)

      {:reply, result, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      assert result in [{:error, :merchant_gone}, {:error, :too_far}, {:error, :no_commerce}]
      assert new_state.players[:player].gold == 100
      assert new_state.players[:player].inventory |> Enum.at(0) != nil
    end

    test "sell is rejected after walking far away from the merchant" do
      merchant_id = find_merchant_npc_id()
      item_id = find_sellable_item_id()
      assert merchant_id != nil
      assert item_id != nil

      merchant = %{npc_id: merchant_id, x: 51, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          x: 60,
          y: 50,
          gold: 100,
          inventory: List.replace_at(List.duplicate(nil, 24), 0, %{item_id: item_id, amount: 1, equipped: false})
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:reply, result, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      assert result in [{:error, :too_far}, {:error, :merchant_gone}, {:error, :no_commerce}]
      assert new_state.players[:player].gold == 100
      assert new_state.players[:player].inventory |> Enum.at(0) != nil
    end

    test "sell is rejected when the original merchant despawns but another merchant with the same npc_id is nearby" do
      merchant_id = find_merchant_npc_id()
      item_id = find_sellable_item_id()
      assert merchant_id != nil
      assert item_id != nil

      replacement_merchant = %{npc_id: merchant_id, x: 51, y: 50, instance_id: :replacement}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :original,
          x: 50,
          y: 50,
          gold: 100,
          inventory: List.replace_at(List.duplicate(nil, 24), 0, %{item_id: item_id, amount: 1, equipped: false})
        })

      state = make_map_state(entity, npcs_live: %{replacement: replacement_merchant})

      {:reply, result, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      assert result in [{:error, :merchant_gone}, {:error, :too_far}, {:error, :no_commerce}]
      assert new_state.players[:player].gold == 100
      assert new_state.players[:player].inventory |> Enum.at(0) != nil
    end
  end

  describe "sell equipped item" do
    test "sell is rejected when the item is equipped" do
      merchant_id = find_merchant_npc_id()
      item_id = find_sellable_item_id()
      assert merchant_id != nil
      assert item_id != nil

      merchant = %{npc_id: merchant_id, x: 50, y: 50, instance_id: :merchant}

      entity =
        make_entity(%{
          commerce_npc_id: merchant_id,
          commerce_npc_instance_id: :merchant,
          x: 50,
          y: 50,
          gold: 100,
          inventory:
            List.replace_at(List.duplicate(nil, 24), 0, %{
              item_id: item_id,
              amount: 1,
              equipped: true
            })
        })

      state = make_map_state(entity, npcs_live: %{merchant: merchant})

      {:reply, result, new_state} = Commerce.handle_commerce_sell(state, :player, 1, 1)

      assert result == {:error, :equipped_item}
      # Inventory and gold must remain unchanged
      assert new_state.players[:player].gold == 100
      assert new_state.players[:player].inventory |> Enum.at(0) != nil
    end
  end
end
