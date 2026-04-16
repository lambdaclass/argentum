defmodule Arena.MixProject do
  use Mix.Project

  def project do
    [
      app: :arena,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # Cross-app runtime calls that cannot be declared as Mix deps.
      #
      # GameBackend modules: arena uses game_backend as its persistence layer
      # but cannot declare {:game_backend, in_umbrella: true} because
      # game_backend already depends on arena (for Arena.Entity.PlayerEntity
      # in Characters.to_entity/from_entity). Adding the dep would create a
      # Mix cycle. TODO: extract PlayerEntity to a shared app to break this.
      #
      # AoTcpGateway/AoSession: sibling umbrella apps that arena calls at
      # runtime (function dispatch, GenServer.call). Declaring them as deps
      # would also create cycles since they already depend on arena.
      xref: [
        exclude: [
          GameBackend.Account,
          GameBackend.BankItems,
          GameBackend.Characters,
          GameBackend.Guilds,
          AoTcpGateway.BrowserApi,
          AoSession.OnlineDirectory
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Arena.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.10"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_live_dashboard, "~> 0.8.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:rustler, "~> 0.36"},
      {:ao_protocol, in_umbrella: true},
      {:credo, "~> 1.7.12", only: [:dev, :test], runtime: false},
      {:plug_cowboy, "~> 2.5"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
