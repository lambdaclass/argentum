defmodule Arena.World.Wire do
  @moduledoc """
  The bytes that cross the boundary, as the server encodes and decodes them.

  The specification is `client-rs/crates/ao-core/fixtures/wire_contract.txt`: semantic values
  beside the exact bytes they must become, with the hexadecimal produced by a third
  implementation rather than by either codec. Neither this module nor `ao_core::wire` defines
  the answers, and neither can pass by reproducing its own mistake — which is how two
  languages come to hold different beliefs about one field while both test suites stay green.

  Three records, little-endian, each behind a one-byte discriminant:

      1 position  : topology_version u64, space u128, x i32, y i32         33 bytes
      2 ownership : entity u64, region u32, epoch u64                      21 bytes
      3 transfer  : transfer u64, transition u8, from_region u32, to u32   18 bytes

  The topology version is the manifest's content hash — sixteen hex characters, exactly u64 —
  so a position can *name* a release rather than carry a bare counter. It was a freely
  constructed u32 with no relationship to any artifact.

  Naming is not proving. `encode/1` accepts any u64 and `Arena.World.Topology.from_manifest_hash/1`
  accepts any sixteen lowercase hex characters; neither can tell whether the release was ever
  compiled. Only `Arena.World.Topology.resolve/3` can, by comparing against the release actually
  loaded. A version on the wire is a claim to be checked, not a checked claim.

  A space id is 128 bits because not every space is compiled: `W-0104` mints one per live
  dungeon instance at runtime, from whichever region is asked, and a narrower id would need a
  central allocator or hand-managed ranges to stay unique. Getting that wrong puts two parties
  in one space. A region id stays 32 bits: a region is a unit of authority over compiled
  content, not something minted per player action.

  It is *not* yet allocated by anything. `W-0097`'s manifest emits spaces, geometry, maps and
  origins and contains no regions, so the earlier claim that region ids "come from the topology
  manifest" was false when written. Nothing in this contract depends on the allocator existing —
  the type is opaque and stable by construction — but stability across releases and reshards is
  not yet *established*, and `W-0125` owes it.

  Coordinates are signed because the world has negative ones. Reading `x` as unsigned turns a
  tile one step west of a space's origin into a position four billion tiles east, which looks
  like a plausible place.

  Zero is not a transition kind. An uninitialised byte must not decode as a geographic seam —
  the one kind meaning a player crosses without noticing — because a field nobody set should
  never become the most permissive answer.

  Decoding is exact-length: a record with a trailing byte is refused rather than ignored. A
  decoder that tolerates extra bytes cannot tell a framing bug from a new field, and will
  accept a message from a version it does not understand.
  """

  @position 1
  @ownership 2
  @transfer 3

  # Elixir integers are unbounded and bit syntax silently keeps only the low bits, so a value
  # one past a field's range encodes as something else entirely: `space = 2^128` produced the
  # same bytes as `space = 0`, and `x = 2^31` came back as `-2^31`. Rust's types cannot hold
  # those inputs at all, so the two sides would have disagreed about identity while both test
  # suites stayed green. Every field is range-checked before it is written.
  @u32 0xFFFF_FFFF
  @u64 0xFFFF_FFFF_FFFF_FFFF
  @u128 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF
  @i32_min -2_147_483_648
  @i32_max 2_147_483_647

  @seam 1
  @door 2
  @portal 3
  @teleport 4
  @instance 5

  @type transition :: :seam | :door | :portal | :teleport | :instance

  @type record ::
          {:position, version :: non_neg_integer(), space :: non_neg_integer(), x :: integer(), y :: integer()}
          | {:ownership, entity :: non_neg_integer(), region :: non_neg_integer(), epoch :: non_neg_integer()}
          | {:transfer, transfer :: non_neg_integer(), transition(), from :: non_neg_integer(), to :: non_neg_integer()}

  @type error ::
          {:truncated, needed :: non_neg_integer(), found :: non_neg_integer()}
          | {:oversized, expected :: non_neg_integer(), found :: non_neg_integer()}
          | {:unknown_record, byte :: non_neg_integer()}
          | {:unknown_transition, byte :: non_neg_integer()}

  @doc "The encoded length of a record, including its discriminant."
  @spec byte_size_of(record()) :: pos_integer()
  def byte_size_of({:position, _, _, _, _}), do: 33
  def byte_size_of({:ownership, _, _, _}), do: 21
  def byte_size_of({:transfer, _, _, _, _}), do: 18

  @doc """
  Encode a record.

  Raises on a value outside its field's range rather than truncating it. Truncation here is not
  a rounding error: it silently rewrites an identity, so two different spaces or entities become
  the same one, and nothing downstream can tell.
  """
  @spec encode(record()) :: binary()
  def encode({:position, version, space, x, y})
      when version in 0..@u64 and space in 0..@u128 and x in @i32_min..@i32_max and
             y in @i32_min..@i32_max do
    <<@position::unsigned-8, version::little-unsigned-64, space::little-unsigned-128, x::little-signed-32,
      y::little-signed-32>>
  end

  def encode({:ownership, entity, region, epoch})
      when entity in 0..@u64 and region in 0..@u32 and epoch in 0..@u64 do
    <<@ownership::unsigned-8, entity::little-unsigned-64, region::little-unsigned-32, epoch::little-unsigned-64>>
  end

  def encode({:transfer, transfer, transition, from, to})
      when transfer in 0..@u64 and from in 0..@u32 and to in 0..@u32 do
    <<@transfer::unsigned-8, transfer::little-unsigned-64, transition_byte(transition)::unsigned-8,
      from::little-unsigned-32, to::little-unsigned-32>>
  end

  # Reached only when a field is out of range, since the clauses above cover every in-range
  # record. Names the offending field and its bound, because "encode failed" would send a
  # reader looking at the wrong value.
  def encode(record) do
    raise ArgumentError, """
    #{inspect(record)} cannot be encoded: #{out_of_range(record)}.

    Elixir integers are unbounded and bit syntax keeps only the low bits, so encoding this
    would have produced the bytes of a different record. The bounds are the wire contract's:
    u64 for a topology version, an entity, an epoch and a transfer id, u32 for a region, u128
    for a world space, and signed i32 for a coordinate.
    """
  end

  defp out_of_range({:position, version, space, x, y}) do
    cond do
      version not in 0..@u64 -> "topology version #{version} exceeds u64"
      space not in 0..@u128 -> "world space #{space} exceeds u128"
      x not in @i32_min..@i32_max -> "x #{x} is outside i32"
      y not in @i32_min..@i32_max -> "y #{y} is outside i32"
      true -> "an unknown field is out of range"
    end
  end

  defp out_of_range({:ownership, entity, region, epoch}) do
    cond do
      entity not in 0..@u64 -> "entity #{entity} exceeds u64"
      region not in 0..@u32 -> "region #{region} exceeds u32"
      epoch not in 0..@u64 -> "epoch #{epoch} exceeds u64"
      true -> "an unknown field is out of range"
    end
  end

  defp out_of_range({:transfer, transfer, _transition, from, to}) do
    cond do
      transfer not in 0..@u64 -> "transfer id #{transfer} exceeds u64"
      from not in 0..@u32 -> "source region #{from} exceeds u32"
      to not in 0..@u32 -> "destination region #{to} exceeds u32"
      true -> "an unknown field is out of range"
    end
  end

  defp out_of_range(_), do: "it is not a record this version knows"

  @doc "The inclusive bounds of each field, so a caller can check before it builds a record."
  def bounds do
    %{
      topology_version: 0..@u64,
      world_space: 0..@u128,
      coordinate: @i32_min..@i32_max,
      entity: 0..@u64,
      region: 0..@u32,
      epoch: 0..@u64,
      transfer: 0..@u64
    }
  end

  @doc """
  Decode exactly these bytes, or say why not.

  Length is checked against the record the discriminant names before any field is read, so a
  truncated record cannot be reported as a malformed one.
  """
  @spec decode(binary()) :: {:ok, record()} | {:error, error()}
  def decode(<<>>), do: {:error, {:truncated, 1, 0}}

  def decode(<<discriminant::unsigned-8, _::binary>> = bytes) do
    case expected_size(discriminant) do
      {:ok, expected} -> decode_sized(bytes, expected, discriminant)
      :error -> {:error, {:unknown_record, discriminant}}
    end
  end

  defp expected_size(@position), do: {:ok, 33}
  defp expected_size(@ownership), do: {:ok, 21}
  defp expected_size(@transfer), do: {:ok, 18}
  defp expected_size(_), do: :error

  defp decode_sized(bytes, expected, discriminant) do
    found = byte_size(bytes)

    cond do
      found < expected -> {:error, {:truncated, expected, found}}
      found > expected -> {:error, {:oversized, expected, found}}
      true -> decode_body(discriminant, bytes)
    end
  end

  defp decode_body(
         @position,
         <<_::unsigned-8, version::little-unsigned-64, space::little-unsigned-128, x::little-signed-32,
           y::little-signed-32>>
       ) do
    {:ok, {:position, version, space, x, y}}
  end

  defp decode_body(
         @ownership,
         <<_::unsigned-8, entity::little-unsigned-64, region::little-unsigned-32, epoch::little-unsigned-64>>
       ) do
    {:ok, {:ownership, entity, region, epoch}}
  end

  defp decode_body(
         @transfer,
         <<_::unsigned-8, transfer::little-unsigned-64, transition::unsigned-8, from::little-unsigned-32,
           to::little-unsigned-32>>
       ) do
    case transition_name(transition) do
      {:ok, name} -> {:ok, {:transfer, transfer, name, from, to}}
      :error -> {:error, {:unknown_transition, transition}}
    end
  end

  defp transition_byte(:seam), do: @seam
  defp transition_byte(:door), do: @door
  defp transition_byte(:portal), do: @portal
  defp transition_byte(:teleport), do: @teleport
  defp transition_byte(:instance), do: @instance

  defp transition_name(@seam), do: {:ok, :seam}
  defp transition_name(@door), do: {:ok, :door}
  defp transition_name(@portal), do: {:ok, :portal}
  defp transition_name(@teleport), do: {:ok, :teleport}
  defp transition_name(@instance), do: {:ok, :instance}
  # Zero included: an uninitialised byte is not the most permissive kind.
  defp transition_name(_), do: :error
end
