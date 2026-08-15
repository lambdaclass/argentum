defmodule ArenaWeb.SpaController do
  use ArenaWeb, :controller

  require Logger

  # Resolved through the shared root rather than File.cwd!/0 at request time.
  # cwd is process-global and mix changes it per umbrella app during dev code
  # reloads, so a request racing a reload resolved this to
  # `server/apps/client/dist/index.html` and raised File.Error -> 500.
  @index_path Path.join(ArenaWeb.StaticAssets.project_root(), "client/dist/index.html")

  # Extensions that are always a static asset, never a client-side route. The
  # catch-all is reached only when no static plug matched, so these are missing
  # files: answer 404 instead of handing back an HTML body under status 200,
  # which the client decodes as a corrupt image/sound rather than a miss.
  @asset_extensions ~w(.png .jpg .jpeg .gif .webp .svg .ico
                       .json .js .mjs .css .map
                       .ogg .mp3 .wav .webm .mid .midi
                       .woff .woff2 .ttf .csm .ind)

  def index(conn, params) do
    if asset_request?(params) do
      conn
      |> put_resp_header("content-type", "text/plain; charset=utf-8")
      |> send_resp(404, "Not found\n")
    else
      send_index(conn)
    end
  end

  defp asset_request?(%{"path" => segments}) when is_list(segments) and segments != [] do
    segments
    |> List.last()
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in @asset_extensions))
  end

  defp asset_request?(_params), do: false

  defp send_index(conn) do
    path = index_path()

    if File.regular?(path) do
      conn
      |> put_resp_header("content-type", "text/html; charset=utf-8")
      |> send_file(200, path)
    else
      # Serving an HTML body for a missing sprite or audio file would hand the
      # client a 200 it cannot decode. Say what actually happened instead.
      Logger.warning("SPA index not built at #{path} — run `make client.build`")

      conn
      |> put_resp_header("content-type", "text/plain; charset=utf-8")
      |> send_resp(503, "Client bundle not built. Run `make client.build`.\n")
    end
  end

  defp index_path do
    case System.get_env("ARGENTUM_PROJECT_ROOT") do
      nil -> @index_path
      _ -> Path.join(ArenaWeb.StaticAssets.project_root(), "client/dist/index.html")
    end
  end
end
