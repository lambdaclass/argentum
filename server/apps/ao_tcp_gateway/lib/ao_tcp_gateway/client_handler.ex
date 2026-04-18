defmodule AoTcpGateway.ClientHandler do
  @moduledoc """
  Handles a single TCP client connection.

  Thin transport layer: decodes packets, delegates to SessionLogic,
  encodes and sends response packets over TCP.
  """

  @behaviour :ranch_protocol

  require Logger

  alias AoProtocol.Server.Encoder
  alias AoTcpGateway.{FloodGuard, PacketCounter, SessionLogic}

  @backpressure_warn Application.compile_env(:ao_tcp_gateway, :backpressure_warn, 500)
  @backpressure_disconnect Application.compile_env(:ao_tcp_gateway, :backpressure_disconnect, 1000)

  @impl :ranch_protocol
  def start_link(ref, socket, transport, _opts) do
    pid = :proc_lib.spawn_link(__MODULE__, :init, [ref, socket, transport])
    {:ok, pid}
  end

  def init(ref, socket, transport) do
    :ok = :ranch.accept_ack(ref)
    transport.setopts(socket, active: :once, nodelay: true, send_timeout: 5_000, send_timeout_close: true)

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
      in_commerce: false,
      in_bank: false,
      in_trade: false,
      is_gm: false,
      is_dead: false,
      hogar_timer_ref: nil,
      viewing_forum_id: nil,
      flood_guard: FloodGuard.new(),
      packet_counters: PacketCounter.new()
    })
  end

  defp loop(state) do
    case check_backpressure(state) do
      :disconnect -> :ok
      :ok -> do_loop(state)
    end
  end

  defp do_loop(state) do
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

        if reason == :timeout do
          :telemetry.execute(
            [:arena, :session, :backpressure],
            %{mailbox_len: 0},
            %{character_id: state.character_id, action: :disconnect, transport: :tcp, cause: :send_timeout}
          )
        end

        SessionLogic.cleanup(state)

      {:send_packet, command} ->
        send_to_client(state, command)
        loop(state)

      {:send_raw, binary} ->
        state.transport.send(state.socket, binary)
        loop(state)

      {:set_viewing_forum, forum_id} ->
        loop(%{state | viewing_forum_id: forum_id})

      :trade_started ->
        loop(%{state | in_trade: true})

      {:transfer, dest_map, dest_x, dest_y, entity} ->
        {state, packets} = SessionLogic.transfer(state, dest_map, dest_x, dest_y, entity)
        send_packets(state, packets)
        loop(state)

      {:autosave, entity} ->
        if entity.map_id == state.map_id do
          SessionLogic.autosave(entity)
        end
        loop(state)

      :shutdown_drain ->
        Logger.info("Shutdown drain: closing session for char #{inspect(state.character_id)}")
        SessionLogic.cleanup(state)
        state.transport.close(state.socket)

      :hogar_arrive ->
        case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
          {:ok, entity} ->
            case SessionLogic.handle_hogar_arrive(state, entity) do
              {:transfer, dest_map, dest_x, dest_y, ent} ->
                {state, packets} = SessionLogic.transfer(state, dest_map, dest_x, dest_y, ent)
                state = Map.put(state, :hogar_timer_ref, nil)
                packets = packets ++ [{:console_msg, %{message: "Has llegado a tu hogar.", font_index: 0}}]
                send_packets(state, packets)
                loop(state)

              {state, packets} ->
                send_packets(state, packets)
                loop(state)
            end

          _ ->
            state = Map.put(state, :hogar_timer_ref, nil)
            loop(state)
        end
    end
  end

  defp check_backpressure(state) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    cond do
      len >= @backpressure_disconnect ->
        Logger.warning("Backpressure disconnect: mailbox=#{len} char=#{inspect(state.character_id)}")

        :telemetry.execute(
          [:arena, :session, :backpressure],
          %{mailbox_len: len},
          %{character_id: state.character_id, action: :disconnect, transport: :tcp, cause: :mailbox_overflow}
        )

        SessionLogic.cleanup(state)
        state.transport.close(state.socket)
        :disconnect

      len >= @backpressure_warn ->
        :telemetry.execute(
          [:arena, :session, :backpressure],
          %{mailbox_len: len},
          %{character_id: state.character_id, action: :warn, transport: :tcp, cause: :mailbox_overflow}
        )

        :ok

      true ->
        :ok
    end
  end

  defp process_data(state, data) do
    buffer = state.buffer <> data
    decode_loop(%{state | buffer: buffer})
  end

  defp decode_loop(state) do
    if AoTcpGateway.ShutdownDrain.shutdown_in_progress?() do
      # Shutdown in progress — stop processing commands, close connection
      Logger.info("Shutdown gate: rejecting commands for char #{inspect(state.character_id)}")
      SessionLogic.cleanup(state)
      state.transport.close(state.socket)
      %{state | character_id: nil, map_id: nil}
    else
      decode_loop_inner(state)
    end
  end

  defp decode_loop_inner(state) do
    case AoProtocol.Client.Decoder.decode(state.buffer) do
      {:ok, command, rest} ->
        case FloodGuard.check(state.flood_guard) do
          {:ok, guard} ->
            state = %{state | flood_guard: guard, buffer: rest}

            case PacketCounter.verify(state.packet_counters, command) do
              {:ok, counters} ->
                state = %{state | packet_counters: counters}
                {state, packets} = dispatch_command(state, command)
                send_packets(state, packets)
                decode_loop(state)

              {:replay, _counters} ->
                Logger.warning("Packet replay detected, disconnecting #{inspect(state.character_id)}")
                send_to_client(state, {:error_msg, %{message: "Packet replay detected. Disconnected."}})
                SessionLogic.cleanup(state)
                state.transport.close(state.socket)
                %{state | character_id: nil, map_id: nil}
            end

          {:error, :flood} ->
            Logger.warning("Flood detected, disconnecting #{inspect(state.character_id)}")
            send_to_client(state, {:error_msg, %{message: "Too many packets. Disconnected."}})
            SessionLogic.cleanup(state)
            state.transport.close(state.socket)
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
