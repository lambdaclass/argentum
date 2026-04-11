defmodule Mix.Tasks.Bench.Soak do
  @moduledoc """
  Sustained load/soak test that runs bots for an extended period and monitors
  for degradation (memory leaks, queue buildup, scheduler saturation, bot deaths).

  The task starts the server automatically via `app.start`.

  ## Usage

      mix bench.soak --bots 100 --duration 300 --profile walk_only
      mix bench.soak --bots 500 --duration 600 --map 999

  ## Options

      --bots      Number of bots to spawn (default: 100)
      --duration  Test duration in seconds (default: 300 = 5 minutes)
      --profile   Bot action profile: walk_only, walk_chat, idle, default (default: walk_only)
      --interval  Action interval in ms (default: 300)
      --map       Benchmark map ID; nil = real maps (default: nil)

  ## Pass/Fail Criteria

      memory_stable    Last memory sample < 2x first memory sample
      no_queue_buildup Max message queue depth across all samples < 100
      scheduler_ok     Average scheduler utilization < 80%
      bots_alive       Final connected count >= 90% of spawned

  Exits with code 1 if any criterion fails.
  """

  use Mix.Task

  require Logger

  @shortdoc "Sustained soak test with degradation detection"

  @sample_interval_sec 10

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          bots: :integer,
          duration: :integer,
          profile: :string,
          interval: :integer,
          map: :integer
        ]
      )

    count = Keyword.get(opts, :bots, 100)
    duration = Keyword.get(opts, :duration, 300)
    profile = if p = Keyword.get(opts, :profile), do: String.to_atom(p), else: :walk_only
    interval = Keyword.get(opts, :interval, 300)
    max_interval = interval + 200
    bench_map = Keyword.get(opts, :map, nil)

    # Enable scheduler wall time tracking
    :erlang.system_flag(:scheduler_wall_time, true)

    # Start benchmark map if requested
    if bench_map do
      case Arena.Map.MapSupervisor.start_map(bench_map) do
        {:ok, _pid} -> Mix.shell().info("Started benchmark map #{bench_map}")
        {:error, {:already_started, _}} -> Mix.shell().info("Benchmark map #{bench_map} already running")
        {:error, reason} -> Mix.shell().error("Failed to start benchmark map #{bench_map}: #{inspect(reason)}")
      end
    end

    map_label = if bench_map, do: "map #{bench_map}", else: "real maps"

    Mix.shell().info("""

    ╔══════════════════════════════════════╗
    ║         Soak Test Runner             ║
    ╚══════════════════════════════════════╝

    Bots:       #{count}
    Profile:    #{profile}
    Interval:   #{interval}..#{max_interval}ms
    Duration:   #{duration}s
    Map:        #{map_label}
    Sample every #{@sample_interval_sec}s
    """)

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
    Mix.shell().info("Waiting for connections (5s)...")
    Process.sleep(5_000)
    status = BotArmy.status()
    Mix.shell().info("Connected: #{status.connected}/#{status.total}")

    # Warmup
    Mix.shell().info("Warming up for 10s...")
    Process.sleep(10_000)
    BotArmy.reset_metrics()

    # Sample loop
    num_samples = div(duration, @sample_interval_sec)
    Mix.shell().info("Sampling for #{duration}s (#{num_samples} samples)...\n")

    samples = collect_samples(num_samples)

    # Final bot metrics
    bot_metrics = BotArmy.metrics()
    final_status = BotArmy.status()

    # Stop all bots
    Mix.shell().info("Stopping bots...")
    BotArmy.stop_all()
    Process.sleep(2_000)

    # Analyze and print
    verdict = analyze(samples, final_status, spawned)
    print_results(%{
      count: count, profile: profile, interval: interval, max_interval: max_interval,
      duration: duration, map_label: map_label, samples: samples,
      bot_metrics: bot_metrics, final_status: final_status, spawned: spawned, verdict: verdict
    })

    unless verdict.pass do
      System.at_exit(fn _ -> :ok end)
      exit({:shutdown, 1})
    end
  end

  # ---------------------------------------------------------------------------
  # Sampling
  # ---------------------------------------------------------------------------

  defp collect_samples(num_samples) do
    for i <- 1..num_samples do
      Process.sleep(@sample_interval_sec * 1_000)

      scheduler_util = get_scheduler_util()
      memory_mb = Float.round(:erlang.memory(:total) / (1024 * 1024), 1)
      process_count = :erlang.system_info(:process_count)

      {total_queue, max_queue} = map_queue_depths()

      bot_status = BotArmy.status()

      sample = %{
        seq: i,
        scheduler_util: scheduler_util,
        memory_mb: memory_mb,
        process_count: process_count,
        total_queue: total_queue,
        max_queue: max_queue,
        connected: bot_status.connected,
        disconnected: bot_status.disconnected
      }

      Mix.shell().info(
        "  [#{String.pad_leading(Integer.to_string(i), 3)}] " <>
          "sched=#{scheduler_util}%  " <>
          "mem=#{memory_mb}MB  " <>
          "procs=#{process_count}  " <>
          "q_max=#{max_queue}  " <>
          "bots=#{bot_status.connected}/#{bot_status.total}"
      )

      sample
    end
  end

  defp map_queue_depths do
    queues =
      Registry.select(Arena.MapRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.map(fn {_map_id, pid} ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, len} -> len
          nil -> 0
        end
      end)

    total = Enum.sum(queues)
    max_q = if queues == [], do: 0, else: Enum.max(queues)
    {total, max_q}
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

  # ---------------------------------------------------------------------------
  # Analysis
  # ---------------------------------------------------------------------------

  defp analyze(samples, final_status, spawned) do
    memories = Enum.map(samples, & &1.memory_mb)
    first_mem = List.first(memories) || 1
    last_mem = List.last(memories) || 1
    memory_stable = last_mem < 2 * first_mem

    max_queue = samples |> Enum.map(& &1.max_queue) |> Enum.max(fn -> 0 end)
    no_queue_buildup = max_queue < 100

    avg_sched =
      case samples do
        [] -> 0.0
        _ -> Enum.sum(Enum.map(samples, & &1.scheduler_util)) / length(samples)
      end

    scheduler_ok = avg_sched < 80.0

    bots_alive = final_status.connected >= div(spawned * 90, 100)

    pass = memory_stable and no_queue_buildup and scheduler_ok and bots_alive

    %{
      memory_stable: memory_stable,
      first_mem: first_mem,
      last_mem: last_mem,
      no_queue_buildup: no_queue_buildup,
      max_queue: max_queue,
      scheduler_ok: scheduler_ok,
      avg_sched: Float.round(avg_sched, 1),
      bots_alive: bots_alive,
      final_connected: final_status.connected,
      pass: pass
    }
  end

  # ---------------------------------------------------------------------------
  # Reporting
  # ---------------------------------------------------------------------------

  defp print_results(%{
         count: count, profile: profile, interval: interval, max_interval: max_interval,
         duration: duration, map_label: map_label, samples: samples,
         bot_metrics: bot_metrics, final_status: final_status, spawned: spawned, verdict: verdict
       }) do
    avg = fn list -> if list == [], do: 0.0, else: Enum.sum(list) / length(list) end

    memories = Enum.map(samples, & &1.memory_mb)
    avg_mem = Float.round(avg.(memories), 1)
    min_mem = if memories == [], do: 0.0, else: Float.round(Enum.min(memories), 1)
    max_mem = if memories == [], do: 0.0, else: Float.round(Enum.max(memories), 1)

    avg_procs =
      case samples do
        [] -> 0
        _ -> div(Enum.sum(Enum.map(samples, & &1.process_count)), length(samples))
      end

    packets_per_sec = if duration > 0, do: Float.round(bot_metrics.packets_in / duration, 0), else: 0
    kb_per_sec = if duration > 0, do: Float.round(bot_metrics.bytes_in / duration / 1024, 1), else: 0.0

    rtt_str =
      case bot_metrics.rtt_samples do
        [] ->
          "no samples"

        rtt_samples ->
          sorted = Enum.sort(rtt_samples)
          len = length(sorted)
          p50 = Enum.at(sorted, div(len, 2))
          p99 = Enum.at(sorted, trunc(len * 0.99))
          max_rtt = List.last(sorted)
          "p50=#{div(p50, 1000)}ms p99=#{div(p99, 1000)}ms max=#{div(max_rtt, 1000)}ms"
      end

    check = fn val -> if val, do: "PASS", else: "FAIL" end
    pad = 40

    Mix.shell().info("""

    ┌──────────────────────────────────────────────────────┐
    │                  Soak Test Results                    │
    ├──────────────────────────────────────────────────────┤
    │ Bots:             #{String.pad_trailing(to_string(count), pad)}│
    │ Profile:          #{String.pad_trailing(to_string(profile), pad)}│
    │ Interval:         #{String.pad_trailing("#{interval}..#{max_interval}ms", pad)}│
    │ Duration:         #{String.pad_trailing("#{duration}s", pad)}│
    │ Map:              #{String.pad_trailing(map_label, pad)}│
    ├──────────────────────────────────────────────────────┤
    │ Scheduler util:   #{String.pad_trailing("#{verdict.avg_sched}%", pad)}│
    │ Memory (avg):     #{String.pad_trailing("#{avg_mem} MB", pad)}│
    │ Memory (range):   #{String.pad_trailing("#{min_mem} - #{max_mem} MB", pad)}│
    │ Processes (avg):  #{String.pad_trailing("#{avg_procs}", pad)}│
    │ Max queue depth:  #{String.pad_trailing("#{verdict.max_queue}", pad)}│
    │ Packets/sec (rx): #{String.pad_trailing("#{trunc(packets_per_sec)}", pad)}│
    │ Bandwidth (rx):   #{String.pad_trailing("#{kb_per_sec} KB/s", pad)}│
    │ Move RTT:         #{String.pad_trailing(rtt_str, pad)}│
    ├──────────────────────────────────────────────────────┤
    │ Bots alive:       #{String.pad_trailing("#{final_status.connected}/#{spawned}", pad)}│
    ├──────────────────────────────────────────────────────┤
    │ memory_stable     #{String.pad_trailing("#{check.(verdict.memory_stable)} (#{verdict.first_mem} -> #{verdict.last_mem} MB)", pad)}│
    │ no_queue_buildup  #{String.pad_trailing("#{check.(verdict.no_queue_buildup)} (max=#{verdict.max_queue})", pad)}│
    │ scheduler_ok      #{String.pad_trailing("#{check.(verdict.scheduler_ok)} (avg=#{verdict.avg_sched}%)", pad)}│
    │ bots_alive        #{String.pad_trailing("#{check.(verdict.bots_alive)} (#{verdict.final_connected}/#{spawned})", pad)}│
    ├──────────────────────────────────────────────────────┤
    │ VERDICT:          #{String.pad_trailing(if(verdict.pass, do: "PASS", else: "FAIL"), pad)}│
    └──────────────────────────────────────────────────────┘
    """)
  end
end
