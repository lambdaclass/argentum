defmodule AoProtocol.WriterTest do
  use ExUnit.Case, async: true

  alias AoProtocol.Writer

  describe "write_int8/1" do
    test "encodes unsigned byte" do
      assert Writer.write_int8(0) == <<0>>
      assert Writer.write_int8(255) == <<255>>
      assert Writer.write_int8(42) == <<42>>
    end
  end

  describe "write_int16/1" do
    test "encodes little-endian signed 16-bit" do
      # 1 = 0x0001 LE = <<1, 0>>
      assert Writer.write_int16(1) == <<1, 0>>
      # 256 = 0x0100 LE = <<0, 1>>
      assert Writer.write_int16(256) == <<0, 1>>
      # -1 = 0xFFFF LE = <<0xFF, 0xFF>>
      assert Writer.write_int16(-1) == <<0xFF, 0xFF>>
      assert Writer.write_int16(0) == <<0, 0>>
    end
  end

  describe "write_int32/1" do
    test "encodes little-endian signed 32-bit" do
      assert Writer.write_int32(1) == <<1, 0, 0, 0>>
      assert Writer.write_int32(0x01020304) == <<4, 3, 2, 1>>
      assert Writer.write_int32(-1) == <<0xFF, 0xFF, 0xFF, 0xFF>>
    end
  end

  describe "write_bool/1" do
    test "encodes boolean as single byte" do
      # VB6 Boolean: False = 0x00, True = 0x01
      assert Writer.write_bool(false) == <<0>>
      assert Writer.write_bool(true) == <<1>>
    end
  end

  describe "write_real32/1" do
    test "encodes IEEE 754 float little-endian" do
      # 1.0 as IEEE 754 = 0x3F800000 LE = <<0, 0, 128, 63>>
      assert Writer.write_real32(1.0) == <<0, 0, 128, 63>>
    end
  end

  describe "write_string8/1" do
    test "encodes with Int16 length prefix, no null terminator" do
      # AO20 string format: Int16(len) + bytes
      # "Hi" = len=2 -> <<2, 0, 72, 105>>
      assert Writer.write_string8("Hi") == <<2, 0, 72, 105>>
    end

    test "empty string" do
      assert Writer.write_string8("") == <<0, 0>>
    end

    test "longer string" do
      str = "Ullathorpe"
      expected = <<10, 0>> <> str
      assert Writer.write_string8(str) == expected
    end
  end

  describe "build_packet/2" do
    test "prefixes payload with Int16 packet ID" do
      # Packet ID 30 (eChangeMap) = <<30, 0>> + payload
      payload = <<1, 0, 5, 0>>
      assert Writer.build_packet(30, payload) == <<30, 0, 1, 0, 5, 0>>
    end
  end
end
