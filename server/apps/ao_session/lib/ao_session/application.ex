defmodule AoSession.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AoSession.SessionRegistry},
      AoSession.OnlineDirectory,
      AoSession.SosQueue,
      AoSession.SessionMonitor
    ]

    opts = [strategy: :one_for_one, name: AoSession.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
