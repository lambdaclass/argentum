defmodule Arena.DropDriftTest do
  @moduledoc """
  Tests for three verified drop/inventory drifts against VB6 HandleDrop logic.

  D11: intirable semantics -- Intirable=1 means "cannot be dropped" (blocks drop)
  D9:  Missing trading/mounted/instransferible checks in drop handler
  D10: Gold dropping (slot 200) not supported

  Roadmap #4: `handle_drop_item/4` returns `{:ok, state, effects}`. Rejection
  no longer surfaces as `{:error, reason}` — the handler emits a console-message
  effect and the gold/inventory state is left untouched.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.InventoryHandlers
  alias Arena.Test.MapStateFactory
  alias AoEntities.PlayerEntity

  @gold_slot 200
  @gold_item_id 12

  setup_all do
    Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Arena.PubSub) do
      {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end

    unless Process.whereis(Arena.Data.GameData) do
      {:ok, _} = Arena.Data.GameData.start_link([])
    end

    :ok
  end

  # Build a basic entity at position (50, 50) with overrides
  defp make_entity(char_id, overrides) do
    base = %PlayerEntity{
      char_id: char_id,
      name: "TestPlayer#{char_id}",
      account_id: "acct_#{char_id}",
      x: 50,
      y: 50
    }

    Enum.reduce(overrides, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  # Build a state containing one player and a session (self()) for messages
  defp make_state(char_id, entity) do
    MapStateFactory.map_state(
      players: %{char_id => entity},
      sessions: %{char_id => self()},
      occupancy: %{{entity.x, entity.y} => {:player, char_id}}
    )
  end

  defp effect_payload_contains?(effects, needle) do
    Enum.any?(effects, fn
      {:send, _char_id, %{payload: payload}} when is_binary(payload) ->
        :binary.match(payload, needle) != :nomatch

      _ ->
        false
    end)
  end

  # ── D11: intirable semantics ──────────────────────────────────────────

  describe "D11: intirable semantics -- Intirable=1 blocks drop" do
    test "item with intirable=true (Intirable=1 in VB6) is BLOCKED from dropping" do
      # Verify parsing: Intirable=1 -> intirable=true
      parsed = Arena.Data.ItemDef.from_section(9990, %{"intirable" => "1"})
      assert parsed.intirable == true, "Intirable=1 must parse to intirable=true"

      # Verify parsing: Intirable=0 -> intirable=false
      parsed0 = Arena.Data.ItemDef.from_section(9991, %{"intirable" => "0"})
      assert parsed0.intirable == false, "Intirable=0 must parse to intirable=false"

      # Test the handler with a REAL item from game data that has intirable=true
      real_intirable_id = find_intirable_item()

      if real_intirable_id do
        real_def = Arena.Data.GameData.get_item(real_intirable_id)
        assert real_def.intirable == true

        inv =
          List.replace_at(
            List.duplicate(nil, 24),
            0,
            %{item_id: real_intirable_id, amount: 1, equipped: false}
          )

        ent = make_entity(2, inventory: inv)
        st = make_state(2, ent)

        {:ok, new_state, effects} = InventoryHandlers.handle_drop_item(st, 2, 0, 1)

        # Inventory must be untouched.
        assert new_state.players[2].inventory == inv

        # No ground item must be created.
        assert new_state.ground_items == %{}

        assert effect_payload_contains?(effects, "no se puede tirar"),
               "Item with intirable=true must emit a not-throwable console message"
      end
    end

    test "item with intirable=false (Intirable=0 in VB6) is ALLOWED to drop" do
      real_droppable_id = find_droppable_item()

      if real_droppable_id do
        inv =
          List.replace_at(
            List.duplicate(nil, 24),
            0,
            %{item_id: real_droppable_id, amount: 1, equipped: false}
          )

        ent = make_entity(3, inventory: inv)
        st = make_state(3, ent)

        {:ok, new_state, _effects} = InventoryHandlers.handle_drop_item(st, 3, 0, 1)

        # Drop succeeds: ground gains item, inventory loses it.
        assert Map.has_key?(new_state.ground_items, {50, 50})
        assert Enum.at(new_state.players[3].inventory, 0) == nil
      end
    end
  end

  # ── D9: Missing trading/mounted/instransferible checks ────────────────

  describe "D9: drop blocked while trading" do
    test "cannot drop items while trading (trade_partner_id != nil)" do
      real_droppable_id = find_droppable_item()

      if real_droppable_id do
        inv =
          List.replace_at(
            List.duplicate(nil, 24),
            0,
            %{item_id: real_droppable_id, amount: 1, equipped: false}
          )

        ent = make_entity(4, inventory: inv, trade_partner_id: 999)
        st = make_state(4, ent)

        {:ok, new_state, effects} = InventoryHandlers.handle_drop_item(st, 4, 0, 1)

        assert new_state.players[4].inventory == inv
        assert new_state.ground_items == %{}

        assert effect_payload_contains?(effects, "comercias"),
               "VB6: Comerciando blocks drop with comerciando console message"
      end
    end
  end

  describe "D9: drop blocked while mounted" do
    test "cannot drop items while mounted" do
      real_droppable_id = find_droppable_item()

      if real_droppable_id do
        inv =
          List.replace_at(
            List.duplicate(nil, 24),
            0,
            %{item_id: real_droppable_id, amount: 1, equipped: false}
          )

        ent = make_entity(5, inventory: inv, mounted: true)
        st = make_state(5, ent)

        {:ok, new_state, effects} = InventoryHandlers.handle_drop_item(st, 5, 0, 1)

        assert new_state.players[5].inventory == inv
        assert new_state.ground_items == %{}

        assert effect_payload_contains?(effects, "montura"),
               "VB6: Montado blocks drop with mount console message"
      end
    end
  end

  describe "D9: drop blocked for instransferible items" do
    test "cannot drop instransferible items" do
      # All real instransferible items in obj.dat also have intirable=true
      # and newbie=true, so other guards fire first. We verify the drop IS
      # blocked (the specific message depends on which guard fires first).
      real_instransferible_id = find_any_instransferible_item()

      if real_instransferible_id do
        inv =
          List.replace_at(
            List.duplicate(nil, 24),
            0,
            %{item_id: real_instransferible_id, amount: 1, equipped: false}
          )

        ent = make_entity(6, inventory: inv)
        st = make_state(6, ent)

        {:ok, new_state, effects} = InventoryHandlers.handle_drop_item(st, 6, 0, 1)

        assert new_state.players[6].inventory == inv
        assert new_state.ground_items == %{}

        # Any rejection message is acceptable as long as drop is blocked.
        rejected =
          effect_payload_contains?(effects, "newbies") or
            effect_payload_contains?(effects, "no se puede tirar")

        assert rejected, "VB6: Instransferible items must be blocked from dropping"
      end
    end

    test "instransferible guard exists in handler cond chain" do
      # Verify the instransferible check is present in the source code.
      source =
        File.read!(
          Path.join([File.cwd!(), "lib/arena/map/inventory_handlers.ex"])
        )

      assert source =~ "item_def.instransferible",
             "inventory_handlers.ex must check item_def.instransferible in drop guard"
    end
  end

  # ── D10: Gold drop (slot 200) ─────────────────────────────────────────

  describe "D10: gold drop via slot 200" do
    test "dropping gold (slot=200) deducts gold from entity" do
      ent = make_entity(10, gold: 5000)
      st = make_state(10, ent)

      {:ok, new_state, _effects} = InventoryHandlers.handle_drop_item(st, 10, @gold_slot, 1000)

      updated_entity = new_state.players[10]
      assert updated_entity.gold == 4000,
             "Gold should be deducted: 5000 - 1000 = 4000"
    end

    test "gold drop is capped at 100000" do
      ent = make_entity(11, gold: 500_000)
      st = make_state(11, ent)

      {:ok, new_state, _effects} =
        InventoryHandlers.handle_drop_item(st, 11, @gold_slot, 200_000)

      updated_entity = new_state.players[11]
      assert updated_entity.gold == 400_000,
             "Gold drop capped at 100000: 500000 - 100000 = 400000"
    end

    test "gold drop fails if insufficient gold" do
      ent = make_entity(12, gold: 50)
      st = make_state(12, ent)

      {:ok, new_state, effects} = InventoryHandlers.handle_drop_item(st, 12, @gold_slot, 100)

      assert new_state.players[12].gold == 50, "gold must NOT change on insufficient_gold"
      assert effect_payload_contains?(effects, "suficiente oro")
    end

    test "gold drop places gold on ground" do
      ent = make_entity(13, gold: 5000)
      st = make_state(13, ent)

      {:ok, new_state, _effects} = InventoryHandlers.handle_drop_item(st, 13, @gold_slot, 1000)

      ground = Map.get(new_state.ground_items, {50, 50})
      assert ground != nil, "Gold must appear on ground"
      assert ground.item_id == @gold_item_id
      assert ground.amount == 1000
    end

    test "gold drop while dead is blocked" do
      ent = make_entity(14, gold: 5000, dead: true)
      st = make_state(14, ent)

      {:ok, new_state, effects} = InventoryHandlers.handle_drop_item(st, 14, @gold_slot, 1000)

      assert new_state.players[14].gold == 5000, "gold must NOT change on dead"
      assert effects == [], "dead drop is a silent no-op"
    end

    test "gold drop while trading is blocked" do
      ent = make_entity(15, gold: 5000, trade_partner_id: 999)
      st = make_state(15, ent)

      {:ok, new_state, effects} = InventoryHandlers.handle_drop_item(st, 15, @gold_slot, 1000)

      assert new_state.players[15].gold == 5000
      assert effect_payload_contains?(effects, "comercias")
    end

    test "gold drop while mounted is blocked" do
      ent = make_entity(16, gold: 5000, mounted: true)
      st = make_state(16, ent)

      {:ok, new_state, effects} = InventoryHandlers.handle_drop_item(st, 16, @gold_slot, 1000)

      assert new_state.players[16].gold == 5000
      assert effect_payload_contains?(effects, "montura")
    end
  end

  # ── Helpers to find real items from loaded game data ──────────────────

  defp find_intirable_item do
    find_item_by(fn def_ -> def_.intirable == true and not def_.newbie end)
  end

  defp find_droppable_item do
    find_item_by(fn def_ ->
      def_.intirable == false and not def_.newbie and
        not def_.instransferible and not def_.destruye and
        def_.obj_type not in [13, 14, 44]
    end)
  end

  defp find_any_instransferible_item do
    find_item_by(fn def_ -> def_.instransferible == true end)
  end

  defp find_item_by(pred) do
    Enum.find_value(1..1000, fn id ->
      case Arena.Data.GameData.get_item(id) do
        nil -> nil
        def_ -> if pred.(def_), do: def_.id, else: nil
      end
    end)
  end
end
