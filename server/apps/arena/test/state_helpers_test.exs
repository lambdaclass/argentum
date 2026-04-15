defmodule Arena.Map.StateHelpersTest do
  use ExUnit.Case, async: true

  alias Arena.Map.State
  import Arena.Test.MapStateFactory

  # ---------------------------------------------------------------------------
  # put_player/3
  # ---------------------------------------------------------------------------

  describe "put_player/3" do
    test "adds a new player to an empty players map" do
      state = map_state()
      result = State.put_player(state, 1, %{name: "Alice"})

      assert result.players == %{1 => %{name: "Alice"}}
    end

    test "overwrites an existing player with the same id" do
      state = map_state(players: %{1 => %{name: "Alice", hp: 100}})
      result = State.put_player(state, 1, %{name: "Alice", hp: 50})

      assert result.players[1] == %{name: "Alice", hp: 50}
    end

    test "supports multiple players coexisting" do
      state =
        map_state()
        |> State.put_player(1, %{name: "Alice"})
        |> State.put_player(2, %{name: "Bob"})
        |> State.put_player(3, %{name: "Carol"})

      assert map_size(result = state.players) == 3
      assert result[1].name == "Alice"
      assert result[2].name == "Bob"
      assert result[3].name == "Carol"
    end
  end

  # ---------------------------------------------------------------------------
  # update_player/3
  # ---------------------------------------------------------------------------

  describe "update_player/3" do
    test "updates an existing player with a function" do
      state = map_state(players: %{1 => %{hp: 100}})
      result = State.update_player(state, 1, fn p -> %{p | hp: p.hp - 25} end)

      assert result.players[1].hp == 75
    end

    test "returns state unchanged when player does not exist" do
      state = map_state(players: %{1 => %{hp: 100}})
      result = State.update_player(state, 999, fn p -> Map.put(p, :hp, 0) end)

      assert result === state
    end

    test "update function can modify multiple fields" do
      state = map_state(players: %{1 => %{hp: 100, mana: 50, alive: true}})

      result =
        State.update_player(state, 1, fn p ->
          %{p | hp: 0, alive: false}
        end)

      assert result.players[1] == %{hp: 0, mana: 50, alive: false}
    end
  end

  # ---------------------------------------------------------------------------
  # delete_player/2
  # ---------------------------------------------------------------------------

  describe "delete_player/2" do
    test "removes an existing player" do
      state = map_state(players: %{1 => %{name: "Alice"}, 2 => %{name: "Bob"}})
      result = State.delete_player(state, 1)

      assert result.players == %{2 => %{name: "Bob"}}
    end

    test "returns state unchanged when deleting a non-existent player" do
      state = map_state(players: %{1 => %{name: "Alice"}})
      result = State.delete_player(state, 999)

      assert result.players == %{1 => %{name: "Alice"}}
    end
  end

  # ---------------------------------------------------------------------------
  # put_npc/3
  # ---------------------------------------------------------------------------

  describe "put_npc/3" do
    test "adds a new npc" do
      state = map_state()
      result = State.put_npc(state, :npc_1, %{type: :goblin})

      assert result.npcs_live == %{npc_1: %{type: :goblin}}
    end

    test "overwrites an existing npc" do
      state = map_state(npcs_live: %{npc_1: %{type: :goblin, hp: 30}})
      result = State.put_npc(state, :npc_1, %{type: :goblin, hp: 10})

      assert result.npcs_live[:npc_1] == %{type: :goblin, hp: 10}
    end

    test "supports multiple npcs" do
      state =
        map_state()
        |> State.put_npc(:a, %{type: :wolf})
        |> State.put_npc(:b, %{type: :bear})

      assert map_size(state.npcs_live) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # update_npc/3
  # ---------------------------------------------------------------------------

  describe "update_npc/3" do
    test "updates an existing npc" do
      state = map_state(npcs_live: %{1 => %{hp: 50}})
      result = State.update_npc(state, 1, fn n -> %{n | hp: 25} end)

      assert result.npcs_live[1].hp == 25
    end

    test "returns state unchanged for non-existent npc" do
      state = map_state(npcs_live: %{1 => %{hp: 50}})
      result = State.update_npc(state, 999, fn n -> Map.put(n, :hp, 0) end)

      assert result === state
    end

    test "update function can modify multiple fields" do
      state = map_state(npcs_live: %{1 => %{hp: 50, aggro: nil, alive: true}})

      result =
        State.update_npc(state, 1, fn n ->
          %{n | hp: 0, alive: false}
        end)

      assert result.npcs_live[1] == %{hp: 0, aggro: nil, alive: false}
    end
  end

  # ---------------------------------------------------------------------------
  # delete_npc/2
  # ---------------------------------------------------------------------------

  describe "delete_npc/2" do
    test "removes an existing npc" do
      state = map_state(npcs_live: %{1 => %{type: :wolf}, 2 => %{type: :bear}})
      result = State.delete_npc(state, 1)

      assert result.npcs_live == %{2 => %{type: :bear}}
    end

    test "returns state unchanged for non-existent npc" do
      state = map_state(npcs_live: %{1 => %{type: :wolf}})
      result = State.delete_npc(state, 999)

      assert result.npcs_live == %{1 => %{type: :wolf}}
    end
  end

  # ---------------------------------------------------------------------------
  # put_meta/3
  # ---------------------------------------------------------------------------

  describe "put_meta/3" do
    test "adds a new meta key" do
      state = map_state()
      result = State.put_meta(state, :safe_zone, true)

      assert result.meta[:safe_zone] == true
    end

    test "overwrites an existing meta key" do
      state = map_state(meta: %{weather: :rain})
      result = State.put_meta(state, :weather, :sunny)

      assert result.meta[:weather] == :sunny
    end

    test "accepts a list as value" do
      state = map_state()
      result = State.put_meta(state, :spawn_points, [{10, 20}, {30, 40}])

      assert result.meta[:spawn_points] == [{10, 20}, {30, 40}]
    end

    test "accepts a nested map as value" do
      state = map_state()
      result = State.put_meta(state, :config, %{difficulty: :hard, pvp: true})

      assert result.meta[:config] == %{difficulty: :hard, pvp: true}
    end
  end

  # ---------------------------------------------------------------------------
  # put_ground_item/3
  # ---------------------------------------------------------------------------

  describe "put_ground_item/3" do
    test "adds an item at a position" do
      state = map_state()
      result = State.put_ground_item(state, {5, 10}, %{item_id: 42, qty: 1})

      assert result.ground_items[{5, 10}] == %{item_id: 42, qty: 1}
    end

    test "overwrites item at the same position" do
      state = map_state(ground_items: %{{5, 10} => %{item_id: 42}})
      result = State.put_ground_item(state, {5, 10}, %{item_id: 99})

      assert result.ground_items[{5, 10}] == %{item_id: 99}
    end
  end

  # ---------------------------------------------------------------------------
  # delete_ground_item/2
  # ---------------------------------------------------------------------------

  describe "delete_ground_item/2" do
    test "removes an item at a position" do
      state = map_state(ground_items: %{{1, 1} => %{item_id: 7}, {2, 2} => %{item_id: 8}})
      result = State.delete_ground_item(state, {1, 1})

      assert result.ground_items == %{{2, 2} => %{item_id: 8}}
    end

    test "does not crash when deleting at an empty position" do
      state = map_state(ground_items: %{})
      result = State.delete_ground_item(state, {99, 99})

      assert result.ground_items == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # General / structural edge cases
  # ---------------------------------------------------------------------------

  describe "structural guarantees" do
    test "all helpers return an %Arena.Map.State{} struct" do
      state = map_state()

      assert %State{} = State.put_player(state, 1, %{})
      assert %State{} = State.update_player(state, 1, & &1)
      assert %State{} = State.delete_player(state, 1)
      assert %State{} = State.put_npc(state, 1, %{})
      assert %State{} = State.update_npc(state, 1, & &1)
      assert %State{} = State.delete_npc(state, 1)
      assert %State{} = State.put_meta(state, :k, :v)
      assert %State{} = State.put_ground_item(state, {0, 0}, %{})
      assert %State{} = State.delete_ground_item(state, {0, 0})
    end

    test "helpers compose via pipe" do
      result =
        map_state()
        |> State.put_player(1, %{name: "Alice"})
        |> State.put_npc(:npc_1, %{type: :goblin})
        |> State.put_meta(:safe_zone, false)
        |> State.put_ground_item({5, 5}, %{item_id: 1})
        |> State.delete_player(1)
        |> State.delete_npc(:npc_1)
        |> State.delete_ground_item({5, 5})

      assert %State{} = result
      assert result.players == %{}
      assert result.npcs_live == %{}
      assert result.meta == %{safe_zone: false}
      assert result.ground_items == %{}
    end
  end
end
