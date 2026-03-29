defmodule Arena.Metrics do
  @moduledoc """
  Lock-free broadcast counters for benchmark instrumentation.
  Uses :atomics for zero-contention concurrent increments from MapServer processes.
  """

  # Indices: 1=move_broadcasts, 2=move_recipients, 3=chat_broadcasts, 4=chat_recipients
  @move_broadcasts 1
  @move_recipients 2
  @chat_broadcasts 3
  @chat_recipients 4

  @doc "Initialize the counters. Call once at application start."
  def setup do
    ref = :atomics.new(4, signed: false)
    :persistent_term.put(:arena_metrics, ref)
    :ok
  end

  @doc "Record a move broadcast with the given recipient count."
  def inc_move(recipients) do
    ref = :persistent_term.get(:arena_metrics, nil)
    if ref do
      :atomics.add(ref, @move_broadcasts, 1)
      :atomics.add(ref, @move_recipients, recipients)
    end
  end

  @doc "Record a chat broadcast with the given recipient count."
  def inc_chat(recipients) do
    ref = :persistent_term.get(:arena_metrics, nil)
    if ref do
      :atomics.add(ref, @chat_broadcasts, 1)
      :atomics.add(ref, @chat_recipients, recipients)
    end
  end

  @doc "Read current counter values."
  def snapshot do
    case :persistent_term.get(:arena_metrics, nil) do
      nil ->
        %{move_broadcasts: 0, move_recipients: 0, chat_broadcasts: 0, chat_recipients: 0}

      ref ->
        %{
          move_broadcasts: :atomics.get(ref, @move_broadcasts),
          move_recipients: :atomics.get(ref, @move_recipients),
          chat_broadcasts: :atomics.get(ref, @chat_broadcasts),
          chat_recipients: :atomics.get(ref, @chat_recipients)
        }
    end
  end

  @doc "Reset all counters to zero."
  def reset do
    case :persistent_term.get(:arena_metrics, nil) do
      nil -> :ok
      ref ->
        for i <- 1..4, do: :atomics.put(ref, i, 0)
        :ok
    end
  end
end
