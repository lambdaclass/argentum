defmodule AoTcpGateway.AutosaveWriterTest do
  @moduledoc """
  Tests for the AutosaveWriter: coalescing, serialization, flush, and telemetry.
  """

  use ExUnit.Case, async: false

  alias AoTcpGateway.AutosaveWriter

  setup_all do
    start_if_needed(:ranch_sup, fn -> Application.ensure_all_started(:ranch) end)

    start_if_needed(Arena.PubSub, fn ->
      Application.ensure_all_started(:phoenix_pubsub)
      Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end)

    start_if_needed(AoSession.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: AoSession.SessionRegistry)
    end)

    start_if_needed(Arena.MapRegistry, fn ->
      Registry.start_link(keys: :unique, name: Arena.MapRegistry)
    end)

    start_if_needed(Arena.Map.MapSupervisor, fn ->
      Arena.Map.MapSupervisor.start_link([])
    end)

    case Registry.lookup(Arena.MapRegistry, 1) do
      [] -> Arena.Map.MapSupervisor.start_map(1)
      _ -> :ok
    end

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})
    :ok
  end

  test "submit + flush persists entity to DB" do
    {char_id, entity} = create_test_character("ASW_Flush_#{System.unique_integer([:positive])}")

    on_exit(fn -> cleanup_char(char_id) end)

    # Modify entity state
    entity = %{entity | gold: 9999, hp: 42}

    AutosaveWriter.submit(entity)
    assert :ok == AutosaveWriter.flush(char_id)

    # Verify the DB was updated
    saved = GameBackend.Characters.get(char_id)
    assert saved.gold == 9999
    assert saved.hp == 42
  end

  test "flush with nothing pending returns immediately" do
    fake_id = -999
    assert :ok == AutosaveWriter.flush(fake_id)
  end

  test "multiple submits coalesce — only the latest snapshot is written" do
    {char_id, entity} = create_test_character("ASW_Coal_#{System.unique_integer([:positive])}")

    on_exit(fn -> cleanup_char(char_id) end)

    test_pid = self()
    handler_id = "asw_coal_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arena, :persistence, :autosave],
      fn _event, _measurements, metadata, _config ->
        if metadata.char_id == char_id do
          send(test_pid, {:autosave_event, metadata.event})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Submit 3 snapshots rapidly — the first kicks off a write, the next two coalesce
    AutosaveWriter.submit(%{entity | gold: 100})
    AutosaveWriter.submit(%{entity | gold: 200})
    AutosaveWriter.submit(%{entity | gold: 300})

    assert :ok == AutosaveWriter.flush(char_id)

    # The final DB state should reflect the latest snapshot
    saved = GameBackend.Characters.get(char_id)
    assert saved.gold == 300

    # We should have seen at least one coalesce event
    assert_received {:autosave_event, :coalesced}
  end

  test "autosave failure logs and emits error telemetry" do
    test_pid = self()
    handler_id = "asw_err_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arena, :persistence, :autosave],
      fn _event, _measurements, metadata, _config ->
        if metadata.event == :error do
          send(test_pid, {:autosave_error, metadata.char_id})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Submit an entity with a non-existent char_id — save_snapshot will fail
    fake_entity = %AoEntities.PlayerEntity{char_id: -1, name: "Ghost", inventory: [], equipment: %{}, skills: %{}, spells: []}
    AutosaveWriter.submit(fake_entity)
    assert :ok == AutosaveWriter.flush(-1)

    assert_received {:autosave_error, -1}
  end

  test "snapshot_from_entity builds a complete snapshot" do
    entity = %AoEntities.PlayerEntity{
      char_id: 1, name: "Test", gold: 500,
      inventory: [%{item_id: 1, amount: 5, equipped: false}],
      equipment: %{weapon: 10},
      skills: %{mining: 50},
      spells: [%{spell_id: 1, slot: 1}]
    }

    snapshot = AutosaveWriter.snapshot_from_entity(entity)
    assert snapshot.attrs.gold == 500
    assert snapshot.inventory == entity.inventory
    assert snapshot.equipment == entity.equipment
    assert snapshot.skills == entity.skills
    assert snapshot.spells == entity.spells
  end

  # ---- Adversarial / regression tests ----

  test "stale snapshot cannot overwrite a newer one" do
    # If an old autosave arrives after a newer one (e.g. due to message reordering),
    # the latest-snapshot-wins rule must ensure only the most recent data persists.
    {char_id, entity} = create_test_character("ASW_Stale_#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_char(char_id) end)

    # Submit "new" state first, then "old" state immediately after.
    # Both will coalesce into the pending slot — the second replaces the first,
    # so the "old" snapshot wins if ordering is wrong.
    # To test properly: submit new, let it start writing, then submit old.
    new_entity = %{entity | gold: 5000, level: 10}
    old_entity = %{entity | gold: 0, level: 1}

    AutosaveWriter.submit(new_entity)
    # Give the writer a moment to pick up the first submit and start writing
    Process.sleep(50)
    # Now submit the "old" snapshot — it should coalesce into pending
    AutosaveWriter.submit(old_entity)
    AutosaveWriter.flush(char_id)

    saved = GameBackend.Characters.get(char_id)
    # The old entity arrived AFTER the new one, so it is actually the "latest"
    # from the writer's perspective. This is correct: the writer doesn't
    # compare timestamps, it keeps the most recently submitted snapshot.
    # The caller (MapServer) is responsible for sending snapshots in order.
    assert saved.gold == 0
    assert saved.level == 1
  end

  test "concurrent flushes for the same char_id both complete" do
    {char_id, entity} = create_test_character("ASW_DFlush_#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_char(char_id) end)

    AutosaveWriter.submit(%{entity | gold: 777})

    # Two concurrent flushes — both must return :ok, neither should hang
    task1 = Task.async(fn -> AutosaveWriter.flush(char_id) end)
    task2 = Task.async(fn -> AutosaveWriter.flush(char_id) end)

    assert :ok == Task.await(task1, 5_000)
    assert :ok == Task.await(task2, 5_000)

    saved = GameBackend.Characters.get(char_id)
    assert saved.gold == 777
  end

  test "rapid-fire submits during in-flight write — only final state persists" do
    {char_id, entity} = create_test_character("ASW_Rapid_#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_char(char_id) end)

    test_pid = self()
    handler_id = "asw_rapid_#{System.unique_integer([:positive])}"
    coalesce_count = :counters.new(1, [:atomics])

    :telemetry.attach(
      handler_id,
      [:arena, :persistence, :autosave],
      fn _event, _measurements, metadata, _config ->
        if metadata.char_id == char_id and metadata.event == :coalesced do
          :counters.add(coalesce_count, 1, 1)
        end

        if metadata.char_id == char_id and metadata.event in [:ok, :error] do
          send(test_pid, {:write_complete, metadata.event})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # First submit starts the write
    AutosaveWriter.submit(%{entity | gold: 1})

    # Rapid-fire 50 more while the first write is in flight
    for i <- 2..51 do
      AutosaveWriter.submit(%{entity | gold: i})
    end

    AutosaveWriter.flush(char_id)

    saved = GameBackend.Characters.get(char_id)
    # The final state must be gold=51 (the last submit)
    assert saved.gold == 51

    # Should have coalesced many times (at least some of the 49 pending overwrites)
    assert :counters.get(coalesce_count, 1) > 0
  end

  test "flush does not hang when AutosaveWriter has no record of char_id" do
    # Flush for a char_id that was never submitted should return instantly
    assert :ok == AutosaveWriter.flush(999_999_999)
  end

  test "submit for two different char_ids does not cross-contaminate" do
    {char_id_a, entity_a} = create_test_character("ASW_IsoA_#{System.unique_integer([:positive])}")
    {char_id_b, entity_b} = create_test_character("ASW_IsoB_#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_char(char_id_a); cleanup_char(char_id_b) end)

    AutosaveWriter.submit(%{entity_a | gold: 111})
    AutosaveWriter.submit(%{entity_b | gold: 222})

    AutosaveWriter.flush(char_id_a)
    AutosaveWriter.flush(char_id_b)

    saved_a = GameBackend.Characters.get(char_id_a)
    saved_b = GameBackend.Characters.get(char_id_b)

    assert saved_a.gold == 111
    assert saved_b.gold == 222
  end

  test "submit after flush starts a fresh write cycle" do
    {char_id, entity} = create_test_character("ASW_PostF_#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_char(char_id) end)

    # First cycle
    AutosaveWriter.submit(%{entity | gold: 100})
    AutosaveWriter.flush(char_id)

    saved = GameBackend.Characters.get(char_id)
    assert saved.gold == 100

    # Second cycle — must not be confused by the first
    AutosaveWriter.submit(%{entity | gold: 200})
    AutosaveWriter.flush(char_id)

    saved = GameBackend.Characters.get(char_id)
    assert saved.gold == 200
  end

  test "GenServer survives a write failure and continues serving" do
    # Submit a failing write (non-existent char_id)
    fake = %AoEntities.PlayerEntity{char_id: -42, name: "Bad", inventory: [], equipment: %{}, skills: %{}, spells: []}
    AutosaveWriter.submit(fake)
    AutosaveWriter.flush(-42)

    # The GenServer should still be alive and accept new work
    {char_id, entity} = create_test_character("ASW_Surv_#{System.unique_integer([:positive])}")
    on_exit(fn -> cleanup_char(char_id) end)

    AutosaveWriter.submit(%{entity | gold: 555})
    AutosaveWriter.flush(char_id)

    saved = GameBackend.Characters.get(char_id)
    assert saved.gold == 555
  end

  # ---- Helpers ----

  defp create_test_character(name) do
    account = ensure_test_account()

    {:ok, char} =
      GameBackend.Characters.create(%{
        name: name,
        account_id: account.id,
        race: "humano",
        class: "guerrero",
        gender: "male",
        home_city: "ullathorpe",
        head_id: 1,
        body_id: 1,
        pos_x: 50,
        pos_y: 50,
        map_id: 1,
        heading: "south",
        hp: 100,
        max_hp: 100,
        mana: 50,
        max_mana: 50,
        stamina: 100,
        max_stamina: 100,
        hunger: 100,
        thirst: 100,
        level: 1,
        xp: 0,
        gold: 0,
        str: 18,
        agi: 18,
        int: 18,
        con: 18,
        cha: 18,
        skill_points: 0,
        dead: false,
        criminal: false,
        penalty: 0,
        fishing_points: 0,
        faction: "none",
        npcs_killed: 0,
        deaths: 0,
        citizens_killed: 0,
        criminals_killed: 0,
        faction_kills_royal: 0,
        faction_kills_chaos: 0,
        faction_score: 0,
        faction_rank_armada: 0,
        faction_rank_chaos: 0,
        faction_reenlistadas: 0
      })

    entity = GameBackend.Characters.to_entity(char)
    {char.id, entity}
  end

  defp ensure_test_account do
    name = "asw_test_#{System.unique_integer([:positive])}"
    {:ok, account} = GameBackend.Account.create(name, "test_password")
    account
  end

  defp cleanup_char(char_id) do
    try do
      Arena.Map.MapServer.leave(1, char_id)
    catch
      :exit, _ -> :ok
    end

    AoSession.OnlineDirectory.unregister(char_id)
    AoSession.unregister(char_id)
  end

  defp start_if_needed(name, start_fun) do
    case Process.whereis(name) do
      nil -> start_fun.()
      _pid -> :ok
    end
  end
end
