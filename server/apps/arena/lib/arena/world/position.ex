defmodule Arena.World.Position do
  @moduledoc """
  Global world positions, in a world that is not one plane.

  The Rust side of this contract is `ao_core::position`, and neither implementation defines
  the answers: both read `client-rs/crates/ao-core/fixtures/position_contract.txt`, which is
  hand-authored precisely so that going first does not make one of them right. A disagreement
  becomes a failing case in review rather than the server and the client placing a player in
  different rooms.

  `W-0097` compiled the corpus into 226 coordinate spaces: most planes, one 148x160 torus,
  199 reachable only by transition. So a position is a pair of numbers *in a space*, and the
  space decides what arithmetic means — a step east can wrap, or leave, depending on shape.

  Nothing here persists or transmits anything yet. This is the coordinate contract alone;
  storage and protocol follow once it is proven on both sides.
  """

  @core_x 14..87
  @core_y 11..90
  @pitch_x 74
  @pitch_y 80

  # A global coordinate is an i32 on the wire and in Rust, so a position outside that range is
  # not a position. Elixir integers are unbounded, so without this the two sides disagreed: an
  # origin near the maximum returned `{2_147_483_653, 0}` here and `None` there.
  @i32_min -2_147_483_648
  @i32_max 2_147_483_647

  # A render coordinate is an i64 in Rust: it accumulates circuits and so is wider than the
  # canonical i32, but it is not unbounded. Elixir's integers are, which is how the two sides
  # came to disagree about a camera at the end of the type.
  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807

  @typedoc "A coordinate space's shape. Periods are in tiles; 0 means the axis does not wrap."
  @type geometry ::
          :plane
          | :discrete
          | {:cylinder, :x | :y, pos_integer()}
          | {:torus, pos_integer(), pos_integer()}

  @typedoc "A space: its shape and where each map's core sits in its coordinates."
  @type space :: %{id: non_neg_integer(), geometry: geometry(), placements: %{integer() => {integer(), integer()}}}

  @typedoc "A tile inside one map, as legacy content and the collision grid address it."
  @type local :: {map_id :: integer(), x :: integer(), y :: integer()}

  @doc "The simulated core bounds and pitch, so callers do not restate them."
  def core_x, do: @core_x
  def core_y, do: @core_y
  def pitch, do: {@pitch_x, @pitch_y}

  @doc """
  Whether a tile is inside the simulated core.

  A transition band tile is not a place: a character occupies one for the instant between
  stepping onto it and the exit firing, so it has no global position and must never be
  persisted as one.
  """
  @spec in_core?(local()) :: boolean()
  def in_core?({_map, x, y}), do: x in @core_x and y in @core_y

  @doc "The wrap period of each axis, `0` where the space does not wrap."
  @spec periods(geometry()) :: {integer(), integer()}
  def periods(:plane), do: {0, 0}
  def periods(:discrete), do: {0, 0}
  def periods({:cylinder, :x, period}), do: {period, 0}
  def periods({:cylinder, :y, period}), do: {0, period}
  def periods({:torus, width, height}), do: {width, height}

  @doc "Bring a coordinate pair into a geometry's canonical range."
  @spec reduce(geometry(), {integer(), integer()}) :: {integer(), integer()}
  def reduce(geometry, {x, y}) do
    {px, py} = periods(geometry)
    {axis(x, px), axis(y, py)}
  end

  defp axis(value, 0), do: value
  defp axis(value, period), do: Integer.mod(value, period)

  @doc """
  The global position of a local tile, or `:none`.

  `:none` where the tile is outside the core or the map is not in this space — a band tile
  deliberately has no global coordinates.
  """
  @spec to_global(space(), local()) :: {:ok, {integer(), integer()}} | :none
  def to_global(space, {map, x, y} = local) do
    with true <- in_core?(local),
         {ox, oy} when is_integer(ox) <- Map.get(space.placements, map, :missing),
         {gx, gy} <- reduce(space.geometry, {ox + (x - @core_x.first), oy + (y - @core_y.first)}),
         true <- gx in @i32_min..@i32_max and gy in @i32_min..@i32_max do
      {:ok, {gx, gy}}
    else
      _ -> :none
    end
  end

  @doc "The inclusive range a global coordinate must lie in."
  def coordinate_range, do: @i32_min..@i32_max

  @doc "The inclusive range a render coordinate may take: i64, wider than a stored position."
  def render_range, do: @i64_min..@i64_max

  @doc """
  The local tile a global position falls on, or `:none`.

  `:none` also when *more than one* map covers it. `W-0097` measured 26 such cells, and a
  position there means two places; answering with either would be a guess presented as a
  location.
  """
  @spec to_local(space(), {integer(), integer()}) :: {:ok, local()} | :none
  def to_local(_space, {x, y}) when x not in @i32_min..@i32_max or y not in @i32_min..@i32_max do
    # A global coordinate is an i32 on the wire and in Rust, so a value outside that range is
    # not a position and has no tile. Only `to_global` checked this, so `to_local`, `step` and
    # `region_at` all happily assigned a tile -- and an owner -- to coordinates the other side
    # could not even hold.
    :none
  end

  def to_local(space, position) do
    {gx, gy} = reduce(space.geometry, position)

    covering =
      Enum.flat_map(space.placements, fn {map, {ox, oy}} ->
        {rox, roy} = reduce(space.geometry, {ox, oy})
        dx = gx - rox
        dy = gy - roy

        if dx >= 0 and dy >= 0 and dx < @pitch_x and dy < @pitch_y do
          [{map, @core_x.first + dx, @core_y.first + dy}]
        else
          []
        end
      end)

    case covering do
      [only] -> {:ok, only}
      _ -> :none
    end
  end

  @doc """
  Move one tile. The only way to change a global position, because the answer depends on the
  shape: a wrapping axis comes back around, a planar edge leaves the space.
  """
  @spec step(space(), {integer(), integer()}, {integer(), integer()}) ::
          {:inside, {integer(), integer()}} | :leaves
  def step(space, {x, y}, {dx, dy}) do
    landed = reduce(space.geometry, {x + dx, y + dy})

    case to_local(space, landed) do
      {:ok, _} -> {:inside, landed}
      :none -> :leaves
    end
  end

  @doc """
  A render position for a wrapping space, chosen nearest to where the camera already is.

  The canonical position stays reduced; only rendering unwraps. Crossing a torus seam moves a
  character one tile in the world and a whole period in stored coordinates, and drawing the
  stored value would snap the camera across the map. The two must never be confused: one is
  where the character is, the other is where to draw them this frame.
  """
  @spec nearest_unwrapped(space(), {integer(), integer()}, {:render, integer(), integer()}) ::
          {:render, integer(), integer()} | :none
  def nearest_unwrapped(_space, _position, {:render, near_x, near_y})
      when near_x not in @i64_min..@i64_max or near_y not in @i64_min..@i64_max do
    # A camera outside i64 is not a camera. Rust's `RenderPosition` cannot hold one, so there is
    # no question for it to answer; here there is, and answering it would produce a render
    # position the client could not receive.
    :none
  end

  def nearest_unwrapped(space, {x, y}, {:render, near_x, near_y}) do
    {px, py} = periods(space.geometry)
    # Tagged `:render` so it cannot be passed where a canonical `{x, y}` is expected -- and the
    # camera is tagged too, because a canonical position passed as the camera would have made
    # the two kinds interchangeable at the one call site that must not confuse them. On a
    # 148-wide torus, canonical 0 and render-only 148 are both plausible-looking pairs.
    # Both axes or neither: half a render position is not one.
    with {:ok, rx} <- nearest_on_axis(x, near_x, px),
         {:ok, ry} <- nearest_on_axis(y, near_y, py) do
      {:render, rx, ry}
    end
  end

  @doc """
  Whether a position is in this space's canonical range.

  A wrapping space reduces its coordinates, so `x = 148` on a 148-wide torus is a render
  position that has been mistaken for a stored one.
  """
  @spec canonical?(space(), {integer(), integer()}) :: boolean()
  def canonical?(space, {x, y}) do
    reduce(space.geometry, {x, y}) == {x, y} and x in @i32_min..@i32_max and
      y in @i32_min..@i32_max
  end

  defp nearest_on_axis(value, _near, 0), do: {:ok, value}

  defp nearest_on_axis(value, near, period) do
    # The congruent value nearest the camera, whatever the distance. Checking only one period
    # either side assumed the camera was never more than a single wrap away, which is false the
    # moment anything follows a character around a torus twice: for period 148, canonical 0 near
    # 295 answered 148 when 296 is one tile away.
    periods = Integer.floor_div(near - value + div(period, 2), period)
    candidate = value + periods * period

    # And the nearest congruent value to a camera at the end of i64 is *past* the end of it: for
    # period 148 and canonical 0, the nearest value to i64::MAX is i64::MAX + 69. Rust has no
    # render position to return there, and returning the closest representable one instead would
    # put the sprite a whole period from where it belongs -- the defect this function exists to
    # prevent, reintroduced at the boundary.
    if candidate in @i64_min..@i64_max, do: {:ok, candidate}, else: :none
  end

  @doc """
  The difference between two positions, or why there is none.

  Not subtraction, because subtraction has no failure case and this does. Two positions are
  comparable only inside one space *and* one topology version: the same tile has different
  global coordinates under two releases, so a difference taken across them looks like a
  distance and is not one.
  """
  @spec compare(
          {space :: map(), version :: integer(), {integer(), integer()}},
          {space :: map(), version :: integer(), {integer(), integer()}}
        ) ::
          {:tiles, {integer(), integer()}} | :different_space | :different_version
  def compare({left_space, left_version, {lx, ly}}, {right_space, right_version, {rx, ry}}) do
    cond do
      left_space.id != right_space.id -> :different_space
      left_version != right_version -> :different_version
      true -> {:tiles, {rx - lx, ry - ly}}
    end
  end

  @doc """
  Which region owns a global position.

  Authority is per region, not per space: two regions of one space meet at a seam, and this is
  the question that crossing it answers differently on either side.

  `placements` is a list of `%{region:, space:, map:, origin:}`, checked by
  `Arena.World.Identity.check_authority/2` before it is used. Refuses rather than guessing if
  the placements do not describe this space: a drifted origin would otherwise assign authority
  at coordinates the space does not agree with.

  It is the *authority* check, not the weaker consistency one, because Rust can only ask this
  question through `ResolvedSpace`, which requires complete ownership. Validating less here
  would have made a partially placed space name an owner on the server and refuse to on the
  client — the two sides disagreeing about who is responsible for a tile, which is the exact
  class of divergence these contracts exist to prevent. A caller that genuinely wants the
  weaker question calls `Identity.check_placements/2` and does its own lookup.
  """
  @spec region_at(map(), {integer(), integer()}, [map()]) ::
          {:ok, integer()} | :none | {:error, tuple()}
  def region_at(space, position, placements) do
    case Arena.World.Identity.check_authority(space, placements) do
      :ok ->
        case to_local(space, position) do
          {:ok, {map, _x, _y}} ->
            case Enum.find(placements, &(&1.map == map)) do
              nil -> :none
              placement -> {:ok, placement.region}
            end

          :none ->
            :none
        end

      {:error, _} = fault ->
        fault
    end
  end

  @doc """
  Project a global position to legacy `map_id + x/y`, or refuse.

  Refuses rather than approximates: an uncovered or ambiguous position has no legacy address,
  and rounding one to the nearest map would place a character on a map that does not contain
  them.
  """
  @spec to_legacy(space(), {integer(), integer()}) :: {:ok, local()} | :unrepresentable
  def to_legacy(space, position) do
    case to_local(space, position) do
      {:ok, local} -> {:ok, local}
      :none -> :unrepresentable
    end
  end
end
