defmodule TileGrid do
  @moduledoc """
  Rust NIF for tile-based map operations.

  Each map is a 100x100 grid of u8 tile values:
  - 0 = walkable
  - 1 = blocked
  - 2 = water
  - 3 = lava
  - 4 = exit trigger

  Maps are loaded into Rust memory at boot and accessed via NIF calls.
  """

  use Rustler, otp_app: :arena, crate: "tile_grid"

  defmodule Position do
    @moduledoc "A tile position on a map."
    defstruct [:x, :y]
  end

  @doc "Load a map's tile data (list of 10000 u8 values) into memory."
  @spec load_map(non_neg_integer(), [non_neg_integer()]) :: :ok | :error
  def load_map(_map_id, _tiles), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Unload a map from memory."
  @spec unload_map(non_neg_integer()) :: :ok
  def unload_map(_map_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Check if a tile is walkable."
  @spec is_walkable(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: boolean()
  def is_walkable(_map_id, _x, _y), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Get the tile value at a position."
  @spec get_tile(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def get_tile(_map_id, _x, _y), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Try to move one tile in a direction.
  Returns `{:ok, %Position{}}` or `{:error, :blocked}`.
  Direction is one of: :north, :south, :east, :west
  """
  @spec move_entity(non_neg_integer(), non_neg_integer(), non_neg_integer(), atom()) ::
          {:ok, Position.t()} | {:error, :blocked}
  def move_entity(_map_id, _x, _y, _direction), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Check line of sight between two points using Bresenham's algorithm."
  @spec line_of_sight(non_neg_integer(), integer(), integer(), integer(), integer()) :: boolean()
  def line_of_sight(_map_id, _x1, _y1, _x2, _y2), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  A* pathfinding. Returns a list of positions from near start to goal,
  or an empty list if no path exists.
  """
  @spec a_star(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          [Position.t()]
  def a_star(_map_id, _x1, _y1, _x2, _y2), do: :erlang.nif_error(:nif_not_loaded)
end
