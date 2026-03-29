defmodule AoTcpGateway.Application do
  @moduledoc false

  use Application

  @default_tcp_port 7666
  @default_ws_port 7667

  @impl true
  def start(_type, _args) do
    tcp_port = Application.get_env(:ao_tcp_gateway, :port, @default_tcp_port)
    ws_port = Application.get_env(:ao_tcp_gateway, :ws_port, @default_ws_port)

    ws_dispatch = :cowboy_router.compile([
      {:_, [
        {"/ao", AoTcpGateway.WsHandler, []},
        {"/", AoTcpGateway.RootHandler, []},
        {:_, Plug.Cowboy.Handler, {AoTcpGateway.WsRouter, []}}
      ]}
    ])

    children = [
      {AoTcpGateway.Listener, port: tcp_port},
      %{
        id: :ao_ws_listener,
        start: {:cowboy, :start_clear, [
          :ao_ws_listener,
          [port: ws_port, max_connections: :infinity],
          %{env: %{dispatch: ws_dispatch}}
        ]},
        type: :supervisor
      }
    ]

    opts = [strategy: :one_for_one, name: AoTcpGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
