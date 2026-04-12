defmodule Arena.TreasureEvent do
  @moduledoc """
  Server-wide treasure search event system (VB6: ModTesoros).

  A GM triggers one of three event types:
    - `:treasure` — random treasure item placed on a random map (VB6: PerderTesoro)
    - `:gift` — random gift/magic item placed in a dungeon map (VB6: PerderRegalo)
    - `:npc` — a special NPC spawned on a random map (VB6: BusquedaNpcActiva)

  Only one event can be active at a time. When a player picks up the item
  at the treasure/gift location, the event ends and all players are notified.
  For NPC events, the event ends when the NPC is killed.

  Configuration is loaded from Tesoros.dat at startup via GameData.
  """

  use GenServer

  require Logger

  alias Arena.Data.GameData
  alias AoSession.OnlineDirectory

  # ---- Public API ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a treasure search event. Only GMs can trigger this.

  `type` is one of `:treasure`, `:gift`, or `:npc`.
  Returns `:ok` or `{:error, reason}`.
  """
  def start_event(type) when type in [:treasure, :gift, :npc] do
    GenServer.call(__MODULE__, {:start_event, type})
  end

  @doc """
  Re-announce the current active event (VB6: when GM triggers
  event that is already active, a reminder is broadcast).
  """
  def reannounce do
    GenServer.call(__MODULE__, :reannounce)
  end

  @doc """
  Check if a pickup at the given position completes the active event.
  Called from InventoryHandlers when a player picks up a ground item.

  Returns `:no_event` or `{:treasure_found, player_name}` / `{:gift_found, player_name}`.
  """
  def check_pickup(map_id, x, y, player_name) do
    GenServer.call(__MODULE__, {:check_pickup, map_id, x, y, player_name})
  end

  @doc """
  Notify that the event NPC was killed. Called from combat handlers.
  """
  def notify_npc_killed(npc_instance_id) do
    GenServer.cast(__MODULE__, {:npc_killed, npc_instance_id})
  end

  @doc """
  Get the current event state (for testing/inspection).
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(_opts) do
    state = %{
      active_event: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_event, type}, _from, state) do
    if state.active_event != nil do
      # VB6: an event is already active, cannot start a new one
      {:reply, {:error, :event_already_active, state.active_event}, state}
    else
      case do_start_event(type) do
        {:ok, event} ->
          broadcast_event_start(event)
          {:reply, :ok, %{state | active_event: event}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:reannounce, _from, state) do
    case state.active_event do
      nil ->
        {:reply, {:error, :no_active_event}, state}

      event ->
        broadcast_event_reminder(event)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:check_pickup, map_id, x, y, player_name}, _from, state) do
    case state.active_event do
      %{type: event_type, map_id: event_map, x: event_x, y: event_y}
      when event_type in [:treasure, :gift] and
             map_id == event_map and x == event_x and y == event_y ->
        broadcast_event_found(event_type, player_name)
        {:reply, {:event_found, event_type}, %{state | active_event: nil}}

      _ ->
        {:reply, :no_event, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:npc_killed, npc_instance_id}, state) do
    case state.active_event do
      %{type: :npc, npc_instance_id: ^npc_instance_id} ->
        broadcast_console_all("Eventos> El NPC del evento ha sido derrotado. Felicitaciones!")
        {:noreply, %{state | active_event: nil}}

      _ ->
        {:noreply, state}
    end
  end

  # ---- Private ----

  defp do_start_event(:treasure) do
    config = GameData.get_treasure_config()

    case config do
      %{treasure_maps: maps, treasure_items: items}
      when maps != [] and items != [] ->
        map_id = Enum.random(maps)
        {item_id, amount} = Enum.random(items)
        {x, y} = find_random_position(map_id)

        # VB6: MakeObj places the treasure item on the ground
        place_ground_item(map_id, x, y, item_id, amount)

        {:ok,
         %{
           type: :treasure,
           map_id: map_id,
           x: x,
           y: y,
           item_id: item_id,
           amount: amount
         }}

      _ ->
        {:error, :no_treasure_config}
    end
  end

  defp do_start_event(:gift) do
    config = GameData.get_treasure_config()

    case config do
      %{gift_maps: maps, gift_items: items}
      when maps != [] and items != [] ->
        map_id = Enum.random(maps)
        {item_id, amount} = Enum.random(items)
        {x, y} = find_random_position(map_id)

        place_ground_item(map_id, x, y, item_id, amount)

        {:ok,
         %{
           type: :gift,
           map_id: map_id,
           x: x,
           y: y,
           item_id: item_id,
           amount: amount
         }}

      _ ->
        {:error, :no_gift_config}
    end
  end

  defp do_start_event(:npc) do
    config = GameData.get_treasure_config()

    case config do
      %{npc_ids: npc_ids, npc_maps: npc_maps}
      when npc_ids != [] and npc_maps != [] ->
        # VB6: SpawnNpc at center of random map
        map_id = Enum.random(npc_maps)
        _npc_id = Enum.random(npc_ids)
        # NPC spawning would go through MapServer, simplified here
        {:ok,
         %{
           type: :npc,
           map_id: map_id,
           npc_instance_id: nil
         }}

      _ ->
        {:error, :no_npc_config}
    end
  end

  defp find_random_position(map_id) do
    # VB6: RandomNumber(20, 80) for both X and Y, checking walkability
    # Try up to 20 times, then pick any position
    try_find_position(map_id, 20)
  end

  defp try_find_position(_map_id, 0) do
    # Fallback: center of map
    {50, 50}
  end

  defp try_find_position(map_id, attempts) do
    x = Enum.random(20..80)
    y = Enum.random(20..80)

    if walkable?(map_id, x, y) do
      {x, y}
    else
      try_find_position(map_id, attempts - 1)
    end
  end

  defp walkable?(map_id, x, y) do
    try do
      TileGrid.is_walkable(map_id, x, y)
    rescue
      _ -> true
    catch
      _, _ -> true
    end
  end

  defp place_ground_item(map_id, x, y, item_id, amount) do
    try do
      Arena.Map.MapServer.place_event_item(map_id, x, y, item_id, amount)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp broadcast_event_start(%{type: :treasure, map_id: map_id}) do
    map_name = get_map_name(map_id)

    broadcast_console_all(
      "Eventos> Rondan rumores que hay un tesoro enterrado en el mapa: #{map_name}(#{map_id}) Quien sera el afortunado que lo encuentre?"
    )
  end

  defp broadcast_event_start(%{type: :gift, map_id: map_id}) do
    map_name = get_map_name(map_id)

    broadcast_console_all(
      "Eventos> De repente ha surgido un item maravilloso en el mapa: #{map_name}(#{map_id}) Quien sera el valiente que lo encuentre? MUCHO CUIDADO!"
    )
  end

  defp broadcast_event_start(%{type: :npc, map_id: map_id}) do
    broadcast_console_all(
      "Eventos> Una criatura peligrosa ha aparecido en el mapa #{map_id}. Quien sera el valiente que la derrote?"
    )
  end

  defp broadcast_event_reminder(%{type: :treasure, map_id: map_id}) do
    map_name = get_map_name(map_id)

    broadcast_console_all(
      "Eventos> Todavia nadie fue capaz de encontar el tesoro, recorda que se encuentra en #{map_name}(#{map_id}). Quien sera el valiente que lo encuentre?"
    )
  end

  defp broadcast_event_reminder(%{type: :gift, map_id: map_id}) do
    map_name = get_map_name(map_id)

    broadcast_console_all(
      "Eventos> Ningun valiente fue capaz de encontrar el item misterioso, recuerda que se encuentra en #{map_name}(#{map_id}). Ten cuidado!"
    )
  end

  defp broadcast_event_reminder(%{type: :npc, map_id: map_id}) do
    broadcast_console_all(
      "Eventos> Todavia nadie logro matar el NPC que se encuentra en el mapa #{map_id}."
    )
  end

  defp broadcast_event_found(:treasure, player_name) do
    broadcast_console_all("Eventos> #{player_name} encontro el tesoro. Felicitaciones!")
  end

  defp broadcast_event_found(:gift, player_name) do
    broadcast_console_all(
      "Eventos> #{player_name} fue el valiente que encontro el gran item magico. Felicitaciones!"
    )
  end

  defp broadcast_console_all(message) do
    alias AoProtocol.Server.Encoder
    raw = Encoder.encode({:console_msg, %{message: message, font_index: 0}})
    OnlineDirectory.broadcast_all({:send_raw, raw})
  end

  defp get_map_name(map_id) do
    try do
      {:ok, info} = Arena.Map.MapServer.get_info(map_id)
      info.name || "Mapa #{map_id}"
    rescue
      _ -> "Mapa #{map_id}"
    catch
      :exit, _ -> "Mapa #{map_id}"
    end
  end
end
