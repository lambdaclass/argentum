defmodule AoProtocol.EncoderDrift19Test do
  @moduledoc """
  Drift #19: Six outbound encoders ported from VB6 that were previously missing
  from `AoProtocol.Server.Encoder`.

  VB6 references (old/server/Codigo/):
    * PacketId.bas:83  — eWorkRequestTarget = 62
    * PacketId.bas:93  — eRestOK           = 72
    * PacketId.bas:106 — eBlindNoMore      = 85
    * PacketId.bas:107 — eDumbNoMore       = 86
    * PacketId.bas:118 — eParalizeOK       = 97
    * PacketId.bas:119 — eStunStart        = 98

  Protocol_Writes.bas bodies:
    * WriteWorkRequestTarget — id + Int8 Skill + Bool CasteaArea + Int8 Radio
    * WriteRestOK            — id only (no payload)
    * WriteBlindNoMore       — id only (no payload)
    * WriteDumbNoMore        — id only (no payload)
    * WriteParalizeOK        — id only (no payload)
    * WriteStunStart         — id + Int16 Duration
  """
  use ExUnit.Case, async: true

  alias AoProtocol.Server.Encoder

  describe "eParalizeOK (ID 97) encode" do
    test "encodes empty body" do
      assert Encoder.encode({:paralize_ok, %{}}) == <<97::little-signed-16>>
    end
  end

  describe "eBlindNoMore (ID 85) encode" do
    test "encodes empty body" do
      assert Encoder.encode({:blind_no_more, %{}}) == <<85::little-signed-16>>
    end
  end

  describe "eDumbNoMore (ID 86) encode" do
    test "encodes empty body" do
      assert Encoder.encode({:dumb_no_more, %{}}) == <<86::little-signed-16>>
    end
  end

  describe "eRestOK (ID 72) encode" do
    test "encodes empty body" do
      assert Encoder.encode({:rest_ok, %{}}) == <<72::little-signed-16>>
    end
  end

  describe "eWorkRequestTarget (ID 62) encode" do
    test "encodes skill with default CasteaArea=false, Radio=0" do
      packet = Encoder.encode({:work_request_target, %{skill: 7}})

      assert packet ==
               <<62::little-signed-16>> <> <<7::unsigned-8>> <> <<0>> <> <<0::unsigned-8>>
    end

    test "encodes area cast with radius" do
      packet =
        Encoder.encode(
          {:work_request_target, %{skill: 10, castea_area: true, radio: 3}}
        )

      assert packet ==
               <<62::little-signed-16>> <> <<10::unsigned-8>> <> <<1>> <> <<3::unsigned-8>>
    end

    test "defaults skill to 0 when unspecified" do
      packet = Encoder.encode({:work_request_target, %{}})

      assert packet ==
               <<62::little-signed-16>> <> <<0::unsigned-8>> <> <<0>> <> <<0::unsigned-8>>
    end
  end

  describe "eStunStart (ID 98) encode" do
    test "encodes stun duration as Int16" do
      assert Encoder.encode({:stun_start, %{duration: 3000}}) ==
               <<98::little-signed-16, 3000::little-signed-16>>
    end

    test "defaults duration to 0" do
      assert Encoder.encode({:stun_start, %{}}) ==
               <<98::little-signed-16, 0::little-signed-16>>
    end
  end
end
