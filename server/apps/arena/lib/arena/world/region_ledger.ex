defmodule Arena.World.RegionLedger do
  @moduledoc """
  The region allocation ledger: which `RegionId`s were issued, which are live, which are spent.

  `W-0098` defined a region as a unit of runtime authority that survives process restarts and
  topology releases, and nothing made it survive anything. The manifest emits no regions, so
  every id in those contracts is a number a person typed into a fixture, and the four-region MVP
  would have promoted fixture numbers into production identity by accident.

  What makes identity durable is retained history, not derivation. An id computed from graph
  traversal order, a map number, or the current corpus changes when the corpus changes — which is
  exactly when it must not. So the ledger is a version-controlled file, it is compiler *input*,
  and a normal compile never writes to it. There is no runtime allocator, no ETS table, no PID
  registry, no database sequence and no movement-time lookup: by the time anything is moving,
  every region already has its name.

  A release token names the release a change came *after*, never the release being built. The
  ledger is an input to the topology content hash, so a tombstone naming the hash it is part of
  would make that hash depend on itself — there is no order in which such a file can be written.

  The counterpart is `ao_core::ledger`, and
  `client-rs/crates/ao-core/fixtures/ledger_contract.txt` is the specification both satisfy. It
  fixes the order the checks run in, because two implementations reporting different faults for
  one broken file would each look wrong to the other.
  """

  @format 1
  @u32_max 4_294_967_295

  @type region_id :: pos_integer()
  @type fault :: {atom(), term()}
  @type t :: %{
          next_region_id: non_neg_integer(),
          active: %{optional(region_id()) => %{space: non_neg_integer(), maps: [integer()]}},
          tombstones: %{optional(region_id()) => %{retired_after: String.t(), reason: atom()}},
          splits: [%{from: region_id(), into: [region_id()], after: String.t()}],
          merges: [%{from: [region_id()], into: region_id(), after: String.t()}]
        }

  @doc "The one format this compiler understands."
  def format, do: @format

  @doc "The largest id `u32` can hold, which is also the mark at which allocation refuses."
  def exhausted_at, do: @u32_max

  @doc """
  Read and validate a ledger.

  The check order is part of the contract: format, then per-line faults, then dispositions, then
  accounting. Dispositions before accounting, because a split naming an id that was never issued
  is a statement about *that line*, and reporting it as a hole in the numbering would send a
  reader to the high-water mark instead of to the disposition that is wrong.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, fault()}
  def parse(text) do
    empty = %{next_region_id: nil, active: %{}, tombstones: %{}, splits: [], merges: [], order: []}

    with {:ok, ledger} <- read_lines(text, empty),
         :ok <- check_header(ledger),
         :ok <- check_declarations(ledger),
         :ok <- check_dispositions(ledger),
         :ok <- check_accounting(ledger) do
      {:ok, Map.delete(ledger, :order)}
    end
  end

  defp read_lines(text, ledger) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, ledger}, fn {raw, at}, {:ok, ledger} ->
      line = raw |> String.split("#") |> hd() |> String.trim()

      if line == "" do
        {:cont, {:ok, ledger}}
      else
        case read_line(String.split(line, ~r/\s+/), at, ledger) do
          {:ok, ledger} -> {:cont, {:ok, ledger}}
          {:error, _} = fault -> {:halt, fault}
        end
      end
    end)
  end

  defp read_line(["format", version], at, ledger) do
    with {:ok, version} <- number(version, at, "format") do
      if version == @format,
        do: {:ok, Map.put(ledger, :format, version)},
        else: {:error, {:unknown_format, version}}
    end
  end

  defp read_line(["next_region_id", mark], at, ledger) do
    with {:ok, mark} <- number(mark, at, "next_region_id") do
      {:ok, %{ledger | next_region_id: mark}}
    end
  end

  defp read_line(["active", id, "space", space, "maps" | rest], at, ledger) do
    with {:ok, id} <- number(id, at, "region"),
         {:ok, space} <- number(space, at, "space"),
         {:ok, maps} <- number_list(List.first(rest) || "", at, "map") do
      {:ok,
       %{
         ledger
         | active: Map.put(ledger.active, id, %{space: space, maps: maps}),
           order: ledger.order ++ [id]
       }}
    end
  end

  defp read_line(["tombstone", id, "retired_after", release, "reason", reason], at, ledger) do
    with {:ok, id} <- number(id, at, "region"),
         {:ok, reason} <- retirement(reason, at) do
      {:ok,
       %{
         ledger
         | tombstones: Map.put(ledger.tombstones, id, %{retired_after: release, reason: reason}),
           order: ledger.order ++ [id]
       }}
    end
  end

  defp read_line(["split", from, "into", into, "after", release], at, ledger) do
    with {:ok, from} <- number(from, at, "region"),
         {:ok, into} <- number_list(into, at, "region") do
      split = %{from: from, into: into, after: release}
      {:ok, %{ledger | splits: ledger.splits ++ [split]}}
    end
  end

  defp read_line(["merge", from, "into", into, "after", release], at, ledger) do
    with {:ok, from} <- number_list(from, at, "region"),
         {:ok, into} <- number(into, at, "region") do
      merge = %{from: from, into: into, after: release}
      {:ok, %{ledger | merges: ledger.merges ++ [merge]}}
    end
  end

  defp read_line(word, at, _ledger), do: {:error, {:unreadable, "line #{at}: #{Enum.join(word, " ")}"}}

  defp check_header(ledger) do
    cond do
      not Map.has_key?(ledger, :format) -> {:error, {:unreadable, "no format line"}}
      ledger.next_region_id == nil -> {:error, {:unreadable, "no next_region_id"}}
      true -> :ok
    end
  end

  # Per-line faults, in the order a reader meets them.
  defp check_declarations(ledger) do
    with :ok <- check_ids(ledger),
         :ok <- check_maps(ledger) do
      :ok
    end
  end

  defp check_ids(ledger) do
    Enum.reduce_while(ledger.order, MapSet.new(), fn id, seen ->
      cond do
        id == 0 ->
          {:halt, {:error, {:not_a_region, 0}}}

        MapSet.member?(seen, id) ->
          {:halt, {:error, {:duplicate_region, id}}}

        id >= ledger.next_region_id ->
          {:halt, {:error, {:past_high_water, id}}}

        Map.has_key?(ledger.active, id) and Map.has_key?(ledger.tombstones, id) ->
          {:halt, {:error, {:reused, id}}}

        true ->
          {:cont, MapSet.put(seen, id)}
      end
    end)
    |> case do
      {:error, _} = fault -> fault
      %MapSet{} -> :ok
    end
  end

  defp check_maps(ledger) do
    ledger.active
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(MapSet.new(), fn {id, region}, owned ->
      duplicate = Enum.find(region.maps, &MapSet.member?(owned, &1))

      cond do
        # Duplicates before sortedness: `330,330` is non-descending, and calling it a sorting
        # problem would send a reader looking for the wrong edit.
        duplicate != nil ->
          {:halt, {:error, {:duplicate_map, duplicate}}}

        length(Enum.uniq(region.maps)) != length(region.maps) ->
          {:halt, {:error, {:duplicate_map, first_repeat(region.maps)}}}

        region.maps != Enum.sort(region.maps) ->
          {:halt, {:error, {:unsorted, id}}}

        region.maps == [] ->
          {:halt, {:error, {:empty, id}}}

        true ->
          {:cont, MapSet.union(owned, MapSet.new(region.maps))}
      end
    end)
    |> case do
      {:error, _} = fault -> fault
      %MapSet{} -> :ok
    end
  end

  defp first_repeat(maps) do
    maps
    |> Enum.frequencies()
    |> Enum.filter(fn {_, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.min()
  end

  # The history has to add up, not merely reference live ids.
  #
  # A ledger can be internally consistent about *ids* and still record two incompatible stories
  # about what happened, which is worse than recording nothing: the next reviewer trusts it. So
  # every retired-by-change id has exactly one disposition, every disposition agrees with its
  # tombstone about the parent release, and every release token is a topology hash.
  defp check_dispositions(ledger) do
    with :ok <- check_releases(ledger),
         {:ok, disposed} <- check_splits(ledger, MapSet.new()),
         {:ok, disposed} <- check_merges(ledger, disposed) do
      check_disposed(ledger, disposed)
    end
  end

  # Release tokens first: a fault reported against an unparseable release would name a token
  # that means nothing, and the reader needs to know *that* is the problem.
  defp check_releases(ledger) do
    tokens =
      Enum.map(ledger.tombstones, fn {_, stone} -> stone.retired_after end) ++
        Enum.map(ledger.splits, & &1.after) ++ Enum.map(ledger.merges, & &1.after)

    case Enum.find(tokens, &(not release?(&1))) do
      nil -> :ok
      token -> {:error, {:not_a_release, token}}
    end
  end

  # Sixteen lowercase hex characters, checked through `Arena.World.Topology.from_manifest_hash/1`
  # rather than re-implemented, so the ledger and the wire cannot disagree about what a release
  # is called.
  defp release?(token), do: Arena.World.Topology.from_manifest_hash(token) != :error

  defp check_splits(ledger, disposed) do
    Enum.reduce_while(ledger.splits, {:ok, disposed}, fn split, {:ok, disposed} ->
      stone = Map.get(ledger.tombstones, split.from)

      cond do
        stone == nil or stone.reason != :split ->
          {:halt, {:error, {:dangling_split, split.from}}}

        stone.retired_after != split.after ->
          {:halt, {:error, {:release_mismatch, split.from}}}

        MapSet.member?(disposed, split.from) ->
          {:halt, {:error, {:repeated_disposition, split.from}}}

        length(split.into) < 2 ->
          {:halt, {:error, {:not_a_split, split.from}}}

        split.into != Enum.sort(Enum.uniq(split.into)) ->
          {:halt, {:error, {:unsorted_disposition, split.from}}}

        true ->
          case Enum.find(split.into, &(not issued?(ledger, &1) or &1 == split.from)) do
            nil -> {:cont, {:ok, MapSet.put(disposed, split.from)}}
            id -> {:halt, {:error, {:dangling_split, id}}}
          end
      end
    end)
  end

  defp check_merges(ledger, disposed) do
    Enum.reduce_while(ledger.merges, {:ok, disposed}, fn merge, {:ok, disposed} ->
      cond do
        length(merge.from) < 2 ->
          {:halt, {:error, {:not_a_merge, merge.into}}}

        merge.from != Enum.sort(Enum.uniq(merge.from)) ->
          {:halt, {:error, {:unsorted_disposition, merge.into}}}

        true ->
          case merge_sources(ledger, merge, disposed) do
            {:ok, disposed} ->
              if issued?(ledger, merge.into) and merge.into not in merge.from,
                do: {:cont, {:ok, disposed}},
                else: {:halt, {:error, {:dangling_merge, merge.into}}}

            {:error, _} = fault ->
              {:halt, fault}
          end
      end
    end)
  end

  defp merge_sources(ledger, merge, disposed) do
    Enum.reduce_while(merge.from, {:ok, disposed}, fn id, {:ok, disposed} ->
      stone = Map.get(ledger.tombstones, id)

      cond do
        stone == nil or stone.reason != :merge ->
          {:halt, {:error, {:dangling_merge, id}}}

        stone.retired_after != merge.after ->
          {:halt, {:error, {:release_mismatch, id}}}

        MapSet.member?(disposed, id) ->
          {:halt, {:error, {:repeated_disposition, id}}}

        true ->
          {:cont, {:ok, MapSet.put(disposed, id)}}
      end
    end)
  end

  # Every id retired *by a change* must have that change on record. `:removed` is the one reason
  # that needs no disposition: nothing replaced it, and that is the whole content of the
  # statement.
  defp check_disposed(ledger, disposed) do
    ledger.tombstones
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find(fn {id, stone} ->
      stone.reason in [:split, :merge] and not MapSet.member?(disposed, id)
    end)
    |> case do
      nil -> :ok
      {id, _} -> {:error, {:undisposed, id}}
    end
  end

  # Every id below the high-water mark is live or spent. This is what makes "never reused"
  # provable rather than hoped for: the ledger is a complete record of every id ever issued, so a
  # gap means one was lost, and a lost id is one nobody can prove is free.
  defp check_accounting(ledger) do
    case Enum.find(1..(ledger.next_region_id - 1)//1, &(not issued?(ledger, &1))) do
      nil -> :ok
      id -> {:error, {:unaccounted, id}}
    end
  end

  defp issued?(ledger, id),
    do: Map.has_key?(ledger.active, id) or Map.has_key?(ledger.tombstones, id)

  defp retired_as?(ledger, id, reason) do
    match?(%{reason: ^reason}, Map.get(ledger.tombstones, id))
  end

  @doc """
  Which region owns a map, in the space that claims it.

  The space is checked, not assumed: a map belongs to one space, and answering from the map alone
  would hand a caller an owner from a different world if the two ever disagreed.
  """
  @spec owner(t(), non_neg_integer(), integer()) :: {:ok, region_id()} | :none
  def owner(ledger, space, map) do
    ledger.active
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find(fn {_, region} -> region.space == space and map in region.maps end)
    |> case do
      {id, _} -> {:ok, id}
      nil -> :none
    end
  end

  @doc """
  The next id to issue, or `:exhausted`.

  Always the recorded high-water mark, never a count of the live regions and never a scan for a
  hole: counting hands out an id a split already spent, and scanning hands out one a tombstone is
  holding. Exhaustion is an explicit refusal because the alternative is wrapping to 1, and id 1
  belonged to somebody.
  """
  @spec next_available(t()) :: {:ok, region_id()} | :exhausted
  def next_available(%{next_region_id: @u32_max}), do: :exhausted
  def next_available(ledger), do: {:ok, ledger.next_region_id}

  @doc """
  Issue an id to a new authority. The only thing that moves the high-water mark.

  Called by the explicit review command, never by a compile or a check: a build that can
  renumber the world when the corpus changes is a build that decides identity, and identity is
  what this file exists to keep out of the build's hands.

  Everything is checked *before* anything is written, so success always leaves another valid
  ledger and a refusal leaves this one untouched. It used to accept an empty map list or a map
  another region already owned, return success, and hand back a ledger its own parser would
  reject — a function whose success value is invalid is worse than one that fails, because the
  failure surfaces at the next read and blames whoever read it.

  Maps are deduplicated and sorted rather than refused for being unsorted: a caller passing a
  set has no order to get wrong, and the canonical spelling is this function's job. A map
  repeated *within* the request is still a duplicate, because it means the caller believes it is
  allocating two things.
  """
  @spec allocate(t(), non_neg_integer(), [integer()]) ::
          {:ok, region_id(), t()} | {:error, fault()}
  def allocate(ledger, space, maps) do
    with {:ok, id} <- next_or_fault(ledger),
         :ok <- check_request(ledger, id, maps) do
      region = %{space: space, maps: Enum.sort(maps)}

      {:ok, id, %{ledger | active: Map.put(ledger.active, id, region), next_region_id: id + 1}}
    end
  end

  defp next_or_fault(ledger) do
    case next_available(ledger) do
      {:ok, id} -> {:ok, id}
      # Its own fault rather than `past_high_water`, which is a statement about a line in the
      # file: this one is about the allocator having nothing left to give, and a reader shown
      # "past high water" would go looking for an id that is not there.
      :exhausted -> {:error, {:exhausted, @u32_max}}
    end
  end

  defp check_request(ledger, id, maps) do
    owned =
      ledger.active
      |> Enum.flat_map(fn {_, region} -> region.maps end)
      |> MapSet.new()

    cond do
      maps == [] ->
        {:error, {:empty, id}}

      (repeat = first_repeated(maps)) != nil ->
        {:error, {:duplicate_map, repeat}}

      # Any space, not just this one: a map belongs to one space, so a second claim is the
      # corpus contradiction `W-0097` measured rather than a fact to allocate around.
      (taken = Enum.find(maps, &MapSet.member?(owned, &1))) != nil ->
        {:error, {:duplicate_map, taken}}

      true ->
        :ok
    end
  end

  defp first_repeated(maps) do
    maps
    |> Enum.frequencies()
    |> Enum.filter(fn {_, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.min(fn -> nil end)
  end

  @doc """
  The ledger as bytes: sorted, line-oriented, identical for identical state.

  Re-encoding a parsed ledger must reproduce it exactly, or a release pair cannot be compared
  byte for byte and "unchanged" stops being checkable.
  """
  @spec encode(t()) :: String.t()
  def encode(ledger) do
    header = ["format #{@format}", "next_region_id #{ledger.next_region_id}"]

    actives =
      for {id, region} <- Enum.sort_by(ledger.active, &elem(&1, 0)) do
        "active #{id} space #{region.space} maps #{Enum.join(region.maps, ",")}"
      end

    stones =
      for {id, stone} <- Enum.sort_by(ledger.tombstones, &elem(&1, 0)) do
        "tombstone #{id} retired_after #{stone.retired_after} reason #{stone.reason}"
      end

    splits =
      for split <- ledger.splits do
        "split #{split.from} into #{Enum.join(split.into, ",")} after #{split.after}"
      end

    merges =
      for merge <- ledger.merges do
        "merge #{Enum.join(merge.from, ",")} into #{merge.into} after #{merge.after}"
      end

    Enum.join(header ++ actives ++ stones ++ splits ++ merges, "\n") <> "\n"
  end

  @doc "A fault as the contract writes it, so both languages report one broken file the same way."
  @spec fault_name(fault()) :: String.t()
  def fault_name({kind, value}) do
    name =
      kind
      |> Atom.to_string()
      |> String.replace("_", "-")

    "#{name} #{value}"
  end

  # A tombstone's reason explains the history; no reason permits reuse.
  defp retirement("removed", _at), do: {:ok, :removed}
  defp retirement("split", _at), do: {:ok, :split}
  defp retirement("merge", _at), do: {:ok, :merge}

  defp retirement(other, at),
    do: {:error, {:unreadable, "line #{at}: reason #{inspect(other)}"}}

  defp number(text, at, what) do
    case Integer.parse(text) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, {:unreadable, "line #{at}: #{what} #{inspect(text)}"}}
    end
  end

  defp number_list("", _at, _what), do: {:ok, []}

  defp number_list(text, at, what) do
    text
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case number(part, at, what) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, _} = fault -> {:halt, fault}
      end
    end)
  end
end
