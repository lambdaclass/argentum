# Test script: connects to the AO TCP server using AO20 protocol, sends login, reads responses.
# Usage: mix run --no-start scripts/test_tcp_login.exs
#
# Make sure the server is running first with: mix run --no-halt

alias AoProtocol.Writer
alias AoProtocol.Reader
alias AoProtocol.PacketIds

defmodule TcpTest do
  def run do
    IO.puts("=== AO20 Protocol Test ===")
    IO.puts("Connecting to localhost:7666...")

    case :gen_tcp.connect(~c"localhost", 7666, [:binary, active: false, packet: :raw], 2000) do
      {:ok, socket} ->
        IO.puts("Connected!\n")

        # Build AO20 login packet:
        # packet_id(Int16=73) + session_token(String8) + char_id(Int32) + version(3xInt8) + md5(String8)
        session_token = "fake_token_for_testing_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        char_id = 1
        md5 = "abcdef1234567890abcdef1234567890"

        login_payload =
          Writer.write_string8(session_token) <>
          Writer.write_int32(char_id) <>
          Writer.write_int8(1) <> Writer.write_int8(0) <> Writer.write_int8(0) <>
          Writer.write_string8(md5)

        packet = Writer.build_packet(PacketIds.Client.login_existing_char(), login_payload)

        IO.puts("Sending login packet (#{byte_size(packet)} bytes, char_id=#{char_id})...")
        :ok = :gen_tcp.send(socket, packet)

        # Read all login response packets
        IO.puts("\n--- Login Response ---")
        remaining_data = read_and_decode(socket, <<>>)

        # Send walk south (ID 78): heading(Int8=3) + packet_count(Int32)
        walk_south = Writer.build_packet(
          PacketIds.Client.walk(),
          Writer.write_int8(3) <> Writer.write_int32(1)
        )

        IO.puts("\n--- Walk South ---")
        :ok = :gen_tcp.send(socket, walk_south)
        remaining_data = read_and_decode(socket, remaining_data)

        # Send walk east (ID 78): heading(Int8=2)
        walk_east = Writer.build_packet(
          PacketIds.Client.walk(),
          Writer.write_int8(2) <> Writer.write_int32(2)
        )

        IO.puts("\n--- Walk East ---")
        :ok = :gen_tcp.send(socket, walk_east)
        remaining_data = read_and_decode(socket, remaining_data)

        # Send talk (ID 75): message(String8)
        talk = Writer.build_packet(
          PacketIds.Client.talk(),
          Writer.write_string8("Hello Argentum!")
        )

        IO.puts("\n--- Talk ---")
        :ok = :gen_tcp.send(socket, talk)
        _remaining = read_and_decode(socket, remaining_data)

        :gen_tcp.close(socket)
        IO.puts("\nDone! Connection closed.")

      {:error, reason} ->
        IO.puts("Failed to connect: #{inspect(reason)}")
        IO.puts("Make sure the server is running with: mix run --no-halt")
    end
  end

  defp read_and_decode(socket, leftover) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, data} ->
        decode_all(leftover <> data)

      {:error, :timeout} ->
        if leftover != <<>> do
          decode_all(leftover)
        else
          IO.puts("  (no data)")
          <<>>
        end

      {:error, reason} ->
        IO.puts("  recv error: #{inspect(reason)}")
        <<>>
    end
  end

  defp decode_all(<<>>) do
    <<>>
  end

  defp decode_all(data) when byte_size(data) < 2 do
    data
  end

  defp decode_all(<<packet_id::little-signed-16, rest::binary>> = data) do
    case decode_packet(packet_id, rest) do
      {:ok, description, remaining} ->
        IO.puts("  [#{packet_id}] #{description}")
        decode_all(remaining)

      :need_more ->
        # Not enough data for this packet
        data
    end
  end

  # ---- Packet decoders ----

  # eConnected (1) — no payload
  defp decode_packet(1, rest), do: {:ok, "CONNECTED", rest}

  # elogged (2) — newUser(Bool)
  defp decode_packet(2, <<new_user::8, rest::binary>>) do
    {:ok, "LOGGED new_user=#{new_user != 0}", rest}
  end

  # eDisconnect (7) — no payload
  defp decode_packet(7, rest), do: {:ok, "DISCONNECT", rest}

  # eUpdateSta (25) — MinSta(Int16)
  defp decode_packet(25, <<min_sta::little-signed-16, rest::binary>>) do
    {:ok, "UPDATE_STA sta=#{min_sta}", rest}
  end

  # eUpdateMana (26) — MinMAN(Int16)
  defp decode_packet(26, <<min_mana::little-signed-16, rest::binary>>) do
    {:ok, "UPDATE_MANA mana=#{min_mana}", rest}
  end

  # eUpdateHP (27) — MinHp(Int16) + shield(Int32)
  defp decode_packet(27, <<min_hp::little-signed-16, shield::little-signed-32, rest::binary>>) do
    {:ok, "UPDATE_HP hp=#{min_hp} shield=#{shield}", rest}
  end

  # eChangeMap (30) — Map(Int16) + MapResource(Int16)
  defp decode_packet(30, <<map_id::little-signed-16, version::little-signed-16, rest::binary>>) do
    {:ok, "CHANGE_MAP map=#{map_id} version=#{version}", rest}
  end

  # ePosUpdate (31) — x(Int8) + y(Int8)
  defp decode_packet(31, <<x::8, y::8, rest::binary>>) do
    {:ok, "POS_UPDATE x=#{x} y=#{y}", rest}
  end

  # eChatOverHead (35)
  defp decode_packet(35, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, char_idx, rest} <- Reader.read_int16(rest),
         {:ok, _color, rest} <- Reader.read_int32(rest),
         {:ok, _es_spell, rest} <- Reader.read_bool(rest),
         {:ok, _x, rest} <- Reader.read_int8(rest),
         {:ok, _y, rest} <- Reader.read_int8(rest),
         {:ok, _min_time, rest} <- Reader.read_int16(rest),
         {:ok, _max_time, rest} <- Reader.read_int16(rest) do
      {:ok, "CHAT_OVER_HEAD char=#{char_idx} #{inspect(msg)}", rest}
    else
      _ -> :need_more
    end
  end

  # eConsoleMsg (37) — chat(String8) + FontIndex(Int8)
  defp decode_packet(37, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data),
         {:ok, font, rest} <- Reader.read_int8(rest) do
      {:ok, "CONSOLE_MSG font=#{font} #{inspect(msg)}", rest}
    else
      _ -> :need_more
    end
  end

  # eCharacterCreate (42) — complex, just read key fields
  defp decode_packet(42, data) do
    with {:ok, char_idx, rest} <- Reader.read_int16(data),
         {:ok, body, rest} <- Reader.read_int16(rest),
         {:ok, head, rest} <- Reader.read_int16(rest),
         {:ok, heading, rest} <- Reader.read_int8(rest),
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
         {:ok, _group_idx, rest} <- Reader.read_int16(rest),
         {:ok, _clan_idx, rest} <- Reader.read_int16(rest),
         {:ok, _clan_nivel, rest} <- Reader.read_int8(rest),
         {:ok, min_hp, rest} <- Reader.read_int32(rest),
         {:ok, max_hp, rest} <- Reader.read_int32(rest),
         {:ok, min_mana, rest} <- Reader.read_int32(rest),
         {:ok, max_mana, rest} <- Reader.read_int32(rest),
         {:ok, _simbolo, rest} <- Reader.read_int8(rest),
         {:ok, _flags, rest} <- Reader.read_int8(rest),
         {:ok, _tipo_usuario, rest} <- Reader.read_int8(rest),
         {:ok, _team_captura, rest} <- Reader.read_int8(rest),
         {:ok, _tiene_bandera, rest} <- Reader.read_int8(rest),
         {:ok, _npc_num, rest} <- Reader.read_int16(rest) do
      {:ok,
       "CHARACTER_CREATE idx=#{char_idx} body=#{body} head=#{head} " <>
         "heading=#{heading} pos=(#{x},#{y}) name=#{inspect(name)} " <>
         "hp=#{min_hp}/#{max_hp} mana=#{min_mana}/#{max_mana}", rest}
    else
      _ -> :need_more
    end
  end

  # eUserIndexInServer (46) — Int16
  defp decode_packet(46, <<idx::little-signed-16, rest::binary>>) do
    {:ok, "USER_INDEX_IN_SERVER idx=#{idx}", rest}
  end

  # eUserCharIndexInServer (47) — Int16
  defp decode_packet(47, <<idx::little-signed-16, rest::binary>>) do
    {:ok, "USER_CHAR_INDEX_IN_SERVER idx=#{idx}", rest}
  end

  # eErrorMsg (73) — message(String8)
  defp decode_packet(73, data) do
    with {:ok, msg, rest} <- Reader.read_string8(data) do
      {:ok, "ERROR_MSG #{inspect(msg)}", rest}
    else
      _ -> :need_more
    end
  end

  # Unknown
  defp decode_packet(id, _rest) do
    {:ok, "UNKNOWN(#{id}) -- stopping decode", <<>>}
  end

  defp decode_packet(_, <<>>), do: :need_more
end

TcpTest.run()
