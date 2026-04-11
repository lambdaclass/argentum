defmodule ArenaWeb.SpaController do
  use ArenaWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_file(200, Path.expand("../client/dist/index.html", File.cwd!()))
  end
end
