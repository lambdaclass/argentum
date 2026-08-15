defmodule ArenaWeb.StaticAssets do
  @moduledoc """
  Serves game resource directories and client dist assets at runtime.
  Plug.Static with `plug` macro evaluates paths at compile time, so we
  resolve paths at init/1 instead.
  """

  @behaviour Plug

  @impl true
  def init(_opts) do
    root = project_root()

    entries = [
      {"/graficos", Path.join(root, "resources/raw/Graficos")},
      {"/graficos_char", Path.join(root, "resources/graficos_char")},
      {"/indices", Path.join(root, "resources/indices")},
      {"/midi", Path.join(root, "resources/raw/midi")},
      {"/sounds", Path.join(root, "resources/raw/SoundsOgg")},
      {"/assets", Path.join(root, "client/dist/assets")},
      {"/client/assets", Path.join(root, "client/dist/assets")},
      {"/data/packs", Path.join(root, "client/dist/data/packs")},
      {"/client/data/packs", Path.join(root, "client/dist/data/packs")},
      {"/data", Path.join(root, "client/dist/data")},
      {"/client/data", Path.join(root, "client/dist/data")}
    ]

    plugs =
      entries
      |> Enum.filter(fn {_at, from} -> File.dir?(from) end)
      |> Enum.map(fn {at, from} ->
        opts =
          Plug.Static.init(
            at: at,
            from: from,
            gzip: false,
            headers: [{"access-control-allow-origin", "*"}]
          )

        {at, opts}
      end)

    plugs
  end

  @impl true
  def call(conn, plugs) do
    Enum.reduce_while(plugs, conn, fn {_at, opts}, acc ->
      result = Plug.Static.call(acc, opts)

      if result.halted do
        {:halt, result}
      else
        {:cont, result}
      end
    end)
  end

  # Anchored to this module's own compile-time location, NOT File.cwd!/0.
  #
  # The working directory is process-global in the BEAM, and mix changes it per
  # umbrella app while compiling. In dev, code reloading recompiles on request,
  # so a cwd-derived root could resolve to `server/apps/...` — asset roots then
  # failed File.dir?/1 and every sprite fell through to the SPA catch-all, and
  # the SPA controller itself 500'd on `server/apps/client/dist/index.html`.
  @source_project_root Path.expand("../../../../..", __DIR__)

  @doc """
  Absolute path to the repository root, for resolving `client/dist` and
  `resources/`. Shared with ArenaWeb.SpaController so both agree.
  """
  def project_root do
    System.get_env("ARGENTUM_PROJECT_ROOT") ||
      case System.get_env("RELEASE_ROOT") do
        nil -> @source_project_root
        release_root -> Path.expand("..", release_root)
      end
  end
end
