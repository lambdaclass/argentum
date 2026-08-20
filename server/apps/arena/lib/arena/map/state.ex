defmodule Arena.Map.State do
  @moduledoc """
  Struct representing the state of a single map GenServer.

  Provides compile-time key safety and update helpers that eliminate
  the repeated `Map.put(state.players, id, entity)` / `%{state | players: ...}`
  boilerplate across handler modules.
  """

  @enforce_keys [:map_id]
  defstruct [
    # Core identity
    map_id: nil,
    loading: false,
    meta: %{},

    # Entities
    players: %{},
    sessions: %{},
    npcs_live: %{},
    npc_char_indices: %{},

    # Spatial
    occupancy: nil,
    visibility_mode: :global,
    grid: nil,
    visible_sets: nil,

    # World objects
    ground_items: %{},
    next_char_index: 1,

    # Process tracking
    monitors: %{},
    monitor_refs: %{},

    # Runtime state (previously added dynamically, now explicit)
    thirst_tick_counter: 0,
    hunger_tick_counter: 0,
    hunger_thirst_tick_counter: 0,
    penalty_tick_counter: 0,
    gm_blocked_tiles: MapSet.new(),
    triggers: %{},

    # Which generation of fast timers is current, and whether one is running.
    #
    # An empty map stops rearming its NPC, buff and regen timers entirely, and entry
    # arms them again. Between those two things a tick can already be in flight: it was
    # sent while the map still had a player, and it arrives after entry has armed a fresh
    # chain. Without a generation to compare against, that stale tick rearms itself and
    # the map runs two chains of the same timer forever — twice the wakeups, and a bug
    # that only shows up as a map that is inexplicably busier than its neighbours.
    #
    # Entry increments the generation, so a tick from an older one is dropped.
    fast_timer_gen: 0,
    fast_timers_armed: false,

    # Whether this map's process heap has been compacted since the map last became
    # empty. Set when we compact, cleared the moment a player enters. Without it an
    # empty map would either be compacted once per autosave forever, or not at all
    # on the paths that empty it without going through `leave` — a session crash
    # reaches `do_remove_player` through a monitor, not through the player.
    idle_compacted: false
  ]

  # -- Player helpers --

  def put_player(state, char_id, entity) do
    %{state | players: Map.put(state.players, char_id, entity)}
  end

  def update_player(state, char_id, fun) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} -> %{state | players: Map.put(state.players, char_id, fun.(entity))}
      :error -> state
    end
  end

  def delete_player(state, char_id) do
    %{state | players: Map.delete(state.players, char_id)}
  end

  # -- NPC helpers --

  def put_npc(state, instance_id, npc) do
    %{state | npcs_live: Map.put(state.npcs_live, instance_id, npc)}
  end

  def update_npc(state, instance_id, fun) do
    case Map.fetch(state.npcs_live, instance_id) do
      {:ok, npc} -> %{state | npcs_live: Map.put(state.npcs_live, instance_id, fun.(npc))}
      :error -> state
    end
  end

  def delete_npc(state, instance_id) do
    %{state | npcs_live: Map.delete(state.npcs_live, instance_id)}
  end

  # -- Meta helpers --

  def put_meta(state, key, value) do
    %{state | meta: Map.put(state.meta, key, value)}
  end

  # -- Ground items helpers --

  def put_ground_item(state, pos, item) do
    %{state | ground_items: Map.put(state.ground_items, pos, item)}
  end

  def delete_ground_item(state, pos) do
    %{state | ground_items: Map.delete(state.ground_items, pos)}
  end
end
