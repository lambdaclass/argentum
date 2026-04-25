defmodule BotArmy.BotTest do
  @moduledoc """
  Lightweight unit checks on Bot init that don't require a running server.

  The bot triggers a :connect on init; that call fails fast (no server)
  and the bot then sleeps for @reconnect_delay (5s). We grab state in
  that window.
  """
  use ExUnit.Case, async: true

  alias BotArmy.Bot

  test "init stores profile and recv_delay_ms in state" do
    {:ok, pid} =
      Bot.start_link(
        char_id: 99_001,
        profile: :slow_client,
        recv_delay_ms: 750
      )

    state = :sys.get_state(pid)
    assert state.profile == :slow_client
    assert state.recv_delay_ms == 750

    GenServer.stop(pid)
  end

  test "recv_delay_ms defaults to 1000 when not provided" do
    {:ok, pid} = Bot.start_link(char_id: 99_002, profile: :walk_only)

    state = :sys.get_state(pid)
    assert state.recv_delay_ms == 1_000
    assert state.profile == :walk_only

    GenServer.stop(pid)
  end

  test "slow_client bot handles :rearm_recv with no socket gracefully" do
    {:ok, pid} = Bot.start_link(char_id: 99_003, profile: :slow_client)
    # No server means socket stays nil after the failed connect.
    send(pid, :rearm_recv)
    # Survive a roundtrip to the GenServer.
    assert :sys.get_state(pid).profile == :slow_client
    GenServer.stop(pid)
  end
end
