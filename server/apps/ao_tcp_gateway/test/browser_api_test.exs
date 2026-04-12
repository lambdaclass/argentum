defmodule AoTcpGateway.BrowserApiTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts AoTcpGateway.WsRouter.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})
    :ok
  end

  test "register creates a browser session and exposes it via /api/auth/session" do
    name = unique_name("acct")

    register_conn =
      request(:post, "/api/auth/register", %{
        username: name,
        password: "secret-password"
      })

    assert register_conn.status == 201
    assert response_json(register_conn)["account"]["username"] == name

    session_conn = request(:get, "/api/auth/session", nil, register_conn)

    assert session_conn.status == 200
    assert response_json(session_conn) == %{
             "authenticated" => true,
             "account" => %{
               "id" => response_json(register_conn)["account"]["id"],
               "username" => name
             }
           }
  end

  test "character create and list stay scoped to the signed-in account" do
    account_conn = register_account(unique_name("acct"))
    char_name = unique_name("hero")

    create_conn =
      request(:post, "/api/characters", %{
        name: char_name,
        race: 1,
        gender: 1,
        class: 6,
        head: 1,
        home_city: 1
      }, account_conn)

    assert create_conn.status == 201
    assert response_json(create_conn)["character"]["name"] == char_name

    list_conn = request(:get, "/api/characters", nil, create_conn)

    assert list_conn.status == 200
    assert [%{"name" => ^char_name}] = response_json(list_conn)["characters"]
  end

  test "launching a browser character session returns login_existing_char credentials" do
    account_conn = register_account(unique_name("acct"))
    char_name = unique_name("hero")

    create_conn =
      request(:post, "/api/characters", %{
        name: char_name,
        race: 1,
        gender: 1,
        class: 6,
        head: 1,
        home_city: 1
      }, account_conn)

    character = response_json(create_conn)["character"]

    launch_conn =
      request(:post, "/api/characters/#{character["id"]}/session", %{}, create_conn)

    assert launch_conn.status == 200

    payload = response_json(launch_conn)
    assert payload["character"]["name"] == char_name
    assert payload["credentials"]["char_id"] == character["id"]
    assert is_binary(payload["credentials"]["token"])
    assert byte_size(payload["credentials"]["token"]) > 10
  end

  test "ranking returns created characters ordered into the browser payload" do
    account_conn = register_account(unique_name("acct"))
    char_name = unique_name("ranker")

    create_conn =
      request(:post, "/api/characters", %{
        name: char_name,
        race: 1,
        gender: 1,
        class: 6,
        head: 1,
        home_city: 1
      }, account_conn)

    assert create_conn.status == 201

    ranking_conn = request(:get, "/api/ranking/general", nil)

    assert ranking_conn.status == 200
    assert Enum.any?(response_json(ranking_conn)["entries"], fn entry ->
             entry["character"]["name"] == char_name
           end)
  end

  test "character list requires an authenticated browser session" do
    conn = request(:get, "/api/characters", nil)

    assert conn.status == 401
    assert response_json(conn)["message"] == "Account session required."
  end

  defp register_account(name) do
    request(:post, "/api/auth/register", %{username: name, password: "secret-password"})
  end

  defp request(method, path, body, previous_conn \\ nil) do
    conn =
      method
      |> conn(path, body && Jason.encode!(body))
      |> Map.put(:secret_key_base, "QK4nHna6CWP5+KH2khYXzdIAM2GmQ1B7xwDP6fdjhQro1659xfFvC+69Joj/dKyw")
      |> put_req_header("content-type", "application/json")
      |> maybe_recycle(previous_conn)

    AoTcpGateway.WsRouter.call(conn, @opts)
  end

  defp maybe_recycle(conn, nil), do: conn
  defp maybe_recycle(conn, previous_conn), do: recycle_cookies(conn, previous_conn)

  defp response_json(conn), do: Jason.decode!(conn.resp_body)

  defp unique_name(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
