defmodule Arena.HungerThirstTest do
  @moduledoc """
  Tests for hunger/thirst drain in the regen tick.

  VB6 behavior:
  - Hunger and thirst decrement by 1 each regen tick
  - At 0 hunger: player takes starvation damage, regen is blocked
  - At 0 thirst: player takes dehydration damage, regen is blocked
  - Dead players don't drain
  - Client receives update_hunger_and_thirst packet on change
  """
  use ExUnit.Case, async: true

  alias Arena.Map.{CombatHandlers, StatusTicks}
  alias Arena.Entity.PlayerEntity

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # VB6: IntervaloSed = 54 regen ticks, IntervaloHambre = 60 regen ticks.
  # Set counters to interval-1 so the next tick triggers the drain.
  defp make_state(players, opts \\ []) do
    %{
      players: players,
      sessions: %{},
      npcs_live: %{},
      meta: %{safe_zone: false},
      visibility_mode: :global,
      thirst_tick_counter: Keyword.get(opts, :thirst_counter, 53),
      hunger_tick_counter: Keyword.get(opts, :hunger_counter, 59)
    }
  end

  describe "hunger/thirst drain in regen tick" do
    test "hunger and thirst decrement by 10 each tick" do
      entity = %PlayerEntity{char_id: 1, hunger: 50, thirst: 60}
      state = make_state(%{1 => entity})

      new_state = StatusTicks.process_regen_tick(state)
      player = new_state.players[1]

      assert player.hunger == 40, "hunger should drain by 10, got #{player.hunger}"
      assert player.thirst == 50, "thirst should drain by 10, got #{player.thirst}"
    end

    test "hunger and thirst don't go below 0" do
      entity = %PlayerEntity{char_id: 1, hunger: 0, thirst: 0}
      state = make_state(%{1 => entity})

      new_state = StatusTicks.process_regen_tick(state)
      player = new_state.players[1]

      assert player.hunger == 0
      assert player.thirst == 0
    end

    test "dead players don't drain hunger or thirst" do
      entity = %PlayerEntity{char_id: 1, hunger: 50, thirst: 50, dead: true}
      state = make_state(%{1 => entity})

      new_state = StatusTicks.process_regen_tick(state)
      player = new_state.players[1]

      assert player.hunger == 50, "dead players should not lose hunger"
      assert player.thirst == 50, "dead players should not lose thirst"
    end

    test "starvation deals damage when hunger reaches 0" do
      # VB6: HP damage only when stamina == 0 AND starving
      entity = %PlayerEntity{char_id: 1, hp: 100, max_hp: 100, hunger: 0, thirst: 50, stamina: 0}
      state = make_state(%{1 => entity})

      new_state = StatusTicks.process_regen_tick(state)
      player = new_state.players[1]

      assert player.hp < 100, "starvation should deal damage, hp=#{player.hp}"
    end

    test "dehydration deals damage when thirst reaches 0" do
      # VB6: HP damage only when stamina == 0 AND dehydrated
      entity = %PlayerEntity{char_id: 1, hp: 100, max_hp: 100, hunger: 50, thirst: 0, stamina: 0}
      state = make_state(%{1 => entity})

      new_state = StatusTicks.process_regen_tick(state)
      player = new_state.players[1]

      assert player.hp < 100, "dehydration should deal damage, hp=#{player.hp}"
    end

    test "regen is blocked when hunger is 0" do
      entity = %PlayerEntity{
        char_id: 1,
        hp: 50,
        max_hp: 100,
        hunger: 0,
        thirst: 50,
        resting: true
      }

      state = make_state(%{1 => entity})

      new_state = StatusTicks.process_regen_tick(state)
      player = new_state.players[1]

      # HP should not increase (starvation damage may reduce it further)
      assert player.hp <= 50, "resting should not regen HP when starving, hp=#{player.hp}"
    end

    test "regen is blocked when thirst is 0" do
      entity = %PlayerEntity{
        char_id: 1,
        mana: 50,
        max_mana: 100,
        hunger: 50,
        thirst: 0,
        meditating: true
      }

      state = make_state(%{1 => entity})

      new_state = StatusTicks.process_regen_tick(state)
      player = new_state.players[1]

      assert player.mana <= 50, "meditating should not regen mana when dehydrated, mana=#{player.mana}"
    end

    test "starvation can kill a player" do
      # VB6: HP damage only when stamina == 0 AND starving
      entity = %PlayerEntity{char_id: 1, hp: 1, max_hp: 100, hunger: 0, thirst: 50, stamina: 0}
      state = make_state(%{1 => entity})

      new_state = StatusTicks.process_regen_tick(state)
      player = new_state.players[1]

      assert player.hp <= 0, "starvation should be able to kill"
      assert player.dead == true, "player should be marked dead"
    end
  end
end
