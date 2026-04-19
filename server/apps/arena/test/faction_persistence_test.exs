defmodule Arena.FactionPersistenceTest do
  @moduledoc """
  Persistence tests for faction state across save/load cycles.

  Covers faction membership, score, rank, kill counters,
  re-enlistment counter, leaving faction, and entity round-trips.

  Uses direct Ecto/context calls against a sandboxed Postgres connection.
  No TCP connections required.
  """

  use ExUnit.Case, async: false

  alias GameBackend.Characters
  alias GameBackend.Account

  setup do
    owner_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GameBackend.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid) end)

    {:ok, account} = Account.create("factionuser_#{System.unique_integer([:positive])}", "password123")

    %{account: account}
  end

  defp create_character(account, name_suffix \\ "") do
    name = "FacChar#{System.unique_integer([:positive])}#{name_suffix}"

    {:ok, char} =
      Characters.create(%{
        name: name,
        account_id: account.id
      })

    char
  end

  # ---- Faction membership persists across save/load ----

  describe "faction membership persists across save/load" do
    test "armada faction saved by save_snapshot and loaded by get + to_entity", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "armada"})

      reloaded = Characters.get(char.id)
      assert reloaded.faction == "armada"

      entity = Characters.to_entity(reloaded)
      assert entity.faction == :armada
    end

    test "chaos faction saved by save_snapshot and loaded by get + to_entity", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "chaos"})

      reloaded = Characters.get(char.id)
      assert reloaded.faction == "chaos"

      entity = Characters.to_entity(reloaded)
      assert entity.faction == :chaos
    end

    test "none faction saved by save_snapshot and loaded by get + to_entity", %{account: account} do
      char = create_character(account)

      # First set to armada, then back to none
      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "armada"})
      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "none"})

      reloaded = Characters.get(char.id)
      assert reloaded.faction == "none"

      entity = Characters.to_entity(reloaded)
      assert entity.faction == :none
    end

    test "default faction is none for new characters", %{account: account} do
      char = create_character(account)

      reloaded = Characters.get(char.id)
      assert reloaded.faction == "none"

      entity = Characters.to_entity(reloaded)
      assert entity.faction == :none
    end
  end

  # ---- Faction score persists ----

  describe "faction score persists" do
    test "faction_score increments persist across save/load", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "armada", faction_score: 100})

      reloaded = Characters.get(char.id)
      assert reloaded.faction_score == 100

      # Simulate score increment
      {:ok, _} = Characters.save_snapshot(char.id, %{faction_score: 250})

      reloaded2 = Characters.get(char.id)
      assert reloaded2.faction_score == 250
    end

    test "faction_score round-trips through entity conversion", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "chaos", faction_score: 500})

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)
      assert entity.faction_score == 500

      attrs = Characters.from_entity(entity)
      assert attrs.faction_score == 500
    end

    test "zero faction_score persists", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction_score: 0})

      reloaded = Characters.get(char.id)
      assert reloaded.faction_score == 0
    end
  end

  # ---- Faction rank persists ----

  describe "faction rank persists" do
    test "armada rank persists across save/load", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "armada", faction_rank_armada: 5})

      reloaded = Characters.get(char.id)
      assert reloaded.faction_rank_armada == 5
    end

    test "chaos rank persists across save/load", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "chaos", faction_rank_chaos: 3})

      reloaded = Characters.get(char.id)
      assert reloaded.faction_rank_chaos == 3
    end

    test "both faction ranks can be non-zero (player switched factions)", %{account: account} do
      char = create_character(account)

      {:ok, _} =
        Characters.save_snapshot(char.id, %{
          faction: "chaos",
          faction_rank_armada: 2,
          faction_rank_chaos: 4
        })

      reloaded = Characters.get(char.id)
      assert reloaded.faction_rank_armada == 2
      assert reloaded.faction_rank_chaos == 4

      entity = Characters.to_entity(reloaded)
      assert entity.faction_rank_armada == 2
      assert entity.faction_rank_chaos == 4
    end
  end

  # ---- Faction kill counters persist ----

  describe "faction kill counters persist" do
    test "all four kill counters survive snapshot round-trip", %{account: account} do
      char = create_character(account)

      {:ok, _} =
        Characters.save_snapshot(char.id, %{
          faction: "armada",
          faction_kills_royal: 12,
          faction_kills_chaos: 25,
          citizens_killed: 3,
          criminals_killed: 8
        })

      reloaded = Characters.get(char.id)
      assert reloaded.faction_kills_royal == 12
      assert reloaded.faction_kills_chaos == 25
      assert reloaded.citizens_killed == 3
      assert reloaded.criminals_killed == 8
    end

    test "kill counters round-trip through entity conversion", %{account: account} do
      char = create_character(account)

      {:ok, _} =
        Characters.save_snapshot(char.id, %{
          faction_kills_royal: 7,
          faction_kills_chaos: 14,
          citizens_killed: 1,
          criminals_killed: 5
        })

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)
      assert entity.faction_kills_royal == 7
      assert entity.faction_kills_chaos == 14
      assert entity.citizens_killed == 1
      assert entity.criminals_killed == 5

      attrs = Characters.from_entity(entity)
      assert attrs.faction_kills_royal == 7
      assert attrs.faction_kills_chaos == 14
      assert attrs.citizens_killed == 1
      assert attrs.criminals_killed == 5
    end

    test "kill counters increment across multiple snapshots", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{citizens_killed: 2})
      {:ok, _} = Characters.save_snapshot(char.id, %{citizens_killed: 5})

      reloaded = Characters.get(char.id)
      assert reloaded.citizens_killed == 5
    end
  end

  # ---- Faction re-enlistment counter persists ----

  describe "faction re-enlistment counter persists" do
    test "faction_reenlistadas persists across save/load", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction_reenlistadas: 3})

      reloaded = Characters.get(char.id)
      assert reloaded.faction_reenlistadas == 3
    end

    test "faction_reenlistadas round-trips through entity conversion", %{account: account} do
      char = create_character(account)

      {:ok, _} = Characters.save_snapshot(char.id, %{faction_reenlistadas: 2})

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)
      assert entity.faction_reenlistadas == 2

      attrs = Characters.from_entity(entity)
      assert attrs.faction_reenlistadas == 2
    end
  end

  # ---- Player leaving faction sets faction to :none and persists ----

  describe "player leaving faction sets faction to :none and persists" do
    test "switching from armada to none clears faction", %{account: account} do
      char = create_character(account)

      {:ok, _} =
        Characters.save_snapshot(char.id, %{
          faction: "armada",
          faction_score: 100,
          faction_rank_armada: 2
        })

      # Player leaves faction
      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "none"})

      reloaded = Characters.get(char.id)
      assert reloaded.faction == "none"

      entity = Characters.to_entity(reloaded)
      assert entity.faction == :none

      # Score and rank should still be preserved (historical data)
      assert reloaded.faction_score == 100
      assert reloaded.faction_rank_armada == 2
    end

    test "switching from chaos to none clears faction", %{account: account} do
      char = create_character(account)

      {:ok, _} =
        Characters.save_snapshot(char.id, %{
          faction: "chaos",
          faction_score: 200,
          faction_rank_chaos: 4
        })

      {:ok, _} = Characters.save_snapshot(char.id, %{faction: "none"})

      reloaded = Characters.get(char.id)
      assert reloaded.faction == "none"
      # Historical data preserved
      assert reloaded.faction_rank_chaos == 4
    end
  end

  # ---- Full faction state snapshot ----

  describe "full faction state snapshot" do
    test "all faction fields persist in a single snapshot", %{account: account} do
      char = create_character(account)

      {:ok, _} =
        Characters.save_snapshot(char.id, %{
          faction: "armada",
          faction_kills_royal: 10,
          faction_kills_chaos: 20,
          citizens_killed: 4,
          criminals_killed: 15,
          faction_score: 300,
          faction_rank_armada: 5,
          faction_rank_chaos: 1,
          faction_reenlistadas: 2
        })

      reloaded = Characters.get(char.id)
      entity = Characters.to_entity(reloaded)

      assert entity.faction == :armada
      assert entity.faction_kills_royal == 10
      assert entity.faction_kills_chaos == 20
      assert entity.citizens_killed == 4
      assert entity.criminals_killed == 15
      assert entity.faction_score == 300
      assert entity.faction_rank_armada == 5
      assert entity.faction_rank_chaos == 1
      assert entity.faction_reenlistadas == 2

      # Round-trip back to DB attrs
      attrs = Characters.from_entity(entity)
      assert attrs.faction == "armada"
      assert attrs.faction_kills_royal == 10
      assert attrs.faction_kills_chaos == 20
      assert attrs.citizens_killed == 4
      assert attrs.criminals_killed == 15
      assert attrs.faction_score == 300
      assert attrs.faction_rank_armada == 5
      assert attrs.faction_rank_chaos == 1
      assert attrs.faction_reenlistadas == 2
    end
  end
end
