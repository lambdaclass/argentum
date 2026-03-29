defmodule AoProtocol.Writer do
  @moduledoc """
  Binary writer for AO packets. All integers are little-endian.
  """

  @doc "Write an unsigned 8-bit integer."
  def write_int8(value), do: <<value::unsigned-integer-8>>

  @doc "Write a signed 16-bit little-endian integer."
  def write_int16(value), do: <<value::little-signed-integer-16>>

  @doc "Write a signed 32-bit little-endian integer."
  def write_int32(value), do: <<value::little-signed-integer-32>>

  @doc "Write a boolean (1 byte)."
  def write_bool(true), do: <<1>>
  def write_bool(false), do: <<0>>

  @doc "Write a 32-bit IEEE 754 float, little-endian."
  def write_real32(value), do: <<value::little-float-32>>

  @doc "Write an Int16-length-prefixed string (AO20 wire format)."
  def write_string8(str) when is_binary(str) do
    len = byte_size(str)
    <<len::little-signed-integer-16, str::binary>>
  end

  @doc "Build a complete packet: Int16 packet_id followed by payload."
  def build_packet(packet_id, payload) when is_integer(packet_id) and is_binary(payload) do
    <<packet_id::little-signed-integer-16, payload::binary>>
  end
end
