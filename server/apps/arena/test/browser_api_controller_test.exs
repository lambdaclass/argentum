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

  test "GET /api/meta/world-pack returns the current world-pack manifest" do
    conn = get(build_conn(), "/api/meta/world-pack")
    payload = json_response(conn, 200)

    assert payload["version"] == 1
    assert payload["maps"] > 800
    assert payload["bytes"] > 1_000_000
    assert is_binary(payload["hash"])
    assert String.length(payload["hash"]) == 16
    assert String.starts_with?(payload["filename"], "maps.")
    assert String.ends_with?(payload["filename"], ".pack")
  end
end
