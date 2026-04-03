defmodule AoTcpGateway.ClientHandler do
  @moduledoc """
  Handles a single TCP client connection.

  Thin transport layer: decodes packets, delegates to SessionLogic,
  encodes and sends response packets over TCP.
  """

  @behaviour :ranch_protocol

  require Logger

  alias AoProtocol.Server.Encoder
  alias AoTcpGateway.{FloodGuard, SessionLogic}

  @impl :ranch_protocol
  def start_link(ref, socket, transport, _opts) do
    pid = :proc_lib.spawn_link(__MODULE__, :init, [ref, socket, transport])
    {:ok, pid}
  end

  def init(ref, socket, transport) do
    :ok = :ranch.accept_ack(ref)
    transport.setopts(socket, active: :once, nodelay: true)

    Logger.info("Client connected")

    loop(%{
      socket: socket,
      transport: transport,
      buffer: <<>>,
      account_id: nil,
      character_id: nil,
      char_index: nil,
      map_id: nil,
      entity: nil,
      target_x: nil,
      target_y: nil,
      flood_guard: FloodGuard.new()
    })
  end

  defp loop(state) do
    receive do
      {:tcp, socket, data} ->
        state.transport.setopts(socket, active: :once)
        state = process_data(state, data)
        loop(state)

      {:tcp_closed, _socket} ->
        Logger.info("Client disconnected")
        SessionLogic.cleanup(state)

      {:tcp_error, _socket, reason} ->
        Logger.warning("Client TCP error: #{inspect(reason)}")
        SessionLogic.cleanup(state)

      {:send_packet, command} ->
        send_to_client(state, command)
        loop(state)

      {:send_raw, binary} ->
        state.transport.send(state.socket, binary)
        loop(state)

      {:transfer, dest_map, dest_x, dest_y, entity} ->
        {state, packets} = SessionLogic.transfer(state, dest_map, dest_x, dest_y, entity)
        send_packets(state, packets)
        loop(state)

      {:autosave, entity} ->
        if entity.map_id == state.map_id do
          SessionLogic.autosave(entity)
        end
        loop(state)
    end
  end

  defp process_data(state, data) do
    buffer = state.buffer <> data
    decode_loop(%{state | buffer: buffer})
  end

  defp decode_loop(state) do
    case AoProtocol.Client.Decoder.decode(state.buffer) do
      {:ok, command, rest} ->
        case FloodGuard.check(state.flood_guard) do
          {:ok, guard} ->
            state = %{state | flood_guard: guard, buffer: rest}
            {state, packets} = dispatch_command(state, command)
            send_packets(state, packets)
            decode_loop(state)

          {:error, :flood} ->
            Logger.warning("Flood detected, disconnecting #{inspect(state.character_id)}")
            send_to_client(state, {:error_msg, %{message: "Too many packets. Disconnected."}})
            SessionLogic.cleanup(state)
            state.transport.close(state.socket)
            # Nil out character_id so the {:tcp_closed} handler's cleanup is a no-op
            %{state | character_id: nil, map_id: nil}
        end

      :incomplete ->
        state

      {:error, reason} ->
        Logger.warning("Packet decode error: #{inspect(reason)}")
        state
    end
  end

  # ---- Command dispatch ----

  defp dispatch_command(state, {:login_existing_char, %{char_id: char_id, session_token: token}}) do
    Logger.info("Login attempt: char_id=#{char_id}")
    SessionLogic.login_existing(state, char_id, token)
  end

  defp dispatch_command(state, {:login_new_char, params}) do
    Logger.info("New character attempt: #{params.username}")
    SessionLogic.login_new(state, params)
  end

  defp dispatch_command(state, {:quit, _}) do
    state.transport.close(state.socket)
    {state, []}
  end

  defp dispatch_command(state, command) do
    SessionLogic.handle_command(state, command)
  end

  # ---- Transport ----

  defp send_packets(state, packets) do
    Enum.each(packets, &send_to_client(state, &1))
  end

  defp send_to_client(state, command) do
    packet = Encoder.encode(command)
    state.transport.send(state.socket, packet)
  end
end
