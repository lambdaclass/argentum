defmodule Arena.Events.InvasionServer do
  @moduledoc """
  GM-triggered NPC invasion of a city/map (VB6: modInvasion).

  A GM issues `/INVASION map_id npc_id count` to spawn waves of hostile NPCs
  on a target map. The server tracks kills, announces progress, and declares
  the invasion over when all NPCs are eliminated.

  Only one invasion can be active per map at a time. Multiple maps can have
  concurrent invasions.
  """

  use GenServer

  require Logger

  alias Arena.Data.GameData
  alias AoSession.OnlineDirectory
  alias AoProtocol.Server.Encoder

  # ── Types ──────────────────────────────────────────────────────────────

  defmodule Invasion do
    @moduledoc false
    defstruct [
      :map_id,
      :npc_id,
      :total_count,
      :spawned_ids,
      :started_at,
      :started_by,
      kills: 0
    ]
  end

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start an NPC invasion on `map_id` spawning `count` NPCs of type `npc_id`.
  `gm_name` is the GM who triggered it (for announcements).

  Returns `{:ok, spawned_count}` or `{:error, reason}`.
  """
  def start_invasion(map_id, npc_id, count, gm_name \\ "GM") do
    GenServer.call(__MODULE__, {:start_invasion, map_id, npc_id, count, gm_name})
  end

  @doc """
  Notify that an NPC was killed during an invasion.
  Called from combat handlers when an NPC dies on a map with an active invasion.
  """
  def notify_npc_killed(map_id, instance_id) do
    GenServer.cast(__MODULE__, {:npc_killed, map_id, instance_id})
  end

  @doc "Stop an active invasion on a map. Returns `:ok` or `{:error, :no_invasion}`."
  def stop_invasion(map_id) do
    GenServer.call(__MODULE__, {:stop_invasion, map_id})
  end

  @doc "Get the current invasion state for a map. Returns `{:ok, invasion}` or `:no_invasion`."
  def get_invasion(map_id) do
    GenServer.call(__MODULE__, {:get_invasion, map_id})
  end

  @doc "List all active invasions."
  def list_invasions do
    GenServer.call(__MODULE__, :list_invasions)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{invasions: %{}}}
  end

  @impl true
  def handle_call({:start_invasion, map_id, npc_id, count, gm_name}, _from, state) do
    if Map.has_key?(state.invasions, map_id) do
      {:reply, {:error, :invasion_already_active}, state}
    else
      case GameData.get_npc(npc_id) do
        nil ->
          {:reply, {:error, :npc_not_found}, state}

        npc_def ->
          {spawned_ids, spawned_count} = spawn_invasion_npcs(map_id, npc_def, count)

          if spawned_count == 0 do
            {:reply, {:error, :no_npcs_spawned}, state}
          else
            invasion = %Invasion{
              map_id: map_id,
              npc_id: npc_id,
              total_count: spawned_count,
              spawned_ids: spawned_ids,
              started_at: System.system_time(:second),
              started_by: gm_name,
              kills: 0
            }

            invasions = Map.put(state.invasions, map_id, invasion)

            broadcast_console_all(
              "Invasion> #{gm_name} ha iniciado una invasion de #{spawned_count} #{npc_def.name} en el mapa #{map_id}!"
            )

            {:reply, {:ok, spawned_count}, %{state | invasions: invasions}}
          end
      end
    end
  end

  @impl true
  def handle_call({:stop_invasion, map_id}, _from, state) do
    case Map.pop(state.invasions, map_id) do
      {nil, _} ->
        {:reply, {:error, :no_invasion}, state}

      {invasion, invasions} ->
        broadcast_console_all(
          "Invasion> La invasion en el mapa #{map_id} ha sido detenida. " <>
            "#{invasion.kills}/#{invasion.total_count} NPCs fueron eliminados."
        )

        {:reply, :ok, %{state | invasions: invasions}}
    end
  end

  @impl true
  def handle_call({:get_invasion, map_id}, _from, state) do
    case Map.fetch(state.invasions, map_id) do
      {:ok, invasion} -> {:reply, {:ok, invasion}, state}
      :error -> {:reply, :no_invasion, state}
    end
  end

  @impl true
  def handle_call(:list_invasions, _from, state) do
    {:reply, {:ok, state.invasions}, state}
  end

  @impl true
  def handle_cast({:npc_killed, map_id, instance_id}, state) do
    case Map.fetch(state.invasions, map_id) do
      {:ok, invasion} ->
        if MapSet.member?(invasion.spawned_ids, instance_id) do
          new_kills = invasion.kills + 1
          remaining = invasion.total_count - new_kills
          invasion = %{invasion | kills: new_kills}

          cond do
            remaining <= 0 ->
              broadcast_console_all(
                "Invasion> La invasion en el mapa #{map_id} ha sido repelida! " <>
                  "Todos los #{invasion.total_count} NPCs fueron eliminados. Felicitaciones!"
              )

              invasions = Map.delete(state.invasions, map_id)
              {:noreply, %{state | invasions: invasions}}

            announce_milestone?(invasion.total_count, new_kills) ->
              broadcast_console_all(
                "Invasion> Mapa #{map_id}: #{new_kills}/#{invasion.total_count} NPCs eliminados. " <>
                  "Quedan #{remaining}!"
              )

              invasions = Map.put(state.invasions, map_id, invasion)
              {:noreply, %{state | invasions: invasions}}

            true ->
              invasions = Map.put(state.invasions, map_id, invasion)
              {:noreply, %{state | invasions: invasions}}
          end
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp spawn_invasion_npcs(map_id, npc_def, count) do
    Enum.reduce(1..count, {MapSet.new(), 0}, fn _i, {ids, spawned} ->
      case find_spawn_position(map_id) do
        {x, y} ->
          case spawn_single_npc(map_id, npc_def, x, y) do
            {:ok, instance_id} ->
              {MapSet.put(ids, instance_id), spawned + 1}

            _error ->
              {ids, spawned}
          end

        nil ->
          {ids, spawned}
      end
    end)
  end

  defp spawn_single_npc(map_id, npc_def, x, y) do
    try do
      Arena.Map.MapServer.spawn_invasion_npc(map_id, npc_def, x, y)
    rescue
      _ -> :error
    catch
      :exit, _ -> :error
    end
  end

  defp find_spawn_position(map_id) do
    try_find_position(map_id, 30)
  end

  defp try_find_position(_map_id, 0), do: nil

  defp try_find_position(map_id, attempts) do
    x = Enum.random(5..95)
    y = Enum.random(5..95)

    walkable =
      try do
        TileGrid.is_walkable(map_id, x, y)
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    if walkable do
      {x, y}
    else
      try_find_position(map_id, attempts - 1)
    end
  end

  defp announce_milestone?(total, kills) when total > 0 do
    pct = kills / total * 100

    Enum.any?([25, 50, 75], fn milestone ->
      prev_pct = (kills - 1) / total * 100
      prev_pct < milestone and pct >= milestone
    end)
  end

  defp announce_milestone?(_total, _kills), do: false

  defp broadcast_console_all(message) do
    raw = Encoder.encode({:console_msg, %{message: message, font_index: 0}})
    OnlineDirectory.broadcast_all({:send_raw, raw})
  end
end
