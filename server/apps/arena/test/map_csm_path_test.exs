defmodule Arena.Map.CsmPathTest do
  @moduledoc """
  Map files must load regardless of filename case.

  The VB6 resources come from Windows and the set is mixed: 324 of 843 files are
  `MapaNNN.csm`, the rest `mapaNNN.csm`. MapSupervisor discovers maps with a
  case-insensitive regex so all 843 start, but the loader used a hardcoded
  lowercase name. On a case-sensitive filesystem those 324 started, failed to
  read, and never became ready — boot timed out at "518 ready, 325 still loading
  or failed", and anyone entering one of those maps could not move and saw an
  unrendered map.
  """
  use ExUnit.Case, async: false

  alias Arena.Map.MapServer

  setup do
    dir = Path.join(System.tmp_dir!(), "ao_csm_path_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    previous = Application.get_env(:arena, :maps_dir)
    Application.put_env(:arena, :maps_dir, dir)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:arena, :maps_dir)
      else
        Application.put_env(:arena, :maps_dir, previous)
      end

      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "resolves a lowercase map file", %{dir: dir} do
    File.write!(Path.join(dir, "mapa5.csm"), "x")

    assert MapServer.csm_path(5) == Path.join(dir, "mapa5.csm")
  end

  test "resolves an uppercase map file — the 324 that silently failed", %{dir: dir} do
    File.write!(Path.join(dir, "Mapa6.csm"), "x")

    assert MapServer.csm_path(6) == Path.join(dir, "Mapa6.csm")
  end

  test "resolves an unexpected casing via directory scan", %{dir: dir} do
    File.write!(Path.join(dir, "MAPA7.CSM"), "x")

    assert MapServer.csm_path(7) == Path.join(dir, "MAPA7.CSM")
  end

  test "prefers the exact lowercase name when both casings exist", %{dir: dir} do
    File.write!(Path.join(dir, "mapa8.csm"), "x")
    File.write!(Path.join(dir, "Mapa8.csm"), "x")

    assert MapServer.csm_path(8) == Path.join(dir, "mapa8.csm")
  end

  test "falls back to the lowercase name when the map is genuinely absent", %{dir: dir} do
    # Map 843 has no file at all; the caller should get a path it can report
    # :enoent on rather than a crash.
    assert MapServer.csm_path(843) == Path.join(dir, "mapa843.csm")
  end

  test "does not match a different map id that shares a prefix", %{dir: dir} do
    File.write!(Path.join(dir, "Mapa60.csm"), "x")

    assert MapServer.csm_path(6) == Path.join(dir, "mapa6.csm")
  end
end
