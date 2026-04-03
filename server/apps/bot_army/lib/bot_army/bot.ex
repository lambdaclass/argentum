defmodule BotArmy.Bot do
  @moduledoc """
  GenServer managing a single bot's WebSocket connection and AI behavior.

  Connects to the game server, sends a login packet, then periodically
  performs random actions (walk, talk, attack, idle).
  """
  use GenServer, restart: :temporary

  require Logger

  @default_min_action_interval 500
  @default_max_action_interval 2_000
  @reconnect_delay 5_000

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Check if a bot process is currently connected."
  def connected?(pid) do
    GenServer.call(pid, :connected?, 1_000)
  catch
    :exit, _ -> false
  end

  @doc "Get benchmark metrics from a bot process."
  def metrics(pid) do
    GenServer.call(pid, :metrics, 1_000)
  catch
    :exit, _ -> %{packets_in: 0, bytes_in: 0, rtt_samples: []}
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    char_id = Keyword.fetch!(opts, :char_id)
    # :walk_only — only walks (no chat/attack). :walk_chat — walks + chat. :default — original mix.
    profile = Keyword.get(opts, :profile, :default)
    min_interval = Keyword.get(opts, :min_action_interval, @default_min_action_interval)
    max_interval = Keyword.get(opts, :max_action_interval, @default_max_action_interval)

    state = %{
      char_id: char_id,
      socket: nil,
      connected: false,
      position: {0, 0},
      map_id: nil,
      buffer: <<>>,
      action_timer: nil,
      profile: profile,
      min_action_interval: min_interval,
      max_action_interval: max_interval,
      # Benchmark metrics
      packets_in: 0,
      bytes_in: 0,
      walk_sent_at: nil,
      rtt_samples: []
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  @impl true
  def handle_call(:metrics, _from, state) do
    metrics = %{
      packets_in: state.packets_in,
      bytes_in: state.bytes_in,
      rtt_samples: Enum.take(state.rtt_samples, 100)
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_cast(:reset_metrics, state) do
    {:noreply, %{state | packets_in: 0, bytes_in: 0, rtt_samples: [], walk_sent_at: nil}}
  end

  @impl true
  def handle_info(:connect, state) do
    state = cancel_timer(state)

    case BotArmy.WsClient.connect() do
      {:ok, socket} ->
        Logger.debug("Bot #{state.char_id} connected")
        send(self(), :login)
        {:noreply, %{state | socket: socket, connected: true, buffer: <<>>}}

      {:error, reason} ->
        Logger.warning("Bot #{state.char_id} connect failed: #{inspect(reason)}")
        Process.send_after(self(), :connect, @reconnect_delay)
        {:noreply, %{state | connected: false, socket: nil}}
    end
  end

  @impl true
  def handle_info(:login, %{socket: socket, char_id: char_id} = state) when socket != nil do
    packet = build_login(char_id)

    case BotArmy.WsClient.send_binary(socket, packet) do
      :ok ->
        state = schedule_action(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Bot #{char_id} login send failed: #{inspect(reason)}")
        handle_disconnect(state)
    end
  end

  @impl true
  def handle_info(:login, state), do: {:noreply, state}

  @impl true
  def handle_info(:perform_action, %{connected: false} = state), do: {:noreply, state}

  @impl true
  def handle_info(:perform_action, state) do
    {packet, action_type} = random_action(state)

    new_state =
      if packet do
        case BotArmy.WsClient.send_binary(state.socket, packet) do
          :ok ->
            if action_type == :walk do
              %{state | walk_sent_at: System.monotonic_time(:microsecond)}
            else
              state
            end

          {:error, reason} ->
            Logger.warning("Bot #{state.char_id} send failed: #{inspect(reason)}")
            elem(handle_disconnect(state), 1)
        end
      else
        state
      end

    new_state = schedule_action(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    buffer = state.buffer <> data
    {frames, rest} = BotArmy.WsClient.decode_frames(buffer)

    state = %{state |
      buffer: rest,
      bytes_in: state.bytes_in + byte_size(data),
      packets_in: state.packets_in + length(frames)
    }

    state =
      Enum.reduce(frames, state, fn frame, acc ->
        handle_server_packet(frame, acc)
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.debug("Bot #{state.char_id} TCP closed")
    handle_disconnect(state)
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("Bot #{state.char_id} TCP error: #{inspect(reason)}")
    handle_disconnect(state)
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Server packet handling ---

  # We only parse packets we care about; ignore the rest.
  defp handle_server_packet(<<31::little-16, x::unsigned-8, y::unsigned-8, _rest::binary>>, state) do
    # pos_update — measure RTT if we have a pending walk timestamp
    state =
      case state.walk_sent_at do
        nil -> state
        sent_at ->
          rtt = System.monotonic_time(:microsecond) - sent_at
          %{state | rtt_samples: [rtt | state.rtt_samples], walk_sent_at: nil}
      end

    %{state | position: {x, y}}
  end

  defp handle_server_packet(<<30::little-16, map_id::little-signed-16, _rest::binary>>, state) do
    # change_map
    %{state | map_id: map_id}
  end

  defp handle_server_packet(<<73::little-16, _rest::binary>>, state) do
    # error_msg from server - log it
    Logger.debug("Bot #{state.char_id} received error_msg from server")
    state
  end

  defp handle_server_packet(_frame, state), do: state

  # --- Packet builders ---

  # Login new char (ID 74): packet_id(Int16) + password(String8) + name(String8) + version(3xInt8) + md5(String8)
  #   + race(Int8) + gender(Int8) + class(Int8) + head(Int16) + home_city(Int8)
  defp build_login(char_id) do
    name = "Bot_#{char_id}"
    password = "bot_pass_#{char_id}"
    md5 = "botmd5"

    <<74::little-signed-16>> <>
      write_string8(password) <>
      write_string8(name) <>
      <<1::unsigned-8, 0::unsigned-8, 0::unsigned-8>> <>
      write_string8(md5) <>
      <<1::unsigned-8>> <>
      <<1::unsigned-8>> <>
      <<6::unsigned-8>> <>
      <<1::little-signed-16>> <>
      <<1::unsigned-8>>
  end

  # Walk (ID 78): packet_id(Int16) + heading(Int8) + packet_count(Int32)
  defp build_walk(direction) do
    heading =
      case direction do
        :north -> 1
        :east -> 2
        :south -> 3
        :west -> 4
      end

    <<78::little-signed-16, heading::unsigned-8, 1::little-signed-32>>
  end

  # Talk (ID 75): packet_id(Int16) + message(String8) + packet_count(Int32)
  defp build_talk(message) do
    <<75::little-signed-16>> <> write_string8(message) <> <<1::little-signed-32>>
  end

  # Attack (ID 80): packet_id(Int16) + packet_count(Int32)
  defp build_attack do
    <<80::little-signed-16, 1::little-signed-32>>
  end

  defp write_string8(str) do
    len = byte_size(str)
    <<len::little-signed-16, str::binary>>
  end

  # --- Action selection ---

  defp random_action(state) do
    case state.profile do
      :walk_only ->
        {build_walk(Enum.random([:north, :south, :east, :west])), :walk}

      :walk_chat ->
        if :rand.uniform(100) <= 80 do
          {build_walk(Enum.random([:north, :south, :east, :west])), :walk}
        else
          {build_talk("Bot #{state.char_id} says hello!"), :chat}
        end

      :idle ->
        {nil, :idle}

      _default ->
        roll = :rand.uniform(100)
        cond do
          roll <= 50 -> {build_walk(Enum.random([:north, :south, :east, :west])), :walk}
          roll <= 70 -> {build_talk("Bot #{state.char_id} says hello!"), :chat}
          roll <= 90 -> {build_attack(), :attack}
          true -> {nil, :idle}
        end
    end
  end

  # --- Helpers ---

  defp schedule_action(state) do
    range = max(1, state.max_action_interval - state.min_action_interval)
    interval = state.min_action_interval + :rand.uniform(range)
    timer = Process.send_after(self(), :perform_action, interval)
    %{state | action_timer: timer}
  end

  defp cancel_timer(%{action_timer: nil} = state), do: state

  defp cancel_timer(%{action_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | action_timer: nil}
  end

  defp handle_disconnect(state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    state = cancel_timer(state)
    Process.send_after(self(), :connect, @reconnect_delay)
    {:noreply, %{state | socket: nil, connected: false, buffer: <<>>}}
  end
end
