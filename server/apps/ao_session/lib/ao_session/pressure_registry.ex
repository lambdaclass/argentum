defmodule AoSession.PressureRegistry do
  @moduledoc """
  Per-session egress pressure, published to a public ETS table.

  The session loop calls `publish/2` whenever its egress pressure level
  changes. Producers (combat, chat, fan-out loops) call `get/1` before doing
  expensive per-recipient work — an O(1) ETS read with no GenServer hop.

  Pressure is advisory. Egress itself remains the authority on drop/coalesce
  decisions. Producers use this registry to avoid *generating* payloads
  destined for an already-saturated session — e.g., skip a non-essential
  broadcast, raise log level, or route around a slow consumer.

  On session exit, `clear/1` removes the entry. Missing entries read back
  as `:ok` so callers don't need to distinguish "no session" from "no
  pressure."
  """

  @table __MODULE__

  use GenServer

  @type pressure :: AoSession.Egress.pressure()

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, nil}
  end

  @doc "Publish the current pressure level for a session."
  @spec publish(term(), pressure()) :: :ok
  def publish(session_id, level) when level in [:ok, :warn, :high, :critical] do
    :ets.insert(@table, {session_id, level})
    :ok
  end

  @doc "Read the current pressure level for a session. Missing → `:ok`."
  @spec get(term()) :: pressure()
  def get(session_id) do
    case :ets.lookup(@table, session_id) do
      [{_, level}] -> level
      [] -> :ok
    end
  end

  @doc "Remove a session's pressure entry (call on session shutdown)."
  @spec clear(term()) :: :ok
  def clear(session_id) do
    :ets.delete(@table, session_id)
    :ok
  end

  @doc false
  def table, do: @table
end
