defmodule Mix.Tasks.Bench.Persistence do
  @moduledoc """
  Benchmark persistence (autosave) throughput.

  Creates N temporary characters spread across M simulated maps, then fires
  concurrent autosave cycles — measuring wall-clock time and DB throughput
  when many MapServers save simultaneously.

  ## Scenarios

      --mode sequential   One process saves all characters (baseline)
      --mode concurrent   M map processes save their players in parallel (realistic)

  ## Usage

      mix bench.persistence --count 500 --maps 25
      mix bench.persistence --count 2000 --maps 50 --mode concurrent

  ## Options

      --count     Total number of characters (default: 500)
      --maps      Number of simulated maps (default: 25)
      --cycles    Number of autosave cycles to run (default: 3)
      --mode      sequential or concurrent (default: concurrent)
  """

  use Mix.Task

  require Logger
  import Ecto.Query

  alias GameBackend.Characters
  alias GameBackend.Repo
  alias Arena.Entity.PlayerEntity

  @shortdoc "Benchmark autosave throughput"

  @impl true
  def run(args) do
    # Suppress SQL debug logging during benchmark
    Logger.configure(level: :warning)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)
    {:ok, _} = GameBackend.Repo.start_link()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [count: :integer, maps: :integer, cycles: :integer, mode: :string]
      )

    count = Keyword.get(opts, :count, 500)
    maps = Keyword.get(opts, :maps, 25)
    cycles = Keyword.get(opts, :cycles, 3)
    mode = Keyword.get(opts, :mode, "concurrent") |> String.to_atom()

    pool_size = Application.get_env(:game_backend, GameBackend.Repo)[:pool_size] || 50

    Mix.shell().info("""

    ╔══════════════════════════════════════╗
    ║     Persistence Benchmark Runner     ║
    ╚══════════════════════════════════════╝

    Characters: #{count}
    Maps:       #{maps}
    Players/map:#{div(count, maps)}
    Mode:       #{mode}
    Cycles:     #{cycles}
    DB pool:    #{pool_size}
    """)

    Mix.shell().info("Creating #{count} temporary characters...")
    char_ids = create_temp_characters(count)
    Mix.shell().info("Created #{length(char_ids)} characters")

    entities = Enum.map(char_ids, &build_entity/1)

    # Split entities across simulated maps
    entities_by_map =
      entities
      |> Enum.with_index()
      |> Enum.group_by(fn {_e, i} -> rem(i, maps) end, fn {e, _i} -> e end)

    Mix.shell().info("Distributed across #{map_size(entities_by_map)} maps\n")

    # Run both modes for comparison
    results =
      for cycle <- 1..cycles do
        Mix.shell().info("Cycle #{cycle}/#{cycles}:")

        {seq_ms, seq_times} = measure_sequential(entities)
        {con_ms, con_times} = measure_concurrent(entities_by_map)

        seq_rate = if seq_ms > 0, do: Float.round(count * 1_000 / seq_ms, 1), else: 0
        con_rate = if con_ms > 0, do: Float.round(count * 1_000 / con_ms, 1), else: 0
        speedup = if seq_ms > 0, do: Float.round(seq_ms / max(con_ms, 1), 1), else: 0

        Mix.shell().info("  Sequential: #{seq_ms}ms (#{seq_rate}/s) | p50=#{percentile(seq_times, 50)}ms p95=#{percentile(seq_times, 95)}ms")
        Mix.shell().info("  Concurrent: #{con_ms}ms (#{con_rate}/s) | p50=#{percentile(con_times, 50)}ms p95=#{percentile(con_times, 95)}ms")
        Mix.shell().info("  Speedup:    #{speedup}x\n")

        %{
          seq_ms: seq_ms,
          seq_rate: seq_rate,
          con_ms: con_ms,
          con_rate: con_rate,
          speedup: speedup,
          seq_p95: percentile(seq_times, 95),
          con_p95: percentile(con_times, 95)
        }
      end

    print_summary(count, maps, cycles, results)
    print_interval_analysis(count, results)

    Mix.shell().info("\nCleaning up #{count} temporary characters...")
    cleanup_temp_characters(char_ids)
    Mix.shell().info("Done.")
  end

  # Sequential: one process saves all entities in order (baseline)
  defp measure_sequential(entities) do
    {total_us, times} =
      :timer.tc(fn ->
        Enum.map(entities, fn entity ->
          {us, _} = :timer.tc(fn -> save_entity(entity) end)
          div(us, 1_000)
        end)
      end)

    {div(total_us, 1_000), times}
  end

  # Concurrent: each map spawns a task that saves its players sequentially.
  # All maps fire at the same time (simulating autosave timer alignment).
  defp measure_concurrent(entities_by_map) do
    {total_us, all_times} =
      :timer.tc(fn ->
        entities_by_map
        |> Enum.map(fn {_map_id, map_entities} ->
          Task.async(fn ->
            Enum.map(map_entities, fn entity ->
              {us, _} = :timer.tc(fn -> save_entity(entity) end)
              div(us, 1_000)
            end)
          end)
        end)
        |> Enum.flat_map(&Task.await(&1, 60_000))
      end)

    {div(total_us, 1_000), all_times}
  end

  defp save_entity(entity) do
    attrs = Characters.from_entity(entity)
    inventory = Characters.inventory_from_entity(entity)
    equipment = Characters.equipment_from_entity(entity)
    Characters.save_snapshot(entity.char_id, attrs, inventory: inventory, equipment: equipment)
  end

  defp create_temp_characters(count) do
    Enum.map(1..count, fn i ->
      name = "_bench_persist_#{i}_#{System.unique_integer([:positive])}"

      attrs = %{
        name: name,
        account_id: "bench_account_#{i}",
        race: "humano",
        class: "warrior",
        gender: "male",
        home_city: "ullathorpe",
        map_id: 1,
        pos_x: 50,
        pos_y: 50,
        heading: "south",
        body_id: 1,
        head_id: 1,
        hp: 100,
        max_hp: 100,
        mana: 50,
        max_mana: 50,
        stamina: 100,
        max_stamina: 100,
        hunger: 80,
        thirst: 80,
        level: 10,
        xp: 5000,
        skill_points: 5,
        str: 20,
        agi: 18,
        int: 15,
        con: 20,
        cha: 12,
        gold: 1500,
        skills: %{"mining" => 10, "woodcutting" => 5, "combat" => 20},
        spells: [1, 5, 12, 25]
      }

      {:ok, character} =
        %GameBackend.Characters{}
        |> GameBackend.Characters.changeset(attrs)
        |> Repo.insert()

      character.id
    end)
  end

  defp build_entity(char_id) do
    inventory =
      Enum.map(0..23, fn slot ->
        if slot < 8 do
          %{item_id: 100 + slot, amount: Enum.random(1..10), equipped: slot < 2}
        else
          nil
        end
      end)

    %PlayerEntity{
      char_id: char_id,
      name: "bench_player_#{char_id}",
      account_id: "bench_account",
      x: Enum.random(10..90),
      y: Enum.random(10..90),
      heading: :south,
      body_id: 1,
      head_id: 1,
      hp: Enum.random(50..100),
      max_hp: 100,
      mana: Enum.random(20..50),
      max_mana: 50,
      stamina: Enum.random(60..100),
      max_stamina: 100,
      hunger: Enum.random(50..100),
      thirst: Enum.random(50..100),
      level: 10,
      xp: 5000 + Enum.random(0..1000),
      skill_points: 5,
      class: :warrior,
      race: :humano,
      gender: :male,
      home_city: :ullathorpe,
      str: 20,
      agi: 18,
      int: 15,
      con: 20,
      cha: 12,
      gold: 1500 + Enum.random(0..500),
      inventory: inventory,
      equipment: %{weapon: 100, armor: 101, shield: nil, helmet: nil, ring: nil},
      skills: %{"mining" => 10, "woodcutting" => 5, "combat" => 20},
      spells: [1, 5, 12, 25],
      map_id: 1
    }
  end

  defp percentile(times, p) do
    sorted = Enum.sort(times)
    k = max(0, round(length(sorted) * p / 100) - 1)
    Enum.at(sorted, k, 0)
  end

  defp print_summary(count, maps, cycles, results) do
    avg_seq = results |> Enum.map(& &1.seq_rate) |> avg() |> Float.round(1)
    avg_con = results |> Enum.map(& &1.con_rate) |> avg() |> Float.round(1)
    avg_speedup = results |> Enum.map(& &1.speedup) |> avg() |> Float.round(1)
    avg_seq_p95 = results |> Enum.map(& &1.seq_p95) |> avg() |> Float.round(1)
    avg_con_p95 = results |> Enum.map(& &1.con_p95) |> avg() |> Float.round(1)

    Mix.shell().info("""

    ╔══════════════════════════════════════╗
    ║           Summary                    ║
    ╚══════════════════════════════════════╝

    Characters:       #{count}
    Maps:             #{maps} (#{div(count, maps)} players/map)
    Cycles:           #{cycles}

    Sequential:       #{avg_seq} saves/sec  (p95: #{avg_seq_p95}ms)
    Concurrent:       #{avg_con} saves/sec  (p95: #{avg_con_p95}ms)
    Speedup:          #{avg_speedup}x
    """)
  end

  defp print_interval_analysis(count, results) do
    avg_con = results |> Enum.map(& &1.con_rate) |> avg()

    Mix.shell().info("  Autosave interval analysis (#{count} online players, concurrent):")
    Mix.shell().info("  ┌──────────┬──────────────┬──────────────────┬─────────────┐")
    Mix.shell().info("  │ Interval │ Saves needed │ Sustained rate   │ Feasible?   │")
    Mix.shell().info("  ├──────────┼──────────────┼──────────────────┼─────────────┤")

    for {label, secs} <- [{"15s", 15}, {"30s", 30}, {"60s", 60}, {"120s", 120}] do
      needed = count / secs
      feasible = if needed <= avg_con, do: "YES", else: "NO"
      pad_label = String.pad_trailing(label, 8)
      pad_saves = String.pad_trailing("#{Float.round(needed, 1)}/s", 12)
      pad_rate = String.pad_trailing("#{Float.round(avg_con, 1)}/s avail", 16)
      pad_feas = String.pad_trailing(feasible, 11)
      Mix.shell().info("  │ #{pad_label} │ #{pad_saves} │ #{pad_rate} │ #{pad_feas} │")
    end

    Mix.shell().info("  └──────────┴──────────────┴──────────────────┴─────────────┘")
  end

  defp avg(list), do: Enum.sum(list) / max(length(list), 1)

  defp cleanup_temp_characters(char_ids) do
    # Bulk delete is much faster than one-by-one
    char_ids
    |> Enum.chunk_every(500)
    |> Enum.each(fn batch ->
      from(c in GameBackend.Characters, where: c.id in ^batch) |> Repo.delete_all()
    end)
  end
end
