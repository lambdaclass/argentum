defmodule Arena.WorldWeather do
  @moduledoc """
  Global weather state for the server.

  In VB6, rain toggle is a world-wide command: when a GM issues `/LLUVIA`,
  it toggles both rain AND snow globally, broadcasts rain_toggle and
  snow_toggle packets to every connected player, and — when rain starts —
  also sends a thunder sound (wave 404) and a lightning flash screen
  (color 0xF5D3F3, duration 250ms).
  """

  use GenServer

  alias AoProtocol.Server.Encoder

  # VB6 constants for thunder/flash effects
  @thunder_wave_id 404
  @no_3d_sound 0
  @flash_color 0xF5D3F3
  @flash_duration 250

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Toggle rain on/off globally (VB6: HandleRainToggle).

  Toggles both rain and snow, broadcasts rain_toggle + snow_toggle to all
  connected players. When rain starts, also broadcasts thunder sound and
  lightning flash. Returns `{new_rain, new_snow}`.
  """
  def toggle_rain do
    GenServer.call(__MODULE__, :toggle_rain)
  end

  @doc "Query current rain state."
  def raining? do
    GenServer.call(__MODULE__, :raining?)
  end

  @doc "Query current snow state."
  def snowing? do
    GenServer.call(__MODULE__, :snowing?)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{rain: false, snow: false}}
  end

  @impl true
  def handle_call(:toggle_rain, _from, state) do
    new_rain = not state.rain
    new_snow = not state.snow
    state = %{state | rain: new_rain, snow: new_snow}

    # Always broadcast rain and snow toggle (VB6: SendData ToAll)
    rain_raw = Encoder.encode({:rain_toggle, %{raining: new_rain}})
    snow_raw = Encoder.encode({:snow_toggle, %{snowing: new_snow}})
    AoSession.OnlineDirectory.broadcast_all({:send_raw, rain_raw})
    AoSession.OnlineDirectory.broadcast_all({:send_raw, snow_raw})

    # When rain starts, send thunder sound + lightning flash (VB6 effects)
    if new_rain do
      thunder_raw =
        Encoder.encode(
          {:play_wave,
           %{wav: @thunder_wave_id, x: @no_3d_sound, y: @no_3d_sound}}
        )

      flash_raw =
        Encoder.encode(
          {:flash_screen, %{color: @flash_color, duration: @flash_duration}}
        )

      AoSession.OnlineDirectory.broadcast_all({:send_raw, thunder_raw})
      AoSession.OnlineDirectory.broadcast_all({:send_raw, flash_raw})
    end

    {:reply, {new_rain, new_snow}, state}
  end

  @impl true
  def handle_call(:raining?, _from, state) do
    {:reply, state.rain, state}
  end

  @impl true
  def handle_call(:snowing?, _from, state) do
    {:reply, state.snow, state}
  end
end
