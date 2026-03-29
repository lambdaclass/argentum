defmodule Argentum.MixProject do
  use Mix.Project

  def project do
    [
      name: "argentum",
      apps_path: "apps",
      apps: [
        :ao_protocol,
        :ao_session,
        :ao_tcp_gateway,
        :arena,
        :bot_army,
        :game_backend
      ],
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      default_release: :all,
      docs: [
        groups_for_modules: [
          "AO Protocol": ~r"AoProtocol",
          "AO Session": ~r"AoSession",
          "AO TCP Gateway": ~r"AoTcpGateway",
          Arena: [~r"Arena", TileGrid],
          "Game Backend": ~r"GameBackend"
        ]
      ]
    ]
  end

  defp deps do
    [{:ex_doc, "~> 0.21", only: :dev, runtime: false}]
  end

  defp aliases() do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp releases() do
    [
      argentum: [
        applications: [
          ao_protocol: :permanent,
          ao_session: :permanent,
          ao_tcp_gateway: :permanent,
          arena: :permanent,
          game_backend: :permanent
        ]
      ]
    ]
  end
end
