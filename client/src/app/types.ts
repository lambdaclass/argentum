export type ConnectionStatus = "offline" | "connecting" | "connected";
export type LogLevel = "info" | "warn" | "error" | "packet-in" | "packet-out";
export type Direction = "north" | "east" | "south" | "west";
export type KeyBindingAction =
  | "openHud"
  | "pickUp"
  | "attack"
  | "safeToggle"
  | "commerce"
  | "bank"
  | "resyncPosition"
  | "tileDebug"
  | "moveDebug";

export interface SessionCredentials {
  charId: number;
  token: string;
}

export interface InventorySlot {
  itemId: number;
  amount: number;
  equipped: boolean;
  value: number;
  canUse: number;
}

export interface SpellSlot {
  spellId: number;
  name: string;
}

export interface SkillEntry {
  key: string;
  level: number;
}

export interface TileTarget {
  x: number;
  y: number;
}

export interface CombatTextEvent {
  id: number;
  x: number;
  y: number;
  text: string;
  tone: "damage" | "block" | "status" | "info";
  createdAt: number;
  ttlMs: number;
}

export interface WorldFxEvent {
  id: number;
  x: number;
  y: number;
  fxId: number;
  loops: number;
  createdAt: number;
  ttlMs: number;
}

export interface MerchantSlot {
  itemId: number;
  amount: number;
  price: number;
  canUse: number;
  elementalTags: number;
}

export interface BankSlot {
  itemId: number;
  amount: number;
  value: number;
  canUse: number;
  elementalTags: number;
}

export interface TradeOfferSlot {
  itemId: number;
  name: string;
  grhIndex: number;
  amount: number;
  elementalTags: number;
}

export interface TradeOfferState {
  gold: number;
  items: Array<TradeOfferSlot | null>;
}

export interface CharacterView {
  charIndex: number | null;
  name: string;
  x: number | null;
  y: number | null;
  dead: boolean;
  heading: number;
  bodyId: number;
  headId: number;
  weaponId: number;
  shieldId: number;
  helmetId: number;
  cartId: number;
  backpackId: number;
  effectId: number;
  effectLoops: number;
  speed: number;
  hpCurrent: number;
  hpMax: number;
  manaCurrent: number;
  manaMax: number;
  navigating: boolean;
  classId: number | null;
  raceId: number | null;
  genderId: number | null;
  factionStatus: number | null;
  clanIndex: number;
  clanLevel: number;
}

export interface RemoteCharacter {
  charIndex: number;
  name: string;
  x: number;
  y: number;
  dead: boolean;
  heading: number;
  bodyId: number;
  headId: number;
  weaponId: number;
  shieldId: number;
  helmetId: number;
  cartId: number;
  backpackId: number;
  effectId: number;
  effectLoops: number;
  speed: number;
  isNpc: boolean;
}

export interface MapLayerTile {
  x: number;
  y: number;
  grhIndex: number;
}

export interface MapNpc {
  x: number;
  y: number;
  id: number;
}

export interface MapExit {
  x: number;
  y: number;
  destMap: number;
  destX: number;
  destY: number;
}

export interface GroundObject {
  x: number;
  y: number;
  id: number;
  amount: number;
}

export interface ChatBubble {
  id: number;
  message: string;
  x: number;
  y: number;
  createdAt: number;
  ttlMs: number;
}

export interface WorldMapData {
  mapId: number;
  name: string;
  width: number;
  height: number;
  tiles: Uint8Array;
  musicHi: number;
  musicLow: number;
  layers: MapLayerTile[][];
  npcs: MapNpc[];
  exits: MapExit[];
}

export interface PacketLogEntry {
  id: number;
  level: LogLevel;
  message: string;
}

