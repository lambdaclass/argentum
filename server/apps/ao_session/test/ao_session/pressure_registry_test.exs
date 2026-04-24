defmodule AoSession.PressureRegistryTest do
  use ExUnit.Case, async: false

  alias AoSession.PressureRegistry

  setup do
    session_id = {:test, System.unique_integer([:positive])}
    on_exit(fn -> PressureRegistry.clear(session_id) end)
    %{session_id: session_id}
  end

  test "missing session reads as :ok", %{session_id: id} do
    assert PressureRegistry.get(id) == :ok
  end

  test "publish/get round-trip", %{session_id: id} do
    assert :ok = PressureRegistry.publish(id, :warn)
    assert PressureRegistry.get(id) == :warn

    assert :ok = PressureRegistry.publish(id, :critical)
    assert PressureRegistry.get(id) == :critical
  end

  test "clear removes entry", %{session_id: id} do
    PressureRegistry.publish(id, :high)
    assert PressureRegistry.get(id) == :high
    PressureRegistry.clear(id)
    assert PressureRegistry.get(id) == :ok
  end

  test "sessions are independent" do
    a = {:a, System.unique_integer([:positive])}
    b = {:b, System.unique_integer([:positive])}
    PressureRegistry.publish(a, :warn)
    PressureRegistry.publish(b, :critical)
    assert PressureRegistry.get(a) == :warn
    assert PressureRegistry.get(b) == :critical
    PressureRegistry.clear(a)
    PressureRegistry.clear(b)
  end
end
