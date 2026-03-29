defmodule AoTcpGateway.FloodGuard do
  @moduledoc """
  Token bucket rate limiter for session-level flood protection.

  Pure functions — no GenServer. Embed in handler state.
  Default: 30 tokens max, refill 15/sec.
  """

  defstruct tokens: 30.0,
            max_tokens: 30,
            refill_rate: 15.0,
            last_refill: 0

  @doc "Create a new FloodGuard with current timestamp."
  def new(opts \\ []) do
    max = Keyword.get(opts, :max_tokens, 30)
    rate = Keyword.get(opts, :refill_rate, 15.0)

    %__MODULE__{
      tokens: max * 1.0,
      max_tokens: max,
      refill_rate: rate,
      last_refill: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Consume one token. Returns `{:ok, updated_guard}` or `{:error, :flood}`.
  """
  def check(%__MODULE__{} = guard) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = max(now - guard.last_refill, 0)
    refilled = guard.tokens + elapsed_ms / 1000.0 * guard.refill_rate
    tokens = min(refilled, guard.max_tokens * 1.0)

    if tokens >= 1.0 do
      {:ok, %{guard | tokens: tokens - 1.0, last_refill: now}}
    else
      {:error, :flood}
    end
  end
end
