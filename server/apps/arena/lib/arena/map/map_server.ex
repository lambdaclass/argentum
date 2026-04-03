defmodule Arena.Map.MapServer do
  @moduledoc """
  GenServer that owns a single map instance.

  Sole authority for all online gameplay state on this map.
  Player actions are processed immediately in mailbox order.
  Periodic timers handle background work only (NPC AI, regen, autosave).

  Handler logic is delegated to domain modules:
  - `Arena.Map.Movement` — walk, heading, tile exits
  - `Arena.Map.CombatHandlers` — attack, spells, buffs, regen
  - `Arena.Map.InventoryHandlers` — pick up, drop, equip, use item
  - `Arena.Map.Commerce` — NPC shopkeeper
  - `Arena.Map.Bank` — banking
  - `Arena.Map.Trade` — user-to-user trade
  - `Arena.Map.Social` — chat, rest, meditate, heal, stats, NPC interaction
  - `Arena.Map.Visibility` — spatial grid, AoI broadcasts, visible sets
  - `Arena.Map.Helpers` — shared utilities (occupancy, packets, conversions)
  """

  use GenServer

  require Logger

  alias Arena.Map.CsmParser
  alias Arena.Entity.PlayerEntity
  alias Arena.Entity.NpcEntity
  alias Arena.Map.{Helpers, Visibility, Movement, CombatHandlers, InventoryHandlers, Commerce, Bank, Trade, Social}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @map_width 100
  @map_height 100
  @autosave_interval_ms 60_000
  @npc_ai_tick_ms 500
  @regen_tick_ms 3000

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

  @doc "Enter a player onto this map."
  def enter(map_id, %PlayerEntity{} = entity, opts \\ []) do
    GenServer.call(via(map_id), {:enter, entity, opts})
  end

  @doc "Remove a player from this map."
  def leave(map_id, char_id), do: GenServer.call(via(map_id), {:leave, char_id})

  @doc "Move a player."
  def move_character(map_id, char_id, direction), do: GenServer.call(via(map_id), {:move, char_id, direction})

  def change_heading(map_id, char_id, heading), do: GenServer.cast(via(map_id), {:change_heading, char_id, heading})
  def chat(map_id, char_id, message), do: GenServer.cast(via(map_id), {:chat, char_id, message})
  def pick_up(map_id, char_id), do: GenServer.call(via(map_id), {:pick_up, char_id})
  def drop_item(map_id, char_id, slot, amount), do: GenServer.call(via(map_id), {:drop_item, char_id, slot, amount})
  def equip_item(map_id, char_id, slot), do: GenServer.call(via(map_id), {:equip_item, char_id, slot})
  def use_item(map_id, char_id, slot), do: GenServer.call(via(map_id), {:use_item, char_id, slot})
  def attack(map_id, char_id, target_x \\ nil, target_y \\ nil), do: GenServer.call(via(map_id), {:attack, char_id, target_x, target_y})
  def cast_spell(map_id, char_id, spell_slot, target_x, target_y), do: GenServer.call(via(map_id), {:cast_spell, char_id, spell_slot, target_x, target_y})
  def safe_toggle(map_id, char_id), do: GenServer.call(via(map_id), {:safe_toggle, char_id})
  def open_commerce(map_id, char_id, target_x, target_y), do: GenServer.call(via(map_id), {:open_commerce, char_id, target_x, target_y})
  def commerce_buy(map_id, char_id, slot, amount), do: GenServer.call(via(map_id), {:commerce_buy, char_id, slot, amount})
  def commerce_sell(map_id, char_id, slot, amount), do: GenServer.call(via(map_id), {:commerce_sell, char_id, slot, amount})
  def commerce_end(map_id, char_id), do: GenServer.call(via(map_id), {:commerce_end, char_id})
  def open_bank(map_id, char_id, target_x, target_y), do: GenServer.call(via(map_id), {:open_bank, char_id, target_x, target_y})
  def bank_deposit(map_id, char_id, slot, amount, slot_destino), do: GenServer.call(via(map_id), {:bank_deposit, char_id, slot, amount, slot_destino})
  def bank_extract_item(map_id, char_id, slot, amount, slot_destino), do: GenServer.call(via(map_id), {:bank_extract_item, char_id, slot, amount, slot_destino})
  def bank_deposit_gold(map_id, char_id, amount), do: GenServer.call(via(map_id), {:bank_deposit_gold, char_id, amount})
  def bank_extract_gold(map_id, char_id, amount), do: GenServer.call(via(map_id), {:bank_extract_gold, char_id, amount})
  def bank_end(map_id, char_id), do: GenServer.call(via(map_id), {:bank_end, char_id})
  def user_trade_offer(map_id, char_id, obj_index, amount), do: GenServer.call(via(map_id), {:user_trade_offer, char_id, obj_index, amount})
  def user_trade_accept(map_id, char_id), do: GenServer.call(via(map_id), {:user_trade_accept, char_id})
  def user_trade_reject(map_id, char_id), do: GenServer.call(via(map_id), {:user_trade_reject, char_id})
  def user_trade_end(map_id, char_id), do: GenServer.call(via(map_id), {:user_trade_end, char_id})
  def yell(map_id, char_id, message), do: GenServer.cast(via(map_id), {:yell, char_id, message})
  def whisper(map_id, char_id, target_char_id, message), do: GenServer.cast(via(map_id), {:whisper, char_id, target_char_id, message})
  def rest(map_id, char_id), do: GenServer.cast(via(map_id), {:rest, char_id})
  def meditate(map_id, char_id), do: GenServer.cast(via(map_id), {:meditate, char_id})
  def heal(map_id, char_id), do: GenServer.cast(via(map_id), {:heal, char_id})
  def resucitate(map_id, char_id), do: GenServer.cast(via(map_id), {:resucitate, char_id})
  def request_atributes(map_id, char_id), do: GenServer.cast(via(map_id), {:request_atributes, char_id})
  def request_skills(map_id, char_id), do: GenServer.cast(via(map_id), {:request_skills, char_id})
  def request_mini_stats(map_id, char_id), do: GenServer.cast(via(map_id), {:request_mini_stats, char_id})
  def double_click(map_id, char_id, x, y), do: GenServer.cast(via(map_id), {:double_click, char_id, x, y})
  def snapshot_entity(map_id, char_id), do: GenServer.call(via(map_id), {:snapshot, char_id})
  def player_count(map_id), do: GenServer.call(via(map_id), :player_count)

  @doc "Check if a map process is loaded and ready to accept commands."
  def ready?(map_id) do
    GenServer.call(via(map_id), :ready?)
  catch
    :exit, _ -> false
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

          Process.send_after(self(), :autosave, @autosave_interval_ms)

          visibility_mode = Application.get_env(:arena, :visibility_mode, :aoi_grid)

          occupancy = :array.new(@map_width * @map_height, default: nil)
          {npcs_live, npc_char_indices, occupancy, next_idx} =
            spawn_npcs(map_data.npcs, map_id, occupancy)

          # Build O(1) tile exit map from list
          tile_exit_map = Map.new(map_data.tile_exits, fn ex -> {{ex.x, ex.y}, ex} end)

          # Static metadata — never changes after init
          meta = %{
            name: map_data.map_name,
            zone: map_data.zone,
            terrain: map_data.terrain,
            safe_zone: map_data.safe_zone,
            restrict_mode: Map.get(map_data, :restrict_mode, ""),
            music_hi: map_data.music_hi,
            music_low: map_data.music_low,
            layers: map_data.layers,
            npcs: map_data.npcs,
            objects: map_data.objects,
            tile_exits: map_data.tile_exits,
            tile_exit_map: tile_exit_map,
            triggers: map_data.triggers
          }

          state = %{
            map_id: map_id,
            loading: false,
            meta: meta,
            players: %{},
            sessions: %{},
            monitors: %{},
            monitor_refs: %{},
            occupancy: occupancy,
            visibility_mode: visibility_mode,
            grid: if(visibility_mode == :aoi_grid, do: %{}, else: nil),
            visible_sets: if(visibility_mode == :global, do: nil, else: %{}),
            ground_items: InventoryHandlers.build_ground_items(map_data.objects),
            next_char_index: next_idx,
            npcs_live: npcs_live,
            npc_char_indices: npc_char_indices
          }

          if map_size(npcs_live) > 0 do
            Process.send_after(self(), :npc_ai_tick, @npc_ai_tick_ms)
          end

          Process.send_after(self(), :buff_tick, 1000)
          Process.send_after(self(), :regen_tick, @regen_tick_ms)

          {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("Failed to parse map #{map_id}: #{inspect(reason)}")
        {:stop, :normal, %{map_id: map_id, loading: true}}
    end
  end

  # ---- Loading guard ----

  @impl true
  def handle_call(:ready?, _from, %{loading: true} = state), do: {:reply, false, state}
  def handle_call(:ready?, _from, state), do: {:reply, true, state}
  def handle_call(_msg, _from, %{loading: true} = state), do: {:reply, {:error, :map_loading}, state}

  # ---- Enter / Leave ----

  @impl true
  def handle_call({:enter, %PlayerEntity{} = entity, opts}, {caller_pid, _}, state) do
    with :ok <- Helpers.check_map_restriction(state.meta.restrict_mode, entity) do
      do_enter(state, entity, opts, caller_pid)
    else
      {:error, reason} ->
        send(caller_pid, {:send_raw, Encoder.encode({:console_msg, %{message: reason, font_index: 0}})})
        {:reply, {:error, :restricted}, state}
    end
  end

  @impl true
  def handle_call({:leave, char_id}, _from, state) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        state = do_remove_player(state, char_id, entity)
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

  # ---- Inventory (delegated) ----

  @impl true
  def handle_call({:pick_up, char_id}, _from, state), do: InventoryHandlers.handle_pick_up(state, char_id)
  @impl true
  def handle_call({:drop_item, char_id, slot, amount}, _from, state), do: InventoryHandlers.handle_drop_item(state, char_id, slot, amount)
  @impl true
  def handle_call({:equip_item, char_id, slot}, _from, state), do: InventoryHandlers.handle_equip_item(state, char_id, slot)
  @impl true
  def handle_call({:use_item, char_id, slot}, _from, state), do: InventoryHandlers.handle_use_item(state, char_id, slot)

  # ---- Combat (delegated) ----

  @impl true
  def handle_call({:attack, char_id, target_x, target_y}, _from, state), do: CombatHandlers.handle_attack(state, char_id, target_x, target_y)
  @impl true
  def handle_call({:cast_spell, char_id, spell_slot, target_x, target_y}, _from, state), do: CombatHandlers.handle_cast_spell(state, char_id, spell_slot, target_x, target_y)

  # ---- Commerce / Bank / Trade (delegated) ----

  # ---- Commerce / Bank / Trade (delegated) ----

  @impl true
  def handle_call({:safe_toggle, char_id}, _from, state), do: Social.handle_safe_toggle(state, char_id)
  @impl true
  def handle_call({:open_commerce, char_id, tx, ty}, _from, state), do: Commerce.handle_open_commerce(state, char_id, tx, ty)
  @impl true
  def handle_call({:commerce_buy, char_id, slot, amount}, _from, state), do: Commerce.handle_commerce_buy(state, char_id, slot, amount)
  @impl true
  def handle_call({:commerce_sell, char_id, slot, amount}, _from, state), do: Commerce.handle_commerce_sell(state, char_id, slot, amount)
  @impl true
  def handle_call({:commerce_end, char_id}, _from, state), do: Commerce.handle_commerce_end(state, char_id)
  @impl true
  def handle_call({:open_bank, char_id, tx, ty}, _from, state), do: Bank.handle_open_bank(state, char_id, tx, ty)
  @impl true
  def handle_call({:bank_deposit, char_id, slot, amount, slot_destino}, _from, state), do: Bank.handle_bank_deposit(state, char_id, slot, amount, slot_destino)
  @impl true
  def handle_call({:bank_extract_item, char_id, slot, amount, slot_destino}, _from, state), do: Bank.handle_bank_extract_item(state, char_id, slot, amount, slot_destino)
  @impl true
  def handle_call({:bank_deposit_gold, char_id, amount}, _from, state), do: Bank.handle_bank_deposit_gold(state, char_id, amount)
  @impl true
  def handle_call({:bank_extract_gold, char_id, amount}, _from, state), do: Bank.handle_bank_extract_gold(state, char_id, amount)
  @impl true
  def handle_call({:bank_end, char_id}, _from, state), do: Bank.handle_bank_end(state, char_id)
  @impl true
  def handle_call({:user_trade_offer, char_id, obj_index, amount}, _from, state), do: Trade.handle_user_trade_offer(state, char_id, obj_index, amount)
  @impl true
  def handle_call({:user_trade_accept, char_id}, _from, state), do: Trade.handle_user_trade_accept(state, char_id)
  @impl true
  def handle_call({:user_trade_reject, char_id}, _from, state), do: Trade.handle_user_trade_reject(state, char_id)
  @impl true
  def handle_call({:user_trade_end, char_id}, _from, state), do: Trade.handle_user_trade_end(state, char_id)

  # ---- Info / Map Data ----

  @impl true
  def handle_call(:player_count, _from, state), do: {:reply, map_size(state.players), state}

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      map_id: state.map_id,
      name: state.meta.name,
      zone: state.meta.zone,
      terrain: state.meta.terrain,
      safe_zone: state.meta.safe_zone,
      npc_count: length(state.meta.npcs),
      object_count: length(state.meta.objects),
      exit_count: length(state.meta.tile_exits)
    }
    {:reply, info, state}
  end

  @impl true
  def handle_call(:get_map_data, _from, state) do
    tiles = for y <- 1..100, x <- 1..100, do: TileGrid.get_tile(state.map_id, x, y)

    encode_layer = fn layer ->
      Enum.map(layer, fn %{x: x, y: y, grh_index: grh} -> [x, y, grh] end)
    end

    [l1, l2, l3, l4] = state.meta.layers

    data = %{
      map_id: state.map_id,
      name: state.meta.name,
      width: 100,
      height: 100,
      tiles: tiles,
      music_hi: state.meta.music_hi,
      music_low: state.meta.music_low,
      layers: [encode_layer.(l1), encode_layer.(l2), encode_layer.(l3), encode_layer.(l4)],
      npcs: Enum.map(state.meta.npcs, fn npc -> %{x: npc.x, y: npc.y, id: npc.npc_index} end),
      objects: Enum.map(state.meta.objects, fn obj -> %{x: obj.x, y: obj.y, id: obj.obj_index, amount: obj.amount} end),
      exits: Enum.map(state.meta.tile_exits, fn ex -> %{x: ex.x, y: ex.y, dest_map: ex.dest_map, dest_x: ex.dest_x, dest_y: ex.dest_y} end)
    }
    {:reply, data, state}
  end

  # ---- Movement (delegated) ----

  @impl true
  def handle_call({:move, char_id, direction}, _from, state), do: Movement.handle_move(state, char_id, direction)

  # ---- Casts (delegated) ----

  @impl true
  def handle_cast({:change_heading, char_id, heading}, state), do: Movement.handle_change_heading(state, char_id, heading)
  @impl true
  def handle_cast({:chat, char_id, message}, state), do: Social.handle_chat(state, char_id, message)
  @impl true
  def handle_cast({:yell, char_id, message}, state), do: Social.handle_yell(state, char_id, message)
  @impl true
  def handle_cast({:rest, char_id}, state), do: Social.handle_rest(state, char_id)
  @impl true
  def handle_cast({:meditate, char_id}, state), do: Social.handle_meditate(state, char_id)
  @impl true
  def handle_cast({:heal, char_id}, state), do: Social.handle_heal(state, char_id)
  @impl true
  def handle_cast({:resucitate, char_id}, state), do: Social.handle_resucitate(state, char_id)
  @impl true
  def handle_cast({:request_atributes, char_id}, state), do: Social.handle_request_atributes(state, char_id)
  @impl true
  def handle_cast({:request_skills, char_id}, state), do: Social.handle_request_skills(state, char_id)
  @impl true
  def handle_cast({:request_mini_stats, char_id}, state), do: Social.handle_request_mini_stats(state, char_id)
  @impl true
  def handle_cast({:double_click, char_id, x, y}, state), do: Social.handle_double_click(state, char_id, x, y)

  # ---- Timers ----

  @impl true
  def handle_info(:autosave, state) do
    for {char_id, entity} <- state.players do
      Helpers.send_to_session(state.sessions, char_id, {:autosave, entity})
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
        CombatHandlers.process_player_buffs(state, char_id, entity, now)
      end
    end)

    Process.send_after(self(), :buff_tick, 1000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:regen_tick, state) do
    state = CombatHandlers.process_regen_tick(state)
    Process.send_after(self(), :regen_tick, @regen_tick_ms)
    {:noreply, state}
  end

  # Session process crashed — clean up the player (O(1) via reverse ref map)
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitor_refs, ref) do
      {:ok, char_id} ->
        Logger.warning("Session #{char_id} crashed, cleaning up from map #{state.map_id}")
        case Map.fetch(state.players, char_id) do
          {:ok, entity} ->
            {:noreply, do_remove_player(state, char_id, entity)}
          :error ->
            {:noreply, %{state | monitors: Map.delete(state.monitors, char_id),
                                  monitor_refs: Map.delete(state.monitor_refs, ref)}}
        end

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    TileGrid.unload_map(state.map_id)
    :ok
  end

  # ---- Enter helper ----

  defp do_enter(state, entity, opts, caller_pid) do
    {x, y} =
      case Keyword.get(opts, :position) do
        {px, py} when is_integer(px) and is_integer(py) -> {px, py}
        _ -> find_spawn_point(state.map_id)
      end

    {x, y} = find_unoccupied_spawn(state, x, y)
    char_index = state.next_char_index

    entity = %{entity | x: x, y: y, char_index: char_index, map_id: state.map_id}

    # Monitor session process for crash cleanup
    ref = Process.monitor(caller_pid)

    players = Map.put(state.players, entity.char_id, entity)
    sessions = Map.put(state.sessions, entity.char_id, caller_pid)
    monitors = Map.put(state.monitors, entity.char_id, ref)
    monitor_refs = Map.put(state.monitor_refs, ref, entity.char_id)
    occupancy = Helpers.set_occupancy(state.occupancy, x, y, {:player, entity.char_id})
    grid = Visibility.maybe_grid_add(state, x, y, entity.char_id)

    state = %{state | players: players, sessions: sessions, monitors: monitors,
                      monitor_refs: monitor_refs, occupancy: occupancy, grid: grid}

    {visible_sets, reply_players} = Visibility.enter_visibility(state, entity, sessions)

    Logger.info("#{entity.name} (#{entity.char_id}) entered map #{state.map_id} at (#{x}, #{y}) index=#{char_index}")

    state = %{state | visible_sets: visible_sets, next_char_index: char_index + 1}
    {:reply, {:ok, char_index, reply_players}, state}
  end

  # Shared cleanup for leave + :DOWN — single source of truth
  defp do_remove_player(state, char_id, entity) do
    visible_sets = Visibility.remove_from_visibility(state, char_id, entity)

    # Demonitor session
    {ref, monitors} = Map.pop(state.monitors, char_id)
    monitor_refs = if ref do
      Process.demonitor(ref, [:flush])
      Map.delete(state.monitor_refs, ref)
    else
      state.monitor_refs
    end

    players = Map.delete(state.players, char_id)
    sessions = Map.delete(state.sessions, char_id)
    occupancy = Helpers.clear_occupancy(state.occupancy, entity.x, entity.y)
    grid = Visibility.maybe_grid_remove(state, entity.x, entity.y, char_id)

    %{state | players: players, sessions: sessions, monitors: monitors,
              monitor_refs: monitor_refs, occupancy: occupancy, grid: grid,
              visible_sets: visible_sets}
  end

  # ---- Private helpers (map-server-specific) ----

  defp find_spawn_point(map_id) do
    Enum.find_value(1..200, {50, 50}, fn _ ->
      x = :rand.uniform(@map_width)
      y = :rand.uniform(@map_height)
      if TileGrid.is_walkable(map_id, x, y), do: {x, y}
    end)
  end

  defp find_unoccupied_spawn(state, x, y) do
    if TileGrid.is_walkable(state.map_id, x, y) and Helpers.get_occupancy(state.occupancy, x, y) == nil do
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
                   Helpers.get_occupancy(state.occupancy, nx, ny) == nil do
                {nx, ny}
              end
            end
          end)
        end)
      end)
    end
  end

  defp spawn_npcs(npc_spawns, map_id, occupancy) do
    Enum.reduce(npc_spawns, {%{}, %{}, occupancy, 1}, fn npc_spawn, {live, indices, occ, next_idx} ->
      case GameData.get_npc(npc_spawn.npc_index) do
        nil -> {live, indices, occ, next_idx}
        npc_def ->
          x = npc_spawn.x
          y = npc_spawn.y

          if x >= 1 and x <= @map_width and y >= 1 and y <= @map_height and
             TileGrid.is_walkable(map_id, x, y) and :array.get(Helpers.occ_index(x, y), occ) == nil do
            instance_id = next_idx
            entity = NpcEntity.from_def(npc_def, instance_id, next_idx, x, y)
            occ = Helpers.set_occupancy(occ, x, y, {:npc, instance_id})
            {Map.put(live, instance_id, entity),
             Map.put(indices, next_idx, instance_id),
             occ, next_idx + 1}
          else
            {live, indices, occ, next_idx}
          end
      end
    end)
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

  defp crowd_arena_map_data do
    alias Arena.Map.CsmParser.MapData

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

  defp maps_dir do
    Application.get_env(:arena, :maps_dir, Path.join(:code.priv_dir(:arena), "maps"))
  end
end
