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
    conn = normalise_legacy_extension(conn)

    Enum.reduce_while(plugs, conn, fn {_at, opts}, acc ->
      result = Plug.Static.call(acc, opts)

      if result.halted do
        {:halt, result}
      else
        {:cont, result}
      end
    end)
  end

  # The upstream art has four files with an upper-case extension.
  #
  # `resources/raw/Graficos` holds 2,327 sheets, of which 1000.PNG, 1001.PNG, 1002.PNG and
  # 1471.PNG are spelled that way and the other 2,323 are not. The graphics index refers to
  # all of them as `<n>.png`, so on a case-sensitive filesystem exactly those four 404 —
  # and one of them is ground art at Ullathorpe's spawn point, which is where every new
  # player starts. The client drew the hole and said nothing; the Rust client's first-scene
  # barrier is what finally reported it.
  #
  # Fixed here rather than by renaming the files: the asset tree is upstream data, and the
  # mapping from a request path to a file on disk is this module's job. Only the extension
  # is retried, and only when the exact path does not exist, so nothing else about static
  # serving becomes case-insensitive.
  defp normalise_legacy_extension(%Plug.Conn{path_info: path_info} = conn) do
    with [_ | _] <- path_info,
         {:ok, {directory, name}} <- legacy_asset(path_info),
         false <- File.exists?(Path.join(directory, name)),
         upper = swap_extension_case(name),
         true <- upper != name and File.exists?(Path.join(directory, upper)) do
      %{conn | path_info: List.replace_at(path_info, length(path_info) - 1, upper)}
    else
      _ -> conn
    end
  end

  defp legacy_asset(path_info) do
    root = project_root()

    case path_info do
      ["graficos" | rest] when rest != [] ->
        {:ok, {Path.join([root, "resources/raw/Graficos" | Enum.drop(rest, -1)]), List.last(rest)}}

      ["graficos_char" | rest] when rest != [] ->
        {:ok, {Path.join([root, "resources/graficos_char" | Enum.drop(rest, -1)]), List.last(rest)}}

      _ ->
        :error
    end
  end

  defp swap_extension_case(name) do
    case Path.extname(name) do
      "" -> name
      extension -> Path.rootname(name) <> String.upcase(extension)
    end
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
