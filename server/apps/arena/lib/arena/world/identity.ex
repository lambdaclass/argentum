defmodule Arena.World.Identity do
  @moduledoc """
  Who owns what, and who may act on it.

  The Rust side is `ao_core::identity`, and neither defines the answers: both read
  `client-rs/crates/ao-core/fixtures/identity_contract.txt`, hand-authored for exactly that
  reason. A disagreement here is a disagreement about who is allowed to move a player.

  Four things in this system look like an id and are not interchangeable, and mixing any two
  only shows up under restart, reshard or a content release:

    * **content identity** — which map, space or instance template. Names authored content, so
      it is stable across everything.
    * **world version** — which compiled release. The same tile has different global
      coordinates under two releases, so a position without a version is a number without a
      meaning.
    * **runtime ownership** — which region is authoritative *right now*. Changes on every seam
      crossing and every restart, and is never persisted or shown.
    * **dynamic instance identity** — which live copy of a template. Exists only while that
      copy does.

  Authority belongs to a **region**, not a world space. Several regions occupy one space —
  today one MapServer per map — so a seamless crossing hands a character between regions while
  the space never changes. Ownership recorded per space could not describe the central event of
  the seamless world.
  """

  @typedoc "A region: one unit of runtime authority, stable across restarts and releases."
  @type region_id :: non_neg_integer()

  @typedoc "An entity, for as long as it exists anywhere. Not a session, not a process."
  @type entity_id :: non_neg_integer()

  @typedoc "One generation of an entity's authoritative owner."
  @type epoch :: non_neg_integer()

  @typedoc "One attempt to move an entity from one owner to another."
  @type transfer_id :: non_neg_integer()

  @type ownership :: %{entity: entity_id(), region: region_id(), epoch: epoch()}
  @type addressed :: %{entity: entity_id(), epoch: epoch()}
  @type reach :: :authoritative | :observed
  @type refusal :: :not_owner | :stale_epoch | :read_only

  @max_epoch 18_446_744_073_709_551_615

  @doc """
  Whether a recipient may execute a command addressed to an entity.

  One function so the rule cannot be restated differently in two routers. Order matters: the
  ownership check comes first, because "you do not own this" is the honest answer and
  reporting a stale epoch for an entity somebody never owned sends a reader to the wrong
  problem.
  """
  @spec may_execute(addressed(), ownership(), reach()) :: :ok | {:error, refusal()}
  def may_execute(command, owner, reach) when reach in [:authoritative, :observed] do
    cond do
      command.entity != owner.entity -> {:error, :not_owner}
      reach == :observed -> {:error, :read_only}
      command.epoch != owner.epoch -> {:error, :stale_epoch}
      true -> :ok
    end
  end

  @doc """
  Advance an epoch, or say that it cannot be advanced.

  Checked rather than incremented. `u64::MAX` handoffs is not a reachable number, and that is
  not why this is checked: wrapping would turn the oldest possible message into the newest,
  which is the one failure the epoch exists to prevent.
  """
  @spec advance(epoch()) :: {:ok, epoch()} | {:error, :exhausted}
  def advance(@max_epoch), do: {:error, :exhausted}

  def advance(epoch) when is_integer(epoch) and epoch >= 0 and epoch < @max_epoch,
    do: {:ok, epoch + 1}

  # An epoch above u64 is not an epoch: Elixir would happily increment it forever while the
  # wire and the Rust side cannot represent it at all. Matching `@max_epoch` exactly and then
  # incrementing anything else meant `advance(2**64)` returned `2**64 + 1`.
  def advance(epoch) when is_integer(epoch) do
    raise ArgumentError,
          "epoch #{epoch} is outside u64, so it cannot be an authority epoch " <>
            "(the maximum is #{@max_epoch})"
  end

  @doc "The largest representable epoch, which is the one that cannot advance."
  def max_epoch, do: @max_epoch

  @doc """
  Whether a message stamped `stamped` is current against the installed epoch.

  An epoch from the future is as refused as one from the past: it did not come from this
  installation, so nothing about it can be trusted.
  """
  @spec current?(epoch(), epoch()) :: boolean()
  def current?(stamped, installed), do: stamped == installed

  @doc """
  Check the one-instance-to-one-runtime-space relationship.

  Every live instance gets its own space. Two parties in the same dungeon design share a
  template and share nothing else, so a reused runtime space would let one party stand on the
  other's tiles.

  Each entry is `%{template: t, instance: i, space: s}`.
  """
  @spec check_instances([map()]) ::
          :ok | {:error, {:space_shared, non_neg_integer()}} | {:error, {:instance_repeated, non_neg_integer()}}
  def check_instances(live) do
    Enum.reduce_while(live, {MapSet.new(), MapSet.new()}, fn entry, {instances, spaces} ->
      cond do
        MapSet.member?(instances, entry.instance) ->
          {:halt, {:error, {:instance_repeated, entry.instance}}}

        MapSet.member?(spaces, entry.space) ->
          {:halt, {:error, {:space_shared, entry.space}}}

        true ->
          {:cont, {MapSet.put(instances, entry.instance), MapSet.put(spaces, entry.space)}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {_instances, _spaces} -> :ok
    end
  end

  @doc """
  Check that region placements agree with the space they claim to place regions in.

  The origin on a placement is a second copy of a fact the space already states, so that a
  caller can do its own arithmetic without asking anything — and a second copy nothing compares
  is a fact waiting to disagree. A region whose origin has drifted converts every position
  successfully and answers every one wrong by a fixed offset, so nothing fails until a player
  is somewhere nobody expects.

  `space` is `%{id: id, placements: %{map => {ox, oy}}}`; each placement is
  `%{region: r, space: s, map: m, origin: {ox, oy}}`.
  """
  @spec check_placements(map(), [map()]) :: :ok | {:error, tuple()}
  @doc """
  Authority: consistent, *and* every map of the space owned by exactly one region.

  This is what a space must satisfy to be resolvable. `W-0125`: "Review topology may be
  incomplete, but authority may not be." An entity cannot enter, spawn, persist or hand off into
  a map no region owns, and a lookup that answered "no owner" for a whole map would report it in
  exactly the words it uses for a tile no map covers — the same answer for "nothing is there" and
  "something is there and nobody is responsible for it".

  `check_placements/2` deliberately does not ask this. A compiler report on a partly reviewed
  corpus is legitimately incomplete, and the two questions have different right answers.
  """
  @spec check_authority(map(), [map()]) :: :ok | {:error, tuple()}
  def check_authority(space, placements) do
    with :ok <- check_placements(space, placements) do
      owned = MapSet.new(placements, & &1.map)

      # Sorted, so the map named is the lowest-numbered unowned one. Rust's placements are a
      # `BTreeMap` and iterate in key order; without sorting here the two languages would name
      # different maps for the same broken space, and a reader comparing their errors would
      # think they disagreed about the rule.
      space.placements
      |> Map.keys()
      |> Enum.sort()
      |> Enum.find(&(not MapSet.member?(owned, &1)))
      |> case do
        nil -> :ok
        map -> {:error, {:map_without_region, map}}
      end
    end
  end

  def check_placements(space, placements) do
    Enum.reduce_while(placements, MapSet.new(), fn placement, claimed ->
      cond do
        placement.space != space.id ->
          {:halt, {:error, {:wrong_space, placement.region, placement.space}}}

        not Map.has_key?(space.placements, placement.map) ->
          {:halt, {:error, {:map_not_in_space, placement.region, placement.map}}}

        Map.fetch!(space.placements, placement.map) != placement.origin ->
          {:halt,
           {:error,
            {:origin_disagrees, placement.region, placement.map, placement.origin,
             Map.fetch!(space.placements, placement.map)}}}

        MapSet.member?(claimed, placement.map) ->
          {:halt, {:error, {:map_shared, placement.map}}}

        true ->
          {:cont, MapSet.put(claimed, placement.map)}
      end
    end)
    |> case do
      {:error, _} = error -> error
      %MapSet{} -> :ok
    end
  end

  @doc """
  The reaches a command can arrive with.

  Listed rather than inferred from "not authoritative": an unrecognised reach is a programming
  error and should raise, not be quietly treated as the read-only case and hidden.
  """
  def reaches, do: [:authoritative, :observed]

  @doc """
  Whether crossing this kind of boundary should be continuous for the player.

  Only a geographic seam is. The rest are deliberate discontinuities, and a client that
  animated a journey across a teleport would be inventing travel that never happened.
  """
  @spec seamless?(:seam | :door | :portal | :teleport | :instance) :: boolean()
  def seamless?(:seam), do: true
  def seamless?(kind) when kind in [:door, :portal, :teleport, :instance], do: false
end
