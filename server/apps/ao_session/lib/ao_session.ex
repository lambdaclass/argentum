defmodule AoSession do
  @moduledoc """
  Session and presence management for Argentum Online.

  Shared by both TCP (VB6 client) and WebSocket (new client) transports.
  Tracks which character_id maps to which session process.
  """

  alias AoSession.SessionRegistry

  @doc "Register a player session. Returns :ok or {:error, :already_connected}."
  def register(account_id, char_id, transport_pid) do
    case Registry.register(SessionRegistry, char_id, %{
           account_id: account_id,
           transport_pid: transport_pid,
           connected_at: System.monotonic_time(:millisecond)
         }) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :already_connected}
    end
  end

  @doc "Unregister a player session."
  def unregister(char_id) do
    Registry.unregister(SessionRegistry, char_id)
  end

  @doc "Look up a player session by char_id."
  def lookup(char_id) do
    case Registry.lookup(SessionRegistry, char_id) do
      [{pid, meta}] -> {:ok, pid, meta}
      [] -> {:error, :not_found}
    end
  end

  @doc "Count online players."
  def online_count do
    Registry.count(SessionRegistry)
  end
end
