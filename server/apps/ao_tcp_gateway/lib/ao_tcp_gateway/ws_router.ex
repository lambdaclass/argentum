defmodule AoTcpGateway.WsRouter do
  @moduledoc """
  Minimal Plug router that serves:
  - /ao — WebSocket upgrade to AoTcpGateway.WsHandler
  - /test_client.html — minimal test client
  - /client/ — serious Vite web client
  - / — ao-web-client (full client with sprites and zoom)
  - /api/map/:id — map tile data as JSON
  - /graficos/* — sprite sheet PNGs
  - /indices/* — sprite index JSONs
  """

  use Plug.Router

  plug :serve_runtime_static
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  get "/" do
    path = Application.app_dir(:ao_tcp_gateway, "priv/static/test_client.html")
    serve_file(conn, path, "text/html")
  end

  # Override webclient config.json to point to our WS endpoint
  get "/config.json" do
    ws_port = Application.get_env(:ao_tcp_gateway, :ws_port, 7667)
    host = conn.host || "localhost"
    config = Jason.encode!(%{version: "0.13.0", ip: host, port: "#{ws_port}", ws_path: "/ao"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, config)
  end

  get "/test_client.html" do
    path = Application.app_dir(:ao_tcp_gateway, "priv/static/test_client.html")
    serve_file(conn, path, "text/html")
  end

  get "/client" do
    serve_serious_client(conn)
  end

  get "/client/index.html" do
    serve_serious_client(conn)
  end

  get "/api/map/:id" do
    try do
      map_id = String.to_integer(id)
      data = Arena.Map.MapServer.get_map_data(map_id)
      json = Jason.encode!(data)

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("access-control-allow-origin", "*")
      |> send_resp(200, json)
    rescue
      _ -> send_resp(conn, 404, "Map not found")
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp serve_file(conn, path, content_type) do
    case File.read(path) do
      {:ok, body} ->
        conn
        |> put_resp_content_type(content_type)
        |> send_resp(200, body)

      {:error, _} ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp serve_serious_client(conn) do
    path = Path.join(serious_client_dir(), "index.html")

    case File.read(path) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, body)

      {:error, _} ->
        send_resp(conn, 503, "Serious client not built. Run `make client.build`.")
    end
  end

  defp serve_runtime_static(conn, _opts) do
    Enum.reduce_while(runtime_static_opts(), conn, fn opts, acc ->
      served = Plug.Static.call(acc, Plug.Static.init(opts))

      if served.halted do
        {:halt, served}
      else
        {:cont, served}
      end
    end)
  end

  defp runtime_static_opts do
    [
      [at: "/", from: webclient_dir(), only: ~w(css js fonts imagenes graficos indices audio)],
      [at: "/graficos", from: graphics_dir()],
      [at: "/graficos_char", from: char_graphics_dir()],
      [at: "/indices", from: indices_dir()],
      [at: "/midi", from: midi_dir()],
      [at: "/sounds", from: sounds_dir()],
      [
        at: "/client/assets",
        from: serious_client_assets_dir(),
        headers: [{"cache-control", "public, max-age=31536000, immutable"}]
      ],
      [
        at: "/client/data/packs",
        from: serious_client_pack_dir(),
        gzip: true,
        headers: [{"cache-control", "public, max-age=31536000, immutable"}]
      ],
      [
        at: "/client/data",
        from: serious_client_data_dir(),
        only: ~w(map-pack.json),
        headers: [{"cache-control", "public, max-age=60, must-revalidate"}]
      ],
      [
        at: "/data/packs",
        from: serious_client_pack_dir(),
        gzip: true,
        headers: [{"cache-control", "public, max-age=31536000, immutable"}]
      ],
      [
        at: "/data",
        from: serious_client_data_dir(),
        only: ~w(map-pack.json),
        headers: [{"cache-control", "public, max-age=60, must-revalidate"}]
      ]
    ]
    |> Enum.filter(fn opts -> File.dir?(Keyword.fetch!(opts, :from)) end)
  end

  defp webclient_dir do
    Application.get_env(:ao_tcp_gateway, :webclient_dir, Path.join(project_root(), "old/clients/webclient/ao-web-client/client"))
  end

  defp graphics_dir do
    Application.get_env(:ao_tcp_gateway, :graphics_dir, Path.join(project_root(), "resources/raw/Graficos"))
  end

  defp char_graphics_dir do
    Application.get_env(:ao_tcp_gateway, :char_graphics_dir, Path.join(project_root(), "resources/graficos_char"))
  end

  defp indices_dir do
    Application.get_env(:ao_tcp_gateway, :indices_dir, Path.join(project_root(), "resources/indices"))
  end

  defp midi_dir do
    Application.get_env(:ao_tcp_gateway, :midi_dir, Path.join(project_root(), "resources/raw/midi"))
  end

  defp sounds_dir do
    Application.get_env(:ao_tcp_gateway, :sounds_dir, Path.join(project_root(), "resources/raw/SoundsOgg"))
  end

  defp serious_client_dir do
    Application.get_env(:ao_tcp_gateway, :serious_client_dir, Path.join(project_root(), "client/dist"))
  end

  defp serious_client_assets_dir, do: Path.join(serious_client_dir(), "assets")
  defp serious_client_data_dir, do: Path.join(serious_client_dir(), "data")
  defp serious_client_pack_dir, do: Path.join(serious_client_data_dir(), "packs")

  defp project_root do
    System.get_env("ARGENTUM_PROJECT_ROOT") ||
      case System.get_env("RELEASE_ROOT") do
        nil -> Path.expand("..", File.cwd!())
        release_root -> Path.expand("..", release_root)
      end
  end
end
