defmodule Arena.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Arena.Metrics.setup()

    children = [
      {Registry, keys: :unique, name: Arena.MapRegistry},
      {Phoenix.PubSub, name: Arena.PubSub},
      Arena.PromEx,
      Arena.Settings,
      Arena.Data.GameData,
      Arena.WorldWeather,
      Arena.TreasureEvent,
      Arena.PartyServer,
      Arena.GuildServer,
      Arena.DuelServer,
      Arena.Auction,
      Arena.Forum,
      Arena.Events.InvasionServer,
      Arena.Events.TournamentServer,
      Arena.Events.EventManager,
      Supervisor.child_spec(Arena.Map.MapSupervisor, shutdown: 30_000),
      ArenaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Arena.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Order matters. Build the pack first so its content hash is known, check the exit
        # annotations against *that* -- not against their own version.txt, which only proves
        # the artefact agrees with itself -- and only then start the MapServers that will
        # trust those annotations to decide where a character may be put.
        Arena.ClientMapPack.manifest()
        Arena.World.ExitAnnotations.verify!()
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
