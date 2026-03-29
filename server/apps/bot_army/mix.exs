defmodule BotArmy.MixProject do
  use Mix.Project

  def project do
    [
      app: :bot_army,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {BotArmy.Application, []}
    ]
  end

  defp deps do
    [
      {:arena, in_umbrella: true},
      {:game_backend, in_umbrella: true}
    ]
  end
end
