defmodule Arena.World.PositionContractTest do
  @moduledoc """
  Executes the shared position contract on the Elixir side.

  The file this reads is the same one `ao_core::position` reads, and it is hand-authored so
  that neither language defines the answers by having been written first. If the server and
  the client ever disagree about where a tile is, this test fails on the exact case rather
  than a player noticing.
  """
  use ExUnit.Case, async: true

  alias Arena.World.Position

  @contract Path.join([
              __DIR__,
              "..",
              "..",
              "..",
              "..",
              "client-rs",
              "crates",
              "ao-core",
              "fixtures",
              "position_contract.txt"
            ])

  defp parse do
    @contract
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(fn line -> line |> String.split("#") |> hd() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce({%{}, []}, fn line, {spaces, cases} ->
      case String.split(line, ~r/\s+/) do
        ["space", id, shape] ->
          id = String.to_integer(id)
          {Map.put(spaces, id, %{id: id, geometry: geometry(shape), placements: %{}}), cases}

        ["place", space, map, at] ->
          space = String.to_integer(space)
          updated = put_in(spaces[space].placements[String.to_integer(map)], pair(at))
          {updated, cases}

        other ->
          {spaces, cases ++ [other]}
      end
    end)
  end

  defp geometry("plane"), do: :plane
  defp geometry("discrete"), do: :discrete

  defp geometry("cylinder-x:" <> period), do: {:cylinder, :x, String.to_integer(period)}
  defp geometry("cylinder-y:" <> period), do: {:cylinder, :y, String.to_integer(period)}

  defp geometry("torus:" <> size) do
    [width, height] = String.split(size, "x")
    {:torus, String.to_integer(width), String.to_integer(height)}
  end

  defp pair(text) do
    [x, y] = String.split(text, ",")
    {String.to_integer(String.trim(x)), String.to_integer(String.trim(y))}
  end

  defp local(map, at) do
    {x, y} = pair(at)
    {String.to_integer(map), x, y}
  end

  test "the contract file is present and worth checking" do
    {spaces, cases} = parse()
    assert map_size(spaces) >= 6, "expected several spaces, got #{map_size(spaces)}"
    assert length(cases) >= 50, "expected a real contract, got #{length(cases)} cases"
  end

  test "elixir satisfies every case in the position contract" do
    {spaces, cases} = parse()

    for kase <- cases do
      case kase do
        ["global", space, map, at, "->", "none"] ->
          space = spaces[String.to_integer(space)]
          assert Position.to_global(space, local(map, at)) == :none, "global #{map} #{at}"

        ["global", space, map, at, "->", expected] ->
          space = spaces[String.to_integer(space)]

          assert Position.to_global(space, local(map, at)) == {:ok, pair(expected)},
                 "global #{map} #{at}"

        ["local", space, at, "->", "none"] ->
          space = spaces[String.to_integer(space)]
          assert Position.to_local(space, pair(at)) == :none, "local #{at}"

        ["local", space, at, "->", map, tile] ->
          space = spaces[String.to_integer(space)]

          assert Position.to_local(space, pair(at)) == {:ok, local(map, tile)},
                 "local #{at}"

        ["step", space, at, "by", by, "->", "leaves"] ->
          space = spaces[String.to_integer(space)]
          assert Position.step(space, pair(at), pair(by)) == :leaves, "step #{at} by #{by}"

        ["step", space, at, "by", by, "->", "inside", expected] ->
          space = spaces[String.to_integer(space)]

          assert Position.step(space, pair(at), pair(by)) == {:inside, pair(expected)},
                 "step #{at} by #{by}"

        ["render", space, at, "near", near, "->", expected] ->
          space = spaces[String.to_integer(space)]

          assert Position.nearest_unwrapped(space, pair(at), pair(near)) == pair(expected),
                 "render #{at} near #{near}"

        ["legacy", space, at, "->", "unrepresentable"] ->
          space = spaces[String.to_integer(space)]
          assert Position.to_legacy(space, pair(at)) == :unrepresentable, "legacy #{at}"

        ["legacy", space, at, "->", map, tile] ->
          space = spaces[String.to_integer(space)]

          assert Position.to_legacy(space, pair(at)) == {:ok, local(map, tile)},
                 "legacy #{at}"

        other ->
          flunk("cannot read contract line: #{inspect(other)}")
      end
    end
  end

  test "local to global to local returns the original tile for every core tile" do
    # The invariant the contract rests on, checked exhaustively on this side too rather than
    # trusted because Rust checks it: a spec both languages read is only worth what each one
    # independently verifies.
    {spaces, _} = parse()

    for {_id, space} <- spaces, {map, _origin} <- space.placements do
      for y <- Position.core_y(), x <- Position.core_x() do
        original = {map, x, y}
        {:ok, global} = Position.to_global(space, original)

        # A space with two maps on one cell has no unique local tile, and says so.
        case Position.to_local(space, global) do
          {:ok, roundtripped} -> assert roundtripped == original
          :none -> assert map_size(space.placements) > 1
        end
      end
    end
  end

  test "the pinned walking routes produce the same coordinates here as in rust" do
    # `walking_paths.txt` was generated by the Rust compiler from the real corpus. The four
    # routes are re-derived here from the contract's placements for space 199, so a
    # divergence in either language's arithmetic fails rather than being discovered by a
    # player walking east and arriving somewhere else.
    {spaces, _} = parse()
    space = spaces[199]

    routes =
      Path.join([__DIR__, "..", "..", "..", "..", "client-rs", "crates", "ao-core", "fixtures", "walking_paths.txt"])
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    assert length(routes) == 4, "one route per cardinal direction"

    for route <- routes do
      fields = String.split(route, ~r/\s+/)
      [direction, "walking", "from", from_map, from_tile] = Enum.take(fields, 5)
      ["band", _band_map, _band_tile] = Enum.slice(fields, 5, 3)
      ["to", to_map, to_tile] = Enum.slice(fields, 8, 3)
      ["global", before_at, "->", after_at] = Enum.slice(fields, 11, 4)
      ["authority", auth_before, "->", auth_after] = Enum.slice(fields, 15, 4)

      assert {:ok, pair(before_at)} == Position.to_global(space, local(from_map, from_tile)),
             "#{route}"

      assert {:ok, pair(after_at)} == Position.to_global(space, local(to_map, to_tile)),
             "#{route}"

      assert Position.step(space, pair(before_at), cardinal(direction)) ==
               {:inside, pair(after_at)},
             "#{route}"

      # A seam crossing always hands the player to a different owner; one that did not would
      # not be exercising the handoff W-0096 has to make atomic.
      refute auth_before == auth_after
    end
  end

  defp cardinal("east"), do: {1, 0}
  defp cardinal("west"), do: {-1, 0}
  defp cardinal("north"), do: {0, -1}
  defp cardinal("south"), do: {0, 1}
end
