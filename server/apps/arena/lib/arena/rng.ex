defmodule Arena.Rng do
  @moduledoc """
  RNG shim. Production code reads `uniform/0,1` instead of `:rand.uniform`
  directly so tests can install a deterministic strategy via
  `Process.put(:arena_test_rng, fn)`.

  Production behaviour: identical to `:rand.uniform/0,1`.
  Test behaviour: invokes the stored function with the upper bound
  (or `nil` for the unit form). Tests typically install a list-driven
  consumer (`Arena.Test.Rng.list/1`).

  `Enum.shuffle/1` and list-form `Enum.random/1` (pick one element of a
  collection) are NOT shimmed in this slice — see the `Arena.Test.Rng`
  companion for guidance on the few Enum-based call sites that matter
  (gamble payouts, AoE target order). Use `between/2` for the common
  `Enum.random(min..max)` numeric-range form so parity-sensitive damage
  and roll calls stay deterministically testable.
  """

  @spec uniform() :: float()
  def uniform do
    case Process.get(:arena_test_rng) do
      nil -> :rand.uniform()
      fun when is_function(fun, 1) -> fun.(nil)
    end
  end

  @spec uniform(pos_integer()) :: pos_integer()
  def uniform(n) when is_integer(n) and n >= 1 do
    case Process.get(:arena_test_rng) do
      nil -> :rand.uniform(n)
      fun when is_function(fun, 1) -> fun.(n)
    end
  end

  @doc """
  Inclusive random integer in `min..max` — the shimmable replacement for
  `Enum.random(min..max)`. Routes through `uniform/1`, so a deterministic
  strategy installed via `Process.put(:arena_test_rng, fn)` drives it too.

  When `min == max` the result is `min` regardless of the strategy
  (`uniform(1)` is always `1`), matching `Enum.random(n..n)`.
  """
  @spec between(integer(), integer()) :: integer()
  def between(min, max) when is_integer(min) and is_integer(max) and min <= max do
    min - 1 + uniform(max - min + 1)
  end
end
