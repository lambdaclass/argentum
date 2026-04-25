defmodule Arena.PromExTest do
  @moduledoc """
  Verifies that Arena.PromEx subscribes to telemetry events and produces
  Prometheus-format output that includes our custom metric names.

  Async: false because telemetry handlers are global and we share the
  application-wide reporter started by Arena.Application.
  """

  use ExUnit.Case, async: false

  test "metrics/0 returns a non-empty list of Telemetry.Metrics structs" do
    metrics = Arena.PromEx.metrics()
    assert is_list(metrics)
    refute Enum.empty?(metrics)
    assert Enum.all?(metrics, &match?(%{__struct__: _}, &1))
  end

  test "scrape/0 returns Prometheus exposition text including our metric names" do
    # Emit one event of each shape so the scrape body has registered series.
    :telemetry.execute(
      [:arena, :session, :backpressure],
      %{critical_depth: 42},
      %{cause: :critical_overflow, action: :disconnect, transport: :tcp}
    )

    :telemetry.execute(
      [:arena, :persistence, :autosave],
      %{count: 1, duration: System.convert_time_unit(5, :millisecond, :native)},
      %{event: :ok, char_id: 1}
    )

    :telemetry.execute([:arena, :session, :login], %{count: 1}, %{})

    body = Arena.PromEx.scrape()
    assert is_binary(body)

    assert body =~ "arena_session_backpressure_events_total"
    assert body =~ "arena_persistence_autosave_events_total"
    assert body =~ "arena_session_login_total"
    # Help/HELP lines are part of valid exposition format
    assert body =~ "# HELP"
    assert body =~ "# TYPE"
  end

  test "backpressure tag normalizer fills in missing keys with :unknown" do
    # Some emit sites omit transport (e.g. mailbox check before pressure tracked).
    # The normalizer must default missing tags so the metric still records.
    :telemetry.execute(
      [:arena, :session, :backpressure],
      %{mailbox_len: 1234},
      %{cause: :mailbox_overflow, action: :warn}
    )

    body = Arena.PromEx.scrape()
    # The transport tag should appear with the "unknown" default rather
    # than dropping the event.
    assert body =~ ~s(transport="unknown")
  end
end
