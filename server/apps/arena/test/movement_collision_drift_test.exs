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

  # ═══════════════════════════════════════════════════════════════════════
  # Packet byte-level fixtures (carry-forward from Phase 1 item 4):
  # movement broadcast, mover pos_update, heading, and the out-of-band
  # transfer control message.
  # ═══════════════════════════════════════════════════════════════════════

  describe "movement packet bytes" do
    test "successful east step: mover gets ePosUpdate, observer gets eCharacterMove" do
      sess1 = start_receiver(:sess1)
      sess2 = start_receiver(:sess2)

      mover = make_player(1, %{x: 50, y: 50})
      # Observer sits two tiles east so it does not block the (51,50) step but
      # is still in the (global) AoI and receives the move broadcast.
      observer = make_player(2, %{x: 52, y: 50})

      state =
        map_state(
          map_id: @test_map_id,
          players: %{1 => mover, 2 => observer},
          sessions: %{1 => sess1, 2 => sess2},
          occupancy: %{{50, 50} => {:player, 1}, {52, 50} => {:player, 2}},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      {:reply, {:ok, {51, 50}}, _state} = Movement.handle_move(state, 1, :east)

      pos_id = AoProtocol.PacketIds.Server.pos_update()
      move_id = AoProtocol.PacketIds.Server.character_move()

      # Byte-level: ePosUpdate (31) is unicast to the mover — x(Int8) + y(Int8)
      # carrying the new tile (51, 50).
      assert_receive {:receiver, :sess1, {:egress, %{payload: <<^pos_id::little-signed-16, 51, 50>>}}}

      # Byte-level: eCharacterMove (44) fans to the observer —
      # char_index(Int16) + x(Int8) + y(Int8) for the mover's char_index (1)
      # and its new tile.
      assert_receive {:receiver, :sess2,
                      {:egress, %{payload: <<^move_id::little-signed-16, 1::little-signed-16, 51, 50>>}}}

      # The mover must NOT receive its own character_move broadcast (the
      # AoI fanout excludes the originator).
      refute_receive {:receiver, :sess1,
                      {:egress, %{payload: <<^move_id::little-signed-16, _::binary>>}}}
    end

    test "change heading: observer gets eCharacterChange carrying the new heading" do
      sess1 = start_receiver(:sess1)
      sess2 = start_receiver(:sess2)

      # Mover faces south (heading_to_int 3); flip to north (1).
      mover = make_player(1, %{x: 50, y: 50, heading: :south, body_id: 1, head_id: 1})
      observer = make_player(2, %{x: 52, y: 50})

      state =
        map_state(
          map_id: @test_map_id,
          players: %{1 => mover, 2 => observer},
          sessions: %{1 => sess1, 2 => sess2},
          occupancy: %{{50, 50} => {:player, 1}, {52, 50} => {:player, 2}},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      {:noreply, _state} = Movement.handle_change_heading(state, 1, :north)

      cc_id = AoProtocol.PacketIds.Server.character_change()

      # Byte-level: eCharacterChange — char_index(Int16) + flags(Int8) +
      # body(Int16) + head(Int16) + heading(Int8) + ... The heading byte must
      # be 1 (north); char_index is the mover's (1).
      assert_receive {:receiver, :sess2,
                      {:egress,
                       %{
                         payload:
                           <<^cc_id::little-signed-16, 1::little-signed-16, _flags,
                             _body::little-signed-16, _head::little-signed-16, heading_byte,
                             _rest::binary>>
                       }}}

      assert heading_byte == 1, "heading byte must encode :north (heading_to_int 1)"
    end

    test "stepping onto a tile-exit: out-of-band transfer control message, pos_update suppressed" do
      sess1 = start_receiver(:sess1)
      sess2 = start_receiver(:sess2)

      mover = make_player(1, %{x: 50, y: 50})
      observer = make_player(2, %{x: 52, y: 50})

      state =
        map_state(
          map_id: @test_map_id,
          players: %{1 => mover, 2 => observer},
          sessions: %{1 => sess1, 2 => sess2},
          occupancy: %{{50, 50} => {:player, 1}, {52, 50} => {:player, 2}},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{
              {51, 50} =>
                Arena.World.ExitAnnotations.synthetic(
                  %{dest_map: 5, dest_x: 30, dest_y: 40},
                  :walkable,
                  true
                )
            }}
        )

      {:reply, {:ok, {51, 50}}, _state} = Movement.handle_move(state, 1, :east)

      # The transfer is OUT-OF-BAND: it is not an encoded wire packet. The
      # `:transfer` effect is delivered as a control message straight to the
      # mover's session process (the session then drives enter(dest_map),
      # which is where the client-visible eChangeMap is produced).
      assert_receive {:receiver, :sess1, {:transfer, 5, 30, 40, _entity}}

      # On a transfer, the mover's own ePosUpdate is suppressed (the dest-map
      # enter repositions the client) — assert it never arrives.
      pos_id = AoProtocol.PacketIds.Server.pos_update()

      refute_receive {:receiver, :sess1,
                      {:egress, %{payload: <<^pos_id::little-signed-16, _::binary>>}}}
    end

    test "a refused arrival corrects the client to the position it never left" do
      # The other half of W-0105, tested through the handler rather than through
      # `check_tile_exit/5`, because the correction is emitted by the movement decision above
      # it. A client that predicts locally would otherwise keep drawing the character on the
      # transition band while the server has them where they started.
      sess1 = start_receiver(:sess1)
      mover = make_player(1, %{x: 50, y: 50})

      state =
        map_state(
          map_id: @test_map_id,
          players: %{1 => mover},
          sessions: %{1 => sess1},
          occupancy: %{{50, 50} => {:player, 1}},
          visibility_mode: :global,
          meta: %{
            tile_exit_map: %{
              {51, 50} =>
                Arena.World.ExitAnnotations.synthetic(
                  %{dest_map: 5, dest_x: 30, dest_y: 40},
                  :solid,
                  true
                )
            }
          }
        )

      assert {:reply, {:error, {:arrival_blocked, :arrival_solid}}, returned} =
               Movement.handle_move(state, 1, :east)

      # The character has not moved and is still owned here.
      assert returned.players[1].x == 50
      assert returned.players[1].y == 50
      assert map_size(returned.players) == 1

      # Exactly one authoritative position, and it names the tile they never left.
      pos_id = AoProtocol.PacketIds.Server.pos_update()

      assert_receive {:receiver, :sess1,
                      {:egress, %{payload: <<^pos_id::little-signed-16, rest::binary>>}}}

      assert <<50::little-unsigned-8, 50::little-unsigned-8, _::binary>> = rest

      refute_receive {:receiver, :sess1,
                      {:egress, %{payload: <<^pos_id::little-signed-16, _::binary>>}}}

      # And no handoff was begun.
      refute_receive {:receiver, :sess1, {:transfer, _, _, _, _}}
    end
  end
end
