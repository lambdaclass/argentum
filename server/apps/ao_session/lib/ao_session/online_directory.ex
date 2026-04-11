defmodule AoSession.OnlineDirectory do
  @moduledoc """
  Bidirectional online player lookup: char_id ↔ name, char_id → map_id/session_pid.

  Backed by ETS for concurrent reads. GenServer only owns the table.
  """

  use GenServer

  @table :ao_online_directory

  # ---- Public API ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register an online character."
  def register(char_id, name, map_id, session_pid) do
    normalized = String.downcase(String.trim(name))

    :ets.insert(
      @table,
      {{:by_id, char_id}, %{name: name, map_id: map_id, session_pid: session_pid}}
    )

    :ets.insert(@table, {{:by_name, normalized}, char_id})
    :ok
  end

  @doc "Update map_id after transfer."
  def update_map(char_id, new_map_id) do
    case :ets.lookup(@table, {:by_id, char_id}) do
      [{key, info}] ->
        :ets.insert(@table, {key, %{info | map_id: new_map_id}})
        :ok

      [] ->
        :ok
    end
  end

  @doc "Unregister on disconnect."
  def unregister(char_id) do
    case :ets.lookup(@table, {:by_id, char_id}) do
      [{_, info}] ->
        normalized = String.downcase(String.trim(info.name))
        :ets.delete(@table, {:by_name, normalized})
        :ets.delete(@table, {:by_id, char_id})

      [] ->
        :ok
    end
  end

  @doc "Lookup by char_id. Returns `{:ok, info}` or `:not_found`."
  def lookup_by_id(char_id) do
    case :ets.lookup(@table, {:by_id, char_id}) do
      [{_, info}] -> {:ok, info}
      [] -> :not_found
    end
  end

  @doc "Lookup by character name. Returns `{:ok, char_id, info}` or `:not_found`."
  def lookup_by_name(name) do
    normalized = String.downcase(String.trim(name))

    case :ets.lookup(@table, {:by_name, normalized}) do
      [{_, char_id}] ->
        case lookup_by_id(char_id) do
          {:ok, info} -> {:ok, char_id, info}
          :not_found -> :not_found
        end

      [] ->
        :not_found
    end
  end

  @doc "Count online players."
  def online_count do
    # Count :by_id entries only (not :by_name which are secondary index)
    :ets.select_count(@table, [{{{:by_id, :_}, :_}, [], [true]}])
  end

  @doc "Send a message to every connected session pid."
  def broadcast_all(message) do
    :ets.foldl(
      fn
        {{:by_id, _char_id}, %{session_pid: pid}}, acc ->
          send(pid, message)
          acc + 1

        _other, acc ->
          acc
      end,
      0,
      @table
    )
  end

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
