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

  @static_dir Application.compile_env(:ao_tcp_gateway, :static_dir,
               Path.expand("../../priv/static", __DIR__))

  # Repo root is 5 levels up from __DIR__ (server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/)
  @repo_root Path.expand("../../../../..", __DIR__)

  @webclient_dir Application.compile_env(:ao_tcp_gateway, :webclient_dir,
                   Path.join(@repo_root, "old_clients/webclient/ao-web-client/client"))

  @graphics_dir Application.compile_env(:ao_tcp_gateway, :graphics_dir,
                  Path.join(@repo_root, "resources/raw/Graficos"))

  @char_graphics_dir Application.compile_env(:ao_tcp_gateway, :char_graphics_dir,
                       Path.join(@repo_root, "resources/graficos_char"))

  @indices_dir Application.compile_env(:ao_tcp_gateway, :indices_dir,
                Path.join(@repo_root, "resources/indices"))

  @midi_dir Application.compile_env(:ao_tcp_gateway, :midi_dir,
             Path.join(@repo_root, "resources/raw/midi"))

  @sounds_dir Application.compile_env(:ao_tcp_gateway, :sounds_dir,
               Path.join(@repo_root, "resources/raw/SoundsOgg"))

  @serious_client_dir Application.compile_env(:ao_tcp_gateway, :serious_client_dir,
                        Path.join(@repo_root, "client/dist"))

  @serious_client_assets_dir Path.join(@serious_client_dir, "assets")
  @serious_client_data_dir Path.join(@serious_client_dir, "data")
  @serious_client_pack_dir Path.join(@serious_client_data_dir, "packs")

  # Serve legacy ao-web-client assets (css, js, fonts, imagenes, etc.)
  plug Plug.Static,
    at: "/",
    from: @webclient_dir,
    only: ~w(css js fonts imagenes graficos indices audio)

  plug Plug.Static,
    at: "/graficos",
    from: @graphics_dir

  plug Plug.Static,
    at: "/graficos_char",
    from: @char_graphics_dir

  plug Plug.Static,
    at: "/indices",
    from: @indices_dir

  plug Plug.Static,
    at: "/midi",
    from: @midi_dir

  plug Plug.Static,
    at: "/sounds",
    from: @sounds_dir

  plug Plug.Static,
    at: "/client/assets",
    from: @serious_client_assets_dir,
    headers: [{"cache-control", "public, max-age=31536000, immutable"}]

  plug Plug.Static,
    at: "/client/data/packs",
    from: @serious_client_pack_dir,
    gzip: true,
    headers: [{"cache-control", "public, max-age=31536000, immutable"}]

  plug Plug.Static,
    at: "/client/data",
    from: @serious_client_data_dir,
    only: ~w(map-pack.json),
    headers: [{"cache-control", "public, max-age=60, must-revalidate"}]

  plug Plug.Static,
    at: "/data/packs",
    from: @serious_client_pack_dir,
    gzip: true,
    headers: [{"cache-control", "public, max-age=31536000, immutable"}]

  plug Plug.Static,
    at: "/data",
    from: @serious_client_data_dir,
    only: ~w(map-pack.json),
    headers: [{"cache-control", "public, max-age=60, must-revalidate"}]

  # Serve gateway static assets (test client, fallback files)
  plug Plug.Static,
    at: "/",
    from: @static_dir,
    only: ~w()

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
    path = Path.join(@serious_client_dir, "index.html")

    case File.read(path) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, body)

      {:error, _} ->
        send_resp(conn, 503, "Serious client not built. Run `make client.build`.")
    end
  end
end
