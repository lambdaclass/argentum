defmodule Arena.WorldWeatherTest do
  @moduledoc """
  Tests for Arena.WorldWeather — global rain toggle.

  The rain_toggle GM command should:
  - Toggle rain state globally (not per-map)
  - Broadcast rain_toggle packets to ALL connected sessions via OnlineDirectory
  - Query current rain state via raining?/0
  """
  use ExUnit.Case

  setup_all do
    unless Process.whereis(AoSession.OnlineDirectory) do
      {:ok, _} = AoSession.OnlineDirectory.start_link([])
    end

    :ok
  end

  setup do
    # Ensure WorldWeather is running; reset to known state (rain off)
    case Process.whereis(Arena.WorldWeather) do
      nil ->
        {:ok, _} = Arena.WorldWeather.start_link([])

      _pid ->
        # Reset: if rain is on, toggle it off
        if Arena.WorldWeather.raining?(), do: Arena.WorldWeather.toggle_rain()
    end

    :ok
  end

  describe "toggle_rain/0" do
    test "toggles rain from off to on" do
      assert Arena.WorldWeather.raining?() == false
      result = Arena.WorldWeather.toggle_rain()
      assert result == {true, true}
      assert Arena.WorldWeather.raining?() == true
    end

    test "toggles rain from on to off" do
      Arena.WorldWeather.toggle_rain()
      assert Arena.WorldWeather.raining?() == true

      result = Arena.WorldWeather.toggle_rain()
      assert result == {false, false}
      assert Arena.WorldWeather.raining?() == false
    end

    test "broadcasts rain_toggle packet to all connected sessions" do
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

      AoSession.OnlineDirectory.register(70001, "WeatherListener", 1, listener_pid)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(70001)
        send(listener_pid, :stop)
      end)

      Arena.WorldWeather.toggle_rain()

      Process.sleep(50)

      msgs = collect_tagged_messages(:listener_msg)

      rain_msgs =
        Enum.filter(msgs, fn
          {:send_raw, <<59::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      assert length(rain_msgs) >= 1,
        "Listener should receive rain_toggle packet, got: #{inspect(msgs)}"

      # Verify the rain_toggle packet has raining=true (1)
      [{:send_raw, <<59::little-16, rain_byte::8, _::binary>>}] = rain_msgs
      assert rain_byte == 1
    end

    test "second toggle broadcasts raining=false" do
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

      AoSession.OnlineDirectory.register(70002, "WeatherListener2", 1, listener_pid)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(70002)
        send(listener_pid, :stop)
      end)

      # First toggle: rain on
      Arena.WorldWeather.toggle_rain()
      Process.sleep(50)
      # Drain first batch
      _msgs = collect_tagged_messages(:listener_msg)

      # Second toggle: rain off
      Arena.WorldWeather.toggle_rain()
      Process.sleep(50)

      msgs = collect_tagged_messages(:listener_msg)

      rain_msgs =
        Enum.filter(msgs, fn
          {:send_raw, <<59::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      assert length(rain_msgs) >= 1

      [{:send_raw, <<59::little-16, rain_byte::8, _::binary>>}] = rain_msgs
      assert rain_byte == 0
    end

    test "multiple listeners all receive rain_toggle" do
      test_pid = self()

      make_listener = fn id, name, tag ->
        pid =
          spawn(fn ->
            forward_loop = fn forward_loop ->
              receive do
                :stop -> :ok
                msg ->
                  send(test_pid, {tag, msg})
                  forward_loop.(forward_loop)
              end
            end

            forward_loop.(forward_loop)
          end)

        AoSession.OnlineDirectory.register(id, name, 1, pid)
        pid
      end

      pid1 = make_listener.(70010, "L1", :l1_msg)
      pid2 = make_listener.(70011, "L2", :l2_msg)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(70010)
        AoSession.OnlineDirectory.unregister(70011)
        send(pid1, :stop)
        send(pid2, :stop)
      end)

      Arena.WorldWeather.toggle_rain()
      Process.sleep(50)

      l1_msgs = collect_tagged_messages(:l1_msg)
      l2_msgs = collect_tagged_messages(:l2_msg)

      l1_rain = Enum.filter(l1_msgs, &match?({:send_raw, <<59::little-16, _::binary>>}, &1))
      l2_rain = Enum.filter(l2_msgs, &match?({:send_raw, <<59::little-16, _::binary>>}, &1))

      assert length(l1_rain) >= 1, "Listener 1 should receive rain_toggle"
      assert length(l2_rain) >= 1, "Listener 2 should receive rain_toggle"
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
