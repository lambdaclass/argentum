defmodule AoTcpGateway.GmMessageTest do
  @moduledoc """
  Tests for the GM broadcast message (gm_message) packet handler.

  VB6 semantics (Protocol_GmCommands.bas HandleGMMessage):
  - Only GMs (EsGM) can send
  - Broadcast to GMs only (SendTarget.ToAdmins)
  - Format: "name > message" with FONTTYPE_GMMSG (index 16)
  - Empty messages are silently ignored
  - Logged via LogGM for audit
  """
  use ExUnit.Case

  alias AoTcpGateway.SessionLogic
  alias Arena.Entity.PlayerEntity

  # FONTTYPE_GMMSG = 16 in the VB6 e_FontTypeNames enum (0-based)
  @fonttype_gmmsg 16

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

  describe "gm_message broadcast (VB6 parity)" do
    test "GM message is sent only to GM sessions, not to regular players" do
      test_pid = self()

      gm_listener_pid = spawn_listener(test_pid, :gm_listener_msg)
      regular_listener_pid = spawn_listener(test_pid, :regular_listener_msg)

      # Register a GM listener (is_gm: true)
      AoSession.OnlineDirectory.register(60010, "GMListener", 1, gm_listener_pid, is_gm: true)
      # Register a regular player listener (is_gm: false, the default)
      AoSession.OnlineDirectory.register(60011, "RegularPlayer", 1, regular_listener_pid)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(60010)
        AoSession.OnlineDirectory.unregister(60011)
        send(gm_listener_pid, :stop)
        send(regular_listener_pid, :stop)
      end)

      state = base_state()

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:gm_message, %{message: "Maintenance in 5 min!"}})

      # No direct reply packets (broadcast is via OnlineDirectory)
      assert packets == []

      Process.sleep(50)

      # GM listener should receive the message
      gm_msgs = collect_tagged_messages(:gm_listener_msg)

      send_raw_msgs =
        Enum.filter(gm_msgs, fn
          {:send_raw, _data} -> true
          _ -> false
        end)

      assert length(send_raw_msgs) == 1,
        "GM listener should receive broadcast, got: #{inspect(gm_msgs)}"

      # Regular player should NOT receive any message
      regular_msgs = collect_tagged_messages(:regular_listener_msg)
      assert regular_msgs == [],
        "Regular player should NOT receive GM message, got: #{inspect(regular_msgs)}"
    end

    test "message format is 'name > message' with FONTTYPE_GMMSG (16)" do
      test_pid = self()
      gm_listener_pid = spawn_listener(test_pid, :fmt_listener_msg)

      AoSession.OnlineDirectory.register(60020, "FmtGMListener", 1, gm_listener_pid, is_gm: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(60020)
        send(gm_listener_pid, :stop)
      end)

      state = base_state()

      {_state, _packets} =
        SessionLogic.handle_command(state, {:gm_message, %{message: "Hello GMs"}})

      Process.sleep(50)

      msgs = collect_tagged_messages(:fmt_listener_msg)
      [{:send_raw, raw_data}] = Enum.filter(msgs, &match?({:send_raw, _}, &1))

      # Decode: packet ID 37 (console_msg), then string8 message, then font byte
      <<37::little-16, payload::binary>> = raw_data
      <<msg_len::little-16, msg_bytes::binary-size(msg_len), font_byte::8, _rest::binary>> = payload

      assert msg_bytes == "GMBroadcaster > Hello GMs"
      assert font_byte == @fonttype_gmmsg
    end

    test "empty message is silently ignored (no broadcast)" do
      test_pid = self()
      gm_listener_pid = spawn_listener(test_pid, :empty_listener_msg)

      AoSession.OnlineDirectory.register(60030, "EmptyGMListener", 1, gm_listener_pid, is_gm: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(60030)
        send(gm_listener_pid, :stop)
      end)

      state = base_state()

      {_state, packets} =
        SessionLogic.handle_command(state, {:gm_message, %{message: ""}})

      assert packets == []

      Process.sleep(50)

      msgs = collect_tagged_messages(:empty_listener_msg)
      assert msgs == [], "Empty message should not trigger broadcast, got: #{inspect(msgs)}"
    end

    test "non-GM player cannot send gm_message" do
      test_pid = self()

      listener_pid = spawn_listener(test_pid, :nongm_listener_msg)
      AoSession.OnlineDirectory.register(60040, "NGMListener", 1, listener_pid, is_gm: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(60040)
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

      listener_msgs = collect_tagged_messages(:nongm_listener_msg)
      assert listener_msgs == [], "Non-GM should not be able to broadcast, got: #{inspect(listener_msgs)}"
    end

    test "gm_message with is_gm false returns not-authorized message" do
      state = base_state(%{entity: nil, is_gm: false})

      {_state, packets} =
        SessionLogic.handle_command(state, {:gm_message, %{message: "Should not send"}})

      assert packets == [{:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}]
    end
  end

  # ---- Helpers ----

  defp spawn_listener(test_pid, tag) do
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
