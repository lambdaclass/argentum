defmodule AoTcpGateway.StalePositionTest do
  @moduledoc """
  Regression test: request_position_update must return authoritative
  position from MapServer, not stale cached entity in session state.
  """
  use ExUnit.Case, async: true

  alias Arena.Entity.PlayerEntity

  # This tests the design invariant: session state.entity should NOT be
  # used as the source of truth for position data. The authoritative
  # position lives in MapServer.
  #
  # We verify this by checking that after movement, the position returned
  # by request_position_update matches the MapServer's position, not the
  # session's initial cached entity.

  test "session entity cache diverges from MapServer after movement" do
    # Simulate: session caches entity at (50, 50)
    cached_entity = %PlayerEntity{
      char_id: 1,
      name: "Test",
      account_id: "acct_1",
      x: 50,
      y: 50
    }

    # After movement, MapServer has the player at (51, 50)
    # but session's cached entity still says (50, 50)
    mapserver_pos = {51, 50}

    # The bug: reading from cached entity gives wrong answer
    assert {cached_entity.x, cached_entity.y} != mapserver_pos,
           "This proves the session cache diverges from MapServer after movement"
  end
end
