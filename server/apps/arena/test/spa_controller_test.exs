defmodule ArenaWeb.SpaControllerTest do
  @moduledoc """
  The SPA catch-all must not answer asset requests with an HTML body.

  A missing sprite used to return index.html under status 200, so the client
  received markup where it expected a PNG and reported a decode failure rather
  than a miss. Client-side routes still need the index, so the split is by file
  extension: anything that looks like a static asset 404s, everything else gets
  the SPA shell.
  """
  use ExUnit.Case, async: true
  use Phoenix.ConnTest

  @endpoint ArenaWeb.Endpoint

  describe "asset-shaped paths" do
    test "a missing sprite 404s instead of returning HTML under 200" do
      conn = get(build_conn(), "/graficos/999999.png")

      assert conn.status == 404
      refute conn |> get_resp_header("content-type") |> Enum.any?(&(&1 =~ "text/html"))
      refute response(conn, 404) =~ "<html"
    end

    test "missing audio 404s rather than serving the SPA shell" do
      conn = get(build_conn(), "/audio/musica/999999.ogg")

      assert conn.status == 404
    end

    test "extension matching is case-insensitive" do
      conn = get(build_conn(), "/graficos/999999.PNG")

      assert conn.status == 404
    end

    test "covers the other asset kinds the client fetches" do
      for path <- [
            "/indices/nope.json",
            "/assets/nope.js",
            "/assets/nope.css",
            "/midi/999999.mid",
            "/sounds/999999.wav"
          ] do
        conn = get(build_conn(), path)
        assert conn.status == 404, "expected 404 for #{path}, got #{conn.status}"
      end
    end
  end

  describe "client-side routes" do
    test "the root serves the SPA shell" do
      conn = get(build_conn(), "/")

      assert conn.status == 200
      assert response_content_type(conn, :html)
    end

    test "an extensionless route serves the SPA shell so deep links work" do
      conn = get(build_conn(), "/play")

      assert conn.status == 200
      assert response_content_type(conn, :html)
    end

    test "a nested extensionless route still serves the shell" do
      conn = get(build_conn(), "/account/characters")

      assert conn.status == 200
      assert response_content_type(conn, :html)
    end
  end
end
