defmodule Arena.Rng do
  @moduledoc """
  RNG shim. Production code reads `uniform/0,1` instead of `:rand.uniform`
  directly so tests can install a deterministic strategy via
  `Process.put(:arena_test_rng, fn)`.

  Production behaviour: identical to `:rand.uniform/0,1`.
  Test behaviour: invokes the stored function with the upper bound
  (or `nil` for the unit form). Tests typically install a list-driven
  consumer (`Arena.Test.Rng.list/1`).

  `Enum.random/1` and `Enum.shuffle/1` are NOT shimmed in this slice —
  see the `Arena.Test.Rng` companion for guidance on the few
  Enum-based call sites that matter (gamble payouts, AoE target order).
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
end
