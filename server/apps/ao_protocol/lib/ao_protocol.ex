defmodule AoProtocol do
  @moduledoc """
  Argentum Online binary packet codec.

  Wire format:
  - All integers are little-endian
  - Packet structure: [Int16 packet_id][fields...]
  - No length prefix at the packet level — schema-driven parsing
  - Strings: [Int32 byte_length][UTF-8 bytes][null terminator]

  Types:
  - Int8:    1 byte unsigned
  - Int16:   2 bytes little-endian signed
  - Int32:   4 bytes little-endian signed
  - Bool:    1 byte (0 = false)
  - Real32:  4 bytes IEEE 754 float little-endian
  - String8: Int32 length + UTF-8 bytes + null terminator
  """
end
