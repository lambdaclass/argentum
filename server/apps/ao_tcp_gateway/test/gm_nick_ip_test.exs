defmodule AoTcpGateway.GmNickIpTest do
  @moduledoc """
  Tests for the GM address-lookup commands.

  VB6 semantics:
  - /NICK2IP (Protocol_GmCommands.bas:2061 HandleNickToIP) reports the peer
    address of the named online player.
  - /IP2NICK (Protocol_GmCommands.bas:2111 HandleIPToNick) reports every online
    player connected from the given address.

  Regression guard: `nick_to_ip` previously matched `{:ok, session}` against
  `OnlineDirectory.lookup_by_name/1`, which returns `{:ok, char_id, info}`.
  Every successful lookup raised CaseClauseError and killed the GM's session.
  The adversarial suite never caught it because non-GMs are rejected before
  dispatch, so the clause was only reachable by an actual GM.
  """
  use ExUnit.Case, async: false

  alias AoSession.OnlineDirectory
  alias AoTcpGateway.SessionCommands.Gm

  setup do
    unless Process.whereis(OnlineDirectory) do
      {:ok, _} = OnlineDirectory.start_link([])
    end

    :ets.delete_all_objects(:ao_online_directory)
    :ok
  end

  # These two clauses pass state through untouched, so a bare map is enough.
  defp state, do: %{character_id: 1, map_id: 1, is_gm: true}

  describe "/NICK2IP" do
    test "reports the peer address of an online player" do
      :ok = OnlineDirectory.register(700, "Victim", 1, self(), ip: "203.0.113.9")

      assert {_state, [{:console_msg, %{message: message}}]} =
               Gm.handle_command(state(), {:nick_to_ip, %{name: "Victim"}})

      assert message =~ "Victim"
      assert message =~ "203.0.113.9"
    end

    test "resolves names case-insensitively, like the directory index" do
      :ok = OnlineDirectory.register(700, "Victim", 1, self(), ip: "203.0.113.9")

      assert {_state, [{:console_msg, %{message: message}}]} =
               Gm.handle_command(state(), {:nick_to_ip, %{name: "victim"}})

      assert message =~ "203.0.113.9"
    end

    test "reports desconocida when the transport gave no peer" do
      :ok = OnlineDirectory.register(700, "Ghost", 1, self())

      assert {_state, [{:console_msg, %{message: message}}]} =
               Gm.handle_command(state(), {:nick_to_ip, %{name: "Ghost"}})

      assert message =~ "desconocida"
    end

    test "reports not-found for an offline player instead of crashing" do
      assert {_state, [{:console_msg, %{message: message}}]} =
               Gm.handle_command(state(), {:nick_to_ip, %{name: "Nobody"}})

      assert message =~ "no encontrado"
    end
  end

  describe "/IP2NICK" do
    test "lists only the players connected from the queried address" do
      :ok = OnlineDirectory.register(701, "Alt1", 1, self(), ip: "203.0.113.9")
      :ok = OnlineDirectory.register(702, "Alt2", 1, self(), ip: "203.0.113.9")
      :ok = OnlineDirectory.register(703, "Elsewhere", 1, self(), ip: "198.51.100.4")

      assert {_state, [{:console_msg, %{message: message}}]} =
               Gm.handle_command(state(), {:ip_to_nick, %{ip: "203.0.113.9"}})

      assert message =~ "Alt1"
      assert message =~ "Alt2"
      refute message =~ "Elsewhere"
    end

    test "reports no results for an address with nobody online" do
      :ok = OnlineDirectory.register(701, "Somebody", 1, self(), ip: "203.0.113.9")

      assert {_state, [{:console_msg, %{message: message}}]} =
               Gm.handle_command(state(), {:ip_to_nick, %{ip: "198.51.100.4"}})

      assert message =~ "sin resultados"
      refute message =~ "Somebody"
    end
  end
end
