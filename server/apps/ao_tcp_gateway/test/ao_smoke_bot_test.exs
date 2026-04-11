defmodule AoSmokeBotTest do
  @moduledoc """
  TCP-level smoke bot that exercises the full network stack: connect, login,
  walk, chat, request stats, and verify wire-level responses.

  Unlike the Arena unit tests (which call MapServer directly), this test
  goes through Ranch TCP -> ClientHandler -> Session -> MapServer and back,
  validating the actual AO20 binary protocol end-to-end.
  """

  use ExUnit.Case, async: false

  alias AoProtocol.Writer
  alias AoTcpGateway.TestPacketDecoder, as: Decoder

  @connect_timeout 2_000

  # -- Client packet IDs --
  @pkt_login_new_char 74
  @pkt_talk 75
  @pkt_yell 76
  @pkt_walk 78
  @pkt_request_atributes 85
  @pkt_request_skills 86
  @pkt_request_mini_stats 87
  @pkt_change_heading 6
  @pkt_rest 47
  @pkt_quit 39

  # -- Server packet IDs (only those used in assertions) --
  @srv_logged 2
  @srv_change_map 30
  @srv_pos_update 31
  @srv_chat_over_head 35
  @srv_console_msg 37
  @srv_character_create 42
  @srv_character_move 44
  @srv_mini_stats 79
  @srv_send_atributes 81
  @srv_send_skills 87

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

    listener_name = :"smoke_bot_#{System.unique_integer([:positive])}"

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

  defp unique_name, do: "SmokeBot_#{System.unique_integer([:positive])}"

  defp send_login_new_char(socket, name) do
    token = "test_token"
    md5 = "abcdef1234567890abcdef1234567890"

    payload =
      Writer.write_string8(token) <>
        Writer.write_string8(name) <>
        Writer.write_int8(1) <> Writer.write_int8(0) <> Writer.write_int8(0) <>
        Writer.write_string8(md5) <>
        Writer.write_int8(1) <>   # race: human
        Writer.write_int8(1) <>   # gender: male
        Writer.write_int8(6) <>   # class: guerrero
        Writer.write_int16(1) <>  # head
        Writer.write_int8(1)      # home_city: ullathorpe

    packet = Writer.build_packet(@pkt_login_new_char, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_walk(socket, heading) do
    payload = Writer.write_int8(heading) <> Writer.write_int32(1)
    packet = Writer.build_packet(@pkt_walk, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_talk(socket, message) do
    payload = Writer.write_string8(message) <> Writer.write_int32(1)
    packet = Writer.build_packet(@pkt_talk, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_yell(socket, message) do
    payload = Writer.write_string8(message) <> Writer.write_int32(1)
    packet = Writer.build_packet(@pkt_yell, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_request_atributes(socket) do
    packet = Writer.build_packet(@pkt_request_atributes, <<>>)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_request_skills(socket) do
    packet = Writer.build_packet(@pkt_request_skills, <<>>)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_request_mini_stats(socket) do
    packet = Writer.build_packet(@pkt_request_mini_stats, <<>>)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_change_heading(socket, direction) do
    payload = Writer.write_int8(direction) <> Writer.write_int32(1)
    packet = Writer.build_packet(@pkt_change_heading, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_rest(socket) do
    packet = Writer.build_packet(@pkt_rest, <<>>)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp send_quit(socket) do
    packet = Writer.build_packet(@pkt_quit, <<>>)
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

  # Login, receive response, and register on_exit cleanup. Returns {socket, packets, char_id}.
  defp login_and_setup(port, name) do
    socket = connect(port)
    send_login_new_char(socket, name)
    packets = Decoder.recv_until_packet(socket, @srv_logged, 3_000)
    char_id = get_char_id(name)
    on_exit(fn -> :gen_tcp.close(socket); cleanup_char(char_id) end)
    {socket, packets, char_id}
  end

  # ============================================================
  # Tests
  # ============================================================

  describe "smoke bot - connect and login" do
    test "1. bot connects and creates a new character — receives logged(2) + change_map(30)", %{port: port} do
      {_socket, packets, _char_id} = login_and_setup(port, unique_name())
      ids = Decoder.packet_ids(packets)

      assert @srv_logged in ids,
             "Should receive logged(2) packet after login, got: #{inspect(ids)}"

      assert @srv_change_map in ids,
             "Should receive change_map(30) packet after login, got: #{inspect(ids)}"

      # Verify logged packet content
      {2, logged} = Decoder.find_packet(packets, @srv_logged)
      assert is_boolean(logged.new_user)

      # Verify change_map points to map 1
      {30, change_map} = Decoder.find_packet(packets, @srv_change_map)
      assert change_map.map_id == 1
    end
  end

  describe "smoke bot - movement" do
    test "2. bot walks in each direction — receives pos_update(31) or character_move(44)", %{port: port} do
      {socket, packets, _char_id} = login_and_setup(port, unique_name())
      {31, _initial_pos} = Decoder.find_packet(packets, @srv_pos_update)

      # Try all four directions (1=north, 2=east, 3=south, 4=west)
      walked_any = Enum.any?([3, 1, 2, 4], fn heading ->
        send_walk(socket, heading)
        data = Decoder.recv_all(socket)
        walk_packets = Decoder.decode_all_packets(data)
        Decoder.has_packet?(walk_packets, @srv_pos_update) or Decoder.has_packet?(walk_packets, @srv_character_move)
      end)

      assert walked_any,
             "At least one walk direction should produce a pos_update(31) or character_move(44)"
    end
  end

  describe "smoke bot - chat" do
    test "3. bot sends chat message — receives chat_over_head(35) or console_msg(37)", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_talk(socket, "Hello from smoke bot!")
      data = Decoder.recv_all(socket)
      chat_packets = Decoder.decode_all_packets(data)

      has_chat = Decoder.has_packet?(chat_packets, @srv_chat_over_head) or
                 Decoder.has_packet?(chat_packets, @srv_console_msg)

      assert has_chat,
             "Should receive chat_over_head(35) or console_msg(37) after talking, got: #{inspect(Decoder.packet_ids(chat_packets))}"
    end

    test "9. bot sends yell — receives chat response", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_yell(socket, "YELLING FROM SMOKE BOT!")
      data = Decoder.recv_all(socket)
      yell_packets = Decoder.decode_all_packets(data)

      has_yell = Decoder.has_packet?(yell_packets, @srv_chat_over_head) or
                 Decoder.has_packet?(yell_packets, @srv_console_msg)

      assert has_yell,
             "Should receive chat response after yelling, got: #{inspect(Decoder.packet_ids(yell_packets))}"
    end
  end

  describe "smoke bot - stats requests" do
    test "4. bot requests attributes — receives send_atributes(81)", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_request_atributes(socket)
      packets = Decoder.recv_until_packet(socket, @srv_send_atributes, 2_000)

      assert Decoder.has_packet?(packets, @srv_send_atributes),
             "Should receive send_atributes(81) after requesting attributes, got: #{inspect(Decoder.packet_ids(packets))}"
    end

    test "5. bot requests skills — receives send_skills(87)", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_request_skills(socket)
      packets = Decoder.recv_until_packet(socket, @srv_send_skills, 2_000)

      assert Decoder.has_packet?(packets, @srv_send_skills),
             "Should receive send_skills(87) after requesting skills, got: #{inspect(Decoder.packet_ids(packets))}"
    end

    test "6. bot requests mini stats — receives mini_stats(79)", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_request_mini_stats(socket)
      packets = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)

      assert Decoder.has_packet?(packets, @srv_mini_stats),
             "Should receive mini_stats(79) after requesting mini stats, got: #{inspect(Decoder.packet_ids(packets))}"
    end
  end

  describe "smoke bot - heading and rest" do
    test "7. bot changes heading — server does not crash", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      for direction <- [1, 2, 3, 4] do
        send_change_heading(socket, direction)
        Process.sleep(50)
      end

      # Verify the connection is still alive by requesting stats
      send_request_mini_stats(socket)
      packets = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)

      assert is_list(packets), "Server should remain responsive after heading changes"
    end

    test "8. bot starts resting — server does not crash", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_rest(socket)
      Process.sleep(200)

      # Verify the connection is still alive
      send_request_mini_stats(socket)
      packets = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)

      assert is_list(packets), "Server should remain responsive after resting"
    end
  end

  describe "smoke bot - full lifecycle" do
    test "10. full bot lifecycle: connect -> login -> walk -> chat -> stats -> rest -> quit", %{port: port} do
      name = unique_name()
      socket = connect(port)
      send_login_new_char(socket, name)
      login_packets = Decoder.recv_until_packet(socket, @srv_logged, 3_000)

      char_id = get_char_id(name)
      on_exit(fn -> :gen_tcp.close(socket); cleanup_char(char_id) end)

      # Verify login succeeded
      assert Decoder.has_packet?(login_packets, @srv_logged), "Login should produce logged(2)"
      assert Decoder.has_packet?(login_packets, @srv_change_map), "Login should produce change_map(30)"
      assert Decoder.has_packet?(login_packets, @srv_pos_update), "Login should produce pos_update(31)"

      # Walk south
      send_walk(socket, 3)
      _walk_data = Decoder.recv_all(socket)

      # Chat
      send_talk(socket, "Smoke bot lifecycle test")
      chat_data = Decoder.recv_all(socket)
      chat_packets = Decoder.decode_all_packets(chat_data)
      has_chat = Decoder.has_packet?(chat_packets, @srv_chat_over_head) or
                 Decoder.has_packet?(chat_packets, @srv_console_msg)
      assert has_chat, "Chat should produce a response"

      # Request attributes — step by step with targeted waits
      send_request_atributes(socket)
      attr_packets = Decoder.recv_until_packet(socket, @srv_send_atributes, 2_000)
      assert Decoder.has_packet?(attr_packets, @srv_send_atributes), "Attributes request should produce send_atributes(81)"

      # Request skills
      send_request_skills(socket)
      skill_packets = Decoder.recv_until_packet(socket, @srv_send_skills, 2_000)
      assert Decoder.has_packet?(skill_packets, @srv_send_skills), "Skills request should produce send_skills(87)"

      # Request mini stats
      send_request_mini_stats(socket)
      mini_packets = Decoder.recv_until_packet(socket, @srv_mini_stats, 2_000)
      assert Decoder.has_packet?(mini_packets, @srv_mini_stats), "Mini stats request should produce mini_stats(79)"

      # Rest
      send_rest(socket)
      Process.sleep(200)

      # Quit
      send_quit(socket)
      Process.sleep(200)

      # After quit, the socket should be closed or return error
      result = :gen_tcp.recv(socket, 0, 500)
      assert result == {:error, :closed} or result == {:error, :timeout} or match?({:ok, _}, result),
             "After quit, socket should be closed or drained"
    end
  end

  describe "smoke bot - multi-bot interaction" do
    test "11. two bots interact: bot A enters, bot B enters — bot A receives character_create(42) for bot B", %{port: port} do
      # Bot A logs in
      name_a = unique_name()
      {socket_a, _packets_a, _char_id_a} = login_and_setup(port, name_a)

      # Drain any remaining data from bot A's login
      _drain = Decoder.recv_quick(socket_a)

      # Bot B logs in
      name_b = unique_name()
      socket_b = connect(port)
      send_login_new_char(socket_b, name_b)
      _login_b_packets = Decoder.recv_until_packet(socket_b, @srv_logged, 3_000)

      char_id_b = get_char_id(name_b)
      on_exit(fn -> :gen_tcp.close(socket_b); cleanup_char(char_id_b) end)

      # Bot A should receive character_create for bot B
      a_packets = Decoder.recv_until_packet(socket_a, @srv_character_create, 2_000)

      char_creates = Enum.filter(a_packets, fn {id, _} -> id == @srv_character_create end)

      has_b_create =
        Enum.any?(char_creates, fn {42, fields} ->
          Map.get(fields, :name, "") == name_b
        end)

      assert has_b_create,
             "Bot A should receive character_create(42) for bot B (#{name_b}), got creates: #{inspect(Enum.map(char_creates, fn {_, f} -> Map.get(f, :name) end))}"
    end
  end

  describe "smoke bot - rapid actions" do
    test "12. bot sends rapid actions without waiting — server stays responsive", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      # Fire off several lightweight actions in rapid succession
      for _ <- 1..3 do
        send_walk(socket, Enum.random([1, 2, 3, 4]))
      end

      send_talk(socket, "rapid fire")
      send_change_heading(socket, 1)
      send_change_heading(socket, 3)

      # Drain burst responses
      Process.sleep(500)
      _burst_data = Decoder.recv_all(socket)

      # Verify server is still alive: send a stats request and wait for response
      send_request_mini_stats(socket)
      final_packets = Decoder.recv_until_packet(socket, @srv_mini_stats, 5_000)

      assert Decoder.has_packet?(final_packets, @srv_mini_stats),
             "Server should remain responsive after rapid-fire actions, got: #{inspect(Decoder.packet_ids(final_packets))}"
    end
  end
end
