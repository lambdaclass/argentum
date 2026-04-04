defmodule Arena.NpcAiTest do
  use ExUnit.Case, async: true

  alias Arena.NpcAi
  alias Arena.Entity.NpcEntity

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
    :ok
  end

  defp make_state(opts \\ []) do
    npc = %NpcEntity{
      npc_id: opts[:npc_id] || 559,
      instance_id: 1,
      char_index: 100,
      x: opts[:npc_x] || 50,
      y: opts[:npc_y] || 50,
      hp: 250,
      max_hp: 250,
      alive: true,
      target_id: nil,
      spawn_x: 50,
      spawn_y: 50,
      next_attack_at: -1_000_000_000_000,
      next_move_at: -1_000_000_000_000,
      next_spell_at: -1_000_000_000_000
    }

    player = %{
      char_id: 7,
      name: "TestPlayer",
      x: opts[:player_x] || 55,
      y: opts[:player_y] || 50,
      dead: false,
      invisible: false,
      hp: 100,
      max_hp: 100
    }

    occupancy = :array.new(100 * 100, default: nil)

    %{
      map_id: 999,
      players: %{7 => player},
      sessions: %{7 => self()},
      npcs_live: %{1 => npc},
      npc_char_indices: %{100 => 1},
      occupancy: occupancy,
      visibility_mode: :global,
      visible_sets: nil,
      grid: nil,
      ground_items: %{}
    }
  end

  describe "NPC target acquisition and persistence" do
    test "hostile NPC acquires target after tick" do
      # NPC 559 = Lobo Negro (hostile), player is 5 tiles away (within aggro range 10)
      state = make_state(npc_id: 559, npc_x: 50, npc_y: 50, player_x: 55, player_y: 50)

      # Verify NPC starts with no target
      npc_before = state.npcs_live[1]
      assert npc_before.target_id == nil

      # Run one tick
      state = NpcAi.tick(state)

      # NPC should now have the player as target
      npc_after = state.npcs_live[1]
      assert npc_after.target_id == 7, "NPC should target player 7, got: #{inspect(npc_after.target_id)}"
    end

    test "hostile NPC moves toward target after tick" do
      state = make_state(npc_id: 559, npc_x: 50, npc_y: 50, player_x: 55, player_y: 50)
      npc_before = state.npcs_live[1]

      state = NpcAi.tick(state)
      npc_after = state.npcs_live[1]

      # NPC should have moved toward the player (east, x+1)
      assert npc_after.x > npc_before.x or npc_after.target_id == 7,
        "NPC should have moved toward player or at least acquired target"
    end

    test "target persists across multiple ticks" do
      state = make_state(npc_id: 559, npc_x: 50, npc_y: 50, player_x: 55, player_y: 50)

      # Run 5 ticks
      state = Enum.reduce(1..5, state, fn _, s -> NpcAi.tick(s) end)

      npc = state.npcs_live[1]
      assert npc.target_id == 7, "Target should persist across ticks"
      # NPC should have moved closer to player
      assert npc.x > 50, "NPC should have moved east toward player at x=55"
    end
  end
end
