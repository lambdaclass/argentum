defmodule Arena.PromEx do
  @moduledoc """
  Prometheus reporter for Arena telemetry events.

  Subscribes to the telemetry events emitted across the umbrella
  (`[:arena, :session, :backpressure]`, `[:arena, :persistence, :autosave]`,
  `[:arena, :map, :tick]`, etc.) and exposes them in Prometheus exposition
  format via `scrape/0`.

  Started as a child of `Arena.Application`. The HTTP `/metrics` endpoint
  that calls `scrape/0` is wired separately in `AoTcpGateway.Application`'s
  Cowboy router (gateway owns the listener).

  ### Tag cardinality

  We deliberately skip `character_id` and `map_id` from tag sets. Per-player
  series would explode (thousands of active sessions), and per-map series
  would be ~290 × every metric. The metrics that need a per-map view are
  intentionally aggregated globally; if dashboards later need per-map
  drill-down, add a separate exporter with explicit allow-listing.

  ### Buckets

  Distribution buckets are tuned for the observed distributions:
  - autosave duration: ms-to-second range
  - cleanup duration: similar
  - map tick duration: sub-ms to tens of ms
  - combat duration: sub-ms
  - backpressure depths: queue-size scale
  """

  alias Telemetry.Metrics

  @doc "Telemetry metric definitions exposed by this reporter."
  def metrics do
    [
      # ---- Backpressure ----
      Metrics.counter("arena.session.backpressure.events.total",
        event_name: [:arena, :session, :backpressure],
        description: "Backpressure events grouped by cause and action.",
        tags: [:cause, :action, :transport],
        tag_values: &normalize_backpressure_tags/1
      ),
      Metrics.distribution("arena.session.backpressure.critical_depth",
        event_name: [:arena, :session, :backpressure],
        measurement: :critical_depth,
        description: "Critical-queue depth observed at backpressure event.",
        reporter_options: [buckets: [0, 10, 50, 100, 250, 500, 1000, 2000]],
        tags: [:cause],
        tag_values: &normalize_backpressure_tags/1,
        keep: fn meta -> Map.has_key?(meta, :cause) end
      ),
      Metrics.distribution("arena.session.backpressure.queued_bytes",
        event_name: [:arena, :session, :backpressure],
        measurement: :queued_bytes,
        description: "Queued egress bytes at pressure-level transition.",
        reporter_options: [
          buckets: [1024, 16384, 65536, 262144, 1_048_576, 4_194_304]
        ]
      ),
      Metrics.distribution("arena.session.backpressure.mailbox_len",
        event_name: [:arena, :session, :backpressure],
        measurement: :mailbox_len,
        description: "Process mailbox length at backpressure trigger.",
        reporter_options: [buckets: [0, 100, 500, 1000, 2500, 5000, 10000]]
      ),

      # ---- Persistence: autosave ----
      Metrics.counter("arena.persistence.autosave.events.total",
        event_name: [:arena, :persistence, :autosave],
        description: "Autosave lifecycle events (submitted, started, ok, error, coalesced).",
        tags: [:event],
        tag_values: &normalize_autosave_tags/1
      ),
      Metrics.distribution("arena.persistence.autosave.duration.seconds",
        event_name: [:arena, :persistence, :autosave],
        measurement: :duration,
        description: "Autosave write duration (only :ok/:error events).",
        unit: {:native, :second},
        reporter_options: [
          buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0]
        ],
        tags: [:event],
        tag_values: &normalize_autosave_tags/1,
        keep: fn meta -> meta[:event] in [:ok, :error] end
      ),

      # ---- Persistence: cleanup ----
      Metrics.distribution("arena.persistence.cleanup.duration.seconds",
        event_name: [:arena, :persistence, :cleanup],
        measurement: :duration,
        description: "Cleanup-save duration on logout/disconnect.",
        unit: {:native, :second},
        reporter_options: [
          buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0]
        ],
        tags: [:result],
        tag_values: &normalize_cleanup_tags/1
      ),
      Metrics.counter("arena.persistence.cleanup_save_failed.total",
        event_name: [:arena, :persistence, :cleanup_save_failed],
        description: "Final-save failures during session cleanup."
      ),

      # ---- Sessions ----
      Metrics.counter("arena.session.login.total",
        event_name: [:arena, :session, :login],
        description: "Successful logins."
      ),
      Metrics.counter("arena.session.crash_cleanup.total",
        event_name: [:arena, :session, :crash_cleanup],
        description: "Sessions cleaned up after a crash."
      ),

      # ---- Map tick ----
      Metrics.distribution("arena.map.tick.duration.seconds",
        event_name: [:arena, :map, :tick],
        measurement: :duration,
        description: "Map tick processing duration by tick type.",
        unit: {:native, :second},
        reporter_options: [
          buckets: [0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5]
        ],
        tags: [:tick_type],
        tag_values: &normalize_tick_tags/1
      ),
      Metrics.distribution("arena.map.tick.queue_len",
        event_name: [:arena, :map, :tick],
        measurement: :queue_len,
        description: "MapServer GenServer mailbox length at tick.",
        reporter_options: [buckets: [0, 10, 50, 100, 500, 1000]],
        tags: [:tick_type],
        tag_values: &normalize_tick_tags/1
      ),

      # ---- Map broadcasts ----
      Metrics.distribution("arena.map.broadcast.recipients",
        event_name: [:arena, :map, :broadcast],
        measurement: :recipients,
        description: "Recipients per map broadcast (visibility fan-out).",
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 200]]
      ),

      # ---- Combat hot path ----
      Metrics.distribution("arena.combat.attack.duration.seconds",
        event_name: [:arena, :combat, :attack],
        measurement: :duration,
        description: "Melee/ranged attack handler duration.",
        unit: {:native, :second},
        reporter_options: [
          buckets: [0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1]
        ]
      ),
      Metrics.distribution("arena.combat.spell.duration.seconds",
        event_name: [:arena, :combat, :spell],
        measurement: :duration,
        description: "Spell cast handler duration.",
        unit: {:native, :second},
        reporter_options: [
          buckets: [0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1]
        ]
      ),

      # ---- Movement ----
      Metrics.distribution("arena.map.move.duration.seconds",
        event_name: [:arena, :map, :move],
        measurement: :duration,
        description: "Movement-request handler duration.",
        unit: {:native, :second},
        reporter_options: [
          buckets: [0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05]
        ]
      ),

      # ---- Shutdown ----
      Metrics.counter("arena.shutdown.shutdown_started.total",
        event_name: [:arena, :shutdown, :shutdown_started],
        description: "Graceful shutdown initiations."
      ),
      Metrics.counter("arena.shutdown.drain_timeout.total",
        event_name: [:arena, :shutdown, :drain_timeout],
        description: "Shutdown drains that timed out before completion."
      )
    ]
  end

  @doc "Reporter name passed to TelemetryMetricsPrometheus.Core."
  def reporter_name, do: __MODULE__

  @doc "Returns the Prometheus exposition-format scrape body."
  def scrape do
    TelemetryMetricsPrometheus.Core.scrape(reporter_name())
  end

  def child_spec(_opts) do
    TelemetryMetricsPrometheus.Core.child_spec(
      metrics: metrics(),
      name: reporter_name()
    )
  end

  # ---- Tag normalizers ----
  # Telemetry.Metrics requires every declared tag key to exist in metadata.
  # Some emit sites omit fields (e.g. critical-overflow has no :transport),
  # so we project metadata into a stable shape, defaulting missing keys.

  defp normalize_backpressure_tags(meta) do
    %{
      cause: Map.get(meta, :cause, :unknown),
      action: Map.get(meta, :action, :unknown),
      transport: Map.get(meta, :transport, :unknown)
    }
  end

  defp normalize_autosave_tags(meta) do
    %{event: Map.get(meta, :event, :unknown)}
  end

  defp normalize_cleanup_tags(meta) do
    %{result: Map.get(meta, :result, :unknown)}
  end

  defp normalize_tick_tags(meta) do
    %{tick_type: Map.get(meta, :tick_type, :unknown)}
  end
end
