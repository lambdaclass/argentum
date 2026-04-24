defmodule AoSession.Egress do
  @moduledoc """
  Per-session bounded outbound queue.

  Owns the only path from a producer to a client socket. Producers call
  `enqueue/2` with an `%AoSession.Outbound{}`; the session loop calls
  `flush/2` to drain into the transport. Nothing else sends to a session's
  socket directly.

  ## State

    * `critical_q` — FIFO of packets that must be delivered. Bounded by
      `:critical_max`; overflow triggers disconnect (no silent drop allowed).
    * `coalesce_map` — `%{key => %Outbound{}}` holding the most recent
      coalescing packet per key. Older samples overwritten in place.
    * `coalesce_order` — FIFO of keys for flush ordering (oldest-update-first).
    * `lossy_q` — FIFO of droppable packets. Bounded by `:lossy_max`; overflow
      drops oldest.
    * `queued_bytes` — sum of payload bytes across all three queues.
    * `dropped_lossy` / `dropped_coalesce_replaced` / telemetry counters.

  ## Pressure

  `pressure_level/1` returns `:ok | :warn | :high | :critical` based on
  byte budget and critical-queue depth. Producers consult the pressure
  registry (cheap ETS read) before doing expensive work; they do not poll
  this module directly.

  Pure state module — no processes, no sockets. The session loop owns the
  struct and performs side effects (socket writes, telemetry emits,
  disconnect decisions).
  """

  alias AoSession.Outbound

  @type key :: term()

  @enforce_keys [:session_id, :limits]
  defstruct session_id: nil,
            limits: %{},
            critical_q: :queue.new(),
            critical_depth: 0,
            coalesce_map: %{},
            coalesce_order: :queue.new(),
            lossy_q: :queue.new(),
            lossy_depth: 0,
            queued_bytes: 0,
            dropped_lossy: 0,
            dropped_coalesce_replaced: 0,
            shed_events: 0

  @type t :: %__MODULE__{
          session_id: term(),
          limits: map(),
          critical_q: :queue.queue(Outbound.t()),
          critical_depth: non_neg_integer(),
          coalesce_map: %{optional(key()) => Outbound.t()},
          coalesce_order: :queue.queue(key()),
          lossy_q: :queue.queue(Outbound.t()),
          lossy_depth: non_neg_integer(),
          queued_bytes: non_neg_integer(),
          dropped_lossy: non_neg_integer(),
          dropped_coalesce_replaced: non_neg_integer(),
          shed_events: non_neg_integer()
        }

  @type pressure :: :ok | :warn | :high | :critical

  @default_limits %{
    # soft byte budget — lossy shedding kicks in above this
    soft_bytes: 64 * 1024,
    # hard byte budget — coalesce shedding + warn telemetry
    hard_bytes: 256 * 1024,
    # critical-queue disconnect threshold
    critical_max: 2_000,
    # lossy-queue drop-oldest threshold
    lossy_max: 500
  }

  @doc "Build a fresh egress state for a session."
  @spec new(term(), map()) :: t()
  def new(session_id, overrides \\ %{}) do
    %__MODULE__{session_id: session_id, limits: Map.merge(@default_limits, overrides)}
  end

  @doc """
  Producer-facing API: send an envelope to the session identified by `pid`.

  Fire-and-forget. The session loop receives an `{:egress, %Outbound{}}`
  message and runs the enqueue/flush cycle in its own process. Returns `:ok`
  whether the session applies, drops, coalesces, or disconnects — the
  producer never blocks on downstream pressure.

  Callers that classify per-packet should construct the envelope with
  `Outbound.critical/1`, `Outbound.lossy/1`, `Outbound.coalesce/2`, or
  `Outbound.from_class/3` (bridging a `AoProtocol.Classify.class_for/1`
  result). Do not invent ad-hoc tuple formats in producer modules.
  """
  @spec enqueue(pid(), Outbound.t()) :: :ok
  def enqueue(pid, %Outbound{} = out) when is_pid(pid) do
    send(pid, {:egress, out})
    :ok
  end

  @doc "Producer-facing API: enqueue a list of envelopes to a session."
  @spec enqueue_many(pid(), [Outbound.t()]) :: :ok
  def enqueue_many(pid, outs) when is_pid(pid) and is_list(outs) do
    Enum.each(outs, &enqueue(pid, &1))
  end

  @doc """
  Session-loop internal: apply an envelope to the egress state.

  Returns `{:ok, state}` on success or `{:disconnect, reason, state}` if the
  critical queue has overflowed — the session loop must tear down the
  connection with the given reason.
  """
  @spec push(t(), Outbound.t()) ::
          {:ok, t()} | {:disconnect, :critical_overflow, t()}
  def push(%__MODULE__{} = state, %Outbound{class: :critical} = out) do
    new_depth = state.critical_depth + 1

    if new_depth > state.limits.critical_max do
      {:disconnect, :critical_overflow, state}
    else
      {:ok,
       %{
         state
         | critical_q: :queue.in(out, state.critical_q),
           critical_depth: new_depth,
           queued_bytes: state.queued_bytes + out.bytes
       }}
    end
  end

  def push(%__MODULE__{} = state, %Outbound{class: :lossy} = out) do
    state =
      if state.lossy_depth >= state.limits.lossy_max do
        drop_oldest_lossy(state)
      else
        state
      end

    {:ok,
     %{
       state
       | lossy_q: :queue.in(out, state.lossy_q),
         lossy_depth: state.lossy_depth + 1,
         queued_bytes: state.queued_bytes + out.bytes
     }}
  end

  def push(%__MODULE__{} = state, %Outbound{class: :coalesce, coalesce_key: key} = out)
      when not is_nil(key) do
    case Map.fetch(state.coalesce_map, key) do
      {:ok, prev} ->
        {:ok,
         %{
           state
           | coalesce_map: Map.put(state.coalesce_map, key, out),
             queued_bytes: state.queued_bytes - prev.bytes + out.bytes,
             dropped_coalesce_replaced: state.dropped_coalesce_replaced + 1
         }}

      :error ->
        {:ok,
         %{
           state
           | coalesce_map: Map.put(state.coalesce_map, key, out),
             coalesce_order: :queue.in(key, state.coalesce_order),
             queued_bytes: state.queued_bytes + out.bytes
         }}
    end
  end

  @doc """
  Drain queued packets into a reverse-ordered binary list.

  Returns `{binaries, state}` where `binaries` is a list of payloads in send
  order. Critical first, then coalesced (oldest-update-first), then lossy.
  Session loop writes the binaries and updates state.
  """
  @spec flush(t(), pos_integer()) :: {[binary()], t()}
  def flush(%__MODULE__{} = state, max_packets) when max_packets > 0 do
    {crit, state} = take_critical(state, max_packets, [])
    remaining = max_packets - length(crit)

    {coal, state} =
      if remaining > 0, do: take_coalesce(state, remaining, []), else: {[], state}

    remaining = remaining - length(coal)

    {lossy, state} =
      if remaining > 0, do: take_lossy(state, remaining, []), else: {[], state}

    {crit ++ coal ++ lossy, state}
  end

  defp take_critical(state, 0, acc), do: {Enum.reverse(acc), state}

  defp take_critical(state, n, acc) do
    case :queue.out(state.critical_q) do
      {:empty, _} ->
        {Enum.reverse(acc), state}

      {{:value, out}, q} ->
        state = %{
          state
          | critical_q: q,
            critical_depth: state.critical_depth - 1,
            queued_bytes: state.queued_bytes - out.bytes
        }

        take_critical(state, n - 1, [out.payload | acc])
    end
  end

  defp take_coalesce(state, 0, acc), do: {Enum.reverse(acc), state}

  defp take_coalesce(state, n, acc) do
    case :queue.out(state.coalesce_order) do
      {:empty, _} ->
        {Enum.reverse(acc), state}

      {{:value, key}, order_q} ->
        case Map.pop(state.coalesce_map, key) do
          {nil, _} ->
            take_coalesce(%{state | coalesce_order: order_q}, n, acc)

          {out, map} ->
            state = %{
              state
              | coalesce_order: order_q,
                coalesce_map: map,
                queued_bytes: state.queued_bytes - out.bytes
            }

            take_coalesce(state, n - 1, [out.payload | acc])
        end
    end
  end

  defp take_lossy(state, 0, acc), do: {Enum.reverse(acc), state}

  defp take_lossy(state, n, acc) do
    case :queue.out(state.lossy_q) do
      {:empty, _} ->
        {Enum.reverse(acc), state}

      {{:value, out}, q} ->
        state = %{
          state
          | lossy_q: q,
            lossy_depth: state.lossy_depth - 1,
            queued_bytes: state.queued_bytes - out.bytes
        }

        take_lossy(state, n - 1, [out.payload | acc])
    end
  end

  defp drop_oldest_lossy(state) do
    case :queue.out(state.lossy_q) do
      {:empty, _} ->
        state

      {{:value, dropped}, q} ->
        %{
          state
          | lossy_q: q,
            lossy_depth: state.lossy_depth - 1,
            queued_bytes: state.queued_bytes - dropped.bytes,
            dropped_lossy: state.dropped_lossy + 1,
            shed_events: state.shed_events + 1
        }
    end
  end

  @doc """
  Classify current pressure purely from byte budget and critical depth.

  Consumed by the session loop (to decide whether to publish a new level to
  the pressure registry) and by tests.
  """
  @spec pressure_level(t()) :: pressure()
  def pressure_level(%__MODULE__{} = state) do
    %{soft_bytes: soft, hard_bytes: hard, critical_max: cmax} = state.limits
    crit = state.critical_depth

    cond do
      crit >= div(cmax * 9, 10) -> :critical
      state.queued_bytes >= hard -> :high
      state.queued_bytes >= soft -> :warn
      crit >= div(cmax, 2) -> :warn
      true -> :ok
    end
  end

  @doc "Total queued packets across all classes (for telemetry / tests)."
  @spec total_queued(t()) :: non_neg_integer()
  def total_queued(%__MODULE__{} = s) do
    s.critical_depth + s.lossy_depth + map_size(s.coalesce_map)
  end

  @doc "True when no packets are queued."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = s), do: total_queued(s) == 0
end
