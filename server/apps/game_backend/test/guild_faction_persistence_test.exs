defmodule GameBackend.GuildFactionPersistenceTest do
  @moduledoc """
  Persistence tests for guild, faction, ban, and mute state.

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

    # Create a test account
    {:ok, account} = Account.create("testuser_#{System.unique_integer([:positive])}", "password123")

    %{account: account}
  end

  defp create_character(account, name_suffix \\ "") do
    name = "TestChar#{System.unique_integer([:positive])}#{name_suffix}"

    {:ok, char} =
      Characters.create(%{
        name: name,
        account_id: account.id
      })

    char
  end

  # ---- Guild creation persists ----

  describe "guild creation persists" do
    test "creating a guild writes it to DB and it can be reloaded", %{account: account} do
      char = create_character(account)

      {:ok, db_guild} = Guilds.create_guild(char.id, "TestClan")

      # Verify it exists in DB
      all_guilds = Guilds.list_all()
      guild_ids = Enum.map(all_guilds, & &1.id)
      assert db_guild.id in guild_ids

      # Reload the guild fresh from DB
      reloaded = Repo.get(GameBackend.Guild, db_guild.id) |> Repo.preload(:members)
      assert reloaded != nil
      assert reloaded.name == "TestClan"
      assert reloaded.leader_id == char.id
      assert reloaded.founder_id == char.id
    end
  end

  # ---- Guild membership persists ----

  describe "guild membership persists" do
    test "adding a member writes it to DB and can be queried", %{account: account} do
      leader = create_character(account, "_leader")
      member = create_character(account, "_member")

      {:ok, db_guild} = Guilds.create_guild(leader.id, "MemberClan")

      # Add a member
      {:ok, _db_member} = Guilds.add_member(db_guild.id, member.id)

      # Query guild members from DB
      guild = Guilds.get_guild_by_char(member.id)
      assert guild != nil
      assert guild.id == db_guild.id

      member_ids = Enum.map(guild.members, & &1.char_id)
      assert leader.id in member_ids
      assert member.id in member_ids
    end

    test "removing a member removes from DB", %{account: account} do
      leader = create_character(account, "_leader")
      member = create_character(account, "_member")

      {:ok, db_guild} = Guilds.create_guild(leader.id, "KickClan")
      {:ok, _} = Guilds.add_member(db_guild.id, member.id)

      # Remove the member
      Guilds.remove_member(db_guild.id, member.id)

      # Verify member is gone
      assert Guilds.get_guild_by_char(member.id) == nil

      # Leader is still there
      guild = Guilds.get_guild_by_char(leader.id)
      assert guild != nil
      member_ids = Enum.map(guild.members, & &1.char_id)
      assert leader.id in member_ids
      refute member.id in member_ids
    end
  end

  # ---- Guild relations persist ----

  describe "guild relations persist" do
    test "war relation persists in DB", %{account: account} do
      leader_a = create_character(account, "_a")
      leader_b = create_character(account, "_b")

      {:ok, guild_a} = Guilds.create_guild(leader_a.id, "WarClanA")
      {:ok, guild_b} = Guilds.create_guild(leader_b.id, "WarClanB")

      # Declare war
      {:ok, _relation} = Guilds.set_relation(guild_a.id, guild_b.id, "war")

      # Reload from DB
      relations = Guilds.list_relations()
      {a, b} = if guild_a.id <= guild_b.id, do: {guild_a.id, guild_b.id}, else: {guild_b.id, guild_a.id}

      war =
        Enum.find(relations, fn r ->
          r.guild_a_id == a and r.guild_b_id == b
        end)

      assert war != nil
      assert war.relation_type == "war"
    end

    test "alliance relation persists in DB", %{account: account} do
      leader_a = create_character(account, "_a")
      leader_b = create_character(account, "_b")

      {:ok, guild_a} = Guilds.create_guild(leader_a.id, "AllyClanA")
      {:ok, guild_b} = Guilds.create_guild(leader_b.id, "AllyClanB")

      {:ok, _relation} = Guilds.set_relation(guild_a.id, guild_b.id, "alliance")

      relations = Guilds.list_relations()
      {a, b} = if guild_a.id <= guild_b.id, do: {guild_a.id, guild_b.id}, else: {guild_b.id, guild_a.id}

      alliance =
        Enum.find(relations, fn r ->
          r.guild_a_id == a and r.guild_b_id == b
        end)

      assert alliance != nil
      assert alliance.relation_type == "alliance"
    end

    test "deleting a relation removes it from DB", %{account: account} do
      leader_a = create_character(account, "_a")
      leader_b = create_character(account, "_b")

      {:ok, guild_a} = Guilds.create_guild(leader_a.id, "DelRelA")
      {:ok, guild_b} = Guilds.create_guild(leader_b.id, "DelRelB")

      {:ok, _} = Guilds.set_relation(guild_a.id, guild_b.id, "war")
      Guilds.delete_relation(guild_a.id, guild_b.id)

      relations = Guilds.list_relations()
      {a, b} = if guild_a.id <= guild_b.id, do: {guild_a.id, guild_b.id}, else: {guild_b.id, guild_a.id}

      war =
        Enum.find(relations, fn r ->
          r.guild_a_id == a and r.guild_b_id == b
        end)

      assert war == nil
    end
  end

  # ---- Guild requests persist ----

  describe "guild requests persist" do
    test "membership request is stored and can be listed", %{account: account} do
      leader = create_character(account, "_leader")
      applicant = create_character(account, "_applicant")

      {:ok, guild} = Guilds.create_guild(leader.id, "ReqClan")

      {:ok, _request} = Guilds.create_request(guild.id, applicant.id, "Please accept me")

      requests = Guilds.list_requests(guild.id)
      assert length(requests) == 1
      assert hd(requests).char_id == applicant.id
      assert hd(requests).description == "Please accept me"
    end

    test "deleting a request removes it", %{account: account} do
      leader = create_character(account, "_leader")
      applicant = create_character(account, "_applicant")

      {:ok, guild} = Guilds.create_guild(leader.id, "ReqDelClan")
      {:ok, _} = Guilds.create_request(guild.id, applicant.id)

      Guilds.delete_request(guild.id, applicant.id)

      requests = Guilds.list_requests(guild.id)
      assert requests == []
    end
  end

  # ---- Faction assignment persists ----

  describe "faction assignment persists" do
    test "setting faction on character survives reload", %{account: account} do
      char = create_character(account)

      # Assign faction
      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "armada"})

      # Reload from DB
      reloaded = Characters.get(char.id)
      assert reloaded.faction == "armada"
    end

    test "faction converts correctly to entity and back", %{account: account} do
      char = create_character(account)
      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "chaos"})

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)
      assert entity.faction == :chaos

      attrs = Characters.from_entity(entity)
      assert attrs.faction == "chaos"
    end
  end

  # ---- Ban persists ----

  describe "ban persists" do
    test "banning an account persists and is detectable on reload", %{account: account} do
      # Ban for 1 hour from now
      ban_until = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = Account.ban(account.id, ban_until)

      # Reload account from DB
      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == true
    end

    test "unbanning an account persists", %{account: account} do
      ban_until = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = Account.ban(account.id, ban_until)
      {:ok, _} = Account.unban(account.id)

      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == false
    end

    test "expired ban is not considered banned", %{account: account} do
      # Ban until 1 second ago (already expired)
      ban_until = DateTime.add(DateTime.utc_now(), -1, :second)
      {:ok, _} = Account.ban(account.id, ban_until)

      reloaded = Repo.get(Account, account.id)
      assert Account.banned?(reloaded) == false
    end
  end

  # ---- Mute persists ----

  describe "mute persists" do
    test "setting muted_until on character survives reload", %{account: account} do
      char = create_character(account)

      # Set muted_until to a future monotonic-style timestamp
      mute_expiry = System.os_time(:second) + 3600

      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: mute_expiry})

      reloaded = Characters.get(char.id)
      assert reloaded.muted_until == mute_expiry
    end

    test "muted_until converts correctly to entity and back", %{account: account} do
      char = create_character(account)
      mute_expiry = 9_999_999

      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: mute_expiry})

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)
      assert entity.muted_until == mute_expiry

      attrs = Characters.from_entity(entity)
      assert attrs.muted_until == mute_expiry
    end

    test "zero muted_until means not muted", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: 0})

      reloaded = Characters.get(char.id)
      assert reloaded.muted_until == 0

      entity = Characters.to_entity(reloaded)
      assert entity.muted_until == 0
    end
  end

  # ---- Guild survives server restart ----
  #
  # GuildServer.init/1 loads guilds from DB via Guilds.list_all() and
  # relations via Guilds.list_relations(). We cannot cleanly restart the
  # named GuildServer under its supervisor in a sandbox test, so we verify
  # that the DB-level load functions return correct data after writes --
  # this is exactly what init relies on.

  describe "guild survives server restart (DB load path)" do
    test "list_all returns guilds with members after creation", %{account: account} do
      leader = create_character(account, "_leader")
      member = create_character(account, "_member")

      {:ok, db_guild} = Guilds.create_guild(leader.id, "RestartClan")
      {:ok, _} = Guilds.add_member(db_guild.id, member.id)

      # Simulate what GuildServer.init does: load all guilds from DB
      all_guilds = Guilds.list_all()
      guild = Enum.find(all_guilds, &(&1.id == db_guild.id))

      assert guild != nil
      assert guild.name == "RestartClan"
      assert guild.leader_id == leader.id

      member_ids = Enum.map(guild.members, & &1.char_id)
      assert leader.id in member_ids
      assert member.id in member_ids
    end

    test "list_relations returns relations after creation", %{account: account} do
      leader_a = create_character(account, "_a")
      leader_b = create_character(account, "_b")

      {:ok, guild_a} = Guilds.create_guild(leader_a.id, "RestartWarA")
      {:ok, guild_b} = Guilds.create_guild(leader_b.id, "RestartWarB")
      {:ok, _} = Guilds.set_relation(guild_a.id, guild_b.id, "war")

      # Simulate what GuildServer.init does: load all relations
      relations = Guilds.list_relations()
      {a, b} = if guild_a.id <= guild_b.id, do: {guild_a.id, guild_b.id}, else: {guild_b.id, guild_a.id}

      war = Enum.find(relations, fn r -> r.guild_a_id == a and r.guild_b_id == b end)
      assert war != nil
      assert war.relation_type == "war"
    end
  end

  # ---- Guild update fields persist ----

  describe "guild update fields persist" do
    test "updating level and current_exp persists", %{account: account} do
      leader = create_character(account, "_leader")
      {:ok, db_guild} = Guilds.create_guild(leader.id, "LevelClan")

      {:ok, updated} = Guilds.update_guild(db_guild.id, %{level: 3, current_exp: 2500})
      assert updated.level == 3
      assert updated.current_exp == 2500

      # Reload fresh from DB
      reloaded = Repo.get(GameBackend.Guild, db_guild.id)
      assert reloaded.level == 3
      assert reloaded.current_exp == 2500
    end

    test "updating news persists", %{account: account} do
      leader = create_character(account, "_leader")
      {:ok, db_guild} = Guilds.create_guild(leader.id, "NewsClan")

      {:ok, _} = Guilds.update_guild(db_guild.id, %{news: "Guild meeting at 9pm!"})

      reloaded = Repo.get(GameBackend.Guild, db_guild.id)
      assert reloaded.news == "Guild meeting at 9pm!"
    end

    test "updating description persists", %{account: account} do
      leader = create_character(account, "_leader")
      {:ok, db_guild} = Guilds.create_guild(leader.id, "DescClan")

      {:ok, _} = Guilds.update_guild(db_guild.id, %{description: "We are the best clan"})

      reloaded = Repo.get(GameBackend.Guild, db_guild.id)
      assert reloaded.description == "We are the best clan"
    end

    test "updating url persists", %{account: account} do
      leader = create_character(account, "_leader")
      {:ok, db_guild} = Guilds.create_guild(leader.id, "UrlClan")

      {:ok, _} = Guilds.update_guild(db_guild.id, %{url: "https://example.com"})

      reloaded = Repo.get(GameBackend.Guild, db_guild.id)
      assert reloaded.url == "https://example.com"
    end

    test "updating alignment persists", %{account: account} do
      leader = create_character(account, "_leader")
      {:ok, db_guild} = Guilds.create_guild(leader.id, "AlignClan", 0)

      {:ok, _} = Guilds.update_guild(db_guild.id, %{alignment: 2})

      reloaded = Repo.get(GameBackend.Guild, db_guild.id)
      assert reloaded.alignment == 2
    end
  end

  # ---- Guild leader succession persists ----

  describe "guild leader succession persists" do
    test "changing leader_id via update_guild persists", %{account: account} do
      leader = create_character(account, "_leader")
      member = create_character(account, "_member")

      {:ok, db_guild} = Guilds.create_guild(leader.id, "SuccClan")
      {:ok, _} = Guilds.add_member(db_guild.id, member.id)

      # Simulate what GuildServer.do_leave does: update leader_id
      {:ok, _} = Guilds.update_guild(db_guild.id, %{leader_id: member.id})

      # Verify the change persists
      reloaded = Repo.get(GameBackend.Guild, db_guild.id)
      assert reloaded.leader_id == member.id
    end

    test "leader leaves, member removed, guild dissolved via delete_guild", %{account: account} do
      leader = create_character(account, "_leader")

      {:ok, db_guild} = Guilds.create_guild(leader.id, "DissolveClan")

      # Simulate what GuildServer.do_leave does when last member leaves:
      # remove member, then delete guild
      Guilds.remove_member(db_guild.id, leader.id)
      Guilds.delete_guild(db_guild.id)

      # Verify guild is gone
      assert Repo.get(GameBackend.Guild, db_guild.id) == nil
      assert Guilds.get_guild_by_char(leader.id) == nil
    end
  end

  # ---- Relation type change persists ----

  describe "relation type change persists" do
    test "changing war to alliance updates the existing row", %{account: account} do
      leader_a = create_character(account, "_a")
      leader_b = create_character(account, "_b")

      {:ok, guild_a} = Guilds.create_guild(leader_a.id, "FlipRelA")
      {:ok, guild_b} = Guilds.create_guild(leader_b.id, "FlipRelB")

      {:ok, rel_war} = Guilds.set_relation(guild_a.id, guild_b.id, "war")
      {:ok, rel_alliance} = Guilds.set_relation(guild_a.id, guild_b.id, "alliance")

      # Same row, updated type
      assert rel_war.id == rel_alliance.id
      assert rel_alliance.relation_type == "alliance"

      # Verify from DB reload
      relations = Guilds.list_relations()
      {a, b} = if guild_a.id <= guild_b.id, do: {guild_a.id, guild_b.id}, else: {guild_b.id, guild_a.id}

      rel = Enum.find(relations, fn r -> r.guild_a_id == a and r.guild_b_id == b end)
      assert rel.relation_type == "alliance"
    end
  end

  # ---- Faction score and rank persist ----

  describe "faction score and rank persist" do
    test "faction kill counters survive snapshot", %{account: account} do
      char = create_character(account)

      {:ok, _} =
        Characters.save_snapshot(char.id, %{
          faction: "armada",
          faction_kills_royal: 5,
          faction_kills_chaos: 10,
          citizens_killed: 2,
          criminals_killed: 7,
          faction_score: 150,
          faction_rank_armada: 3,
          faction_rank_chaos: 0,
          faction_reenlistadas: 1
        })

      reloaded = Characters.get(char.id)
      assert reloaded.faction == "armada"
      assert reloaded.faction_kills_royal == 5
      assert reloaded.faction_kills_chaos == 10
      assert reloaded.citizens_killed == 2
      assert reloaded.criminals_killed == 7
      assert reloaded.faction_score == 150
      assert reloaded.faction_rank_armada == 3
      assert reloaded.faction_rank_chaos == 0
      assert reloaded.faction_reenlistadas == 1
    end

    test "faction counters round-trip through entity conversion", %{account: account} do
      char = create_character(account)

      {:ok, _} =
        Characters.save_snapshot(char.id, %{
          faction: "chaos",
          faction_score: 200,
          faction_rank_chaos: 2
        })

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)

      assert entity.faction == :chaos
      assert entity.faction_score == 200
      assert entity.faction_rank_chaos == 2

      attrs = Characters.from_entity(entity)
      assert attrs.faction == "chaos"
      assert attrs.faction_score == 200
      assert attrs.faction_rank_chaos == 2
    end
  end

  # ---- Ban checked on login ----

  describe "ban check on login simulation" do
    test "banned account is rejected by banned? check", %{account: account} do
      ban_until = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = Account.ban(account.id, ban_until)

      # Simulate what login does: load account, check banned?
      loaded = Repo.get(GameBackend.Account, account.id)
      assert Account.banned?(loaded) == true
    end

    test "non-banned account passes banned? check", %{account: account} do
      loaded = Repo.get(GameBackend.Account, account.id)
      assert Account.banned?(loaded) == false
    end
  end

  # ---- Mute blocks chat simulation ----

  describe "mute blocks chat simulation" do
    test "active mute is detected by comparing muted_until to current time", %{account: account} do
      char = create_character(account)

      future_ts = System.os_time(:second) + 3600
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: future_ts})

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)

      # The chat handler should check: entity.muted_until > System.os_time(:second)
      assert entity.muted_until > System.os_time(:second)
    end

    test "expired mute does not block chat", %{account: account} do
      char = create_character(account)

      past_ts = System.os_time(:second) - 3600
      {:ok, _} = Characters.save_snapshot(char.id, %{muted_until: past_ts})

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)

      # Expired mute: muted_until is in the past
      assert entity.muted_until < System.os_time(:second)
    end
  end

  # ---- Guild with no members cleanup ----

  describe "guild with no members cleanup" do
    test "deleting all members then the guild leaves no orphan rows", %{account: account} do
      leader = create_character(account, "_leader")
      member = create_character(account, "_member")

      {:ok, db_guild} = Guilds.create_guild(leader.id, "CleanupClan")
      {:ok, _} = Guilds.add_member(db_guild.id, member.id)

      # Remove all members
      Guilds.remove_member(db_guild.id, member.id)
      Guilds.remove_member(db_guild.id, leader.id)

      # Delete the now-empty guild
      Guilds.delete_guild(db_guild.id)

      # Verify no traces remain
      assert Repo.get(GameBackend.Guild, db_guild.id) == nil
      assert Guilds.get_guild_by_char(leader.id) == nil
      assert Guilds.get_guild_by_char(member.id) == nil
    end

    test "delete_guild cascades member removal", %{account: account} do
      leader = create_character(account, "_leader")
      member = create_character(account, "_member")

      {:ok, db_guild} = Guilds.create_guild(leader.id, "CascadeClan")
      {:ok, _} = Guilds.add_member(db_guild.id, member.id)

      # delete_guild removes members first, then the guild
      {:ok, _} = Guilds.delete_guild(db_guild.id)

      # Both members are no longer associated
      assert Guilds.get_guild_by_char(leader.id) == nil
      assert Guilds.get_guild_by_char(member.id) == nil
    end
  end

  # ---- Guild creation with alignment ----

  describe "guild creation with alignment" do
    test "alignment is persisted on creation", %{account: account} do
      char = create_character(account)

      {:ok, db_guild} = Guilds.create_guild(char.id, "ArmadaClan", 1)

      reloaded = Repo.get(GameBackend.Guild, db_guild.id)
      assert reloaded.alignment == 1
    end

    test "guild created with alignment loads correctly via list_all", %{account: account} do
      char = create_character(account)

      {:ok, db_guild} = Guilds.create_guild(char.id, "ChaosClan", 2)

      all_guilds = Guilds.list_all()
      guild = Enum.find(all_guilds, &(&1.id == db_guild.id))

      assert guild != nil
      assert guild.alignment == 2
    end
  end
end
