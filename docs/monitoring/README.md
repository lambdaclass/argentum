# Arena Monitoring Runbook

Production observability for the Arena umbrella. Metrics are emitted via
`:telemetry` and exposed in Prometheus exposition format by
`Arena.PromEx`, served by the Cowboy WS listener at `/metrics`
(default `http://127.0.0.1:7667/metrics`).

The reporter is a thin `telemetry_metrics_prometheus_core` integration —
no embedded HTTP, no plugin layer. New metrics are declared in
`server/apps/arena/lib/arena/prom_ex.ex`.

---

## Local scrape

```sh
# Boot server (umbrella root)
mix run --no-halt

# In another shell, scrape once
curl -s http://127.0.0.1:7667/metrics | head -50
```

Run a load profile against it to see the histograms fill in:

```sh
# Light load (walks only)
mix bench.soak --bots 100 --duration 60 --profile walk_only

# Backpressure load: 200 slow readers, 1500ms gating between socket reads
mix bench.soak --bots 200 --duration 120 --profile slow_client --recv-delay-ms 1500
```

The slow-client profile flips the bot WS socket to `active: :once` after
handshake and rearms after `--recv-delay-ms`. That backs server send
buffers up and trips the backpressure path, so
`arena_session_backpressure_events_total` and the depth/byte/mailbox
distributions get real values.

---

## Metric reference

All metric names are listed below with the telemetry event they
subscribe to and how to read them. Prometheus names follow the
Telemetry.Metrics convention: dots become underscores, distributions get
the standard `_bucket` / `_sum` / `_count` suffixes.

### Session backpressure

| Metric | Type | What it means |
| --- | --- | --- |
| `arena_session_backpressure_events_total{cause,action,transport}` | counter | One increment per `[:arena, :session, :backpressure]` event. |
| `arena_session_backpressure_critical_depth_bucket{cause}` | histogram | Critical-queue depth at the moment pressure was raised. |
| `arena_session_backpressure_queued_bytes_bucket` | histogram | Outbound bytes queued at level transitions. |
| `arena_session_backpressure_mailbox_len_bucket` | histogram | Process mailbox length when the pressure check fired. |

`cause` values: `:critical_overflow`, `:mailbox_overflow`, `:send_timeout`.
Missing `transport` defaults to `"unknown"` (the normalizer fills it).

### Persistence

| Metric | Type | What it means |
| --- | --- | --- |
| `arena_persistence_autosave_events_total{event}` | counter | Lifecycle events: `submitted`, `started`, `ok`, `error`, `coalesced`. |
| `arena_persistence_autosave_duration_seconds_bucket{event}` | histogram | Write duration for `:ok`/`:error` only. Buckets 1ms–5s. |
| `arena_persistence_cleanup_duration_seconds_bucket{result}` | histogram | Final-save duration on logout/disconnect. |
| `arena_persistence_cleanup_save_failed_total` | counter | Cleanup save errors. |

Autosave runs under `AoTcpGateway.AutosaveTaskSupervisor` (since 2026-04-25),
so worker crashes show up as `event="error"` rather than as silent supervisor
restarts.

### Sessions

| Metric | Type | What it means |
| --- | --- | --- |
| `arena_session_login_total` | counter | Successful logins. |
| `arena_session_crash_cleanup_total` | counter | Sessions that needed post-crash cleanup. |

### Map server hot path

| Metric | Type | What it means |
| --- | --- | --- |
| `arena_map_tick_duration_seconds_bucket{tick_type}` | histogram | Per-tick processing time. Watch tail latency. |
| `arena_map_tick_queue_len_bucket{tick_type}` | histogram | MapServer mailbox depth at tick start. |
| `arena_map_broadcast_recipients_bucket` | histogram | Visibility fan-out per broadcast. |
| `arena_combat_attack_duration_seconds_bucket` | histogram | Melee/ranged attack handler duration. |
| `arena_combat_spell_duration_seconds_bucket` | histogram | Spell cast handler duration. |
| `arena_map_move_duration_seconds_bucket` | histogram | Movement handler duration. |

Map and character IDs are deliberately NOT tagged on these series.
Per-map alone would be ~290 series × every metric, and per-character
would be unbounded. If a per-map drill-down becomes necessary, add a
separate exporter with explicit allow-listing.

### Shutdown

| Metric | Type | What it means |
| --- | --- | --- |
| `arena_shutdown_shutdown_started_total` | counter | Graceful-shutdown initiations. |
| `arena_shutdown_drain_timeout_total` | counter | Drain windows that hit the timeout before completion. |

---

## Alert thresholds (suggested)

Tune against real traffic — these are starting points.

- `rate(arena_session_backpressure_events_total{cause="send_timeout"}[5m]) > 0.1`
  — sustained `send_timeout` means a bucket of clients can't drain at the
  rate the server pushes; investigate slow-client or NIC issues.
- `rate(arena_persistence_autosave_events_total{event="error"}[5m]) > 0`
  — autosave write failures should be zero in steady state.
- `histogram_quantile(0.99, sum by (le) (rate(arena_map_tick_duration_seconds_bucket[5m]))) > 0.05`
  — p99 tick > 50ms is the start of perceptible lag.
- `rate(arena_shutdown_drain_timeout_total[5m]) > 0` — the shutdown drain
  is timing out, sessions are being dropped uncleanly.

---

## Adding a metric

1. Emit a `:telemetry.execute([:arena, :something, :event], measurements, metadata)` from the code path.
2. Add a `Telemetry.Metrics.{counter,distribution,sum,last_value}` definition in `Arena.PromEx.metrics/0`.
3. If metadata has optional keys, add a `tag_values` normalizer that defaults missing keys (otherwise Telemetry.Metrics drops the event).
4. Mind cardinality: never tag with `character_id`, `map_id`, or any unbounded value.

---

## Pointers

- Reporter module: `server/apps/arena/lib/arena/prom_ex.ex`
- HTTP handler: `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/metrics_handler.ex`
- Tests: `server/apps/arena/test/prom_ex_test.exs`
- Bot profiles: `server/apps/bot_army/lib/bot_army/bot.ex`
- Soak driver: `server/apps/bot_army/lib/mix/tasks/bench_soak.ex`
