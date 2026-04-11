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
end
