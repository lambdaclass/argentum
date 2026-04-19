defmodule Arena.MovementCollisionDriftTest do
  @moduledoc """
  VB6 parity drift #9: movement collision checks `gm` instead of `invisible`.

  VB6 ref: a player can walk through another player ONLY if they are dead
  (Muerto = 1) or AdminInvisible. A visible GM blocks the tile like a
  normal player.

  The bug: `movement.ex:98` checks `other.gm` instead of `other.invisible`,
  allowing walk-through of visible GMs (which VB6 does not allow).
  """
  use ExUnit.Case, async: true

  alias Arena.Map.Movement
  alias AoEntities.PlayerEntity

  import Arena.Test.MapStateFactory

  @test_map_id 996

  setup_all do
    Arena.Metrics.setup()

    case Arena.Settings.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Load a fully-walkable 100x100 test map into TileGrid NIF
    tiles = List.duplicate(0, 100 * 100)
    TileGrid.load_map(@test_map_id, tiles)

    on_exit(fn -> TileGrid.unload_map(@test_map_id) end)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp start_receiver(label) do
    parent = self()
    spawn_link(fn -> receiver_loop(parent, label) end)
  end

  defp receiver_loop(parent, label) do
    receive do
      msg ->
        send(parent, {:receiver, label, msg})
        receiver_loop(parent, label)
    end
  end

  defp make_player(id, overrides \\ %{}) do
    Map.merge(
      %PlayerEntity{
        char_id: id,
        char_index: id,
        x: 50,
        y: 50,
        heading: :south,
        name: "Player#{id}",
        body_id: 1,
        head_id: 1,
        invisible: false,
        oculto: false,
        gm: false,
        dead: false,
        speeding: 1.0,
        equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil, saddle: nil},
        hp: 100,
        max_hp: 100,
        mana: 100,
        max_mana: 100,
        guild_id: 0,
        guild_level: 0,
        skills: %{},
        class: :guerrero,
        buffs: [],
        last_step_at: -1_000_000_000_000,
        next_move_at: -1_000_000_000_000,
        speed_hack_counter: 0.0,
        paralyzed: false,
        immobilized: false,
        penalty: 0,
        navigating: false,
        resting: false,
        meditating: false
      },
      overrides
    )
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Tests for tile collision with other players
  # ═══════════════════════════════════════════════════════════════════════

  describe "movement collision — VB6: only dead or invisible players can be walked through" do
    test "visible GM (gm: true, invisible: false) blocks movement" do
      sess1 = start_receiver(:sess1)
      sess2 = start_receiver(:sess2)

      mover = make_player(1, %{x: 50, y: 50})
      blocker = make_player(2, %{x: 51, y: 50, gm: true, invisible: false, dead: false})

      state =
        map_state(
          map_id: @test_map_id,
          players: %{1 => mover, 2 => blocker},
          sessions: %{1 => sess1, 2 => sess2},
          occupancy: %{{50, 50} => {:player, 1}, {51, 50} => {:player, 2}},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      {:reply, result, _state} = Movement.handle_move(state, 1, :east)

      assert result == {:error, :blocked},
        "A visible GM should block the tile just like a normal player (VB6 parity)"
    end

    test "invisible player (invisible: true) allows walk-through" do
      sess1 = start_receiver(:sess1)
      sess2 = start_receiver(:sess2)

      mover = make_player(1, %{x: 50, y: 50})
      invisible = make_player(2, %{x: 51, y: 50, invisible: true, dead: false})

      state =
        map_state(
          map_id: @test_map_id,
          players: %{1 => mover, 2 => invisible},
          sessions: %{1 => sess1, 2 => sess2},
          occupancy: %{{50, 50} => {:player, 1}, {51, 50} => {:player, 2}},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      {:reply, result, _state} = Movement.handle_move(state, 1, :east)

      assert result == {:ok, {51, 50}},
        "An invisible player should be walk-throughable (swapped out of the way)"
    end

    test "dead player allows walk-through" do
      sess1 = start_receiver(:sess1)
      sess2 = start_receiver(:sess2)

      mover = make_player(1, %{x: 50, y: 50})
      dead_player = make_player(2, %{x: 51, y: 50, dead: true})

      state =
        map_state(
          map_id: @test_map_id,
          players: %{1 => mover, 2 => dead_player},
          sessions: %{1 => sess1, 2 => sess2},
          occupancy: %{{50, 50} => {:player, 1}, {51, 50} => {:player, 2}},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      {:reply, result, _state} = Movement.handle_move(state, 1, :east)

      assert result == {:ok, {51, 50}},
        "A dead player should be walk-throughable (swapped out of the way)"
    end

    test "normal living player blocks movement" do
      sess1 = start_receiver(:sess1)
      sess2 = start_receiver(:sess2)

      mover = make_player(1, %{x: 50, y: 50})
      normal = make_player(2, %{x: 51, y: 50, gm: false, invisible: false, dead: false})

      state =
        map_state(
          map_id: @test_map_id,
          players: %{1 => mover, 2 => normal},
          sessions: %{1 => sess1, 2 => sess2},
          occupancy: %{{50, 50} => {:player, 1}, {51, 50} => {:player, 2}},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      {:reply, result, _state} = Movement.handle_move(state, 1, :east)

      assert result == {:error, :blocked},
        "A normal living player should block the tile"
    end

    test "invisible GM (gm: true, invisible: true) allows walk-through" do
      sess1 = start_receiver(:sess1)
      sess2 = start_receiver(:sess2)

      mover = make_player(1, %{x: 50, y: 50})
      invis_gm = make_player(2, %{x: 51, y: 50, gm: true, invisible: true, dead: false})

      state =
        map_state(
          map_id: @test_map_id,
          players: %{1 => mover, 2 => invis_gm},
          sessions: %{1 => sess1, 2 => sess2},
          occupancy: %{{50, 50} => {:player, 1}, {51, 50} => {:player, 2}},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      {:reply, result, _state} = Movement.handle_move(state, 1, :east)

      assert result == {:ok, {51, 50}},
        "An invisible GM should be walk-throughable"
    end
  end
end
