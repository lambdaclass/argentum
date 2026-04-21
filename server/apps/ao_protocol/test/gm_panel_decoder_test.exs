defmodule AoProtocol.GmPanelDecoderTest do
  @moduledoc """
  Tests for /PANELGM packet decoding (VB6: eGMPanel, PacketId.bas:351).

  VB6 parity (Protocol_GmCommands.bas:764 HandleGMPanel):
    Reads only the packet id — no payload bytes.
  """
  use ExUnit.Case, async: true

  alias AoProtocol.Client.Decoder

  # eGMPanel ID = 116 (ClientPacketID enum, see PacketId.bas:351).
  @gm_panel_id 116

  defp packet(id, payload), do: <<id::little-signed-16>> <> payload

  describe "eGMPanel (ID 116)" do
    test "decodes with no payload to {:gm_panel_request, %{}}" do
      raw = packet(@gm_panel_id, <<>>)
      assert {:ok, {:gm_panel_request, %{}}, <<>>} = Decoder.decode(raw)
    end

    test "preserves trailing data after an empty payload" do
      raw = packet(@gm_panel_id, <<0xAA, 0xBB>>)
      assert {:ok, {:gm_panel_request, %{}}, <<0xAA, 0xBB>>} = Decoder.decode(raw)
    end
  end
end
