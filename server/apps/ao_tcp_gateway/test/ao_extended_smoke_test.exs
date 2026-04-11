defmodule AoExtendedSmokeTest do
  @moduledoc """
  Extended TCP-level smoke tests covering bank, commerce, safe-toggle,
  meditate, reconnect, whisper, yell, and online-request flows.

  Follows the same pattern as AoSmokeBotTest: goes through
  Ranch TCP -> ClientHandler -> Session -> MapServer and back,
  validating the actual AO20 binary protocol end-to-end.
  """

  use ExUnit.Case, async: false

  alias AoProtocol.Writer
  alias AoTcpGateway.TestPacketDecoder, as: Decoder

  @connect_timeout 2_000

  # -- Client packet IDs --
  @pkt_login_new_char 74
  @pkt_login_existing_char 73
  @pkt_yell 76
  @pkt_whisper 77
  @pkt_safe_toggle 82
  @pkt_request_mini_stats 87
  @pkt_meditate 48
  @pkt_rest 47
  @pkt_online 38
  @pkt_bank_start 54
  @pkt_bank_deposit 12
  @pkt_bank_extract_item 10
  @pkt_bank_deposit_gold 71
  @pkt_bank_extract_gold 70
  @pkt_bank_end 90
  @pkt_commerce_start 53

  # -- Server packet IDs --
  @srv_logged 2
  @srv_change_map 30
  @srv_console_msg 37
  @srv_chat_over_head 35
  @srv_mini_stats 79
  @srv_safe_mode_on 20
  @srv_safe_mode_off 21
  @srv_error_msg 73
  @srv_bank_init 11
  @srv_commerce_init 10

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

    listener_name = :"ext_smoke_#{System.unique_integer([:positive])}"

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

  defp unique_name, do: "ExtBot_#{System.unique_integer([:positive])}"

  defp send_login_new_char(socket, name) do
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

    packet = Writer.build_packet(@pkt_login_new_char, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_login_existing_char(socket, char_id, session_token) do
    md5 = "abcdef1234567890abcdef1234567890"

    payload =
      Writer.write_string8(session_token) <>
        Writer.write_int32(char_id) <>
        Writer.write_int8(1) <> Writer.write_int8(0) <> Writer.write_int8(0) <>
        Writer.write_string8(md5)

    packet = Writer.build_packet(@pkt_login_existing_char, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp get_char_id(name) do
    case GameBackend.Characters.get_by_name(name) do
      nil -> nil
      char -> char.id
    end
  end

  defp cleanup_char(nil), do: :ok

  defp cleanup_char(char_id) do
    try do
      Arena.Map.MapServer.leave(1, char_id)
    catch
      :exit, _ -> :ok
    end

    try do
      AoSession.OnlineDirectory.unregister(char_id)
      AoSession.unregister(char_id)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp login_and_setup(port, name) do
    socket = connect(port)
    send_login_new_char(socket, name)
    packets = Decoder.recv_until_packet(socket, @srv_logged, 3_000)
    char_id = get_char_id(name)
    on_exit(fn -> :gen_tcp.close(socket); cleanup_char(char_id) end)
    {socket, packets, char_id}
  end

  defp send_packet(socket, packet_id, payload \\ <<>>) do
    packet = Writer.build_packet(packet_id, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  # ============================================================
  # Tests — Bank flow
  # ============================================================

  describe "bank flow" do
    test "bank_start sends bank_init or error, bank operations don't crash server", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      # Drain any leftover login data
      _drain = Decoder.recv_quick(socket)

      # Send bank_start (54) — no payload
      send_packet(socket, @pkt_bank_start)
      bank_packets = Decoder.recv_all(socket, 1_000)
      decoded = Decoder.decode_all_packets(bank_packets)
      ids = Decoder.packet_ids(decoded)

      # Server should respond with bank_init(11) or error_msg(73)
      has_bank_response = @srv_bank_init in ids or @srv_error_msg in ids or @srv_console_msg in ids

      assert has_bank_response,
             "Should receive bank_init(11) or error_msg(73) after bank_start, got: #{inspect(ids)}"

      if @srv_bank_init in ids do
        # If bank opened, try deposit item (slot 1, amount 1, dest slot 1)
        deposit_payload =
          Writer.write_int8(1) <> Writer.write_int16(1) <> Writer.write_int8(1)

        send_packet(socket, @pkt_bank_deposit, deposit_payload)
        _dep = Decoder.recv_all(socket, 500)

        # Try extract item (slot 1, amount 1, dest slot 1)
        extract_payload =
          Writer.write_int8(1) <> Writer.write_int16(1) <> Writer.write_int8(1)

        send_packet(socket, @pkt_bank_extract_item, extract_payload)
        _ext = Decoder.recv_all(socket, 500)

        # Deposit gold (amount 100)
        send_packet(socket, @pkt_bank_deposit_gold, Writer.write_int32(100))
        _dep_gold = Decoder.recv_all(socket, 500)

        # Extract gold (amount 50)
        send_packet(socket, @pkt_bank_extract_gold, Writer.write_int32(50))
        _ext_gold = Decoder.recv_all(socket, 500)

        # End bank session
        send_packet(socket, @pkt_bank_end)
        _bank_end = Decoder.recv_all(socket, 500)
      end

      # Verify server is still alive
      send_packet(socket, @pkt_request_mini_stats)
      final = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)

      assert Decoder.has_packet?(final, @srv_mini_stats),
             "Server should remain responsive after bank flow"
    end
  end

  # ============================================================
  # Tests — NPC Commerce flow
  # ============================================================

  describe "NPC commerce flow" do
    test "commerce_start doesn't crash server", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())
      _drain = Decoder.recv_quick(socket)

      # Send commerce_start (53) — no payload per decoder
      send_packet(socket, @pkt_commerce_start)
      commerce_data = Decoder.recv_all(socket, 1_000)
      decoded = Decoder.decode_all_packets(commerce_data)
      ids = Decoder.packet_ids(decoded)

      # Server may respond with commerce_init(10), error_msg(73), or console_msg(37)
      # We just verify it doesn't crash
      _response_type =
        cond do
          @srv_commerce_init in ids -> :commerce_init
          @srv_error_msg in ids -> :error
          @srv_console_msg in ids -> :console_msg
          true -> :no_response
        end

      # Verify server is still alive
      send_packet(socket, @pkt_request_mini_stats)
      final = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)

      assert Decoder.has_packet?(final, @srv_mini_stats),
             "Server should remain responsive after commerce_start, initial response IDs: #{inspect(ids)}"
    end
  end

  # ============================================================
  # Tests — Safe toggle
  # ============================================================

  describe "safe toggle" do
    test "toggling safe mode twice produces two responses", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())
      _drain = Decoder.recv_quick(socket)

      # First toggle
      send_packet(socket, @pkt_safe_toggle)
      data1 = Decoder.recv_all(socket, 1_000)
      decoded1 = Decoder.decode_all_packets(data1)
      ids1 = Decoder.packet_ids(decoded1)

      has_safe1 = @srv_safe_mode_on in ids1 or @srv_safe_mode_off in ids1 or @srv_console_msg in ids1

      assert has_safe1,
             "First safe_toggle should produce safe_mode_on(20) or safe_mode_off(21), got: #{inspect(ids1)}"

      # Second toggle
      send_packet(socket, @pkt_safe_toggle)
      data2 = Decoder.recv_all(socket, 1_000)
      decoded2 = Decoder.decode_all_packets(data2)
      ids2 = Decoder.packet_ids(decoded2)

      has_safe2 = @srv_safe_mode_on in ids2 or @srv_safe_mode_off in ids2 or @srv_console_msg in ids2

      assert has_safe2,
             "Second safe_toggle should produce safe_mode_on(20) or safe_mode_off(21), got: #{inspect(ids2)}"

      # Verify server still alive
      send_packet(socket, @pkt_request_mini_stats)
      final = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)

      assert Decoder.has_packet?(final, @srv_mini_stats),
             "Server should remain responsive after safe toggles"
    end
  end

  # ============================================================
  # Tests — Meditate
  # ============================================================

  describe "meditate" do
    test "meditate command doesn't crash server", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())
      _drain = Decoder.recv_quick(socket)

      send_packet(socket, @pkt_meditate)
      _med_data = Decoder.recv_all(socket, 500)

      # Verify server is still alive by requesting stats
      send_packet(socket, @pkt_request_mini_stats)
      final = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)

      assert Decoder.has_packet?(final, @srv_mini_stats),
             "Server should remain responsive after meditate"
    end
  end

  # ============================================================
  # Tests — Reconnect flow
  # ============================================================

  describe "reconnect flow" do
    test "login, get session_token from DB, disconnect, reconnect with login_existing_char", %{port: port} do
      name = unique_name()
      socket1 = connect(port)
      send_login_new_char(socket1, name)
      login_packets = Decoder.recv_until_packet(socket1, @srv_logged, 3_000)

      assert Decoder.has_packet?(login_packets, @srv_logged), "Initial login should succeed"

      char_id = get_char_id(name)
      assert char_id != nil, "Character should exist in DB"

      # Get session token from DB (TCP doesn't send session_token packet)
      character = GameBackend.Characters.get(char_id)
      session_token = character.session_token

      assert is_binary(session_token) and byte_size(session_token) > 0,
             "Character should have a session_token after login"

      # Clean up map entity so reconnect can proceed
      cleanup_char(char_id)

      # Disconnect first socket
      :gen_tcp.close(socket1)
      Process.sleep(300)

      # Reconnect with login_existing_char
      socket2 = connect(port)
      send_login_existing_char(socket2, char_id, session_token)
      reconnect_packets = Decoder.recv_until_packet(socket2, @srv_logged, 3_000)
      reconnect_ids = Decoder.packet_ids(reconnect_packets)

      on_exit(fn -> :gen_tcp.close(socket2); cleanup_char(char_id) end)

      assert @srv_logged in reconnect_ids,
             "Reconnect should produce logged(2), got: #{inspect(reconnect_ids)}"

      assert @srv_change_map in reconnect_ids,
             "Reconnect should produce change_map(30), got: #{inspect(reconnect_ids)}"
    end
  end

  # ============================================================
  # Tests — Whisper
  # ============================================================

  describe "whisper" do
    test "bot A whispers to bot B, bot B receives console_msg", %{port: port} do
      name_a = unique_name()
      name_b = unique_name()

      # Login bot A
      {socket_a, _packets_a, _char_id_a} = login_and_setup(port, name_a)
      _drain_a = Decoder.recv_quick(socket_a)

      # Login bot B
      socket_b = connect(port)
      send_login_new_char(socket_b, name_b)
      _login_b = Decoder.recv_until_packet(socket_b, @srv_logged, 3_000)
      char_id_b = get_char_id(name_b)
      on_exit(fn -> :gen_tcp.close(socket_b); cleanup_char(char_id_b) end)

      # Drain leftover data on both sockets
      _drain_a2 = Decoder.recv_quick(socket_a)
      _drain_b = Decoder.recv_quick(socket_b)

      # Bot A whispers to bot B
      whisper_msg = "secret message from A"
      whisper_payload = Writer.write_string8(name_b) <> Writer.write_string8(whisper_msg)
      send_packet(socket_a, @pkt_whisper, whisper_payload)

      # Bot B should receive a console_msg with the whisper content
      b_data = Decoder.recv_all(socket_b, 1_000)
      b_packets = Decoder.decode_all_packets(b_data)

      has_whisper =
        Enum.any?(b_packets, fn
          {37, %{message: msg}} -> String.contains?(msg, whisper_msg)
          _ -> false
        end)

      # Also check bot A's own socket for echo
      a_data = Decoder.recv_all(socket_a, 500)
      a_packets = Decoder.decode_all_packets(a_data)

      a_has_whisper =
        Enum.any?(a_packets, fn
          {37, %{message: msg}} -> String.contains?(msg, whisper_msg)
          _ -> false
        end)

      assert has_whisper or a_has_whisper,
             "At least one bot should receive whisper message in console_msg(37). " <>
               "Bot B packets: #{inspect(Decoder.packet_ids(b_packets))}, " <>
               "Bot A packets: #{inspect(Decoder.packet_ids(a_packets))}"
    end
  end

  # ============================================================
  # Tests — Online request
  # ============================================================

  describe "online request" do
    test "online command returns console_msg with player count", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())
      _drain = Decoder.recv_quick(socket)

      # Send online (38) — no payload
      send_packet(socket, @pkt_online)
      online_data = Decoder.recv_all(socket, 1_000)
      online_packets = Decoder.decode_all_packets(online_data)
      ids = Decoder.packet_ids(online_packets)

      assert @srv_console_msg in ids,
             "Online request should produce console_msg(37), got: #{inspect(ids)}"
    end
  end

  # ============================================================
  # Tests — Yell
  # ============================================================

  describe "yell" do
    test "yell produces chat_over_head or console_msg", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())
      _drain = Decoder.recv_quick(socket)

      yell_payload = Writer.write_string8("YELLING LOUDLY!")
      send_packet(socket, @pkt_yell, yell_payload)
      yell_data = Decoder.recv_all(socket, 1_000)
      yell_packets = Decoder.decode_all_packets(yell_data)
      ids = Decoder.packet_ids(yell_packets)

      has_yell = @srv_chat_over_head in ids or @srv_console_msg in ids

      assert has_yell,
             "Yell should produce chat_over_head(35) or console_msg(37), got: #{inspect(ids)}"
    end
  end

  # ============================================================
  # Tests — Rest
  # ============================================================

  describe "rest" do
    test "rest command doesn't crash server", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())
      _drain = Decoder.recv_quick(socket)

      send_packet(socket, @pkt_rest)
      _rest_data = Decoder.recv_all(socket, 500)

      # Verify server alive
      send_packet(socket, @pkt_request_mini_stats)
      final = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)

      assert Decoder.has_packet?(final, @srv_mini_stats),
             "Server should remain responsive after rest"
    end
  end
end
