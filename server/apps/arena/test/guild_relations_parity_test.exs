defmodule Arena.GuildRelationsParityTest do
  @moduledoc """
  Tests for guild relation logic: war declaration, peace proposals, alliance
  proposals, relation queries, and idempotency guards.

  Uses synthetic guild IDs in ETS (no DB backing) to isolate the GuildServer
  GenServer logic. DB persistence failures are expected and acceptable here;
  what matters is the ETS state and reply contract.

  Roadmap item #11: Fix remaining guild relation stubs.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arena.GuildServer

  @table :ao_guilds

  @guild_a_id 90_001
  @guild_b_id 90_002
  @guild_c_id 90_003
  @leader_a 80_001
  @leader_b 80_002
  @leader_c 80_003
  @member_a 80_010

  setup do
    case GuildServer.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ets.delete_all_objects(@table)

    guild_a = %{
      id: @guild_a_id,
      name: "AlphaGuild",
      leader: @leader_a,
      founder_id: @leader_a,
      created_at: ~N[2025-01-01 00:00:00],
      members: [@leader_a, @member_a],
      level: 1,
      current_exp: 0,
      description: "",
      news: "",
      url: "",
      alignment: 0
    }

    guild_b = %{
      id: @guild_b_id,
      name: "BravoGuild",
      leader: @leader_b,
      founder_id: @leader_b,
      created_at: ~N[2025-01-01 00:00:00],
      members: [@leader_b],
      level: 1,
      current_exp: 0,
      description: "",
      news: "",
      url: "",
      alignment: 0
    }

    guild_c = %{
      id: @guild_c_id,
      name: "CharlieGuild",
      leader: @leader_c,
      founder_id: @leader_c,
      created_at: ~N[2025-01-01 00:00:00],
      members: [@leader_c],
      level: 1,
      current_exp: 0,
      description: "",
      news: "",
      url: "",
      alignment: 0
    }

    :ets.insert(@table, {{:guild, @guild_a_id}, guild_a})
    :ets.insert(@table, {{:member, @leader_a}, @guild_a_id})
    :ets.insert(@table, {{:member, @member_a}, @guild_a_id})

    :ets.insert(@table, {{:guild, @guild_b_id}, guild_b})
    :ets.insert(@table, {{:member, @leader_b}, @guild_b_id})

    :ets.insert(@table, {{:guild, @guild_c_id}, guild_c})
    :ets.insert(@table, {{:member, @leader_c}, @guild_c_id})

    :ok
  end

  # ---- Helper ----

  defp set_war_in_ets(ga, gb) do
    {a, b} = if ga <= gb, do: {ga, gb}, else: {gb, ga}
    :ets.insert(@table, {{:relation, a, b}, "war"})
  end

  defp set_alliance_in_ets(ga, gb) do
    {a, b} = if ga <= gb, do: {ga, gb}, else: {gb, ga}
    :ets.insert(@table, {{:relation, a, b}, "alliance"})
  end

  # ===========================================================
  # 1. War declaration idempotency: re-declaring war when already
  #    at war should return :already_at_war (not re-broadcast).
  # ===========================================================

  describe "declare_war idempotency" do
    test "re-declaring war when already at war returns :already_at_war" do
      set_war_in_ets(@guild_a_id, @guild_b_id)

      capture_log(fn ->
        result = GuildServer.declare_war(@leader_a, "BravoGuild")
        assert result == {:error, :already_at_war}
      end)

      # Relation should still be war
      assert GuildServer.at_war?(@guild_a_id, @guild_b_id)
    end
  end

  # ===========================================================
  # 2. Propose peace: leader removes war relation.
  #    The GuildServer backend is implemented but the session
  #    command text handler is stubbed. We test the GenServer
  #    directly here.
  # ===========================================================

  describe "propose_peace" do
    test "proposing peace when at war removes the war relation from ETS" do
      set_war_in_ets(@guild_a_id, @guild_b_id)
      assert GuildServer.at_war?(@guild_a_id, @guild_b_id)

      capture_log(fn ->
        result = GuildServer.propose_peace(@leader_a, "BravoGuild")
        # DB persist may fail (synthetic IDs) but ETS should be updated
        # since persist_relation(:delete) rescues and returns :ok
        assert result == :ok
      end)

      refute GuildServer.at_war?(@guild_a_id, @guild_b_id)
      assert GuildServer.get_relation(@guild_a_id, @guild_b_id) == "peace"
    end

    test "proposing peace when NOT at war returns :not_at_war" do
      capture_log(fn ->
        assert {:error, :not_at_war} == GuildServer.propose_peace(@leader_a, "BravoGuild")
      end)
    end
  end

  # ===========================================================
  # 3. Alliance proposal idempotency and war conflict check.
  # ===========================================================

  describe "propose_alliance" do
    test "proposing alliance when already allied returns :already_allied" do
      set_alliance_in_ets(@guild_a_id, @guild_b_id)

      capture_log(fn ->
        result = GuildServer.propose_alliance(@leader_a, "BravoGuild")
        assert result == {:error, :already_allied}
      end)

      # Relation should still be alliance
      assert GuildServer.get_relation(@guild_a_id, @guild_b_id) == "alliance"
    end

    test "proposing alliance when at war returns :at_war" do
      set_war_in_ets(@guild_a_id, @guild_b_id)

      capture_log(fn ->
        result = GuildServer.propose_alliance(@leader_a, "BravoGuild")
        assert result == {:error, :at_war}
      end)

      # War should remain
      assert GuildServer.at_war?(@guild_a_id, @guild_b_id)
    end
  end

  # ===========================================================
  # 4. ETS relation reads: at_war?, get_relation, players_at_war?
  # ===========================================================

  describe "ETS relation reads" do
    test "at_war? returns true for guilds at war" do
      set_war_in_ets(@guild_a_id, @guild_b_id)
      assert GuildServer.at_war?(@guild_a_id, @guild_b_id)
      # Symmetric
      assert GuildServer.at_war?(@guild_b_id, @guild_a_id)
    end

    test "at_war? returns false for guilds not at war" do
      refute GuildServer.at_war?(@guild_a_id, @guild_b_id)
    end

    test "at_war? returns false for non-integer args" do
      refute GuildServer.at_war?(nil, nil)
      refute GuildServer.at_war?(nil, @guild_b_id)
    end

    test "get_relation returns 'war' for war" do
      set_war_in_ets(@guild_a_id, @guild_b_id)
      assert GuildServer.get_relation(@guild_a_id, @guild_b_id) == "war"
    end

    test "get_relation returns 'alliance' for alliance" do
      set_alliance_in_ets(@guild_a_id, @guild_b_id)
      assert GuildServer.get_relation(@guild_a_id, @guild_b_id) == "alliance"
    end

    test "get_relation returns 'peace' (default) when no relation set" do
      assert GuildServer.get_relation(@guild_a_id, @guild_b_id) == "peace"
    end

    test "players_at_war? returns true when players' guilds are at war" do
      set_war_in_ets(@guild_a_id, @guild_b_id)
      assert GuildServer.players_at_war?(@leader_a, @leader_b)
      # Also works for member
      assert GuildServer.players_at_war?(@member_a, @leader_b)
    end

    test "players_at_war? returns false for same-guild members" do
      refute GuildServer.players_at_war?(@leader_a, @member_a)
    end

    test "players_at_war? returns false when one player has no guild" do
      refute GuildServer.players_at_war?(@leader_a, 99999)
    end
  end

  # ===========================================================
  # 5. Session text commands: /PROPONERPAZ and /ALIANZA should
  #    be wired through to GuildServer, not return disabled message.
  # ===========================================================

  describe "session text command: /PROPONERPAZ (guild_peace)" do
    test "calls GuildServer.propose_peace instead of returning disabled" do
      set_war_in_ets(@guild_a_id, @guild_b_id)

      state = %{
        character_id: @leader_a,
        map_id: 1,
        account_id: "test_acct",
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        in_commerce: false,
        in_bank: false,
        in_trade: false,
        is_gm: false,
        is_dead: false,
        hogar_timer_ref: nil
      }

      capture_log(fn ->
        {_state, packets} =
          AoTcpGateway.SessionCommands.Guild.handle_talk_guild(state, {:guild_peace, "BravoGuild"})

        # The handler should return an empty packet list (it delegates to
        # GuildServer.propose_peace which communicates via notify/broadcast).
        # Critically, it must NOT return the "disabled" message.
        disabled_msg = "Relaciones de clan desactivadas por el momento."

        has_disabled =
          Enum.any?(packets, fn
            {:send_raw, raw} when is_binary(raw) -> String.contains?(raw, disabled_msg)
            _ -> false
          end)

        refute has_disabled,
          "handle_talk_guild for :guild_peace should call GuildServer.propose_peace, not return disabled"

        assert packets == [],
          "handle_talk_guild for :guild_peace should return empty packets (delegates to GuildServer)"
      end)
    end
  end

  describe "session text command: /ALIANZA (guild_alliance)" do
    test "calls GuildServer.propose_alliance instead of returning disabled" do
      state = %{
        character_id: @leader_a,
        map_id: 1,
        account_id: "test_acct",
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        in_commerce: false,
        in_bank: false,
        in_trade: false,
        is_gm: false,
        is_dead: false,
        hogar_timer_ref: nil
      }

      capture_log(fn ->
        {_state, packets} =
          AoTcpGateway.SessionCommands.Guild.handle_talk_guild(state, {:guild_alliance, "BravoGuild"})

        # Should NOT return the "disabled" message
        disabled_msg = "Relaciones de clan desactivadas por el momento."

        has_disabled =
          Enum.any?(packets, fn
            {:send_raw, raw} when is_binary(raw) -> String.contains?(raw, disabled_msg)
            _ -> false
          end)

        refute has_disabled,
          "handle_talk_guild for :guild_alliance should call GuildServer.propose_alliance, not return disabled"

        assert packets == [],
          "handle_talk_guild for :guild_alliance should return empty packets (delegates to GuildServer)"
      end)
    end
  end

  # ===========================================================
  # 6. Non-leader cannot declare war, propose peace, or propose alliance.
  # ===========================================================

  describe "non-leader authority checks" do
    test "non-leader cannot declare war" do
      capture_log(fn ->
        result = GuildServer.declare_war(@member_a, "BravoGuild")
        assert result == {:error, :not_leader}
      end)
    end

    test "non-leader cannot propose peace" do
      set_war_in_ets(@guild_a_id, @guild_b_id)

      capture_log(fn ->
        result = GuildServer.propose_peace(@member_a, "BravoGuild")
        assert result == {:error, :not_leader}
      end)

      # War should still be active
      assert GuildServer.at_war?(@guild_a_id, @guild_b_id)
    end

    test "non-leader cannot propose alliance" do
      capture_log(fn ->
        result = GuildServer.propose_alliance(@member_a, "BravoGuild")
        assert result == {:error, :not_leader}
      end)
    end
  end

  # ===========================================================
  # 7. Cannot declare war / propose alliance on own guild.
  # ===========================================================

  describe "self-targeting guards" do
    test "cannot declare war on own guild" do
      capture_log(fn ->
        result = GuildServer.declare_war(@leader_a, "AlphaGuild")
        assert result == {:error, :same_guild}
      end)
    end

    test "cannot propose alliance with own guild" do
      capture_log(fn ->
        result = GuildServer.propose_alliance(@leader_a, "AlphaGuild")
        assert result == {:error, :same_guild}
      end)
    end
  end

  # ===========================================================
  # 8. Target guild not found.
  # ===========================================================

  describe "target not found" do
    test "declare_war returns :not_found for unknown guild" do
      capture_log(fn ->
        result = GuildServer.declare_war(@leader_a, "NonexistentGuild")
        assert result == {:error, :not_found}
      end)
    end

    test "propose_peace returns :not_found for unknown guild" do
      capture_log(fn ->
        result = GuildServer.propose_peace(@leader_a, "NonexistentGuild")
        assert result == {:error, :not_found}
      end)
    end

    test "propose_alliance returns :not_found for unknown guild" do
      capture_log(fn ->
        result = GuildServer.propose_alliance(@leader_a, "NonexistentGuild")
        assert result == {:error, :not_found}
      end)
    end
  end
end