export interface ClientState {
  connection: {
    status: ConnectionStatus;
    endpoint: string;
    characterName: string;
    bootstrapPassword: string;
    lastError: string | null;
    credentials: SessionCredentials | null;
  };
  world: {
    mapId: number | null;
    mapStatus: "idle" | "loading" | "transferring" | "ready" | "error";
    mapError: string | null;
    map: WorldMapData | null;
    groundObjects: Record<string, GroundObject>;
    chatBubbles: ChatBubble[];
    targetTile: TileTarget | null;
    combatTexts: CombatTextEvent[];
    fxEvents: WorldFxEvent[];
    walkIntervalMs: number;
    self: CharacterView;
    others: Record<number, RemoteCharacter>;
  };
  combat: {
    safeMode: boolean;
    lastEvent: string | null;
  };
  stats: {
    hpCurrent: number;
    hpMax: number;
    manaCurrent: number;
    manaMax: number;
    staminaCurrent: number;
    staminaMax: number;
    hunger: number;
    thirst: number;
    gold: number;
    level: number;
    xpCurrent: number;
    xpNext: number;
  };
  inventory: {
    slots: Array<InventorySlot | null>;
    selectedSlot: number | null;
  };
  spellbook: {
    slots: Array<SpellSlot | null>;
    selectedSlot: number | null;
  };
  commerce: {
    open: boolean;
    npcName: string | null;
    slots: Array<MerchantSlot | null>;
    selectedSlot: number | null;
    buyAmount: number;
    sellAmount: number;
  };
  bank: {
    open: boolean;
    slots: Array<BankSlot | null>;
    selectedSlot: number | null;
    bankGold: number;
    depositAmount: number;
    withdrawAmount: number;
    depositGoldAmount: number;
    withdrawGoldAmount: number;
  };
  trade: {
    open: boolean;
    myOffer: TradeOfferState;
    otherOffer: TradeOfferState;
    offerAmount: number;
    accepted: boolean;
    partnerAccepted: boolean;
  };
  skills: {
    entries: SkillEntry[];
    selectedKey: string | null;
    source: "none" | "server";
  };
  party: {
    open: boolean;
    members: string[];
    invited: boolean;
    inviterName: string;
    safeMode: boolean;
  };
  clan: {
    open: boolean;
    name: string;
    members: string[];
    rank: string;
  };
  weather: {
    raining: boolean;
    snowing: boolean;
  };
  settings: {
    audio: {
      musicEnabled: boolean;
      musicVolume: number;
      soundEnabled: boolean;
      soundVolume: number;
    };
    controls: {
      bindings: Record<KeyBindingAction, string | null>;
    };
  };
  log: PacketLogEntry[];
}

export type WorldState = ClientState["world"];

export interface CharacterCreatePacket {
  charIndex: number;
  bodyId: number;
  headId: number;
  weaponId: number;
  shieldId: number;
  helmetId: number;
  cartId: number;
  backpackId: number;
  effectId: number;
  effectLoops: number;
  heading: number;
  x: number;
  y: number;
  name: string;
  speed: number;
  minHp: number;
  maxHp: number;
  minMana: number;
  maxMana: number;
  isNpc: boolean;
  clanIndex: number;
  clanLevel: number;
}

