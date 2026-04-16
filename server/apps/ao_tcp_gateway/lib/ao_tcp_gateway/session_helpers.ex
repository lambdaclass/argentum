defmodule AoTcpGateway.SessionHelpers do
  @moduledoc """
  Shared helpers for session command modules.
  """

  @doc "Send a console message to the current session process."
  def send_console(message) do
    raw = AoProtocol.Server.Encoder.encode({:console_msg, %{message: message, font_index: 0}})
    send(self(), {:send_raw, raw})
  end

  @doc "Resolve a character ID to a player name (online or DB fallback)."
  def resolve_char_name(char_id) when is_integer(char_id) do
    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} -> info.name
      _ ->
        case GameBackend.Repo.get(GameBackend.Characters, char_id) do
          %{name: name} -> name
          _ -> "ID:#{char_id}"
        end
    end
  end

  def resolve_char_name(_), do: "Unknown"
end
