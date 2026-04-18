defmodule Arena.GuildAuthorityDbBackedTest do
  @moduledoc """
  DB-backed guild authority coverage.

  These tests use persisted guild, character, and request rows to exercise
  authority decisions in GuildServer against real database state, while
  keeping ETS aligned with the loaded DB rows.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AoSession.OnlineDirectory
  alias Arena.GuildServer
  alias Ecto.Adapters.SQL.Sandbox
  alias GameBackend.{Account, Characters, Guild, Guilds, Repo}

  @guild_table :ao_guilds
  @online_table :ao_online_directory

  setup do
    owner_pid = Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      if Process.alive?(owner_pid) do
        Sandbox.stop_owner(owner_pid)
      end
    end)

    ensure_started!(OnlineDirectory)
    ensure_started!(GuildServer)
    clear_tables()

    {:ok, account} =
      Account.create(
        "guild_db_#{System.unique_integer([:positive])}",
        "password123"
      )

    %{owner_pid: owner_pid, account: account}
  end

  describe "accept_invite with persisted guild rows" do
    test "rejects an invite after the inviter loses leadership", %{account: account} do
      inviter = create_character(account, "inviter")
      successor = create_character(account, "successor")
      target = create_character(account, "target")

      {:ok, guild} = Guilds.create_guild(inviter.id, "LeadShiftClan")
      {:ok, _} = Guilds.add_member(guild.id, successor.id)
      {:ok, _} = Guilds.update_guild(guild.id, %{leader_id: successor.id})
      seed_guild_ets_from_db!(guild.id)
      put_invite(target.id, guild.id, inviter.id)

      assert {:error, :invite_invalid} == GuildServer.accept_invite(target.id)
      assert :ets.lookup(@guild_table, {:invite, target.id}) == []
    end

    test "rejects an invite after the inviter leaves the guild", %{account: account} do
      inviter = create_character(account, "inviter_leave")
      successor = create_character(account, "successor_leave")
      target = create_character(account, "target_leave")

      {:ok, guild} = Guilds.create_guild(inviter.id, "LeaveClan")
      {:ok, _} = Guilds.add_member(guild.id, successor.id)
      {:ok, _} = Guilds.remove_member_and_set_leader(guild.id, inviter.id, successor.id)
      seed_guild_ets_from_db!(guild.id)
      put_invite(target.id, guild.id, inviter.id)

      assert {:error, :invite_invalid} == GuildServer.accept_invite(target.id)
      assert :ets.lookup(@guild_table, {:invite, target.id}) == []
      assert Guilds.get_guild_by_char(inviter.id) == nil
    end

    test "rejects an invite after the guild is deleted", %{account: account} do
      inviter = create_character(account, "inviter_deleted")
      target = create_character(account, "target_deleted")

      {:ok, guild} = Guilds.create_guild(inviter.id, "DeleteClan")
      seed_guild_ets_from_db!(guild.id)
      put_invite(target.id, guild.id, inviter.id)

      {:ok, _deleted_guild} = Guilds.delete_guild(guild.id)
      clear_guild_ets(guild.id)

      assert {:error, :guild_gone} == GuildServer.accept_invite(target.id)
      assert :ets.lookup(@guild_table, {:invite, target.id}) == []
    end

    test "rejects an expired invite without waiting for cleanup", %{account: account} do
      inviter = create_character(account, "inviter_expired")
      target = create_character(account, "target_expired")

      {:ok, guild} = Guilds.create_guild(inviter.id, "ExpireClan")
      seed_guild_ets_from_db!(guild.id)
      put_invite(target.id, guild.id, inviter.id, System.monotonic_time(:millisecond) - 10_000)

      assert {:error, :invite_invalid} == GuildServer.accept_invite(target.id)
      assert :ets.lookup(@guild_table, {:invite, target.id}) == []
    end

    test "keeps the invite when add_member fails on a persisted unique constraint", %{account: account} do
      inviter = create_character(account, "inviter_dbfail")
      target = create_character(account, "target_dbfail")

      {:ok, guild_a} = Guilds.create_guild(inviter.id, "InviteFailureClan")
      {:ok, guild_b} = Guilds.create_guild(target.id, "TargetAlreadyInClan")
      seed_guild_ets_from_db!(guild_a.id)
      put_invite(target.id, guild_a.id, inviter.id)
      assert Guilds.get_guild_by_char(target.id).id == guild_b.id

      log =
        capture_log(fn ->
          assert {:error, :db_error} == GuildServer.accept_invite(target.id)
        end)

      assert log =~ "Failed to persist guild join"
      assert :ets.lookup(@guild_table, {:invite, target.id}) != []
      assert Guilds.get_guild_by_char(target.id).id == guild_b.id
      assert Guilds.get_guild_by_char(inviter.id).id == guild_a.id
    end
  end

  describe "accept_request with persisted guild rows" do
    test "rejects accept_request when no DB request exists", %{account: account} do
      leader = create_character(account, "leader_no_req")
      target = create_character(account, "target_no_req")

      {:ok, guild} = Guilds.create_guild(leader.id, "NoRequestClan")
      seed_guild_ets_from_db!(guild.id)
      register_online(target)

      assert {:error, :no_request} == GuildServer.accept_request(leader.id, target.name)
      assert Guilds.get_guild_by_char(target.id) == nil
    end

    test "keeps the request when add_member fails on a persisted unique constraint", %{account: account} do
      leader = create_character(account, "leader_req_fail")
      target = create_character(account, "target_req_fail")

      {:ok, guild_a} = Guilds.create_guild(leader.id, "RequestFailureClan")
      {:ok, guild_b} = Guilds.create_guild(target.id, "TargetAlreadyRequestedClan")
      {:ok, _request} = Guilds.create_request(guild_a.id, target.id, "let me in")
      seed_guild_ets_from_db!(guild_a.id)
      register_online(target)

      assert Guilds.request_exists?(guild_a.id, target.id)
      assert Guilds.get_guild_by_char(target.id).id == guild_b.id

      assert {:error, :db_error} == GuildServer.accept_request(leader.id, target.name)

      assert Guilds.request_exists?(guild_a.id, target.id)
      assert Guilds.get_guild_by_char(target.id).id == guild_b.id
      assert Guilds.get_guild_by_char(leader.id).id == guild_a.id
    end

    test "returns db_error when request_exists? cannot reach the database", %{account: account, owner_pid: owner_pid} do
      leader = create_character(account, "leader_req_query")
      target = create_character(account, "target_req_query")

      {:ok, guild} = Guilds.create_guild(leader.id, "RequestQueryClan")
      seed_guild_ets_from_db!(guild.id)
      register_online(target)

      Sandbox.stop_owner(owner_pid)

      log =
        capture_log(fn ->
          assert {:error, :db_error} == GuildServer.accept_request(leader.id, target.name)
        end)

      assert log =~ "Guild request_exists? raised"
    end

    test "returns db_error when list_requests cannot reach the database", %{account: account, owner_pid: owner_pid} do
      leader = create_character(account, "leader_list_query")
      requester = create_character(account, "requester_list_query")

      {:ok, guild} = Guilds.create_guild(leader.id, "ListQueryClan")
      {:ok, _request} = Guilds.create_request(guild.id, requester.id, "please")
      seed_guild_ets_from_db!(guild.id)
      register_online(leader)

      Sandbox.stop_owner(owner_pid)

      log =
        capture_log(fn ->
          assert {:error, :db_error} == GuildServer.list_requests(leader.id)
        end)

      assert log =~ "Guild list_requests raised"
    end
  end

  describe "request_membership with persisted guild rows" do
    test "returns not_found when the guild row disappears before request creation", %{account: account} do
      leader = create_character(account, "leader_request_member")
      applicant = create_character(account, "applicant_request_member")

      {:ok, guild} = Guilds.create_guild(leader.id, "RequestClan")
      seed_guild_ets_from_db!(guild.id)
      {:ok, _deleted_guild} = Guilds.delete_guild(guild.id)

      clear_guild_ets(guild.id)

      assert {:error, :not_found} == GuildServer.request_membership(applicant.id, guild.name, "please let me in")
      assert Guilds.get_guild_by_char(applicant.id) == nil
    end
  end

  defp ensure_started!(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _ -> :ok
    end
  end

  defp clear_tables do
    clear_table(@guild_table)
    clear_table(@online_table)
  end

  defp clear_table(table) do
    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end
  end

  defp clear_guild_ets(guild_id) do
    case :ets.lookup(@guild_table, {:guild, guild_id}) do
      [{_, guild}] ->
        Enum.each(guild.members, fn mid ->
          :ets.delete(@guild_table, {:member, mid})
        end)

      [] ->
        :ok
    end

    :ets.delete(@guild_table, {:guild, guild_id})
  end

  defp seed_guild_ets_from_db!(guild_id) do
    case Repo.get(Guild, guild_id) do
      nil ->
        clear_guild_ets(guild_id)
        nil

      db_guild ->
        db_guild = Repo.preload(db_guild, :members)
        clear_guild_ets(guild_id)

        member_ids = Enum.map(db_guild.members, & &1.char_id)

        guild = %{
          id: db_guild.id,
          name: db_guild.name,
          leader: db_guild.leader_id,
          founder_id: db_guild.founder_id || db_guild.leader_id,
          created_at: db_guild.inserted_at,
          members: member_ids,
          level: db_guild.level || 1,
          current_exp: db_guild.current_exp || 0,
          description: db_guild.description || "",
          news: db_guild.news || "",
          url: db_guild.url || "",
          alignment: db_guild.alignment || 0
        }

        :ets.insert(@guild_table, {{:guild, db_guild.id}, guild})

        Enum.each(member_ids, fn mid ->
          :ets.insert(@guild_table, {{:member, mid}, db_guild.id})
        end)

        guild
    end
  end

  defp create_character(account, name_prefix) do
    name = "#{name_prefix}_#{System.unique_integer([:positive])}"

    {:ok, character} =
      Characters.create(%{
        name: name,
        account_id: account.id
      })

    character
  end

  defp register_online(character, map_id \\ 1) do
    :ok = OnlineDirectory.register(character.id, character.name, map_id, self())
  end

  defp put_invite(target_id, guild_id, from_id, expires_at \\ System.monotonic_time(:millisecond) + 60_000) do
    :ets.insert(
      @guild_table,
      {{:invite, target_id}, %{guild_id: guild_id, from: from_id, expires_at: expires_at}}
    )
  end
end
