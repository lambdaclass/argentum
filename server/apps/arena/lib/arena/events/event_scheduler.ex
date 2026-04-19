defmodule Arena.Events.EventScheduler do
  @moduledoc """
  Hourly event scheduling (VB6: ModEventos / CheckEvento).

  Loads a schedule of timed events (24 hourly slots) and automatically triggers
  them when the current hour matches a configured slot. Supports XP/gold/drop
  bonus events and invasions.

  ## Schedule entries

  Each entry maps an hour (0-23) to an event type, duration, and configuration:

      %ScheduleEntry{
        id: "xp_noon",
        event_type: :xp_bonus,
        event_config: %{multiplier: 2},
        hour: 12,
        duration_minutes: 30,
        enabled: true
      }

  ## Features

  - Hourly tick checks current hour against configured schedule
  - Auto-starts events when hour matches and event is not already active
  - Duration tracking with automatic cleanup on expiry
  - Manual override via `force_event/2` for GM use
  - Injectable clock function for deterministic testing
  """

  use GenServer

  require Logger

  # ── Types ──────────────────────────────────────────────────────────────

  defmodule ScheduleEntry do
    @moduledoc false
    @enforce_keys [:id, :event_type, :hour, :duration_minutes]
    defstruct [
      :id,
      :event_type,
      :hour,
      :duration_minutes,
      event_config: %{},
      enabled: true
    ]
  end

  @tick_interval_ms 60_000

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Load or replace the full schedule."
  def load_schedule(server \\ __MODULE__, entries) do
    GenServer.call(server, {:load_schedule, entries})
  end

  @doc "Add a single schedule entry."
  def add_schedule(server \\ __MODULE__, entry) do
    GenServer.call(server, {:add_schedule, entry})
  end

  @doc "Remove a schedule entry by id."
  def remove_schedule(server \\ __MODULE__, id) do
    GenServer.call(server, {:remove_schedule, id})
  end

  @doc "List all configured schedule entries."
  def list_schedules(server \\ __MODULE__) do
    GenServer.call(server, :list_schedules)
  end

  @doc "List currently active events."
  def list_active(server \\ __MODULE__) do
    GenServer.call(server, :list_active)
  end

  @doc "Force-start a scheduled event immediately, regardless of the current hour."
  def force_event(server \\ __MODULE__, id) do
    GenServer.call(server, {:force_event, id})
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    clock_fun = Keyword.get(opts, :clock_fun, fn -> DateTime.utc_now().hour end)
    tick_interval = Keyword.get(opts, :tick_interval, @tick_interval_ms)
    schedule = Keyword.get(opts, :schedule, [])
    notify = Keyword.get(opts, :notify, nil)

    validated =
      Enum.reduce_while(schedule, {:ok, []}, fn entry, {:ok, acc} ->
        case validate_entry(entry) do
          :ok -> {:cont, {:ok, [entry | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case validated do
      {:ok, entries} ->
        timer_ref = schedule_tick(tick_interval)

        state = %{
          schedule: Enum.reverse(entries),
          active_events: %{},
          timer_ref: timer_ref,
          clock_fun: clock_fun,
          tick_interval: tick_interval,
          notify: notify
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:load_schedule, entries}, _from, state) do
    validated =
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        case validate_entry(entry) do
          :ok -> {:cont, {:ok, [entry | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case validated do
      {:ok, valid_entries} ->
        {:reply, :ok, %{state | schedule: Enum.reverse(valid_entries)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:add_schedule, entry}, _from, state) do
    case validate_entry(entry) do
      :ok ->
        if Enum.any?(state.schedule, &(&1.id == entry.id)) do
          {:reply, {:error, :duplicate_id}, state}
        else
          {:reply, :ok, %{state | schedule: state.schedule ++ [entry]}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_schedule, id}, _from, state) do
    if Enum.any?(state.schedule, &(&1.id == id)) do
      schedule = Enum.reject(state.schedule, &(&1.id == id))
      {:reply, :ok, %{state | schedule: schedule}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_schedules, _from, state) do
    {:reply, {:ok, state.schedule}, state}
  end

  @impl true
  def handle_call(:list_active, _from, state) do
    {:reply, {:ok, state.active_events}, state}
  end

  @impl true
  def handle_call({:force_event, id}, _from, state) do
    case Enum.find(state.schedule, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        if Map.has_key?(state.active_events, entry.id) do
          {:reply, {:error, :already_active}, state}
        else
          state = start_event(state, entry)
          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_info(:tick, state) do
    current_hour = state.clock_fun.()

    matching_entries =
      Enum.filter(state.schedule, fn entry ->
        entry.enabled &&
          entry.hour == current_hour &&
          not Map.has_key?(state.active_events, entry.id)
      end)

    state = Enum.reduce(matching_entries, state, &start_event(&2, &1))

    timer_ref = schedule_tick(state.tick_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info({:event_ended, event_id}, state) do
    case Map.pop(state.active_events, event_id) do
      {nil, _} ->
        {:noreply, state}

      {_event_info, active_events} ->
        Logger.info("EventScheduler: event #{event_id} ended (duration expired)")
        state = %{state | active_events: active_events}
        maybe_notify(state, {:event_ended, event_id})
        {:noreply, state}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp start_event(state, entry) do
    duration_ms = entry.duration_minutes * 60 * 1000
    timer_ref = Process.send_after(self(), {:event_ended, entry.id}, duration_ms)

    event_info = %{
      entry: entry,
      started_at: System.system_time(:second),
      timer_ref: timer_ref
    }

    Logger.info(
      "EventScheduler: starting #{entry.event_type} event '#{entry.id}' " <>
        "for #{entry.duration_minutes} minutes"
    )

    state = %{state | active_events: Map.put(state.active_events, entry.id, event_info)}
    maybe_notify(state, {:event_started, entry.id, entry})
    state
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp maybe_notify(%{notify: nil}, _msg), do: :ok
  defp maybe_notify(%{notify: pid}, msg), do: send(pid, msg)

  defp validate_entry(%ScheduleEntry{} = entry) do
    cond do
      not is_integer(entry.hour) or entry.hour < 0 or entry.hour > 23 ->
        {:error, {:invalid_hour, entry.hour}}

      not is_integer(entry.duration_minutes) or entry.duration_minutes <= 0 ->
        {:error, {:invalid_duration, entry.duration_minutes}}

      entry.id == nil ->
        {:error, :missing_id}

      entry.event_type not in [:xp_bonus, :gold_bonus, :drop_bonus, :invasion] ->
        {:error, {:invalid_event_type, entry.event_type}}

      true ->
        :ok
    end
  end

  defp validate_entry(_other) do
    {:error, :invalid_entry}
  end
end
