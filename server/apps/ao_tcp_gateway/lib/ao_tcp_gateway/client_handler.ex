defmodule AoTcpGateway.ClientHandler do
  @moduledoc """
  Handles a single TCP client connection.

  Thin transport layer: decodes packets, delegates to SessionLogic,
  encodes and sends response packets over TCP.
  """

  @behaviour :ranch_protocol

  require Logger

  alias AoProtocol.{Classify, Server.Encoder}
  alias AoSession.{Egress, Outbound, PressureRegistry}
  alias AoTcpGateway.{FloodGuard, PacketCounter, SessionLogic}

  @backpressure_warn Application.compile_env(:ao_tcp_gateway, :backpressure_warn, 500)
  @backpressure_disconnect Application.compile_env(:ao_tcp_gateway, :backpressure_disconnect, 1000)
  @flush_batch 128

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
      packet_counters: PacketCounter.new(),
      egress: Egress.new(self()),
      pressure: :ok
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
        PressureRegistry.clear(self())
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

        PressureRegistry.clear(self())
        SessionLogic.cleanup(state)

      {:egress, %Outbound{} = out} ->
        handle_outbound(state, out)

      {:send_packet, command} ->
        handle_outbound(state, wrap_command(command))

      {:send_raw, binary} ->
        handle_outbound(state, wrap_raw(binary))

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
        PressureRegistry.clear(self())
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

  # ---- Egress integration ----

  defp handle_outbound(state, %Outbound{} = out) do
    case Egress.push(state.egress, out) do
      {:ok, eg} ->
        {bins, eg} = Egress.flush(eg, @flush_batch)
        write_bins(state, bins)
        state = update_pressure(state, eg)
        loop(state)

      {:disconnect, :critical_overflow, _eg} ->
        Logger.warning(
          "Egress critical overflow, disconnecting char=#{inspect(state.character_id)}"
        )

        :telemetry.execute(
          [:arena, :session, :backpressure],
          %{critical_depth: state.egress.critical_depth},
          %{
            character_id: state.character_id,
            action: :disconnect,
            transport: :tcp,
            cause: :critical_overflow
          }
        )

        PressureRegistry.clear(self())
        SessionLogic.cleanup(state)
        state.transport.close(state.socket)
    end
  end

  defp write_bins(_state, []), do: :ok

  defp write_bins(state, bins) do
    state.transport.send(state.socket, Enum.reduce(bins, <<>>, &(&2 <> &1)))
  end

  defp update_pressure(state, eg) do
    new_level = Egress.pressure_level(eg)

    state =
      if new_level != state.pressure do
        PressureRegistry.publish(self(), new_level)

        :telemetry.execute(
          [:arena, :session, :backpressure],
          %{
            queued_bytes: eg.queued_bytes,
            critical_depth: eg.critical_depth,
            lossy_depth: eg.lossy_depth,
            coalesce_size: map_size(eg.coalesce_map),
            dropped_lossy: eg.dropped_lossy,
            dropped_coalesce_replaced: eg.dropped_coalesce_replaced
          },
          %{
            character_id: state.character_id,
            transport: :tcp,
            level: new_level,
            prev_level: state.pressure,
            action: :pressure_change
          }
        )

        %{state | pressure: new_level}
      else
        state
      end

    %{state | egress: eg}
  end

  defp wrap_command(command) do
    bin = Encoder.encode(command)
    wrap_raw(bin)
  end

  defp wrap_raw(<<packet_id::little-signed-integer-16, _::binary>> = bin) do
    class = Classify.class_for(packet_id)
    Outbound.from_class(class, bin, Classify.coalesce_key_for(packet_id))
  end

  defp wrap_raw(bin), do: Outbound.critical(bin)

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

        PressureRegistry.clear(self())
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
