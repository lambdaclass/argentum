import type {
  CharacterCreatePacket,
  ClientAction,
  ClientState,
  GroundObject,
  PacketLogEntry,
  SessionCredentials
} from "./types";

const DEFAULT_ENDPOINT = "ws://127.0.0.1:7667/ao";
const DEFAULT_CHARACTER_NAME = "Player_Web";
const DEFAULT_BOOTSTRAP_PASSWORD = "browser_bootstrap_token";
const STORAGE_CHAR_ID = "ao_char_id";
const STORAGE_TOKEN = "ao_session_token";

function defaultEndpoint() {
  if (typeof window === "undefined") {
    return DEFAULT_ENDPOINT;
  }

  const rawHostname = window.location.hostname || "127.0.0.1";
  const hostname = rawHostname === "localhost" ? "127.0.0.1" : rawHostname;
  return `ws://${hostname}:7667/ao`;
}

function loadStoredCredentials(): SessionCredentials | null {
  if (typeof window === "undefined") {
    return null;
  }

  const rawCharId = window.localStorage.getItem(STORAGE_CHAR_ID);
  const token = window.localStorage.getItem(STORAGE_TOKEN);

  if (!rawCharId || !token) {
    return null;
  }

  const charId = Number.parseInt(rawCharId, 10);

  if (!Number.isFinite(charId) || token.length === 0) {
    return null;
  }

  return { charId, token };
}

export function persistCredentials(credentials: SessionCredentials | null) {
  if (typeof window === "undefined") {
    return;
  }

  if (!credentials) {
    window.localStorage.removeItem(STORAGE_CHAR_ID);
    window.localStorage.removeItem(STORAGE_TOKEN);
    return;
  }

  window.localStorage.setItem(STORAGE_CHAR_ID, String(credentials.charId));
  window.localStorage.setItem(STORAGE_TOKEN, credentials.token);
}

function createLogEntry(level: PacketLogEntry["level"], message: string): PacketLogEntry {
  return {
    id: Date.now() + Math.floor(Math.random() * 10_000),
    level,
    message
  };
}

function initialCharacter(): ClientState["world"]["self"] {
  return {
    charIndex: null,
    name: "",
    x: null,
    y: null,
    heading: 3,
    bodyId: 1,
    headId: 1,
    speed: 1,
    hpCurrent: 100,
    hpMax: 100,
    manaCurrent: 100,
    manaMax: 100
  };
}

function groundObjectKey(x: number, y: number) {
  return `${x},${y}`;
}

function normalizeSkills(
  entries: ClientState["skills"]["entries"]
): ClientState["skills"]["entries"] {
  return [...entries].sort((left, right) => {
    if (right.level !== left.level) {
      return right.level - left.level;
    }

    return left.key.localeCompare(right.key);
  });
}

function nextMapStatus(world: ClientState["world"]) {
  return world.map != null ? "transferring" : "loading";
}

function applyCharacter(target: CharacterCreatePacket, character: ClientState["world"]["self"]) {
  character.charIndex = target.charIndex;
  character.name = target.name;
  character.x = target.x;
  character.y = target.y;
  character.heading = target.heading;
  character.bodyId = target.bodyId;
  character.headId = target.headId;
  character.speed = target.speed;
  character.hpCurrent = target.minHp;
  character.hpMax = target.maxHp;
  character.manaCurrent = target.minMana;
  character.manaMax = target.maxMana;
}

export function createInitialState(): ClientState {
  return {
    connection: {
      status: "offline",
      endpoint: defaultEndpoint(),
      characterName: DEFAULT_CHARACTER_NAME,
      bootstrapPassword: DEFAULT_BOOTSTRAP_PASSWORD,
      lastError: null,
      credentials: loadStoredCredentials()
    },
    world: {
      mapId: null,
      mapStatus: "idle",
      mapError: null,
      map: null,
      groundObjects: {},
      chatBubbles: [],
      walkIntervalMs: 210,
      self: initialCharacter(),
      others: {}
    },
    stats: {
      hpCurrent: 100,
      hpMax: 100,
      manaCurrent: 100,
      manaMax: 100,
      staminaCurrent: 100,
      staminaMax: 100,
      hunger: 100,
      thirst: 100,
      gold: 0,
      level: 1,
      xpCurrent: 0,
      xpNext: 500
    },
    inventory: {
      slots: Array.from({ length: 24 }, () => null),
      selectedSlot: null
    },
    spellbook: {
      slots: Array.from({ length: 20 }, () => null),
      selectedSlot: null
    },
    skills: {
      entries: [],
      selectedKey: null,
      source: "none"
    },
    log: [createLogEntry("info", "Client initialized.")]
  };
}

