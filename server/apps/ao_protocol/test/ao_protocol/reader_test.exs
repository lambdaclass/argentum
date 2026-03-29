defmodule AoProtocol.ReaderTest do
  use ExUnit.Case, async: true

  alias AoProtocol.Reader

  describe "read_int8/1" do
    test "reads unsigned byte" do
      assert {:ok, 42, <<99>>} = Reader.read_int8(<<42, 99>>)
      assert {:ok, 255, <<>>} = Reader.read_int8(<<255>>)
    end

    test "returns incomplete on empty" do
      assert :incomplete = Reader.read_int8(<<>>)
    end
  end

  describe "read_int16/1" do
    test "reads little-endian signed 16-bit" do
      assert {:ok, 1, <<>>} = Reader.read_int16(<<1, 0>>)
      assert {:ok, 256, <<>>} = Reader.read_int16(<<0, 1>>)
      assert {:ok, -1, <<>>} = Reader.read_int16(<<0xFF, 0xFF>>)
    end

    test "returns incomplete on insufficient data" do
      assert :incomplete = Reader.read_int16(<<1>>)
      assert :incomplete = Reader.read_int16(<<>>)
    end
  end

  describe "read_int32/1" do
    test "reads little-endian signed 32-bit" do
      assert {:ok, 1, <<>>} = Reader.read_int32(<<1, 0, 0, 0>>)
      assert {:ok, -1, <<>>} = Reader.read_int32(<<0xFF, 0xFF, 0xFF, 0xFF>>)
    end

    test "returns incomplete on insufficient data" do
      assert :incomplete = Reader.read_int32(<<1, 0, 0>>)
    end
  end

  describe "read_bool/1" do
    test "reads VB6 boolean" do
      assert {:ok, false, <<>>} = Reader.read_bool(<<0>>)
      assert {:ok, true, <<>>} = Reader.read_bool(<<1>>)
      # Any non-zero is true in VB6
      assert {:ok, true, <<>>} = Reader.read_bool(<<0xFF>>)
    end
  end

  describe "read_real32/1" do
    test "reads IEEE 754 float little-endian" do
      assert {:ok, 1.0, <<>>} = Reader.read_real32(<<0, 0, 128, 63>>)
    end
  end

  describe "read_string8/1" do
    test "reads Int16-length-prefixed string" do
      # "Hi" = <<2, 0, 72, 105>>
      assert {:ok, "Hi", <<>>} = Reader.read_string8(<<2, 0, 72, 105>>)
    end

    test "reads empty string" do
      assert {:ok, "", <<99>>} = Reader.read_string8(<<0, 0, 99>>)
    end

    test "preserves remaining data" do
      assert {:ok, "AB", <<0xFF>>} = Reader.read_string8(<<2, 0, 65, 66, 0xFF>>)
    end

    test "returns incomplete when string data is truncated" do
      # Says 5 bytes but only 3 available
      assert :incomplete = Reader.read_string8(<<5, 0, 65, 66, 67>>)
    end

    test "returns incomplete on insufficient header" do
      assert :incomplete = Reader.read_string8(<<2>>)
      assert :incomplete = Reader.read_string8(<<>>)
    end
  end

  describe "read_packet_id/1" do
    test "reads Int16 packet ID" do
      # Packet ID 73 (eLoginExistingChar)
      assert {:ok, 73, <<1, 2, 3>>} = Reader.read_packet_id(<<73, 0, 1, 2, 3>>)
    end
  end

  describe "roundtrip writer/reader" do
    alias AoProtocol.Writer

    test "int8 roundtrips" do
      for v <- [0, 1, 127, 255] do
        assert {:ok, ^v, <<>>} = Reader.read_int8(Writer.write_int8(v))
      end
    end

    test "int16 roundtrips" do
      for v <- [0, 1, -1, 256, -32768, 32767] do
        assert {:ok, ^v, <<>>} = Reader.read_int16(Writer.write_int16(v))
      end
    end

    test "int32 roundtrips" do
      for v <- [0, 1, -1, 100_000, -100_000] do
        assert {:ok, ^v, <<>>} = Reader.read_int32(Writer.write_int32(v))
      end
    end

    test "string8 roundtrips" do
      for s <- ["", "a", "Hello World", String.duplicate("x", 300)] do
        assert {:ok, ^s, <<>>} = Reader.read_string8(Writer.write_string8(s))
      end
    end

    test "bool roundtrips" do
      assert {:ok, false, <<>>} = Reader.read_bool(Writer.write_bool(false))
      assert {:ok, true, <<>>} = Reader.read_bool(Writer.write_bool(true))
    end
  end
end
