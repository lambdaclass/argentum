defmodule GameBackend.MixProject do
  use Mix.Project

  def project do
    [
      app: :game_backend,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {GameBackend.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
      # {:sibling_app_in_umbrella, in_umbrella: true}
      {:ecto, "~> 3.11"},
      {:ecto_sql, "~> 3.6"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      {:bcrypt_elixir, "~> 3.0"},
      # KNOWN CIRCULAR DEP: game_backend depends on arena only for the
      # Arena.Entity.PlayerEntity struct used in Characters.to_entity/1 and
      # Characters.from_entity/1 (DB <-> in-memory entity conversion).
      # Arena also depends on game_backend (the persistence layer).
      # TODO: extract PlayerEntity to a shared app (e.g. ao_core) to break
      # this cycle cleanly. See apps/arena/test/dependency_boundary_test.exs
      # for guard-rail tests that prevent this coupling from spreading.
      {:arena, in_umbrella: true}
    ]
  end
end
