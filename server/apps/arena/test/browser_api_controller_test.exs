defmodule ArenaWeb.BrowserApiControllerTest do
  use ExUnit.Case, async: true
  use Phoenix.ConnTest

  @endpoint ArenaWeb.Endpoint

  test "GET /api/auth/session returns unauthenticated JSON when no browser session exists" do
    conn = get(build_conn(), "/api/auth/session")

    assert json_response(conn, 200) == %{
             "authenticated" => false,
             "account" => nil
           }
  end
end
