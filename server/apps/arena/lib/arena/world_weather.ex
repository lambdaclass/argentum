defmodule Arena.WorldWeather do
  @moduledoc """
  Global weather state for the server.

  In VB6, rain is a world-wide toggle: when a GM issues the rain command,
  every connected player receives the rain_toggle packet regardless of which
  map they are on.
  """

  use GenServer

  alias AoProtocol.Server.Encoder

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Toggle rain on/off globally. Returns the new rain state (:on | :off)."
  def toggle_rain do
    GenServer.call(__MODULE__, :toggle_rain)
  end

  @doc "Query current rain state."
  def raining? do
    GenServer.call(__MODULE__, :raining?)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{rain: false}}
  end

  @impl true
  def handle_call(:toggle_rain, _from, state) do
    new_rain = not state.rain
    state = %{state | rain: new_rain}

    raw = Encoder.encode({:rain_toggle, %{raining: new_rain}})
    AoSession.OnlineDirectory.broadcast_all({:send_raw, raw})

    {:reply, new_rain, state}
  end

  @impl true
  def handle_call(:raining?, _from, state) do
    {:reply, state.rain, state}
  end
end
