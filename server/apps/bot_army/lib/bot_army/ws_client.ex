defmodule BotArmy.WsClient do
  @moduledoc """
  Minimal WebSocket client over raw `:gen_tcp`.

  Performs the HTTP/1.1 upgrade handshake, then sends/receives WebSocket
  binary frames. All client frames are masked per RFC 6455.
  """

  require Logger

  @ws_path "/ao"

  @doc """
  Connect to the WebSocket server. Returns `{:ok, socket}` or `{:error, reason}`.
  """
  def connect(host \\ ~c"127.0.0.1", port \\ 7667) do
    case :gen_tcp.connect(host, port, [:binary, active: false, packet: :raw], 5_000) do
      {:ok, socket} ->
        key = Base.encode64(:crypto.strong_rand_bytes(16))

        handshake =
          "GET #{@ws_path} HTTP/1.1\r\n" <>
            "Host: #{host}:#{port}\r\n" <>
            "Upgrade: websocket\r\n" <>
            "Connection: Upgrade\r\n" <>
            "Sec-WebSocket-Key: #{key}\r\n" <>
            "Sec-WebSocket-Version: 13\r\n" <>
            "\r\n"

        :ok = :gen_tcp.send(socket, handshake)

        case recv_handshake(socket, <<>>, System.monotonic_time(:millisecond) + 5_000) do
          {:ok, _rest} ->
            # Switch to active mode so the owning process gets {:tcp, ...} messages
            :inet.setopts(socket, active: true)
            {:ok, socket}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, {:handshake_failed, reason}}
        end

      error ->
        error
    end
  end

  @doc "Send a binary payload as a WebSocket binary frame (opcode 2, masked)."
  def send_binary(socket, payload) do
    frame = encode_frame(payload)
    :gen_tcp.send(socket, frame)
  end

  @doc """
  Decode WebSocket frames from a TCP data buffer.
  Returns `{frames, rest}` where frames is a list of binaries (payloads).
  """
  def decode_frames(data) do
    decode_frames(data, [])
  end

  # --- Private ---

  defp recv_handshake(socket, buf, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      timeout = min(remaining, 5_000) |> trunc()

      case :gen_tcp.recv(socket, 0, timeout) do
        {:ok, data} ->
          buf = buf <> data

          if String.contains?(buf, "\r\n\r\n") do
            case String.split(buf, "\r\n\r\n", parts: 2) do
              [header, rest] ->
                if String.contains?(header, "101") do
                  {:ok, rest}
                else
                  {:error, {:bad_status, header}}
                end

              _ ->
                {:error, :bad_response}
            end
          else
            recv_handshake(socket, buf, deadline)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp encode_frame(payload) do
    mask_key = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)
    masked = mask(payload, mask_key)

    length_bytes =
      cond do
        len <= 125 ->
          <<1::1, len::7>>

        len <= 65_535 ->
          <<1::1, 126::7, len::16>>

        true ->
          <<1::1, 127::7, len::64>>
      end

    # FIN=1, RSV=0, opcode=2 (binary)
    <<1::1, 0::3, 2::4>> <> length_bytes <> mask_key <> masked
  end

  defp mask(payload, <<m0, m1, m2, m3>>) do
    mask_bytes = <<m0, m1, m2, m3>>
    do_mask(payload, mask_bytes, 0, <<>>)
  end

  defp do_mask(<<>>, _mask, _i, acc), do: acc

  defp do_mask(<<byte, rest::binary>>, mask, i, acc) do
    mask_byte = :binary.at(mask, rem(i, 4))
    do_mask(rest, mask, i + 1, <<acc::binary, Bitwise.bxor(byte, mask_byte)>>)
  end

  defp decode_frames(data, acc) when byte_size(data) < 2, do: {Enum.reverse(acc), data}

  defp decode_frames(<<_fin::1, _rsv::3, _opcode::4, 0::1, 127::7, len::64, rest::binary>> = data, acc) do
    if byte_size(rest) >= len do
      <<payload::binary-size(len), remaining::binary>> = rest
      decode_frames(remaining, [payload | acc])
    else
      {Enum.reverse(acc), data}
    end
  end

  defp decode_frames(<<_fin::1, _rsv::3, _opcode::4, 0::1, 126::7, len::16, rest::binary>> = data, acc) do
    if byte_size(rest) >= len do
      <<payload::binary-size(len), remaining::binary>> = rest
      decode_frames(remaining, [payload | acc])
    else
      {Enum.reverse(acc), data}
    end
  end

  defp decode_frames(<<_fin::1, _rsv::3, _opcode::4, 0::1, len::7, rest::binary>> = data, acc) when len <= 125 do
    if byte_size(rest) >= len do
      <<payload::binary-size(len), remaining::binary>> = rest
      decode_frames(remaining, [payload | acc])
    else
      {Enum.reverse(acc), data}
    end
  end

  defp decode_frames(data, acc), do: {Enum.reverse(acc), data}
end
