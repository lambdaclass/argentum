defmodule Arena.Map.Visibility do
  @moduledoc """
  Spatial-grid, AoI broadcast, and visible-set lifecycle helpers.

  Extracted from `Arena.Map.MapServer` so the GenServer module stays focused on
  state transitions while this module owns every question of the form
  "who can see whom?" and "how do we tell them?".
  """

  alias Arena.Map.Helpers
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  # cell_size is compile-time; runtime AoI checks use Helpers.aoi_range_x/y()
  @cell_size max(
               max(
                 Application.compile_env(:arena, :aoi_range_x, 11),
                 Application.compile_env(:arena, :aoi_range_y, 9)
               ),
               12
             )

  # --- Spatial grid helpers ---
  # Grid cells are @cell_size x @cell_size tiles. Each cell stores a MapSet of char_ids.
  # For AoI lookup we check only the 3x3 neighborhood of cells around the origin.

  def cell_key(x, y), do: {div(x, @cell_size), div(y, @cell_size)}

  def grid_add(grid, x, y, char_id) do
    key = cell_key(x, y)
    Map.update(grid, key, MapSet.new([char_id]), &MapSet.put(&1, char_id))
  end

  def grid_remove(grid, x, y, char_id) do
    key = cell_key(x, y)

    case Map.get(grid, key) do
      nil ->
        grid

      set ->
        new_set = MapSet.delete(set, char_id)
        if MapSet.size(new_set) == 0, do: Map.delete(grid, key), else: Map.put(grid, key, new_set)
    end
  end

  # Collect all char_ids in the 3x3 cell neighborhood around (x, y)
  def grid_nearby_ids(grid, x, y) do
    {cx, cy} = cell_key(x, y)

    for dx <- -1..1,
        dy <- -1..1,
        key = {cx + dx, cy + dy},
        set = Map.get(grid, key, nil),
        set != nil,
        cid <- set,
        do: cid
  end

  # AoI broadcast using spatial grid: O(k) where k = nearby players
  def broadcast_aoi_grid(grid, players, sessions, origin_x, origin_y, exclude_id, fun) do
    for cid <- grid_nearby_ids(grid, origin_x, origin_y),
        cid != exclude_id do
      case Map.get(players, cid) do
        nil ->
          :ok

        entity ->
          if abs(entity.x - origin_x) <= Helpers.aoi_range_x() and abs(entity.y - origin_y) <= Helpers.aoi_range_y() do
            case Map.get(sessions, cid) do
              nil -> :ok
              pid -> fun.(pid)
            end
          end
      end
    end
  end

  def broadcast_aoi_grid_all(grid, players, sessions, origin_x, origin_y, fun) do
    for cid <- grid_nearby_ids(grid, origin_x, origin_y) do
      case Map.get(players, cid) do
        nil ->
          :ok

        entity ->
          if abs(entity.x - origin_x) <= Helpers.aoi_range_x() and abs(entity.y - origin_y) <= Helpers.aoi_range_y() do
            case Map.get(sessions, cid) do
              nil -> :ok
              pid -> fun.(pid)
            end
          end
      end
    end
  end

  # --- Invisibility helpers ---

  @doc "Send character_remove to nearby non-GM players (entity going invisible)."
  def hide_from_non_gm(state, entity) do
    remove_raw = Encoder.encode({:character_remove, %{char_index: entity.char_index}})

    broadcast_visible_non_gm(state, entity.x, entity.y, entity.char_id, fn pid ->
      send(pid, {:send_raw, remove_raw})
    end)
  end

  @doc "Send character_create to nearby non-GM players (entity becoming visible)."
  def reveal_to_non_gm(state, entity) do
    create_raw = Encoder.encode(Helpers.character_create_packet(entity))

    broadcast_visible_non_gm(state, entity.x, entity.y, entity.char_id, fn pid ->
      send(pid, {:send_raw, create_raw})
    end)
  end

  # Broadcast to nearby non-GM players, excluding exclude_id.
  defp broadcast_visible_non_gm(state, origin_x, origin_y, exclude_id, fun) do
    case state.visibility_mode do
      :global ->
        for {cid, pid} <- state.sessions, cid != exclude_id do
          case Map.get(state.players, cid) do
            nil -> fun.(pid)
            %{gm: true} -> :skip
            _ -> fun.(pid)
          end
        end

      :aoi_scan ->
        for {cid, entity} <- state.players,
            cid != exclude_id,
            not entity.gm,
            abs(entity.x - origin_x) <= Helpers.aoi_range_x(),
            abs(entity.y - origin_y) <= Helpers.aoi_range_y() do
          case Map.get(state.sessions, cid) do
            nil -> :skip
            pid -> fun.(pid)
          end
        end

      :aoi_grid ->
        for cid <- grid_nearby_ids(state.grid, origin_x, origin_y),
            cid != exclude_id do
          case Map.get(state.players, cid) do
            nil ->
              :ok

            entity ->
              if not entity.gm and
                   abs(entity.x - origin_x) <= Helpers.aoi_range_x() and
                   abs(entity.y - origin_y) <= Helpers.aoi_range_y() do
                case Map.get(state.sessions, cid) do
                  nil -> :ok
                  pid -> fun.(pid)
                end
              end
          end
        end
    end
  end

  @doc "Broadcast to nearby GM players only (used for invisible entity position updates)."
  def broadcast_visible_gm_only(state, origin_x, origin_y, exclude_id, fun) do
    case state.visibility_mode do
      :global ->
        for {cid, pid} <- state.sessions, cid != exclude_id do
          case Map.get(state.players, cid) do
            %{gm: true} -> fun.(pid)
            _ -> :skip
          end
        end

      :aoi_scan ->
        for {cid, entity} <- state.players,
            cid != exclude_id,
            entity.gm,
            abs(entity.x - origin_x) <= Helpers.aoi_range_x(),
            abs(entity.y - origin_y) <= Helpers.aoi_range_y() do
          case Map.get(state.sessions, cid) do
            nil -> :skip
            pid -> fun.(pid)
          end
        end

      :aoi_grid ->
        for cid <- grid_nearby_ids(state.grid, origin_x, origin_y),
            cid != exclude_id do
          case Map.get(state.players, cid) do
            %{gm: true} = entity ->
              if abs(entity.x - origin_x) <= Helpers.aoi_range_x() and
                   abs(entity.y - origin_y) <= Helpers.aoi_range_y() do
                case Map.get(state.sessions, cid) do
                  nil -> :ok
                  pid -> fun.(pid)
                end
              end

            _ ->
              :ok
          end
        end
    end
  end

  # --- Broadcast helpers ---

  # Broadcast to all visible players excluding one (using current mode).
  # Pass exclude_id = nil to include everyone (broadcast_visible_all behaviour).
  def broadcast_visible(state, origin_x, origin_y, exclude_id \\ nil, fun) do
    results =
      case state.visibility_mode do
        :global ->
          if exclude_id do
            for {cid, pid} <- state.sessions, cid != exclude_id, do: fun.(pid)
          else
            for {_cid, pid} <- state.sessions, do: fun.(pid)
          end

        :aoi_scan ->
          if exclude_id do
            for {cid, entity} <- state.players,
                cid != exclude_id,
                abs(entity.x - origin_x) <= Helpers.aoi_range_x(),
                abs(entity.y - origin_y) <= Helpers.aoi_range_y() do
              case Map.get(state.sessions, cid) do
                nil -> :skip
                pid -> fun.(pid)
              end
            end
          else
            for {cid, entity} <- state.players,
                abs(entity.x - origin_x) <= Helpers.aoi_range_x(),
                abs(entity.y - origin_y) <= Helpers.aoi_range_y() do
              case Map.get(state.sessions, cid) do
                nil -> :skip
                pid -> fun.(pid)
              end
            end
          end

        :aoi_grid ->
          if exclude_id do
            broadcast_aoi_grid(state.grid, state.players, state.sessions, origin_x, origin_y, exclude_id, fun)
          else
            broadcast_aoi_grid_all(state.grid, state.players, state.sessions, origin_x, origin_y, fun)
          end
      end

    recipients = length(List.wrap(results))

    :telemetry.execute([:arena, :map, :broadcast], %{recipients: recipients},
      %{map_id: state.map_id})

    recipients
  end

  # Broadcast to all visible players including origin (for chat).
  # Delegates to broadcast_visible with nil exclude.
  def broadcast_visible_all(state, origin_x, origin_y, fun) do
    broadcast_visible(state, origin_x, origin_y, nil, fun)
  end

  # Broadcast to ALL sessions on the map (weather, audio, announcements).
  # Unlike broadcast_visible_all, this ignores AoI and always reaches everyone.
  def broadcast_to_map(state, fun) do
    for {_cid, pid} <- state.sessions, do: fun.(pid)
  end

  # Broadcast to a custom range (used for yell)
  def broadcast_range(state, origin_x, origin_y, range_x, range_y, fun) do
    case state.visibility_mode do
      :global ->
        for {_cid, pid} <- state.sessions, do: fun.(pid)

      _ ->
        for {cid, entity} <- state.players,
            abs(entity.x - origin_x) <= range_x,
            abs(entity.y - origin_y) <= range_y do
          case Map.get(state.sessions, cid) do
            nil -> :skip
            pid -> fun.(pid)
          end
        end
    end
  end

  # --- Visible set lifecycle ---
  # Each player has a MapSet of char_ids they can currently see.
  # In :global mode, visible_sets is nil -- create/remove go to everyone.

  # Compute which other players are visible from (x, y), excluding self
  def compute_visible_ids(state, x, y, exclude_id) do
    case state.visibility_mode do
      :global ->
        state.players
        |> Map.keys()
        |> Enum.reject(&(&1 == exclude_id))
        |> MapSet.new()

      :aoi_scan ->
        state.players
        |> Enum.filter(fn {cid, entity} ->
          cid != exclude_id and
            abs(entity.x - x) <= Helpers.aoi_range_x() and abs(entity.y - y) <= Helpers.aoi_range_y()
        end)
        |> Enum.map(fn {cid, _} -> cid end)
        |> MapSet.new()

      :aoi_grid ->
        grid_nearby_ids(state.grid, x, y)
        |> Enum.filter(fn cid ->
          cid != exclude_id and
            case Map.get(state.players, cid) do
              nil -> false
              entity -> abs(entity.x - x) <= Helpers.aoi_range_x() and abs(entity.y - y) <= Helpers.aoi_range_y()
            end
        end)
        |> MapSet.new()
    end
  end

  # Handle enter: compute visible set, send creates both ways.
  # Invisible players are not broadcast to non-GM clients; GMs see everyone.
  def enter_visibility(state, entity, sessions) do
    if state.visible_sets == nil do
      # :global mode -- broadcast to everyone, no visible set tracking
      create_raw = Encoder.encode(Helpers.character_create_packet(entity))

      for {cid, pid} <- sessions, cid != entity.char_id do
        if entity.invisible do
          # Only send to GMs
          viewer = Map.get(state.players, cid)
          if viewer != nil and viewer.gm, do: send(pid, {:send_raw, create_raw})
        else
          send(pid, {:send_raw, create_raw})
        end
      end

      # Filter invisible players out of the reply (unless entering player is GM)
      reply_players =
        if entity.gm do
          state.players
        else
          Map.reject(state.players, fn {cid, p} -> cid != entity.char_id and p.invisible end)
        end

      {nil, reply_players}
    else
      visible_ids = compute_visible_ids(state, entity.x, entity.y, entity.char_id)
      visible_sets = Map.put(state.visible_sets, entity.char_id, visible_ids)

      create_raw = Encoder.encode(Helpers.character_create_packet(entity))

      visible_sets =
        Enum.reduce(visible_ids, visible_sets, fn other_id, vs ->
          if entity.invisible do
            # Only send our create to GMs
            other = Map.get(state.players, other_id)
            if other != nil and other.gm do
              Helpers.send_to_session(sessions, other_id, {:send_raw, create_raw})
            end
          else
            Helpers.send_to_session(sessions, other_id, {:send_raw, create_raw})
          end

          Map.update(vs, other_id, MapSet.new([entity.char_id]), &MapSet.put(&1, entity.char_id))
        end)

      # Filter invisible players from nearby list (unless entering player is GM)
      all_nearby = Map.take(state.players, MapSet.to_list(visible_ids) ++ [entity.char_id])

      nearby =
        if entity.gm do
          all_nearby
        else
          Map.reject(all_nearby, fn {cid, p} -> cid != entity.char_id and p.invisible end)
        end

      {visible_sets, nearby}
    end
  end

  @doc """
  Return pre-encoded NPC create packets for NPCs within AoI range of entity.
  The caller is responsible for delivering these to the entering player's session.
  """
  def nearby_npc_packets(state, entity) do
    for {_iid, npc} <- state.npcs_live,
        npc.alive,
        abs(npc.x - entity.x) <= Helpers.aoi_range_x(),
        abs(npc.y - entity.y) <= Helpers.aoi_range_y(),
        npc_def = GameData.get_npc(npc.npc_id),
        npc_def != nil do
      Encoder.encode(Helpers.npc_create_packet(npc, npc_def))
    end
  end

  # Handle leave/transfer: send removal to observers, clean up visible sets
  def remove_from_visibility(state, char_id, entity) do
    if state.visible_sets == nil do
      # :global mode
      remove_raw = Encoder.encode({:character_remove, %{char_index: entity.char_index}})
      for {cid, pid} <- state.sessions, cid != char_id, do: send(pid, {:send_raw, remove_raw})
      nil
    else
      remove_raw = Encoder.encode({:character_remove, %{char_index: entity.char_index}})
      old_visible = Map.get(state.visible_sets, char_id, MapSet.new())

      visible_sets =
        Enum.reduce(old_visible, state.visible_sets, fn other_id, vs ->
          Helpers.send_to_session(state.sessions, other_id, {:send_raw, remove_raw})
          Map.update(vs, other_id, MapSet.new(), &MapSet.delete(&1, char_id))
        end)

      Map.delete(visible_sets, char_id)
    end
  end

  # After a move, diff old visible set vs new, send create/remove both ways
  def update_visible_set_on_move(state, char_id, entity) do
    if state.visible_sets == nil do
      # :global mode -- no boundary crossings needed
      state
    else
      old_visible = Map.get(state.visible_sets, char_id, MapSet.new())
      new_visible = compute_visible_ids(state, entity.x, entity.y, char_id)

      entered = MapSet.difference(new_visible, old_visible)
      left = MapSet.difference(old_visible, new_visible)

      # Players that just entered mover's AoI: send create both ways
      # Invisible filtering: don't reveal invisible entities to non-GMs
      create_mover_raw = Encoder.encode(Helpers.character_create_packet(entity))
      mover_is_gm = entity.gm

      visible_sets =
        Enum.reduce(entered, state.visible_sets, fn other_id, vs ->
          other = Map.get(state.players, other_id)

          # Send other's create to mover (unless other is invisible and mover is not GM)
          if other do
            unless other.invisible and not mover_is_gm do
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode(Helpers.character_create_packet(other))}
              )
            end
          end

          # Send mover's create to other (unless mover is invisible and other is not GM)
          unless entity.invisible and (other == nil or not other.gm) do
            Helpers.send_to_session(state.sessions, other_id, {:send_raw, create_mover_raw})
          end

          Map.update(vs, other_id, MapSet.new([char_id]), &MapSet.put(&1, char_id))
        end)

      # Players that just left mover's AoI: send remove both ways
      # Only send remove if the entity was actually visible to the recipient
      remove_mover_raw = Encoder.encode({:character_remove, %{char_index: entity.char_index}})

      visible_sets =
        Enum.reduce(left, visible_sets, fn other_id, vs ->
          other = Map.get(state.players, other_id)

          # Send other's remove to mover (unless other was invisible to mover)
          if other do
            unless other.invisible and not mover_is_gm do
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:character_remove, %{char_index: other.char_index}})}
              )
            end
          end

          # Send mover's remove to other (unless mover was invisible to other)
          unless entity.invisible and (other == nil or not other.gm) do
            Helpers.send_to_session(state.sessions, other_id, {:send_raw, remove_mover_raw})
          end

          Map.update(vs, other_id, MapSet.new(), &MapSet.delete(&1, char_id))
        end)

      visible_sets = Map.put(visible_sets, char_id, new_visible)
      state = %{state | visible_sets: visible_sets}

      # NPC boundary updates are sent by the caller (do_move) via
      # nearby_npc_packets/2 to keep side-effect sends out of visibility logic.
      state
    end
  end

  # Grid maintenance: add/remove only in :aoi_grid mode
  def maybe_grid_add(state, x, y, char_id) do
    if state.visibility_mode == :aoi_grid do
      grid_add(state.grid, x, y, char_id)
    else
      state.grid
    end
  end

  def maybe_grid_remove(state, x, y, char_id) do
    if state.visibility_mode == :aoi_grid do
      grid_remove(state.grid, x, y, char_id)
    else
      state.grid
    end
  end
end
