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
  @default_slow_client_recv_delay_ms 1_000

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
    # Profiles:
    #   :walk_only    — only walks (no chat/attack)
    #   :walk_chat    — walks + chat
    #   :slow_client  — walks + chat, but throttles socket reads via active: :once
    #                   gated by recv_delay_ms, to saturate the server send buffer
    #                   and exercise the backpressure path
    #   :default      — original mix
    profile = Keyword.get(opts, :profile, :default)
    min_interval = Keyword.get(opts, :min_action_interval, @default_min_action_interval)
    max_interval = Keyword.get(opts, :max_action_interval, @default_max_action_interval)

    recv_delay_ms =
      Keyword.get(opts, :recv_delay_ms, @default_slow_client_recv_delay_ms)

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
      recv_delay_ms: recv_delay_ms,
      # Per-command packet counters (anti-cheat requires strictly increasing)
      packet_counters: %{walk: 0, talk: 0, attack: 0},
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
        # For slow_client, flip from the WsClient default (active: true) to
        # active: :once so we can gate reads behind a delay and saturate the
        # server send buffer.
        if state.profile == :slow_client do
          :inet.setopts(socket, active: :once)
        end

        send(self(), :login)
        {:noreply, %{state | socket: socket, connected: true, buffer: <<>>, packet_counters: %{walk: 0, talk: 0, attack: 0}}}

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
    {packet, action_type, state} = random_action(state)

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

    state = maybe_schedule_rearm(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:rearm_recv, %{socket: nil} = state), do: {:noreply, state}

  @impl true
  def handle_info(:rearm_recv, %{socket: socket} = state) do
    :inet.setopts(socket, active: :once)
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

  defp handle_server_packet(<<73::little-16, rest::binary>>, state) do
    # error_msg from server - parse and log the message
    msg =
      case rest do
        <<len::little-signed-16, text::binary-size(len), _::binary>> -> text
        _ -> "(unparseable)"
      end

    Logger.warning("Bot #{state.char_id} received error_msg: #{msg}")
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
  defp build_walk(direction, count) do
    heading =
      case direction do
        :north -> 1
        :east -> 2
        :south -> 3
        :west -> 4
      end

    <<78::little-signed-16, heading::unsigned-8, count::little-signed-32>>
  end

  # Talk (ID 75): packet_id(Int16) + message(String8) + packet_count(Int32)
  defp build_talk(message, count) do
    <<75::little-signed-16>> <> write_string8(message) <> <<count::little-signed-32>>
  end

  # Attack (ID 80): packet_id(Int16) + packet_count(Int32)
  defp build_attack(count) do
    <<80::little-signed-16, count::little-signed-32>>
  end

  defp write_string8(str) do
    len = byte_size(str)
    <<len::little-signed-16, str::binary>>
  end

  # --- Action selection ---

  defp random_action(state) do
    case state.profile do
      :walk_only ->
        next_action(state, :walk)

      :walk_chat ->
        if :rand.uniform(100) <= 80 do
          next_action(state, :walk)
        else
          next_action(state, :chat)
        end

      :idle ->
        {nil, :idle, state}

      _default ->
        roll = :rand.uniform(100)
        cond do
          roll <= 50 -> next_action(state, :walk)
          roll <= 70 -> next_action(state, :chat)
          roll <= 90 -> next_action(state, :attack)
          true -> {nil, :idle, state}
        end
    end
  end

  defp next_action(state, :walk) do
    counters = state.packet_counters
    count = counters.walk + 1
    packet = build_walk(Enum.random([:north, :south, :east, :west]), count)
    {packet, :walk, %{state | packet_counters: %{counters | walk: count}}}
  end

  defp next_action(state, :chat) do
    counters = state.packet_counters
    count = counters.talk + 1
    packet = build_talk("Bot #{state.char_id} says hello!", count)
    {packet, :chat, %{state | packet_counters: %{counters | talk: count}}}
  end

  defp next_action(state, :attack) do
    counters = state.packet_counters
    count = counters.attack + 1
    packet = build_attack(count)
    {packet, :attack, %{state | packet_counters: %{counters | attack: count}}}
  end

  # --- Helpers ---

  defp maybe_schedule_rearm(%{profile: :slow_client, recv_delay_ms: delay} = state)
       when is_integer(delay) and delay > 0 do
    Process.send_after(self(), :rearm_recv, delay)
    state
  end

  defp maybe_schedule_rearm(%{profile: :slow_client, socket: socket} = state)
       when not is_nil(socket) do
    :inet.setopts(socket, active: :once)
    state
  end

  defp maybe_schedule_rearm(state), do: state

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
