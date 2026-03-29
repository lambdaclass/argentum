defmodule AoSession.MixProject do
  use Mix.Project

  def project do
    [
      app: :ao_session,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {AoSession.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:game_backend, in_umbrella: true}
    ]
  end
end
