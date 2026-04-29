defmodule Arena.Clock do
  @moduledoc """
  Monotonic clock shim. Production code reads `now_ms/0` instead of
  `System.monotonic_time(:millisecond)` directly so tests can freeze
  time via `Process.put(:arena_clock_ms, _)`.

  Production behaviour: identical to `System.monotonic_time/1`.
  Test behaviour: returns the integer stored in the process dictionary.
  """

  @spec now_ms() :: integer()
  def now_ms do
    case Process.get(:arena_clock_ms) do
      nil -> System.monotonic_time(:millisecond)
      ms when is_integer(ms) -> ms
    end
  end
end
