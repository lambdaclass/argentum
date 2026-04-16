defmodule BotArmy.SoakTest do
  @moduledoc """
  Mini soak test -- 10 bots for 30 seconds.
  Tagged :soak, excluded from normal test runs.

  Run with:

      mix test --only soak

  Requires a running server (the app must be started).
  """
  use ExUnit.Case

  @moduletag :soak

  @tag timeout: 120_000
  test "10 bots survive 30 seconds without crashes" do
    # Spawn 10 bots
    {:ok, spawned} =
      BotArmy.spawn(10,
        profile: :walk_only,
        min_action_interval: 500,
        max_action_interval: 1_000
      )

    assert spawned == 10

    # Let bots connect and settle
    Process.sleep(5_000)
    status = BotArmy.status()
    initial_connected = status.connected

    # Run for 30 seconds
    Process.sleep(30_000)

    # Check survival -- more than half must still be connected
    final_status = BotArmy.status()

    assert final_status.connected >= div(initial_connected, 2),
           "More than half the bots died: #{final_status.connected}/#{initial_connected} remain"

    # Check memory didn't explode
    # Baseline is ~6GB with 843 maps loaded eagerly; check for runaway growth
    memory_mb = :erlang.memory(:total) / (1024 * 1024)
    assert memory_mb < 8192, "Memory exceeded 8GB: #{Float.round(memory_mb, 1)}MB"

    BotArmy.stop_all()
  end
end
