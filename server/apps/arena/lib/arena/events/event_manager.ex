defmodule Arena.Events.EventManager do
  @moduledoc """
  Generic timed event framework.

  Supports scheduling events with announcements, participation tracking, and
  rewards. Events can be triggered by GMs or scheduled on a timer.

  ## Event types

  - `:xp_bonus` -- double XP for a duration
  - `:gold_bonus` -- double gold drops for a duration
  - `:drop_bonus` -- increased item drop rate for a duration
  - `:custom` -- generic named event with announcements

  ## GM commands

  - `/EVENT START xp_bonus 30` -- start a 30-minute XP bonus event
  - `/EVENT START gold_bonus 60` -- start a 60-minute gold bonus event
  - `/EVENT STOP xp_bonus` -- stop a running event
  - `/EVENT LIST` -- list all active events
  """

  use GenServer

  require Logger

  alias AoSession.OnlineDirectory
  alias AoProtocol.Server.Encoder

  # ── Types ──────────────────────────────────────────────────────────────

  defmodule Event do
    @moduledoc false
    defstruct [
      :type,
      :started_at,
      :ends_at,
      :started_by,
      :timer_ref,
      :description,
      participants: MapSet.new()
    ]
  end

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a timed event.

  `type` is one of `:xp_bonus`, `:gold_bonus`, `:drop_bonus`, or `:custom`.
  `duration_minutes` is how long the event lasts.
  `gm_name` is the GM who started it.
  `description` is an optional custom description (used for `:custom` events).
  """
  def start_event(type, duration_minutes, gm_name \\ "GM", description \\ nil) do
    GenServer.call(__MODULE__, {:start_event, type, duration_minutes, gm_name, description})
  end

  @doc "Stop an active event by type."
  def stop_event(type) do
    GenServer.call(__MODULE__, {:stop_event, type})
  end

  @doc "List all active events."
  def list_events do
    GenServer.call(__MODULE__, :list_events)
  end

  @doc """
  Check if a bonus event is active.
  Returns true if an event of the given type is currently running.
  """
  def active?(type) do
    GenServer.call(__MODULE__, {:active?, type})
  end

  @doc """
  Track a player's participation in the current event.
  Used for statistics and optional rewards.
  """
  def track_participation(type, char_id) do
    GenServer.cast(__MODULE__, {:track_participation, type, char_id})
  end

  @doc "Get participant count for an active event."
  def participant_count(type) do
    GenServer.call(__MODULE__, {:participant_count, type})
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{events: %{}}}
  end

  @impl true
  def handle_call({:start_event, type, duration_minutes, gm_name, description}, _from, state) do
    if Map.has_key?(state.events, type) do
      {:reply, {:error, :event_already_active}, state}
    else
      now = System.system_time(:second)
      duration_sec = duration_minutes * 60
      ends_at = now + duration_sec

      timer_ref = Process.send_after(self(), {:event_expired, type}, duration_sec * 1000)

      desc = description || default_description(type)

      event = %Event{
        type: type,
        started_at: now,
        ends_at: ends_at,
        started_by: gm_name,
        timer_ref: timer_ref,
        description: desc,
        participants: MapSet.new()
      }

      events = Map.put(state.events, type, event)

      broadcast_console_all(
        "Evento> #{gm_name} ha iniciado: #{desc}! Duracion: #{duration_minutes} minutos."
      )

      {:reply, :ok, %{state | events: events}}
    end
  end

  @impl true
  def handle_call({:stop_event, type}, _from, state) do
    case Map.pop(state.events, type) do
      {nil, _} ->
        {:reply, {:error, :no_such_event}, state}

      {event, events} ->
        if event.timer_ref, do: Process.cancel_timer(event.timer_ref)

        participant_count = MapSet.size(event.participants)

        broadcast_console_all(
          "Evento> #{event.description} ha finalizado. " <>
            "#{participant_count} jugadores participaron."
        )

        {:reply, :ok, %{state | events: events}}
    end
  end

  @impl true
  def handle_call(:list_events, _from, state) do
    now = System.system_time(:second)

    events_info =
      Enum.map(state.events, fn {type, event} ->
        remaining = max(0, event.ends_at - now)

        %{
          type: type,
          description: event.description,
          started_by: event.started_by,
          remaining_seconds: remaining,
          participants: MapSet.size(event.participants)
        }
      end)

    {:reply, {:ok, events_info}, state}
  end

  @impl true
  def handle_call({:active?, type}, _from, state) do
    {:reply, Map.has_key?(state.events, type), state}
  end

  @impl true
  def handle_call({:participant_count, type}, _from, state) do
    case Map.fetch(state.events, type) do
      {:ok, event} -> {:reply, {:ok, MapSet.size(event.participants)}, state}
      :error -> {:reply, {:error, :no_such_event}, state}
    end
  end

  @impl true
  def handle_cast({:track_participation, type, char_id}, state) do
    case Map.fetch(state.events, type) do
      {:ok, event} ->
        event = %{event | participants: MapSet.put(event.participants, char_id)}
        events = Map.put(state.events, type, event)
        {:noreply, %{state | events: events}}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:event_expired, type}, state) do
    case Map.pop(state.events, type) do
      {nil, _} ->
        {:noreply, state}

      {event, events} ->
        participant_count = MapSet.size(event.participants)

        broadcast_console_all(
          "Evento> #{event.description} ha finalizado. " <>
            "#{participant_count} jugadores participaron."
        )

        {:noreply, %{state | events: events}}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp default_description(:xp_bonus), do: "Experiencia doble"
  defp default_description(:gold_bonus), do: "Oro doble"
  defp default_description(:drop_bonus), do: "Drop rate aumentado"
  defp default_description(:custom), do: "Evento especial"
  defp default_description(type), do: "Evento: #{type}"

  defp broadcast_console_all(message) do
    raw = Encoder.encode({:console_msg, %{message: message, font_index: 0}})
    OnlineDirectory.broadcast_all({:send_raw, raw})
  end
end
