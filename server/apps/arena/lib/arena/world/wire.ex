defmodule Arena.World.Wire do
  @moduledoc """
  The bytes that cross the boundary, as the server encodes and decodes them.

  The specification is `client-rs/crates/ao-core/fixtures/wire_contract.txt`: semantic values
  beside the exact bytes they must become, with the hexadecimal produced by a third
  implementation rather than by either codec. Neither this module nor `ao_core::wire` defines
  the answers, and neither can pass by reproducing its own mistake — which is how two
  languages come to hold different beliefs about one field while both test suites stay green.

  Three records, little-endian, each behind a one-byte discriminant:

      1 position  : topology_version u32, space u32, x i32, y i32          17 bytes
      2 ownership : entity u64, region u32, epoch u64                      21 bytes
      3 transfer  : transfer u64, transition u8, from_region u32, to u32   18 bytes

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

  @seam 1
  @door 2
  @portal 3
  @teleport 4
  @instance 5

  @type transition :: :seam | :door | :portal | :teleport | :instance

  @type record ::
          {:position, version :: non_neg_integer(), space :: non_neg_integer(), x :: integer(),
           y :: integer()}
          | {:ownership, entity :: non_neg_integer(), region :: non_neg_integer(),
             epoch :: non_neg_integer()}
          | {:transfer, transfer :: non_neg_integer(), transition(), from :: non_neg_integer(),
             to :: non_neg_integer()}

  @type error ::
          {:truncated, needed :: non_neg_integer(), found :: non_neg_integer()}
          | {:oversized, expected :: non_neg_integer(), found :: non_neg_integer()}
          | {:unknown_record, byte :: non_neg_integer()}
          | {:unknown_transition, byte :: non_neg_integer()}

  @doc "The encoded length of a record, including its discriminant."
  @spec byte_size_of(record()) :: pos_integer()
  def byte_size_of({:position, _, _, _, _}), do: 17
  def byte_size_of({:ownership, _, _, _}), do: 21
  def byte_size_of({:transfer, _, _, _, _}), do: 18

  @doc "Encode a record."
  @spec encode(record()) :: binary()
  def encode({:position, version, space, x, y}) do
    <<@position::unsigned-8, version::little-unsigned-32, space::little-unsigned-32,
      x::little-signed-32, y::little-signed-32>>
  end

  def encode({:ownership, entity, region, epoch}) do
    <<@ownership::unsigned-8, entity::little-unsigned-64, region::little-unsigned-32,
      epoch::little-unsigned-64>>
  end

  def encode({:transfer, transfer, transition, from, to}) do
    <<@transfer::unsigned-8, transfer::little-unsigned-64, transition_byte(transition)::unsigned-8,
      from::little-unsigned-32, to::little-unsigned-32>>
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

  defp expected_size(@position), do: {:ok, 17}
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

  defp decode_body(@position, <<_::unsigned-8, version::little-unsigned-32,
         space::little-unsigned-32, x::little-signed-32, y::little-signed-32>>) do
    {:ok, {:position, version, space, x, y}}
  end

  defp decode_body(@ownership, <<_::unsigned-8, entity::little-unsigned-64,
         region::little-unsigned-32, epoch::little-unsigned-64>>) do
    {:ok, {:ownership, entity, region, epoch}}
  end

  defp decode_body(@transfer, <<_::unsigned-8, transfer::little-unsigned-64,
         transition::unsigned-8, from::little-unsigned-32, to::little-unsigned-32>>) do
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
