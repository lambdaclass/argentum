defmodule AoTcpGateway.GmMessageTest do
  @moduledoc """
  Tests for the GM broadcast message (gm_message) packet handler.

  The gm_message handler should:
  - Only allow GM-privileged users to broadcast
  - Send a console_msg to ALL connected players via OnlineDirectory
  - Non-GM users should be silently ignored
  """
  use ExUnit.Case

  alias AoTcpGateway.SessionLogic
  alias Arena.Entity.PlayerEntity

  setup_all do
    unless Process.whereis(AoSession.OnlineDirectory) do
      {:ok, _} = AoSession.OnlineDirectory.start_link([])
    end

    :ok
  end

  defp base_entity(overrides \\ %{}) do
    Map.merge(
      %PlayerEntity{
        char_id: 60001,
        name: "GMBroadcaster",
        account_id: "acct_gm_broadcast",
        x: 50,
        y: 50,
        level: 45,
        gm: true
      },
      overrides
    )
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 60001,
        map_id: 1,
        account_id: "acct_gm_broadcast",
        entity: base_entity(),
        char_index: 1,
        target_x: nil,
        target_y: nil,
        is_gm: true
      },
      overrides
    )
  end

  describe "gm_message broadcast" do
    test "GM player broadcasts console_msg to all connected sessions" do
      test_pid = self()

      # Register a listener session in OnlineDirectory
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

      AoSession.OnlineDirectory.register(60010, "Listener", 1, listener_pid)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(60010)
        send(listener_pid, :stop)
      end)

      state = base_state()

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:gm_message, %{message: "Server maintenance in 5 minutes!"}})

      # No direct reply packets (broadcast is via OnlineDirectory)
      assert packets == []

      # Wait for message delivery
      Process.sleep(50)

      # Collect forwarded messages from listener
      listener_msgs = collect_tagged_messages(:listener_msg)

      send_raw_msgs =
        Enum.filter(listener_msgs, fn
          {:send_raw, _data} -> true
          _ -> false
        end)

      assert length(send_raw_msgs) >= 1,
        "Listener should receive broadcast console_msg, got: #{inspect(listener_msgs)}"

      # Verify the packet contains console_msg (packet ID 37) with "Servidor> " prefix and font_index 1
      [{:send_raw, raw_data}] = send_raw_msgs
      <<37::little-16, payload::binary>> = raw_data
      # Decode the string8 (length-prefixed) message from payload
      <<msg_len::little-16, msg_bytes::binary-size(msg_len), font_byte::8, _rest::binary>> = payload
      assert msg_bytes == "Servidor> Server maintenance in 5 minutes!"
      assert font_byte == 1
    end

    test "non-GM player cannot broadcast gm_message" do
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

      AoSession.OnlineDirectory.register(60011, "Listener2", 1, listener_pid)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(60011)
        send(listener_pid, :stop)
      end)

      non_gm_entity = base_entity(%{char_id: 60002, name: "NotAGM", gm: false})

      state =
        base_state(%{
          character_id: 60002,
          entity: non_gm_entity,
          is_gm: false
        })

      {_state, packets} =
        SessionLogic.handle_command(state, {:gm_message, %{message: "Hacked broadcast!"}})

      # Non-GM gets not-authorized message from catch-all
      assert packets == [{:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}]

      Process.sleep(50)

      listener_msgs = collect_tagged_messages(:listener_msg)
      assert listener_msgs == [], "Non-GM should not be able to broadcast, got: #{inspect(listener_msgs)}"
    end

    test "gm_message with is_gm false returns not-authorized message" do
      state = base_state(%{entity: nil, is_gm: false})

      {_state, packets} =
        SessionLogic.handle_command(state, {:gm_message, %{message: "Should not send"}})

      assert packets == [{:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}]
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