export type ServerPacket =
  | { type: "logged"; newUser: boolean }
  | { type: "change_map"; mapId: number; version: number }
  | { type: "pos_update"; x: number; y: number }
  | { type: "chat_over_head"; message: string; charIndex: number; x: number; y: number }
  | { type: "console_msg"; message: string; fontIndex: number }
  | { type: "console_faction_message"; message: string; fontIndex: number; factionLabel: string }
  | { type: "guild_chat"; status: number; message: string }
  | { type: "character_create"; character: CharacterCreatePacket }
  | { type: "character_remove"; charIndex: number }
  | { type: "character_move"; charIndex: number; x: number; y: number }
  | { type: "user_index_in_server"; userIndex: number }
  | { type: "user_char_index_in_server"; charIndex: number }
  | {
      type: "character_change";
      charIndex: number;
      bodyId: number;
      headId: number;
      weaponId: number;
      shieldId: number;
      helmetId: number;
      cartId: number;
      backpackId: number;
      effectId: number;
      effectLoops: number;
      heading: number;
    }
  | { type: "char_swing"; charIndex: number }
  | { type: "npc_kill_user" }
  | { type: "blocked_with_shield_user" }
  | { type: "blocked_with_shield_other"; charIndex: number }
  | { type: "npc_hit_user"; target: number; damage: number }
  | { type: "user_hitted_by_user"; charIndex: number; target: number; damage: number }
  | { type: "user_hitted_user"; charIndex: number; target: number; damage: number }
  | { type: "safe_mode_on" }
  | { type: "safe_mode_off" }
  | { type: "navigate_toggle"; navigating: boolean }
  | { type: "create_fx"; charIndex: number; fxId: number; loops: number; x: number; y: number }
  | { type: "play_wave"; wav: number; x: number; y: number; cancelLast: boolean; localize: boolean }
  | {
      type: "change_inventory_slot";
      slotIndex: number;
      slot: InventorySlot | null;
    }
  | { type: "object_create"; x: number; y: number; objIndex: number; amount: number }
  | { type: "object_delete"; x: number; y: number }
  | { type: "update_hunger_and_thirst"; hunger: number; thirst: number }
  | { type: "update_hp"; current: number; shield: number }
  | { type: "update_mana"; current: number }
  | { type: "update_stamina"; current: number }
  | { type: "update_gold"; gold: number; walletGoldByLevel: number }
  | { type: "update_exp"; currentXp: number; nextXp: number }
  | { type: "level_up"; level: number }
  | { type: "intervals"; walk: number }
  | { type: "error_msg"; message: string }
  | { type: "session_token"; credentials: SessionCredentials }
  | { type: "change_spell_slot"; slotIndex: number; slot: SpellSlot | null }
  | { type: "commerce_init"; npcName: string }
  | { type: "bank_init" }
  | { type: "user_commerce_init"; partnerName: string }
  | { type: "user_commerce_end" }
  | {
      type: "change_npc_inventory_slot";
      slotIndex: number;
      slot: MerchantSlot | null;
    }
  | {
      type: "change_bank_slot";
      slotIndex: number;
      slot: BankSlot | null;
    }
  | {
      type: "change_user_trade_slot";
      myOffer: boolean;
      gold: number;
      items: Array<TradeOfferSlot | null>;
    }
  | { type: "commerce_end" }
  | { type: "bank_end" }
  | { type: "update_bank_gold"; bankGold: number }
  | {
      type: "update_user_stats";
      hpCurrent: number;
      hpMax: number;
      manaCurrent: number;
      manaMax: number;
      staminaCurrent: number;
      staminaMax: number;
      gold: number;
      level: number;
      currentXp: number;
      nextXp: number;
    }
  | { type: "mini_stats"; classId: number; raceId: number; genderId: number; factionStatus: number }
  | { type: "send_skills"; skills: SkillEntry[] }
  | { type: "rain_toggle"; raining: boolean }
  | { type: "snow_toggle"; snowing: boolean }
  | { type: "unknown"; packetId: number };

