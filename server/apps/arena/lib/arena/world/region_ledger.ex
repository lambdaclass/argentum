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

  # A split's old id must be spent *as a split*, and each new id must have been issued. Same for
  # a merge. The tombstone and the disposition must tell the same story, or the history explains
  # a change that never happened.
  defp check_dispositions(ledger) do
    with :ok <- check_splits(ledger) do
      check_merges(ledger)
    end
  end

  defp check_splits(ledger) do
    Enum.reduce_while(ledger.splits, :ok, fn split, :ok ->
      cond do
        not retired_as?(ledger, split.from, :split) ->
          {:halt, {:error, {:dangling_split, split.from}}}

        true ->
          case Enum.find(split.into, &(not issued?(ledger, &1) or &1 == split.from)) do
            nil -> {:cont, :ok}
            id -> {:halt, {:error, {:dangling_split, id}}}
          end
      end
    end)
  end

  defp check_merges(ledger) do
    Enum.reduce_while(ledger.merges, :ok, fn merge, :ok ->
      case Enum.find(merge.from, &(not retired_as?(ledger, &1, :merge))) do
        nil ->
          if issued?(ledger, merge.into) and merge.into not in merge.from,
            do: {:cont, :ok},
            else: {:halt, {:error, {:dangling_merge, merge.into}}}

        id ->
          {:halt, {:error, {:dangling_merge, id}}}
      end
    end)
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

  Called by the explicit review command, never by a compile or a check: a build that can renumber
  the world when the corpus changes is a build that decides identity, and identity is what this
  file exists to keep out of the build's hands.
  """
  @spec allocate(t(), non_neg_integer(), [integer()]) ::
          {:ok, region_id(), t()} | {:error, :exhausted}
  def allocate(ledger, space, maps) do
    case next_available(ledger) do
      :exhausted ->
        {:error, :exhausted}

      {:ok, id} ->
        region = %{space: space, maps: maps |> Enum.uniq() |> Enum.sort()}

        {:ok, id, %{ledger | active: Map.put(ledger.active, id, region), next_region_id: id + 1}}
    end
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
