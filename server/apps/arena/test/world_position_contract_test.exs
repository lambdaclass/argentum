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

  defp placements_of(lines) do
    for ["region", space, region, map, origin] <- lines, reduce: %{} do
      acc ->
        space_id = String.to_integer(space)

        placement = %{
          region: String.to_integer(region),
          space: space_id,
          map: String.to_integer(map),
          origin: pair(origin)
        }

        Map.update(acc, space_id, [placement], &(&1 ++ [placement]))
    end
  end

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

        ["region", _space, _region, _map, _origin] ->
          {spaces, cases}

        other ->
          {spaces, cases ++ [other]}
      end
    end)
  end

  defp all_lines do
    @contract
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(fn line -> line |> String.split("#") |> hd() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.split(&1, ~r/\s+/))
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

          {rx, ry} = pair(expected)

          {nx, ny} = pair(near)

          assert Position.nearest_unwrapped(space, pair(at), {:render, nx, ny}) ==
                   {:render, rx, ry},
                 "render #{at} near #{near}"

        ["unrepresentable", space, at] ->
          space = spaces[String.to_integer(space)]
          position = pair(at)

          # Rust satisfies this case by construction -- no `WorldPosition` holds these
          # coordinates. Elixir's integers are unbounded, so it has to refuse them explicitly:
          # `to_local` accepted them and named a tile, and `region_at` named an owner, for a
          # position the other side cannot represent at all.
          #
          # Asserted out of range first, exactly as Rust does. Otherwise any coordinate no map
          # happens to cover would satisfy this case, and it would stop testing the guard.
          {x, y} = position

          assert x not in Position.coordinate_range() or y not in Position.coordinate_range(),
                 "#{at} is representable, so it is not this case"

          assert Position.to_local(space, position) == :none, "local #{at}"
          assert Position.step(space, position, {0, 0}) == :leaves, "step #{at}"
          assert Position.to_legacy(space, position) == :unrepresentable, "legacy #{at}"

        ["legacy", space, at, "->", "unrepresentable"] ->
          space = spaces[String.to_integer(space)]
          assert Position.to_legacy(space, pair(at)) == :unrepresentable, "legacy #{at}"

        ["legacy", space, at, "->", map, tile] ->
          space = spaces[String.to_integer(space)]

          assert Position.to_legacy(space, pair(at)) == {:ok, local(map, tile)},
                 "legacy #{at}"

        ["region-at", space, at, "->", "none"] ->
          space = spaces[String.to_integer(space)]
          placements = placements_of(all_lines())[space.id] || []
          assert Position.region_at(space, pair(at), placements) == :none, "region-at #{at}"

        ["region-at", space, at, "->", region] ->
          space = spaces[String.to_integer(space)]
          placements = placements_of(all_lines())[space.id] || []

          assert Position.region_at(space, pair(at), placements) ==
                   {:ok, String.to_integer(region)},
                 "region-at #{at}"

        ["compare", left_space, left_version, left_at, "with", right_space, right_version,
         right_at | verdict] ->
          left = {spaces[String.to_integer(left_space)], String.to_integer(left_version), pair(left_at)}
          right = {spaces[String.to_integer(right_space)], String.to_integer(right_version), pair(right_at)}

          want =
            case verdict do
              ["->", "different-space"] -> :different_space
              ["->", "different-version"] -> :different_version
              ["->", tiles] -> {:tiles, pair(tiles)}
            end

          assert Position.compare(left, right) == want,
                 "compare #{left_at} with #{right_at}"

        other ->
          flunk("cannot read contract line: #{inspect(other)}")
      end
    end
  end

  test "local to global to local returns the original tile, and every refusal is justified" do
    # The invariant the contract rests on, checked exhaustively on this side too rather than
    # trusted because Rust checks it.
    #
    # Codex review, 2026-08-23: this used to accept `:none` from `to_local` whenever a space
    # held more than one map, so a regression that lost every multi-map tile would have passed.
    # Now a refusal has to be explained: either the tile's coordinate is outside i32, or the
    # space is the one the contract declares ambiguous on purpose.
    {spaces, _} = parse()
    ambiguous = 900
    checked = 0

    checked =
      for {id, space} <- spaces, {map, {ox, oy}} <- space.placements, reduce: checked do
        acc ->
          for y <- Position.core_y(), x <- Position.core_x(), reduce: acc do
            inner ->
              original = {map, x, y}
              # What the coordinate would be before any range check.
              raw_x = ox + (x - Position.core_x().first)
              raw_y = oy + (y - Position.core_y().first)
              in_range = raw_x in Position.coordinate_range() and raw_y in Position.coordinate_range()

              case Position.to_global(space, original) do
                :none ->
                  refute in_range,
                         "space #{id} refused #{inspect(original)} whose coordinate fits i32"

                  inner + 1

                {:ok, global} ->
                  assert in_range

                  case Position.to_local(space, global) do
                    {:ok, roundtripped} ->
                      assert roundtripped == original
                      inner + 1

                    :none ->
                      assert id == ambiguous,
                             "space #{id} lost #{inspect(original)}; only the deliberately " <>
                               "ambiguous space #{ambiguous} may refuse"

                      inner + 1
                  end
              end
          end
      end

    assert checked > 50_000, "expected the whole core of every space, got #{checked} tiles"
  end

  test "a coordinate outside i32 is not a position here either" do
    # Codex review, 2026-08-23: Elixir returned unbounded coordinates where Rust returned
    # none, so an origin near the maximum produced a position the other side could not hold.
    space = %{id: 1, geometry: :plane, placements: %{1 => {2_147_483_647, 0}}}
    assert Position.to_global(space, {1, 20, 11}) == :none
    assert Position.coordinate_range() == -2_147_483_648..2_147_483_647

    at_the_edge = %{id: 1, geometry: :plane, placements: %{1 => {2_147_483_647 - 73, 0}}}
    assert Position.to_global(at_the_edge, {1, 87, 11}) == {:ok, {2_147_483_647, 0}}
  end

  test "a render position is tagged so it cannot be stored as a position" do
    torus = %{id: 37, geometry: {:torus, 148, 160}, placements: %{168 => {0, 0}}}

    assert {:render, 148, 39} = Position.nearest_unwrapped(torus, {0, 39}, {:render, 147, 39})
    refute Position.canonical?(torus, {148, 39}), "148 is a render value on a 148-wide torus"
    assert Position.canonical?(torus, {0, 39})
  end

  test "a drifted placement origin refuses to name an owner" do
    # Codex review, 2026-08-23: `region_at` used only the map id, so a placement naming
    # another space or carrying a stale origin still assigned authority successfully. The
    # dangerous shape is that every conversion succeeds and every answer is wrong by a fixed
    # offset.
    {spaces, _} = parse()
    space = spaces[199]
    good = placements_of(all_lines())[199]

    assert {:ok, 330} = Position.region_at(space, {221, 214}, good)

    drifted =
      Enum.map(good, fn placement ->
        if placement.map == 330 do
          {x, y} = placement.origin
          %{placement | origin: {x + 1, y}}
        else
          placement
        end
      end)

    assert {:error, {:origin_disagrees, 330, 330, {149, 160}, {148, 160}}} =
             Position.region_at(space, {221, 214}, drifted)

    stray = [%{region: 37, space: 37, map: 330, origin: {148, 160}}]
    assert {:error, {:wrong_space, 37, 37}} = Position.region_at(space, {221, 214}, stray)

    shared = good ++ [%{region: 331, space: 199, map: 330, origin: {148, 160}}]
    assert {:error, {:map_shared, 330}} = Position.region_at(space, {221, 214}, shared)
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
