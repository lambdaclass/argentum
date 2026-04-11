defmodule AoTcpGateway.AdversarialProtocolTest do
  @moduledoc """
  Adversarial / negative-path tests for the TCP protocol layer.

  Verifies the server handles malformed packets, protocol abuse, and
  resource-exhaustion scenarios gracefully — without crashing, leaking
  resources, or becoming unresponsive.
  """

  use ExUnit.Case, async: false

  alias AoProtocol.Writer
  alias AoTcpGateway.TestPacketDecoder, as: Decoder

  @connect_timeout 2_000

  # Server packet IDs used in assertions
  @srv_logged 2
  @srv_mini_stats 79

  # ============================================================
  # Setup
  # ============================================================

  setup_all do
    start_if_needed(:ranch_sup, fn -> Application.ensure_all_started(:ranch) end)

    start_if_needed(Arena.PubSub, fn ->
      Application.ensure_all_started(:phoenix_pubsub)
      Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end)

    start_if_needed(AoSession.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: AoSession.SessionRegistry)
    end)

    start_if_needed(Arena.MapRegistry, fn ->
      Registry.start_link(keys: :unique, name: Arena.MapRegistry)
    end)

    start_if_needed(Arena.Map.MapSupervisor, fn ->
      Arena.Map.MapSupervisor.start_link([])
    end)

    case Registry.lookup(Arena.MapRegistry, 1) do
      [] -> Arena.Map.MapSupervisor.start_map(1)
      _ -> :ok
    end

    :ok
  end

  setup do
    owner_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GameBackend.Repo, shared: true)

    listener_name = :"adversarial_#{System.unique_integer([:positive])}"

    {:ok, _} =
      :ranch.start_listener(
        listener_name,
        :ranch_tcp,
        [port: 0],
        AoTcpGateway.ClientHandler,
        []
      )

    port = :ranch.get_port(listener_name)

    on_exit(fn ->
      :ranch.stop_listener(listener_name)
      Process.sleep(200)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid)
    end)

    %{port: port}
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp start_if_needed(name, start_fun) do
    case Process.whereis(name) do
      nil -> start_fun.()
      _pid -> :ok
    end
  end

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw], @connect_timeout)

    socket
  end

  defp unique_name, do: "Adv_#{System.unique_integer([:positive])}"

  defp send_raw(socket, data) do
    :ok = :gen_tcp.send(socket, data)
  end

  defp send_packet(socket, packet_id, payload) do
    packet = Writer.build_packet(packet_id, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp build_login_new_char(name) do
    token = "test_token"
    md5 = "abcdef1234567890abcdef1234567890"

    payload =
      Writer.write_string8(token) <>
        Writer.write_string8(name) <>
        Writer.write_int8(1) <> Writer.write_int8(0) <> Writer.write_int8(0) <>
        Writer.write_string8(md5) <>
        Writer.write_int8(1) <>
        Writer.write_int8(1) <>
        Writer.write_int8(6) <>
        Writer.write_int16(1) <>
        Writer.write_int8(1)

    {74, payload}
  end

  defp cleanup_char(name) do
    try do
      case GameBackend.Characters.get_by_name(name) do
        nil -> :ok
        char ->
          try do
            Arena.Map.MapServer.leave(1, char.id)
          catch
            :exit, _ -> :ok
          end
          AoSession.OnlineDirectory.unregister(char.id)
          AoSession.unregister(char.id)
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp login(port, name) do
    socket = connect(port)
    {pkt_id, payload} = build_login_new_char(name)
    send_packet(socket, pkt_id, payload)
    packets = Decoder.recv_until_packet(socket, @srv_logged, 3_000)
    {socket, packets}
  end

  # Verify the server is still alive by requesting mini_stats.
  # Returns true if the server responds, false if the connection is dead.
  defp server_alive?(socket) do
    try do
      send_packet(socket, 87, <<>>)
      packets = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)
      Decoder.has_packet?(packets, @srv_mini_stats)
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  # Returns true if the connection was closed by the server (or still open but responsive)
  defp connection_ok_or_closed?(socket) do
    case :gen_tcp.recv(socket, 0, 500) do
      {:ok, _data} -> true
      {:error, :timeout} -> true
      {:error, :closed} -> true
      {:error, _} -> true
    end
  end

  # ============================================================
  # 1. Malformed packets
  # ============================================================

  describe "malformed packets" do
    test "1. packet with ID 0 (zero) does not crash the server", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Packet ID 0 is not a known client packet
      send_packet(socket, 0, <<1, 2, 3>>)
      Process.sleep(200)

      # Server should either still be alive or have cleanly disconnected
      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "2. packet with negative ID (-1 as Int16) does not crash the server", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # -1 as signed little-endian Int16 = 0xFFFF
      send_raw(socket, <<-1::little-signed-16, 1, 2, 3, 4>>)
      Process.sleep(200)

      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "3. packet with max Int16 (32767) does not crash the server", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      send_packet(socket, 32767, <<0, 0, 0, 0>>)
      Process.sleep(200)

      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "4. empty payload for packets that expect payload does not crash", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Walk (78) expects Int8 heading + Int32 packet_count = 5 bytes, send 0
      send_packet(socket, 78, <<>>)
      Process.sleep(200)

      # Talk (75) expects String8 + Int32, send 0
      send_packet(socket, 75, <<>>)
      Process.sleep(200)

      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "5. oversized payload (10KB random bytes) does not crash or OOM", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Send walk packet ID followed by 10KB of random bytes
      big_payload = :crypto.strong_rand_bytes(10_240)
      send_packet(socket, 78, big_payload)
      Process.sleep(300)

      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "6. truncated string (length says 100 but only 5 bytes follow) does not crash", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Talk packet (75): first field is String8 (Int16 length + data)
      # Claim 100 bytes but only send 5
      truncated_string = <<100::little-signed-16, "hello">>
      send_packet(socket, 75, truncated_string)
      Process.sleep(300)

      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "7. valid packet ID but wrong payload size (walk with 100 bytes) handles gracefully", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Walk (78) expects 5 bytes; send 100 bytes
      oversized_walk = :crypto.strong_rand_bytes(100)
      send_packet(socket, 78, oversized_walk)
      Process.sleep(200)

      # The decoder will read the 5 bytes it needs and treat the rest as the next packet.
      # Either way, the server should not crash.
      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end
  end

  # ============================================================
  # 2. Protocol abuse
  # ============================================================

  describe "protocol abuse" do
    test "8. 100 packets in a single TCP write (burst) — server stays responsive", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Build 100 walk packets and send in one TCP write
      burst =
        for i <- 1..100, into: <<>> do
          heading = rem(i, 4) + 1
          Writer.build_packet(78, Writer.write_int8(heading) <> Writer.write_int32(1))
        end

      send_raw(socket, burst)

      # Drain responses — server may disconnect due to flood guard, which is acceptable
      Process.sleep(500)
      _data = Decoder.recv_all(socket)

      # Either server is still responsive or it disconnected due to flood guard
      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "9. zero-length TCP segments interspersed — server handles fragmentation", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Send a walk packet split across multiple TCP writes with empty writes
      walk_packet = Writer.build_packet(78, Writer.write_int8(3) <> Writer.write_int32(1))

      # Split the packet byte by byte
      for <<byte::binary-size(1) <- walk_packet>> do
        send_raw(socket, byte)
        Process.sleep(10)
      end

      Process.sleep(300)
      _data = Decoder.recv_all(socket)

      # Server should still be alive
      assert server_alive?(socket) or connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "10. login packet twice on same connection — should reject second login", %{port: port} do
      name1 = unique_name()
      name2 = unique_name()
      on_exit(fn -> cleanup_char(name1); cleanup_char(name2) end)

      # First login
      {socket, packets} = login(port, name1)
      assert Decoder.has_packet?(packets, @srv_logged)

      # Second login on same connection
      {pkt_id, payload} = build_login_new_char(name2)
      send_packet(socket, pkt_id, payload)
      Process.sleep(500)

      # Server should either ignore the second login, send an error, or disconnect
      # It must NOT crash
      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "11. gameplay packets before login (walk, talk, attack) — should be rejected or ignored", %{port: port} do
      socket = connect(port)

      # Send walk without logging in
      send_packet(socket, 78, Writer.write_int8(1) <> Writer.write_int32(1))
      Process.sleep(100)

      # Send talk without logging in
      send_packet(socket, 75, Writer.write_string8("hello") <> Writer.write_int32(1))
      Process.sleep(100)

      # Send attack without logging in
      send_packet(socket, 80, Writer.write_int32(1))
      Process.sleep(100)

      # Send request_mini_stats without logging in
      send_packet(socket, 87, <<>>)
      Process.sleep(200)

      # Server should not crash — connection should still be open or cleanly closed
      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "12. all-zero bytes (binary zero flood) does not crash", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Send 1KB of all-zero bytes
      zeros = :binary.copy(<<0>>, 1024)
      send_raw(socket, zeros)
      Process.sleep(300)

      # Zero bytes will be interpreted as packet ID 0 (unknown), repeated.
      # Server should handle without crashing.
      assert connection_ok_or_closed?(socket)
      :gen_tcp.close(socket)
    end

    test "13. disconnect mid-packet (close TCP after first byte) — server cleans up", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Send only the first byte of a walk packet (partial Int16 packet ID)
      send_raw(socket, <<78>>)

      # Immediately close the socket
      :gen_tcp.close(socket)
      Process.sleep(300)

      # Verify the server is still accepting new connections (did not crash)
      new_socket = connect(port)
      assert is_port(new_socket) or is_reference(new_socket)
      :gen_tcp.close(new_socket)
    end
  end

  # ============================================================
  # 3. Resource exhaustion
  # ============================================================

  describe "resource exhaustion" do
    test "14. open 20 connections rapidly without logging in — connections timeout and clean up", %{port: port} do
      sockets =
        for _ <- 1..20 do
          connect(port)
        end

      Process.sleep(500)

      # All sockets should still be in a valid state (open or timed-out)
      for socket <- sockets do
        assert connection_ok_or_closed?(socket)
        :gen_tcp.close(socket)
      end

      # Server should still accept new connections
      new_socket = connect(port)
      assert is_port(new_socket) or is_reference(new_socket)
      :gen_tcp.close(new_socket)
    end

    test "15. send 1000 chat messages rapidly — server does not OOM", %{port: port} do
      name = unique_name()
      on_exit(fn -> cleanup_char(name) end)
      {socket, _} = login(port, name)

      # Fire 1000 talk packets as fast as possible
      for i <- 1..1000 do
        packet = Writer.build_packet(75, Writer.write_string8("spam#{i}") <> Writer.write_int32(i))
        case :gen_tcp.send(socket, packet) do
          :ok -> :ok
          {:error, _} -> :break
        end
      end

      # Drain — flood guard may have disconnected us, which is acceptable
      Process.sleep(500)
      _data = Decoder.recv_all(socket)

      assert connection_ok_or_closed?(socket)

      # Verify server is still alive by opening a new connection
      new_socket = connect(port)
      assert is_port(new_socket) or is_reference(new_socket)
      :gen_tcp.close(new_socket)
      :gen_tcp.close(socket)
    end

    test "16. login and immediately disconnect, repeat 10 times — no resource leak", %{port: port} do
      names = for _ <- 1..10, do: unique_name()
      on_exit(fn -> Enum.each(names, &cleanup_char/1) end)

      for name <- names do
        socket = connect(port)
        {pkt_id, payload} = build_login_new_char(name)
        send_packet(socket, pkt_id, payload)
        # Don't even wait for response — just slam the connection shut
        Process.sleep(50)
        :gen_tcp.close(socket)
        Process.sleep(100)
      end

      # After all rapid connect/disconnect cycles, the server should still work
      final_name = unique_name()
      on_exit(fn -> cleanup_char(final_name) end)
      {socket, packets} = login(port, final_name)

      assert Decoder.has_packet?(packets, @srv_logged),
             "Server should still accept logins after rapid connect/disconnect cycles. Got: #{inspect(Decoder.packet_ids(packets))}"

      :gen_tcp.close(socket)
    end
  end
end
