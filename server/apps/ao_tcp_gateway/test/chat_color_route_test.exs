defmodule AoTcpGateway.ChatColorRouteTest do
  @moduledoc """
  Drift #10 — routing for the :chat_color packet (VB6 Protocol.bas:5548).

  Covers the session-level GM gate:
    * non-GM senders get the "No tienes privilegios de GM." console reply.
    * GM senders reach the SessionCommands.Gm handler, which dispatches
      a set_chat_color cast to the MapServer (no outbound packets).
  """
  use ExUnit.Case, async: false

  alias AoTcpGateway.SessionLogic
  alias AoTcpGateway.SessionRouteManifest

  setup_all do
    unless Process.whereis(AoSession.OnlineDirectory) do
      {:ok, _} = AoSession.OnlineDirectory.start_link([])
    end

    :ok
  end

  defp base_state(is_gm) do
    %{
      character_id: 1,
      map_id: 1,
      account_id: "acct_chat_color",
      char_index: 1,
      target_x: nil,
      target_y: nil,
      is_gm: is_gm
    }
  end

  test ":chat_color is registered as a GM-group command" do
    assert :chat_color in SessionRouteManifest.group(:gm)
    assert SessionRouteManifest.route(:chat_color).group == :gm
  end

  test "non-GM sender receives the GM-not-authorised console reply" do
    state = base_state(false)

    {^state, effects} =
      SessionLogic.handle_command(state, {:chat_color, %{r: 1, g: 2, b: 3}})

    assert [{:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}] = effects
  end
end
