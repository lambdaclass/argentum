defmodule Arena.Map.StateTest do
  use ExUnit.Case, async: true

  alias Arena.Map.State
  import Arena.Test.MapStateFactory

  # ---------------------------------------------------------------------------
  # Test 1: State struct has all expected keys with defaults
  # ---------------------------------------------------------------------------

  describe "struct defaults" do
    test "creating a State with only required keys fills sensible defaults" do
      state = %State{map_id: 1}

      assert state.map_id == 1
      assert state.loading == false
      assert state.meta == %{}
      assert state.players == %{}
      assert state.sessions == %{}
      assert state.npcs_live == %{}
      assert state.npc_char_indices == %{}
      assert state.occupancy == nil
      assert state.visibility_mode == :global
      assert state.grid == nil
      assert state.visible_sets == nil
      assert state.ground_items == %{}
      assert state.next_char_index == 1
      assert state.monitors == %{}
      assert state.monitor_refs == %{}
      assert state.thirst_tick_counter == 0
      assert state.hunger_tick_counter == 0
      assert state.hunger_thirst_tick_counter == 0
      assert state.penalty_tick_counter == 0
      assert state.gm_blocked_tiles == MapSet.new()
      assert state.triggers == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2: State struct enforces required keys
  # ---------------------------------------------------------------------------

  describe "enforce_keys" do
    test "creating a State without map_id raises ArgumentError" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(State, [])
      end
    end

    test "creating a State with map_id succeeds" do
      state = struct!(State, map_id: 42)
      assert state.map_id == 42
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3: State update syntax works
  # ---------------------------------------------------------------------------

  describe "struct update syntax" do
    test "update via %{state | key: val} works" do
      state = %State{map_id: 1}
      updated = %{state | players: %{1 => :test}}

      assert updated.players == %{1 => :test}
      assert updated.map_id == 1
    end

    test "multiple fields can be updated at once" do
      state = %State{map_id: 1}

      updated = %{state |
        players: %{1 => :alice},
        sessions: %{1 => self()},
        loading: true
      }

      assert updated.players == %{1 => :alice}
      assert updated.sessions == %{1 => self()}
      assert updated.loading == true
    end
  end

  # ---------------------------------------------------------------------------
  # Test 4: State rejects unknown keys
  # ---------------------------------------------------------------------------

  describe "unknown keys" do
    test "update with unknown key raises KeyError" do
      state = %State{map_id: 1}

      assert_raise KeyError, fn ->
        %{state | fake_key: true}
      end
    end

    test "struct!/2 with unknown key raises KeyError" do
      assert_raise KeyError, fn ->
        struct!(State, map_id: 1, bogus_field: 42)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test 5: MapStateFactory produces valid State structs
  # ---------------------------------------------------------------------------

  describe "MapStateFactory" do
    test "map_state/0 returns a %Arena.Map.State{} struct" do
      state = map_state()
      assert %State{} = state
      assert state.map_id == 1
    end

    test "map_state/1 accepts overrides" do
      state = map_state(map_id: 99, players: %{1 => :test})

      assert %State{} = state
      assert state.map_id == 99
      assert state.players == %{1 => :test}
    end

    test "map_state/0 initializes occupancy array" do
      state = map_state()
      assert state.occupancy != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Test 6: All dynamic keys have explicit defaults (adversarial)
  # ---------------------------------------------------------------------------

  describe "dynamic keys have explicit defaults" do
    test "thirst_tick_counter defaults to 0" do
      state = %State{map_id: 1}
      assert state.thirst_tick_counter == 0
    end

    test "hunger_tick_counter defaults to 0" do
      state = %State{map_id: 1}
      assert state.hunger_tick_counter == 0
    end

    test "hunger_thirst_tick_counter defaults to 0" do
      state = %State{map_id: 1}
      assert state.hunger_thirst_tick_counter == 0
    end

    test "penalty_tick_counter defaults to 0" do
      state = %State{map_id: 1}
      assert state.penalty_tick_counter == 0
    end

    test "gm_blocked_tiles defaults to empty MapSet" do
      state = %State{map_id: 1}
      assert state.gm_blocked_tiles == MapSet.new()
    end

    test "triggers defaults to empty map" do
      state = %State{map_id: 1}
      assert state.triggers == %{}
    end

    test "all previously-dynamic keys are accessible via dot notation on factory state" do
      state = map_state()

      # These would crash with KeyError if the keys were missing from the struct
      assert state.thirst_tick_counter == 0
      assert state.hunger_tick_counter == 0
      assert state.hunger_thirst_tick_counter == 0
      assert state.penalty_tick_counter == 0
      assert state.gm_blocked_tiles == MapSet.new()
      assert state.triggers == %{}
    end
  end
end
