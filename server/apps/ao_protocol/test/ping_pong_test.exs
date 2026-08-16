defmodule AoProtocol.PingPongTest do
  @moduledoc """
  Byte-level fixtures for the latency probe.

  ping (client 900) and pong (server 204) have no VB6 ancestor and are
  classified `:intentional_divergence` in the session route manifest. The token
  is opaque and exactly 8 bytes: the client stamps it, the server echoes it, and
  neither side agrees on a clock — which is what keeps the measurement immune to
  clock skew.
  """
  use ExUnit.Case, async: true

  alias AoProtocol.Client.Decoder
  alias AoProtocol.Server.Encoder

  @token <<1, 2, 3, 4, 5, 6, 7, 8>>

  describe "ping (client 900)" do
    test "decodes an 8-byte token and consumes exactly the packet" do
      packet = <<900::little-signed-16>> <> @token <> "trailing"

      assert {:ok, {:ping, %{token: @token}}, "trailing"} = Decoder.decode(packet)
    end

    test "a truncated token asks for more data rather than decoding garbage" do
      for width <- 0..7 do
        packet = <<900::little-signed-16>> <> :binary.part(@token, 0, width)
        assert Decoder.decode(packet) == :incomplete, "width #{width} should be incomplete"
      end
    end

    test "two concatenated pings both decode" do
      second = <<9, 10, 11, 12, 13, 14, 15, 16>>
      packet = <<900::little-signed-16>> <> @token <> <<900::little-signed-16>> <> second

      assert {:ok, {:ping, %{token: @token}}, rest} = Decoder.decode(packet)
      assert {:ok, {:ping, %{token: ^second}}, ""} = Decoder.decode(rest)
    end

    test "a replayed token is decoded, not rejected" do
      # Replay protection is not the protocol's job here: a repeated token only
      # confuses the client's own RTT bookkeeping, and the client discards
      # samples it did not ask for.
      packet = <<900::little-signed-16>> <> @token
      assert {:ok, {:ping, %{token: @token}}, ""} = Decoder.decode(packet)
    end
  end

  describe "pong (server 204)" do
    test "echoes the token verbatim" do
      assert Encoder.encode({:pong, %{token: @token}}) ==
               <<204::little-signed-16>> <> @token
    end

    test "refuses a token that is not exactly 8 bytes" do
      # The decoder requires 8; accepting anything else here would hand a
      # client a packet it cannot parse and desynchronise the stream.
      for bad <- [<<>>, <<1, 2, 3>>, <<0::size(72)>>] do
        assert_raise FunctionClauseError, fn ->
          Encoder.encode({:pong, %{token: bad}})
        end
      end
    end

    test "round-trips any 8 bytes, including zeros and high bits" do
      for token <- [<<0::size(64)>>, <<255, 255, 255, 255, 255, 255, 255, 255>>] do
        assert Encoder.encode({:pong, %{token: token}}) ==
                 <<204::little-signed-16>> <> token
      end
    end
  end

  test "ping is answered by the session, not the map" do
    metadata = AoTcpGateway.SessionRouteManifest.route(:ping)

    assert metadata.parity_status == :intentional_divergence
    assert metadata.dispatch == {AoTcpGateway.SessionLogic, :handle_command}
  end
end
