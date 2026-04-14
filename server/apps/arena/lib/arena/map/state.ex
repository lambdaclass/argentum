defmodule Arena.Map.State do
  @moduledoc """
  Struct representing the state of a single map GenServer.

  Replaces the raw map that was previously used, providing compile-time
  key safety — any typo in a field name will be caught at compile time.
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
    triggers: %{}
  ]
end
