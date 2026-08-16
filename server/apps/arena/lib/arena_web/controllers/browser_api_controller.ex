defmodule ArenaWeb.BrowserApiController do
  use ArenaWeb, :controller

  def session(conn, _params) do
    AoTcpGateway.BrowserApi.session(conn)
  end

  def register(conn, params) do
    AoTcpGateway.BrowserApi.register(conn, params)
  end

  def login(conn, params) do
    AoTcpGateway.BrowserApi.login(conn, params)
  end

  def logout(conn, _params) do
    AoTcpGateway.BrowserApi.logout(conn)
  end

  def character_options(conn, _params) do
    AoTcpGateway.BrowserApi.character_options(conn)
  end

  def online(conn, _params) do
    AoTcpGateway.BrowserApi.online(conn)
  end

  def world_pack(conn, _params) do
    AoTcpGateway.BrowserApi.world_pack(conn)
  end

  def list_characters(conn, _params) do
    AoTcpGateway.BrowserApi.list_characters(conn)
  end

  def create_character(conn, params) do
    AoTcpGateway.BrowserApi.create_character(conn, params)
  end

  def create_character_session(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {char_id, ""} -> AoTcpGateway.BrowserApi.create_character_session(conn, char_id)
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def ranking(conn, params) do
    AoTcpGateway.BrowserApi.ranking(conn, params)
  end
end
