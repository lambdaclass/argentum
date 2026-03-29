defmodule AoTcpGateway.RootHandler do
  @moduledoc """
  Handles "/" — upgrades to WebSocket if requested, otherwise serves index.html.
  """

  def init(req, state) do
    case :cowboy_req.parse_header(<<"upgrade">>, req) do
      [<<"websocket">>] ->
        AoTcpGateway.WsHandler.init(req, state)

      _ ->
        path = Application.app_dir(:ao_tcp_gateway, "priv/static/test_client.html")

        case File.read(path) do
          {:ok, body} ->
            req = :cowboy_req.reply(200, %{<<"content-type">> => <<"text/html">>}, body, req)
            {:ok, req, state}

          {:error, _} ->
            req = :cowboy_req.reply(404, %{}, <<"test_client.html not found">>, req)
            {:ok, req, state}
        end
    end
  end

  # Delegate all websocket callbacks to WsHandler
  defdelegate websocket_init(state), to: AoTcpGateway.WsHandler
  defdelegate websocket_handle(frame, state), to: AoTcpGateway.WsHandler
  defdelegate websocket_info(info, state), to: AoTcpGateway.WsHandler
  defdelegate terminate(reason, req, state), to: AoTcpGateway.WsHandler
end
