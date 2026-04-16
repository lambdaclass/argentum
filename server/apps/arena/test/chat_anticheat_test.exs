defmodule Arena.ChatAnticheatTest do
  @moduledoc "Adversarial tests for chat/yell moderation, filtering, and recipient scoping."
  use ExUnit.Case, async: false

  import Arena.Test.MapStateFactory

  alias Arena.Entity.PlayerEntity
  alias Arena.Map.Chat

  setup do
    case Arena.Settings.start_link() do
      {:ok, pid} ->
        on_exit(fn -> GenServer.stop(pid) end)

      {:error, {:already_started, _pid}} ->
        :ok
    end

    Arena.Settings.reset_all()
    on_exit(fn -> Arena.Settings.reset_all() end)
    :ok
  end

  defp make_entity(overrides \\ %{}) do
    defaults = %{
      char_id: :player,
      name: "Tester",
      account_id: "acc_test",
      x: 50,
      y: 50,
      char_index: 1,
      map_id: 1
    }

    struct!(PlayerEntity, Map.merge(defaults, overrides))
  end

  defp make_state(players, opts) do
    map_state(
      players: players,
      sessions: Keyword.get(opts, :sessions, %{}),
      visibility_mode: Keyword.get(opts, :visibility_mode, :aoi_scan),
      grid: Keyword.get(opts, :grid),
      meta: %{rain: false, snow: false, sin_invi_ocul: false}
    )
  end

  defp start_session(label) do
    parent = self()

    spawn_link(fn ->
      session_loop(parent, label)
    end)
  end

  defp session_loop(parent, label) do
    receive do
      msg ->
        send(parent, {:session, label, msg})
        session_loop(parent, label)
    end
  end

  defp collect_session_messages(timeout, acc \\ []) do
    receive do
      {:session, _label, _msg} = entry ->
        collect_session_messages(timeout, [entry | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp decode_console_msg(
         <<37::little-signed-integer-16, len::little-signed-integer-16, message::binary-size(len),
           font_index::unsigned-integer-8>>
       ) do
    %{message: message, font_index: font_index}
  end

  defp decode_chat_over_head(
         <<35::little-signed-integer-16, len::little-signed-integer-16, message::binary-size(len),
           char_index::little-signed-integer-16, color::little-signed-integer-32, es_spell::unsigned-integer-8,
           x::unsigned-integer-8, y::unsigned-integer-8, min_time::little-signed-integer-16,
           max_time::little-signed-integer-16>>
       ) do
    %{
      message: message,
      char_index: char_index,
      color: color,
      es_spell: es_spell,
      x: x,
      y: y,
      min_time: min_time,
      max_time: max_time
    }
  end

  describe "mute and dead-state guards" do
    test "muted player receives a mute console message and does not broadcast chat" do
      sender_pid = start_session(:sender)
      near_pid = start_session(:near)

      muted_until = System.system_time(:millisecond) + 60_000
      sender = make_entity(%{muted_until: muted_until})
      near = make_entity(%{char_id: :near, name: "Nearby", x: 51, y: 50, char_index: 2})

      state =
        make_state(
          %{sender.char_id => sender, near.char_id => near},
          sessions: %{sender.char_id => sender_pid, near.char_id => near_pid}
        )

      {:noreply, new_state} = Chat.handle_chat(state, sender.char_id, "Hello!")

      assert new_state == state

      assert_receive {:session, :sender, {:send_raw, raw}}
      assert decode_console_msg(raw).message == "Estás silenciado."
      refute_receive {:session, :near, _}, 50
    end

    test "dead player receives a death console message and does not broadcast yell" do
      sender_pid = start_session(:sender)
      near_pid = start_session(:near)

      sender = make_entity(%{dead: true})
      near = make_entity(%{char_id: :near, name: "Nearby", x: 51, y: 50, char_index: 2})

      state =
        make_state(
          %{sender.char_id => sender, near.char_id => near},
          sessions: %{sender.char_id => sender_pid, near.char_id => near_pid}
        )

      {:noreply, new_state} = Chat.handle_yell(state, sender.char_id, "Help!")

      assert new_state == state

      assert_receive {:session, :sender, {:send_raw, raw}}
      assert decode_console_msg(raw).message == "Estas muerto."
      refute_receive {:session, :near, _}, 50
    end
  end

  describe "packet-level filtering" do
    test "chat packets carry filtered text only to visible recipients" do
      sender_pid = start_session(:sender)
      near_pid = start_session(:near)
      far_pid = start_session(:far)

      sender = make_entity()
      near = make_entity(%{char_id: :near, name: "Nearby", x: 51, y: 50, char_index: 2})
      far = make_entity(%{char_id: :far, name: "FarAway", x: 90, y: 90, char_index: 3})

      state =
        make_state(
          %{sender.char_id => sender, near.char_id => near, far.char_id => far},
          sessions: %{
            sender.char_id => sender_pid,
            near.char_id => near_pid,
            far.char_id => far_pid
          }
        )

      message = "sos un pelotudo"
      filtered = Arena.ChatFilter.filter(message)

      {:noreply, new_state} = Chat.handle_chat(state, sender.char_id, message)

      assert new_state.players[sender.char_id].last_chat_at > sender.last_chat_at

      assert_receive {:session, :sender, {:send_raw, sender_raw}}
      assert_receive {:session, :near, {:send_raw, near_raw}}
      refute_receive {:session, :far, _}, 50

      sender_packet = decode_chat_over_head(sender_raw)
      near_packet = decode_chat_over_head(near_raw)

      assert sender_packet.message == filtered
      assert near_packet.message == filtered
      refute String.contains?(sender_packet.message, "pelotudo")
      refute String.contains?(near_packet.message, "pelotudo")
    end

    test "yell packets also carry filtered text" do
      sender_pid = start_session(:sender)
      near_pid = start_session(:near)

      sender = make_entity()
      near = make_entity(%{char_id: :near, name: "Nearby", x: 51, y: 50, char_index: 2})

      state =
        make_state(
          %{sender.char_id => sender, near.char_id => near},
          sessions: %{sender.char_id => sender_pid, near.char_id => near_pid}
        )

      message = "pelotudo"
      filtered = Arena.ChatFilter.filter(message)

      {:noreply, _state} = Chat.handle_yell(state, sender.char_id, message)

      assert_receive {:session, :sender, {:send_raw, sender_raw}}
      assert_receive {:session, :near, {:send_raw, near_raw}}

      assert decode_chat_over_head(sender_raw).message == filtered
      assert decode_chat_over_head(near_raw).message == filtered
    end
  end

  describe "cooldown behavior" do
    test "muted player cannot bypass mute by alternating chat and yell" do
      sender_pid = start_session(:sender)
      near_pid = start_session(:near)

      muted_until = System.system_time(:millisecond) + 60_000
      sender = make_entity(%{muted_until: muted_until})
      near = make_entity(%{char_id: :near, name: "Nearby", x: 51, y: 50, char_index: 2})

      state =
        make_state(
          %{sender.char_id => sender, near.char_id => near},
          sessions: %{sender.char_id => sender_pid, near.char_id => near_pid}
        )

      {:noreply, state} = Chat.handle_chat(state, sender.char_id, "Chat attempt")
      {:noreply, state} = Chat.handle_yell(state, sender.char_id, "Yell attempt")
      {:noreply, state} = Chat.handle_chat(state, sender.char_id, "Chat again")

      messages = collect_session_messages(100)

      sender_console_messages =
        for {:session, :sender, {:send_raw, raw}} <- messages, do: decode_console_msg(raw).message

      near_messages = for {:session, :near, _msg} <- messages, do: :near

      assert sender_console_messages == ["Estás silenciado.", "Estás silenciado.", "Estás silenciado."]
      assert near_messages == []
      assert state.players[sender.char_id].last_chat_at == sender.last_chat_at
    end

    test "chat_cooldown_ms=0 allows immediate repeat chat instead of silently dropping it" do
      Arena.Settings.set(:chat_cooldown_ms, 0)

      sender_pid = start_session(:sender)
      near_pid = start_session(:near)

      sender = make_entity()
      near = make_entity(%{char_id: :near, name: "Nearby", x: 51, y: 50, char_index: 2})

      state =
        make_state(
          %{sender.char_id => sender, near.char_id => near},
          sessions: %{sender.char_id => sender_pid, near.char_id => near_pid}
        )

      {:noreply, state} = Chat.handle_chat(state, sender.char_id, "first")
      {:noreply, _state} = Chat.handle_chat(state, sender.char_id, "second")

      messages = collect_session_messages(100)

      sender_chat_messages =
        for {:session, :sender, {:send_raw, raw}} <- messages, do: decode_chat_over_head(raw).message

      near_chat_messages =
        for {:session, :near, {:send_raw, raw}} <- messages, do: decode_chat_over_head(raw).message

      assert sender_chat_messages == ["first", "second"]
      assert near_chat_messages == ["first", "second"]
    end
  end

  describe "missing player" do
    test "nonexistent player is a clean no-op with no packets" do
      state = make_state(%{}, sessions: %{ghost: start_session(:ghost)})

      {:noreply, new_state} = Chat.handle_yell(state, :ghost, "Hello!")

      assert new_state == state
      refute_receive {:session, :ghost, _}, 50
    end
  end
end
