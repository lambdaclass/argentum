defmodule ArenaWeb.StaticAssetsCaseTest do
  @moduledoc """
  The four sheets whose extension is upper case.

  `resources/raw/Graficos` holds 2,327 files, of which `1000.PNG`, `1001.PNG`, `1002.PNG`
  and `1471.PNG` are spelled that way and the other 2,323 are `.png`. Every graphics index
  refers to all of them as `<n>.png`, so on a case-sensitive filesystem exactly those four
  answered 404 — and one is ground art at Ullathorpe's spawn point, where every new
  player starts. Both clients drew the hole and said nothing about it for as long as this
  server has existed.
  """

  use ExUnit.Case, async: true

  @moduletag :static_assets

  defp request(path) do
    conn = Plug.Test.conn(:get, path)
    ArenaWeb.StaticAssets.call(conn, ArenaWeb.StaticAssets.init([]))
  end

  defp graficos_dir do
    Path.join(ArenaWeb.StaticAssets.project_root(), "resources/raw/Graficos")
  end

  describe "legacy sheets with an upper-case extension" do
    @tag :tmp_dir
    test "the asset tree still has the four files this exists for" do
      # If the art is ever renamed, this test is the thing that says the shim can go —
      # rather than the shim quietly covering for a problem that no longer exists.
      odd =
        graficos_dir()
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".PNG"))
        |> Enum.sort()

      assert odd == ["1000.PNG", "1001.PNG", "1002.PNG", "1471.PNG"],
             "the upper-case sheets changed: #{inspect(odd)}"
    end

    test "a lower-case request reaches an upper-case file" do
      conn = request("/graficos/1001.png")

      assert conn.status == 200, "1001.png answered #{inspect(conn.status)}"
      assert conn.halted
      assert byte_size(conn.resp_body) > 0
    end

    test "the sheets that are already lower case are untouched" do
      conn = request("/graficos/3.png")

      assert conn.status == 200
      assert byte_size(conn.resp_body) > 0
    end

    test "a sheet that does not exist in either case is still a miss" do
      # The shim retries one thing — the extension — and only when the exact path is
      # absent. It must not turn a missing asset into a different asset.
      conn = request("/graficos/999999.png")

      refute conn.halted, "a nonexistent sheet was served as something"
    end

    test "the retry does not make static serving case-insensitive in general" do
      # Only the extension is swapped. A request whose *name* is the wrong case stays a
      # miss, because guessing at names is how one asset gets served for another.
      conn = request("/graficos/ABC.png")

      refute conn.halted
    end
  end
end
