# Script to generate synthetic .bin fixtures.
# Run with: mix run apps/ao_tcp_gateway/test/generate_synthetic_fixture.exs

alias AoProtocol.Writer

token = "test_token"
name = "FixtureBot_1"
md5 = "abcdef1234567890abcdef1234567890"

payload =
  Writer.write_string8(token) <>
    Writer.write_string8(name) <>
    Writer.write_int8(1) <>
    Writer.write_int8(0) <>
    Writer.write_int8(0) <>
    Writer.write_string8(md5) <>
    Writer.write_int8(1) <>
    Writer.write_int8(1) <>
    Writer.write_int8(6) <>
    Writer.write_int16(1) <>
    Writer.write_int8(1)

packet = Writer.build_packet(74, payload)

out_path = Path.join([__DIR__, "fixtures", "packet_captures", "login_synthetic_001.bin"])
File.write!(out_path, packet)
IO.puts("Wrote #{byte_size(packet)} bytes to #{out_path}")
