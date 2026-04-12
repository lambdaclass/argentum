defmodule AoTcpGateway.RainToggleTest do
  @moduledoc """
  Tests for the rain_toggle GM command via SessionLogic.

  VB6 HandleRainToggle toggles both Lloviendo (rain) AND Nebando (snow)
  globally, broadcasts rain_toggle + snow_toggle packets to all connected
  sessions. When rain starts, it also sends thunder sound (wave 404) and
  lightning flash screen (color 0xF5D3F3, duration 250).
  """
  use ExUnit.Case

  alias AoTcpGateway.SessionLogic
  alias Arena.Entity.PlayerEntity

  # VB6 constants
  @thunder_wave_id 404
  @flash_color 0xF5D3F3
  @flash_duration 250

  # Packet IDs
  @rain_toggle_id 59
  @snow_toggle_id 76
  @play_wave_id 55
  @flash_screen_id 129

  setup_all do
    unless Process.whereis(AoSession.OnlineDirectory) do
      {:ok, _} = AoSession.OnlineDirectory.start_link([])
    end

    unless Process.whereis(Arena.WorldWeather) do
      {:ok, _} = Arena.WorldWeather.start_link([])
    end

    :ok
  end

  setup do
    # Reset weather to off
    if Arena.WorldWeather.raining?(), do: Arena.WorldWeather.toggle_rain()
    :ok
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 80001,
        map_id: 1,
        account_id: "acct_rain_gm",
        entity: %PlayerEntity{
          char_id: 80001,
          name: "RainGM",
          account_id: "acct_rain_gm",
          x: 50,
          y: 50,
          level: 45,
          gm: true
        },
        char_index: 1,
        target_x: nil,
        target_y: nil,
        is_gm: true
      },
      overrides
    )
  end

  defp register_listener(char_id, name) do
    test_pid = self()

    listener_pid =
      spawn(fn ->
        forward_loop = fn forward_loop ->
          receive do
            :stop -> :ok
            msg ->
              send(test_pid, {:listener_msg, msg})
              forward_loop.(forward_loop)
          end
        end

        forward_loop.(forward_loop)
      end)

    AoSession.OnlineDirectory.register(char_id, name, 1, listener_pid)
    listener_pid
  end

  describe "rain_toggle via SessionLogic" do
    test "GM toggle broadcasts rain_toggle AND snow_toggle packets to all" do
      listener_pid = register_listener(80010, "WeatherListener")

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(80010)
        send(listener_pid, :stop)
      end)

      state = base_state()
      {_state, packets} = SessionLogic.handle_command(state, {:rain_toggle, %{}})

      # No direct reply packets — broadcasts happen inside WorldWeather
      assert packets == []

      Process.sleep(50)
      msgs = collect_tagged_messages(:listener_msg)

      rain_msgs =
        Enum.filter(msgs, fn
          {:send_raw, <<@rain_toggle_id::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      snow_msgs =
        Enum.filter(msgs, fn
          {:send_raw, <<@snow_toggle_id::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      assert length(rain_msgs) >= 1,
        "Should receive rain_toggle packet, got: #{inspect(msgs)}"

      assert length(snow_msgs) >= 1,
        "Should receive snow_toggle packet, got: #{inspect(msgs)}"
    end

    test "rain toggle also toggles global snow state" do
      state = base_state()

      assert Arena.WorldWeather.raining?() == false
      assert Arena.WorldWeather.snowing?() == false

      SessionLogic.handle_command(state, {:rain_toggle, %{}})

      assert Arena.WorldWeather.raining?() == true
      assert Arena.WorldWeather.snowing?() == true
    end

    test "when rain starts, thunder sound (wave 404) and flash screen are broadcast" do
      listener_pid = register_listener(80020, "ThunderListener")

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(80020)
        send(listener_pid, :stop)
      end)

      state = base_state()

      # First toggle: rain starts -> should get thunder + flash
      SessionLogic.handle_command(state, {:rain_toggle, %{}})
      assert Arena.WorldWeather.raining?() == true

      Process.sleep(50)
      msgs = collect_tagged_messages(:listener_msg)

      wave_msgs =
        Enum.filter(msgs, fn
          {:send_raw, <<@play_wave_id::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      flash_msgs =
        Enum.filter(msgs, fn
          {:send_raw, <<@flash_screen_id::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      assert length(wave_msgs) >= 1,
        "Should receive play_wave (thunder) packet when rain starts, got: #{inspect(msgs)}"

      assert length(flash_msgs) >= 1,
        "Should receive flash_screen (lightning) packet when rain starts, got: #{inspect(msgs)}"

      # Verify thunder wave ID is 404
      [{:send_raw, <<@play_wave_id::little-16, wave_id::little-signed-16, _::binary>>} | _] =
        wave_msgs

      assert wave_id == @thunder_wave_id

      # Verify flash screen color and duration
      [{:send_raw,
        <<@flash_screen_id::little-16, color::little-signed-32,
          duration::little-signed-32, _ignore::8>>} | _] = flash_msgs

      assert color == @flash_color
      assert duration == @flash_duration
    end

    test "when rain stops, no thunder or flash is broadcast" do
      state = base_state()

      # Turn rain on first
      SessionLogic.handle_command(state, {:rain_toggle, %{}})
      assert Arena.WorldWeather.raining?() == true

      # Register listener AFTER first toggle, so we only see the second toggle
      listener_pid = register_listener(80030, "NoThunderListener")

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(80030)
        send(listener_pid, :stop)
      end)

      # Drain any messages from registration
      Process.sleep(50)
      _drain = collect_tagged_messages(:listener_msg)

      # Second toggle: rain stops -> no thunder/flash
      SessionLogic.handle_command(state, {:rain_toggle, %{}})
      assert Arena.WorldWeather.raining?() == false

      Process.sleep(50)
      msgs = collect_tagged_messages(:listener_msg)

      wave_msgs =
        Enum.filter(msgs, fn
          {:send_raw, <<@play_wave_id::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      flash_msgs =
        Enum.filter(msgs, fn
          {:send_raw, <<@flash_screen_id::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      assert wave_msgs == [],
        "Should NOT receive thunder when rain stops, got: #{inspect(wave_msgs)}"

      assert flash_msgs == [],
        "Should NOT receive flash when rain stops, got: #{inspect(flash_msgs)}"
    end

    test "non-GM player cannot toggle rain" do
      state = base_state(%{is_gm: false, character_id: 80002})

      {_state, packets} = SessionLogic.handle_command(state, {:rain_toggle, %{}})

      assert packets == [{:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}]
      assert Arena.WorldWeather.raining?() == false
      assert Arena.WorldWeather.snowing?() == false
    end

    test "double toggle returns both rain and snow to off" do
      state = base_state()

      SessionLogic.handle_command(state, {:rain_toggle, %{}})
      assert Arena.WorldWeather.raining?() == true
      assert Arena.WorldWeather.snowing?() == true

      SessionLogic.handle_command(state, {:rain_toggle, %{}})
      assert Arena.WorldWeather.raining?() == false
      assert Arena.WorldWeather.snowing?() == false
    end
  end

  defp collect_tagged_messages(tag) do
    collect_tagged_messages(tag, [])
  end

  defp collect_tagged_messages(tag, acc) do
    receive do
      {^tag, msg} -> collect_tagged_messages(tag, [msg | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
