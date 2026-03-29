defmodule AoProtocol.Reader do
  @moduledoc """
  Binary reader for AO packets. All integers are little-endian.
  """

  @doc "Read an unsigned 8-bit integer."
  def read_int8(<<value::unsigned-integer-8, rest::binary>>), do: {:ok, value, rest}
  def read_int8(_), do: :incomplete

  @doc "Read a signed 16-bit little-endian integer."
  def read_int16(<<value::little-signed-integer-16, rest::binary>>), do: {:ok, value, rest}
  def read_int16(_), do: :incomplete

  @doc "Read a signed 32-bit little-endian integer."
  def read_int32(<<value::little-signed-integer-32, rest::binary>>), do: {:ok, value, rest}
  def read_int32(_), do: :incomplete

  @doc "Read a boolean (1 byte, 0 = false)."
  def read_bool(<<0, rest::binary>>), do: {:ok, false, rest}
  def read_bool(<<_, rest::binary>>), do: {:ok, true, rest}
  def read_bool(_), do: :incomplete

  @doc "Read a 32-bit IEEE 754 float, little-endian."
  def read_real32(<<value::little-float-32, rest::binary>>), do: {:ok, value, rest}
  def read_real32(_), do: :incomplete

  @doc "Read an Int16-length-prefixed string (AO20 wire format)."
  def read_string8(<<len::little-signed-integer-16, rest::binary>>) when len >= 0 do
    case rest do
      <<str::binary-size(len), rest2::binary>> ->
        {:ok, str, rest2}

      _ ->
        :incomplete
    end
  end

  def read_string8(_), do: :incomplete

  @doc "Read the packet ID (Int16) from the start of a buffer."
  def read_packet_id(data), do: read_int16(data)
end
