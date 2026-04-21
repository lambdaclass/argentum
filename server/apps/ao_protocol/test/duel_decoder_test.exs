defmodule AoProtocol.DuelDecoderTest do
  @moduledoc """
  Tests for binary duel packet decoding (drift #3).

  VB6 reference:
    * PacketId.bas:454-457 — `eDuel`, `eAcceptDuel`, `eCancelDuel`, `eQuitDuel`.
      Derived enum ids (from `eMinPacket` = 0): 218, 219, 220, 221 respectively.
    * Protocol.bas:5931-5981 — `HandleDuel`, `HandleAcceptDuel`,
      `HandleCancelDuel`, `HandleQuitDuel`.

  Payloads (read in order by the VB6 handlers):
    * eDuel        — target_username(String8) + bet(Int32) +
                     pociones_maximas(Int16) + caen_items(Bool/Int8).
    * eAcceptDuel  — target_username(String8).
    * eCancelDuel  — padding Int16 (client-specific filler; discarded).
    * eQuitDuel    — no payload.
  """

  use ExUnit.Case, async: true

  alias AoProtocol.Client.Decoder
  alias AoProtocol.Writer

  @eDuel 218
  @eAcceptDuel 219
  @eCancelDuel 220
  @eQuitDuel 221

  defp packet(id, payload), do: <<id::little-signed-16>> <> payload

  describe "eDuel (ID 218)" do
    test "decodes target_username, bet, pociones_maximas, caen_items" do
      payload =
        Writer.write_string8("Shilien") <>
          Writer.write_int32(5000) <>
          Writer.write_int16(20) <>
          Writer.write_bool(true)

      raw = packet(@eDuel, payload)

      assert {:ok,
              {:duel,
               %{
                 target_username: "Shilien",
                 bet: 5000,
                 pociones_maximas: 20,
                 caen_items: true
               }}, <<>>} = Decoder.decode(raw)
    end

    test "decodes caen_items=false" do
      payload =
        Writer.write_string8("Zaphyr") <>
          Writer.write_int32(100) <>
          Writer.write_int16(0) <>
          Writer.write_bool(false)

      raw = packet(@eDuel, payload)

      assert {:ok,
              {:duel,
               %{
                 target_username: "Zaphyr",
                 bet: 100,
                 pociones_maximas: 0,
                 caen_items: false
               }}, <<>>} = Decoder.decode(raw)
    end

    test "returns incomplete for short payload" do
      # Missing pociones_maximas and caen_items
      payload = Writer.write_string8("Ami") <> Writer.write_int32(1)
      raw = packet(@eDuel, payload)
      assert :incomplete = Decoder.decode(raw)
    end
  end

  describe "eAcceptDuel (ID 219)" do
    test "decodes target_username" do
      payload = Writer.write_string8("Challenger")
      raw = packet(@eAcceptDuel, payload)

      assert {:ok, {:accept_duel, %{target_username: "Challenger"}}, <<>>} =
               Decoder.decode(raw)
    end

    test "returns incomplete when string is truncated" do
      # length 10 but only 3 bytes follow
      raw = packet(@eAcceptDuel, <<10::little-signed-16, "abc">>)
      assert :incomplete = Decoder.decode(raw)
    end
  end

  describe "eCancelDuel (ID 220)" do
    test "decodes as an empty command (padding Int16 is consumed)" do
      payload = Writer.write_int16(0)
      raw = packet(@eCancelDuel, payload)

      assert {:ok, {:cancel_duel, %{}}, <<>>} = Decoder.decode(raw)
    end

    test "preserves trailing data after padding Int16" do
      payload = Writer.write_int16(0) <> <<0xAA>>
      raw = packet(@eCancelDuel, payload)

      assert {:ok, {:cancel_duel, %{}}, <<0xAA>>} = Decoder.decode(raw)
    end
  end

  describe "eQuitDuel (ID 221)" do
    test "decodes with no payload" do
      raw = packet(@eQuitDuel, <<>>)
      assert {:ok, {:quit_duel, %{}}, <<>>} = Decoder.decode(raw)
    end

    test "preserves trailing data" do
      raw = packet(@eQuitDuel, <<0xBB, 0xCC>>)
      assert {:ok, {:quit_duel, %{}}, <<0xBB, 0xCC>>} = Decoder.decode(raw)
    end
  end
end
