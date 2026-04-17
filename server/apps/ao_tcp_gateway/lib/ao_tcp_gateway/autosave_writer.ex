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
  def handle_info({:write_done, char_id, result, duration}, state) do
    event = if result == :ok, do: :ok, else: :error

    :telemetry.execute([:arena, :persistence, :autosave],
      %{duration: duration, count: 1},
      %{char_id: char_id, event: event})

    if result != :ok do
      Logger.error("Autosave failed for #{char_id}: #{inspect(result)}")
    end

    # Demonitor and clean up the task_monitors entry for this char_id
    state = demonitor_for_char(state, char_id)

    state = %{state | in_flight: Map.delete(state.in_flight, char_id)}

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

  # ---- Internal ----

  defp start_write(state, char_id, snapshot) do
    parent = self()

    :telemetry.execute([:arena, :persistence, :autosave], %{count: 1},
      %{char_id: char_id, event: :started})

    try do
      {:ok, pid} =
        Task.start(fn ->
          start = System.monotonic_time()

          result =
            case GameBackend.Characters.save_snapshot(char_id, snapshot.attrs,
                   inventory: snapshot.inventory,
                   equipment: snapshot.equipment,
                   skills: snapshot.skills,
                   spells: snapshot.spells
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> {:error, reason}
            end

          duration = System.monotonic_time() - start
          send(parent, {:write_done, char_id, result, duration})
        end)

      monitor_ref = Process.monitor(pid)
      state = %{state |
        in_flight: Map.put(state.in_flight, char_id, true),
        task_monitors: Map.put(state.task_monitors, monitor_ref, char_id)
      }
      {:noreply, state}
    rescue
      e ->
        Logger.error("Failed to start autosave task for #{char_id}: #{inspect(e)}")

        :telemetry.execute([:arena, :persistence, :autosave], %{count: 1},
          %{char_id: char_id, event: :error})

        # Resolve flush waiters since the write won't happen
        notify_and_clear_waiters(state, char_id)
    end
  end

  defp demonitor_for_char(state, char_id) do
    case Enum.find(state.task_monitors, fn {_ref, cid} -> cid == char_id end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        %{state | task_monitors: Map.delete(state.task_monitors, ref)}

      nil ->
        state
    end
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
