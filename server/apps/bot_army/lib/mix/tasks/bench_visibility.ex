defmodule Mix.Tasks.Bench.Visibility do
  @moduledoc """
  Benchmark visibility modes: global, aoi_scan, aoi_grid.

  Spawns bots and measures server + client metrics for a sample period.
  The task starts the server automatically via `app.start`.

  ## Hot-map scenarios (dedicated benchmark map 999, 100x100 open, no exits)

      --scenario hot_spread       Bots spread across the map
      --scenario hot_dense        Bots clustered at center
      --scenario hot_saturated    Fixed 210ms walk interval, peak pressure

  ## Crowd arena scenarios (map 998, 25x25 walkable center, rest blocked)

      --scenario crowd            Bots packed into 25x25 arena
      --scenario crowd_saturated  25x25 arena + fixed 210ms walk interval

  ## World-scale scenarios (real maps with exit tiles)

      --scenario world_spread     Bots wander freely across maps (default)
      --scenario world_idle       Bots connected but take no actions

  Explicit --profile, --interval, --warmup flags override scenario defaults.

  ## Usage

      AO_VISIBILITY_MODE=aoi_grid mix bench.visibility --scenario hot_spread --count 1000

  ## Options

      --count     Number of bots to spawn (default: 200)
      --duration  Sample duration in seconds (default: 30)
      --warmup    Warmup duration in seconds (default: per scenario)
      --profile   Bot action profile: walk_only, walk_chat, idle, default
      --interval  Action interval in ms (default: per scenario)
      --scenario  Benchmark scenario (default: world_spread)
  """

  use Mix.Task

  require Logger

  @shortdoc "Benchmark visibility modes with bots"

  @scenarios %{
    # --- Hot-map scenarios: dedicated benchmark map 999, no exits ---
    "hot_spread" => %{
      profile: :walk_only,
      min_interval: 210,
      max_interval: 410,
      warmup: 10,
      map_id: 999,
      spawn: :spread,
      description: "benchmark map, bots spread across 100x100"
    },
    "hot_dense" => %{
      profile: :walk_only,
      min_interval: 210,
      max_interval: 410,
      warmup: 2,
      map_id: 999,
      spawn: :center,
      description: "benchmark map, bots clustered at center"
    },
    "hot_saturated" => %{
      profile: :walk_only,
      min_interval: 210,
      max_interval: 210,
      warmup: 10,
      map_id: 999,
      spawn: :spread,
      description: "benchmark map, fixed 210ms walk interval"
    },
    # --- Crowd arena scenarios: map 998, 25x25 walkable center ---
    "crowd" => %{
      profile: :walk_only,
      min_interval: 210,
      max_interval: 410,
      warmup: 5,
      map_id: 998,
      spawn: :center,
      description: "25x25 arena, bots packed into constrained area"
    },
    "crowd_saturated" => %{
      profile: :walk_only,
      min_interval: 210,
      max_interval: 210,
      warmup: 5,
      map_id: 998,
      spawn: :center,
      description: "25x25 arena, fixed 210ms walk interval"
    },
    # --- World-scale scenarios: real maps with exits ---
    "world_spread" => %{
      profile: :walk_only,
      min_interval: 210,
      max_interval: 410,
      warmup: 15,
      map_id: nil,
      spawn: :world,
      description: "real maps, bots pre-scattered then wander via exits"
    },
    "world_idle" => %{
      profile: :idle,
      min_interval: 1_000,
      max_interval: 2_000,
      warmup: 5,
      map_id: nil,
      spawn: :default,
      description: "real maps, bots connected but idle"
    }
  }

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          count: :integer,
          duration: :integer,
          warmup: :integer,
          profile: :string,
          interval: :integer,
          scenario: :string
        ]
      )

    scenario_name = Keyword.get(opts, :scenario, "world_spread")

    scenario =
      case Map.get(@scenarios, scenario_name) do
        nil ->
          Mix.shell().error("Unknown scenario: #{scenario_name}")
          hot = @scenarios |> Enum.filter(fn {_, v} -> v.map_id != nil end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
          world = @scenarios |> Enum.filter(fn {_, v} -> v.map_id == nil end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
          Mix.shell().error("  Hot-map:     #{Enum.join(hot, ", ")}")
          Mix.shell().error("  World-scale: #{Enum.join(world, ", ")}")
          exit(:shutdown)

        s ->
          s
      end

    # Explicit flags override scenario defaults
    count = Keyword.get(opts, :count, 200)
    duration = Keyword.get(opts, :duration, 30)
    warmup = Keyword.get(opts, :warmup, scenario.warmup)
    profile = if p = Keyword.get(opts, :profile), do: String.to_atom(p), else: scenario.profile
    interval = Keyword.get(opts, :interval, scenario.min_interval)
    max_interval = if Keyword.has_key?(opts, :interval), do: interval + 200, else: scenario.max_interval
    bench_map = scenario.map_id
    spawn_mode = scenario.spawn

    # Enable scheduler wall time tracking
    :erlang.system_flag(:scheduler_wall_time, true)

    visibility_mode = Application.get_env(:arena, :visibility_mode, :aoi_grid)

    # For hot-map scenarios, start the benchmark map if not already running
    if bench_map do
      case Arena.Map.MapSupervisor.start_map(bench_map) do
        {:ok, _pid} -> Mix.shell().info("Started benchmark map #{bench_map}")
        {:error, {:already_started, _}} -> Mix.shell().info("Benchmark map #{bench_map} already running")
        {:error, reason} -> Mix.shell().error("Failed to start benchmark map #{bench_map}: #{inspect(reason)}")
      end
    end

    map_label = if bench_map, do: "map #{bench_map} (no exits)", else: "real maps (exits enabled)"

    Mix.shell().info("""

    ╔══════════════════════════════════════╗
    ║     Visibility Benchmark Runner      ║
    ╚══════════════════════════════════════╝

    Scenario:   #{scenario_name} — #{scenario.description}
    Mode:       #{visibility_mode}
    Bots:       #{count}
    Profile:    #{profile}
    Interval:   #{interval}..#{max_interval}ms
    Warmup:     #{warmup}s
    Duration:   #{duration}s
    Map:        #{map_label}
    Spawn:      #{spawn_mode}
    """)

    # Reset bot positions for deterministic scenarios.
    # Hot-map/crowd: all bots to benchmark map.
    # World: pre-scatter across connected maps.
    if bench_map || spawn_mode == :world do
      reset_bot_positions(count, bench_map, spawn_mode)
    end

    # Spawn bots
    Mix.shell().info("Spawning #{count} bots...")

    {:ok, spawned} =
      BotArmy.spawn(count,
        profile: profile,
        min_action_interval: interval,
        max_action_interval: max_interval
      )

    Mix.shell().info("Spawned #{spawned}/#{count} bots")

    # Wait for connections
    Mix.shell().info("Waiting for connections...")
    Process.sleep(5_000)
    status = BotArmy.status()
    Mix.shell().info("Connected: #{status.connected}/#{status.total}")

    # Warmup
    Mix.shell().info("Warming up for #{warmup}s...")
    Process.sleep(warmup * 1_000)

    # Reset all metrics counters so we only measure the sample window
    Arena.Metrics.reset()
    BotArmy.reset_metrics()

    # Sample
    Mix.shell().info("Sampling for #{duration}s...")
    samples = collect_samples(duration)

    # Collect final bot metrics
    bot_metrics = BotArmy.metrics()

    # Stop bots
    Mix.shell().info("Stopping bots...")
    BotArmy.stop_all()
    Process.sleep(2_000)

    # Print results
    print_results(visibility_mode, count, profile, interval, max_interval, scenario_name, samples, bot_metrics, duration)
  end

  defp reset_bot_positions(count, map_id, spawn_mode) do
    start_id = 10_000
    names = for i <- 0..(count - 1), do: "Bot_#{start_id + i}"

    case spawn_mode do
      :center ->
        # All bots at map center — deterministic dense cluster
        Ecto.Adapters.SQL.query!(
          GameBackend.Repo,
          "UPDATE characters SET map_id = $1, pos_x = 50, pos_y = 50 WHERE name = ANY($2)",
          [map_id, names]
        )
        Mix.shell().info("Reset #{count} bots to map #{map_id} at (50, 50)")

      :spread ->
        # Distribute bots in a grid pattern across the map (avoiding edges)
        # Place on a grid within 10..90 x 10..90 (80x80 = 6400 positions)
        Ecto.Adapters.SQL.query!(
          GameBackend.Repo,
          "UPDATE characters SET map_id = $1, pos_x = 50, pos_y = 50 WHERE name = ANY($2)",
          [map_id, names]
        )
        # Bots start at center and spread naturally during warmup on a
        # 100x100 open map with no exits — they can't escape.
        Mix.shell().info("Reset #{count} bots to map #{map_id} (will spread during warmup)")

      :world ->
        # Pre-scatter bots across connected maps so they start distributed.
        # Maps reachable from map 1 (Ciudad de Ullathorpe).
        world_maps = [1, 2, 5, 8, 11, 40, 168, 395, 600, 601, 602, 603, 748]
        map_count = length(world_maps)

        # Batch update: group names by target map, one UPDATE per map
        groups =
          names
          |> Enum.with_index()
          |> Enum.group_by(fn {_name, i} -> Enum.at(world_maps, rem(i, map_count)) end, fn {name, _i} -> name end)

        for {target_map, group_names} <- groups do
          Ecto.Adapters.SQL.query!(
            GameBackend.Repo,
            "UPDATE characters SET map_id = $1, pos_x = 50, pos_y = 50 WHERE name = ANY($2)",
            [target_map, group_names]
          )
        end

        Mix.shell().info("Pre-scattered #{count} bots across #{map_count} maps: #{inspect(world_maps)}")

      _ ->
        :ok
    end
  end

  defp collect_samples(duration_seconds) do
    interval_ms = 2_000
    num_samples = div(duration_seconds * 1_000, interval_ms)

    initial_reductions = total_reductions()

    samples =
      for _ <- 1..num_samples do
        before_red = total_reductions()
        metrics_before = Arena.Metrics.snapshot()
        Process.sleep(interval_ms)
        after_red = total_reductions()
        metrics_after = Arena.Metrics.snapshot()

        all_maps = get_all_map_server_info()
        total_queue = all_maps |> Map.values() |> Enum.map(& &1[:message_queue_len]) |> Enum.sum()
        max_queue = all_maps |> Map.values() |> Enum.map(& &1[:message_queue_len]) |> Enum.max(fn -> 0 end)

        # Compute per-sample deltas for broadcast metrics
        move_broadcasts = metrics_after.move_broadcasts - metrics_before.move_broadcasts
        move_recipients = metrics_after.move_recipients - metrics_before.move_recipients

        %{
          timestamp: System.monotonic_time(:millisecond),
          scheduler_util: get_scheduler_util(),
          memory_mb: :erlang.memory(:total) / (1024 * 1024),
          process_count: :erlang.system_info(:process_count),
          reductions_per_sec: div(after_red - before_red, div(interval_ms, 1_000)),
          map_server_queue: total_queue,
          map_server_max_queue: max_queue,
          map_info: all_maps,
          move_broadcasts: move_broadcasts,
          move_recipients: move_recipients,
          avg_recipients_per_move: if(move_broadcasts > 0, do: Float.round(move_recipients / move_broadcasts, 1), else: 0.0)
        }
      end

    final_reductions = total_reductions()
    total_time = duration_seconds

    %{
      samples: samples,
      avg_reductions_per_sec: div(final_reductions - initial_reductions, max(total_time, 1))
    }
  end

  defp get_all_map_server_info do
    Registry.select(Arena.MapRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {map_id, pid} ->
      queue_info =
        case Process.info(pid, [:message_queue_len, :reductions]) do
          nil -> %{message_queue_len: 0, reductions: 0}
          info -> Map.new(info)
        end

      player_count =
        try do
          GenServer.call(pid, :player_count, 1_000)
        catch
          :exit, _ -> 0
        end

      {map_id, Map.put(queue_info, :player_count, player_count)}
    end)
    |> Map.new()
  end

  defp total_reductions do
    :erlang.statistics(:reductions) |> elem(0)
  end

  defp get_scheduler_util do
    t0 = :erlang.statistics(:scheduler_wall_time)
    Process.sleep(200)
    t1 = :erlang.statistics(:scheduler_wall_time)

    case {t0, t1} do
      {nil, _} -> 0.0
      {_, nil} -> 0.0
      {s0, s1} ->
        pairs = Enum.zip(Enum.sort(s0), Enum.sort(s1))
        {total_active, total_total} =
          Enum.reduce(pairs, {0, 0}, fn {{id, a0, t0}, {id, a1, t1}}, {acc_a, acc_t} ->
            {acc_a + (a1 - a0), acc_t + (t1 - t0)}
          end)
        if total_total > 0, do: Float.round(total_active / total_total * 100, 1), else: 0.0
    end
  rescue
    _ -> 0.0
  end

  defp print_results(mode, count, profile, interval, max_interval, scenario, data, bot_metrics, duration) do
    samples = data.samples

    queues = Enum.map(samples, & &1.map_server_queue)
    max_queues = Enum.map(samples, & &1.map_server_max_queue)
    memory = Enum.map(samples, & &1.memory_mb)
    sched = Enum.map(samples, & &1.scheduler_util)
    procs = Enum.map(samples, & &1.process_count)
    recipients = Enum.map(samples, & &1.avg_recipients_per_move)
    move_bcast = Enum.map(samples, & &1.move_broadcasts)

    avg = fn list -> if list == [], do: 0.0, else: Enum.sum(list) / length(list) end

    avg_queue = avg.(queues)
    max_queue = if max_queues == [], do: 0, else: Enum.max(max_queues)
    avg_mem = Float.round(avg.(memory), 1)
    avg_sched = Float.round(avg.(sched), 1)
    avg_procs = if procs == [], do: 0, else: div(Enum.sum(procs), length(procs))
    avg_recipients = Float.round(avg.(recipients), 1)
    total_move_bcast = Enum.sum(move_bcast)
    moves_per_sec = if duration > 0, do: Float.round(total_move_bcast / duration, 0), else: 0

    # Bot-side metrics
    packets_per_sec = if duration > 0, do: Float.round(bot_metrics.packets_in / duration, 0), else: 0
    bytes_per_sec = if duration > 0, do: Float.round(bot_metrics.bytes_in / duration, 0), else: 0
    kb_per_sec = Float.round(bytes_per_sec / 1024, 1)

    rtt_str =
      case bot_metrics.rtt_samples do
        [] ->
          "no samples"

        samples ->
          sorted = Enum.sort(samples)
          len = length(sorted)
          p50 = Enum.at(sorted, div(len, 2))
          p99 = Enum.at(sorted, trunc(len * 0.99))
          max_rtt = List.last(sorted)
          "p50=#{div(p50, 1000)}ms p99=#{div(p99, 1000)}ms max=#{div(max_rtt, 1000)}ms"
      end

    # Per-map player distribution from last sample
    map_dist =
      case List.last(samples) do
        nil ->
          "no data"

        sample ->
          sample.map_info
          |> Enum.filter(fn {_id, info} -> info.player_count > 0 end)
          |> Enum.sort_by(fn {id, _} -> id end)
          |> Enum.map(fn {id, info} -> "map#{id}=#{info.player_count}" end)
          |> Enum.join(" ")
          |> case do
            "" -> "no players"
            s -> s
          end
      end

    pad = 40

    Mix.shell().info("""

    ┌──────────────────────────────────────────────────────┐
    │                 Benchmark Results                     │
    ├──────────────────────────────────────────────────────┤
    │ Scenario:         #{String.pad_trailing(scenario, pad)}│
    │ Mode:             #{String.pad_trailing(to_string(mode), pad)}│
    │ Bots:             #{String.pad_trailing(to_string(count), pad)}│
    │ Profile:          #{String.pad_trailing(to_string(profile), pad)}│
    │ Interval:         #{String.pad_trailing("#{interval}..#{max_interval}ms", pad)}│
    ├──────────────────────────────────────────────────────┤
    │ Scheduler util:   #{String.pad_trailing("#{avg_sched}%", pad)}│
    │ Memory (avg):     #{String.pad_trailing("#{avg_mem} MB", pad)}│
    │ Processes:        #{String.pad_trailing("#{avg_procs}", pad)}│
    │ Reductions/sec:   #{String.pad_trailing("#{data.avg_reductions_per_sec}", pad)}│
    ├──────────────────────────────────────────────────────┤
    │ MapServer queue:  #{String.pad_trailing("avg=#{Float.round(avg_queue, 1)} max=#{max_queue}", pad)}│
    │ Recipients/move:  #{String.pad_trailing("#{avg_recipients}", pad)}│
    │ Moves/sec:        #{String.pad_trailing("#{trunc(moves_per_sec)}", pad)}│
    │ Packets/sec (rx): #{String.pad_trailing("#{trunc(packets_per_sec)}", pad)}│
    │ Bandwidth (rx):   #{String.pad_trailing("#{kb_per_sec} KB/s", pad)}│
    │ Move RTT:         #{String.pad_trailing(rtt_str, pad)}│
    ├──────────────────────────────────────────────────────┤
    │ Player dist:      #{String.pad_trailing(map_dist, pad)}│
    └──────────────────────────────────────────────────────┘
    """)
  end
end
