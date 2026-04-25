defmodule AoTcpGateway.AutosaveWriter do
  @moduledoc """
  Serialized, coalescing autosave writer.

  One in-flight DB write per character, never more. If multiple autosaves
  arrive while a write is in progress, only the latest snapshot is kept.
  This is intentionally async — autosave is a best-effort snapshot path,
  not the authoritative persistence boundary.

  API:
  - submit(entity) — enqueue or coalesce a snapshot (async, fire-and-forget)
  - flush(char_id) — block until any pending/in-flight write for char_id completes
  """

  use GenServer

  require Logger

  # ---- Public API ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Submit an entity snapshot for async persistence. Latest-snapshot-wins."
  def submit(entity) do
    GenServer.cast(__MODULE__, {:submit, entity})
  end

  @doc "Block until any pending or in-flight autosave for char_id completes."
  def flush(char_id, timeout \\ 10_000) do
    GenServer.call(__MODULE__, {:flush, char_id}, timeout)
  end

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    {:ok, %{pending: %{}, in_flight: %{}, flush_waiters: %{}, task_monitors: %{}}}
  end

  @impl true
  def handle_cast({:submit, entity}, state) do
    char_id = entity.char_id
    snapshot = snapshot_from_entity(entity)

    :telemetry.execute([:arena, :persistence, :autosave], %{count: 1},
      %{char_id: char_id, event: :submitted})

    if Map.has_key?(state.in_flight, char_id) do
      # Write in progress — coalesce by keeping only the latest snapshot
      old = Map.has_key?(state.pending, char_id)

      if old do
        :telemetry.execute([:arena, :persistence, :autosave], %{count: 1},
          %{char_id: char_id, event: :coalesced})
      end

      {:noreply, %{state | pending: Map.put(state.pending, char_id, snapshot)}}
    else
      # No write in progress — start one now
      start_write(state, char_id, snapshot)
    end
  end

  @impl true
  def handle_call({:flush, char_id}, from, state) do
    if not Map.has_key?(state.in_flight, char_id) and not Map.has_key?(state.pending, char_id) do
      # Nothing pending or in-flight — reply immediately
      {:reply, :ok, state}
    else
      # Register waiter — will be notified when all writes for char_id complete
      waiters = Map.update(state.flush_waiters, char_id, [from], &[from | &1])
      {:noreply, %{state | flush_waiters: waiters}}
    end
  end

  @impl true
  def handle_info({ref, {char_id, result, duration}}, state) when is_reference(ref) do
    # Task.Supervisor.async_nolink monitors the task; flush the trailing :DOWN.
    Process.demonitor(ref, [:flush])

    event = if result == :ok, do: :ok, else: :error

    :telemetry.execute([:arena, :persistence, :autosave],
      %{duration: duration, count: 1},
      %{char_id: char_id, event: event})

    if result != :ok do
      Logger.error("Autosave failed for #{char_id}: #{inspect(result)}")
    end

    state = %{state |
      task_monitors: Map.delete(state.task_monitors, ref),
      in_flight: Map.delete(state.in_flight, char_id)
    }

    # Check if there's a pending (coalesced) snapshot to write next
    case Map.pop(state.pending, char_id) do
      {nil, _pending} ->
        # No more pending — notify flush waiters
        notify_and_clear_waiters(state, char_id)

      {snapshot, pending} ->
        state = %{state | pending: pending}
        {:noreply, elem(start_write(state, char_id, snapshot), 1)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.task_monitors, ref) do
      {nil, _} ->
        # Unknown monitor ref — ignore
        {:noreply, state}

      {char_id, task_monitors} ->
        Logger.error("Autosave task crashed for #{char_id}: #{inspect(reason)}")

        :telemetry.execute([:arena, :persistence, :autosave],
          %{count: 1},
          %{char_id: char_id, event: :error})

        state = %{state | task_monitors: task_monitors, in_flight: Map.delete(state.in_flight, char_id)}

        # Check if there's a pending (coalesced) snapshot to write next
        case Map.pop(state.pending, char_id) do
          {nil, _pending} ->
            notify_and_clear_waiters(state, char_id)

          {snapshot, pending} ->
            state = %{state | pending: pending}
            {:noreply, elem(start_write(state, char_id, snapshot), 1)}
        end
    end
  end

  @impl true
  def terminate(reason, state) do
    in_flight_count = map_size(state.in_flight)
    pending_count = map_size(state.pending)

    if in_flight_count > 0 or pending_count > 0 do
      Logger.info(
        "AutosaveWriter shutting down (#{inspect(reason)}): " <>
          "waiting for #{in_flight_count} in-flight, #{pending_count} pending writes"
      )

      # Wait for in-flight writes to complete (best-effort, 10s max)
      wait_in_flight(state, System.monotonic_time(:millisecond) + 10_000)
    end

    :ok
  end

  defp wait_in_flight(state, deadline) do
    if map_size(state.in_flight) == 0 and map_size(state.pending) == 0 do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        Logger.warning(
          "AutosaveWriter shutdown timeout: #{map_size(state.in_flight)} in-flight, " <>
            "#{map_size(state.pending)} pending writes still remaining"
        )
      else
        # Start any pending writes that have no in-flight counterpart
        state = start_pending_writes(state)

        # Process any incoming task results or :DOWN messages
        receive do
          {ref, {char_id, result, duration}} when is_reference(ref) ->
            Process.demonitor(ref, [:flush])
            event = if result == :ok, do: :ok, else: :error

            :telemetry.execute([:arena, :persistence, :autosave],
              %{duration: duration, count: 1},
              %{char_id: char_id, event: event})

            if result != :ok do
              Logger.error("Autosave failed during shutdown for #{char_id}: #{inspect(result)}")
            end

            state = %{state |
              task_monitors: Map.delete(state.task_monitors, ref),
              in_flight: Map.delete(state.in_flight, char_id)
            }
            wait_in_flight(state, deadline)

          {:DOWN, ref, :process, _pid, reason} ->
            case Map.pop(state.task_monitors, ref) do
              {nil, _} ->
                wait_in_flight(state, deadline)

              {char_id, task_monitors} ->
                Logger.error("Autosave task crashed during shutdown for #{char_id}: #{inspect(reason)}")
                state = %{state | task_monitors: task_monitors, in_flight: Map.delete(state.in_flight, char_id)}
                wait_in_flight(state, deadline)
            end
        after
          500 -> wait_in_flight(state, deadline)
        end
      end
    end
  end

  # Start writes for pending snapshots that don't already have an in-flight write.
  defp start_pending_writes(state) do
    ready = for {char_id, _} <- state.pending, not Map.has_key?(state.in_flight, char_id), do: char_id

    Enum.reduce(ready, state, fn char_id, acc ->
      {snapshot, pending} = Map.pop(acc.pending, char_id)
      acc = %{acc | pending: pending}
      {_, acc} = start_write(acc, char_id, snapshot)
      acc
    end)
  end

  # ---- Internal ----

  defp start_write(state, char_id, snapshot) do
    :telemetry.execute([:arena, :persistence, :autosave], %{count: 1},
      %{char_id: char_id, event: :started})

    # Supervised, monitored, not linked: a worker crash cannot take down
    # AutosaveWriter; {:DOWN, ...} clears in_flight. The Task.Supervisor
    # ensures workers are terminated cleanly during application shutdown.
    task =
      Task.Supervisor.async_nolink(AoTcpGateway.AutosaveTaskSupervisor, fn ->
        start = System.monotonic_time()

        result =
          try do
            case GameBackend.Characters.save_snapshot(char_id, snapshot.attrs,
                   inventory: snapshot.inventory,
                   equipment: snapshot.equipment,
                   skills: snapshot.skills,
                   spells: snapshot.spells
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> {:error, reason}
            end
          rescue
            e -> {:error, e}
          end

        duration = System.monotonic_time() - start
        {char_id, result, duration}
      end)

    state = %{state |
      in_flight: Map.put(state.in_flight, char_id, true),
      task_monitors: Map.put(state.task_monitors, task.ref, char_id)
    }
    {:noreply, state}
  end

  defp notify_and_clear_waiters(state, char_id) do
    case Map.pop(state.flush_waiters, char_id) do
      {nil, _} ->
        {:noreply, state}

      {waiters, flush_waiters} ->
        for from <- waiters, do: GenServer.reply(from, :ok)
        {:noreply, %{state | flush_waiters: flush_waiters}}
    end
  end

  @doc "Build a snapshot map from a PlayerEntity. Used by both autosave and cleanup."
  def snapshot_from_entity(entity) do
    %{
      attrs: GameBackend.Characters.from_entity(entity),
      inventory: GameBackend.Characters.inventory_from_entity(entity),
      equipment: GameBackend.Characters.equipment_from_entity(entity),
      skills: GameBackend.Characters.skills_from_entity(entity),
      spells: GameBackend.Characters.spells_from_entity(entity)
    }
  end
end
