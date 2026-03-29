defmodule BotArmy.Swarm do
  @moduledoc """
  Manages spawning and killing bot processes via a DynamicSupervisor.
  """
  use GenServer

  require Logger

  # --- Public API ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Spawn `count` bots with sequential char_ids."
  def start(count, opts \\ []) do
    GenServer.call(__MODULE__, {:start, count, opts}, :infinity)
  end

  @doc "Stop all running bots."
  def stop_all do
    GenServer.call(__MODULE__, :stop_all, :infinity)
  end

  @doc "Return status of the swarm."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Return aggregate metrics from all bots."
  def metrics do
    GenServer.call(__MODULE__, :metrics, 30_000)
  end

  @doc "Reset metrics counters on all bots (clears warmup/connection noise)."
  def reset_metrics do
    GenServer.call(__MODULE__, :reset_metrics, 30_000)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{bots: %{}}}
  end

  # Spawn bots in batches to avoid DB pool saturation during login storm.
  @batch_size 100
  @batch_delay_ms 50

  @impl true
  def handle_call({:start, count, opts}, _from, state) do
    start_id = Keyword.get(opts, :start_id, 10_000)

    ids = for i <- 0..(count - 1), do: start_id + i
    batches = Enum.chunk_every(ids, @batch_size)

    new_bots =
      batches
      |> Enum.with_index()
      |> Enum.flat_map(fn {batch, batch_idx} ->
        if batch_idx > 0, do: Process.sleep(@batch_delay_ms)

        Enum.map(batch, fn char_id ->
          bot_opts = Keyword.merge(opts, char_id: char_id)

          case DynamicSupervisor.start_child(
                 BotArmy.BotSupervisor,
                 {BotArmy.Bot, bot_opts}
               ) do
            {:ok, pid} ->
              Process.monitor(pid)
              {pid, char_id}

            {:error, reason} ->
              Logger.warning("Failed to start bot #{char_id}: #{inspect(reason)}")
              {make_ref(), {:failed, char_id}}
          end
        end)
      end)
      |> Map.new()

    bots = Map.merge(state.bots, new_bots)
    started = Enum.count(new_bots, fn {_k, v} -> not match?({:failed, _}, v) end)
    Logger.info("Swarm: spawned #{started}/#{count} bots")
    {:reply, {:ok, started}, %{state | bots: bots}}
  end

  @impl true
  def handle_call(:stop_all, _from, state) do
    for {pid, _char_id} <- state.bots, is_pid(pid) and Process.alive?(pid) do
      DynamicSupervisor.terminate_child(BotArmy.BotSupervisor, pid)
    end

    Logger.info("Swarm: stopped all bots")
    {:reply, :ok, %{state | bots: %{}}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    total = map_size(state.bots)

    connected =
      Enum.count(state.bots, fn {pid, _} ->
        is_pid(pid) and Process.alive?(pid) and BotArmy.Bot.connected?(pid)
      end)

    {:reply, %{total: total, connected: connected, disconnected: total - connected}, state}
  end

  @impl true
  def handle_call(:metrics, _from, state) do
    bot_metrics =
      state.bots
      |> Enum.filter(fn {pid, _} -> is_pid(pid) and Process.alive?(pid) end)
      |> Enum.map(fn {pid, _} -> BotArmy.Bot.metrics(pid) end)

    total_packets = Enum.sum(Enum.map(bot_metrics, & &1.packets_in))
    total_bytes = Enum.sum(Enum.map(bot_metrics, & &1.bytes_in))
    all_rtt = Enum.flat_map(bot_metrics, & &1.rtt_samples)

    {:reply, %{packets_in: total_packets, bytes_in: total_bytes, rtt_samples: all_rtt}, state}
  end

  @impl true
  def handle_call(:reset_metrics, _from, state) do
    for {pid, _} <- state.bots, is_pid(pid) and Process.alive?(pid) do
      GenServer.cast(pid, :reset_metrics)
    end
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.get(state.bots, pid) do
      nil ->
        {:noreply, state}

      char_id ->
        unless reason == :normal do
          Logger.warning("Bot #{char_id} (#{inspect(pid)}) exited: #{inspect(reason)}")
        end

        {:noreply, %{state | bots: Map.delete(state.bots, pid)}}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
