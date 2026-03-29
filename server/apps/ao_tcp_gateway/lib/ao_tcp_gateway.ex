defmodule AoTcpGateway do
  @moduledoc """
  TCP gateway for the VB6 Argentum Online client.

  Listens on a configurable port (default 7666), accepts TCP connections,
  and translates AO binary packets into domain commands via ao_protocol.

  Each connected client gets its own process that:
  1. Reads binary data from the socket
  2. Decodes packets via AoProtocol.Client.Decoder
  3. Dispatches commands to the arena (game world)
  4. Encodes server responses via AoProtocol.Server.Encoder
  5. Writes binary data back to the socket
  """
end
