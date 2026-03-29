defmodule Arena.Map.MapServer do
  @moduledoc """
  GenServer that owns a single map instance.

  Sole authority for all online gameplay state on this map.
  Player actions are processed immediately in mailbox order.
  Periodic timers handle background work only (NPC AI, regen, autosave).
  """

  use GenServer

  require Logger

  alias Arena.Map.CsmParser
  alias Arena.Entity.PlayerEntity
  alias Arena.Inventory
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @map_width 100
  @map_height 100
  @autosave_interval_ms 60_000
  # VB6: IntervaloCaminar=210, MargenDeIntervaloPorPing=30
  # Server allows a move if elapsed >= interval (simple timer reset, like VB6).
  # Movement is synchronous (call) — processed inline before next packet.
  @base_walk_interval_ms 210
  # Traditional AO viewport is 23×19 tiles at 32×32, centered on the player.
  # That gives a half-viewport of 11 tiles horizontally and 9 vertically.
  @aoi_range_x Application.compile_env(:arena, :aoi_range_x, 11)
  @aoi_range_y Application.compile_env(:arena, :aoi_range_y, 9)
  # Spatial grid cell size for O(1) AoI lookups.
  # Cell size should be >= the larger AoI axis so we only need to check 9 cells (3×3).
  @cell_size max(max(@aoi_range_x, @aoi_range_y), 12)

  # ---- Public API ----

  def child_spec(map_id) do
    %{
      id: {__MODULE__, map_id},
      start: {__MODULE__, :start_link, [map_id]},
      restart: :transient
    }
  end

  def start_link(map_id) when is_integer(map_id) do
    GenServer.start_link(__MODULE__, map_id, name: via(map_id))
  end

  def via(map_id), do: {:via, Registry, {Arena.MapRegistry, map_id}}

  @doc "Get map metadata."
  def get_info(map_id), do: GenServer.call(via(map_id), :get_info)

  @doc "Get full map data for rendering: tiles, NPCs, objects, exits."
  def get_map_data(map_id), do: GenServer.call(via(map_id), :get_map_data)

  @doc "Check if a tile is walkable (delegates to NIF)."
  def walkable?(map_id, x, y), do: TileGrid.is_walkable(map_id, x, y)

  @doc "Find a random walkable tile on the map."
  def random_spawn(map_id) do
    Enum.find_value(1..200, {50, 50}, fn _ ->
      x = :rand.uniform(@map_width)
      y = :rand.uniform(@map_height)
      if TileGrid.is_walkable(map_id, x, y), do: {x, y}
    end)
  end

  @doc """
  Enter a player onto this map.
  Returns {:ok, char_index, all_entities} or {:error, reason}.
  The entity is placed at the given position or a spawn point.
  """
  def enter(map_id, %PlayerEntity{} = entity, opts \\ []) do
    GenServer.call(via(map_id), {:enter, entity, opts})
  end

  @doc "Remove a player from this map. Returns the exported entity or :not_found."
  def leave(map_id, char_id) do
    GenServer.call(via(map_id), {:leave, char_id})
  end

  @doc "Move a player. Synchronous like VB6 — processed inline before next packet."
  def move_character(map_id, char_id, direction) do
    GenServer.call(via(map_id), {:move, char_id, direction})
  end

  @doc "Change a player's heading without moving."
  def change_heading(map_id, char_id, heading) do
    GenServer.cast(via(map_id), {:change_heading, char_id, heading})
  end

  @doc "Player chat message."
  def chat(map_id, char_id, message) do
    GenServer.cast(via(map_id), {:chat, char_id, message})
  end

  @doc "Pick up item at player's feet."
  def pick_up(map_id, char_id) do
    GenServer.call(via(map_id), {:pick_up, char_id})
  end

  @doc "Drop item from inventory slot onto the ground."
  def drop_item(map_id, char_id, slot, amount) do
    GenServer.call(via(map_id), {:drop_item, char_id, slot, amount})
  end

  @doc "Toggle equip on an inventory slot."
  def equip_item(map_id, char_id, slot) do
    GenServer.call(via(map_id), {:equip_item, char_id, slot})
  end

  @doc "Use an item from inventory slot (food, drink, potion)."
  def use_item(map_id, char_id, slot) do
    GenServer.call(via(map_id), {:use_item, char_id, slot})
  end

  @doc "Get a snapshot of a player entity (for autosave)."
  def snapshot_entity(map_id, char_id) do
    GenServer.call(via(map_id), {:snapshot, char_id})
  end

  # ---- GenServer callbacks ----

  @benchmark_map_id 999
  @crowd_arena_map_id 998

  @impl true
  def init(map_id) do
    {:ok, %{map_id: map_id, loading: true}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %{map_id: map_id}) do
    Logger.info("Loading map #{map_id}...")

    map_data_result =
      case map_id do
        @benchmark_map_id -> {:ok, benchmark_map_data()}
        @crowd_arena_map_id -> {:ok, crowd_arena_map_data()}
        _ ->
          csm_path = Path.join(maps_dir(), "mapa#{map_id}.csm")
          CsmParser.parse_file(csm_path)
      end

    case map_data_result do
      {:ok, map_data} ->
        result = TileGrid.load_map(map_id, map_data.tiles)

        if result != :ok do
          Logger.error("Failed to load map #{map_id} into NIF: #{inspect(result)}")
          {:stop, :normal, %{map_id: map_id, loading: true}}
        else
          blocked_count = Enum.count(map_data.tiles, &(&1 != 0))

          Logger.info(
            "Map #{map_id} loaded: #{map_data.map_name} " <>
              "(#{blocked_count} blocked tiles, #{length(map_data.npcs)} NPCs, " <>
              "#{length(map_data.objects)} objects, #{length(map_data.tile_exits)} exits)"
          )

          # Schedule autosave timer
          Process.send_after(self(), :autosave, @autosave_interval_ms)

          visibility_mode = Application.get_env(:arena, :visibility_mode, :aoi_grid)

          state = %{
            map_id: map_id,
            loading: false,
            name: map_data.map_name,
            zone: map_data.zone,
            terrain: map_data.terrain,
            safe_zone: map_data.safe_zone,
            music_hi: map_data.music_hi,
            music_low: map_data.music_low,
            layers: map_data.layers,
            npcs: map_data.npcs,
            objects: map_data.objects,
            tile_exits: map_data.tile_exits,
            triggers: map_data.triggers,
            # Player entities: %{char_id => %PlayerEntity{}}
            players: %{},
            # Session pids for direct sends: %{char_id => pid()}
            sessions: %{},
            # Dynamic occupancy: :array of 10000 slots, nil or {:player, char_id}
            occupancy: :array.new(@map_width * @map_height, default: nil),
            # Visibility mode: :global | :aoi_scan | :aoi_grid
            visibility_mode: visibility_mode,
            # Spatial grid: %{cell_key => MapSet.t(char_id)} (only used in :aoi_grid mode)
            grid: if(visibility_mode == :aoi_grid, do: %{}, else: nil),
            # Per-player visible sets: %{char_id => MapSet.t(char_id)}
            # Only used in :aoi_scan and :aoi_grid modes.
            visible_sets: if(visibility_mode == :global, do: nil, else: %{}),
            # Ground items: %{{x, y} => %{item_id: int, amount: int}}
            ground_items: build_ground_items(map_data.objects),
            # Counter for per-map char_index assignment
            next_char_index: 1
          }

          {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("Failed to parse map #{map_id}: #{inspect(reason)}")
        {:stop, :normal, %{map_id: map_id, loading: true}}
    end
  end

  defp benchmark_map_data do
    alias Arena.Map.CsmParser.MapData

    %MapData{
      map_name: "Benchmark Arena",
      zone: "CAMPO",
      terrain: "BOSQUE",
      safe_zone: false,
      music_hi: 0,
      music_low: 0,
      rain: false,
      snow: false,
      fog: false,
      blocked: [],
      layers: [[], [], [], []],
      triggers: [],
      npcs: [],
      objects: [],
      tile_exits: [],
      tiles: List.duplicate(0, 10_000)
    }
  end

  # 25x25 walkable arena centered in the map, rest blocked.
  # Forces high player density within a constrained area.
  # Walkable: x 38..62, y 38..62 (625 tiles). Blocked: 9375 tiles.
  defp crowd_arena_map_data do
    alias Arena.Map.CsmParser.MapData

    # Build 100x100 tile grid: 0 = walkable, 0x0F = blocked all sides
    tiles =
      for y <- 1..@map_height, x <- 1..@map_width do
        if x >= 38 and x <= 62 and y >= 38 and y <= 62, do: 0, else: 0x0F
      end

    %MapData{
      map_name: "Crowd Arena (25x25)",
      zone: "CAMPO",
      terrain: "BOSQUE",
      safe_zone: false,
      music_hi: 0,
      music_low: 0,
      rain: false,
      snow: false,
      fog: false,
      blocked: [],
      layers: [[], [], [], []],
      triggers: [],
      npcs: [],
      objects: [],
      tile_exits: [],
      tiles: tiles
    }
  end

  @doc "Check if a map process is loaded and ready to accept commands."
  def ready?(map_id) do
    GenServer.call(via(map_id), :ready?)
  catch
    :exit, _ -> false
  end

  # ---- Loading guard: reject calls while map is still parsing ----

  @impl true
  def handle_call(:ready?, _from, %{loading: true} = state) do
    {:reply, false, state}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, true, state}
  end

  def handle_call(_msg, _from, %{loading: true} = state) do
    {:reply, {:error, :map_loading}, state}
  end

  # ---- Enter / Leave ----

  @impl true
  def handle_call({:enter, %PlayerEntity{} = entity, opts}, {caller_pid, _}, state) do
    # Determine spawn position
    {x, y} =
      case Keyword.get(opts, :position) do
        {px, py} when is_integer(px) and is_integer(py) -> {px, py}
        _ -> find_spawn_point(state.map_id)
      end

    # Ensure the chosen tile is not already occupied
    {x, y} = find_unoccupied_spawn(state, x, y)

    char_index = state.next_char_index

    entity = %{entity |
      x: x,
      y: y,
      char_index: char_index,
      map_id: state.map_id
    }

    # Update state
    players = Map.put(state.players, entity.char_id, entity)
    sessions = Map.put(state.sessions, entity.char_id, caller_pid)
    occupancy = set_occupancy(state.occupancy, x, y, {:player, entity.char_id})
    grid = maybe_grid_add(state, x, y, entity.char_id)

    state = %{state | players: players, sessions: sessions, occupancy: occupancy, grid: grid}

    # Compute visible set, send creates both ways, get reply players
    {visible_sets, reply_players} = enter_visibility(state, entity, sessions)

    Logger.info("#{entity.name} (#{entity.char_id}) entered map #{state.map_id} at (#{x}, #{y}) index=#{char_index}")

    state = %{state |
      visible_sets: visible_sets,
      next_char_index: char_index + 1
    }

    {:reply, {:ok, char_index, reply_players}, state}
  end

  @impl true
  def handle_call({:leave, char_id}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        # Send removal to visible observers
        visible_sets = remove_from_visibility(state, char_id, entity)

        # Remove from state
        players = Map.delete(state.players, char_id)
        sessions = Map.delete(state.sessions, char_id)
        occupancy = clear_occupancy(state.occupancy, entity.x, entity.y)
        grid = maybe_grid_remove(state, entity.x, entity.y, char_id)

        state = %{state | players: players, sessions: sessions, occupancy: occupancy, grid: grid, visible_sets: visible_sets}
        {:reply, {:ok, entity}, state}

      :error ->
        {:reply, :not_found, state}
    end
  end

  # ---- Snapshot ----

  @impl true
  def handle_call({:snapshot, char_id}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} -> {:reply, {:ok, entity}, state}
      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  # ---- Inventory operations ----

  @item_use_cooldown_ms 500

  @impl true
  def handle_call({:pick_up, char_id}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        pos = {entity.x, entity.y}

        case Map.get(state.ground_items, pos) do
          nil ->
            {:reply, {:error, :no_item}, state}

          ground_item ->
            case Inventory.add_item(entity.inventory, ground_item.item_id, ground_item.amount) do
              {:gold, amount} ->
                entity = %{entity | gold: entity.gold + amount}
                players = Map.put(state.players, char_id, entity)
                ground_items = Map.delete(state.ground_items, pos)
                state = %{state | players: players, ground_items: ground_items}

                send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:update_gold, %{gold: entity.gold}})})
                broadcast_object_delete(state, entity.x, entity.y)

                {:reply, :ok, state}

              {:ok, new_inventory, slot} ->
                entity = %{entity | inventory: new_inventory}
                players = Map.put(state.players, char_id, entity)
                ground_items = Map.delete(state.ground_items, pos)
                state = %{state | players: players, ground_items: ground_items}

                send_inventory_slot(state.sessions, char_id, new_inventory, slot)
                broadcast_object_delete(state, entity.x, entity.y)

                {:reply, :ok, state}

              {:error, :inventory_full} ->
                {:reply, {:error, :inventory_full}, state}
            end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  @impl true
  def handle_call({:drop_item, char_id, slot, amount}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        pos = {entity.x, entity.y}

        cond do
          Map.has_key?(state.ground_items, pos) ->
            {:reply, {:error, :tile_occupied}, state}

          true ->
            case Inventory.get_slot(entity.inventory, slot) do
              nil ->
                {:reply, {:error, :empty_slot}, state}

              item ->
                drop_amount = min(amount, item.amount)

                case Inventory.remove_from_slot(entity.inventory, slot, drop_amount) do
                  {:ok, new_inventory, _slot} ->
                    # If the dropped item was equipped, clear the equipment slot
                    new_equipment =
                      if item.equipped do
                        item_def = Arena.Data.GameData.get_item(item.item_id)
                        if item_def && item_def.equip_slot do
                          Map.put(entity.equipment, item_def.equip_slot, nil)
                        else
                          entity.equipment
                        end
                      else
                        entity.equipment
                      end

                    entity = %{entity | inventory: new_inventory, equipment: new_equipment}
                    players = Map.put(state.players, char_id, entity)
                    ground_items = Map.put(state.ground_items, pos, %{item_id: item.item_id, amount: drop_amount})
                    state = %{state | players: players, ground_items: ground_items}

                    send_inventory_slot(state.sessions, char_id, new_inventory, slot)
                    broadcast_object_create(state, entity.x, entity.y, item.item_id, drop_amount)

                    {:reply, :ok, state}

                  {:error, reason} ->
                    {:reply, {:error, reason}, state}
                end
            end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  @impl true
  def handle_call({:equip_item, char_id, slot}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case Inventory.equip_toggle(entity.inventory, entity.equipment, slot) do
          {:ok, new_inventory, new_equipment, changed_slots} ->
            entity = %{entity | inventory: new_inventory, equipment: new_equipment}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            for s <- changed_slots do
              send_inventory_slot(state.sessions, char_id, new_inventory, s)
            end

            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  @impl true
  def handle_call({:use_item, char_id, slot}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)

        if now < entity.next_item_use_at do
          {:reply, {:error, :cooldown}, state}
        else
          case Inventory.get_slot(entity.inventory, slot) do
            nil ->
              {:reply, {:error, :empty_slot}, state}

            item ->
              item_def = GameData.get_item(item.item_id)

              if item_def == nil do
                {:reply, {:error, :unknown_item}, state}
              else
                case apply_item_use(entity, item_def, slot, state) do
                  {:ok, entity, state} ->
                    entity = %{entity | next_item_use_at: now + @item_use_cooldown_ms}
                    players = Map.put(state.players, char_id, entity)
                    state = %{state | players: players}
                    {:reply, :ok, state}

                  {:error, reason} ->
                    {:reply, {:error, reason}, state}
                end
              end
          end
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  # ---- Info / Map Data ----

  @impl true
  def handle_call(:player_count, _from, state) do
    {:reply, map_size(state.players), state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      map_id: state.map_id,
      name: state.name,
      zone: state.zone,
      terrain: state.terrain,
      safe_zone: state.safe_zone,
      npc_count: length(state.npcs),
      object_count: length(state.objects),
      exit_count: length(state.tile_exits)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:get_map_data, _from, state) do
    tiles =
      for y <- 1..100, x <- 1..100 do
        TileGrid.get_tile(state.map_id, x, y)
      end

    encode_layer = fn layer ->
      Enum.map(layer, fn %{x: x, y: y, grh_index: grh} -> [x, y, grh] end)
    end

    [l1, l2, l3, l4] = state.layers

    data = %{
      map_id: state.map_id,
      name: state.name,
      width: 100,
      height: 100,
      tiles: tiles,
      music_hi: state.music_hi,
      music_low: state.music_low,
      layers: [encode_layer.(l1), encode_layer.(l2), encode_layer.(l3), encode_layer.(l4)],
      npcs: Enum.map(state.npcs, fn npc -> %{x: npc.x, y: npc.y, id: npc.npc_index} end),
      objects: Enum.map(state.objects, fn obj -> %{x: obj.x, y: obj.y, id: obj.obj_index, amount: obj.amount} end),
      exits: Enum.map(state.tile_exits, fn ex -> %{x: ex.x, y: ex.y, dest_map: ex.dest_map, dest_x: ex.dest_x, dest_y: ex.dest_y} end)
    }

    {:reply, data, state}
  end

  # ---- Movement ----

  @impl true
  def handle_call({:move, char_id, direction}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)
        min_interval = trunc(@base_walk_interval_ms / entity.speeding)

        # VB6-style simple check: if enough time elapsed, allow; else silently ignore.
        if now >= entity.next_move_at do
          case TileGrid.move_entity(state.map_id, entity.x, entity.y, direction) do
            {:ok, %TileGrid.Position{x: nx, y: ny}} ->
              if get_occupancy(state.occupancy, nx, ny) == nil do
                moved_entity = %{entity |
                  x: nx,
                  y: ny,
                  heading: direction,
                  last_step_at: now,
                  next_move_at: now + min_interval
                }

                players = Map.put(state.players, char_id, moved_entity)
                occupancy =
                  state.occupancy
                  |> clear_occupancy(entity.x, entity.y)
                  |> set_occupancy(nx, ny, {:player, char_id})
                grid = maybe_grid_remove(state, entity.x, entity.y, char_id)
                grid = if state.visibility_mode == :aoi_grid, do: grid_add(grid, nx, ny, char_id), else: grid

                state = %{state | players: players, occupancy: occupancy, grid: grid}

                # AoI boundary crossings first: send character_create to newly visible
                # players BEFORE the move broadcast, so they know who's moving
                state = update_visible_set_on_move(state, char_id, moved_entity)

                {state, transferring?} = check_tile_exit(state, char_id, moved_entity, nx, ny)

                pos_raw = Encoder.encode({:pos_update, %{x: nx, y: ny}})
                move_raw = Encoder.encode({:character_move, %{char_index: moved_entity.char_index, x: nx, y: ny}})

                if not transferring? do
                  send_to_session(state.sessions, char_id, {:send_raw, pos_raw})
                end

                move_recipients =
                  broadcast_visible(state, nx, ny, char_id, fn pid ->
                    send(pid, {:send_raw, move_raw})
                  end)

                Arena.Metrics.inc_move(move_recipients)
                {:reply, {:ok, {nx, ny}}, state}
              else
                {:reply, {:error, :blocked}, state}
              end

            {:error, :blocked} ->
              {:reply, {:error, :blocked}, state}
          end
        else
          # Too early — silently ignore (VB6 behavior)
          {:reply, {:error, :too_early}, state}
        end

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  # ---- Heading ----

  @impl true
  def handle_cast({:change_heading, char_id, heading}, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | heading: heading}
        players = Map.put(state.players, char_id, entity)

        state = %{state | players: players}
        heading_raw = Encoder.encode({:character_change_heading, %{char_index: entity.char_index, heading: heading_to_int(heading)}})
        broadcast_visible(state, entity.x, entity.y, char_id, fn pid ->
          send(pid, {:send_raw, heading_raw})
        end)

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ---- Chat ----

  @impl true
  def handle_cast({:chat, char_id, message}, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        chat_raw = Encoder.encode({:chat_over_head, %{
          message: message,
          char_index: entity.char_index,
          color: 0x00FFFFFF,
          x: entity.x,
          y: entity.y,
          min_display_time: 2000,
          max_display_time: 5000
        }})

        # Send to nearby players including the speaker
        chat_recipients =
          broadcast_visible_all(state, entity.x, entity.y, fn pid ->
            send(pid, {:send_raw, chat_raw})
          end)

        Arena.Metrics.inc_chat(chat_recipients)

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ---- Timers ----

  @impl true
  def handle_info(:autosave, state) do
    # Notify each session to save its player snapshot
    for {char_id, entity} <- state.players do
      send_to_session(state.sessions, char_id, {:autosave, entity})
    end

    Process.send_after(self(), :autosave, @autosave_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    TileGrid.unload_map(state.map_id)
    :ok
  end

  # ---- Private helpers ----

  # VB6-style speed check is inline in handle_call({:move, ...}) —
  # simple elapsed >= interval gate, no accumulator needed.

  # Occupancy grid helpers
  defp occ_index(x, y), do: (y - 1) * @map_width + (x - 1)

  defp set_occupancy(occ, x, y, value) when x >= 1 and x <= @map_width and y >= 1 and y <= @map_height do
    :array.set(occ_index(x, y), value, occ)
  end
  defp set_occupancy(occ, _x, _y, _value), do: occ

  defp clear_occupancy(occ, x, y) when x >= 1 and x <= @map_width and y >= 1 and y <= @map_height do
    :array.set(occ_index(x, y), nil, occ)
  end
  defp clear_occupancy(occ, _x, _y), do: occ

  defp get_occupancy(occ, x, y) when x >= 1 and x <= @map_width and y >= 1 and y <= @map_height do
    :array.get(occ_index(x, y), occ)
  end
  defp get_occupancy(_occ, _x, _y), do: :out_of_bounds

  # Direct session sends
  defp send_to_session(sessions, char_id, msg) do
    case Map.get(sessions, char_id) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end

  # --- Spatial grid helpers ---
  # Grid cells are @cell_size × @cell_size tiles. Each cell stores a MapSet of char_ids.
  # For AoI lookup we check only the 3×3 neighborhood of cells around the origin.

  defp cell_key(x, y), do: {div(x, @cell_size), div(y, @cell_size)}

  defp grid_add(grid, x, y, char_id) do
    key = cell_key(x, y)
    Map.update(grid, key, MapSet.new([char_id]), &MapSet.put(&1, char_id))
  end

  defp grid_remove(grid, x, y, char_id) do
    key = cell_key(x, y)
    case Map.get(grid, key) do
      nil -> grid
      set ->
        new_set = MapSet.delete(set, char_id)
        if MapSet.size(new_set) == 0, do: Map.delete(grid, key), else: Map.put(grid, key, new_set)
    end
  end

  # Collect all char_ids in the 3×3 cell neighborhood around (x, y)
  defp grid_nearby_ids(grid, x, y) do
    {cx, cy} = cell_key(x, y)
    for dx <- -1..1, dy <- -1..1,
        key = {cx + dx, cy + dy},
        set = Map.get(grid, key, nil),
        set != nil,
        cid <- set,
        do: cid
  end

  # AoI broadcast using spatial grid: O(k) where k = nearby players
  defp broadcast_aoi_grid(grid, players, sessions, origin_x, origin_y, exclude_id, fun) do
    for cid <- grid_nearby_ids(grid, origin_x, origin_y),
        cid != exclude_id do
      case Map.get(players, cid) do
        nil -> :ok
        entity ->
          if abs(entity.x - origin_x) <= @aoi_range_x and abs(entity.y - origin_y) <= @aoi_range_y do
            case Map.get(sessions, cid) do
              nil -> :ok
              pid -> fun.(pid)
            end
          end
      end
    end
  end

  defp broadcast_aoi_grid_all(grid, players, sessions, origin_x, origin_y, fun) do
    for cid <- grid_nearby_ids(grid, origin_x, origin_y) do
      case Map.get(players, cid) do
        nil -> :ok
        entity ->
          if abs(entity.x - origin_x) <= @aoi_range_x and abs(entity.y - origin_y) <= @aoi_range_y do
            case Map.get(sessions, cid) do
              nil -> :ok
              pid -> fun.(pid)
            end
          end
      end
    end
  end

  # Build character_create packet data from entity
  defp character_create_packet(entity) do
    {:character_create, %{
      char_index: entity.char_index,
      body_id: entity.body_id,
      head_id: entity.head_id,
      heading: heading_to_int(entity.heading),
      x: entity.x,
      y: entity.y,
      name: entity.name || "Unknown",
      min_hp: entity.hp,
      max_hp: entity.max_hp,
      min_mana: entity.mana,
      max_mana: entity.max_mana,
      speed: entity.speeding
    }}
  end

  defp heading_to_int(:north), do: 1
  defp heading_to_int(:east), do: 2
  defp heading_to_int(:south), do: 3
  defp heading_to_int(:west), do: 4
  defp heading_to_int(_), do: 3

  # Check if the player stepped on a tile exit.
  # Does NOT remove the player from the source map — the session handler
  # calls leave/2 after successfully entering the destination map.
  # This prevents the player from being on no map if destination entry fails.
  defp check_tile_exit(state, char_id, entity, x, y) do
    case Enum.find(state.tile_exits, fn ex -> ex.x == x and ex.y == y end) do
      nil ->
        {state, false}

      %{dest_map: dest_map, dest_x: dest_x, dest_y: dest_y} ->
        send_to_session(state.sessions, char_id, {:transfer, dest_map, dest_x, dest_y, entity})
        {state, true}
    end
  end

  # --- Visibility helpers ---
  # These functions handle the three visibility modes:
  #   :global    — no AoI, all players see all players
  #   :aoi_scan  — AoI filtering by scanning all players (no spatial grid)
  #   :aoi_grid  — AoI filtering using spatial grid for O(1) lookups

  # Compute which other players are visible from (x, y), excluding self
  defp compute_visible_ids(state, x, y, exclude_id) do
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
            abs(entity.x - x) <= @aoi_range_x and abs(entity.y - y) <= @aoi_range_y
        end)
        |> Enum.map(fn {cid, _} -> cid end)
        |> MapSet.new()

      :aoi_grid ->
        grid_nearby_ids(state.grid, x, y)
        |> Enum.filter(fn cid ->
          cid != exclude_id and
            case Map.get(state.players, cid) do
              nil -> false
              entity -> abs(entity.x - x) <= @aoi_range_x and abs(entity.y - y) <= @aoi_range_y
            end
        end)
        |> MapSet.new()
    end
  end

  # Broadcast to all visible players excluding one (using current mode)
  defp broadcast_visible(state, origin_x, origin_y, exclude_id, fun) do
    results =
      case state.visibility_mode do
        :global ->
          for {cid, pid} <- state.sessions, cid != exclude_id, do: fun.(pid)

        :aoi_scan ->
          for {cid, entity} <- state.players,
              cid != exclude_id,
              abs(entity.x - origin_x) <= @aoi_range_x,
              abs(entity.y - origin_y) <= @aoi_range_y do
            case Map.get(state.sessions, cid) do
              nil -> :skip
              pid -> fun.(pid)
            end
          end

        :aoi_grid ->
          broadcast_aoi_grid(state.grid, state.players, state.sessions, origin_x, origin_y, exclude_id, fun)
      end

    length(List.wrap(results))
  end

  # Broadcast to all visible players including origin (for chat)
  defp broadcast_visible_all(state, origin_x, origin_y, fun) do
    results =
      case state.visibility_mode do
        :global ->
          for {_cid, pid} <- state.sessions, do: fun.(pid)

        :aoi_scan ->
          for {cid, entity} <- state.players,
              abs(entity.x - origin_x) <= @aoi_range_x,
              abs(entity.y - origin_y) <= @aoi_range_y do
            case Map.get(state.sessions, cid) do
              nil -> :skip
              pid -> fun.(pid)
            end
          end

        :aoi_grid ->
          broadcast_aoi_grid_all(state.grid, state.players, state.sessions, origin_x, origin_y, fun)
      end

    length(List.wrap(results))
  end

  # Grid maintenance: add/remove only in :aoi_grid mode
  defp maybe_grid_add(state, x, y, char_id) do
    if state.visibility_mode == :aoi_grid do
      grid_add(state.grid, x, y, char_id)
    else
      state.grid
    end
  end

  defp maybe_grid_remove(state, x, y, char_id) do
    if state.visibility_mode == :aoi_grid do
      grid_remove(state.grid, x, y, char_id)
    else
      state.grid
    end
  end

  # --- Visible set lifecycle ---
  # Each player has a MapSet of char_ids they can currently see.
  # In :global mode, visible_sets is nil — create/remove go to everyone.

  # Handle enter: compute visible set, send creates both ways
  defp enter_visibility(state, entity, sessions) do
    if state.visible_sets == nil do
      # :global mode — broadcast to everyone, no visible set tracking
      create_raw = Encoder.encode(character_create_packet(entity))
      for {cid, pid} <- sessions, cid != entity.char_id, do: send(pid, {:send_raw, create_raw})
      {nil, state.players}
    else
      visible_ids = compute_visible_ids(state, entity.x, entity.y, entity.char_id)
      visible_sets = Map.put(state.visible_sets, entity.char_id, visible_ids)

      create_raw = Encoder.encode(character_create_packet(entity))
      visible_sets =
        Enum.reduce(visible_ids, visible_sets, fn other_id, vs ->
          send_to_session(sessions, other_id, {:send_raw, create_raw})
          Map.update(vs, other_id, MapSet.new([entity.char_id]), &MapSet.put(&1, entity.char_id))
        end)

      nearby = Map.take(state.players, MapSet.to_list(visible_ids) ++ [entity.char_id])
      {visible_sets, nearby}
    end
  end

  # Handle leave/transfer: send removal to observers, clean up visible sets
  defp remove_from_visibility(state, char_id, entity) do
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
          send_to_session(state.sessions, other_id, {:send_raw, remove_raw})
          Map.update(vs, other_id, MapSet.new(), &MapSet.delete(&1, char_id))
        end)

      Map.delete(visible_sets, char_id)
    end
  end

  # After a move, diff old visible set vs new, send create/remove both ways
  defp update_visible_set_on_move(state, char_id, entity) do
    if state.visible_sets == nil do
      # :global mode — no boundary crossings needed
      state
    else
      old_visible = Map.get(state.visible_sets, char_id, MapSet.new())
      new_visible = compute_visible_ids(state, entity.x, entity.y, char_id)

      entered = MapSet.difference(new_visible, old_visible)
      left = MapSet.difference(old_visible, new_visible)

      # Players that just entered mover's AoI: send create both ways
      create_mover_raw = Encoder.encode(character_create_packet(entity))
      visible_sets =
        Enum.reduce(entered, state.visible_sets, fn other_id, vs ->
          other = Map.get(state.players, other_id)
          if other do
            send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode(character_create_packet(other))})
          end
          send_to_session(state.sessions, other_id, {:send_raw, create_mover_raw})
          Map.update(vs, other_id, MapSet.new([char_id]), &MapSet.put(&1, char_id))
        end)

      # Players that just left mover's AoI: send remove both ways
      remove_mover_raw = Encoder.encode({:character_remove, %{char_index: entity.char_index}})
      visible_sets =
        Enum.reduce(left, visible_sets, fn other_id, vs ->
          other = Map.get(state.players, other_id)
          if other do
            send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:character_remove, %{char_index: other.char_index}})})
          end
          send_to_session(state.sessions, other_id, {:send_raw, remove_mover_raw})
          Map.update(vs, other_id, MapSet.new(), &MapSet.delete(&1, char_id))
        end)

      visible_sets = Map.put(visible_sets, char_id, new_visible)
      %{state | visible_sets: visible_sets}
    end
  end

  # Find a nearby unoccupied walkable tile, spiraling outward from (x, y).
  # Returns the original position if it is already free, otherwise searches up to 50 tiles out.
  defp find_unoccupied_spawn(state, x, y) do
    if TileGrid.is_walkable(state.map_id, x, y) and get_occupancy(state.occupancy, x, y) == nil do
      {x, y}
    else
      Enum.find_value(1..50, {x, y}, fn radius ->
        Enum.find_value(-radius..radius, fn dx ->
          Enum.find_value(-radius..radius, fn dy ->
            if abs(dx) == radius or abs(dy) == radius do
              nx = x + dx
              ny = y + dy

              if nx >= 1 and nx <= @map_width and ny >= 1 and ny <= @map_height and
                   TileGrid.is_walkable(state.map_id, nx, ny) and
                   get_occupancy(state.occupancy, nx, ny) == nil do
                {nx, ny}
              end
            end
          end)
        end)
      end)
    end
  end

  # --- Ground items / inventory helpers ---

  defp build_ground_items(objects) do
    objects
    |> Enum.reduce(%{}, fn obj, acc ->
      Map.put(acc, {obj.x, obj.y}, %{item_id: obj.obj_index, amount: obj.amount})
    end)
  end

  defp send_inventory_slot(sessions, char_id, inventory, slot) do
    case Enum.at(inventory, slot) do
      nil ->
        send_to_session(sessions, char_id, {:send_raw,
          Encoder.encode({:change_inventory_slot, %{slot: slot + 1, obj_index: 0, amount: 0}})})

      item ->
        item_def = GameData.get_item(item.item_id)
        valor = if item_def, do: item_def.valor, else: 0

        send_to_session(sessions, char_id, {:send_raw,
          Encoder.encode({:change_inventory_slot, %{
            slot: slot + 1,
            obj_index: item.item_id,
            amount: item.amount,
            equipped: item.equipped,
            valor: valor / 1
          }})})
    end
  end

  defp broadcast_object_create(state, x, y, item_id, amount) do
    item_def = GameData.get_item(item_id)
    grh = if item_def, do: item_def.grh_index, else: 0

    raw = Encoder.encode({:object_create, %{x: x, y: y, obj_index: grh, amount: amount}})
    broadcast_visible_all(state, x, y, fn pid -> send(pid, {:send_raw, raw}) end)
  end

  defp broadcast_object_delete(state, x, y) do
    raw = Encoder.encode({:object_delete, %{x: x, y: y}})
    broadcast_visible_all(state, x, y, fn pid -> send(pid, {:send_raw, raw}) end)
  end

  # Apply item use effects based on obj_type
  # ObjType reference: 1=potion, 5=money, 8=food, 9=drink, 11=arrow, 13=key
  defp apply_item_use(entity, item_def, slot, state) do
    case item_def.obj_type do
      # Food
      8 ->
        new_hunger = min(entity.hunger + item_def.min_ham, 100)
        entity = %{entity | hunger: new_hunger}
        {:ok, entity, consume_and_notify(entity, slot, state, :hunger)}

      # Drink
      9 ->
        new_thirst = min(entity.thirst + item_def.min_sed, 100)
        entity = %{entity | thirst: new_thirst}
        {:ok, entity, consume_and_notify(entity, slot, state, :thirst)}

      # Potion (tipo_pocion: 1=HP, 2=Mana, 4=Stamina, 6=Strength, etc.)
      1 ->
        entity = apply_potion(entity, item_def)
        {:ok, entity, consume_and_notify(entity, slot, state, :potion)}

      _ ->
        {:error, :not_usable}
    end
  end

  defp apply_potion(entity, item_def) do
    amount = Enum.random(item_def.min_modificador..max(item_def.max_modificador, item_def.min_modificador))

    case item_def.tipo_pocion do
      1 -> %{entity | hp: min(entity.hp + amount, entity.max_hp)}
      2 -> %{entity | mana: min(entity.mana + amount, entity.max_mana)}
      4 -> %{entity | stamina: min(entity.stamina + amount, entity.max_stamina)}
      _ -> entity
    end
  end

  defp consume_and_notify(entity, slot, state, effect_type) do
    {:ok, new_inventory, _} = Inventory.remove_from_slot(entity.inventory, slot, 1)
    entity = %{entity | inventory: new_inventory}
    players = Map.put(state.players, entity.char_id, entity)
    state = %{state | players: players}

    send_inventory_slot(state.sessions, entity.char_id, new_inventory, slot)

    case effect_type do
      :hunger ->
        send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_hunger_and_thirst, %{
            max_hunger: 100, min_hunger: entity.hunger,
            max_thirst: 100, min_thirst: entity.thirst
          }})})

      :thirst ->
        send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_hunger_and_thirst, %{
            max_hunger: 100, min_hunger: entity.hunger,
            max_thirst: 100, min_thirst: entity.thirst
          }})})

      :potion ->
        send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_hp, %{min_hp: entity.hp}})})
        send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})
        send_to_session(state.sessions, entity.char_id, {:send_raw,
          Encoder.encode({:update_stamina, %{min_sta: entity.stamina}})})
    end

    state
  end

  # Scan for a walkable tile near the center of the map
  defp find_spawn_point(map_id) do
    # Pick a random walkable tile. Try 200 times, fallback to center.
    Enum.find_value(1..200, {50, 50}, fn _ ->
      x = :rand.uniform(@map_width)
      y = :rand.uniform(@map_height)
      if TileGrid.is_walkable(map_id, x, y), do: {x, y}
    end)
  end

  defp maps_dir do
    Application.get_env(:arena, :maps_dir, "../resources/raw/Mapas")
  end
end
