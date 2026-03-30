defmodule AoTcpGateway.WsIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @ws_port 7667
  @ws_host ~c"127.0.0.1"
  @ws_path "/ao"

  # Packet IDs (server -> client)
  @pkt_logged 2
  @pkt_user_index_in_server 46
  @pkt_change_map 30
  @pkt_session_token 200

  # Packet IDs (client -> server)
  @pkt_login_new_char 74
  @pkt_login_existing_char 73
  @pkt_walk 78

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})

    :ok
  end

  # -------------------------------------------------------------------
  # Tests
  # -------------------------------------------------------------------

  test "login creates character and receives game state" do
    name = "TestChar_#{:rand.uniform(999_999)}"
    {:ok, socket} = ws_connect()

    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok = ws_send(socket, build_create_char_packet(name))

    {:ok, payload} = ws_recv(socket, 5_000)

    assert byte_size(payload) > 0

    packet_ids = extract_packet_ids(payload)

    assert @pkt_logged in packet_ids,
           "Expected logged (ID 2) in response, got: #{inspect(packet_ids)}"

    assert @pkt_user_index_in_server in packet_ids,
           "Expected user_index_in_server (ID 46) in response, got: #{inspect(packet_ids)}"

    assert @pkt_change_map in packet_ids,
           "Expected change_map (ID 30) in response, got: #{inspect(packet_ids)}"

    assert @pkt_session_token in packet_ids,
           "Expected session_token (ID 200) in response, got: #{inspect(packet_ids)}"
  end

  test "walk packet after login doesn't crash" do
    name = "WalkTest_#{:rand.uniform(999_999)}"
    {:ok, socket} = ws_connect()

    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok = ws_send(socket, build_create_char_packet(name))
    {:ok, _login_payload} = ws_recv(socket, 5_000)

    :ok = ws_send(socket, build_walk_packet(:north))
    :ok = ws_send(socket, build_walk_packet(:south))

    Process.sleep(200)

    assert {:ok, _} = :inet.peername(socket)
  end

  test "duplicate login returns error" do
    name = "DupTest_#{:rand.uniform(999_999)}"
    {:ok, socket1} = ws_connect()

    on_exit(fn -> :gen_tcp.close(socket1) end)

    # First login — create character
    :ok = ws_send(socket1, build_create_char_packet(name))
    {:ok, payload1} = ws_recv(socket1, 5_000)
    packet_ids = extract_packet_ids(payload1)
    assert @pkt_logged in packet_ids

    # Second connection — try to create same name
    {:ok, socket2} = ws_connect()

    on_exit(fn -> :gen_tcp.close(socket2) end)

    :ok = ws_send(socket2, build_create_char_packet(name))
    {:ok, payload2} = ws_recv(socket2, 5_000)

    # Should get error_msg (ID 73) — name already taken
    <<first_id::little-signed-integer-16, _rest::binary>> = payload2
    assert first_id == 73, "Expected error_msg (ID 73), got packet ID #{first_id}"
  end

  # -------------------------------------------------------------------
  # WebSocket helpers
  # -------------------------------------------------------------------

  defp ws_connect do
    {:ok, socket} = :gen_tcp.connect(@ws_host, @ws_port, [:binary, active: false, packet: :raw])

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request =
      "GET #{@ws_path} HTTP/1.1\r\n" <>
        "Host: #{@ws_host}:#{@ws_port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(socket, request)

    {:ok, response} = recv_until_double_crlf(socket, <<>>, 5_000)
    assert response =~ "101", "Expected 101 Switching Protocols, got: #{response}"

    {:ok, socket}
  end

  defp ws_send(socket, payload) when is_binary(payload) do
    mask_key = :crypto.strong_rand_bytes(4)
    masked_payload = mask(payload, mask_key)
    len = byte_size(payload)

    header =
      cond do
        len <= 125 ->
          <<0x82, Bitwise.bor(0x80, len)::8>>

        len <= 65_535 ->
          <<0x82, Bitwise.bor(0x80, 126)::8, len::16>>

        true ->
          <<0x82, Bitwise.bor(0x80, 127)::8, len::64>>
      end

    :gen_tcp.send(socket, [header, mask_key, masked_payload])
  end

  defp ws_recv(socket, timeout) do
    case :gen_tcp.recv(socket, 2, timeout) do
      {:ok, <<fin_opcode, mask_len>>} ->
        opcode = Bitwise.band(fin_opcode, 0x0F)

        if opcode == 8 do
          {:error, :ws_close}
        else
          _masked = Bitwise.band(mask_len, 0x80) != 0
          len_indicator = Bitwise.band(mask_len, 0x7F)

          payload_length =
            cond do
              len_indicator <= 125 ->
                len_indicator

              len_indicator == 126 ->
                {:ok, <<ext_len::16>>} = :gen_tcp.recv(socket, 2, timeout)
                ext_len

              len_indicator == 127 ->
                {:ok, <<ext_len::64>>} = :gen_tcp.recv(socket, 8, timeout)
                ext_len
            end

          if payload_length > 0 do
            {:ok, payload} = :gen_tcp.recv(socket, payload_length, timeout)
            {:ok, payload}
          else
            {:ok, <<>>}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Packet builders
  # -------------------------------------------------------------------

  defp build_create_char_packet(name) do
    session_token = "test_token"
    md5 = "fake_md5_hash"
    race = 1      # Human
    gender = 1    # Male
    class = 6     # Guerrero
    head = 1
    home_city = 1 # Ullathorpe

    <<@pkt_login_new_char::little-signed-integer-16,
      byte_size(session_token)::little-signed-integer-16,
      session_token::binary,
      byte_size(name)::little-signed-integer-16,
      name::binary,
      0::8, 13::8, 0::8,
      byte_size(md5)::little-signed-integer-16,
      md5::binary,
      race::8, gender::8, class::8,
      head::little-signed-integer-16,
      home_city::8>>
  end

  defp build_walk_packet(direction) do
    heading =
      case direction do
        :north -> 1
        :east -> 2
        :south -> 3
        :west -> 4
      end

    <<@pkt_walk::little-signed-integer-16, heading::8, 1::little-signed-integer-32>>
  end

  # -------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------

  defp mask(payload, mask_key) do
    mask_bytes = :binary.copy(mask_key, div(byte_size(payload), 4) + 1)
    mask_bytes = binary_part(mask_bytes, 0, byte_size(payload))
    :crypto.exor(payload, mask_bytes)
  end

  defp recv_until_double_crlf(socket, acc, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        new_acc = acc <> data

        if String.contains?(new_acc, "\r\n\r\n") do
          {:ok, new_acc}
        else
          recv_until_double_crlf(socket, new_acc, timeout)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  defp extract_packet_ids(payload) do
    extract_packet_ids_acc(payload, [])
  end

  defp extract_packet_ids_acc(<<>>, acc), do: Enum.reverse(acc)

  defp extract_packet_ids_acc(<<id::little-signed-integer-16, rest::binary>>, acc) do
    case skip_packet_payload(id, rest) do
      {:ok, remaining} ->
        extract_packet_ids_acc(remaining, [id | acc])

      :unknown ->
        Enum.reverse([id | acc])
    end
  end

  defp extract_packet_ids_acc(_other, acc), do: Enum.reverse(acc)

  # logged (2): Bool (1 byte)
  defp skip_packet_payload(2, <<_::binary-size(1), rest::binary>>), do: {:ok, rest}

  # disconnect (7): no payload
  defp skip_packet_payload(7, rest), do: {:ok, rest}

  # user_index_in_server (46): Int16 (2 bytes)
  defp skip_packet_payload(46, <<_::binary-size(2), rest::binary>>), do: {:ok, rest}

  # user_char_index_in_server (47): Int16 (2 bytes)
  defp skip_packet_payload(47, <<_::binary-size(2), rest::binary>>), do: {:ok, rest}

  # change_map (30): Int16 + Int16 (4 bytes)
  defp skip_packet_payload(30, <<_::binary-size(4), rest::binary>>), do: {:ok, rest}

  # pos_update (31): Int8 + Int8 (2 bytes)
  defp skip_packet_payload(31, <<_::binary-size(2), rest::binary>>), do: {:ok, rest}

  # update_hp (27): Int16 + Int32 (6 bytes)
  defp skip_packet_payload(27, <<_::binary-size(6), rest::binary>>), do: {:ok, rest}

  # update_mana (26): Int16 (2 bytes)
  defp skip_packet_payload(26, <<_::binary-size(2), rest::binary>>), do: {:ok, rest}

  # update_sta (25): Int16 (2 bytes)
  defp skip_packet_payload(25, <<_::binary-size(2), rest::binary>>), do: {:ok, rest}

  # update_gold (28): Int32 + Int32 (8 bytes)
  defp skip_packet_payload(28, <<_::binary-size(8), rest::binary>>), do: {:ok, rest}

  # update_hunger_and_thirst (78): Int8 * 4 (4 bytes)
  defp skip_packet_payload(78, <<_::binary-size(4), rest::binary>>), do: {:ok, rest}

  # change_inventory_slot (63): Int8 + Int16 + Int16 + Bool + Real32 + Int8 + Int32 + Bool (16 bytes)
  defp skip_packet_payload(63, <<_::binary-size(16), rest::binary>>), do: {:ok, rest}

  # console_msg (37): String8 + Int8
  defp skip_packet_payload(37, data) do
    case data do
      <<len::little-signed-integer-16, _str::binary-size(len), _font::8, rest::binary>> ->
        {:ok, rest}

      _ ->
        :unknown
    end
  end

  # error_msg (73): String8
  defp skip_packet_payload(73, data) do
    case data do
      <<len::little-signed-integer-16, _str::binary-size(len), rest::binary>> ->
        {:ok, rest}

      _ ->
        :unknown
    end
  end

  # level_up (80): Int16 (2 bytes)
  defp skip_packet_payload(80, <<_::binary-size(2), rest::binary>>), do: {:ok, rest}

  # update_exp (29): Int32 + Int32 (8 bytes)
  defp skip_packet_payload(29, <<_::binary-size(8), rest::binary>>), do: {:ok, rest}

  # change_spell_slot (66): Int8 + Int16 + String8
  defp skip_packet_payload(66, <<_slot::8, _spell_id::binary-size(2), rest::binary>>) do
    case rest do
      <<len::little-signed-integer-16, _str::binary-size(len), rest::binary>> -> {:ok, rest}
      _ -> :unknown
    end
  end

  # intervals (158): 12 * Int32 (48 bytes)
  defp skip_packet_payload(158, <<_::binary-size(48), rest::binary>>), do: {:ok, rest}

  # session_token (200): Int32 + String8
  defp skip_packet_payload(200, <<_char_id::little-signed-integer-32, rest::binary>>) do
    case rest do
      <<len::little-signed-integer-16, _str::binary-size(len), rest::binary>> -> {:ok, rest}
      _ -> :unknown
    end
  end

  # character_create (42): complex packet
  defp skip_packet_payload(42, data) do
    fixed_before_name = 23

    case data do
      <<_::binary-size(fixed_before_name), rest::binary>> ->
        with <<name_len::little-signed-integer-16, _::binary-size(name_len), rest::binary>> <- rest,
             <<_::binary-size(3), rest::binary>> <- rest,
             {:ok, rest} <- skip_string8(rest),
             {:ok, rest} <- skip_string8(rest),
             {:ok, rest} <- skip_string8(rest),
             {:ok, rest} <- skip_string8(rest),
             {:ok, rest} <- skip_string8(rest),
             {:ok, rest} <- skip_string8(rest),
             {:ok, rest} <- skip_string8(rest),
             <<_::binary-size(34), rest::binary>> <- rest do
          {:ok, rest}
        else
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  # character_move (44): Int16 + Int8 + Int8 (4 bytes)
  defp skip_packet_payload(44, <<_::binary-size(4), rest::binary>>), do: {:ok, rest}

  # character_remove (43): Int16 (2 bytes)
  defp skip_packet_payload(43, <<_::binary-size(2), rest::binary>>), do: {:ok, rest}

  # Fallback: unknown packet
  defp skip_packet_payload(_id, _data), do: :unknown

  defp skip_string8(<<len::little-signed-integer-16, _::binary-size(len), rest::binary>>),
    do: {:ok, rest}

  defp skip_string8(_), do: :unknown
end
