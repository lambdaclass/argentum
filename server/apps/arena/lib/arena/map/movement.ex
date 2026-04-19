defmodule Arena.Map.Movement do
  @moduledoc """
  Movement-related handler logic extracted from `Arena.Map.MapServer`.

  Contains walking, tile-exit detection, and heading changes.
  """

  alias Arena.Map.{Helpers, Visibility}
  alias AoProtocol.Server.Encoder

  require Logger

  # ---- Movement ----

  @doc """
  Handle a move request for char_id in the given direction.
  Returns `{:reply, term, state}`.
  """
  def handle_move(state, char_id, direction) do
    start = System.monotonic_time()
    result = do_handle_move(state, char_id, direction)
    duration = System.monotonic_time() - start

    move_result =
      case result do
        {:reply, :ok, _} -> :ok
        {:reply, {:ok, _}, _} -> :ok
        {:reply, {:error, reason}, _} -> reason
      end

    :telemetry.execute([:arena, :map, :move], %{duration: duration},
      %{map_id: state.map_id, result: move_result})

    result
  end

  defp do_handle_move(state, char_id, direction) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)
        min_interval = trunc(base_walk_interval_ms() / entity.speeding)

        cond do
          entity.paralyzed or entity.immobilized or entity.penalty > 0 ->
            {:reply, {:error, :paralyzed}, state}

          now < entity.next_move_at ->
            # Too early — silently ignore (VB6 behavior)
            {:reply, {:error, :too_early}, state}

          true ->
            # Speed hack accumulator
            elapsed = max(now - entity.last_step_at, 1)
            delta = (min_interval - elapsed) / min_interval

            new_counter =
              if delta > 0,
                do: entity.speed_hack_counter + delta,
                else: max(entity.speed_hack_counter + delta * 5, 0.0)

            if new_counter > speed_hack_threshold() do
              # Snap back — reject move, apply penalty
              Logger.warning("[ANTICHEAT] speed_hack char_id=#{char_id} counter=#{Float.round(new_counter, 2)}")
              entity = %{entity | speed_hack_counter: 0.0, next_move_at: now + min_interval * 2}
              players = Map.put(state.players, char_id, entity)

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:pos_update, %{x: entity.x, y: entity.y}})}
              )

              {:reply, {:error, :speed_hack}, %{state | players: players}}
            else
              entity = %{entity | speed_hack_counter: new_counter}

              case TileGrid.move_entity(state.map_id, entity.x, entity.y, direction) do
                {:ok, %TileGrid.Position{x: nx, y: ny}} ->
                  # VB6: water tiles (value 2) require boat
                  tile_val = TileGrid.get_tile(state.map_id, nx, ny)
                  water_blocked = tile_val == 2 and not entity.navigating

                  cond do
                    water_blocked ->
                      {:reply, {:error, :blocked}, state}

                    Helpers.get_occupancy(state.occupancy, nx, ny) == nil ->
                      # Normal move into empty tile
                      state = do_move(state, char_id, entity, nx, ny, direction, now, min_interval)
                      {:reply, {:ok, {nx, ny}}, state}

                    match?({:player, _}, Helpers.get_occupancy(state.occupancy, nx, ny)) ->
                      # VB6: only dead/GM-invisible players get pushed out of the way.
                      # Living visible players block the tile.
                      {:player, other_id} = Helpers.get_occupancy(state.occupancy, nx, ny)
                      other = Map.get(state.players, other_id)

                      if other != nil and (other.dead or other.gm) do
                        old_x = entity.x
                        old_y = entity.y

                        state = do_move(state, char_id, entity, nx, ny, direction, now, min_interval)

                        # Push the dead/invisible player to our old position
                        other = Map.get(state.players, other_id) || other
                        opposite = Helpers.opposite_heading(direction)
                        swapped_other = %{other | x: old_x, y: old_y, heading: opposite}

                        players = Map.put(state.players, other_id, swapped_other)
                        occupancy = Helpers.set_occupancy(state.occupancy, old_x, old_y, {:player, other_id})
                        grid = Visibility.maybe_grid_remove(state, other.x, other.y, other_id)
                        grid = Visibility.maybe_grid_add(%{state | grid: grid}, old_x, old_y, other_id)

                        state = %{state | players: players, occupancy: occupancy, grid: grid}

                        Helpers.send_to_session(
                          state.sessions,
                          other_id,
                          {:send_raw, Encoder.encode({:pos_update, %{x: old_x, y: old_y}})}
                        )

                        swap_raw =
                          Encoder.encode({:character_move, %{char_index: swapped_other.char_index, x: old_x, y: old_y}})

                        Visibility.broadcast_visible(state, old_x, old_y, other_id, fn pid ->
                          send(pid, {:send_raw, swap_raw})
                        end)

                        {:reply, {:ok, {nx, ny}}, state}
                      else
                        {:reply, {:error, :blocked}, state}
                      end

                    true ->
                      # NPC or other non-swappable occupant
                      {:reply, {:error, :blocked}, state}
                  end

                {:error, :blocked} ->
                  {:reply, {:error, :blocked}, state}
              end
            end

            # speed hack else
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  # ---- Heading ----

  @doc """
  Handle a heading change for char_id.
  Returns `{:noreply, state}`.
  """
  def handle_change_heading(state, char_id, heading) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | heading: heading}
        players = Map.put(state.players, char_id, entity)

        state = %{state | players: players}
        heading_raw = Encoder.encode(Helpers.character_change_packet(entity))

        # Invisible players: only broadcast heading to GMs
        if entity.invisible do
          Visibility.broadcast_visible_gm_only(state, entity.x, entity.y, char_id, fn pid ->
            send(pid, {:send_raw, heading_raw})
          end)
        else
          Visibility.broadcast_visible(state, entity.x, entity.y, char_id, fn pid ->
            send(pid, {:send_raw, heading_raw})
          end)
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ---- Internal ----

  @doc """
  Move a player to (nx, ny), update occupancy/grid/visibility, send packets.
  Returns updated state.
  """
  def do_move(state, char_id, entity, nx, ny, direction, now, min_interval) do
    # VB6: spell invisibility does NOT break on walking.
    # Only Oculto (stealth/hide skill) breaks on walk for non-Thief/Bandit.
    # If the entity is oculto and their class/skill combo doesn't qualify
    # for stealth-while-moving, break their invisibility.
    entity =
      if entity.oculto and not can_move_while_hidden?(entity) do
        Helpers.break_invisibility(entity, state, char_id)
      else
        entity
      end

    moved_entity = %{
      entity
      | x: nx,
        y: ny,
        heading: direction,
        last_step_at: now,
        next_move_at: now + min_interval,
        resting: false,
        meditating: false
    }

    players = Map.put(state.players, char_id, moved_entity)

    occupancy =
      state.occupancy
      |> Helpers.clear_occupancy(entity.x, entity.y)
      |> Helpers.set_occupancy(nx, ny, {:player, char_id})

    grid = Visibility.maybe_grid_remove(state, entity.x, entity.y, char_id)
    grid = Visibility.maybe_grid_add(%{state | grid: grid}, nx, ny, char_id)

    state = %{state | players: players, occupancy: occupancy, grid: grid}

    state = Visibility.update_visible_set_on_move(state, char_id, moved_entity)
    {state, transferring?} = check_tile_exit(state, char_id, moved_entity, nx, ny)

    pos_raw = Encoder.encode({:pos_update, %{x: nx, y: ny}})
    move_raw = Encoder.encode({:character_move, %{char_index: moved_entity.char_index, x: nx, y: ny}})

    if not transferring? do
      Helpers.send_to_session(state.sessions, char_id, {:send_raw, pos_raw})
    end

    # Invisible players: only broadcast movement to GMs
    recipients =
      if moved_entity.invisible do
        result =
          Visibility.broadcast_visible_gm_only(state, nx, ny, char_id, fn pid ->
            send(pid, {:send_raw, move_raw})
          end)

        length(List.wrap(result))
      else
        Visibility.broadcast_visible(state, nx, ny, char_id, fn pid ->
          send(pid, {:send_raw, move_raw})
        end)
      end

    Arena.Metrics.inc_move(recipients)

    # NPC boundary updates: send nearby NPC creates to the mover's session.
    # The client handles duplicate creates as no-ops (same char_index overwrites).
    for raw <- Visibility.nearby_npc_packets(state, moved_entity) do
      Helpers.send_to_session(state.sessions, char_id, {:send_raw, raw})
    end

    # VB6: close commerce/bank if player walked away from the NPC
    check_npc_session_proximity(state, char_id)
  end

  @doc """
  Check if the player stepped on a tile exit.
  Uses `tile_exit_map` for O(1) lookup instead of scanning `tile_exits`.
  Returns `{state, transferring?}`.
  """
  def check_tile_exit(state, char_id, entity, x, y) do
    case Map.get(state.meta.tile_exit_map, {x, y}) do
      nil ->
        {state, false}

      %{dest_map: dest_map, dest_x: dest_x, dest_y: dest_y} ->
        Helpers.send_to_session(state.sessions, char_id, {:transfer, dest_map, dest_x, dest_y, entity})
        {state, true}
    end
  end

  # VB6: certain classes can remain oculto while moving, provided their
  # hiding skill meets the threshold.
  defp can_move_while_hidden?(entity) do
    hiding = Map.get(entity.skills, :hiding, 0)

    case entity.class do
      :asesino -> true
      :ladron -> hiding >= 50
      :bandido -> hiding >= 50
      :cazador -> hiding >= 75
      _ -> false
    end
  end

  @doc """
  Close commerce/bank sessions if the player has moved too far from the NPC.
  Called after every successful move.
  """
  def check_npc_session_proximity(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        state = maybe_close_commerce_session(state, char_id, entity)
        entity = state.players[char_id]
        maybe_close_bank_session(state, char_id, entity)

      :error ->
        state
    end
  end

  defp maybe_close_commerce_session(state, char_id, entity) do
    case entity.commerce_npc_instance_id do
      nil ->
        state

      inst_id ->
        npc = Map.get(state.npcs_live, inst_id)

        if npc == nil or abs(entity.x - npc.x) > 3 or abs(entity.y - npc.y) > 3 do
          entity = %{entity | commerce_npc_id: nil, commerce_npc_instance_id: nil}
          players = Map.put(state.players, char_id, entity)

          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:commerce_end, %{}})}
          )

          %{state | players: players}
        else
          state
        end
    end
  end

  defp maybe_close_bank_session(state, char_id, entity) do
    case entity.bank_npc_id do
      nil ->
        state

      inst_id ->
        npc = Map.get(state.npcs_live, inst_id)

        if npc == nil or abs(entity.x - npc.x) > 6 or abs(entity.y - npc.y) > 6 do
          entity = %{entity | bank_npc_id: nil}
          players = Map.put(state.players, char_id, entity)

          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:bank_end, %{}})}
          )

          %{state | players: players}
        else
          state
        end
    end
  end

  defp base_walk_interval_ms, do: Arena.Settings.get(:base_walk_interval_ms)
  defp speed_hack_threshold, do: Arena.Settings.get(:speed_hack_threshold)
end