export function appReducer(state: ClientState, action: ClientAction): ClientState {
  switch (action.type) {
    case "connection/setStatus":
      return {
        ...state,
        connection: {
          ...state.connection,
          status: action.status,
          lastError: action.lastError ?? null
        }
      };

    case "connection/setEndpoint":
      return {
        ...state,
        connection: {
          ...state.connection,
          endpoint: action.endpoint
        }
      };

    case "connection/setCharacterName":
      return {
        ...state,
        connection: {
          ...state.connection,
          characterName: action.characterName
        }
      };

    case "connection/setBootstrapPassword":
      return {
        ...state,
        connection: {
          ...state.connection,
          bootstrapPassword: action.bootstrapPassword
        }
      };

    case "connection/setCredentials":
      persistCredentials(action.credentials);
      return {
        ...state,
        connection: {
          ...state.connection,
          credentials: action.credentials
        }
      };

    case "world/setMap":
      return {
        ...state,
        connection: {
          ...state.connection,
          lastError: null
        },
        world: {
          ...state.world,
          mapId: action.mapId,
          mapStatus: nextMapStatus(state.world),
          mapError: null,
          chatBubbles: [],
          others: {}
        }
      };

    case "world/setMapLoading":
      return {
        ...state,
        connection: {
          ...state.connection,
          lastError: null
        },
        world: {
          ...state.world,
          mapId: action.mapId,
          mapStatus: nextMapStatus(state.world),
          mapError: null,
          chatBubbles: [],
          others: {}
        }
      };

    case "world/setMapData":
      return {
        ...state,
        connection: {
          ...state.connection,
          lastError: null
        },
        world: {
          ...state.world,
          mapId: action.map.mapId,
          mapStatus: "ready",
          mapError: null,
          map: action.map,
          groundObjects: action.groundObjects,
          chatBubbles: []
        }
      };

    case "world/setMapError":
      return {
        ...state,
        world: {
          ...state.world,
          mapId: action.mapId,
          mapStatus: "error",
          mapError: action.message,
          chatBubbles: []
        },
        connection: {
          ...state.connection,
          lastError: action.message
        }
      };

    case "world/setWalkInterval":
      return {
        ...state,
        world: {
          ...state.world,
          walkIntervalMs: action.walkIntervalMs
        }
      };

    case "world/setCharIndex":
      {
        const nextOthers = { ...state.world.others };
        delete nextOthers[action.charIndex];

        return {
          ...state,
          world: {
            ...state.world,
            self: {
              ...state.world.self,
              charIndex: action.charIndex
            },
            others: nextOthers
          }
        };
      }

    case "world/setSelfPosition":
      return {
        ...state,
        world: {
          ...state.world,
          self: {
            ...state.world.self,
            x: action.x,
            y: action.y
          }
        }
      };

    case "world/setSelfHeading":
      return {
        ...state,
        world: {
          ...state.world,
          self: {
            ...state.world.self,
            heading: action.heading
          }
        }
      };

    case "world/upsertCharacter": {
      if (action.self || action.character.charIndex === state.world.self.charIndex) {
        const self = { ...state.world.self };
        applyCharacter(action.character, self);
        const nextOthers = { ...state.world.others };
        delete nextOthers[action.character.charIndex];

        return {
          ...state,
          world: {
            ...state.world,
            self,
            others: nextOthers
          },
          stats: {
            ...state.stats,
            hpCurrent: action.character.minHp,
            hpMax: action.character.maxHp,
            manaCurrent: action.character.minMana,
            manaMax: action.character.maxMana
          }
        };
      }

      return {
        ...state,
        world: {
          ...state.world,
          others: {
            ...state.world.others,
            [action.character.charIndex]: {
              charIndex: action.character.charIndex,
              name: action.character.name,
              x: action.character.x,
              y: action.character.y,
              heading: action.character.heading,
              bodyId: action.character.bodyId,
              headId: action.character.headId,
              speed: action.character.speed
            }
          }
        }
      };
    }

    case "world/moveOther":
      if (!state.world.others[action.charIndex]) {
        return state;
      }

      return {
        ...state,
        world: {
          ...state.world,
          others: {
            ...state.world.others,
            [action.charIndex]: {
              ...state.world.others[action.charIndex],
              x: action.x,
              y: action.y
            }
          }
        }
      };

    case "world/setOtherHeading":
      if (!state.world.others[action.charIndex]) {
        return state;
      }

      return {
        ...state,
        world: {
          ...state.world,
          others: {
            ...state.world.others,
            [action.charIndex]: {
              ...state.world.others[action.charIndex],
              heading: action.heading
            }
          }
        }
      };

    case "world/removeOther": {
      const nextOthers = { ...state.world.others };
      delete nextOthers[action.charIndex];

      return {
        ...state,
        world: {
          ...state.world,
          others: nextOthers
        }
      };
    }

    case "world/upsertGroundObject": {
      const nextGroundObjects: Record<string, GroundObject> = {
        ...state.world.groundObjects
      };
      nextGroundObjects[groundObjectKey(action.object.x, action.object.y)] = action.object;

      return {
        ...state,
        world: {
          ...state.world,
          groundObjects: nextGroundObjects
        }
      };
    }

    case "world/removeGroundObject": {
      const nextGroundObjects = { ...state.world.groundObjects };
      delete nextGroundObjects[groundObjectKey(action.x, action.y)];

      return {
        ...state,
        world: {
          ...state.world,
          groundObjects: nextGroundObjects
        }
      };
    }

    case "world/addChatBubble":
      return {
        ...state,
        world: {
          ...state.world,
          chatBubbles: [...state.world.chatBubbles, action.bubble].slice(-20)
        }
      };

    case "world/pruneChatBubbles":
      return {
        ...state,
        world: {
          ...state.world,
          chatBubbles: state.world.chatBubbles.filter(
            (bubble) => action.now - bubble.createdAt < bubble.ttlMs
          )
        }
      };

    case "stats/setHp":
      return {
        ...state,
        stats: {
          ...state.stats,
          hpCurrent: action.current,
          hpMax: action.max ?? state.stats.hpMax
        }
      };

    case "stats/setMana":
      return {
        ...state,
        stats: {
          ...state.stats,
          manaCurrent: action.current,
          manaMax: action.max ?? state.stats.manaMax
        }
      };

    case "stats/setStamina":
      return {
        ...state,
        stats: {
          ...state.stats,
          staminaCurrent: action.current,
          staminaMax: action.max ?? state.stats.staminaMax
        }
      };

    case "stats/setGold":
      return {
        ...state,
        stats: {
          ...state.stats,
          gold: action.gold
        }
      };

    case "stats/setHungerThirst":
      return {
        ...state,
        stats: {
          ...state.stats,
          hunger: action.hunger,
          thirst: action.thirst
        }
      };

    case "stats/setLevel":
      return {
        ...state,
        stats: {
          ...state.stats,
          level: action.level
        }
      };

    case "stats/setExp":
      return {
        ...state,
        stats: {
          ...state.stats,
          xpCurrent: action.current,
          xpNext: action.next
        }
      };

    case "inventory/setSlot": {
      const slots = [...state.inventory.slots];
      slots[action.slotIndex] = action.slot;

      return {
        ...state,
        inventory: {
          ...state.inventory,
          slots
        }
      };
    }

    case "inventory/selectSlot":
      return {
        ...state,
        inventory: {
          ...state.inventory,
          selectedSlot: action.slotIndex
        }
      };

    case "spellbook/setSlot": {
      const slots =
        action.slotIndex < state.spellbook.slots.length
          ? [...state.spellbook.slots]
          : [
              ...state.spellbook.slots,
              ...Array.from(
                { length: action.slotIndex - state.spellbook.slots.length + 1 },
                () => null
              )
            ];

      slots[action.slotIndex] = action.slot;

      return {
        ...state,
        spellbook: {
          ...state.spellbook,
          slots
        }
      };
    }

    case "spellbook/selectSlot":
      return {
        ...state,
        spellbook: {
          ...state.spellbook,
          selectedSlot: action.slotIndex
        }
      };

    case "skills/setAll": {
      const entries = normalizeSkills(action.entries);
      const selectedExists =
        state.skills.selectedKey != null &&
        entries.some((entry) => entry.key === state.skills.selectedKey);

      return {
        ...state,
        skills: {
          entries,
          selectedKey: selectedExists ? state.skills.selectedKey : (entries[0]?.key ?? null),
          source: action.source ?? "server"
        }
      };
    }

    case "skills/select":
      return {
        ...state,
        skills: {
          ...state.skills,
          selectedKey: action.key
        }
      };

    case "log/add":
      return {
        ...state,
        log: [createLogEntry(action.level, action.message), ...state.log].slice(0, 80)
      };

    case "log/clear":
      return {
        ...state,
        log: []
      };

    case "session/resetRuntime":
      return {
        ...state,
        connection: {
          ...state.connection,
          status: "offline",
          lastError: null
        },
        world: {
          mapId: null,
          mapStatus: "idle",
          mapError: null,
          map: null,
          groundObjects: {},
          chatBubbles: [],
          walkIntervalMs: state.world.walkIntervalMs,
          self: initialCharacter(),
          others: {}
        },
        stats: {
          hpCurrent: 100,
          hpMax: 100,
          manaCurrent: 100,
          manaMax: 100,
          staminaCurrent: 100,
          staminaMax: 100,
          hunger: 100,
          thirst: 100,
          gold: 0,
          level: 1,
          xpCurrent: 0,
          xpNext: 500
        },
        inventory: {
          slots: Array.from({ length: 24 }, () => null),
          selectedSlot: null
        },
        spellbook: {
          slots: Array.from({ length: 20 }, () => null),
          selectedSlot: null
        },
        skills: {
          entries: [],
          selectedKey: null,
          source: "none"
        }
      };

    default:
      return state;
  }
}
