defmodule Arena.World.WireContractTest do
  @moduledoc """
  The server's half of the wire contract.

  Reads the same golden fixture `ao_core::wire` reads. Both sides must encode each semantic
  case to exactly the stated bytes, decode those bytes back to the value, and refuse every
  rejection for the stated reason. The hexadecimal was produced by a third implementation, so
  agreement here is agreement with the specification rather than with each other.
  """
  use ExUnit.Case, async: true

  alias Arena.World.Wire

  @contract Path.join([
              __DIR__,
              "..",
              "..",
              "..",
              "..",
              "client-rs",
              "crates",
              "ao-core",
              "fixtures",
              "wire_contract.txt"
            ])

  defp lines do
    @contract
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp bytes_of(hex) do
    hex
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&String.to_integer(&1, 16))
    |> :erlang.list_to_binary()
  end

  # Mapped explicitly, never `to_existing_atom`. An atom exists only once some loaded module
  # mentions it, so parsing external data that way passes or fails depending on which test ran
  # first -- this exact test passed in isolation and failed in the full suite.
  defp transition_named("seam"), do: :seam
  defp transition_named("door"), do: :door
  defp transition_named("portal"), do: :portal
  defp transition_named("teleport"), do: :teleport
  defp transition_named("instance"), do: :instance

  defp semantic_cases do
    for line <- lines(), not String.starts_with?(line, "reject") do
      [semantic, hex] = String.split(line, "=", parts: 2)
      fields = String.split(String.trim(semantic), ~r/\s+/)

      record =
        case fields do
          ["position", version, space, x, y] ->
            {:position, String.to_integer(version), String.to_integer(space),
             String.to_integer(x), String.to_integer(y)}

          ["ownership", entity, region, epoch] ->
            {:ownership, String.to_integer(entity), String.to_integer(region),
             String.to_integer(epoch)}

          ["transfer", transfer, transition, from, to] ->
            {:transfer, String.to_integer(transfer), transition_named(transition),
             String.to_integer(from), String.to_integer(to)}
        end

      {line, record, bytes_of(hex)}
    end
  end

  defp rejection_cases do
    for line <- lines(), String.starts_with?(line, "reject") do
      rest = String.replace_prefix(line, "reject ", "")
      {hex, reason} = rest |> String.split(~r/\s+/) |> Enum.split(-1)
      {line, bytes_of(Enum.join(hex, " ")), hd(reason)}
    end
  end

  test "the contract is present and covers a real spread" do
    cases = semantic_cases()
    rejections = rejection_cases()

    assert length(cases) >= 18, "expected a real contract, got #{length(cases)} cases"
    assert length(rejections) >= 8, "expected real rejections, got #{length(rejections)}"

    kinds = cases |> Enum.map(&elem(elem(&1, 1), 0)) |> Enum.uniq() |> Enum.sort()
    assert kinds == [:ownership, :position, :transfer]
  end

  test "every case encodes to exactly the bytes the contract states" do
    for {line, record, expected} <- semantic_cases() do
      assert Wire.encode(record) == expected, line
      assert Wire.byte_size_of(record) == byte_size(expected), line
    end
  end

  test "every case decodes back to the value the contract names" do
    for {line, record, bytes} <- semantic_cases() do
      assert Wire.decode(bytes) == {:ok, record}, line
    end
  end

  test "every rejection is refused for the reason the contract states" do
    for {line, bytes, reason} <- rejection_cases() do
      assert {:error, error} = Wire.decode(bytes), line

      case reason do
        "truncated" -> assert match?({:truncated, _, _}, error), "#{line} gave #{inspect(error)}"
        "oversized" -> assert match?({:oversized, _, _}, error), "#{line} gave #{inspect(error)}"
        "unknown-record" -> assert match?({:unknown_record, _}, error), "#{line} gave #{inspect(error)}"
        "unknown-transition" -> assert match?({:unknown_transition, _}, error), "#{line} gave #{inspect(error)}"
      end
    end
  end

  describe "properties the fixture cannot enumerate" do
    test "a zero transition byte is not a seam" do
      bytes = Wire.encode({:transfer, 9, :seam, 330, 269})
      assert :binary.at(bytes, 9) == 1, "seam is 1, so zero is free to mean nothing"

      zeroed = :binary.part(bytes, 0, 9) <> <<0>> <> :binary.part(bytes, 10, byte_size(bytes) - 10)
      assert Wire.decode(zeroed) == {:error, {:unknown_transition, 0}}
    end

    test "every prefix of a valid record is refused, and so is every record with a byte added" do
      for record <- [
            {:position, 1, 199, 221, 214},
            {:ownership, 7, 330, 3},
            {:transfer, 9, :seam, 330, 269}
          ] do
        bytes = Wire.encode(record)

        for shorter <- 0..(byte_size(bytes) - 1) do
          prefix = :binary.part(bytes, 0, shorter)
          assert {:error, {:truncated, _, _}} = Wire.decode(prefix), "#{shorter} bytes"
        end

        assert {:error, {:oversized, _, _}} = Wire.decode(bytes <> <<0>>)
      end
    end

    test "negative coordinates survive as negative coordinates" do
      record = {:position, 3, 199, -1, -1406}
      bytes = Wire.encode(record)
      assert :binary.part(bytes, 21, 4) == <<0xFF, 0xFF, 0xFF, 0xFF>>
      assert Wire.decode(bytes) == {:ok, record}
    end

    test "a runtime instance space id survives that a 32-bit field would truncate" do
      # Three spaces that differ only above bit 32. A narrower field would encode all three
      # identically and put three parties in one place.
      a = Wire.encode({:position, 1, 4_294_967_296, 10, 20})
      b = Wire.encode({:position, 1, 8_589_934_592, 10, 20})
      c = Wire.encode({:position, 1, 0, 10, 20})

      assert a != b
      assert a != c
      assert {:ok, {:position, 1, 4_294_967_296, 10, 20}} = Wire.decode(a)
    end

    test "transposing two fields of equal width changes the bytes" do
      # Why the contract carries the 1/2/3/4 cases: both pairs are the same width, so a
      # swapped implementation would round-trip its own mistake.
      refute Wire.encode({:position, 1, 2, 3, 4}) == Wire.encode({:position, 2, 1, 3, 4})
      refute Wire.encode({:position, 1, 2, 3, 4}) == Wire.encode({:position, 1, 2, 4, 3})
      refute Wire.encode({:ownership, 1, 2, 3}) == Wire.encode({:ownership, 3, 2, 1})
      refute Wire.encode({:transfer, 1, :seam, 2, 3}) == Wire.encode({:transfer, 1, :seam, 3, 2})
    end

    test "boundaries round-trip without saturating" do
      max_u32 = 4_294_967_295
      max_u64 = 18_446_744_073_709_551_615
      max_u128 = 340_282_366_920_938_463_463_374_607_431_768_211_455

      for record <- [
            {:position, max_u32, max_u128, -2_147_483_648, 2_147_483_647},
            {:position, 1, 4_294_967_296, 10, 20},
            {:ownership, max_u64, max_u32, max_u64},
            {:transfer, max_u64, :instance, 0, max_u32}
          ] do
        assert Wire.decode(Wire.encode(record)) == {:ok, record}
      end
    end

    test "one past every field's range is refused rather than truncated" do
      # Codex review, 2026-08-23: Elixir integers are unbounded and bit syntax keeps only the
      # low bits, so every one of these silently encoded as a *different* record. `space =
      # 2^128` produced the bytes of `space = 0` -- an identity collision that no test caught,
      # because the tests stopped at each maximum and never tried maximum-plus-one.
      u32 = 4_294_967_296
      u64 = 18_446_744_073_709_551_616
      u128 = 340_282_366_920_938_463_463_374_607_431_768_211_456

      for record <- [
            {:position, u32, 1, 0, 0},
            {:position, 1, u128, 0, 0},
            {:position, 1, 1, 2_147_483_648, 0},
            {:position, 1, 1, 0, -2_147_483_649},
            {:position, 1, -1, 0, 0},
            {:ownership, u64, 1, 1},
            {:ownership, 1, u32, 1},
            {:ownership, 1, 1, u64},
            {:transfer, u64, :seam, 1, 1},
            {:transfer, 1, :seam, u32, 1},
            {:transfer, 1, :seam, 1, u32}
          ] do
        assert_raise ArgumentError, fn -> Wire.encode(record) end
      end

      # And the maximum itself still encodes, so the bound is inclusive rather than off by one.
      assert Wire.decode(Wire.encode({:position, u32 - 1, u128 - 1, 2_147_483_647, -2_147_483_648})) ==
               {:ok, {:position, u32 - 1, u128 - 1, 2_147_483_647, -2_147_483_648}}

      assert Wire.decode(Wire.encode({:ownership, u64 - 1, u32 - 1, u64 - 1})) ==
               {:ok, {:ownership, u64 - 1, u32 - 1, u64 - 1}}
    end

    test "the declared bounds are the ones the encoder enforces" do
      bounds = Wire.bounds()
      assert bounds.world_space.last == 340_282_366_920_938_463_463_374_607_431_768_211_455
      assert bounds.coordinate.first == -2_147_483_648
      assert bounds.entity.last == 18_446_744_073_709_551_615
      assert bounds.region.last == 4_294_967_295
    end

    test "an unknown record names the discriminant it did not know" do
      for discriminant <- [0, 4, 9, 255] do
        bytes = :binary.copy(<<discriminant>>, 21)
        assert Wire.decode(bytes) == {:error, {:unknown_record, discriminant}}
      end
    end
  end
end
