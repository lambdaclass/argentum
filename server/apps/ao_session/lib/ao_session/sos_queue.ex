defmodule AoSession.SosQueue do
  @moduledoc """
  SOS/support request queue (VB6 parity: Ayuda module).

  Stores support requests submitted via QuestionGM so that GMs can
  list, remove, and clear them through the SOS panel commands.

  Also used by the /GOTO gate: lower-tier GMs (consejero, semi_dios)
  can only teleport to a player who has an active SOS request.
  """

  use Agent

  @doc "Start the SOS queue agent."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> [] end, name: name)
  end

  @doc """
  Add a support request to the queue.

  Stores `%{char_id, name, message, timestamp}`.
  If the player already has a pending request, it is replaced.
  """
  def add_request(char_id, name, message) do
    Agent.update(__MODULE__, fn queue ->
      # Remove any existing request from this char_id (replace semantics)
      queue = Enum.reject(queue, fn req -> req.char_id == char_id end)

      request = %{
        char_id: char_id,
        name: name,
        message: message,
        timestamp: System.monotonic_time(:millisecond)
      }

      queue ++ [request]
    end)

    :ok
  end

  @doc "List all pending support requests."
  def list_requests do
    Agent.get(__MODULE__, & &1)
  end

  @doc """
  Remove a support request by character name (binary, case-insensitive) or
  character id (integer).

  Returns `:ok` if found and removed, `{:error, :not_found}` otherwise.
  """
  def remove_request(name_or_id)

  def remove_request(name) when is_binary(name) do
    normalized = String.downcase(String.trim(name))

    Agent.get_and_update(__MODULE__, fn queue ->
      case Enum.split_with(queue, fn req ->
             String.downcase(String.trim(req.name)) == normalized
           end) do
        {[], _remaining} ->
          {{:error, :not_found}, queue}

        {_removed, remaining} ->
          {:ok, remaining}
      end
    end)
  end

  def remove_request(char_id) when is_integer(char_id) do
    Agent.get_and_update(__MODULE__, fn queue ->
      case Enum.split_with(queue, fn req -> req.char_id == char_id end) do
        {[], _remaining} ->
          {{:error, :not_found}, queue}

        {_removed, remaining} ->
          {:ok, remaining}
      end
    end)
  end

  @doc "Check if a player (by name) has an active SOS request."
  def has_request?(name) when is_binary(name) do
    normalized = String.downcase(String.trim(name))

    Agent.get(__MODULE__, fn queue ->
      Enum.any?(queue, fn req ->
        String.downcase(String.trim(req.name)) == normalized
      end)
    end)
  end

  @doc "Check if a player (by char_id) has an active SOS request."
  def has_request_by_id?(char_id) when is_integer(char_id) do
    Agent.get(__MODULE__, fn queue ->
      Enum.any?(queue, fn req -> req.char_id == char_id end)
    end)
  end

  @doc "Clear all pending requests."
  def clear do
    Agent.update(__MODULE__, fn _queue -> [] end)
    :ok
  end
end
