defmodule AoEntities.PlayerEntity do
  @moduledoc """
  Complete player entity state while online.

  Lives in MapServer state as `%{char_id => %PlayerEntity{}}`.
  Exported on map transfer/logout, imported on map enter/login.

  This struct lives in the ao_entities shared app so that both arena
  (runtime) and game_backend (persistence) can depend on it without
  creating a circular dependency.
  """

  @patron_tier_aventurero 6_057_393
  @patron_tier_heroe 6_057_394
  @patron_tier_leyenda 6_057_395

  @type user_tier :: :normal | :adventurer | :hero | :legend

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

    # VB6 Stats.UserAtributosBackUP — the character's base attribute
    # snapshot, used by strength/agility potions to clamp the bumped
    # value at backup * 2 and to restore on expiry.
    # InvUsuario.bas:1893-1922, General.bas:1278-1297.
    str_backup: 0,
    agi_backup: 0,

    # VB6 flags.DuracionEfecto / flags.TomoPocion — strength/agility
    # potion timer (seconds remaining) and "a potion is active" flag.
    # Ticked once per second by DuracionPociones (General.bas:1278).
    duracion_efecto: 0,
    tomo_pocion: false,
    # Drift #18 — how much of str_buff / agi_buff came from the active
    # potion, so it can be subtracted on expiry without clobbering
    # concurrent spell buffs.
    str_potion_delta: 0,
    agi_potion_delta: 0,

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
    blind: false,
    dumb: false,
    immobilized: false,
    meditating: false,
    resting: false,
    safe_mode: false,
    mounted: false,
    saddle_obj_index: 0,
    saddle_slot: 0,
    navigating: false,
    gm: false,
    # VB6 GM tiers: :admin, :dios, :semi_dios, :consejero, or nil (not GM)
    gm_level: nil,
    # VB6 Stats.tipoUsuario / account.is_active_patron
    user_tier: :normal,
    faction: :none,

    # Guild cache (populated on login, updated on guild join/leave/level-up)
    guild_id: 0,
    guild_level: 0,

    # Cooldowns use System.monotonic_time(:millisecond).
    # Default to far-past so first action is always allowed.
    next_move_at: -1_000_000_000_000,
    next_attack_at: -1_000_000_000_000,
    next_spell_at: -1_000_000_000_000,
    next_item_use_at: -1_000_000_000_000,
    # VB6: Counters.LastAttackTime — when this player last performed an attack (monotonic ms)
    last_attacked_at: -1_000_000_000_000,
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
    # Transient: NPC instance id of open shop (not persisted)
    commerce_npc_instance_id: nil,
    # Transient: NPC id of open bank (not persisted)
    bank_npc_id: nil,
    # Transient: NPC instance/type last selected with double-click (not persisted)
    last_clicked_npc_instance_id: nil,
    last_clicked_npc_type: nil,
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
    quest_npc_id: nil,

    # VB6 Modifiers: magic damage modifier (from effects over time / buffs)
    # GetMagicDamageModifier = max(1 + MagicDamageBonus, 0)
    magic_damage_modifier: 0.0,
    # GetMagicDamageReduction = max(1 - MagicDamageReduction, 0)
    magic_damage_reduction: 0.0,
    # VB6 flags.DivineBlood: when > 0, mortal HP potions and non-healing spells
    # are rejected (InvUsuario.bas:1925, modHechizos.bas:522).
    divine_blood: 0,
    # VB6 Modifiers.SelfHealingBonus (Single): additive bonus applied by
    # effects-over-time. GetSelfHealingBonus = max(1 + SelfHealingBonus, 0).
    # Default 0.0 -> multiplier 1.0. Modulo_UsUaRiOs.bas:3066.
    self_healing_bonus: 0.0,

    # Punishment record (VB6: prontuario) — persisted list of GM actions
    # Each entry: %{number: int, text: String.t(), date: String.t(), gm_name: String.t()}
    punishments: [],

    # VB6 parity: bank gold transfer cooldown (Counters.LastTransferGold)
    # Monotonic ms timestamp of last /BOVTRANSFERIR usage. 10s cooldown.
    last_transfer_gold_at: -1_000_000_000_000,

    # VB6: flags.ChatColor (Modulo_UsUaRiOs.bas:600-625) — RGB tuple used
    # for the speaker's chat-over-head color. Defaults to vbWhite (255,255,255);
    # role/faction-specific defaults are applied at login (see
    # GameBackend.Characters.to_entity). GMs can overwrite via /CHATCOLOR
    # (VB6 Protocol.bas:5548 HandleChatColor).
    chat_color: {255, 255, 255}
  ]

  @doc """
  VB6 parity: default chat colour for a character given role/council flag.

  Ported from Modulo_UsUaRiOs.bas:600-625. Role-based defaults (Admin, Dios,
  SemiDios, Consejero) are set first; faction-based defaults (council tints
  for e_Facciones.consejo / concilio) then override for council members.
  Non-council factions (Ciudadano, Armada, Criminal, Caos) stay vbWhite.
  """
  def default_chat_color(gm_level, council) do
    role_color =
      case gm_level do
        :admin -> {252, 195, 0}
        :dios -> {26, 209, 107}
        :semi_dios -> {60, 150, 60}
        :consejero -> {170, 170, 170}
        _ -> {255, 255, 255}
      end

    case council do
      :royal -> {66, 201, 255}
      :chaos -> {255, 102, 102}
      _ -> role_color
    end
  end

  @doc """
  Pack an {r, g, b} tuple into the VB6 RGB Long format
  (R + G*256 + B*65536) expected by chat_over_head and console packets.
  """
  def chat_color_to_int({r, g, b}) when is_integer(r) and is_integer(g) and is_integer(b) do
    rem(r, 256) + rem(g, 256) * 256 + rem(b, 256) * 65_536
  end

  def chat_color_to_int(_), do: 0x00FFFFFF

  def normalize_user_tier(:adventurer), do: :adventurer
  def normalize_user_tier(:hero), do: :hero
  def normalize_user_tier(:legend), do: :legend
  def normalize_user_tier(:normal), do: :normal
  def normalize_user_tier("adventurer"), do: :adventurer
  def normalize_user_tier("hero"), do: :hero
  def normalize_user_tier("legend"), do: :legend
  def normalize_user_tier("normal"), do: :normal
  def normalize_user_tier(@patron_tier_aventurero), do: :adventurer
  def normalize_user_tier(@patron_tier_heroe), do: :hero
  def normalize_user_tier(@patron_tier_leyenda), do: :legend
  def normalize_user_tier(1), do: :adventurer
  def normalize_user_tier(2), do: :hero
  def normalize_user_tier(3), do: :legend
  def normalize_user_tier(_), do: :normal

  def user_tier_to_protocol(:adventurer), do: 1
  def user_tier_to_protocol(:hero), do: 2
  def user_tier_to_protocol(:legend), do: 3
  def user_tier_to_protocol(_), do: 0

  def user_tier_to_db(:adventurer), do: @patron_tier_aventurero
  def user_tier_to_db(:hero), do: @patron_tier_heroe
  def user_tier_to_db(:legend), do: @patron_tier_leyenda
  def user_tier_to_db(_), do: 0
end