export type ClientAction =
  | { type: "connection/setStatus"; status: ConnectionStatus; lastError?: string | null }
  | { type: "connection/setEndpoint"; endpoint: string }
  | { type: "connection/setCharacterName"; characterName: string }
  | { type: "connection/setBootstrapPassword"; bootstrapPassword: string }
  | { type: "connection/setCredentials"; credentials: SessionCredentials | null }
  | { type: "world/setMap"; mapId: number }
  | { type: "world/setMapLoading"; mapId: number }
  | { type: "world/setMapData"; map: WorldMapData; groundObjects: Record<string, GroundObject> }
  | { type: "world/setMapError"; mapId: number; message: string }
  | { type: "world/setWalkInterval"; walkIntervalMs: number }
  | { type: "world/setTargetTile"; target: TileTarget | null }
  | { type: "world/setCharIndex"; charIndex: number }
  | { type: "world/setSelfPosition"; x: number; y: number }
  | { type: "world/setSelfHeading"; heading: number }
  | { type: "world/setSelfNavigation"; navigating: boolean }
  | { type: "world/setSelfDead"; dead: boolean }
  | { type: "world/upsertCharacter"; character: CharacterCreatePacket; self: boolean }
  | { type: "world/moveOther"; charIndex: number; x: number; y: number }
  | {
      type: "world/setCharacterAppearance";
      charIndex: number;
      bodyId?: number;
      headId?: number;
      weaponId?: number;
      shieldId?: number;
      helmetId?: number;
      cartId?: number;
      backpackId?: number;
      effectId?: number;
      effectLoops?: number;
      heading?: number;
    }
  | {
      type: "world/setMiniStats";
      classId: number;
      raceId: number;
      genderId: number;
      factionStatus: number;
    }
  | { type: "world/removeOther"; charIndex: number }
  | { type: "world/upsertGroundObject"; object: GroundObject }
  | { type: "world/removeGroundObject"; x: number; y: number }
  | { type: "world/addChatBubble"; bubble: ChatBubble }
  | { type: "world/addCombatText"; event: CombatTextEvent }
  | { type: "world/addFx"; event: WorldFxEvent }
  | { type: "world/pruneTransient"; now: number }
  | { type: "combat/setSafeMode"; safeMode: boolean }
  | { type: "combat/setLastEvent"; message: string | null }
  | { type: "stats/setHp"; current: number; max?: number }
  | { type: "stats/setMana"; current: number; max?: number }
  | { type: "stats/setStamina"; current: number; max?: number }
  | { type: "stats/setGold"; gold: number }
  | { type: "stats/setHungerThirst"; hunger: number; thirst: number }
  | { type: "stats/setLevel"; level: number }
  | { type: "stats/setExp"; current: number; next: number }
  | {
      type: "stats/setAll";
      hpCurrent: number;
      hpMax: number;
      manaCurrent: number;
      manaMax: number;
      staminaCurrent: number;
      staminaMax: number;
      gold: number;
      level: number;
      currentXp: number;
      nextXp: number;
    }
  | { type: "inventory/setSlot"; slotIndex: number; slot: InventorySlot | null }
  | { type: "inventory/selectSlot"; slotIndex: number | null }
  | { type: "spellbook/setSlot"; slotIndex: number; slot: SpellSlot | null }
  | { type: "spellbook/selectSlot"; slotIndex: number | null }
  | { type: "commerce/open"; npcName: string }
  | { type: "commerce/close" }
  | { type: "commerce/setSlot"; slotIndex: number; slot: MerchantSlot | null }
  | { type: "commerce/selectSlot"; slotIndex: number | null }
  | { type: "commerce/setBuyAmount"; amount: number }
  | { type: "commerce/setSellAmount"; amount: number }
  | { type: "bank/open" }
  | { type: "bank/close" }
  | { type: "bank/setSlot"; slotIndex: number; slot: BankSlot | null }
  | { type: "bank/selectSlot"; slotIndex: number | null }
  | { type: "bank/setGold"; bankGold: number }
  | { type: "bank/setDepositAmount"; amount: number }
  | { type: "bank/setWithdrawAmount"; amount: number }
  | { type: "bank/setDepositGoldAmount"; amount: number }
  | { type: "bank/setWithdrawGoldAmount"; amount: number }
  | { type: "trade/open" }
  | { type: "trade/close" }
  | { type: "trade/setOffer"; which: "mine" | "theirs"; gold: number; items: Array<TradeOfferSlot | null> }
  | { type: "trade/setOfferAmount"; amount: number }
  | { type: "trade/markAccepted"; accepted: boolean }
  | { type: "trade/markPartnerAccepted"; accepted: boolean }
  | { type: "skills/setAll"; entries: SkillEntry[]; source?: "server" }
  | { type: "skills/select"; key: string | null }
  | { type: "party/toggle" }
  | { type: "party/setMembers"; members: string[] }
  | { type: "party/setInvite"; invited: boolean; inviterName: string }
  | { type: "party/clear" }
  | { type: "party/toggleSafe" }
  | { type: "clan/toggle" }
  | { type: "clan/setInfo"; name: string; members: string[]; rank: string }
  | { type: "clan/clear" }
  | { type: "weather/rain"; raining: boolean }
  | { type: "weather/snow"; snowing: boolean }
  | { type: "settings/setMusicEnabled"; enabled: boolean }
  | { type: "settings/setMusicVolume"; volume: number }
  | { type: "settings/setSoundEnabled"; enabled: boolean }
  | { type: "settings/setSoundVolume"; volume: number }
  | { type: "settings/setKeyBinding"; action: KeyBindingAction; key: string | null }
  | { type: "settings/resetKeyBindings" }
  | { type: "log/add"; level: LogLevel; message: string }
  | { type: "log/clear" }
  | { type: "session/resetRuntime" };
