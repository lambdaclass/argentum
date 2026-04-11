defmodule AoTcpGateway.RainToggleTest do
  @moduledoc """
  Tests for the rain_toggle GM command via SessionLogic.

  The rain_toggle handler should:
  - Only allow GM-privileged users to toggle rain
  - Use WorldWeather for global rain state (not per-map)
  - Broadcast rain_toggle packets to all connected sessions
  - Non-GM users receive not-authorized message
  """
  use ExUnit.Case

  alias AoTcpGateway.SessionLogic
  alias Arena.Entity.PlayerEntity

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
    # Reset rain to off
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

  describe "rain_toggle via SessionLogic" do
    test "GM player toggles global rain and listeners receive rain_toggle packet" do
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

      AoSession.OnlineDirectory.register(80010, "RainListener", 1, listener_pid)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(80010)
        send(listener_pid, :stop)
      end)

      state = base_state()

      {_state, packets} = SessionLogic.handle_command(state, {:rain_toggle, %{}})

      # No direct reply packets
      assert packets == []

      # WorldWeather state should be toggled
      assert Arena.WorldWeather.raining?() == true

      Process.sleep(50)

      msgs = collect_tagged_messages(:listener_msg)

      rain_msgs =
        Enum.filter(msgs, fn
          {:send_raw, <<59::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      assert length(rain_msgs) >= 1,
        "Listener should receive rain_toggle packet, got: #{inspect(msgs)}"
    end

    test "non-GM player cannot toggle rain" do
      state = base_state(%{is_gm: false, character_id: 80002})

      {_state, packets} = SessionLogic.handle_command(state, {:rain_toggle, %{}})

      assert packets == [{:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}]
      assert Arena.WorldWeather.raining?() == false
    end

    test "double toggle returns rain to off" do
      state = base_state()

      SessionLogic.handle_command(state, {:rain_toggle, %{}})
      assert Arena.WorldWeather.raining?() == true

      SessionLogic.handle_command(state, {:rain_toggle, %{}})
      assert Arena.WorldWeather.raining?() == false
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
