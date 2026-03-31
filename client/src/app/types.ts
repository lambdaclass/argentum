export type ConnectionStatus = "offline" | "connecting" | "connected";
export type LogLevel = "info" | "warn" | "error" | "packet-in" | "packet-out";
export type Direction = "north" | "east" | "south" | "west";

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

export interface CharacterView {
  charIndex: number | null;
  name: string;
  x: number | null;
  y: number | null;
  heading: number;
  bodyId: number;
  headId: number;
  speed: number;
  hpCurrent: number;
  hpMax: number;
  manaCurrent: number;
  manaMax: number;
}

export interface RemoteCharacter {
  charIndex: number;
  name: string;
  x: number;
  y: number;
  heading: number;
  bodyId: number;
  headId: number;
  speed: number;
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
    walkIntervalMs: number;
    self: CharacterView;
    others: Record<number, RemoteCharacter>;
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
  skills: {
    entries: SkillEntry[];
    selectedKey: string | null;
    source: "none" | "server";
  };
  log: PacketLogEntry[];
}

export type WorldState = ClientState["world"];

export interface CharacterCreatePacket {
  charIndex: number;
  bodyId: number;
  headId: number;
  heading: number;
  x: number;
  y: number;
  name: string;
  speed: number;
  minHp: number;
  maxHp: number;
  minMana: number;
  maxMana: number;
}

export type ServerPacket =
  | { type: "logged"; newUser: boolean }
  | { type: "change_map"; mapId: number; version: number }
  | { type: "pos_update"; x: number; y: number }
  | { type: "chat_over_head"; message: string; charIndex: number; x: number; y: number }
  | { type: "console_msg"; message: string; fontIndex: number }
  | { type: "character_create"; character: CharacterCreatePacket }
  | { type: "character_remove"; charIndex: number }
  | { type: "character_move"; charIndex: number; x: number; y: number }
  | { type: "user_index_in_server"; userIndex: number }
  | { type: "user_char_index_in_server"; charIndex: number }
  | { type: "character_change_heading"; charIndex: number; heading: number }
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
  | { type: "send_skills"; skills: SkillEntry[] }
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
  | { type: "world/setCharIndex"; charIndex: number }
  | { type: "world/setSelfPosition"; x: number; y: number }
  | { type: "world/setSelfHeading"; heading: number }
  | { type: "world/upsertCharacter"; character: CharacterCreatePacket; self: boolean }
  | { type: "world/moveOther"; charIndex: number; x: number; y: number }
  | { type: "world/setOtherHeading"; charIndex: number; heading: number }
  | { type: "world/removeOther"; charIndex: number }
  | { type: "world/upsertGroundObject"; object: GroundObject }
  | { type: "world/removeGroundObject"; x: number; y: number }
  | { type: "world/addChatBubble"; bubble: ChatBubble }
  | { type: "world/pruneChatBubbles"; now: number }
  | { type: "stats/setHp"; current: number; max?: number }
  | { type: "stats/setMana"; current: number; max?: number }
  | { type: "stats/setStamina"; current: number; max?: number }
  | { type: "stats/setGold"; gold: number }
  | { type: "stats/setHungerThirst"; hunger: number; thirst: number }
  | { type: "stats/setLevel"; level: number }
  | { type: "stats/setExp"; current: number; next: number }
  | { type: "inventory/setSlot"; slotIndex: number; slot: InventorySlot | null }
  | { type: "inventory/selectSlot"; slotIndex: number | null }
  | { type: "spellbook/setSlot"; slotIndex: number; slot: SpellSlot | null }
  | { type: "spellbook/selectSlot"; slotIndex: number | null }
  | { type: "skills/setAll"; entries: SkillEntry[]; source?: "server" }
  | { type: "skills/select"; key: string | null }
  | { type: "log/add"; level: LogLevel; message: string }
  | { type: "log/clear" }
  | { type: "session/resetRuntime" };
