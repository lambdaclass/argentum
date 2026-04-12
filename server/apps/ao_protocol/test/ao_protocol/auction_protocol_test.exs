defmodule AoProtocol.AuctionProtocolTest do
  @moduledoc """
  Tests for auction packet decoding (VB6: eOfertaInicial, eOfertaDeSubasta, eSubastaInfo).
  """
  use ExUnit.Case, async: true

  alias AoProtocol.Client.Decoder
  alias AoProtocol.Writer

  # Helper: build a raw packet with a 16-bit LE packet_id prefix.
  defp packet(id, payload), do: <<id::little-signed-16>> <> payload

  describe "eOfertaInicial (ID 213)" do
    test "decodes amount" do
      raw = packet(213, Writer.write_int32(5000))
      assert {:ok, {:oferta_inicial, %{amount: 5000}}, <<>>} = Decoder.decode(raw)
    end

    test "decodes with trailing data" do
      raw = packet(213, Writer.write_int32(1000) <> <<0xFF>>)
      assert {:ok, {:oferta_inicial, %{amount: 1000}}, <<0xFF>>} = Decoder.decode(raw)
    end

    test "returns incomplete when data is short" do
      raw = packet(213, <<1, 2>>)
      assert :incomplete = Decoder.decode(raw)
    end
  end

  describe "eOfertaDeSubasta (ID 214)" do
    test "decodes amount" do
      raw = packet(214, Writer.write_int32(7500))
      assert {:ok, {:oferta_de_subasta, %{amount: 7500}}, <<>>} = Decoder.decode(raw)
    end

    test "returns incomplete when payload missing" do
      raw = packet(214, <<>>)
      assert :incomplete = Decoder.decode(raw)
    end
  end

  describe "eSubastaInfo (ID 240)" do
    test "decodes with no payload" do
      raw = packet(240, <<>>)
      assert {:ok, {:subasta_info, %{}}, <<>>} = Decoder.decode(raw)
    end

    test "preserves trailing data" do
      raw = packet(240, <<0xAB, 0xCD>>)
      assert {:ok, {:subasta_info, %{}}, <<0xAB, 0xCD>>} = Decoder.decode(raw)
    end
  end
end
