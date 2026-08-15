# Walk-latency benchmark.
#
# Measures server-side walk responsiveness: the round-trip from a bot sending a
# walk intent to receiving the resulting `pos_update` (packet 31), over the same
# WebSocket transport the browser client uses.
#
# The point of this benchmark is attribution. When someone reports "movement
# feels slow", this answers whether the backend is responsible before anyone
# profiles the renderer. Sub-millisecond p95 here means the delay is client-side.
#
# Requires an ALREADY-RUNNING server (`make run`). Run with --no-start so this
# node does not try to bind the game ports a second time:
#
#     make bench.walk
#     mix run --no-start scripts/bench_walk_latency.exs
#
# Tunables (environment variables):
#
#     BENCH_BOTS        bot count                       (default 5)
#     BENCH_WARMUP_S    warmup before measuring         (default 8)
#     BENCH_DURATION_S  measurement window              (default 25)
#     BENCH_HOST        gateway host                    (default 127.0.0.1)
#     BENCH_PORT        gateway WebSocket port          (default 7667)
#     BENCH_P95_BUDGET_MS  fail above this p95          (default 5.0)
#     BENCH_START_ID    first bot char id               (default 90000)
#
# Exits non-zero if p95 exceeds the budget or if no samples were collected, so
# this can gate CI as well as be read by a human.

defmodule Bench do
  def env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      raw -> String.to_integer(String.trim(raw))
    end
  end

  def env_float(name, default) do
    case System.get_env(name) do
      nil -> default
      raw -> String.to_float(String.trim(raw))
    end
  end

  def percentile(sorted, p) do
    n = length(sorted)
    Enum.at(sorted, min(n - 1, trunc(n * p / 100)))
  end

  def ms(us), do: Float.round(us / 1000, 3)

  def die(message) do
    IO.puts(:stderr, "\nFAIL: #{message}")
    System.halt(1)
  end
end

bots = Bench.env_int("BENCH_BOTS", 5)
warmup_s = Bench.env_int("BENCH_WARMUP_S", 8)
duration_s = Bench.env_int("BENCH_DURATION_S", 25)
host = System.get_env("BENCH_HOST", "127.0.0.1")
port = Bench.env_int("BENCH_PORT", 7667)
budget_ms = Bench.env_float("BENCH_P95_BUDGET_MS", 5.0)

# Bot characters persist, so a previous run can leave them wedged against a wall
# where every walk is legitimately blocked. Vary this to test with fresh ones.
start_id = Bench.env_int("BENCH_START_ID", 90_000)

# Fail fast with an actionable message rather than a wall of connect errors.
case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 2_000) do
  {:ok, probe} ->
    :gen_tcp.close(probe)

  {:error, reason} ->
    Bench.die("""
    no server listening on #{host}:#{port} (#{inspect(reason)}).
    Start one first:  make run
    """)
end

{:ok, _} =
  DynamicSupervisor.start_link(
    name: BotArmy.BotSupervisor,
    strategy: :one_for_one,
    max_restarts: 0
  )

{:ok, _} = BotArmy.Swarm.start_link([])

IO.puts("walk-latency benchmark -> ws://#{host}:#{port}/ao")
IO.puts("  bots=#{bots} warmup=#{warmup_s}s window=#{duration_s}s p95 budget=#{budget_ms}ms\n")

# :walk_only keeps chat/attack out of the sample so the number means one thing.
# Tight action intervals maximise samples per second of wall clock.
BotArmy.spawn(bots,
  profile: :walk_only,
  start_id: start_id,
  min_action_interval: 200,
  max_action_interval: 400
)

Process.sleep(warmup_s * 1_000)

status = BotArmy.status()
IO.inspect(status, label: "connected after warmup")

if status.connected == 0 do
  BotArmy.stop_all()
  Bench.die("no bots connected — check the gateway and login path")
end

# Reset after warmup so connection/login noise stays out of the measurement.
BotArmy.reset_metrics()
Process.sleep(duration_s * 1_000)

metrics = BotArmy.metrics()
samples = Map.get(metrics, :rtt_samples, [])

BotArmy.stop_all()

if samples == [] do
  Bench.die("no walk round-trips completed in #{duration_s}s — movement may be fully stalled")
end

sorted = Enum.sort(samples)
n = length(sorted)
p50 = Bench.percentile(sorted, 50)
p95 = Bench.percentile(sorted, 95)
p99 = Bench.percentile(sorted, 99)

IO.puts("""

── walk -> pos_update round-trip ──
  samples  #{n}  (#{metrics.packets_in} packets in, #{metrics.bytes_in} bytes)
  min      #{Bench.ms(Enum.min(sorted))} ms
  p50      #{Bench.ms(p50)} ms
  p95      #{Bench.ms(p95)} ms
  p99      #{Bench.ms(p99)} ms
  max      #{Bench.ms(Enum.max(sorted))} ms
""")

p95_ms = Bench.ms(p95)

if p95_ms > budget_ms do
  Bench.die("p95 #{p95_ms}ms exceeds budget #{budget_ms}ms — the backend IS slow")
else
  IO.puts("PASS: p95 #{p95_ms}ms within budget #{budget_ms}ms.")
  IO.puts("If movement still feels slow, the cost is client-side, not in the server.")
end
