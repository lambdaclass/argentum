defmodule Arena.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Arena.Metrics.setup()

    children = [
      {Registry, keys: :unique, name: Arena.MapRegistry},
      {Phoenix.PubSub, name: Arena.PubSub},
      Arena.Data.GameData,
      Arena.PartyServer,
      Arena.GuildServer,
      Supervisor.child_spec(Arena.Map.MapSupervisor, shutdown: 30_000),
      ArenaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Arena.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Arena.Map.MapSupervisor.boot_maps()
        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ArenaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
