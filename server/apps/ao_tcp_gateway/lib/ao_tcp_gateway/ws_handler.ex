defmodule AoTcpGateway.WsHandler do
  @moduledoc """
  Cowboy WebSocket handler that speaks AO20 binary protocol.

  Thin transport layer: decodes packets, delegates to SessionLogic,
  encodes and sends response packets over WebSocket frames.
  """

  require Logger

  alias AoProtocol.Server.Encoder
  alias AoProtocol.Client.Decoder
  alias AoTcpGateway.{FloodGuard, PacketCounter, SessionLogic}

  # Idle timeout: disconnect if no data (including pong) for 90s.
  # We send pings every 30s so a live client resets the timer.
  @ws_idle_timeout 90_000
  @ping_interval 30_000

  @backpressure_warn Application.compile_env(:ao_tcp_gateway, :backpressure_warn, 500)
  @backpressure_disconnect Application.compile_env(:ao_tcp_gateway, :backpressure_disconnect, 1000)

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
       packet_counters: PacketCounter.new()
     }}
  end

  def websocket_handle({:binary, data}, state) do
    buffer = state.buffer <> data
    {state, frames} = decode_loop(%{state | buffer: buffer}, [])
    reply(state, frames)
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  # Direct sends from MapServer
  def websocket_info({:send_packet, command}, state) do
    case check_backpressure(state) do
      :disconnect -> {:reply, {:close, 1008, "backpressure"}, state}
      :ok -> {:reply, {:binary, Encoder.encode(command)}, state}
    end
  end

  # Pre-encoded raw bytes from MapServer
  def websocket_info({:send_raw, binary}, state) do
    case check_backpressure(state) do
      :disconnect -> {:reply, {:close, 1008, "backpressure"}, state}
      :ok -> {:reply, {:binary, binary}, state}
    end
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

  def websocket_info(_info, state), do: {:ok, state}

  def terminate(_reason, _req, state) do
    Logger.info("WebSocket client disconnected")
    SessionLogic.cleanup(state)
    :ok
  end

  # ---- Backpressure ----

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
