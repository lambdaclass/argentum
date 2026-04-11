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
const GHOST_BODY_ID = 829;

function isDeadBody(bodyId: number) {
  return bodyId === GHOST_BODY_ID;
}

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
    dead: false,
    heading: 3,
    bodyId: 1,
    headId: 1,
    weaponId: 0,
    shieldId: 0,
    helmetId: 0,
    cartId: 0,
    backpackId: 0,
    effectId: 0,
    effectLoops: 0,
    speed: 1,
    hpCurrent: 100,
    hpMax: 100,
    manaCurrent: 100,
    manaMax: 100,
    navigating: false,
    classId: null,
    raceId: null,
    genderId: null,
    factionStatus: null,
    clanIndex: 0,
    clanLevel: 0
  };
}

function initialBank(): ClientState["bank"] {
  return {
    open: false,
    slots: Array.from({ length: 40 }, () => null),
    selectedSlot: null,
    bankGold: 0,
    depositAmount: 1,
    withdrawAmount: 1,
    depositGoldAmount: 1,
    withdrawGoldAmount: 1
  };
}

function initialTrade(): ClientState["trade"] {
  return {
    open: false,
    myOffer: {
      gold: 0,
      items: Array.from({ length: 10 }, () => null)
    },
    otherOffer: {
      gold: 0,
      items: Array.from({ length: 10 }, () => null)
    },
    offerAmount: 1,
    accepted: false,
    partnerAccepted: false
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
  character.dead = isDeadBody(target.bodyId) || target.minHp <= 0;
  character.heading = target.heading;
  character.bodyId = target.bodyId;
  character.headId = target.headId;
  character.weaponId = target.weaponId;
  character.shieldId = target.shieldId;
  character.helmetId = target.helmetId;
  character.cartId = target.cartId;
  character.backpackId = target.backpackId;
  character.effectId = target.effectId;
  character.effectLoops = target.effectLoops;
  character.speed = target.speed;
  character.hpCurrent = target.minHp;
  character.hpMax = target.maxHp;
  character.manaCurrent = target.minMana;
  character.manaMax = target.maxMana;
  character.clanIndex = target.clanIndex;
  character.clanLevel = target.clanLevel;
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
      targetTile: null,
      combatTexts: [],
      fxEvents: [],
      walkIntervalMs: 210,
      self: initialCharacter(),
      others: {}
    },
    combat: {
      safeMode: false,
      lastEvent: null
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
    commerce: {
      open: false,
      npcName: null,
      slots: [],
      selectedSlot: null,
      buyAmount: 1,
      sellAmount: 1
    },
    bank: initialBank(),
    trade: initialTrade(),
    skills: {
      entries: [],
      selectedKey: null,
      source: "none"
    },
    party: {
      open: false,
      members: [],
      invited: false,
      inviterName: "",
      safeMode: false
    },
    clan: {
      open: false,
      name: "",
      members: [],
      rank: ""
    },
    weather: {
      raining: false,
      snowing: false
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
          targetTile: null,
          combatTexts: [],
          fxEvents: [],
          others: {}
        },
        combat: {
          ...state.combat,
          lastEvent: null
        },
        commerce: {
          open: false,
          npcName: null,
          slots: [],
          selectedSlot: null,
          buyAmount: 1,
          sellAmount: 1
        },
        bank: initialBank(),
        trade: initialTrade()
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
          targetTile: null,
          combatTexts: [],
          fxEvents: [],
          others: {}
        },
        combat: {
          ...state.combat,
          lastEvent: null
        },
        commerce: {
          open: false,
          npcName: null,
          slots: [],
          selectedSlot: null,
          buyAmount: 1,
          sellAmount: 1
        },
        bank: initialBank(),
        trade: initialTrade()
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

    case "world/setTargetTile":
      return {
        ...state,
        world: {
          ...state.world,
          targetTile: action.target
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

    case "world/setSelfNavigation":
      return {
        ...state,
        world: {
          ...state.world,
          self: {
            ...state.world.self,
            navigating: action.navigating
          }
        }
      };

    case "world/setSelfDead":
      return {
        ...state,
        world: {
          ...state.world,
          self: {
            ...state.world.self,
            dead: action.dead
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
              dead: isDeadBody(action.character.bodyId) || action.character.minHp <= 0,
              heading: action.character.heading,
              bodyId: action.character.bodyId,
              headId: action.character.headId,
              weaponId: action.character.weaponId,
              shieldId: action.character.shieldId,
              helmetId: action.character.helmetId,
              cartId: action.character.cartId,
              backpackId: action.character.backpackId,
              effectId: action.character.effectId,
              effectLoops: action.character.effectLoops,
              speed: action.character.speed,
              isNpc: action.character.isNpc
            }
          }
        }
      };
    }

    case "world/setMiniStats":
      return {
        ...state,
        world: {
          ...state.world,
          self: {
            ...state.world.self,
            classId: action.classId,
            raceId: action.raceId,
            genderId: action.genderId,
            factionStatus: action.factionStatus
          }
        }
      };

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

    case "world/setCharacterAppearance":
      if (action.charIndex === state.world.self.charIndex) {
        return {
          ...state,
          world: {
            ...state.world,
            self: {
              ...state.world.self,
              dead:
                action.bodyId != null
                  ? isDeadBody(action.bodyId)
                  : state.world.self.dead,
              heading: action.heading ?? state.world.self.heading,
              bodyId: action.bodyId ?? state.world.self.bodyId,
              headId: action.headId ?? state.world.self.headId,
              weaponId: action.weaponId ?? state.world.self.weaponId,
              shieldId: action.shieldId ?? state.world.self.shieldId,
              helmetId: action.helmetId ?? state.world.self.helmetId,
              cartId: action.cartId ?? state.world.self.cartId,
              backpackId: action.backpackId ?? state.world.self.backpackId,
              effectId: action.effectId ?? state.world.self.effectId,
              effectLoops: action.effectLoops ?? state.world.self.effectLoops
            }
          }
        };
      }

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
              dead:
                action.bodyId != null
                  ? isDeadBody(action.bodyId)
                  : state.world.others[action.charIndex].dead,
              heading: action.heading ?? state.world.others[action.charIndex].heading,
              bodyId: action.bodyId ?? state.world.others[action.charIndex].bodyId,
              headId: action.headId ?? state.world.others[action.charIndex].headId,
              weaponId: action.weaponId ?? state.world.others[action.charIndex].weaponId,
              shieldId: action.shieldId ?? state.world.others[action.charIndex].shieldId,
              helmetId: action.helmetId ?? state.world.others[action.charIndex].helmetId,
              cartId: action.cartId ?? state.world.others[action.charIndex].cartId,
              backpackId: action.backpackId ?? state.world.others[action.charIndex].backpackId,
              effectId: action.effectId ?? state.world.others[action.charIndex].effectId,
              effectLoops: action.effectLoops ?? state.world.others[action.charIndex].effectLoops
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

    case "world/addCombatText":
      return {
        ...state,
        world: {
          ...state.world,
          combatTexts: [...state.world.combatTexts, action.event].slice(-24)
        }
      };

    case "world/addFx":
      return {
        ...state,
        world: {
          ...state.world,
          fxEvents: [...state.world.fxEvents, action.event].slice(-24)
        }
      };

    case "world/pruneTransient":
      return {
        ...state,
        world: {
          ...state.world,
          chatBubbles: state.world.chatBubbles.filter(
            (bubble) => action.now - bubble.createdAt < bubble.ttlMs
          ),
          combatTexts: state.world.combatTexts.filter(
            (event) => action.now - event.createdAt < event.ttlMs
          ),
          fxEvents: state.world.fxEvents.filter(
            (event) => action.now - event.createdAt < event.ttlMs
          )
        }
      };

    case "combat/setSafeMode":
      return {
        ...state,
        combat: {
          ...state.combat,
          safeMode: action.safeMode
        }
      };

    case "combat/setLastEvent":
      return {
        ...state,
        combat: {
          ...state.combat,
          lastEvent: action.message
        }
      };

    case "stats/setHp":
      return {
        ...state,
        world: {
          ...state.world,
          self: {
            ...state.world.self,
            dead: action.current <= 0
          }
        },
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

    case "stats/setAll":
      return {
        ...state,
        world: {
          ...state.world,
          self: {
            ...state.world.self,
            dead: action.hpCurrent <= 0
          }
        },
        stats: {
          ...state.stats,
          hpCurrent: action.hpCurrent,
          hpMax: action.hpMax,
          manaCurrent: action.manaCurrent,
          manaMax: action.manaMax,
          staminaCurrent: action.staminaCurrent,
          staminaMax: action.staminaMax,
          gold: action.gold,
          level: action.level,
          xpCurrent: action.currentXp,
          xpNext: action.nextXp
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

    case "commerce/open":
      return {
        ...state,
        commerce: {
          open: true,
          npcName: action.npcName,
          slots: [],
          selectedSlot: null,
          buyAmount: 1,
          sellAmount: 1
        }
      };

    case "commerce/close":
      return {
        ...state,
        commerce: {
          open: false,
          npcName: null,
          slots: [],
          selectedSlot: null,
          buyAmount: 1,
          sellAmount: 1
        }
      };

    case "commerce/setSlot": {
      const slots =
        action.slotIndex < state.commerce.slots.length
          ? [...state.commerce.slots]
          : [
              ...state.commerce.slots,
              ...Array.from(
                { length: action.slotIndex - state.commerce.slots.length + 1 },
                () => null
              )
            ];

      slots[action.slotIndex] = action.slot;

      const selectedSlot =
        state.commerce.selectedSlot != null &&
        state.commerce.selectedSlot < slots.length &&
        slots[state.commerce.selectedSlot] != null
          ? state.commerce.selectedSlot
          : slots.findIndex((slot) => slot != null);

      return {
        ...state,
        commerce: {
          ...state.commerce,
          open: true,
          slots,
          selectedSlot: selectedSlot >= 0 ? selectedSlot : null
        }
      };
    }

    case "commerce/selectSlot":
      return {
        ...state,
        commerce: {
          ...state.commerce,
          selectedSlot: action.slotIndex
        }
      };

    case "commerce/setBuyAmount":
      return {
        ...state,
        commerce: {
          ...state.commerce,
          buyAmount: Math.max(1, Math.floor(action.amount) || 1)
        }
      };

    case "commerce/setSellAmount":
      return {
        ...state,
        commerce: {
          ...state.commerce,
          sellAmount: Math.max(1, Math.floor(action.amount) || 1)
        }
      };

    case "bank/open":
      return {
        ...state,
        bank: {
          ...initialBank(),
          open: true
        }
      };

    case "bank/close":
      return {
        ...state,
        bank: initialBank()
      };

    case "bank/setSlot": {
      const slots =
        action.slotIndex < state.bank.slots.length
          ? [...state.bank.slots]
          : [
              ...state.bank.slots,
              ...Array.from(
                { length: action.slotIndex - state.bank.slots.length + 1 },
                () => null
              )
            ];

      slots[action.slotIndex] = action.slot;

      const selectedSlot =
        state.bank.selectedSlot != null &&
        state.bank.selectedSlot < slots.length &&
        slots[state.bank.selectedSlot] != null
          ? state.bank.selectedSlot
          : slots.findIndex((slot) => slot != null);

      return {
        ...state,
        bank: {
          ...state.bank,
          open: true,
          slots,
          selectedSlot: selectedSlot >= 0 ? selectedSlot : null
        }
      };
    }

    case "bank/selectSlot":
      return {
        ...state,
        bank: {
          ...state.bank,
          selectedSlot: action.slotIndex
        }
      };

    case "bank/setGold":
      return {
        ...state,
        bank: {
          ...state.bank,
          open: true,
          bankGold: Math.max(0, action.bankGold)
        }
      };

    case "bank/setDepositAmount":
      return {
        ...state,
        bank: {
          ...state.bank,
          depositAmount: Math.max(1, Math.floor(action.amount) || 1)
        }
      };

    case "bank/setWithdrawAmount":
      return {
        ...state,
        bank: {
          ...state.bank,
          withdrawAmount: Math.max(1, Math.floor(action.amount) || 1)
        }
      };

    case "bank/setDepositGoldAmount":
      return {
        ...state,
        bank: {
          ...state.bank,
          depositGoldAmount: Math.max(1, Math.floor(action.amount) || 1)
        }
      };

    case "bank/setWithdrawGoldAmount":
      return {
        ...state,
        bank: {
          ...state.bank,
          withdrawGoldAmount: Math.max(1, Math.floor(action.amount) || 1)
        }
      };

    case "trade/open":
      return {
        ...state,
        trade: {
          ...initialTrade(),
          open: true
        }
      };

    case "trade/close":
      return {
        ...state,
        trade: initialTrade()
      };

    case "trade/setOffer":
      return {
        ...state,
        trade: {
          ...state.trade,
          open: true,
          accepted: false,
          partnerAccepted: false,
          myOffer:
            action.which === "mine"
              ? { gold: action.gold, items: action.items }
              : state.trade.myOffer,
          otherOffer:
            action.which === "theirs"
              ? { gold: action.gold, items: action.items }
              : state.trade.otherOffer
        }
      };

    case "trade/setOfferAmount":
      return {
        ...state,
        trade: {
          ...state.trade,
          offerAmount: Math.max(1, Math.floor(action.amount) || 1)
        }
      };

    case "trade/markAccepted":
      return {
        ...state,
        trade: {
          ...state.trade,
          accepted: action.accepted
        }
      };

    case "trade/markPartnerAccepted":
      return {
        ...state,
        trade: {
          ...state.trade,
          partnerAccepted: action.accepted
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

    case "weather/rain":
      return {
        ...state,
        weather: {
          ...state.weather,
          raining: action.raining
        }
      };

    case "weather/snow":
      return {
        ...state,
        weather: {
          ...state.weather,
          snowing: action.snowing
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
          targetTile: null,
          combatTexts: [],
          fxEvents: [],
          walkIntervalMs: state.world.walkIntervalMs,
          self: initialCharacter(),
          others: {}
        },
        combat: {
          safeMode: false,
          lastEvent: null
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
        commerce: {
          open: false,
          npcName: null,
          slots: [],
          selectedSlot: null,
          buyAmount: 1,
          sellAmount: 1
        },
        bank: initialBank(),
        trade: initialTrade(),
        skills: {
          entries: [],
          selectedKey: null,
          source: "none"
        },
        party: {
          open: false,
          members: [],
          invited: false,
          inviterName: "",
          safeMode: false
        },
        clan: {
          open: false,
          name: "",
          members: [],
          rank: ""
        },
        weather: {
          raining: false,
          snowing: false
        }
      };

    case "party/toggle":
      return {
        ...state,
        party: {
          ...state.party,
          open: !state.party.open
        }
      };

    case "party/setMembers":
      return {
        ...state,
        party: {
          ...state.party,
          members: action.members
        }
      };

    case "party/setInvite":
      return {
        ...state,
        party: {
          ...state.party,
          invited: action.invited,
          inviterName: action.inviterName
        }
      };

    case "party/clear":
      return {
        ...state,
        party: {
          ...state.party,
          members: [],
          invited: false,
          inviterName: "",
          safeMode: false
        }
      };

    case "party/toggleSafe":
      return {
        ...state,
        party: {
          ...state.party,
          safeMode: !state.party.safeMode
        }
      };

    case "clan/toggle":
      return {
        ...state,
        clan: {
          ...state.clan,
          open: !state.clan.open
        }
      };

    case "clan/setInfo":
      return {
        ...state,
        clan: {
          ...state.clan,
          name: action.name,
          members: action.members,
          rank: action.rank
        }
      };

    case "clan/clear":
      return {
        ...state,
        clan: {
          ...state.clan,
          name: "",
          members: [],
          rank: ""
        }
      };

    default:
      return state;
  }
}
