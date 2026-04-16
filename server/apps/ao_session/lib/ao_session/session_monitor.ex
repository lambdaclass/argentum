defmodule AoSession.SessionMonitor do
  @moduledoc """
  Monitors transport pids and auto-cleans stale sessions when they die.

  If a TCP/WebSocket connection crashes without calling `SessionLogic.cleanup()`,
  the char_id would remain in the Registry and OnlineDirectory forever. This
  GenServer monitors the transport_pid and performs lightweight cleanup on
  `:DOWN` — removing entries from SessionRegistry and OnlineDirectory only.
  """

  use GenServer

  require Logger

  # ---- Public API ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start monitoring a transport_pid for the given char_id."
  def monitor(char_id, transport_pid) do
    GenServer.cast(__MODULE__, {:monitor, char_id, transport_pid})
  end

  @doc "Stop monitoring for the given char_id (called on normal unregister)."
  def demonitor(char_id) do
    GenServer.cast(__MODULE__, {:demonitor, char_id})
  end

  # ---- GenServer callbacks ----

  @impl true
  def init(_opts) do
    {:ok, %{refs: %{}, pids: %{}}}
  end

  @impl true
  def handle_cast({:monitor, char_id, pid}, state) do
    # If we already monitor this char_id, demonitor the old ref first
    state =
      case Map.pop(state.pids, char_id) do
        {nil, _pids} ->
          state

        {old_ref, pids} ->
          Process.demonitor(old_ref, [:flush])
          %{state | pids: pids, refs: Map.delete(state.refs, old_ref)}
      end

    ref = Process.monitor(pid)

    {:noreply,
     %{
       state
       | refs: Map.put(state.refs, ref, char_id),
         pids: Map.put(state.pids, char_id, ref)
     }}
  end

  @impl true
  def handle_cast({:demonitor, char_id}, state) do
    case Map.pop(state.pids, char_id) do
      {nil, _pids} ->
        {:noreply, state}

      {ref, pids} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | pids: pids, refs: Map.delete(state.refs, ref)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {char_id, refs} ->
        Logger.info("SessionMonitor: transport died for char_id #{char_id}, auto-cleaning session")
        AoSession.unregister(char_id)
        AoSession.OnlineDirectory.unregister(char_id)
        {:noreply, %{state | refs: refs, pids: Map.delete(state.pids, char_id)}}
    end
  end
end
