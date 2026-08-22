# Emit what Elixir believes each tile *means*, so Rust can be held to it.
#
# Run with: mix run --no-start apps/arena/test/generate_tile_semantics_fixture.exs
#
# `--no-start` because this reads a file and needs no applications; booting the umbrella
# would fight a running dev server for its TCP port.
#
# The client and the server both read the same map pack, and a byte in the blocked layer
# only has meaning because `Arena.Map.CsmParser` gave it one and `Arena.Map.Movement` acts
# on it. Nothing in the pack format says so. That gap already produced one week-long error:
# the layer holds three states, the Rust side read it as two, and every count downstream was
# stable and wrong. A drift gate could not see it, because the numbers never drifted.
#
# So this writes down the semantics rather than the bytes: for a spread of positions, what
# the *server's own rules* say a character may do there. Rust asserts its `mappack::Tile` and
# seam classification agree, and a future change to either side has to change this file --
# which is a review, not a silent divergence.
#
# The rules encoded here, quoted from the code that owns them:
#
#   Arena.Map.CsmParser.build_tile_grid/1 -- writes the values
#   Arena.Map.TileSemantics               -- says what they mean; called by both
#                                            Arena.Map.Movement and this generator
#
# Note the asymmetry, which is the server's behaviour and not a typo here: water requires a
# boat, and *nothing* stops a boat on dry land.

pack_path =
  System.get_env("AO_PACK") ||
    Path.wildcard(Path.join([__DIR__, "..", "..", "..", "..", "client", "dist", "data", "packs", "maps.*.pack"]))
    |> List.first()

unless pack_path && File.exists?(pack_path) do
  IO.puts(:stderr, "no map pack found; set AO_PACK to one")
  System.halt(2)
end

<<"AOMP", 1::little-16, count::little-16, rest::binary>> = File.read!(pack_path)

# Decode just enough of each map to reach its tile grid: the pack is the shared artefact, so
# reading it here rather than re-parsing the CSMs keeps both languages on the same bytes and
# isolates the question to what those bytes *mean*.
read_map = fn data ->
  <<map_id::little-16, name_len::little-16, rest::binary>> = data
  <<_name::binary-size(name_len), w::little-16, h::little-16, _music::binary-size(8), rest::binary>> = rest
  tile_count = w * h
  <<tiles::binary-size(tile_count), rest::binary>> = rest
  {map_id, w, h, tiles, rest}
end

skip_sections = fn data ->
  # four graphic layers, then npcs, objects, exits
  data =
    Enum.reduce(1..4, data, fn _, acc ->
      <<n::little-16, acc::binary>> = acc
      <<_::binary-size(n * 6), acc::binary>> = acc
      acc
    end)

  <<npcs::little-16, data::binary>> = data
  <<_::binary-size(npcs * 4), data::binary>> = data
  <<objects::little-16, data::binary>> = data
  <<_::binary-size(objects * 6), data::binary>> = data
  # 6 bytes each: x, y, dest_map u16, dest_x, dest_y. Getting this wrong overshoots by a
  # few hundred bytes per map and lands mid-layer in the next one.
  <<exits::little-16, data::binary>> = data
  <<_::binary-size(exits * 6), data::binary>> = data
  data
end

{maps, _} =
  Enum.map_reduce(1..count, rest, fn _, acc ->
    {map_id, w, h, tiles, acc} = read_map.(acc)
    {{map_id, w, h, tiles}, skip_sections.(acc)}
  end)

by_id = Map.new(maps, fn {id, w, h, tiles} -> {id, {w, h, tiles}} end)

# What the server's rules say about one tile value -- by asking the server, not by writing
# the rule down again here. A handwritten table can agree with a stale copy of a rule; this
# calls the same function `Arena.Map.Movement` calls, so the fixture cannot describe
# behaviour the server does not have.
semantics = fn value ->
  {
    Atom.to_string(Arena.Map.TileSemantics.class(value)),
    Arena.Map.TileSemantics.enterable?(value, false),
    Arena.Map.TileSemantics.enterable?(value, true)
  }
end

# Sample positions that matter rather than a uniform grid: the core edges and transition
# bands are where a seam lives, and a fixture that only covered map interiors would have
# agreed with the buggy reading too.
sample_positions = [
  {14, 11}, {87, 11}, {14, 90}, {87, 90},
  {13, 50}, {88, 50}, {50, 10}, {50, 91},
  {14, 50}, {87, 50}, {50, 11}, {50, 90},
  {50, 50}
]

# Maps chosen for what they contain, not by id: dry rock, a city, coast, open sea, and the
# two ends of the seams the reports name.
sample_maps = [1, 10, 17, 37, 41, 103, 199, 274, 495, 570, 573]

rows =
  for map_id <- sample_maps,
      {w, h, tiles} = Map.get(by_id, map_id, {0, 0, <<>>}),
      w > 0,
      {x, y} <- sample_positions do
    value = :binary.at(tiles, (y - 1) * w + (x - 1))
    {name, on_foot, navigating} = semantics.(value)
    "#{map_id} #{x} #{y} #{value} #{name} #{on_foot} #{navigating}"
  end

header = """
# Tile semantics, generated from the Elixir server's own rules.
# Regenerate: mix run apps/arena/test/generate_tile_semantics_fixture.exs
#
# Source of truth:
#   Arena.Map.CsmParser.build_tile_grid/1 -- writes the values
#   Arena.Map.TileSemantics.class/1       -- 0 walkable, 1 solid, 2 navigable water
#   Arena.Map.TileSemantics.enterable?/2  -- water needs a boat; nothing blocks a boat on
#                                            land. Called by Arena.Map.Movement itself.
#
# columns: map_id x y tile_value class enterable_on_foot enterable_while_navigating
"""

out_path = Path.join([__DIR__, "..", "..", "..", "..", "client-rs", "crates", "ao-core", "fixtures", "tile_semantics.txt"])
File.mkdir_p!(Path.dirname(out_path))
File.write!(out_path, header <> Enum.join(rows, "\n") <> "\n")

IO.puts("wrote #{length(rows)} rows to #{Path.relative_to_cwd(out_path)}")

by_class =
  rows
  |> Enum.map(fn row -> row |> String.split(" ") |> Enum.at(4) end)
  |> Enum.frequencies()

IO.inspect(by_class, label: "classes covered")
