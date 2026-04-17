defmodule AoTcpGateway.ChatAuthorityTest do
  @moduledoc """
  Adversarial chat-authorization tests for guild and party chat.

  These target the remaining moderation gaps: mute and cooldown enforcement in
  the gateway layer, plus the text guild-chat path bypassing dead checks.
  """

  use ExUnit.Case, async: false

  alias AoTcpGateway.SessionLogic

  @guild_table :ao_guilds
  @party_table :ao_parties
  @online_table :ao_online_directory

  setup do
    unless Process.whereis(AoSession.OnlineDirectory) do
      {:ok, _} = AoSession.OnlineDirectory.start_link([])
    end

    case Arena.GuildServer.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Arena.PartyServer.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ets.delete_all_objects(@online_table)
    :ets.delete_all_objects(@guild_table)
    :ets.delete_all_objects(@party_table)

    :ok
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 1001,
        map_id: 1,
        account_id: "acct_chat",
        entity: %{muted_until: 0, last_chat_at: -1_000_000_000_000},
        char_index: 1,
        target_x: nil,
        target_y: nil,
        is_gm: false,
        is_dead: false
      },
      overrides
    )
  end

  defp probe(tag) do
    test_pid = self()

    spawn(fn ->
      loop = fn loop ->
        receive do
          :stop -> :ok
          msg ->
            send(test_pid, {tag, msg})
            loop.(loop)
        end
      end

      loop.(loop)
    end)
  end

  defp seed_guild(guild_id, leader_id, members, name \\ "TestGuild") do
    guild = %{
      id: guild_id,
      name: name,
      leader: leader_id,
      founder_id: leader_id,
      created_at: ~N[2025-01-01 00:00:00],
      members: members,
      level: 1,
      current_exp: 0,
      description: "",
      news: "",
      url: "",
      alignment: 0
    }

    :ets.insert(@guild_table, {{:guild, guild_id}, guild})

    for member_id <- members do
      :ets.insert(@guild_table, {{:member, member_id}, guild_id})
    end
  end

  defp seed_party(party_id, leader_id, members) do
    :ets.insert(@party_table, {{:party, party_id}, %{leader: leader_id, members: members, safe: false}})

    for member_id <- members do
      :ets.insert(@party_table, {{:member, member_id}, party_id})
    end
  end

  describe "guild chat moderation" do
    test "muted player cannot send guild_message" do
      sender_pid = probe(:sender)
      recipient_pid = probe(:recipient)
      future = System.system_time(:millisecond) + 60_000

      AoSession.OnlineDirectory.register(1001, "MutedSender", 1, sender_pid)
      AoSession.OnlineDirectory.register(1002, "Guildmate", 1, recipient_pid)
      seed_guild(1, 1001, [1001, 1002])

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(1001)
        AoSession.OnlineDirectory.unregister(1002)
        send(sender_pid, :stop)
        send(recipient_pid, :stop)
      end)

      {_state, packets} =
        SessionLogic.handle_command(
          base_state(%{entity: %{muted_until: future, last_chat_at: -1_000_000_000_000}}),
          {:guild_message, %{message: "silenced"}}
        )

      assert packets == [{:console_msg, %{message: "Estás silenciado.", font_index: 0}}]
      refute_receive {:recipient, {:send_raw, <<39::little-signed-16, _::binary>>}}, 50
    end

    test "dead player cannot use /CC text guild chat" do
      sender_pid = probe(:sender)
      recipient_pid = probe(:recipient)

      AoSession.OnlineDirectory.register(1001, "DeadSender", 1, sender_pid)
      AoSession.OnlineDirectory.register(1002, "Guildmate", 1, recipient_pid)
      seed_guild(1, 1001, [1001, 1002])

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(1001)
        AoSession.OnlineDirectory.unregister(1002)
        send(sender_pid, :stop)
        send(recipient_pid, :stop)
      end)

      {_state, packets} =
        SessionLogic.handle_command(
          base_state(%{is_dead: true}),
          {:talk, %{message: "/CC still talking"}}
        )

      assert packets == []
      refute_receive {:recipient, {:send_raw, <<39::little-signed-16, _::binary>>}}, 50
    end
  end

  describe "party chat moderation" do
    test "muted player cannot use party chat" do
      sender_pid = probe(:sender)
      recipient_pid = probe(:recipient)
      future = System.system_time(:millisecond) + 60_000

      AoSession.OnlineDirectory.register(1001, "MutedSender", 1, sender_pid)
      AoSession.OnlineDirectory.register(1002, "PartyMate", 1, recipient_pid)
      seed_party(1, 1001, [1001, 1002])

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(1001)
        AoSession.OnlineDirectory.unregister(1002)
        send(sender_pid, :stop)
        send(recipient_pid, :stop)
      end)

      {_state, packets} =
        SessionLogic.handle_command(
          base_state(%{entity: %{muted_until: future, last_chat_at: -1_000_000_000_000}}),
          {:grupo_msg, %{message: "party spam"}}
        )

      assert packets == [{:console_msg, %{message: "Estás silenciado.", font_index: 0}}]
      refute_receive {:recipient, {:send_raw, <<37::little-signed-16, _::binary>>}}, 50
    end

    test "party chat cooldown blocks immediate resend" do
      sender_pid = probe(:sender)
      recipient_pid = probe(:recipient)
      now = System.monotonic_time(:millisecond)

      AoSession.OnlineDirectory.register(1001, "FastSender", 1, sender_pid)
      AoSession.OnlineDirectory.register(1002, "PartyMate", 1, recipient_pid)
      seed_party(1, 1001, [1001, 1002])

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(1001)
        AoSession.OnlineDirectory.unregister(1002)
        send(sender_pid, :stop)
        send(recipient_pid, :stop)
      end)

      {_state, packets} =
        SessionLogic.handle_command(
          base_state(%{entity: %{muted_until: 0, last_chat_at: now}}),
          {:grupo_msg, %{message: "too fast"}}
        )

      assert packets == [{:console_msg, %{message: "Estás hablando demasiado rápido.", font_index: 0}}]
      refute_receive {:recipient, {:send_raw, <<37::little-signed-16, _::binary>>}}, 50
    end
  end
end
