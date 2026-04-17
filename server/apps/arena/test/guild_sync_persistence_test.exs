defmodule Arena.GuildSyncPersistenceTest do
  @moduledoc """
  Tests that guild persistence is synchronous and that DB failures
  do not crash the GuildServer or corrupt ETS state.

  Uses synthetic guild IDs in ETS that have no DB backing, so all
  persist_guild_update / persist_relation calls will fail — verifying
  that the GenServer survives and ETS remains consistent.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arena.GuildServer

  @table :ao_guilds

  # Synthetic IDs with no DB backing — DB writes will fail
  @guild_id 80_001
  @guild2_id 80_002
  @leader_id 70_001
  @member_id 70_002
  @leader2_id 70_003

  setup do
    case GuildServer.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ets.delete_all_objects(@table)

    guild = %{
      id: @guild_id,
      name: "SyncTestGuild",
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

    guild2 = %{
      id: @guild2_id,
      name: "SyncRivalGuild",
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

  describe "set_news with DB failure" do
    test "ETS is updated and GenServer survives when persist fails" do
      log =
        capture_log(fn ->
          assert :ok == GuildServer.set_guild_news(@leader_id, "New guild news!")
        end)

      # ETS should have the updated news despite DB failure
      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert guild.news == "New guild news!"

      # DB failure should be logged
      assert log =~ "Guild DB update failed"

      # GenServer should still be alive and responsive
      assert Process.whereis(GuildServer) != nil
      {:ok, info, _} = GuildServer.guild_info(@leader_id)
      assert info.news == "New guild news!"
    end
  end

  describe "set_description with DB failure" do
    test "ETS is updated and GenServer survives when persist fails" do
      log =
        capture_log(fn ->
          assert :ok == GuildServer.set_guild_description(@leader_id, "A test description")
        end)

      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert guild.description == "A test description"
      assert log =~ "Guild DB update failed"

      # Still alive
      assert :ok == GuildServer.set_guild_description(@leader_id, "Second update")
      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert guild.description == "Second update"
    end
  end

  describe "set_website with DB failure" do
    test "ETS is updated and GenServer survives when persist fails" do
      log =
        capture_log(fn ->
          assert :ok == GuildServer.update_website(@leader_id, "https://example.com")
        end)

      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert guild.url == "https://example.com"
      assert log =~ "Guild DB update failed"
    end
  end

  describe "declare_war with DB failure" do
    test "ETS relation is set and GenServer survives when persist fails" do
      log =
        capture_log(fn ->
          assert :ok == GuildServer.declare_war(@leader_id, "SyncRivalGuild")
        end)

      # ETS should have the war relation
      {a, b} = if @guild_id <= @guild2_id, do: {@guild_id, @guild2_id}, else: {@guild2_id, @guild_id}
      assert [{_, "war"}] = :ets.lookup(@table, {:relation, a, b})

      assert log =~ "Guild relation set failed"

      # GenServer still alive
      assert Process.whereis(GuildServer) != nil
    end
  end

  describe "multiple DB failures in sequence" do
    test "GenServer handles repeated failures without crashing" do
      log =
        capture_log(fn ->
          assert :ok == GuildServer.set_guild_news(@leader_id, "News 1")
          assert :ok == GuildServer.set_guild_news(@leader_id, "News 2")
          assert :ok == GuildServer.set_guild_description(@leader_id, "Desc 1")
          assert :ok == GuildServer.update_website(@leader_id, "https://site.com")
        end)

      [{_, guild}] = :ets.lookup(@table, {:guild, @guild_id})
      assert guild.news == "News 2"
      assert guild.description == "Desc 1"
      assert guild.url == "https://site.com"

      # Multiple failure logs
      assert length(Regex.scan(~r/Guild DB update failed/, log)) >= 4
    end
  end
end
