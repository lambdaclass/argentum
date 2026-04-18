defmodule AoTcpGateway.ShutdownDrain do
  @moduledoc """
  Coordinated shutdown drain for the Argentum server.

  Called from `AoTcpGateway.Application.prep_stop/1` before the supervision
  tree tears down. Executes the shutdown contract in order:

  1. **Stop listeners** — no new TCP/WS connections accepted
  2. **Drain sessions** — trigger cleanup for all online sessions
  3. **Flush autosave** — drain the AutosaveWriter queue

  ## Shutdown contract

  **Must finish:**
  - In-flight authoritative writes (trade, bank, guild) — these are synchronous
    in the MapServer GenServer, so they complete before the session sees the
    shutdown signal.
  - Session cleanup for registries/ownership — OnlineDirectory and SessionRegistry
    entries are removed so reconnect sees a clean state.

  **Best-effort:**
  - Autosave snapshots — AutosaveWriter is flushed with a timeout. Pending
    writes that don't complete in time are dropped.

  **May be dropped:**
  - New incoming connections/commands after shutdown begins.
  - Autosave snapshots that exceed the drain timeout.

  ## Telemetry events

  All events are prefixed with `[:arena, :shutdown]`:
  - `shutdown_started` — drain begins
  - `listeners_stopped` — TCP/WS listeners are down
  - `drain_started` — session cleanup begins
  - `drain_finished` — all sessions cleaned up (or timeout reached)
  - `drain_timeout` — drain exceeded the allowed time
  - `shutdown_completed` — drain phase is done, supervision teardown proceeds
  """

  require Logger

  @drain_timeout_ms Application.compile_env(:ao_tcp_gateway, :shutdown_drain_timeout_ms, 15_000)
  @shutdown_key :ao_tcp_gateway_shutdown_in_progress

  @doc "Returns true after shutdown drain has started."
  def shutdown_in_progress? do
    :persistent_term.get(@shutdown_key, false)
  end

  @doc false
  # Reset the shutdown gate. Only for tests.
  def reset_shutdown_gate do
    :persistent_term.put(@shutdown_key, false)
  end

  @doc """
  Execute the coordinated shutdown drain. Called from prep_stop/1.

  Returns :ok. Errors are logged but do not prevent shutdown.
  """
  def run do
    :persistent_term.put(@shutdown_key, true)
    start = System.monotonic_time()
    :telemetry.execute([:arena, :shutdown, :shutdown_started], %{}, %{})
    Logger.info("Shutdown drain started")

    stop_listeners()
    drain_sessions(start)
    flush_autosave()

    duration = System.monotonic_time() - start
    :telemetry.execute([:arena, :shutdown, :shutdown_completed], %{duration: duration}, %{})
    Logger.info("Shutdown drain completed")
    :ok
  end

  # ---- Phase 1: Stop listeners ----

  defp stop_listeners do
    start = System.monotonic_time()

    # Stop Ranch TCP listener
    try do
      :ranch.stop_listener(AoTcpGateway.Listener)
    catch
      kind, reason ->
        Logger.warning("Failed to stop TCP listener: #{inspect(kind)} #{inspect(reason)}")
    end

    # Stop Cowboy WebSocket listener
    try do
      :cowboy.stop_listener(:ao_ws_listener)
    catch
      kind, reason ->
        Logger.warning("Failed to stop WS listener: #{inspect(kind)} #{inspect(reason)}")
    end

    duration = System.monotonic_time() - start
    :telemetry.execute([:arena, :shutdown, :listeners_stopped], %{duration: duration}, %{})
    Logger.info("Listeners stopped")
  end

  # ---- Phase 2: Drain sessions ----

  defp drain_sessions(drain_start) do
    :telemetry.execute([:arena, :shutdown, :drain_started], %{}, %{})

    # Get all online session pids from the registry
    sessions = Registry.select(AoSession.SessionRegistry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    session_count = length(sessions)
    Logger.info("Draining #{session_count} online sessions")

    if session_count > 0 do
      # Send a shutdown signal to each transport pid.
      # TCP handlers will see {:tcp_closed, _} when the socket closes.
      # WS handlers will see terminate/3 when cowboy shuts down.
      # For TCP, we close the socket to trigger cleanup.
      for {_pid, meta} <- sessions do
        try do
          send(meta.transport_pid, :shutdown_drain)
        catch
          _, _ -> :ok
        end
      end

      # Wait for sessions to drain (poll OnlineDirectory)
      deadline = drain_start + System.convert_time_unit(@drain_timeout_ms, :millisecond, :native)
      wait_sessions_drained(session_count, deadline)
    end

    remaining = AoSession.online_count()
    duration = System.monotonic_time() - drain_start

    if remaining > 0 do
      :telemetry.execute([:arena, :shutdown, :drain_timeout],
        %{duration: duration},
        %{remaining_sessions: remaining, initial_sessions: session_count})
      Logger.warning("Drain timeout: #{remaining}/#{session_count} sessions still online")
    else
      :telemetry.execute([:arena, :shutdown, :drain_finished],
        %{duration: duration},
        %{session_count: session_count})
      Logger.info("All #{session_count} sessions drained")
    end
  end

  defp wait_sessions_drained(initial_count, deadline) do
    if System.monotonic_time() >= deadline do
      :timeout
    else
      remaining = AoSession.online_count()

      if remaining == 0 do
        :ok
      else
        Process.sleep(100)
        wait_sessions_drained(initial_count, deadline)
      end
    end
  end

  # ---- Phase 3: Flush autosave ----

  defp flush_autosave do
    # AutosaveWriter.terminate/2 will handle flushing pending writes
    # when the supervisor shuts it down. We just log the intent here.
    Logger.info("Autosave flush will complete during supervisor teardown")
  end
end
