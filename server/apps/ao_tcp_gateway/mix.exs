defmodule AoTcpGateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :ao_tcp_gateway,
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
      mod: {AoTcpGateway.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ao_protocol, in_umbrella: true},
      {:ao_session, in_umbrella: true},
      {:arena, in_umbrella: true},
      {:ranch, "~> 1.8"},
      {:cowboy, "~> 2.10"},
      {:plug, "~> 1.14"},
      {:plug_cowboy, "~> 2.7"}
    ]
  end
end
