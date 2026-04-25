defmodule AoTcpGateway.WsHandler do
  @moduledoc """
  Cowboy WebSocket handler that speaks AO20 binary protocol.

  Thin transport layer: decodes packets, delegates to SessionLogic,
  encodes and sends response packets over WebSocket frames.
  """

  require Logger

  alias AoProtocol.{Classify, Server.Encoder}
  alias AoProtocol.Client.Decoder
  alias AoSession.{Egress, Outbound, PressureRegistry}
  alias AoTcpGateway.{FloodGuard, PacketCounter, SessionLogic}

  # Idle timeout: disconnect if no data (including pong) for 90s.
  # We send pings every 30s so a live client resets the timer.
  @ws_idle_timeout 90_000
  @ping_interval 30_000

  @backpressure_warn Application.compile_env(:ao_tcp_gateway, :backpressure_warn, 500)
  @backpressure_disconnect Application.compile_env(:ao_tcp_gateway, :backpressure_disconnect, 1000)
  @flush_batch 128

  # ---- Cowboy callbacks ----

  def init(req, state) do
    {:cowboy_websocket, req, state, %{idle_timeout: @ws_idle_timeout}}
  end

  def websocket_init(_state) do
    Logger.info("WebSocket client connected")
    Process.send_after(self(), :ws_ping, @ping_interval)

    {:ok,
     %{
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
     }}
  end

  def websocket_handle({:binary, data}, state) do
    if AoTcpGateway.ShutdownDrain.shutdown_in_progress?() do
      Logger.info("Shutdown gate: rejecting WS commands for char #{inspect(state.character_id)}")
      SessionLogic.cleanup(state)
      {:reply, {:close, 1001, "Server shutting down"}, state}
    else
      buffer = state.buffer <> data
      {state, frames} = decode_loop(%{state | buffer: buffer}, [])
      reply(state, frames)
    end
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  # Egress envelope from producers (primary path)
  def websocket_info({:egress, %Outbound{} = out}, state) do
    handle_outbound(state, out)
  end

  # Legacy: direct send with a command tuple. Shim during migration —
  # wraps + classifies by packet ID and routes through egress.
  def websocket_info({:send_packet, command}, state) do
    handle_outbound(state, wrap_command(command))
  end

  # Legacy: pre-encoded raw bytes. Shim during migration — classifies by
  # packet ID from the first 2 bytes and routes through egress.
  def websocket_info({:send_raw, binary}, state) do
    handle_outbound(state, wrap_raw(binary))
  end

  def websocket_info(:trade_started, state) do
    {:ok, %{state | in_trade: true}}
  end

  def websocket_info({:set_viewing_forum, forum_id}, state) do
    {:ok, %{state | viewing_forum_id: forum_id}}
  end

  # Map transfer request from MapServer
  def websocket_info({:transfer, dest_map, dest_x, dest_y, entity}, state) do
    {state, packets} = SessionLogic.transfer(state, dest_map, dest_x, dest_y, entity)
    reply(state, encode_frames(packets))
  end

  # Autosave from MapServer — guard against stale saves during map transfer
  def websocket_info({:autosave, entity}, state) do
    if entity.map_id == state.map_id do
      SessionLogic.autosave(entity)
    end
    {:ok, state}
  end

  def websocket_info(:ws_ping, state) do
    Process.send_after(self(), :ws_ping, @ping_interval)
    {:reply, :ping, state}
  end

  def websocket_info(:hogar_arrive, state) do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} ->
        case SessionLogic.handle_hogar_arrive(state, entity) do
          {:transfer, dest_map, dest_x, dest_y, ent} ->
            {state, packets} = SessionLogic.transfer(state, dest_map, dest_x, dest_y, ent)
            state = Map.put(state, :hogar_timer_ref, nil)
            packets = packets ++ [{:console_msg, %{message: "Has llegado a tu hogar.", font_index: 0}}]
            reply(state, encode_frames(packets))

          {state, packets} ->
            reply(state, encode_frames(packets))
        end

      _ ->
        {:ok, Map.put(state, :hogar_timer_ref, nil)}
    end
  end

  def websocket_info(:shutdown_drain, state) do
    Logger.info("Shutdown drain: closing WS session for char #{inspect(state.character_id)}")
    SessionLogic.cleanup(state)
    {:reply, {:close, 1001, "Server shutting down"}, state}
  end

  def websocket_info(_info, state), do: {:ok, state}

  def terminate(_reason, _req, state) do
    Logger.info("WebSocket client disconnected")
    PressureRegistry.clear(self())
    SessionLogic.cleanup(state)
    :ok
  end

  # ---- Egress integration ----

  defp handle_outbound(state, %Outbound{} = out) do
    case check_backpressure(state) do
      :disconnect ->
        PressureRegistry.clear(self())
        {:reply, {:close, 1008, "mailbox overflow"}, state}

      :ok ->
        do_handle_outbound(state, out)
    end
  end

  defp do_handle_outbound(state, %Outbound{} = out) do
    case Egress.push(state.egress, out) do
      {:ok, eg} ->
        {bins, eg} = Egress.flush(eg, @flush_batch)
        state = update_pressure(state, eg)

        case bins do
          [] -> {:ok, state}
          _ -> {:reply, {:binary, Enum.reduce(bins, <<>>, &(&2 <> &1))}, state}
        end

      {:disconnect, :critical_overflow, _eg} ->
        Logger.warning(
          "WS egress critical overflow, disconnecting char=#{inspect(state.character_id)}"
        )

        :telemetry.execute(
          [:arena, :session, :backpressure],
          %{critical_depth: state.egress.critical_depth},
          %{
            character_id: state.character_id,
            action: :disconnect,
            transport: :websocket,
            cause: :critical_overflow
          }
        )

        PressureRegistry.clear(self())
        SessionLogic.cleanup(state)
        {:reply, {:close, 1008, "egress overflow"}, state}
    end
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
            transport: :websocket,
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

  # ---- Mailbox backpressure (legacy fuse) ----

  defp check_backpressure(state) do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)

    cond do
      len >= @backpressure_disconnect ->
        Logger.warning("WS backpressure disconnect: mailbox=#{len} char=#{inspect(state.character_id)}")

        :telemetry.execute(
          [:arena, :session, :backpressure],
          %{mailbox_len: len},
          %{character_id: state.character_id, action: :disconnect, transport: :websocket, cause: :mailbox_overflow}
        )

        SessionLogic.cleanup(state)
        :disconnect

      len >= @backpressure_warn ->
        :telemetry.execute(
          [:arena, :session, :backpressure],
          %{mailbox_len: len},
          %{character_id: state.character_id, action: :warn, transport: :websocket, cause: :mailbox_overflow}
        )

        :ok

      true ->
        :ok
    end
  end

  # ---- Decode loop ----

  defp decode_loop(state, frames) do
    case Decoder.decode(state.buffer) do
      {:ok, command, rest} ->
        case FloodGuard.check(state.flood_guard) do
          {:ok, guard} ->
            state = %{state | flood_guard: guard, buffer: rest}

            case PacketCounter.verify(state.packet_counters, command) do
              {:ok, counters} ->
                state = %{state | packet_counters: counters}
                {state, new_frames} = dispatch_command(state, command)
                decode_loop(state, frames ++ new_frames)

              {:replay, _counters} ->
                Logger.warning("WS packet replay detected, disconnecting #{inspect(state.character_id)}")
                SessionLogic.cleanup(state)
                state = %{state | character_id: nil, map_id: nil}
                error_frame = {:binary, Encoder.encode({:error_msg, %{message: "Packet replay detected."}})}
                {state, frames ++ [error_frame, {:close, 1008, "packet replay"}]}
            end

          {:error, :flood} ->
            Logger.warning("WS flood detected, disconnecting #{inspect(state.character_id)}")
            SessionLogic.cleanup(state)
            state = %{state | character_id: nil, map_id: nil}
            error_frame = {:binary, Encoder.encode({:error_msg, %{message: "Too many packets."}})}
            {state, frames ++ [error_frame, {:close, 1008, "flood"}]}
        end

      :incomplete ->
        {state, frames}

      {:error, reason} ->
        Logger.warning("WS packet decode error: #{inspect(reason)}")
        {state, frames}
    end
  end

  # ---- Command dispatch ----

  defp dispatch_command(state, {:login_existing_char, %{char_id: char_id, session_token: token}}) do
    Logger.info("WS Login: char_id=#{char_id}")
    {state, packets} = SessionLogic.login_existing(state, char_id, token)
    {state, bootstrap_frames(state) ++ encode_frames(packets) ++ session_token_frame(state)}
  end

  defp dispatch_command(state, {:login_new_char, params}) do
    Logger.info("WS new character: #{params.username}")
    {state, packets} = SessionLogic.login_new(state, params)
    {state, bootstrap_frames(state) ++ encode_frames(packets) ++ session_token_frame(state)}
  end

  defp dispatch_command(state, {:quit, _}) do
    # cleanup happens in terminate/3 after the close frame is sent
    {state, [{:close, 1000, "quit"}]}
  end

  defp dispatch_command(state, command) do
    {state, packets} = SessionLogic.handle_command(state, command)
    {state, encode_frames(packets)}
  end

  # ---- Frame helpers ----

  defp encode_frames(packets) do
    Enum.map(packets, fn cmd -> {:binary, Encoder.encode(cmd)} end)
  end

  defp bootstrap_frames(state) do
    world_pack_signature_frame(state)
  end

  # After successful login, send session credentials so the web client can reconnect.
  # Only sent over WebSocket — VB6 TCP clients never see this packet.
  defp session_token_frame(%{character_id: char_id}) when is_integer(char_id) do
    case GameBackend.Characters.get(char_id) do
      %{session_token: token} when is_binary(token) and byte_size(token) > 0 ->
        [{:binary, Encoder.encode({:session_token, %{char_id: char_id, token: token}})}]

      _ ->
        []
    end
  end

  defp session_token_frame(_state), do: []

  defp world_pack_signature_frame(%{character_id: char_id}) when is_integer(char_id) do
    manifest = Arena.ClientMapPack.manifest()

    [
      {:binary,
       Encoder.encode(
         {:world_pack_signature, %{version: manifest.version, hash: manifest.hash}}
       )}
    ]
  end

  defp world_pack_signature_frame(_state), do: []

  # Combine binary frames for efficiency, pass through control frames (close).
  defp reply(state, []), do: {:ok, state}

  defp reply(state, frames) do
    {binaries, others} = Enum.split_with(frames, &match?({:binary, _}, &1))

    combined =
      case binaries do
        [] ->
          others

        _ ->
          bin = Enum.reduce(binaries, <<>>, fn {:binary, b}, acc -> acc <> b end)
          [{:binary, bin} | others]
      end

    {:reply, combined, state}
  end
end
