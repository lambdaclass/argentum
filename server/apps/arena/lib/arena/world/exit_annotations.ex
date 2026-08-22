defmodule Arena.World.ExitAnnotations do
  @moduledoc """
  What each exit's destination tile is, compiled in beside the map rather than looked up.

  A MapServer holds its own map's tiles and nobody else's, so it cannot answer "is the tile
  this exit names walkable?" on its own. Asking the destination process would put a
  synchronous call in the movement path, and a shared table would be one process's ETS that
  vanishes when that process dies. Neither is necessary: fixed exits do not change, so the
  topology compiler resolves every destination once and writes it out per map
  (`ao-topology <pack> --exit-annotations <dir>`), and each MapServer merges its own file into
  its own exits at load. Validation is then a field read on a record the server already has.

  **Absent or mismatched annotation means refuse.** An exit with no annotation, or one carried
  over from a different world version, is not transferred. That is the opposite of the first
  attempt at this, which allowed a transfer whenever data was missing — and so promised the
  source validates the destination while quietly failing open exactly when it could not. The
  1,196 exits in this corpus whose destination map does not exist are unannotated on purpose
  and are refused for the same reason.

  The version is the corpus hash the annotations were compiled from. A handoff must never
  combine two world-pack versions: the same tile has a different meaning under a different
  release, and a stale annotation is worse than none because it looks authoritative.
  """

  require Logger

  @type annotation :: %{
          class: :walkable | :solid | :water,
          drawn?: boolean(),
          dest_map: integer(),
          dest_x: integer(),
          dest_y: integer(),
          version: String.t()
        }

  @doc """
  Merge annotations into a map's exits.

  Returns the exits with `:arrival` set where an annotation exists and matching `:version`.
  Exits without one are returned unchanged, and the movement path refuses them.
  """
  @spec annotate([map()], integer(), String.t() | nil) :: [map()]
  def annotate(exits, map_id, expected_version) do
    annotations = load(map_id, expected_version)

    Enum.map(exits, fn exit ->
      case Map.get(annotations, {exit.x, exit.y}) do
        nil ->
          exit

        annotation ->
          # Only trust an annotation that names the same destination the exit does. A
          # mismatch means the annotation file and the map data disagree about the world,
          # which is exactly when guessing is worst.
          if annotation.dest_map == exit.dest_map and annotation.dest_x == exit.dest_x and
               annotation.dest_y == exit.dest_y do
            Map.put(exit, :arrival, annotation)
          else
            Logger.warning(
              "Map #{map_id} exit (#{exit.x},#{exit.y}): annotation names " <>
                "#{annotation.dest_map} (#{annotation.dest_x},#{annotation.dest_y}) but the map " <>
                "says #{exit.dest_map} (#{exit.dest_x},#{exit.dest_y}); refusing to annotate"
            )

            exit
          end
      end
    end)
  end

  @doc """
  Read one map's annotations, keyed by the exit tile they belong to.

  An empty map is returned when the file is absent, unreadable, or compiled from a different
  world version — every case where the honest answer is "I do not know", which the caller
  turns into a refusal.
  """
  @spec load(integer(), String.t() | nil) :: %{{integer(), integer()} => annotation()}
  def load(map_id, expected_version) do
    path = Path.join(directory(), "map-#{map_id}.txt")

    with {:ok, text} <- File.read(path),
         {:ok, version} <- version_of(text),
         :ok <- check_version(version, expected_version, map_id) do
      parse(text, version)
    else
      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("Map #{map_id}: cannot read exit annotations: #{inspect(reason)}")
        %{}

      :version_mismatch ->
        %{}
    end
  end

  @doc "Where the compiled annotations live."
  def directory do
    Application.get_env(:arena, :exit_annotations_dir) ||
      Path.join(:code.priv_dir(:arena), "arrival")
  end

  @doc "The world version the server expects annotations to have been compiled from."
  def expected_version, do: Application.get_env(:arena, :topology_version)

  defp version_of(text) do
    case Regex.run(~r/^#\s*version\s+(\S+)/m, text) do
      [_, version] -> {:ok, version}
      _ -> {:error, :no_version}
    end
  end

  defp check_version(_version, nil, _map_id), do: :ok

  defp check_version(version, expected, map_id) do
    if version == expected do
      :ok
    else
      Logger.warning(
        "Map #{map_id}: exit annotations are for world #{version} but this server expects " <>
          "#{expected}; every exit on this map will be refused rather than guessed"
      )

      :version_mismatch
    end
  end

  defp parse(text, version) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ~r/\s+/) do
        [x, y, dest_map, dest_x, dest_y, class, drawn] ->
          Map.put(acc, {String.to_integer(x), String.to_integer(y)}, %{
            class: class_of(class),
            drawn?: drawn == "drawn",
            dest_map: String.to_integer(dest_map),
            dest_x: String.to_integer(dest_x),
            dest_y: String.to_integer(dest_y),
            version: version
          })

        _ ->
          acc
      end
    end)
  end

  defp class_of("walkable"), do: :walkable
  defp class_of("water"), do: :water
  # Anything unrecognised is solid: an unknown class must not become open ground.
  defp class_of(_), do: :solid

  @doc """
  Annotate an exit in code, for maps built in the process rather than compiled.

  Synthetic test and benchmark maps know their own tiles where they are defined, so they can
  say so directly instead of being refused for lacking a file. The version is theirs, not the
  corpus's, so a synthetic annotation can never be mistaken for compiled world data.
  """
  @spec synthetic(map(), :walkable | :solid | :water, boolean()) :: map()
  def synthetic(exit, class, drawn?) do
    Map.put(exit, :arrival, %{
      class: class,
      drawn?: drawn?,
      dest_map: exit.dest_map,
      dest_x: exit.dest_x,
      dest_y: exit.dest_y,
      version: "synthetic"
    })
  end
end
