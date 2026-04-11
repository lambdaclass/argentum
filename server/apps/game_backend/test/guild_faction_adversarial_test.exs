defmodule GameBackend.GuildFactionAdversarialTest do
  @moduledoc """
  Adversarial / negative-path tests for guild, faction, ban, and mute persistence.

  Tests that the system handles bad input correctly at the DB layer.
  Uses direct Ecto/context calls against a sandboxed Postgres connection.
  No TCP connections required.
  """

  use ExUnit.Case, async: false

  alias GameBackend.Repo
  alias GameBackend.Guilds
  alias GameBackend.Characters
  alias GameBackend.Account

  setup do
    owner_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid) end)

    {:ok, account} = Account.create("advuser_#{System.unique_integer([:positive])}", "password123")

    %{account: account}
  end

  defp create_character(account, name_suffix \\ "") do
    name = "AdvChar#{System.unique_integer([:positive])}#{name_suffix}"

    {:ok, char} =
      Characters.create(%{
        name: name,
        account_id: account.id
      })

    char
  end

  # =========================================================================
  # Guild adversarial
  # =========================================================================

  describe "guild: empty name" do
    test "creating a guild with empty name fails", %{account: account} do
      char = create_character(account)
      result = Guilds.create_guild(char.id, "")
      assert {:error, _} = result
    end
  end

  describe "guild: extremely long name" do
    test "creating a guild with 1000+ char name fails validation", %{account: account} do
      char = create_character(account)
      long_name = String.duplicate("a", 1001)
      result = Guilds.create_guild(char.id, long_name)
      assert {:error, _} = result
    end
  end

  describe "guild: duplicate name" do
    test "creating two guilds with the same name fails on the second", %{account: account} do
      char_a = create_character(account, "_a")
      char_b = create_character(account, "_b")

      {:ok, _} = Guilds.create_guild(char_a.id, "DupeName")
      result = Guilds.create_guild(char_b.id, "DupeName")
      assert {:error, _} = result
    end
  end

  describe "guild: add same member twice" do
    test "adding the same member to a guild twice fails on the second insert", %{account: account} do
      leader = create_character(account, "_leader")
      member = create_character(account, "_member")

      {:ok, guild} = Guilds.create_guild(leader.id, "DupeMember")
      {:ok, _} = Guilds.add_member(guild.id, member.id)

      # Second add should fail due to unique constraint on char_id
      result = Guilds.add_member(guild.id, member.id)
      assert {:error, _} = result
    end
  end

  describe "guild: add member to non-existent guild" do
    test "adding a member to a non-existent guild raises a constraint error", %{account: account} do
      member = create_character(account)
      bogus_guild_id = 999_999_999

      # The GuildMember changeset does not declare a foreign_key_constraint,
      # so Ecto raises Ecto.ConstraintError instead of returning {:error, _}.
      assert_raise Ecto.ConstraintError, fn ->
        Guilds.add_member(bogus_guild_id, member.id)
      end
    end
  end

  describe "guild: remove member who is not in the guild" do
    test "removing a non-member does not crash and returns {0, nil}", %{account: account} do
      leader = create_character(account, "_leader")
      outsider = create_character(account, "_outsider")

      {:ok, guild} = Guilds.create_guild(leader.id, "NoMember")

      # Should not crash; delete_all returns {count, nil}
      result = Guilds.remove_member(guild.id, outsider.id)
      assert {0, nil} == result
    end
  end

  describe "guild: delete guild that doesn't exist" do
    test "deleting a non-existent guild does not crash", _context do
      bogus_guild_id = 999_999_999

      # delete_guild handles nil gracefully
      result = Guilds.delete_guild(bogus_guild_id)
      assert {:ok, :ok} == result
    end
  end

  describe "guild: create with non-existent leader character ID" do
    test "create_guild with bogus char_id still inserts (no FK on leader_id)", %{account: account} do
      # leader_id is just an integer column, not a foreign key in the migration.
      # The guild is created but has no valid leader character. This tests that
      # no crash occurs; the system stores the value as-is.
      bogus_char_id = 999_999_999
      result = Guilds.create_guild(bogus_char_id, "OrphanGuild")

      # It succeeds at the DB level because leader_id has no FK constraint.
      # The member insert will also succeed since char_id on guild_members
      # is just an integer column with no FK to characters.
      assert {:ok, guild} = result
      assert guild.leader_id == bogus_char_id

      # Cleanup: remove the guild so it doesn't affect other tests
      _ = Guilds.delete_guild(guild.id)
      _ = create_character(account, "_unused")
    end
  end

  describe "guild: war/alliance between same guild" do
    test "set_relation with same guild_id for both sides stores a self-relation", %{account: account} do
      leader = create_character(account)
      {:ok, guild} = Guilds.create_guild(leader.id, "SelfWar")

      # set_relation normalizes to min(a,b), max(a,b). When both are the same,
      # it becomes (guild.id, guild.id). The DB allows this (no check constraint).
      result = Guilds.set_relation(guild.id, guild.id, "war")
      assert {:ok, _} = result

      # Verify it's stored
      relations = Guilds.list_relations()
      self_rel = Enum.find(relations, fn r -> r.guild_a_id == guild.id and r.guild_b_id == guild.id end)
      assert self_rel != nil
      assert self_rel.relation_type == "war"

      # Cleanup
      Guilds.delete_relation(guild.id, guild.id)
    end
  end

  describe "guild: war/alliance with non-existent guild" do
    test "set_relation with non-existent guild_id fails with FK violation", %{account: account} do
      leader = create_character(account)
      {:ok, guild} = Guilds.create_guild(leader.id, "WarPhantom")
      bogus_guild_id = 999_999_999

      # guild_relations has FK references to guilds, so this should raise
      assert_raise Ecto.ConstraintError, fn ->
        Guilds.set_relation(guild.id, bogus_guild_id, "war")
      end
    end
  end

  describe "guild: duplicate war declaration" do
    test "declaring war twice updates the existing relation (idempotent)", %{account: account} do
      leader_a = create_character(account, "_a")
      leader_b = create_character(account, "_b")

      {:ok, guild_a} = Guilds.create_guild(leader_a.id, "DupWarA")
      {:ok, guild_b} = Guilds.create_guild(leader_b.id, "DupWarB")

      {:ok, rel1} = Guilds.set_relation(guild_a.id, guild_b.id, "war")
      {:ok, rel2} = Guilds.set_relation(guild_a.id, guild_b.id, "war")

      # set_relation does an upsert: should return same relation ID
      assert rel1.id == rel2.id
      assert rel2.relation_type == "war"

      # Only one relation row exists
      {a, b} = if guild_a.id <= guild_b.id, do: {guild_a.id, guild_b.id}, else: {guild_b.id, guild_a.id}
      count = Guilds.list_relations() |> Enum.count(fn r -> r.guild_a_id == a and r.guild_b_id == b end)
      assert count == 1
    end
  end

  # =========================================================================
  # Faction adversarial
  # =========================================================================

  describe "faction: invalid string" do
    test "setting faction to an unknown string stores it as-is (no enum constraint)", %{account: account} do
      char = create_character(account)

      # The characters table has no CHECK constraint on faction, it's just a string.
      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "totally_bogus"})
      reloaded = Characters.get(char.id)
      assert reloaded.faction == "totally_bogus"
    end
  end

  describe "faction: empty string" do
    test "setting faction to empty string stores it or keeps default", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction: ""})
      reloaded = Characters.get(char.id)
      # Empty string is cast; the DB stores it. If the changeset treats ""
      # as no-change, the default "none" is preserved. Either outcome is acceptable.
      assert reloaded.faction in ["", "none"]
    end
  end

  describe "faction: nil value" do
    test "setting faction to nil clears it in the DB", %{account: account} do
      char = create_character(account)
      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "armada"})

      {:ok, _} = Characters.save_snapshot(char.id, %{faction: nil})
      reloaded = Characters.get(char.id)
      assert reloaded.faction == nil
    end
  end

  describe "faction: change while already in a faction" do
    test "changing faction from armada to chaos works", %{account: account} do
      char = create_character(account)
      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "armada"})
      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "chaos"})

      reloaded = Characters.get(char.id)
      assert reloaded.faction == "chaos"
    end
  end

  # =========================================================================
  # Ban / mute adversarial
  # =========================================================================

  describe "ban: already-banned account" do
    test "banning an already-banned account updates the ban_until (idempotent)", %{account: account} do
      first_until = DateTime.add(DateTime.utc_now(), 3600, :second)
      second_until = DateTime.add(DateTime.utc_now(), 7200, :second)

      {:ok, _} = Account.ban(account.id, first_until)
      {:ok, _} = Account.ban(account.id, second_until)

      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == true

      # The ban_until should be the second (later) value
      assert DateTime.compare(reloaded.banned_until, DateTime.truncate(second_until, :second)) == :eq
    end
  end

  describe "ban: negative duration" do
    test "banning with a past datetime results in not being considered banned", %{account: account} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      {:ok, _} = Account.ban(account.id, past)

      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == false
    end
  end

  describe "ban: unban account that is not banned" do
    test "unbanning a non-banned account does not crash", %{account: account} do
      # Account starts with nil banned_until — unbanning should be fine
      {:ok, updated} = Account.unban(account.id)
      assert updated.banned_until == nil
    end
  end

  describe "mute: past timestamp" do
    test "muted_until in the past is stored but should be considered expired", %{account: account} do
      char = create_character(account)

      past_ts = System.os_time(:second) - 3600
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: past_ts})

      reloaded = Characters.get(char.id)
      assert reloaded.muted_until == past_ts

      # The value is in the past, so any runtime check comparing against
      # System.os_time(:second) should consider the mute expired.
      assert reloaded.muted_until < System.os_time(:second)
    end
  end

  describe "ban: non-existent account" do
    test "banning a non-existent account returns error", _context do
      bogus_account_id = 999_999_999
      result = Account.ban(bogus_account_id, DateTime.add(DateTime.utc_now(), 3600, :second))
      assert result == {:error, :not_found}
    end

    test "unbanning a non-existent account returns error", _context do
      bogus_account_id = 999_999_999
      result = Account.unban(bogus_account_id)
      assert result == {:error, :not_found}
    end
  end

  # =========================================================================
  # Concurrent / race conditions
  # =========================================================================

  describe "concurrent: two processes try to create guild with same name" do
    test "only one succeeds, the other fails", %{account: account} do
      char_a = create_character(account, "_race_a")
      char_b = create_character(account, "_race_b")

      parent = self()

      task_a =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Guilds.create_guild(char_a.id, "RaceGuild")
        end)

      task_b =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Guilds.create_guild(char_b.id, "RaceGuild")
        end)

      result_a = Task.await(task_a)
      result_b = Task.await(task_b)

      results = [result_a, result_b]

      successes =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      failures =
        Enum.count(results, fn
          {:error, _} -> true
          _ -> false
        end)

      # Exactly one should succeed and one should fail due to unique constraint
      assert successes == 1
      assert failures == 1
    end
  end

  describe "concurrent: remove guild member while iterating members" do
    test "removing a member while listing does not crash", %{account: account} do
      leader = create_character(account, "_leader")
      members = for i <- 1..5, do: create_character(account, "_m#{i}")

      {:ok, guild} = Guilds.create_guild(leader.id, "IterGuild")
      for m <- members, do: Guilds.add_member(guild.id, m.id)

      parent = self()

      # One task lists all guilds (reads members)
      reader =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

          for _ <- 1..10 do
            all = Guilds.list_all()
            g = Enum.find(all, &(&1.id == guild.id))
            if g, do: length(g.members), else: 0
          end
        end)

      # Another task removes members concurrently
      remover =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

          for m <- members do
            Guilds.remove_member(guild.id, m.id)
          end
        end)

      # Neither should crash
      reader_results = Task.await(reader)
      _remover_results = Task.await(remover)

      assert is_list(reader_results)

      # After removal, only leader remains
      final_guild = Guilds.get_guild_by_char(leader.id)
      assert final_guild != nil
      assert length(final_guild.members) == 1
    end
  end
end
