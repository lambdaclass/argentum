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
  alias Arena.Entity.NpcEntity
  alias Arena.Inventory
  alias Arena.Combat
  alias Arena.CombatStats
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @map_width 100
  @map_height 100
  @autosave_interval_ms 60_000
  # VB6: IntervaloCaminar=210, MargenDeIntervaloPorPing=30
  # Server allows a move if elapsed >= interval (simple timer reset, like VB6).
  # Movement is synchronous (call) — processed inline before next packet.
  @base_walk_interval_ms 210
  @attack_cooldown_ms 1500
  @spell_cooldown_ms 2000
  @npc_ai_tick_ms 500
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

  @doc "Attack in the direction the player is facing, or ranged at target coords."
  def attack(map_id, char_id, target_x \\ nil, target_y \\ nil) do
    GenServer.call(via(map_id), {:attack, char_id, target_x, target_y})
  end

  @doc "Cast a spell at the given target coordinates."
  def cast_spell(map_id, char_id, spell_slot, target_x, target_y) do
    GenServer.call(via(map_id), {:cast_spell, char_id, spell_slot, target_x, target_y})
  end

  @doc "Toggle safe mode (PvP protection)."
  def safe_toggle(map_id, char_id) do
    GenServer.call(via(map_id), {:safe_toggle, char_id})
  end

  @doc "Open commerce with NPC at target coordinates."
  def open_commerce(map_id, char_id, target_x, target_y) do
    GenServer.call(via(map_id), {:open_commerce, char_id, target_x, target_y})
  end

  @doc "Buy an item from the open NPC shop."
  def commerce_buy(map_id, char_id, slot, amount) do
    GenServer.call(via(map_id), {:commerce_buy, char_id, slot, amount})
  end

  @doc "Sell an item to the open NPC shop."
  def commerce_sell(map_id, char_id, slot, amount) do
    GenServer.call(via(map_id), {:commerce_sell, char_id, slot, amount})
  end

  @doc "Close the commerce window."
  def commerce_end(map_id, char_id) do
    GenServer.call(via(map_id), {:commerce_end, char_id})
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

          # Spawn NPC entities from map data
          occupancy = :array.new(@map_width * @map_height, default: nil)
          {npcs_live, npc_char_indices, occupancy, next_idx} =
            spawn_npcs(map_data.npcs, map_id, occupancy)

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
            # Dynamic occupancy: :array of 10000 slots, nil or {:player, char_id}/{:npc, instance_id}
            occupancy: occupancy,
            # Visibility mode: :global | :aoi_scan | :aoi_grid
            visibility_mode: visibility_mode,
            # Spatial grid: %{cell_key => MapSet.t(char_id)} (only used in :aoi_grid mode)
            grid: if(visibility_mode == :aoi_grid, do: %{}, else: nil),
            # Per-player visible sets: %{char_id => MapSet.t(char_id)}
            # Only used in :aoi_scan and :aoi_grid modes.
            visible_sets: if(visibility_mode == :global, do: nil, else: %{}),
            # Ground items: %{{x, y} => %{item_id: int, amount: int}}
            ground_items: build_ground_items(map_data.objects),
            # Counter for per-map char_index assignment (continues after NPC indices)
            next_char_index: next_idx,
            # Live NPC entities: %{instance_id => %NpcEntity{}}
            npcs_live: npcs_live,
            # Reverse map: %{char_index => instance_id}
            npc_char_indices: npc_char_indices
          }

          # Schedule NPC AI tick if map has live NPCs
          if map_size(npcs_live) > 0 do
            Process.send_after(self(), :npc_ai_tick, @npc_ai_tick_ms)
          end

          # Schedule buff decay tick
          Process.send_after(self(), :buff_tick, 1000)

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
        entity = break_invisibility(entity, state, char_id)
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
                    item_def = Arena.Data.GameData.get_item(item.item_id)

                    # If the dropped item was equipped, clear the equipment slot
                    new_equipment =
                      if item.equipped do
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

                    if item_def && item_def.destruye do
                      # Destruye items are destroyed on drop, not placed on ground
                      state = %{state | players: players}
                      send_inventory_slot(state.sessions, char_id, new_inventory, slot)
                      {:reply, :ok, state}
                    else
                      ground_items = Map.put(state.ground_items, pos, %{item_id: item.item_id, amount: drop_amount})
                      state = %{state | players: players, ground_items: ground_items}
                      send_inventory_slot(state.sessions, char_id, new_inventory, slot)
                      broadcast_object_create(state, entity.x, entity.y, item.item_id, drop_amount)
                      {:reply, :ok, state}
                    end

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
        character_info = %{
          level: entity.level,
          class: entity.class,
          race: entity.race,
          gender: entity.gender
        }
        case Inventory.equip_toggle(entity.inventory, entity.equipment, slot, character_info) do
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

  # ---- Combat ----

  @ranged_max_distance 18

  @impl true
  def handle_call({:attack, char_id, target_x, target_y}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)

        cond do
          now < entity.next_attack_at -> {:reply, {:error, :cooldown}, state}
          entity.dead -> {:reply, {:error, :dead}, state}
          entity.paralyzed -> {:reply, {:error, :paralyzed}, state}
          true ->
            entity = break_invisibility(entity, state, char_id)
            weapon_id = entity.equipment[:weapon]
            weapon_def = if weapon_id, do: GameData.get_item(weapon_id)
            is_ranged = weapon_def != nil and weapon_def.proyectil > 0

            if is_ranged and target_x != nil and target_y != nil do
              handle_ranged_attack(state, char_id, entity, weapon_def, target_x, target_y, now)
            else
              # Melee attack
              {tx, ty} = facing_tile(entity.x, entity.y, entity.heading)
              target = get_occupancy(state.occupancy, tx, ty)

              entity = %{entity | next_attack_at: now + @attack_cooldown_ms}

              swing_raw = Encoder.encode({:char_swing, %{char_index: entity.char_index}})
              broadcast_visible(state, entity.x, entity.y, char_id, fn pid ->
                send(pid, {:send_raw, swing_raw})
              end)

              state = handle_attack_target(state, char_id, entity, target)
              {:reply, :ok, state}
            end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  @impl true
  def handle_call({:cast_spell, char_id, spell_slot, target_x, target_y}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)

        cond do
          now < entity.next_spell_at -> {:reply, {:error, :cooldown}, state}
          entity.dead -> {:reply, {:error, :dead}, state}
          entity.paralyzed -> {:reply, {:error, :paralyzed}, state}
          true ->
            spell_idx = spell_slot - 1

            cond do
              spell_idx < 0 or spell_idx >= length(entity.spells) ->
                {:reply, {:error, :invalid_slot}, state}

              true ->
                spell_id = Enum.at(entity.spells, spell_idx)
                spell_def = GameData.get_spell(spell_id)

                cond do
                  spell_def == nil ->
                    {:reply, {:error, :unknown_spell}, state}

                  entity.mana < spell_def.mana_required ->
                    {:reply, {:error, :not_enough_mana}, state}

                  entity.stamina < spell_def.sta_required ->
                    {:reply, {:error, :not_enough_stamina}, state}

                  true ->
                    entity = break_invisibility(entity, state, char_id)
                    entity = %{entity |
                      mana: entity.mana - spell_def.mana_required,
                      stamina: max(entity.stamina - spell_def.sta_required, 0),
                      next_spell_at: now + @spell_cooldown_ms
                    }

                    state = apply_spell(state, char_id, entity, spell_def, target_x, target_y)
                    {:reply, :ok, state}
                end
            end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  @impl true
  def handle_call({:safe_toggle, char_id}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        new_safe = not entity.safe_mode
        entity = %{entity | safe_mode: new_safe}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        packet = if new_safe, do: {:safe_mode_on, %{}}, else: {:safe_mode_off, %{}}
        send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode(packet)})

        {:reply, :ok, state}

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  # ---- Commerce ----

  @impl true
  def handle_call({:open_commerce, char_id, target_x, target_y}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        npc_match = if target_x && target_y do
          target_occ = get_occupancy(state.occupancy, target_x, target_y)
          case target_occ do
            {:npc, inst_id} -> Map.get(state.npcs_live, inst_id)
            _ -> nil
          end
        end

        cond do
          npc_match == nil ->
            {:reply, {:error, :no_npc}, state}

          true ->
            npc_def = GameData.get_npc(npc_match.npc_id)

            cond do
              npc_def == nil or not npc_def.comercia ->
                {:reply, {:error, :not_a_merchant}, state}

              abs(entity.x - npc_match.x) > 2 or abs(entity.y - npc_match.y) > 2 ->
                {:reply, {:error, :too_far}, state}

              true ->
                entity = %{entity | commerce_npc_id: npc_match.npc_id}

                send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:commerce_init, %{npc_name: npc_def.name || "Comerciante"}})})

                npc_def.shop_items
                |> Enum.with_index(1)
                |> Enum.each(fn {%{item_id: item_id}, slot} ->
                  item_def = GameData.get_item(item_id)
                  if item_def do
                    send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:commerce_change_slot, %{
                        slot: slot,
                        obj_index: item_id,
                        amount: 10000,
                        price: item_def.valor / 1.0,
                        can_equip: 1
                      }})})
                  end
                end)

                players = Map.put(state.players, char_id, entity)
                {:reply, :ok, %{state | players: players}}
            end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  @impl true
  def handle_call({:commerce_buy, char_id, slot, amount}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        npc_id = entity.commerce_npc_id
        npc_def = if npc_id, do: GameData.get_npc(npc_id)

        if npc_def == nil or not npc_def.comercia do
          {:reply, {:error, :no_commerce}, state}
        else
          shop_item = Enum.at(npc_def.shop_items, slot - 1)

          if shop_item == nil do
            {:reply, {:error, :invalid_slot}, state}
          else
            item_def = GameData.get_item(shop_item.item_id)

            if item_def == nil do
              {:reply, {:error, :invalid_item}, state}
            else
              trading_skill = Map.get(entity.skills, :trading, 0)
              buy_price = ceil(item_def.valor / (1 + trading_skill / 100) * amount)

              if entity.gold < buy_price do
                send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:console_msg, %{message: "No tienes suficiente oro.", font_index: 0}})})
                {:reply, {:error, :not_enough_gold}, state}
              else
                case find_inventory_slot(entity, shop_item.item_id, item_def.stackable) do
                  nil ->
                    send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:console_msg, %{message: "Inventario lleno.", font_index: 0}})})
                    {:reply, {:error, :inventory_full}, state}

                  inv_slot ->
                    entity = %{entity | gold: entity.gold - buy_price}
                    current = Enum.at(entity.inventory, inv_slot)
                    new_item = if current && current.item_id == shop_item.item_id do
                      %{current | amount: current.amount + amount}
                    else
                      %{item_id: shop_item.item_id, amount: amount, equipped: false}
                    end
                    inventory = List.replace_at(entity.inventory, inv_slot, new_item)
                    entity = %{entity | inventory: inventory}

                    send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:change_inventory_slot, %{
                        slot: inv_slot + 1,
                        obj_index: shop_item.item_id,
                        amount: new_item.amount,
                        equipped: new_item.equipped,
                        valor: item_def.valor / 1.0
                      }})})
                    send_to_session(state.sessions, char_id, {:send_raw,
                      Encoder.encode({:update_gold, %{gold: entity.gold}})})

                    players = Map.put(state.players, char_id, entity)
                    {:reply, :ok, %{state | players: players}}
                end
              end
            end
          end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  @impl true
  def handle_call({:commerce_sell, char_id, slot, amount}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.commerce_npc_id == nil do
          {:reply, {:error, :no_commerce}, state}
        else
          inv_idx = slot - 1
          inv_item = Enum.at(entity.inventory, inv_idx)

          cond do
            inv_item == nil ->
              {:reply, {:error, :empty_slot}, state}

            inv_item.amount < amount ->
              {:reply, {:error, :not_enough}, state}

            true ->
              item_def = GameData.get_item(inv_item.item_id)
              sell_price = if item_def, do: div(item_def.valor, 3) * amount, else: 0

              new_amount = inv_item.amount - amount
              inventory = if new_amount <= 0 do
                List.replace_at(entity.inventory, inv_idx, nil)
              else
                List.replace_at(entity.inventory, inv_idx, %{inv_item | amount: new_amount})
              end

              entity = %{entity | inventory: inventory, gold: entity.gold + sell_price}

              if new_amount <= 0 do
                send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:change_inventory_slot, %{slot: slot, obj_index: 0, amount: 0, equipped: false, valor: 0.0}})})
              else
                valor = if item_def, do: item_def.valor / 1.0, else: 0.0
                send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:change_inventory_slot, %{
                    slot: slot, obj_index: inv_item.item_id, amount: new_amount,
                    equipped: inv_item.equipped, valor: valor
                  }})})
              end

              send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_gold, %{gold: entity.gold}})})

              players = Map.put(state.players, char_id, entity)
              {:reply, :ok, %{state | players: players}}
          end
        end

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  @impl true
  def handle_call({:commerce_end, char_id}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        entity = %{entity | commerce_npc_id: nil}
        send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:commerce_end, %{}})})
        players = Map.put(state.players, char_id, entity)
        {:reply, :ok, %{state | players: players}}

      :error -> {:reply, {:error, :not_on_map}, state}
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
  def handle_info(:npc_ai_tick, state) do
    state = Arena.NpcAi.tick(state)
    Process.send_after(self(), :npc_ai_tick, @npc_ai_tick_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:buff_tick, state) do
    now = System.monotonic_time(:millisecond)

    state = Enum.reduce(state.players, state, fn {char_id, entity}, state ->
      if entity.buffs == [] do
        state
      else
        process_player_buffs(state, char_id, entity, now)
      end
    end)

    Process.send_after(self(), :buff_tick, 1000)
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

  # Handle enter: compute visible set, send creates both ways, send nearby NPCs
  defp enter_visibility(state, entity, sessions) do
    # Send nearby NPC creates to the entering player
    send_nearby_npcs(state, entity, sessions)

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

  defp send_nearby_npcs(state, entity, sessions) do
    for {_iid, npc} <- state.npcs_live, npc.alive do
      if abs(npc.x - entity.x) <= @aoi_range_x and abs(npc.y - entity.y) <= @aoi_range_y do
        npc_def = GameData.get_npc(npc.npc_id)
        if npc_def do
          raw = Encoder.encode(npc_create_packet(npc, npc_def))
          send_to_session(sessions, entity.char_id, {:send_raw, raw})
        end
      end
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

  # --- NPC spawning ---

  defp spawn_npcs(npc_spawns, map_id, occupancy) do
    Enum.reduce(npc_spawns, {%{}, %{}, occupancy, 1}, fn npc_spawn, {live, indices, occ, next_idx} ->
      case GameData.get_npc(npc_spawn.npc_index) do
        nil -> {live, indices, occ, next_idx}
        npc_def ->
          x = npc_spawn.x
          y = npc_spawn.y

          if x >= 1 and x <= @map_width and y >= 1 and y <= @map_height and
             TileGrid.is_walkable(map_id, x, y) and :array.get(occ_index(x, y), occ) == nil do
            instance_id = next_idx
            entity = NpcEntity.from_def(npc_def, instance_id, next_idx, x, y)
            occ = set_occupancy(occ, x, y, {:npc, instance_id})
            {Map.put(live, instance_id, entity),
             Map.put(indices, next_idx, instance_id),
             occ, next_idx + 1}
          else
            {live, indices, occ, next_idx}
          end
      end
    end)
  end

  # --- Combat helpers ---

  # --- Ranged attack ---

  defp handle_ranged_attack(state, char_id, entity, _weapon_def, target_x, target_y, now) do
    # VB6 uses Chebyshev distance (max of dx, dy) for ranged checks
    distance = max(abs(entity.x - target_x), abs(entity.y - target_y))

    cond do
      distance > @ranged_max_distance ->
        send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:console_msg, %{message: "Demasiado lejos.", font_index: 0}})})
        {:reply, {:error, :out_of_range}, state}

      entity.equipment[:municion] == nil ->
        send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:console_msg, %{message: "No tienes municiones equipadas.", font_index: 0}})})
        {:reply, {:error, :no_ammo}, state}

      true ->
        ammo_id = entity.equipment[:municion]
        ammo_slot_idx = Enum.find_index(entity.inventory, fn
          %{item_id: ^ammo_id, equipped: true} -> true
          _ -> false
        end)

        if ammo_slot_idx == nil do
          entity = %{entity | equipment: Map.put(entity.equipment, :municion, nil)}
          players = Map.put(state.players, char_id, entity)
          {:reply, {:error, :no_ammo}, %{state | players: players}}
        else
          ammo_def = GameData.get_item(ammo_id)
          entity = consume_ammo(entity, state, char_id, ammo_slot_idx, ammo_id)
          entity = %{entity | next_attack_at: now + @attack_cooldown_ms}

          swing_raw = Encoder.encode({:char_swing, %{char_index: entity.char_index}})
          broadcast_visible(state, entity.x, entity.y, char_id, fn pid ->
            send(pid, {:send_raw, swing_raw})
          end)

          target = get_occupancy(state.occupancy, target_x, target_y)

          # Compute extra ammo damage
          {ammo_min, ammo_max} = if ammo_def, do: {ammo_def.min_hit, ammo_def.max_hit}, else: {0, 0}
          opts = [skill: :ranged_weapons, extra_min: ammo_min, extra_max: ammo_max]

          state = handle_attack_target(state, char_id, entity, target, opts)
          {:reply, :ok, state}
        end
    end
  end

  defp consume_ammo(entity, state, char_id, slot_idx, ammo_id) do
    slot = Enum.at(entity.inventory, slot_idx)
    new_amount = slot.amount - 1

    {inventory, equipment} = if new_amount <= 0 do
      {List.replace_at(entity.inventory, slot_idx, nil),
       Map.put(entity.equipment, :municion, nil)}
    else
      {List.replace_at(entity.inventory, slot_idx, %{slot | amount: new_amount}),
       entity.equipment}
    end

    entity = %{entity | inventory: inventory, equipment: equipment}

    # Send inventory update to client
    if new_amount <= 0 do
      send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:change_inventory_slot, %{slot: slot_idx + 1, obj_index: 0, amount: 0, equipped: false, valor: 0.0}})})
    else
      item_def = GameData.get_item(ammo_id)
      valor = if item_def, do: item_def.valor / 1, else: 0.0
      send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:change_inventory_slot, %{slot: slot_idx + 1, obj_index: ammo_id, amount: new_amount, equipped: true, valor: valor}})})
    end

    entity
  end

  # Find an inventory slot for an item: existing stack if stackable, or first empty slot
  defp find_inventory_slot(entity, item_id, stackable) do
    if stackable do
      # Try to find existing stack first
      idx = Enum.find_index(entity.inventory, fn
        %{item_id: ^item_id} -> true
        _ -> false
      end)
      idx || Enum.find_index(entity.inventory, &is_nil/1)
    else
      Enum.find_index(entity.inventory, &is_nil/1)
    end
  end

  defp facing_tile(x, y, :north), do: {x, y - 1}
  defp facing_tile(x, y, :south), do: {x, y + 1}
  defp facing_tile(x, y, :east), do: {x + 1, y}
  defp facing_tile(x, y, :west), do: {x - 1, y}
  defp facing_tile(x, y, _), do: {x, y + 1}

  defp handle_attack_target(state, char_id, entity, target, opts \\ [])

  defp handle_attack_target(state, char_id, entity, {:npc, instance_id}, opts) do
    case Map.get(state.npcs_live, instance_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      npc ->
        if not npc.alive do
          players = Map.put(state.players, char_id, entity)
          %{state | players: players}
        else
          npc_def = GameData.get_npc(npc.npc_id)
          {min_weapon, max_weapon} = CombatStats.effective_damage(entity.equipment)
          min_weapon = min_weapon + Keyword.get(opts, :extra_min, 0)
          max_weapon = max_weapon + Keyword.get(opts, :extra_max, 0)

          class_id = class_atom_to_id(entity.class)

          skill_name = Keyword.get(opts, :skill, :combat_weapons)
          weapon_skill = Map.get(entity.skills, skill_name, 50)
          npc_evasion = if npc_def, do: npc_def.poder_evasion, else: 0
          hit_roll = Combat.hit_chance(weapon_skill, entity.agi, entity.level, class_id,
                                       npc_evasion, 0, (if npc_def, do: npc_def.npc_level, else: 1), class_id)

          if :rand.uniform(100) <= hit_roll do
            raw_damage = Combat.melee_damage(min_weapon, max_weapon, entity.str, class_id)
            npc_defense = if npc_def, do: npc_def.def, else: 0
            final_damage = max(raw_damage - npc_defense, 0)

            new_hp = max(npc.hp - final_damage, 0)
            npc = %{npc | hp: new_hp}

            # Send damage feedback to attacker
            send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:user_hitted_user, %{char_index: npc.char_index, damage: final_damage, hp: new_hp}})})

            if new_hp <= 0 do
              # NPC died
              npc = %{npc | alive: false, respawn_at: System.monotonic_time(:millisecond) + ((if npc_def, do: npc_def.intervalo_respawn, else: 60) * 1000)}
              state = put_in(state.npcs_live[instance_id], npc)
              occupancy = clear_occupancy(state.occupancy, npc.x, npc.y)
              state = %{state | occupancy: occupancy}

              # Broadcast NPC removal
              remove_raw = Encoder.encode({:character_remove, %{char_index: npc.char_index}})
              broadcast_visible_all(state, npc.x, npc.y, fn pid -> send(pid, {:send_raw, remove_raw}) end)

              # Award XP
              give_exp = if npc_def, do: npc_def.give_exp, else: 0
              npc_level = if npc_def, do: npc_def.npc_level, else: 1
              xp_gained = Combat.xp_gain(final_damage, give_exp, npc.max_hp, entity.level, npc_level)
              entity = %{entity | xp: entity.xp + xp_gained}

              # Check level up
              entity = check_level_up(entity, state.sessions, char_id)

              send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_exp, %{current_xp: entity.xp, next_xp: GameData.exp_for_level(entity.level + 1) || 0}})})

              # Award gold
              give_gld = if npc_def, do: npc_def.give_gld, else: 0
              entity = if give_gld > 0, do: %{entity | gold: entity.gold + give_gld}, else: entity
              if give_gld > 0 do
                send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:update_gold, %{gold: entity.gold}})})
              end

              # Drop loot
              state = drop_npc_loot(state, npc, npc_def)

              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            else
              state = put_in(state.npcs_live[instance_id], npc)
              # NPC acquires target on being hit
              npc = %{npc | target_id: char_id}
              state = put_in(state.npcs_live[instance_id], npc)

              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            end
          else
            # Miss
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}
          end
        end
    end
  end

  defp handle_attack_target(state, char_id, entity, {:player, defender_id}, opts) do
    case Map.get(state.players, defender_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      defender ->
        cond do
          entity.safe_mode ->
            send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:console_msg, %{message: "Tienes el seguro activado.", font_index: 0}})})
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          state.safe_zone ->
            send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:console_msg, %{message: "Zona segura.", font_index: 0}})})
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          defender.dead ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          true ->
            class_id = class_atom_to_id(entity.class)
            def_class_id = class_atom_to_id(defender.class)
            {min_weapon, max_weapon} = CombatStats.effective_damage(entity.equipment)
            min_weapon = min_weapon + Keyword.get(opts, :extra_min, 0)
            max_weapon = max_weapon + Keyword.get(opts, :extra_max, 0)

            skill_name = Keyword.get(opts, :skill, :combat_weapons)
            weapon_skill = Map.get(entity.skills, skill_name, 50)
            def_tactics = Map.get(defender.skills, :combat_tactics, 50)

            hit_roll = Combat.hit_chance(weapon_skill, entity.agi, entity.level, class_id,
                                         def_tactics, defender.agi, defender.level, def_class_id)

            if :rand.uniform(100) <= hit_roll do
              shield_pct = CombatStats.shield_defense_pct(defender.equipment)
              def_skill = Map.get(defender.skills, :combat_defense, 50)

              if shield_pct > 0 and Combat.shield_block?(shield_pct, def_skill, weapon_skill) do
                send_to_session(state.sessions, defender_id, {:send_raw,
                  Encoder.encode({:blocked_with_shield_user, %{}})})
                block_raw = Encoder.encode({:blocked_with_shield_other, %{char_index: defender.char_index}})
                broadcast_visible(state, defender.x, defender.y, defender_id, fn pid ->
                  send(pid, {:send_raw, block_raw})
                end)

                players = Map.put(state.players, char_id, entity)
                %{state | players: players}
              else
                raw_damage = Combat.melee_damage(min_weapon, max_weapon, entity.str, class_id)
                {min_def, max_def} = CombatStats.effective_defense(defender.equipment)
                {final_damage, _location} = Combat.apply_defense(raw_damage, {min_def, max_def})

                new_hp = max(defender.hp - final_damage, 0)
                defender = %{defender | hp: new_hp}

                send_to_session(state.sessions, char_id, {:send_raw,
                  Encoder.encode({:user_hitted_user, %{char_index: defender.char_index, damage: final_damage, hp: entity.hp}})})
                send_to_session(state.sessions, defender_id, {:send_raw,
                  Encoder.encode({:user_hitted_by_user, %{char_index: entity.char_index, damage: final_damage, hp: new_hp}})})
                send_to_session(state.sessions, defender_id, {:send_raw,
                  Encoder.encode({:update_hp, %{min_hp: new_hp}})})

                entity = if not defender.criminal, do: %{entity | criminal: true}, else: entity

                defender = if new_hp <= 0 do
                  send_to_session(state.sessions, defender_id, {:send_raw,
                    Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})})
                  %{defender | dead: true}
                else
                  defender
                end

                players = state.players
                  |> Map.put(char_id, entity)
                  |> Map.put(defender_id, defender)
                %{state | players: players}
              end
            else
              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            end
        end
    end
  end

  defp handle_attack_target(state, char_id, entity, _no_target, _opts) do
    players = Map.put(state.players, char_id, entity)
    %{state | players: players}
  end

  # --- Spell helpers ---

  defp apply_spell(state, char_id, entity, spell_def, target_x, target_y) do
    # Broadcast FX
    if spell_def.fx_grh > 0 do
      target_occ = if target_x && target_y, do: get_occupancy(state.occupancy, target_x, target_y), else: nil
      fx_char_index = case target_occ do
        {:player, pid} -> case Map.get(state.players, pid) do nil -> 0; p -> p.char_index end
        {:npc, iid} -> case Map.get(state.npcs_live, iid) do nil -> 0; n -> n.char_index end
        _ -> entity.char_index
      end

      fx_raw = Encoder.encode({:create_fx, %{char_index: fx_char_index, fx: spell_def.fx_grh, loops: spell_def.loops}})
      broadcast_visible_all(state, entity.x, entity.y, fn pid -> send(pid, {:send_raw, fx_raw}) end)
    end

    if spell_def.wav > 0 do
      wav_raw = Encoder.encode({:play_wave, %{wav: spell_def.wav, x: entity.x, y: entity.y}})
      broadcast_visible_all(state, entity.x, entity.y, fn pid -> send(pid, {:send_raw, wav_raw}) end)
    end

    # Apply spell effect
    cond do
      # Resurrection spell
      spell_def.revivir ->
        apply_spell_resurrect(state, char_id, entity, spell_def, target_x, target_y)

      # Damage spell (sube_hp == 2)
      spell_def.sube_hp == 2 ->
        is_mage = entity.class in [:mago]
        damage = Combat.spell_damage(spell_def.min_hp, spell_def.max_hp, entity.level, is_mage)
        state = apply_spell_damage(state, char_id, entity, damage, target_x, target_y)
        state

      # Heal spell (sube_hp == 1 or sanacion)
      spell_def.sube_hp == 1 or spell_def.sanacion ->
        heal = if spell_def.max_hp > spell_def.min_hp,
          do: Enum.random(spell_def.min_hp..spell_def.max_hp),
          else: spell_def.min_hp
        state = apply_spell_heal(state, char_id, entity, heal, spell_def, target_x, target_y)
        state

      # Status effects
      spell_def.paraliza or spell_def.envenena or spell_def.cura_veneno or spell_def.invisibilidad ->
        state = apply_spell_status(state, char_id, entity, spell_def, target_x, target_y)
        state

      # Default: just update mana
      true ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}
    end
  end

  defp apply_spell_damage(state, char_id, entity, damage, target_x, target_y) do
    target = if target_x && target_y, do: get_occupancy(state.occupancy, target_x, target_y), else: nil

    case target do
      {:npc, instance_id} ->
        case Map.get(state.npcs_live, instance_id) do
          nil ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          npc when npc.alive ->
            npc_def = GameData.get_npc(npc.npc_id)
            magic_res = if npc_def, do: npc_def.magic_resistance, else: 0
            final_damage = Combat.apply_magic_resistance(damage, magic_res)
            new_hp = max(npc.hp - final_damage, 0)
            npc = %{npc | hp: new_hp}

            send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:user_hitted_user, %{char_index: npc.char_index, damage: final_damage, hp: new_hp}})})

            if new_hp <= 0 do
              npc = %{npc | alive: false, respawn_at: System.monotonic_time(:millisecond) + ((if npc_def, do: npc_def.intervalo_respawn, else: 60) * 1000)}
              state = put_in(state.npcs_live[instance_id], npc)
              occupancy = clear_occupancy(state.occupancy, npc.x, npc.y)
              state = %{state | occupancy: occupancy}

              remove_raw = Encoder.encode({:character_remove, %{char_index: npc.char_index}})
              broadcast_visible_all(state, npc.x, npc.y, fn pid -> send(pid, {:send_raw, remove_raw}) end)

              give_exp = if npc_def, do: npc_def.give_exp, else: 0
              npc_level = if npc_def, do: npc_def.npc_level, else: 1
              xp_gained = Combat.xp_gain(final_damage, give_exp, npc.max_hp, entity.level, npc_level)
              entity = %{entity | xp: entity.xp + xp_gained}
              entity = check_level_up(entity, state.sessions, char_id)

              send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_exp, %{current_xp: entity.xp, next_xp: GameData.exp_for_level(entity.level + 1) || 0}})})
              send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

              state = drop_npc_loot(state, npc, npc_def)
              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            else
              npc = %{npc | target_id: char_id}
              state = put_in(state.npcs_live[instance_id], npc)
              send_to_session(state.sessions, char_id, {:send_raw,
                Encoder.encode({:update_mana, %{min_mana: entity.mana}})})
              players = Map.put(state.players, char_id, entity)
              %{state | players: players}
            end

          _ ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}
        end

      {:player, target_id} when target_id != char_id ->
        case Map.get(state.players, target_id) do
          nil ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          defender ->
            final_damage = damage
            new_hp = max(defender.hp - final_damage, 0)
            defender = %{defender | hp: new_hp}

            send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:user_hitted_user, %{char_index: defender.char_index, damage: final_damage, hp: entity.hp}})})
            send_to_session(state.sessions, target_id, {:send_raw,
              Encoder.encode({:user_hitted_by_user, %{char_index: entity.char_index, damage: final_damage, hp: new_hp}})})
            send_to_session(state.sessions, target_id, {:send_raw,
              Encoder.encode({:update_hp, %{min_hp: new_hp}})})
            send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

            entity = if not defender.criminal, do: %{entity | criminal: true}, else: entity

            defender = if new_hp <= 0 do
              send_to_session(state.sessions, target_id, {:send_raw,
                Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})})
              %{defender | dead: true}
            else
              defender
            end

            players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, defender)
            %{state | players: players}
        end

      _ ->
        send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}
    end
  end

  defp apply_spell_heal(state, char_id, entity, heal, _spell_def, target_x, target_y) do
    target = if target_x && target_y, do: get_occupancy(state.occupancy, target_x, target_y), else: nil

    case target do
      {:player, target_id} ->
        case Map.get(state.players, target_id) do
          nil ->
            players = Map.put(state.players, char_id, entity)
            %{state | players: players}

          target_entity ->
            new_hp = min(target_entity.hp + heal, target_entity.max_hp)
            target_entity = %{target_entity | hp: new_hp}

            send_to_session(state.sessions, target_id, {:send_raw,
              Encoder.encode({:update_hp, %{min_hp: new_hp}})})
            send_to_session(state.sessions, char_id, {:send_raw,
              Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

            players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
            %{state | players: players}
        end

      _ ->
        # Self-heal
        new_hp = min(entity.hp + heal, entity.max_hp)
        entity = %{entity | hp: new_hp}

        send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_hp, %{min_hp: new_hp}})})
        send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

        players = Map.put(state.players, char_id, entity)
        %{state | players: players}
    end
  end

  defp apply_spell_status(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: get_occupancy(state.occupancy, target_x, target_y), else: nil
    now = System.monotonic_time(:millisecond)

    target_id = case target do
      {:player, tid} -> tid
      _ -> char_id
    end

    case Map.get(state.players, target_id) do
      nil ->
        players = Map.put(state.players, char_id, entity)
        %{state | players: players}

      target_entity ->
        duration_ms = max((spell_def.duration || 0) * 1000, 3000)

        target_entity = cond do
          spell_def.paraliza ->
            buff = %{type: :paralyzed, expires_at: now + div(duration_ms, 2)}
            buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :paralyzed))]
            %{target_entity | paralyzed: true, buffs: buffs}

          spell_def.envenena ->
            buff = %{type: :poisoned, expires_at: now + duration_ms, next_tick: now + 2000}
            buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :poisoned))]
            %{target_entity | poisoned: true, buffs: buffs}

          spell_def.cura_veneno ->
            buffs = Enum.reject(target_entity.buffs, &(&1.type == :poisoned))
            %{target_entity | poisoned: false, buffs: buffs}

          spell_def.invisibilidad ->
            buff = %{type: :invisible, expires_at: now + duration_ms}
            buffs = [buff | Enum.reject(target_entity.buffs, &(&1.type == :invisible))]
            %{target_entity | invisible: true, buffs: buffs}

          true -> target_entity
        end

        send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

        players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, target_entity)
        %{state | players: players}
    end
  end

  # --- Resurrection ---

  defp apply_spell_resurrect(state, char_id, entity, spell_def, target_x, target_y) do
    target = if target_x && target_y, do: get_occupancy(state.occupancy, target_x, target_y), else: nil

    target_id = case target do
      {:player, tid} -> tid
      _ -> nil
    end

    target_player = if target_id, do: Map.get(state.players, target_id)

    if target_player && target_player.dead do
      # VB6: spell min_hp is the % of max_hp to revive at (e.g. 10 → 10%)
      revive_pct = max(spell_def.min_hp, 10)
      revive_hp = max(div(target_player.max_hp * revive_pct, 100), 1)

      revived = %{target_player |
        dead: false, hp: revive_hp, mana: 0, hunger: 0, thirst: 0,
        buffs: [], paralyzed: false, poisoned: false, invisible: false
      }

      # Notify revived player
      send_to_session(state.sessions, target_id, {:send_raw,
        Encoder.encode({:update_hp, %{min_hp: revive_hp}})})
      send_to_session(state.sessions, target_id, {:send_raw,
        Encoder.encode({:update_mana, %{min_mana: 0}})})
      send_to_session(state.sessions, target_id, {:send_raw,
        Encoder.encode({:update_hunger_and_thirst, %{max_hunger: 100, min_hunger: 0, max_thirst: 100, min_thirst: 0}})})
      send_to_session(state.sessions, target_id, {:send_raw,
        Encoder.encode({:console_msg, %{message: "Has sido resucitado!", font_index: 0}})})

      # Update caster mana
      send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:update_mana, %{min_mana: entity.mana}})})

      players = state.players |> Map.put(char_id, entity) |> Map.put(target_id, revived)
      %{state | players: players}
    else
      # No dead player at target — just update caster mana
      send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:update_mana, %{min_mana: entity.mana}})})
      send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:console_msg, %{message: "No hay un jugador muerto ahi.", font_index: 5}})})
      players = Map.put(state.players, char_id, entity)
      %{state | players: players}
    end
  end

  # --- Buff tick processing ---

  @poison_tick_interval 2000

  defp process_player_buffs(state, char_id, entity, now) do
    {expired, active} = Enum.split_with(entity.buffs, fn b -> now >= b.expires_at end)

    # Clear flags for expired buffs
    entity = Enum.reduce(expired, entity, fn buff, ent ->
      case buff.type do
        :paralyzed -> %{ent | paralyzed: false}
        :poisoned -> %{ent | poisoned: false}
        :invisible -> %{ent | invisible: false}
        _ -> ent
      end
    end)

    # Process poison ticks on active poison buffs
    {entity, active} = Enum.map_reduce(active, entity, fn buff, ent ->
      if buff.type == :poisoned and now >= (buff[:next_tick] || 0) do
        damage = max(Enum.random(3..5) * div(ent.max_hp, 100), 1)
        new_hp = max(ent.hp - damage, 0)
        ent = %{ent | hp: new_hp}

        send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:update_hp, %{min_hp: new_hp}})})
        send_to_session(state.sessions, char_id, {:send_raw,
          Encoder.encode({:console_msg, %{message: "Veneno te hace #{damage} de daño.", font_index: 5}})})

        buff = %{buff | next_tick: now + @poison_tick_interval}
        {buff, ent}
      else
        {buff, ent}
      end
    end)

    entity = %{entity | buffs: active}

    # Check poison death
    entity = if entity.hp <= 0 and not entity.dead do
      send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})})
      %{entity | dead: true}
    else
      entity
    end

    players = Map.put(state.players, char_id, entity)
    %{state | players: players}
  end

  # --- Invisibility break (VB6: broken by attack, cast, pick_up) ---

  defp break_invisibility(entity, state, char_id) do
    if entity.invisible do
      buffs = Enum.reject(entity.buffs, &(&1.type == :invisible))
      entity = %{entity | invisible: false, buffs: buffs}
      send_to_session(state.sessions, char_id, {:send_raw,
        Encoder.encode({:console_msg, %{message: "Has vuelto a ser visible.", font_index: 0}})})
      entity
    else
      entity
    end
  end

  # --- NPC helpers ---

  defp drop_npc_loot(state, _npc, nil), do: state
  defp drop_npc_loot(state, npc, npc_def) do
    Enum.reduce(npc_def.loot_table, state, fn %{item_id: item_id, amount: amount}, state ->
      # Simple probability: 1 in 5 chance per loot entry
      if :rand.uniform(5) == 1 do
        pos = {npc.x, npc.y}
        unless Map.has_key?(state.ground_items, pos) do
          ground_items = Map.put(state.ground_items, pos, %{item_id: item_id, amount: amount})
          state = %{state | ground_items: ground_items}
          broadcast_object_create(state, npc.x, npc.y, item_id, amount)
          state
        else
          state
        end
      else
        state
      end
    end)
  end

  defp check_level_up(entity, sessions, char_id) do
    next_xp = GameData.exp_for_level(entity.level + 1)

    if next_xp && entity.xp >= next_xp do
      entity = %{entity | level: entity.level + 1, xp: entity.xp - next_xp}
      send_to_session(sessions, char_id, {:send_raw, Encoder.encode({:level_up, %{level: entity.level}})})
      # Recursive check for multiple level ups
      check_level_up(entity, sessions, char_id)
    else
      entity
    end
  end

  @class_id_map %{
    mago: 1, clerigo: 2, paladin: 3, cazador: 4, trabajador: 5,
    guerrero: 6, ladron: 7, bandido: 8, asesino: 9, druida: 10, bardo: 11, pirata: 12
  }

  defp class_atom_to_id(class_atom), do: Map.get(@class_id_map, class_atom, 6)

  # NPC character_create packet
  def npc_create_packet(npc_entity, npc_def) do
    {:character_create, %{
      char_index: npc_entity.char_index,
      body_id: npc_def.body,
      head_id: npc_def.head,
      heading: npc_def.heading,
      x: npc_entity.x,
      y: npc_entity.y,
      name: npc_def.name || "NPC",
      min_hp: npc_entity.hp,
      max_hp: npc_entity.max_hp,
      es_npc: 1
    }}
  end

  defp maps_dir do
    Application.get_env(:arena, :maps_dir, "../resources/raw/Mapas")
  end
end
