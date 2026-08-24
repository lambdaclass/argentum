defmodule Arena.World.Topology do
  @moduledoc """
  A loaded release, and the only thing that answers a versioned lookup.

  `W-0098` established that topology is resolved *once* against a stated version rather than
  consulted per movement: a central coordinate service asked on every step would put a network
  round trip inside movement and make the whole world's geometry a single point of failure.

  What it did not establish was that anything refuses a stale request. The answers existed as
  values — `{:wrong_version, loaded}` and `:no_such_space` — and the tests wrote them by hand,
  which proves the shape has three cases and says nothing about whether a mismatched version is
  ever caught. So the answer is produced here or not at all.

  A version identifies a release exactly when it is the one loaded. `Arena.World.Wire` accepts
  any u64 and the manifest hash is sixteen hex characters, both of which are checks on shape;
  neither can tell whether a release was ever compiled. That is what this comparison is for.

  The counterpart is `ao_core::identity::LoadedTopology`, and
  `client-rs/crates/ao-core/fixtures/position_contract.txt` holds the cases both must satisfy.
  """

  alias Arena.World.Identity
  alias Arena.World.Position

  @type space :: Position.space()
  @typedoc "Where one region's authority sits: the region, its space, its map and that map's origin."
  @type placement :: %{
          region: Identity.region_id(),
          space: non_neg_integer(),
          map: integer(),
          origin: {integer(), integer()}
        }
  @type t :: %{version: non_neg_integer(), spaces: %{optional(non_neg_integer()) => entry()}}
  @type entry :: %{space: space(), regions: [placement()]}

  @type answer ::
          {:resolved, entry()}
          | {:wrong_version, loaded :: non_neg_integer()}
          | :no_such_space

  @doc """
  Load a release: a version, and spaces whose every map is owned by exactly one region.

  Refuses two spaces claiming one id. The resolver would answer with whichever it found first,
  and every tile of the other would silently be somewhere else — a world that loads cleanly and
  puts half its players in the wrong place.

  Refuses a space with an unowned map, via `Identity.check_authority/2` rather than the weaker
  `check_placements/2`. A partially placed space is a legitimate compiler artefact and not a
  loadable one: it resolves, and then reports every tile of the unowned map as having no owner in
  the same words it uses for a tile no map covers.
  """
  @spec load(non_neg_integer(), [{space(), [placement()]}]) ::
          {:ok, t()} | {:error, {:duplicate_space, non_neg_integer()}} | {:error, term()}
  def load(version, spaces) do
    Enum.reduce_while(spaces, {:ok, %{version: version, spaces: %{}}}, fn {space, regions}, {:ok, loaded} ->
      with false <- Map.has_key?(loaded.spaces, space.id),
           :ok <- Identity.check_authority(space, regions) do
        entry = %{space: space, regions: regions}
        {:cont, {:ok, put_in(loaded.spaces[space.id], entry)}}
      else
        true -> {:halt, {:error, {:duplicate_space, space.id}}}
        {:error, fault} -> {:halt, {:error, fault}}
      end
    end)
  end

  @doc "The release loaded."
  @spec version(t()) :: non_neg_integer()
  def version(loaded), do: loaded.version

  @doc """
  Resolve a space once, against a stated version.

  A mismatched version is refused rather than served from this release. Falling back would
  answer a different question than the one asked: the same tile has different global
  coordinates under two releases, so the caller would receive coordinates that look entirely
  valid and denote somewhere else.
  """
  @spec resolve(t(), non_neg_integer(), non_neg_integer()) :: answer()
  def resolve(loaded, space_id, version) do
    cond do
      version != loaded.version -> {:wrong_version, loaded.version}
      not Map.has_key?(loaded.spaces, space_id) -> :no_such_space
      true -> {:resolved, loaded.spaces[space_id]}
    end
  end

  @doc """
  Which region owns a position, resolving first.

  One answer or none, and `:none` for every reason a lookup can fail: a wrong version, an
  unknown space, a tile no map covers, and a tile two maps claim. A caller that needs to tell
  those apart calls `resolve/3` and reads the answer.
  """
  @spec region_at(t(), non_neg_integer(), non_neg_integer(), {integer(), integer()}) ::
          {:ok, non_neg_integer()} | :none
  def region_at(loaded, space_id, version, position) do
    case resolve(loaded, space_id, version) do
      {:resolved, entry} -> Position.region_at(entry.space, position, entry.regions)
      _ -> :none
    end
  end

  @doc """
  Read a version from a manifest content hash.

  Checks the shape — sixteen hex characters, exactly u64 — and nothing more. It cannot tell
  whether the release was ever compiled; only `resolve/3` can. A version that parses is not a
  version that exists.
  """
  @spec from_manifest_hash(String.t()) :: {:ok, non_neg_integer()} | :error
  def from_manifest_hash(hash) when is_binary(hash) do
    if String.length(hash) == 16 and String.match?(hash, ~r/\A[0-9a-f]{16}\z/) do
      {:ok, String.to_integer(hash, 16)}
    else
      :error
    end
  end

  @doc "The hash a version came from, sixteen hex characters wide."
  @spec manifest_hash(non_neg_integer()) :: String.t()
  def manifest_hash(version) do
    version |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")
  end
end
