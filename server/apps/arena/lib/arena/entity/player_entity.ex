defmodule Arena.Entity.PlayerEntity do
  @moduledoc """
  Complete player entity state while online.

  Lives in MapServer state as `%{char_id => %PlayerEntity{}}`.
  Exported on map transfer/logout, imported on map enter/login.
  """

  defstruct [
    # Identity
    :char_id,
    :name,
    :account_id,

    # Position
    :x,
    :y,
    heading: :south,

    # Visual (display metadata for client packets)
    body_id: 1,
    base_body_id: 1,
    head_id: 1,

    # Vital stats
    hp: 100,
    max_hp: 100,
    mana: 100,
    max_mana: 100,
    stamina: 100,
    max_stamina: 100,
    hunger: 100,
    thirst: 100,

    # Character info
    level: 1,
    xp: 0,
    skill_points: 0,
    class: :warrior,
    race: :human,
    gender: :male,
    home_city: :ullathorpe,

    # Base attributes
    str: 18,
    agi: 18,
    int: 18,
    con: 18,
    cha: 18,

    # Gold
    gold: 0,

    # Inventory: list of 24 slots, each nil or %{item_id, amount, equipped}
    inventory: List.duplicate(nil, 24),

    # Equipment slots: %{weapon: item_id, armor: item_id, shield: item_id, helmet: item_id, ring: item_id}
    equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil, saddle: nil},

    # Skills: %{skill_id => value}
    skills: %{},

    # Known spells: list of spell_ids
    spells: [],

    # Buffs/debuffs: [%{type, remaining_ms, value}, ...]
    buffs: [],

    # Base min/max hit (character level-based damage, VB6: MinHIT/MaxHIT)
    min_hit: 0,
    max_hit: 0,

    # Attribute buff modifiers (from spells, temporary)
    str_buff: 0,
    agi_buff: 0,

    # Faction kill counters (persisted)
    faction_kills_royal: 0,
    faction_kills_chaos: 0,
    citizens_killed: 0,
    criminals_killed: 0,

    # Faction progression (persisted)
    faction_score: 0,
    faction_rank_armada: 0,
    faction_rank_chaos: 0,
    faction_reenlistadas: 0,

    # Lifetime counters (persisted, shown in mini_stats)
    npcs_killed: 0,
    deaths: 0,
    penalty: 0,
    fishing_points: 0,

    # Flags
    dead: false,
    poisoned: false,
    criminal: false,
    invisible: false,
    oculto: false,
    oculto_timer: 0,
    no_detectable: false,
    paralyzed: false,
    immobilized: false,
    meditating: false,
    resting: false,
    safe_mode: false,
    mounted: false,
    saddle_obj_index: 0,
    saddle_slot: 0,
    navigating: false,
    gm: false,
    faction: :none,

    # Cooldowns use System.monotonic_time(:millisecond).
    # Default to far-past so first action is always allowed.
    next_move_at: -1_000_000_000_000,
    next_attack_at: -1_000_000_000_000,
    next_spell_at: -1_000_000_000_000,
    next_item_use_at: -1_000_000_000_000,
    # VB6: per-spell-slot cooldowns — %{spell_slot => next_cast_at_ms}
    spell_cooldowns: %{},

    # Speed hack detection
    last_step_at: -1_000_000_000_000,
    speed_hack_counter: 0.0,
    speeding: 1.0,

    # Server-assigned index on this map (for AO20 packets)
    char_index: nil,

    # Map the player is on (for reference during export)
    map_id: nil,

    # Transient: NPC id of open shop (not persisted)
    commerce_npc_id: nil,
    # Transient: NPC id of open bank (not persisted)
    bank_npc_id: nil,
    # Transient: bank gold loaded during bank session
    bank_gold: 0,
    # Transient: user-to-user trade state (not persisted)
    trade_request_target: nil,
    trade_partner_id: nil,
    trade_offer_gold: 0,
    trade_offer_items: [],
    trade_accepted: false,

    # Pets: list of NPC instance IDs owned by this player (not persisted across sessions)
    pet_ids: [],

    # Player description (VB6: /DESC)
    description: "",

    # Chat moderation: mute expiry (monotonic ms, 0 = not muted)
    muted_until: 0,
    # Chat rate limit: last chat timestamp (monotonic ms, far-past = never)
    last_chat_at: -1_000_000_000_000,

    # Marriage: VB6 SpouseId (persisted char_id, 0 = not married)
    spouse_id: 0,
    # Transient: char_id of the player we proposed to (VB6: Candidato)
    marriage_proposal_target: nil,

    # Duel (reto) state — VB6: flags.EnReto, flags.SalaReto, etc.
    # in_duel: whether player is in an active duel
    in_duel: false,
    # duel_opponent_id: char_id of current duel opponent (nil when not dueling)
    duel_opponent_id: nil,

    # Gambling counters (persisted)
    gamble_wins: 0,
    gamble_losses: 0,
    gamble_plays: 0,
    active_quests: [],
    completed_quests: MapSet.new(),
    quest_npc_id: nil
  ]
end
