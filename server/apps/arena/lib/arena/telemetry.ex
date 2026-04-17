defmodule Arena.Telemetry do
  @moduledoc """
  Telemetry event definitions for the arena.

  ## Event Reference

  ### Map ticks
  - `[:arena, :map, :tick]` — periodic map tick (npc_ai, buff, regen)
    - Measurements: `duration` (native), `queue_len`, `players`, `npcs`
    - Metadata: `map_id`, `tick_type` (:npc_ai | :buff | :regen)

  ### Movement
  - `[:arena, :map, :move]` — player movement request
    - Measurements: `duration` (native)
    - Metadata: `map_id`, `result` (:ok | :blocked | :speed_hack | :paralyzed | :too_early)

  ### Broadcasts
  - `[:arena, :map, :broadcast]` — visibility broadcast
    - Measurements: `recipients`
    - Metadata: `map_id`, `kind` (:move | :chat | :combat | :spawn | :other)

  ### Combat
  - `[:arena, :combat, :attack]` — melee/ranged attack
    - Measurements: `duration` (native)
    - Metadata: `map_id`, `result` (:ok | :cooldown | :dead | :paralyzed | :mounted)

  - `[:arena, :combat, :spell]` — spell cast
    - Measurements: `duration` (native)
    - Metadata: `map_id`, `result` (:ok | :cooldown | :dead | :paralyzed | error atom)

  ### Persistence
  - `[:arena, :persistence, :autosave]` — character autosave
    - Measurements: `duration` (native)
    - Metadata: `char_id`, `result` (:ok | :error)

  - `[:arena, :persistence, :cleanup]` — session cleanup save
    - Measurements: `duration` (native)
    - Metadata: `char_id`, `result` (:ok | :error | :not_found)

  - `[:arena, :persistence, :bank]` — bank DB operation
    - Measurements: `duration` (native)
    - Metadata: `operation` (:open | :deposit | :withdraw | :deposit_gold | :extract_gold),
                `result` (:ok | :error)

  - `[:arena, :persistence, :guild_write]` — guild fire-and-forget DB write
    - Measurements: `duration` (native)
    - Metadata: `operation`, `result` (:ok | :error)

  ### Sessions
  - `[:arena, :session, :crash_cleanup]` — SessionMonitor crash cleanup
    - Measurements: `count` (always 1)
    - Metadata: `char_id`

  - `[:arena, :session, :login]` — successful login
    - Measurements: `count` (always 1)
    - Metadata: `char_id`, `map_id`
  """

  @doc "Emit a telemetry event. Thin wrapper for discoverability."
  defdelegate execute(event, measurements, metadata), to: :telemetry

  @doc "Convenience: measure a function's duration and emit the event."
  def span(event, metadata, fun) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start
    :telemetry.execute(event, %{duration: duration}, metadata)
    result
  end
end
