defmodule AoProtocol.ChatColorDecoderTest do
  @moduledoc """
  Tests for /CHATCOLOR packet decoding (VB6: eChatColor, PacketId.bas:438).

  VB6 parity (Protocol.bas:5548-5561 HandleChatColor):
    Color = RGB(reader.ReadInt8(), reader.ReadInt8(), reader.ReadInt8())

  Three Int8 bytes in order R, G, B.
  """
  use ExUnit.Case, async: true

  alias AoProtocol.Client.Decoder
  alias AoProtocol.Writer

  # eChatColor ID = 421 (ClientPacketID enum, see PacketId.bas:438).
  @chat_color_id 421

  defp packet(id, payload), do: <<id::little-signed-16>> <> payload

  describe "eChatColor (ID 421)" do
    test "decodes three Int8 bytes as R, G, B" do
      raw =
        packet(
          @chat_color_id,
          Writer.write_int8(252) <> Writer.write_int8(195) <> Writer.write_int8(0)
        )

      assert {:ok, {:chat_color, %{r: 252, g: 195, b: 0}}, <<>>} = Decoder.decode(raw)
    end

    test "decodes white (255,255,255)" do
      raw =
        packet(
          @chat_color_id,
          Writer.write_int8(255) <> Writer.write_int8(255) <> Writer.write_int8(255)
        )

      assert {:ok, {:chat_color, %{r: 255, g: 255, b: 255}}, <<>>} = Decoder.decode(raw)
    end

    test "preserves trailing data" do
      raw =
        packet(
          @chat_color_id,
          Writer.write_int8(10) <> Writer.write_int8(20) <> Writer.write_int8(30) <> <<0xAB>>
        )

      assert {:ok, {:chat_color, %{r: 10, g: 20, b: 30}}, <<0xAB>>} = Decoder.decode(raw)
    end

    test "returns incomplete when payload is short" do
      raw = packet(@chat_color_id, <<1, 2>>)
      assert :incomplete = Decoder.decode(raw)
    end
  end
end
