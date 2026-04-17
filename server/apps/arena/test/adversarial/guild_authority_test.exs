defmodule Arena.Adversarial.GuildAuthorityTest do
  @moduledoc """
  Adversarial tests for guild authority checks.

  Verifies that GuildServer correctly rejects operations from unauthorized
  players: non-leaders cannot invite/kick/set news/declare war, players
  cannot accept invites meant for others or join while already in a guild, etc.

  Uses direct ETS manipulation to set up guild state, bypassing DB persistence.
  This isolates the authority-check logic from DB availability.
  """
  use ExUnit.Case, async: false

  alias Arena.GuildServer

  @table :ao_guilds

  # Synthetic IDs -- no DB backing needed
  @guild_id 9001
  @guild2_id 9002
  @leader_id 1001
  @member_id 1002
  @outsider_id 1003
  @leader2_id 1004

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup do
    # Start GuildServer if not already running.
    # Its init creates the ETS table and loads from DB (which rescues gracefully).
    case GuildServer.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Clean slate: delete all ETS entries from previous tests
    :ets.delete_all_objects(@table)

    # Seed guild A: leader=@leader_id, member=@member_id
    guild = %{
      id: @guild_id,
      name: "TestGuild",
      leader: @leader_id,
      founder_id: @leader_id,
      created_at: ~N[2025-01-01 00:00:00],
      members: [@leader_id, @member_id],
      level: 1,
      current_exp: 0,
      description: "",
      news: "",
      url: "",
      alignment: 0
    }

    :ets.insert(@table, {{:guild, @guild_id}, guild})
    :ets.insert(@table, {{:member, @leader_id}, @guild_id})
    :ets.insert(@table, {{:member, @member_id}, @guild_id})

    # Seed guild B: leader=@leader2_id, no other members
    guild2 = %{
      id: @guild2_id,
      name: "RivalGuild",
      leader: @leader2_id,
      founder_id: @leader2_id,
      created_at: ~N[2025-01-01 00:00:00],
      members: [@leader2_id],
      level: 1,
      current_exp: 0,
      description: "",
      news: "",
      url: "",
      alignment: 0
    }

    :ets.insert(@table, {{:guild, @guild2_id}, guild2})
    :ets.insert(@table, {{:member, @leader2_id}, @guild2_id})

    :ok
  end

  # ── 1. Non-leader cannot invite ─────────────────────────────────────────

  describe "non-leader invite" do
    test "a regular member cannot invite another player" do
      result = GuildServer.invite(@member_id, @outsider_id)
      assert result == {:error, :not_leader}
    end
  end

  # ── 2. Stale/expired invite ────────────────────────────────────────────

  describe "stale/expired invite" do
    test "accepting an invite whose TTL has passed returns :no_invite" do
      # Insert an invite that expired 10 seconds ago
      expired_at = System.monotonic_time(:millisecond) - 10_000

      :ets.insert(
        @table,
        {{:invite, @outsider_id},
         %{from: @leader_id, guild_id: @guild_id, expires_at: expired_at}}
      )

      # Trigger the cleanup timer manually
      send(Process.whereis(GuildServer), :cleanup_invites)
      # Give the GenServer a moment to process the info message
      Process.sleep(50)

      # Now try to accept -- the invite should have been cleaned up
      result = GuildServer.accept_invite(@outsider_id)
      assert result == {:error, :no_invite}
    end

    test "accepting an invite after the inviter loses leadership is rejected" do
      now = System.monotonic_time(:millisecond)

      :ets.insert(
        @table,
        {{:invite, @outsider_id},
         %{from: @leader_id, guild_id: @guild_id, expires_at: now + 60_000}}
      )

      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      :ets.insert(@table, {{:guild, @guild_id}, %{guild | leader: @member_id}})

      result = GuildServer.accept_invite(@outsider_id)

      assert result in [{:error, :invite_invalid}, {:error, :not_leader}, {:error, :no_invite}, {:error, :db_error}]
      assert :ets.lookup(@table, {:member, @outsider_id}) == []
    end

    test "accepting an invite after the inviter leaves the guild is rejected" do
      now = System.monotonic_time(:millisecond)

      :ets.insert(
        @table,
        {{:invite, @outsider_id},
         %{from: @leader_id, guild_id: @guild_id, expires_at: now + 60_000}}
      )

      :ets.delete(@table, {:member, @leader_id})
      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      :ets.insert(@table, {{:guild, @guild_id}, %{guild | leader: @member_id, members: [@member_id]}})

      result = GuildServer.accept_invite(@outsider_id)

      assert result in [{:error, :invite_invalid}, {:error, :not_leader}, {:error, :no_invite}, {:error, :db_error}]
      assert :ets.lookup(@table, {:member, @outsider_id}) == []
    end

    test "accepting an invite after the guild is deleted returns :guild_gone" do
      now = System.monotonic_time(:millisecond)

      :ets.insert(
        @table,
        {{:invite, @outsider_id},
         %{from: @leader_id, guild_id: @guild_id, expires_at: now + 60_000}}
      )

      :ets.delete(@table, {:guild, @guild_id})

      result = GuildServer.accept_invite(@outsider_id)

      assert result == {:error, :guild_gone}
      assert :ets.lookup(@table, {:member, @outsider_id}) == []
    end
  end

  # ── 3. Accept invite meant for a different player ──────────────────────

  describe "invite targeting" do
    test "a player cannot accept an invite addressed to someone else" do
      # Create an invite addressed to @outsider_id
      now = System.monotonic_time(:millisecond)

      :ets.insert(
        @table,
        {{:invite, @outsider_id},
         %{from: @leader_id, guild_id: @guild_id, expires_at: now + 60_000}}
      )

      # A completely different player (char_id 9999) tries to accept
      result = GuildServer.accept_invite(9999)
      assert result == {:error, :no_invite}

      # The original invite is still in ETS for the correct target
      assert :ets.lookup(@table, {:invite, @outsider_id}) != []
    end
  end

  # ── 4. Non-leader cannot kick ──────────────────────────────────────────

  describe "non-leader kick" do
    test "a regular member cannot kick another member" do
      # kick is a cast, so we check state after
      GuildServer.kick(@member_id, @leader_id)
      # Allow the cast to be processed
      Process.sleep(50)

      # Leader should still be a member
      assert :ets.lookup(@table, {:member, @leader_id}) == [{{:member, @leader_id}, @guild_id}]

      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert @leader_id in guild.members
    end
  end

  # ── 5. Non-leader cannot set guild news ────────────────────────────────

  describe "non-leader set news" do
    test "a regular member cannot set guild news" do
      result = GuildServer.set_guild_news(@member_id, "Hacked news")
      assert result == {:error, :not_leader}

      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert guild.news == ""
    end
  end

  # ── 6. Non-leader cannot set guild description ─────────────────────────

  describe "non-leader set description" do
    test "a regular member cannot set guild description" do
      result = GuildServer.set_guild_description(@member_id, "Hacked description")
      assert result == {:error, :not_leader}

      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert guild.description == ""
    end
  end

  # ── 7. Non-leader cannot set guild website ─────────────────────────────

  describe "non-leader set website" do
    test "a regular member cannot update guild website" do
      result = GuildServer.update_website(@member_id, "http://evil.com")
      assert result == {:error, :not_leader}

      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert guild.url == ""
    end
  end

  # ── 8. Cannot join a guild while already in one ────────────────────────

  describe "already-in-guild guard" do
    test "a player already in a guild cannot accept another invite" do
      # @member_id is already in @guild_id. Create an invite for them anyway.
      now = System.monotonic_time(:millisecond)

      :ets.insert(
        @table,
        {{:invite, @member_id},
         %{from: @leader2_id, guild_id: @guild2_id, expires_at: now + 60_000}}
      )

      result = GuildServer.accept_invite(@member_id)
      assert result == {:error, :already_in_guild}

      # Still in original guild
      assert :ets.lookup(@table, {:member, @member_id}) == [{{:member, @member_id}, @guild_id}]
    end

    test "a player already in a guild cannot request membership elsewhere" do
      result = GuildServer.request_membership(@member_id, "RivalGuild", "Let me in")
      assert result == {:error, :already_in_guild}
    end
  end

  # ── 9. Non-leader cannot declare war ───────────────────────────────────

  describe "non-leader declare war" do
    test "a regular member cannot declare war" do
      result = GuildServer.declare_war(@member_id, "RivalGuild")
      assert result == {:error, :not_leader}
    end
  end

  # ── 10. Non-leader cannot propose alliance ─────────────────────────────

  describe "non-leader propose alliance" do
    test "a regular member cannot propose alliance" do
      result = GuildServer.propose_alliance(@member_id, "RivalGuild")
      assert result == {:error, :not_leader}
    end
  end

  # ── 11. Leader cannot kick themselves ──────────────────────────────────

  describe "leader self-kick" do
    test "leader kicking themselves is silently rejected" do
      GuildServer.kick(@leader_id, @leader_id)
      Process.sleep(50)

      # Leader should still be in the guild
      assert :ets.lookup(@table, {:member, @leader_id}) == [{{:member, @leader_id}, @guild_id}]

      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert @leader_id in guild.members
      assert guild.leader == @leader_id
    end
  end

  # ── 12. Cannot declare war on own guild ────────────────────────────────

  describe "declare war on own guild" do
    test "leader cannot declare war on their own guild" do
      result = GuildServer.declare_war(@leader_id, "TestGuild")
      assert result == {:error, :same_guild}
    end
  end

  # ── 13. Outsider (no guild) cannot perform leader actions ──────────────

  describe "outsider without guild" do
    test "outsider cannot set news" do
      result = GuildServer.set_guild_news(@outsider_id, "I have no guild")
      assert result == {:error, :not_in_guild}
    end

    test "outsider cannot declare war" do
      result = GuildServer.declare_war(@outsider_id, "TestGuild")
      assert result == {:error, :not_in_guild}
    end

    test "outsider cannot invite" do
      result = GuildServer.invite(@outsider_id, 9999)
      assert result == {:error, :not_in_guild}
    end

    test "outsider cannot list membership requests" do
      result = GuildServer.list_requests(@outsider_id)
      assert result == {:error, :not_in_guild}
    end
  end

  # ── 14. Self-invite guard ──────────────────────────────────────────────

  describe "self-invite" do
    test "leader cannot invite themselves" do
      result = GuildServer.invite(@leader_id, @leader_id)
      assert result == {:error, :self_invite}
    end
  end

  # ── 15. Inviting someone already in a guild ────────────────────────────

  describe "invite player already in guild" do
    test "leader cannot invite a player who is already in another guild" do
      result = GuildServer.invite(@leader_id, @leader2_id)
      assert result == {:error, :already_in_guild}
    end
  end
end
