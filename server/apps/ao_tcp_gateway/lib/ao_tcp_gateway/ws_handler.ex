defmodule AoTcpGateway.WsHandler do
  @moduledoc """
  Cowboy WebSocket handler that speaks AO20 binary protocol.

  Thin transport layer: decodes packets, delegates to SessionLogic,
  encodes and sends response packets over WebSocket frames.
  """

  require Logger

  alias AoProtocol.Server.Encoder
  alias AoProtocol.Client.Decoder
  alias AoTcpGateway.{FloodGuard, SessionLogic}

  # Idle timeout: disconnect if no data (including pong) for 90s.
  # We send pings every 30s so a live client resets the timer.
  @ws_idle_timeout 90_000
  @ping_interval 30_000

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
       flood_guard: FloodGuard.new()
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
    {:reply, {:binary, Encoder.encode(command)}, state}
  end

  # Pre-encoded raw bytes from MapServer
  def websocket_info({:send_raw, binary}, state) do
    {:reply, {:binary, binary}, state}
  end

  # Map transfer request from MapServer
  def websocket_info({:transfer, dest_map, dest_x, dest_y, entity}, state) do
    {state, packets} = SessionLogic.transfer(state, dest_map, dest_x, dest_y, entity)
    reply(state, encode_frames(packets))
  end

  # Autosave from MapServer
  def websocket_info({:autosave, entity}, state) do
    SessionLogic.autosave(entity)
    {:ok, state}
  end

  def websocket_info(:ws_ping, state) do
    Process.send_after(self(), :ws_ping, @ping_interval)
    {:reply, :ping, state}
  end

  def websocket_info(_info, state), do: {:ok, state}

  def terminate(_reason, _req, state) do
    Logger.info("WebSocket client disconnected")
    SessionLogic.cleanup(state)
    :ok
  end

  # ---- Decode loop ----

  defp decode_loop(state, frames) do
    case Decoder.decode(state.buffer) do
      {:ok, command, rest} ->
        case FloodGuard.check(state.flood_guard) do
          {:ok, guard} ->
            state = %{state | flood_guard: guard, buffer: rest}
            {state, new_frames} = dispatch_command(state, command)
            decode_loop(state, frames ++ new_frames)

          {:error, :flood} ->
            Logger.warning("WS flood detected, disconnecting #{inspect(state.character_id)}")
            SessionLogic.cleanup(state)
            # Nil out character_id so terminate/3's cleanup is a no-op
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
    {state, encode_frames(packets)}
  end

  defp dispatch_command(state, {:login_new_char, params}) do
    Logger.info("WS new character: #{params.username}")
    {state, packets} = SessionLogic.login_new(state, params)
    {state, encode_frames(packets)}
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
