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

  The version is the map pack's content hash — `sha256(pack)[0..16]`, the same identity
  `Arena.ClientMapPack` puts in every `maps.<hash>.pack` filename. One artefact, one name: an
  earlier attempt hashed the same bytes with FNV-1a and gave the pack a second identity, which
  is what a content hash exists to prevent. It is deliberately *not* the topology manifest
  hash, which versions a different thing and belongs to W-0096's contract.

  What the expected value is matters as much as that it is checked. It comes from the pack the
  server actually loaded, not from the annotations' own `version.txt`: an artefact agreeing
  with itself proves nothing about whether it describes this world.
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

  @doc """
  The content hash of the map pack this server actually loaded.

  This is the value annotations must match. Configuration overrides it — `:map_pack_hash`, for
  a deployment pinning a version deliberately — and otherwise it comes from
  `Arena.ClientMapPack.manifest/0`, which computes `sha256(pack)[0..16]` from the bytes it
  built.

  Returns `nil` only when the pack cannot be built at all, and `nil` is not a wildcard:
  `verify!/0` turns it into a boot failure and `annotate/3` refuses every exit. An earlier
  version accepted any annotation when the expected value was unset, which is the same
  failing-open mistake as allowing a transfer whose destination could not be judged.
  """
  @spec expected_version() :: String.t() | nil
  def expected_version do
    case Application.get_env(:arena, :map_pack_hash) do
      hash when is_binary(hash) ->
        hash

      _ ->
        try do
          Arena.ClientMapPack.manifest().hash
        rescue
          error ->
            Logger.error("Cannot determine the map pack hash: #{inspect(error)}")
            nil
        end
    end
  end

  @doc """
  What the annotations claim about themselves, from `version.txt`.

  Only useful next to `expected_version/0`. On its own it says the artefact agrees with itself.
  """
  @spec claimed_version() :: String.t() | nil
  def claimed_version do
    case File.read(Path.join(directory(), "version.txt")) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> nil
    end
  end

  @doc """
  Fail the boot if the annotations are absent or unversioned.

  Every fixed exit in the world is refused without them, so starting anyway would produce a
  server where nothing works and nothing says why. Raising here names the cause once.
  """
  def verify! do
    dir = directory()
    expected = expected_version()
    claimed = claimed_version()

    cond do
      not File.dir?(dir) ->
        raise """
        Exit annotations are missing: #{dir} does not exist.

        Every fixed exit is refused without them, because the source MapServer has no other
        way to know what its destinations are. Generate them with:

            cargo run --release -p ao-topology -- <pack> --exit-annotations #{dir}
        """

      expected == nil ->
        raise """
        Cannot determine which world this server is serving.

        The map pack could not be built and :map_pack_hash is not configured, so there is
        nothing to compare the exit annotations against. Every exit would be refused.
        """

      claimed == nil ->
        raise """
        Exit annotations in #{dir} do not say which world they describe.

        #{Path.join(dir, "version.txt")} is missing. Regenerate the annotations:

            cargo run --release -p ao-topology -- <pack> --exit-annotations #{dir}
        """

      claimed != expected ->
        raise """
        Exit annotations describe a different world than this server loaded.

          map pack:    #{expected}
          annotations: #{claimed}

        A stale annotation is worse than a missing one, because the server would trust it.
        Regenerate them from the pack this server serves:

            cargo run --release -p ao-topology -- <pack> --exit-annotations #{dir}
        """

      true ->
        :ok
    end
  end

  defp version_of(text) do
    case Regex.run(~r/^#\s*version\s+(\S+)/m, text) do
      [_, version] -> {:ok, version}
      _ -> {:error, :no_version}
    end
  end

  # No expected version is not a wildcard. Not knowing which world these annotations describe
  # is the same position as not having them, and the answer to both is to refuse.
  defp check_version(_version, nil, map_id) do
    Logger.warning(
      "Map #{map_id}: no expected world version, so its exit annotations are not trusted"
    )

    :version_mismatch
  end

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
