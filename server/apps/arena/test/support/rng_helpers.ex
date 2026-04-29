defmodule Arena.Test.Rng do
  @moduledoc """
  Test-side RNG strategies for the `Arena.Rng` shim.

  Install with `Scenario.set_seed/2`, or directly via
  `Process.put(:arena_test_rng, strategy)` for non-scenario tests.
  """

  @doc "Return `value` for every `Arena.Rng.uniform/0,1` call."
  def constant(value) do
    fn _bound -> value end
  end

  @doc """
  Drive `Arena.Rng.uniform/0,1` from a list of values, in order. After
  the list is exhausted, raises. Handy for golden-fixture-style tests.

      Process.put(:arena_test_rng, Arena.Test.Rng.list([10, 80, 50]))
  """
  def list(values) when is_list(values) do
    pid = spawn_link(fn -> list_loop(values) end)

    fn _bound ->
      Kernel.send(pid, {:next, self()})

      receive do
        {:rng, value} -> value
      after
        100 -> raise "RNG list exhausted"
      end
    end
  end

  defp list_loop([]), do: raise("RNG list exhausted")

  defp list_loop([head | tail]) do
    receive do
      {:next, from} ->
        Kernel.send(from, {:rng, head})
        list_loop(tail)
    end
  end
end
