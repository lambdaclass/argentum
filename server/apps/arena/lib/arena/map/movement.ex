defmodule Arena.Map.Movement do
  @moduledoc """
  Movement-related handler logic extracted from `Arena.Map.MapServer`.

  Public handlers follow the effects contract:

    * `handle_move/3` returns `{:reply, term, state}` (so existing
      callers keep their reply-shape contract); the body runs on the
      effects contract via `Effects.run_handler_call_reply/2` and the
      internal `do_handle_move_effects/3` returns `{:ok, state, reply,
      effects}`.
    * `handle_change_heading/3` returns `{:noreply, state}` via
      `Effects.run_handler/2`; the body returns `{:ok, state, effects}`.

  AoI fanout for movement / heading packets is preserved exactly:

    * Position correction snap-back goes via `Effects.send/2` (unicast
      to the offender).
    * `character_move` / `character_change` AoI broadcasts use
      `Effects.broadcast_visible_except/4` so the originating client
      keeps rendering locally and never receives a duplicate.
    * Invisible movers fan their movement packets via
      `Effects.broadcast_visible_gm_only/4` so only GMs observe them.

  Movement is the most cross-cutting handler in the system: it closes
  commerce / bank sessions on walk-away, handles tile-exit transfers,
  and bridges `Helpers.break_invisibility/3` for the oculto-on-move
  break path. All of those side effects now traverse the effects
  contract — no bare `send/2` to session pids and no
  `Helpers.send_to_session/3` shim.
  """

  alias Arena.Clock
  alias Arena.Map.{Effects, Helpers, Visibility}
  alias AoProtocol.Server.Encoder

  require Logger

  # ---- Movement ----

  @doc """
  Handle a move request for char_id in the given direction.

  Returns `{:reply, term, state}` where the reply is `:ok | {:ok,
  {nx, ny}} | {:error, reason}`. The reply shape is preserved across
  the effects-contract migration so existing callers (MapServer
  `handle_call({:move, ...}, ...)` and direct test invocations) keep
  matching on `{:reply, _, _}`.
  """
  def handle_move(state, char_id, direction) do
    start = System.monotonic_time()

    result =
      Effects.run_handler_call_reply(state, fn s ->
        do_handle_move_effects(s, char_id, direction)
      end)

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

  # Effects-contract body. Returns `{:ok, state, reply, effects}`.
  defp do_handle_move_effects(state, char_id, direction) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = Clock.now_ms()
        min_interval = trunc(base_walk_interval_ms() / entity.speeding)

        cond do
          entity.paralyzed or entity.immobilized or entity.penalty > 0 ->
            {:ok, state, {:error, :paralyzed}, []}

          now < entity.next_move_at ->
            # Too early — silently ignore (VB6 behavior)
            {:ok, state, {:error, :too_early}, []}

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
              new_state = %{state | players: players}

              effects = [
                Effects.send(
                  char_id,
                  Encoder.encode({:pos_update, %{x: entity.x, y: entity.y}})
                )
              ]

              {:ok, new_state, {:error, :speed_hack}, effects}
            else
              entity = %{entity | speed_hack_counter: new_counter}

              case TileGrid.move_entity(state.map_id, entity.x, entity.y, direction) do
                {:ok, %TileGrid.Position{x: nx, y: ny}} ->
                  # VB6: water tiles (value 2) require boat. The rule itself lives in
                  # Arena.Map.TileSemantics, which is also what generates the cross-language
                  # fixture the Rust client is held to -- one rule, called from both places.
                  tile_val = TileGrid.get_tile(state.map_id, nx, ny)
                  water_blocked = Arena.Map.TileSemantics.requires_boat?(tile_val, entity.navigating)

                  # If this tile carries an exit, judge where it would put the character
                  # *before* they step onto it. Refusing the step is what keeps a rejection
                  # free: they never leave the source map, so their position and their owner
                  # are untouched and there is no half-finished handoff to unwind.
                  arrival = arrival_verdict(state, entity, nx, ny)

                  cond do
                    water_blocked ->
                      {:ok, state, {:error, :blocked}, []}

                    match?({:error, _}, arrival) ->
                      {:error, reason} = arrival

                      # Correct the client immediately. It predicts movement locally, so a
                      # refusal that says nothing leaves it drawing the character on the
                      # transition band while the server has them where they started -- a
                      # silent desync at the one tile where a player is most likely to keep
                      # walking. The typed `arrival_blocked` receipt is W-0096's; an
                      # authoritative position is owed now.
                      correction =
                        Effects.send(
                          char_id,
                          Encoder.encode({:pos_update, %{x: entity.x, y: entity.y}})
                        )

                      {:ok, state, {:error, {:arrival_blocked, reason}}, [correction]}

                    Helpers.get_occupancy(state.occupancy, nx, ny) == nil ->
                      # Normal move into empty tile
                      {state, move_effects} =
                        do_move(state, char_id, entity, nx, ny, direction, now, min_interval)

                      {:ok, state, {:ok, {nx, ny}}, move_effects}

                    match?({:player, _}, Helpers.get_occupancy(state.occupancy, nx, ny)) ->
                      # VB6: only dead or invisible players get pushed out of the way.
                      # Living visible players (including visible GMs) block the tile.
                      {:player, other_id} = Helpers.get_occupancy(state.occupancy, nx, ny)
                      other = Map.get(state.players, other_id)

                      if other != nil and (other.dead or other.invisible) do
                        old_x = entity.x
                        old_y = entity.y

                        {state, move_effects} =
                          do_move(state, char_id, entity, nx, ny, direction, now, min_interval)

                        # Push the dead/invisible player to our old position
                        other = Map.get(state.players, other_id) || other
                        opposite = Helpers.opposite_heading(direction)
                        swapped_other = %{other | x: old_x, y: old_y, heading: opposite}

                        players = Map.put(state.players, other_id, swapped_other)
                        occupancy = Helpers.set_occupancy(state.occupancy, old_x, old_y, {:player, other_id})
                        grid = Visibility.maybe_grid_remove(state, other.x, other.y, other_id)
                        grid = Visibility.maybe_grid_add(%{state | grid: grid}, old_x, old_y, other_id)

                        state = %{state | players: players, occupancy: occupancy, grid: grid}

                        swap_raw =
                          Encoder.encode(
                            {:character_move, %{char_index: swapped_other.char_index, x: old_x, y: old_y}}
                          )

                        swap_effects = [
                          Effects.send(
                            other_id,
                            Encoder.encode({:pos_update, %{x: old_x, y: old_y}})
                          ),
                          Effects.broadcast_visible_except(old_x, old_y, other_id, swap_raw)
                        ]

                        {:ok, state, {:ok, {nx, ny}}, move_effects ++ swap_effects}
                      else
                        {:ok, state, {:error, :blocked}, []}
                      end

                    true ->
                      # NPC or other non-swappable occupant
                      {:ok, state, {:error, :blocked}, []}
                  end

                {:error, :blocked} ->
                  {:ok, state, {:error, :blocked}, []}
              end
            end

            # speed hack else
        end

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  # ---- Heading ----

  @doc """
  Handle a heading change for char_id.

  Returns `{:noreply, state}` via `Effects.run_handler/2`; the body
  emits AoI broadcasts through the effects contract so non-GMs never
  see invisible movers' heading flips.
  """
  def handle_change_heading(state, char_id, heading) do
    Effects.run_handler(state, fn s ->
      do_change_heading_effects(s, char_id, heading)
    end)
  end

  defp do_change_heading_effects(state, char_id, heading) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | heading: heading}
        players = Map.put(state.players, char_id, entity)
        new_state = %{state | players: players}

        heading_raw = Encoder.encode(Helpers.character_change_packet(entity))

        # Invisible players: only broadcast heading to GMs.
        effect =
          if entity.invisible do
            Effects.broadcast_visible_gm_only(entity.x, entity.y, char_id, heading_raw)
          else
            Effects.broadcast_visible_except(entity.x, entity.y, char_id, heading_raw)
          end

        {:ok, new_state, [effect]}

      :error ->
        {:ok, state, []}
    end
  end

  # ---- Internal ----

  @doc """
  Move a player to (nx, ny), update occupancy/grid/visibility, and
  produce the effect list for the post-move broadcasts.

  Returns `{state, effects}`. The state mutation is applied
  synchronously (occupancy/grid/visibility-set diffs); only the
  outbound packet emissions are deferred to the runner.
  """
  def do_move(state, char_id, entity, nx, ny, direction, now, min_interval) do
    # VB6: spell invisibility does NOT break on walking.
    # Only Oculto (stealth/hide skill) breaks on walk for non-Thief/Bandit.
    # If the entity is oculto and their class/skill combo doesn't qualify
    # for stealth-while-moving, break their invisibility and append the
    # reveal effects to the move's effect list.
    {entity, invis_effects} =
      if entity.oculto and not can_move_while_hidden?(entity) do
        Helpers.break_invisibility(entity, state, char_id)
      else
        {entity, []}
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
    {state, transferring?, transfer_effects} =
      check_tile_exit(state, char_id, moved_entity, nx, ny)

    pos_raw = Encoder.encode({:pos_update, %{x: nx, y: ny}})
    move_raw = Encoder.encode({:character_move, %{char_index: moved_entity.char_index, x: nx, y: ny}})

    pos_effects =
      if transferring? do
        []
      else
        [Effects.send(char_id, pos_raw)]
      end

    # Invisible players: only broadcast movement to GMs.
    move_broadcast =
      if moved_entity.invisible do
        Effects.broadcast_visible_gm_only(nx, ny, char_id, move_raw)
      else
        Effects.broadcast_visible_except(nx, ny, char_id, move_raw)
      end

    # Telemetry: count broadcast recipients without duplicating the
    # eventual send. `compute_visible_ids/4` is the same set the runner
    # will fan to (minus the GM filter for invisibles), so the count is
    # an upper bound that matches the production tally.
    recipients = move_recipients(state, moved_entity, char_id)
    Arena.Metrics.inc_move(recipients)

    # NPC boundary updates: send nearby NPC creates to the mover's
    # session. The client handles duplicate creates as no-ops.
    npc_effects =
      for raw <- Visibility.nearby_npc_packets(state, moved_entity) do
        Effects.send(char_id, raw)
      end

    # VB6: close commerce/bank if player walked away from the NPC.
    {state, session_effects} = check_npc_session_proximity(state, char_id)

    effects =
      invis_effects ++
        pos_effects ++
        [move_broadcast] ++
        npc_effects ++
        transfer_effects ++
        session_effects

    {state, effects}
  end

  # Count of recipients for a movement broadcast (telemetry only).
  # Matches production AoI semantics: invisible movers reach only GMs;
  # visible movers reach everyone whose AoI covers (x, y), excluding
  # the mover. In :global mode `compute_visible_ids` ignores AoI.
  defp move_recipients(state, moved_entity, char_id) do
    visible = Visibility.compute_visible_ids(state, moved_entity.x, moved_entity.y, char_id)

    if moved_entity.invisible do
      Enum.count(visible, fn cid ->
        case Map.get(state.players, cid) do
          %{gm: true} -> true
          _ -> false
        end
      end)
    else
      MapSet.size(visible)
    end
  end

  @doc """
  Check if the player stepped on a tile exit.

  Uses `tile_exit_map` for O(1) lookup instead of scanning
  `tile_exits`. Returns `{state, transferring?, effects}` — the
  transfer (if any) is a `Effects.transfer/5` so it goes through the
  effects runner like the rest of the move.
  """
  def check_tile_exit(state, char_id, entity, x, y) do
    case Map.get(state.meta.tile_exit_map, {x, y}) do
      nil ->
        {state, false, []}

      %{dest_map: dest_map, dest_x: dest_x, dest_y: dest_y} = exit ->
        # Belt and braces. The movement path already refused the step onto this tile if the
        # arrival is invalid, so reaching here with a bad exit means the character arrived on
        # the band some other way. Standing on a transition band is wrong; being inside rock
        # is worse, so no transfer is emitted.
        case verdict_for(exit, entity) do
          :ok ->
            {state, true, [Effects.transfer(char_id, dest_map, dest_x, dest_y, entity)]}

          {:error, reason} ->
            Logger.warning(
              "Refusing exit #{state.map_id} (#{x},#{y}) -> #{dest_map} " <>
                "(#{dest_x},#{dest_y}): #{Arena.World.Arrival.reason_name(reason)}"
            )

            {state, false, []}
        end
    end
  end

  @doc """
  What `Arena.World.Arrival` says about the exit on this tile, if there is one.

  `:ok` when the tile carries no exit at all: this asks about arrivals, and a tile without an
  exit has none.

  A destination map that has never been recorded is reported as drawn rather than refused. A
  lazy boot would otherwise turn every exit into a wall, and refusing on absent information is
  a different failure from refusing on bad information.
  """
  @spec arrival_verdict(map(), map(), integer(), integer()) :: :ok | {:error, atom()}
  def arrival_verdict(state, entity, x, y) do
    case Map.get(state.meta.tile_exit_map, {x, y}) do
      nil -> :ok
      exit -> verdict_for(exit, entity)
    end
  end

  # The annotation the topology compiler resolved for this exit, merged into the map's own
  # exits at load. No lookup, no shared table, no call to the destination: the source has the
  # fact in hand before it releases anybody.
  #
  # An exit without an annotation is refused. Failing open here would make the promise --
  # the source validates the destination before releasing authority -- false in precisely the
  # case where it matters, and 1,196 exits in this corpus point at a map that does not exist.
  defp verdict_for(%{arrival: %{class: class, drawn?: drawn?}}, entity) do
    Arena.World.Arrival.validate(class, drawn?, entity.navigating)
  end

  defp verdict_for(_exit_without_annotation, _entity), do: {:error, :arrival_unknown}

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
  Close commerce/bank sessions if the player has moved too far from
  the NPC. Called after every successful move.

  Returns `{state, effects}`. The walk-away `commerce_end` /
  `bank_end` packets are emitted as `Effects.send/2` so they traverse
  the egress queue alongside the rest of the move's effects.
  """
  def check_npc_session_proximity(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        {state, commerce_effects} = maybe_close_commerce_session(state, char_id, entity)
        entity = state.players[char_id]
        {state, bank_effects} = maybe_close_bank_session(state, char_id, entity)
        {state, commerce_effects ++ bank_effects}

      :error ->
        {state, []}
    end
  end

  defp maybe_close_commerce_session(state, char_id, entity) do
    case entity.commerce_npc_instance_id do
      nil ->
        {state, []}

      inst_id ->
        npc = Map.get(state.npcs_live, inst_id)

        if npc == nil or abs(entity.x - npc.x) > 3 or abs(entity.y - npc.y) > 3 do
          entity = %{entity | commerce_npc_id: nil, commerce_npc_instance_id: nil}
          players = Map.put(state.players, char_id, entity)

          effects = [Effects.send(char_id, Encoder.encode({:commerce_end, %{}}))]
          {%{state | players: players}, effects}
        else
          {state, []}
        end
    end
  end

  defp maybe_close_bank_session(state, char_id, entity) do
    case entity.bank_npc_id do
      nil ->
        {state, []}

      inst_id ->
        npc = Map.get(state.npcs_live, inst_id)

        if npc == nil or abs(entity.x - npc.x) > 6 or abs(entity.y - npc.y) > 6 do
          entity = %{entity | bank_npc_id: nil}
          players = Map.put(state.players, char_id, entity)

          effects = [Effects.send(char_id, Encoder.encode({:bank_end, %{}}))]
          {%{state | players: players}, effects}
        else
          {state, []}
        end
    end
  end

  defp base_walk_interval_ms, do: Arena.Settings.get(:base_walk_interval_ms)
  defp speed_hack_threshold, do: Arena.Settings.get(:speed_hack_threshold)
end
