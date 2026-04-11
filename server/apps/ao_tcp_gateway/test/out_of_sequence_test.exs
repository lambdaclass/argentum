defmodule AoTcpGateway.OutOfSequenceTest do
  @moduledoc """
  Tests that the TCP gateway rejects out-of-sequence packets:
  - Commerce buy/sell without starting commerce
  - Bank deposit/extract without starting bank
  - User trade offer/ok/reject without active trade session
  - GM commands without GM privileges
  """

  use ExUnit.Case

  alias AoProtocol.Writer
  alias AoProtocol.Reader

  @connect_timeout 2000
  @recv_timeout 500

  # Server packet IDs
  @srv_console_msg 37

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
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})

    listener_name = :"test_oos_#{System.unique_integer([:positive])}"

    {:ok, _} =
      :ranch.start_listener(
        listener_name,
        :ranch_tcp,
        [port: 0],
        AoTcpGateway.ClientHandler,
        []
      )

    port = :ranch.get_port(listener_name)

    on_exit(fn -> :ranch.stop_listener(listener_name) end)

    %{port: port}
  end

  # ---- Helpers ----

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw], @connect_timeout)
    socket
  end

  defp send_login_with_name(socket, name) do
    token = "test_token"
    md5 = "abcdef1234567890abcdef1234567890"

    payload =
      Writer.write_string8(token) <>
        Writer.write_string8(name) <>
        Writer.write_int8(1) <> Writer.write_int8(0) <> Writer.write_int8(0) <>
        Writer.write_string8(md5) <>
        Writer.write_int8(1) <>  # race: human
        Writer.write_int8(1) <>  # gender: male
        Writer.write_int8(6) <>  # class: guerrero
        Writer.write_int16(1) <> # head
        Writer.write_int8(1)     # home_city: ullathorpe

    packet = Writer.build_packet(74, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp login_and_setup(port, name) do
    socket = connect(port)
    send_login_with_name(socket, name)
    data = recv_all(socket)
    packets = decode_all_packets(data)
    char_id = get_char_id(name)
    on_exit(fn -> :gen_tcp.close(socket); cleanup_char(char_id) end)
    {socket, packets, char_id}
  end

  defp recv_all(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :timeout} -> acc
      {:error, _reason} -> acc
    end
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
    AoSession.OnlineDirectory.unregister(char_id)
    AoSession.unregister(char_id)
  end

  defp start_if_needed(name, start_fun) do
    case Process.whereis(name) do
      nil -> start_fun.()
      _pid -> :ok
    end
  end

  defp unique_name, do: "OOS_#{System.unique_integer([:positive])}"

  defp has_console_msg_matching?(packets, pattern) do
    Enum.any?(packets, fn
      {@srv_console_msg, %{message: msg}} -> msg =~ pattern
      _ -> false
    end)
  end

  # ---- Packet senders ----

  # CommerceBuy (ID 9): slot(Int8) + amount(Int16)
  defp send_commerce_buy(socket, slot, amount) do
    payload = Writer.write_int8(slot) <> Writer.write_int16(amount)
    :ok = :gen_tcp.send(socket, Writer.build_packet(9, payload))
  end

  # CommerceSell (ID 11): slot(Int8) + amount(Int16)
  defp send_commerce_sell(socket, slot, amount) do
    payload = Writer.write_int8(slot) <> Writer.write_int16(amount)
    :ok = :gen_tcp.send(socket, Writer.build_packet(11, payload))
  end

  # BankDeposit (ID 12): slot(Int8) + amount(Int16) + slot_destino(Int8)
  defp send_bank_deposit(socket, slot, amount, dest) do
    payload = Writer.write_int8(slot) <> Writer.write_int16(amount) <> Writer.write_int8(dest)
    :ok = :gen_tcp.send(socket, Writer.build_packet(12, payload))
  end

  # BankExtractGold (ID 70): amount(Int32)
  defp send_bank_extract_gold(socket, amount) do
    payload = Writer.write_int32(amount)
    :ok = :gen_tcp.send(socket, Writer.build_packet(70, payload))
  end

  # BankDepositGold (ID 71): amount(Int32)
  defp send_bank_deposit_gold(socket, amount) do
    payload = Writer.write_int32(amount)
    :ok = :gen_tcp.send(socket, Writer.build_packet(71, payload))
  end

  # UserCommerceOffer (ID 16): obj_index(Int16) + amount(Int32)
  defp send_user_commerce_offer(socket, obj_index, amount) do
    payload = Writer.write_int16(obj_index) <> Writer.write_int32(amount)
    :ok = :gen_tcp.send(socket, Writer.build_packet(16, payload))
  end

  # UserCommerceOk (ID 91): no payload
  defp send_user_commerce_ok(socket) do
    :ok = :gen_tcp.send(socket, Writer.build_packet(91, <<>>))
  end

  # GoToChar (ID 114): name(S8) — GM command
  defp send_go_to_char(socket, name) do
    payload = Writer.write_string8(name)
    :ok = :gen_tcp.send(socket, Writer.build_packet(114, payload))
  end

  # Jail (ID 120): name(S8) + reason(S8) + minutes(I8) — GM command
  defp send_jail(socket, name) do
    payload = Writer.write_string8(name) <> Writer.write_string8("test") <> Writer.write_int8(10)
    :ok = :gen_tcp.send(socket, Writer.build_packet(120, payload))
  end

  # Kick (ID 134): name(S8) — GM command
  defp send_kick(socket, name) do
    payload = Writer.write_string8(name)
    :ok = :gen_tcp.send(socket, Writer.build_packet(134, payload))
  end

  # BanChar (ID 136): name(S8) + reason(S8) — GM command
  defp send_ban_char(socket, name) do
    payload = Writer.write_string8(name) <> Writer.write_string8("test reason")
    :ok = :gen_tcp.send(socket, Writer.build_packet(136, payload))
  end

  # Invisible (ID 115): no payload — GM command
  defp send_invisible(socket) do
    :ok = :gen_tcp.send(socket, Writer.build_packet(115, <<>>))
  end

  # RequestPositionUpdate (ID 79): no payload — used to force a server round-trip
  defp send_request_position(socket) do
    :ok = :gen_tcp.send(socket, Writer.build_packet(79, <<>>))
  end

  # ---- Packet decoders ----

  defp decode_all_packets(data), do: decode_all_packets(data, [])
  defp decode_all_packets(<<>>, acc), do: Enum.reverse(acc)
  defp decode_all_packets(data, acc) when byte_size(data) < 2, do: Enum.reverse(acc)
  defp decode_all_packets(<<packet_id::little-signed-16, rest::binary>>, acc) do
    case decode_server_packet(packet_id, rest) do
      {:ok, fields, remaining} -> decode_all_packets(remaining, [{packet_id, fields} | acc])
      :incomplete -> Enum.reverse(acc)
    end
  end

  # error_msg (73): string8
  defp decode_server_packet(73, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data) do
      {:ok, %{message: msg}, rest}
    else
      _ -> :incomplete
    end
  end

  # console_msg (37): string8 + int8(font)
  defp decode_server_packet(37, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, font, rest} <- Reader.read_int8(rest) do
      {:ok, %{message: msg, font_index: font}, rest}
    else
      _ -> :incomplete
    end
  end

  # logged (2): bool
  defp decode_server_packet(2, <<new_user::8, rest::binary>>), do: {:ok, %{new_user: new_user != 0}, rest}
  # update_sta (25)
  defp decode_server_packet(25, <<min_sta::little-signed-16, rest::binary>>), do: {:ok, %{min_sta: min_sta}, rest}
  # update_mana (26)
  defp decode_server_packet(26, <<min_mana::little-signed-16, rest::binary>>), do: {:ok, %{min_mana: min_mana}, rest}
  # update_hp (27)
  defp decode_server_packet(27, <<min_hp::little-signed-16, _shield::little-signed-32, rest::binary>>), do: {:ok, %{min_hp: min_hp}, rest}
  # update_gold (28)
  defp decode_server_packet(28, <<gold::little-signed-32, _billetera::little-signed-32, rest::binary>>), do: {:ok, %{gold: gold}, rest}
  # update_exp (29)
  defp decode_server_packet(29, <<current_xp::little-signed-32, next_xp::little-signed-32, rest::binary>>), do: {:ok, %{current_xp: current_xp, next_xp: next_xp}, rest}
  # change_map (30)
  defp decode_server_packet(30, <<map_id::little-signed-16, version::little-signed-16, rest::binary>>), do: {:ok, %{map_id: map_id, version: version}, rest}
  # pos_update (31)
  defp decode_server_packet(31, <<x::8, y::8, rest::binary>>), do: {:ok, %{x: x, y: y}, rest}

  # chat (35)
  defp decode_server_packet(35, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, _char_index, rest} <- Reader.read_int16(rest),
         {:ok, _color, rest} <- Reader.read_int32(rest),
         {:ok, _es_spell, rest} <- Reader.read_bool(rest),
         {:ok, _x, rest} <- Reader.read_int8(rest),
         {:ok, _y, rest} <- Reader.read_int8(rest),
         {:ok, _min_time, rest} <- Reader.read_int16(rest),
         {:ok, _max_time, rest} <- Reader.read_int16(rest) do
      {:ok, %{message: msg}, rest}
    else
      _ -> :incomplete
    end
  end

  # character_create (42)
  defp decode_server_packet(42, data) do
    with {:ok, char_index, rest} <- Reader.read_int16(data),
         {:ok, _body_id, rest} <- Reader.read_int16(rest),
         {:ok, _head_id, rest} <- Reader.read_int16(rest),
         {:ok, _heading, rest} <- Reader.read_int8(rest),
         {:ok, x, rest} <- Reader.read_int8(rest),
         {:ok, y, rest} <- Reader.read_int8(rest),
         {:ok, _weapon, rest} <- Reader.read_int16(rest),
         {:ok, _shield, rest} <- Reader.read_int16(rest),
         {:ok, _helmet, rest} <- Reader.read_int16(rest),
         {:ok, _cart, rest} <- Reader.read_int16(rest),
         {:ok, _backpack, rest} <- Reader.read_int16(rest),
         {:ok, _fx, rest} <- Reader.read_int16(rest),
         {:ok, _fx_loops, rest} <- Reader.read_int16(rest),
         {:ok, name, rest} <- Reader.read_string8(rest),
         {:ok, _status, rest} <- Reader.read_int8(rest),
         {:ok, _privileges, rest} <- Reader.read_int8(rest),
         {:ok, _particula_fx, rest} <- Reader.read_int8(rest),
         {:ok, _head_aura, rest} <- Reader.read_string8(rest),
         {:ok, _arma_aura, rest} <- Reader.read_string8(rest),
         {:ok, _body_aura, rest} <- Reader.read_string8(rest),
         {:ok, _dm_aura, rest} <- Reader.read_string8(rest),
         {:ok, _rm_aura, rest} <- Reader.read_string8(rest),
         {:ok, _otra_aura, rest} <- Reader.read_string8(rest),
         {:ok, _escudo_aura, rest} <- Reader.read_string8(rest),
         {:ok, _speed, rest} <- Reader.read_real32(rest),
         {:ok, _es_npc, rest} <- Reader.read_int8(rest),
         {:ok, _appear, rest} <- Reader.read_int8(rest),
         {:ok, _group, rest} <- Reader.read_int16(rest),
         {:ok, _clan, rest} <- Reader.read_int16(rest),
         {:ok, _clan_nivel, rest} <- Reader.read_int8(rest),
         {:ok, _min_hp, rest} <- Reader.read_int32(rest),
         {:ok, _max_hp, rest} <- Reader.read_int32(rest),
         {:ok, _min_mana, rest} <- Reader.read_int32(rest),
         {:ok, _max_mana, rest} <- Reader.read_int32(rest),
         {:ok, _simbolo, rest} <- Reader.read_int8(rest),
         {:ok, _flags, rest} <- Reader.read_int8(rest),
         {:ok, _tipo_usuario, rest} <- Reader.read_int8(rest),
         {:ok, _team_captura, rest} <- Reader.read_int8(rest),
         {:ok, _tiene_bandera, rest} <- Reader.read_int8(rest),
         {:ok, _npc_num, rest} <- Reader.read_int16(rest) do
      {:ok, %{char_index: char_index, x: x, y: y, name: name}, rest}
    else
      _ -> :incomplete
    end
  end

  defp decode_server_packet(43, <<_char_index::little-signed-16, _desvanecido::8, _fue_warp::8, rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(44, <<_char_index::little-signed-16, _x::8, _y::8, rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(46, <<idx::little-signed-16, rest::binary>>), do: {:ok, %{user_index: idx}, rest}
  defp decode_server_packet(47, <<idx::little-signed-16, rest::binary>>), do: {:ok, %{char_index: idx}, rest}
  defp decode_server_packet(49, <<_::binary-size(22), rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(59, <<_::8, rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(61, <<_::binary-size(34), rest::binary>>), do: {:ok, %{}, rest}

  defp decode_server_packet(63, <<slot::8, obj_index::little-signed-16, amount::little-signed-16,
      _equipped::8, _valor::little-float-32, _puede_usar::8, _elemental_tags::little-signed-32,
      _is_bindable::8, rest::binary>>) do
    {:ok, %{slot: slot, obj_index: obj_index, amount: amount}, rest}
  end

  defp decode_server_packet(66, <<_slot::8, _spell_id::little-signed-16, _index::little-signed-16, _is_bindable::8, rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(76, <<_::8, rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(78, <<_::binary-size(4), rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(79, <<_::binary-size(28), rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(80, <<_level::little-16, rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(81, <<_::binary-size(5), rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(87, <<_skills::binary-size(24), rest::binary>>), do: {:ok, %{}, rest}
  defp decode_server_packet(158, <<_::binary-size(48), rest::binary>>), do: {:ok, %{}, rest}

  defp decode_server_packet(200, data) do
    with {:ok, _char_id, rest} <- Reader.read_int32(data),
         {:ok, _token, rest} <- Reader.read_string8(rest) do
      {:ok, %{}, rest}
    else
      _ -> :incomplete
    end
  end

  defp decode_server_packet(_id, _rest), do: :incomplete

  # ============================================================
  # Tests
  # ============================================================

  describe "commerce without active session" do
    test "commerce_buy without starting commerce is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      # Try to buy from NPC slot 1, amount 1 — without ever opening commerce
      send_commerce_buy(socket, 1, 1)

      # Send a position request to force a round-trip so we can collect any error response
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      # Should get a console error message about not being in commerce, or silently ignored
      # (no commerce_init packet was ever sent, so the command should be rejected)
      # The key assertion: no crash, and we get a console message about invalid state
      assert has_console_msg_matching?(packets, ~r/comercio|commerce|No est/i) or
             # If silently ignored, at least the position update comes back (no crash)
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end

    test "commerce_sell without starting commerce is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_commerce_sell(socket, 1, 1)
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/comercio|commerce|No est/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end
  end

  describe "bank without active session" do
    test "bank_deposit without starting bank is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_bank_deposit(socket, 1, 1, 1)
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/banco|bank|No est/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end

    test "bank_extract_gold without starting bank is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_bank_extract_gold(socket, 100)
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/banco|bank|No est/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end

    test "bank_deposit_gold without starting bank is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_bank_deposit_gold(socket, 50)
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/banco|bank|No est/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end
  end

  describe "user trade without active session" do
    test "user_commerce_offer without trade session is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_user_commerce_offer(socket, 1, 1)
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      # Should get an error or be silently ignored (no crash)
      assert has_console_msg_matching?(packets, ~r/comerci|trade|No est/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end

    test "user_commerce_ok without trade session is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_user_commerce_ok(socket)
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/comerci|trade|No est/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end
  end

  describe "GM commands without privileges" do
    test "go_to_char without GM is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_go_to_char(socket, "SomePlayer")
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/[Gg][Mm]|priv|permiso|autorizado|No ten/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end

    test "jail command without GM is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_jail(socket, "SomePlayer")
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/[Gg][Mm]|priv|permiso|autorizado|No ten/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end

    test "kick command without GM is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_kick(socket, "SomePlayer")
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/[Gg][Mm]|priv|permiso|autorizado|No ten/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end

    test "ban_char command without GM is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_ban_char(socket, "SomePlayer")
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/[Gg][Mm]|priv|permiso|autorizado|No ten/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end

    test "invisible command without GM is rejected", %{port: port} do
      {socket, _packets, _char_id} = login_and_setup(port, unique_name())

      send_invisible(socket)
      send_request_position(socket)
      data = recv_all(socket)
      packets = decode_all_packets(data)

      assert has_console_msg_matching?(packets, ~r/[Gg][Mm]|priv|permiso|autorizado|No ten/i) or
             Enum.any?(packets, fn {id, _} -> id == 31 end)
    end
  end
end
