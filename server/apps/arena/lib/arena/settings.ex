defmodule Arena.Settings do
  @moduledoc """
  Runtime-tunable server settings backed by ETS.

  Provides a central registry of settings that can be changed at runtime
  (e.g., by GM commands or admin API) without redeployment. Handlers read
  settings via `get/2` which does a fast ETS lookup with a compile-time default.

  ## Usage

      Arena.Settings.get(:xp_multiplier)   # => 1.0 (default)
      Arena.Settings.set(:xp_multiplier, 2.0)
      Arena.Settings.get(:xp_multiplier)   # => 2.0
      Arena.Settings.reset(:xp_multiplier) # => back to 1.0
  """

  use GenServer

  @table :arena_settings

  # Default values for all tunable settings.
  # Adding a new setting only requires adding it here.
  @defaults %{
    # Gameplay multipliers
    xp_multiplier: 1.0,
    gold_multiplier: 1.0,
    drop_rate_multiplier: 1.0,

    # Timing (ms)
    chat_cooldown_ms: 1000,
    attack_cooldown_ms: 1500,
    item_use_cooldown_ms: 500,
    regen_tick_ms: 3000,

    # Speed hack detection
    speed_hack_threshold: 3.0,

    # Movement
    base_walk_interval_ms: 210,

    # Combat
    max_level: 50,

    # Status ticks
    hunger_thirst_damage: 5,
    thirst_drain_interval: 54,
    hunger_drain_interval: 60,
    hunger_thirst_drain_amount: 10
  }

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get a setting value. Falls back to compile-time default."
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> fallback_value(key, default)
    end
  rescue
    ArgumentError -> fallback_value(key, default)
  end

  @doc "Set a runtime setting."
  @spec set(atom(), term()) :: :ok
  def set(key, value) do
    GenServer.call(__MODULE__, {:set, key, value})
  end

  @doc "Reset a setting to its default value."
  @spec reset(atom()) :: :ok
  def reset(key) do
    GenServer.call(__MODULE__, {:reset, key})
  end

  @doc "Reset all settings to defaults."
  @spec reset_all() :: :ok
  def reset_all do
    GenServer.call(__MODULE__, :reset_all)
  end

  @doc "List all settings with their current values."
  @spec all() :: map()
  def all do
    overrides = :ets.tab2list(@table) |> Map.new()
    Map.merge(@defaults, overrides)
  rescue
    ArgumentError -> @defaults
  end

  @doc "Return the compiled default for a setting."
  @spec default(atom()) :: term() | nil
  def default(key), do: Map.get(@defaults, key)

  @doc "Return all compiled defaults."
  @spec defaults() :: map()
  def defaults, do: @defaults

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:set, key, value}, _from, state) do
    :ets.insert(@table, {key, value})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:reset, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset_all, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp fallback_value(key, nil), do: Map.get(@defaults, key)
  defp fallback_value(_key, default), do: default
end
