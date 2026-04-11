import { useEffect, useMemo, useReducer, useRef, useState } from "react";
import { appReducer, createInitialState } from "./appReducer";
import type { Direction } from "./types";
import { SessionClient, type MovementDebugSnapshot } from "../net/SessionClient";
import { MapMusicController } from "../audio/mapMusic";
import { SoundEffectsController } from "../audio/soundEffects";
import { WorldCanvas } from "../render/WorldCanvas";
import { loadAssetCatalog, type AssetCatalog } from "../render/assetCatalog";
import { loadMapPack, type MapPackProgress } from "../net/mapApi";
import { SessionPanel } from "../ui/SessionPanel";
import { PacketLogPanel } from "../ui/PacketLogPanel";
import { ChatPanel } from "../ui/ChatPanel";
import { CharacterCard } from "../ui/CharacterCard";
import { WorldStatusPanel } from "../ui/WorldStatusPanel";
import { HechizosPanel } from "../ui/HechizosPanel";
import { ClassicHudPanel } from "../ui/ClassicHudPanel";
import { SkillsPanel } from "../ui/SkillsPanel";
import { MerchantPanel } from "../ui/MerchantPanel";
import { TradePanel } from "../ui/TradePanel";
import { BankPanel } from "../ui/BankPanel";
import { PartyPanel } from "../ui/PartyPanel";
import { ClansPanel } from "../ui/ClansPanel";

const MOVE_KEYS: Record<string, Direction> = {
  ArrowUp: "north",
  ArrowRight: "east",
  ArrowDown: "south",
  ArrowLeft: "west",
  w: "north",
  d: "east",
  s: "south",
  a: "west"
};

const BASE_RIGHT_TABS = [
  { key: "hud", label: "HUD" },
  { key: "skills", label: "Skills" },
  { key: "spells", label: "Hechizos" },
  { key: "world", label: "Mapa" },
  { key: "session", label: "Sesion" },
  { key: "chat", label: "Chat" },
  { key: "debug", label: "Debug" }
] as const;

const UTILITY_ACTIONS = [
  { key: "world" as const, label: "Mapa" },
  { key: "hud" as const, label: "Estad." },
  { key: "session" as const, label: "Opc." },
  { key: "party" as const, label: "Grupo" },
  { key: "clans" as const, label: "Clanes" }
];

const SPELL_HOTKEY_STORAGE_KEY = "ao_spell_hotkeys";
const UI_DEMO_QUERY_PARAM = "demo";

function loadSpellHotkeys() {
  if (typeof window === "undefined") {
    return Array.from({ length: 10 }, () => null as number | null);
  }

  try {
    const parsed = JSON.parse(window.localStorage.getItem(SPELL_HOTKEY_STORAGE_KEY) ?? "[]");
    if (!Array.isArray(parsed)) {
      return Array.from({ length: 10 }, () => null as number | null);
    }

    return Array.from({ length: 10 }, (_, index) => {
      const value = parsed[index];
      return Number.isInteger(value) && value >= 0 ? value : null;
    });
  } catch {
    return Array.from({ length: 10 }, () => null as number | null);
  }
}

function hotkeyIndexFromKey(key: string) {
  if (key >= "1" && key <= "9") {
    return Number.parseInt(key, 10) - 1;
  }

  if (key === "0") {
    return 9;
  }

  return null;
}

export function App() {
  const [state, dispatch] = useReducer(appReducer, undefined, createInitialState);
  const [assetCatalog, setAssetCatalog] = useState<AssetCatalog | null>(null);
  const [assetStatus, setAssetStatus] = useState<"loading" | "ready" | "error">("loading");
  const [assetError, setAssetError] = useState<string | null>(null);
  const [mapPackStatus, setMapPackStatus] = useState<"loading" | "ready" | "error">("loading");
  const [mapPackError, setMapPackError] = useState<string | null>(null);
  const [mapPackProgress, setMapPackProgress] = useState<MapPackProgress>({
    phase: "download",
    loadedBytes: 0,
    totalBytes: null
  });
  const [activeRightTab, setActiveRightTab] = useState<
    "hud" | "trade" | "bank" | "commerce" | "skills" | "spells" | "world" | "session" | "chat" | "debug"
  >("hud");
  const [showTileDebug, setShowTileDebug] = useState(false);
  const [showMoveDebug, setShowMoveDebug] = useState(false);
  const [spellHotkeys, setSpellHotkeys] = useState<Array<number | null>>(() => loadSpellHotkeys());
  const [bootConnectAttempts, setBootConnectAttempts] = useState(0);
  const [movementDebug, setMovementDebug] = useState<MovementDebugSnapshot>({
    predictedX: null,
    predictedY: null,
    authorityX: null,
    authorityY: null,
    pendingSteps: 0,
    requestCount: 0,
    lastRequestAt: null,
    correctionCount: 0,
    lastCorrectionAt: null
  });
  const stateRef = useRef(state);
  const manualDisconnectRef = useRef(false);
  const enteredWorldRef = useRef(false);
  const demoBootstrapRef = useRef(false);
  const uiDemoMode = useMemo(() => {
    if (typeof window === "undefined") {
      return false;
    }

    return new URLSearchParams(window.location.search).get(UI_DEMO_QUERY_PARAM) === "1";
  }, []);

  useEffect(() => {
    stateRef.current = state;
  }, [state]);

  useEffect(() => {
    if (!uiDemoMode || demoBootstrapRef.current) {
      return;
    }

    demoBootstrapRef.current = true;

    const width = 8;
    const height = 8;
    const tiles = new Uint8Array(width * height).fill(1);
    tiles[4 * width + 4] = 2;

    dispatch({
      type: "world/setMapData",
      map: {
        mapId: 42,
        name: "Demo Coast",
        width,
        height,
        tiles,
        musicHi: 0,
        musicLow: 0,
        layers: [[], [], [], []],
        npcs: [{ x: 4, y: 4, id: 1 }],
        exits: [{ x: 8, y: 8, destMap: 43, destX: 1, destY: 1 }]
      },
      groundObjects: {}
    });
    dispatch({ type: "world/setCharIndex", charIndex: 7 });
    dispatch({ type: "world/setSelfPosition", x: 4, y: 4 });
    dispatch({ type: "world/setTargetTile", target: { x: 5, y: 5 } });
    dispatch({ type: "stats/setAll", hpCurrent: 120, hpMax: 120, manaCurrent: 90, manaMax: 120, staminaCurrent: 80, staminaMax: 100, gold: 875, level: 23, currentXp: 42_000, nextXp: 51_000 });
    dispatch({ type: "inventory/setSlot", slotIndex: 0, slot: { itemId: 501, amount: 12, equipped: false, value: 240, canUse: 0x001f } });
    dispatch({ type: "inventory/setSlot", slotIndex: 1, slot: { itemId: 777, amount: 1, equipped: true, value: 1200, canUse: 0x0003 } });
    dispatch({ type: "inventory/selectSlot", slotIndex: 0 });
    dispatch({ type: "spellbook/setSlot", slotIndex: 0, slot: { spellId: 15, name: "Detectar Invisibilidad" } });
    dispatch({ type: "spellbook/setSlot", slotIndex: 1, slot: { spellId: 16, name: "Invocar Elemental de Fuego" } });
    dispatch({ type: "spellbook/setSlot", slotIndex: 2, slot: { spellId: 14, name: "Resucitar" } });
    dispatch({ type: "spellbook/selectSlot", slotIndex: 0 });
    dispatch({ type: "trade/open" });
    dispatch({
      type: "trade/setOffer",
      which: "mine",
      gold: 150,
      items: [
        { itemId: 501, name: "Vara de exploracion", grhIndex: 231, amount: 3, elementalTags: 0x03 },
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null
      ]
    });
    dispatch({
      type: "trade/setOffer",
      which: "theirs",
      gold: 420,
      items: [
        { itemId: 777, name: "Capa de bruma", grhIndex: 512, amount: 1, elementalTags: 0x09 },
        { itemId: 778, name: "Catalizador", grhIndex: 513, amount: 2, elementalTags: 0x12 },
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null
      ]
    });
    dispatch({ type: "trade/setOfferAmount", amount: 3 });
    dispatch({ type: "weather/rain", raining: true });
    dispatch({ type: "trade/markAccepted", accepted: false });
    dispatch({ type: "trade/markPartnerAccepted", accepted: false });
  }, [uiDemoMode]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    window.localStorage.setItem(SPELL_HOTKEY_STORAGE_KEY, JSON.stringify(spellHotkeys));
  }, [spellHotkeys]);

  const rightTabs = useMemo(() => {
    const dynamicTabs = [];

    if (state.trade.open) {
      dynamicTabs.push({ key: "trade" as const, label: "Trueque" });
    }

    if (state.bank.open) {
      dynamicTabs.push({ key: "bank" as const, label: "Banco" });
    }

    if (state.commerce.open) {
      dynamicTabs.push({ key: "commerce" as const, label: "Comercio" });
    }

    if (dynamicTabs.length === 0) {
      return BASE_RIGHT_TABS;
    }

    return [BASE_RIGHT_TABS[0], ...dynamicTabs, ...BASE_RIGHT_TABS.slice(1)];
  }, [state.bank.open, state.commerce.open, state.trade.open]);

  useEffect(() => {
    if (state.world.mapStatus === "ready" && state.world.map) {
      enteredWorldRef.current = true;
      if (bootConnectAttempts !== 0) {
        setBootConnectAttempts(0);
      }
    }
  }, [bootConnectAttempts, state.world.map, state.world.mapStatus]);

  useEffect(() => {
    if (state.trade.open) {
      setActiveRightTab("trade");
      return;
    }

    if (state.bank.open) {
      setActiveRightTab("bank");
      return;
    }

    if (state.commerce.open) {
      setActiveRightTab("commerce");
      return;
    }

    setActiveRightTab((current) =>
      current === "commerce" || current === "trade" || current === "bank" ? "hud" : current
    );
  }, [state.bank.open, state.commerce.open, state.trade.open]);

  const sessionRef = useRef<SessionClient | null>(null);
  const musicRef = useRef<MapMusicController | null>(null);
  const soundRef = useRef<SoundEffectsController | null>(null);

  if (sessionRef.current == null) {
    sessionRef.current = new SessionClient(dispatch, () => stateRef.current);
  }

  if (musicRef.current == null) {
    musicRef.current = new MapMusicController();
  }

  if (soundRef.current == null) {
    soundRef.current = new SoundEffectsController();
  }

  const session = sessionRef.current;
  const music = musicRef.current;
  const sound = soundRef.current;

  useEffect(() => {
    let cancelled = false;
    setAssetCatalog(null);
    setAssetStatus("loading");
    setAssetError(null);

    loadAssetCatalog(state.connection.endpoint)
      .then((catalog) => {
        if (!cancelled) {
          setAssetCatalog(catalog);
          setAssetStatus("ready");
          dispatch({
            type: "log/add",
            level: "info",
            message: `Asset catalog loaded (${catalog.objects.length} objects, ${catalog.npcs.length} NPCs)`
          });
        }
      })
      .catch((error) => {
        if (!cancelled) {
          const message = error instanceof Error ? error.message : "Asset catalog failed to load.";
          setAssetStatus("error");
          setAssetError(message);
          dispatch({ type: "log/add", level: "error", message });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [state.connection.endpoint]);

  useEffect(() => {
    let cancelled = false;
    setMapPackStatus("loading");
    setMapPackError(null);
    setMapPackProgress({
      phase: "download",
      loadedBytes: 0,
      totalBytes: null
    });

    loadMapPack((progress) => {
      if (!cancelled) {
        setMapPackProgress(progress);
      }
    })
      .then((maps) => {
        if (!cancelled) {
          setMapPackStatus("ready");
          dispatch({
            type: "log/add",
            level: "info",
            message: `Client map pack loaded (${maps.size} maps)`
          });
        }
      })
      .catch((error) => {
        if (!cancelled) {
          const message = error instanceof Error ? error.message : "Map pack failed to load.";
          setMapPackStatus("error");
          setMapPackError(message);
          dispatch({ type: "log/add", level: "error", message });
        }
      });

    return () => {
      cancelled = true;
    };
  }, []);

  const mapPackProgressLabel = useMemo(() => {
    const { loadedBytes, totalBytes, phase } = mapPackProgress;

    const loadedMb = (loadedBytes / (1024 * 1024)).toFixed(1);
    const totalMb = totalBytes != null ? (totalBytes / (1024 * 1024)).toFixed(1) : null;

    if (phase === "decode") {
      return `Decoding world data (${loadedMb} MB)`;
    }

    if (phase === "ready") {
      return totalMb ? `World data ready (${totalMb} MB)` : "World data ready";
    }

    if (totalBytes != null && totalBytes > 0) {
      const percent = Math.min(100, Math.round((loadedBytes / totalBytes) * 100));
      return `Downloading world data ${percent}% (${loadedMb}/${totalMb} MB)`;
    }

    return loadedBytes > 0
      ? `Downloading world data (${loadedMb} MB)`
      : "Starting world data download";
  }, [mapPackProgress]);

  const mapPackProgressValue = useMemo(() => {
    const { phase, loadedBytes, totalBytes } = mapPackProgress;

    if (phase === "ready" || phase === "decode") {
      return 1;
    }

    if (totalBytes != null && totalBytes > 0) {
      return Math.max(0, Math.min(1, loadedBytes / totalBytes));
    }

    return null;
  }, [mapPackProgress]);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      const target = event.target;
      if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
        return;
      }

      if (event.key === "F1") {
        event.preventDefault();
        setShowTileDebug((value) => !value);
        return;
      }

      if (event.key === "F2") {
        event.preventDefault();
        setShowMoveDebug((value) => !value);
        return;
      }

      if (event.key === "i" || event.key === "I") {
        event.preventDefault();
        setActiveRightTab("hud");
        return;
      }

      if (event.key === "p" || event.key === "P") {
        event.preventDefault();
        session.sendPickUp();
        return;
      }

      if (event.key === "f" || event.key === "F") {
        event.preventDefault();
        session.sendAttack();
        return;
      }

      if (event.key === "g" || event.key === "G") {
        event.preventDefault();
        session.sendSafeToggle();
        return;
      }

      if (event.key === "e" || event.key === "E") {
        event.preventDefault();
        session.sendCommerceStart();
        return;
      }

      if (event.key === "b" || event.key === "B") {
        event.preventDefault();
        session.sendBankStart();
        return;
      }

      const hotkeyIndex = hotkeyIndexFromKey(event.key);
      if (hotkeyIndex != null) {
        if (event.ctrlKey || event.metaKey) {
          const selectedSpellSlot = stateRef.current.spellbook.selectedSlot;
          if (selectedSpellSlot != null) {
            event.preventDefault();
            setSpellHotkeys((current) => {
              const next = [...current];
              next[hotkeyIndex] = selectedSpellSlot;
              return next;
            });
            dispatch({
              type: "log/add",
              level: "info",
              message: `Macro ${event.key} asignada al slot ${selectedSpellSlot + 1}.`
            });
          }
          return;
        }

        const slotIndex = spellHotkeys[hotkeyIndex];
        const slot = slotIndex == null ? null : stateRef.current.spellbook.slots[slotIndex];
        if (slotIndex != null && slot != null) {
          event.preventDefault();
          dispatch({ type: "spellbook/selectSlot", slotIndex });
          if (stateRef.current.connection.status === "connected") {
            session.sendCastSpell(slotIndex);
          }
        }
        return;
      }

      const direction = MOVE_KEYS[event.key];
      if (!direction) {
        return;
      }

      event.preventDefault();
      session.rememberMovementKey(direction);
      session.tick(performance.now());
    };

    const releaseHandler = (event: KeyboardEvent) => {
      const direction = MOVE_KEYS[event.key];
      if (!direction) {
        return;
      }

      session.releaseMovementKey(direction);
      event.preventDefault();
    };

    const blurHandler = () => {
      session.clearMovementKeys();
    };

    window.addEventListener("keydown", handler);
    window.addEventListener("keyup", releaseHandler);
    window.addEventListener("blur", blurHandler);

    return () => {
      window.removeEventListener("keydown", handler);
      window.removeEventListener("keyup", releaseHandler);
      window.removeEventListener("blur", blurHandler);
    };
  }, [session, spellHotkeys]);

  useEffect(() => {
    const intervalId = window.setInterval(() => {
      dispatch({ type: "world/pruneTransient", now: Date.now() });
    }, 250);

    return () => {
      window.clearInterval(intervalId);
    };
  }, []);

  useEffect(() => {
    session.setSoundPlayer((payload) => {
      sound.playWave(stateRef.current.connection.endpoint, payload);
    });

    return () => {
      session.setSoundPlayer(null);
    };
  }, [session, sound]);

  useEffect(() => {
    return () => {
      session.destroy();
      music.destroy();
      sound.destroy();
    };
  }, [music, session, sound]);

  useEffect(() => {
    const intervalId = window.setInterval(() => {
      setMovementDebug(session.getDebugSnapshot());
    }, 120);

    return () => {
      window.clearInterval(intervalId);
    };
  }, [session]);

  useEffect(() => {
    if (
      assetStatus !== "ready" ||
      mapPackStatus !== "ready" ||
      state.connection.status !== "offline"
    ) {
      return;
    }

    if (manualDisconnectRef.current || enteredWorldRef.current) {
      return;
    }

    if (state.connection.credentials == null) {
      return;
    }

    if (state.world.map != null || state.world.self.charIndex != null) {
      return;
    }

    const delayMs = bootConnectAttempts === 0 ? 0 : Math.min(5000, 1200 * bootConnectAttempts);
    const timerId = window.setTimeout(() => {
      if (manualDisconnectRef.current || enteredWorldRef.current) {
        return;
      }

      setBootConnectAttempts((attempts) => attempts + 1);
      session.connect(
        state.connection.endpoint,
        state.connection.characterName,
        state.connection.bootstrapPassword
      );
    }, delayMs);

    return () => {
      window.clearTimeout(timerId);
    };
  }, [
    assetStatus,
    bootConnectAttempts,
    mapPackStatus,
    session,
    state.connection.bootstrapPassword,
    state.connection.characterName,
    state.connection.credentials,
    state.connection.endpoint,
    state.connection.status,
    state.world.map,
    state.world.self.charIndex
  ]);

  useEffect(() => {
    if (assetStatus !== "ready") {
      return;
    }

    void music.ensureReady().catch((error) => {
      dispatch({
        type: "log/add",
        level: "warn",
        message: error instanceof Error ? error.message : "Music initialization failed."
      });
    });
  }, [assetStatus, dispatch, music]);

  useEffect(() => {
    if (state.world.mapStatus !== "ready" || !state.world.map) {
      return;
    }

    void music.playMapMusic(state.connection.endpoint, state.world.map.musicLow).catch((error) => {
      dispatch({
        type: "log/add",
        level: "warn",
        message: error instanceof Error ? error.message : "Map music failed."
      });
    });
  }, [dispatch, music, state.connection.endpoint, state.world.map, state.world.mapStatus]);

  useEffect(() => {
    if (state.connection.status === "offline" && state.world.map == null) {
      music.stop();
    }
  }, [music, state.connection.status, state.world.map]);

  const handleConnect = () => {
    manualDisconnectRef.current = false;
    session.connect(
      state.connection.endpoint,
      state.connection.characterName,
      state.connection.bootstrapPassword
    );
  };

  const handleDisconnect = () => {
    manualDisconnectRef.current = true;
    session.disconnect();
  };

  const handleChatSend = (message: string) => {
    const trimmed = message.trim();
    if (!trimmed) {
      return;
    }

    const whisperMatch = trimmed.match(/^\/(?:w|whisper|susurrar)\s+(\S+)\s+(.+)$/i);
    if (whisperMatch) {
      session.sendWhisper(whisperMatch[1], whisperMatch[2]);
      return;
    }

    const yellMatch = trimmed.match(/^\/(?:yell|gritar)\s+(.+)$/i);
    if (yellMatch) {
      session.sendYell(yellMatch[1]);
      return;
    }

    switch (trimmed.toLowerCase()) {
      case "/online":
        session.sendOnline();
        return;
      case "/rest":
      case "/descansar":
        session.sendRest();
        return;
      case "/meditate":
      case "/meditar":
        session.sendMeditate();
        return;
      case "/heal":
      case "/curar":
        session.sendHeal();
        return;
      case "/resucitar":
      case "/resucitate":
        session.sendResucitate();
        return;
      case "/stats":
      case "/atributos":
        session.sendRequestAttributes();
        return;
      case "/skills":
      case "/habilidades":
        session.sendRequestSkills();
        return;
      case "/mini":
      case "/ministats":
      case "/perfil":
        session.sendRequestMiniStats();
        return;
      default:
        session.sendChat(trimmed);
    }
  };

  const title = useMemo(() => {
    const position =
      state.world.self.x != null && state.world.self.y != null
        ? `${state.world.self.x},${state.world.self.y}`
        : "--,--";
    const mapName = state.world.map?.name ?? "--";

    return `Map ${state.world.mapId ?? "--"} · ${mapName} · Pos ${position}`;
  }, [state.world.map?.name, state.world.mapId, state.world.self.x, state.world.self.y]);

  const worldOverlay = useMemo(() => {
    if (assetStatus !== "ready" || mapPackStatus !== "ready") {
      return null;
    }

    if (state.connection.status === "connecting") {
      return {
        eyebrow: "Cuenta",
        title: "Connecting",
        copy: state.connection.credentials
          ? "Reusing the saved session to reconnect this account."
          : "Opening the account login flow with the current name and password."
      };
    }

    if (state.connection.status === "offline" && !state.world.map) {
      return {
        eyebrow: "Cuenta",
        title: state.connection.lastError ? "Connection Failed" : "Ready To Enter",
        copy:
          state.connection.lastError ??
          (state.connection.credentials
            ? "Assets are loaded. A saved reconnect session is ready in Sesion."
            : "Assets are loaded. Enter an account name and password in Sesion, then connect.")
      };
    }

    if (state.world.mapStatus === "error") {
      return {
        eyebrow: "Map",
        title: "Map Load Failed",
        copy: state.world.mapError ?? "The world data could not be loaded."
      };
    }

    if ((state.world.mapStatus === "loading" || state.world.mapStatus === "transferring") && !state.world.map) {
      return {
        eyebrow: "Map",
        title: state.world.mapStatus === "transferring" ? "Changing Map" : "Loading Map",
        copy: "Keeping the session alive while the destination map is prepared."
      };
    }

    return null;
  }, [
    assetStatus,
    mapPackStatus,
    state.connection.lastError,
    state.connection.status,
    state.world.map,
    state.world.mapError,
    state.world.mapId,
    state.world.mapStatus
  ]);

  const moveDebugText = useMemo(() => {
    const now = Date.now();
    const requestAgo =
      movementDebug.lastRequestAt == null ? "never" : `${Math.max(0, now - movementDebug.lastRequestAt)}ms ago`;
    const correctionAgo =
      movementDebug.lastCorrectionAt == null
        ? "never"
        : `${Math.max(0, now - movementDebug.lastCorrectionAt)}ms ago`;

    return [
      `Predicted: (${movementDebug.predictedX ?? "--"}, ${movementDebug.predictedY ?? "--"})`,
      `Authority: (${movementDebug.authorityX ?? "--"}, ${movementDebug.authorityY ?? "--"})`,
      `Pending: ${movementDebug.pendingSteps} step(s)`,
      `RPU sent: ${movementDebug.requestCount} (${requestAgo})`,
      `Corrections: ${movementDebug.correctionCount} (${correctionAgo})`
    ].join("\n");
  }, [movementDebug]);

  return (
    <div className="client-shell">
      <main className="world-column">
        <section className="world-stage world-stage-shell">
          <div className="world-canvas-frame">
            {assetStatus === "ready" && mapPackStatus === "ready" ? (
              <>
                <WorldCanvas
                  world={state.world}
                  assetCatalog={assetCatalog}
                  showTileDebug={showTileDebug}
                  raining={state.weather.raining}
                  session={session}
                  onTileInteraction={({ x, y, detail }) => {
                    session.sendLeftClick(x, y);
                    if (detail >= 2) {
                      const clickedCharacter =
                        Object.values(state.world.others).find(
                          (other) => other.x === x && other.y === y
                        ) ?? null;
                      const staticNpcOnTile =
                        state.world.map?.npcs.some((npc) => npc.x === x && npc.y === y) ?? false;

                      if (clickedCharacter?.isNpc || staticNpcOnTile) {
                        session.sendDoubleClick(x, y);
                        return;
                      }

                      session.sendAttack();
                    }
                  }}
                />
                {worldOverlay ? (
                  <div className="world-overlay-state">
                    <p className="eyebrow">{worldOverlay.eyebrow}</p>
                    <h3>{worldOverlay.title}</h3>
                    <p className="panel-copy compact">{worldOverlay.copy}</p>
                  </div>
                ) : null}
              </>
            ) : (
              <div className="world-loading-state">
                <p className="eyebrow">Viewport</p>
                <h3>
                  {assetStatus === "error"
                    ? "Asset Load Failed"
                    : mapPackStatus === "error"
                      ? "Map Pack Load Failed"
                      : mapPackStatus === "ready"
                        ? "Loading Assets"
                        : "Loading Map Pack"}
                </h3>
                <p className="panel-copy compact">
                  {assetStatus === "error"
                    ? assetError ?? "The web client could not load its sprite indices."
                    : mapPackStatus === "error"
                      ? mapPackError ?? "The web client could not load its prepacked map bundle."
                      : mapPackStatus !== "ready"
                        ? mapPackProgressLabel
                        : "Waiting for the same sprite/index catalog used by the historical clients before entering the world."}
                </p>
                {assetStatus !== "error" && mapPackStatus !== "error" && mapPackStatus !== "ready" ? (
                  <div className="world-loading-progress" aria-hidden="true">
                    <div
                      className={`world-loading-progress-fill ${
                        mapPackProgressValue == null ? "world-loading-progress-fill-indeterminate" : ""
                      }`}
                      style={
                        mapPackProgressValue == null
                          ? undefined
                          : { width: `${Math.round(mapPackProgressValue * 100)}%` }
                      }
                    />
                  </div>
                ) : null}
              </div>
            )}
          </div>
        </section>
      </main>

      <aside className="side-panel side-panel-right game-sidebar">
        <section className="panel ao-sidebar-shell" data-active-tab={activeRightTab}>
          <CharacterCard
            canConnect={assetStatus === "ready" && mapPackStatus === "ready"}
            dense={activeRightTab === "hud"}
            state={state}
            onConnect={handleConnect}
            onDisconnect={handleDisconnect}
            onOpenMap={() => setActiveRightTab("world")}
          />

          <div className="sidebar-tabs sidebar-tabs-top sidebar-tabs-ao">
            {rightTabs.map((tab) => (
              <button
                className={`ghost-button ${activeRightTab === tab.key ? "tab-active" : ""}`}
                key={tab.key}
                onClick={() => setActiveRightTab(tab.key)}
                type="button"
              >
                {tab.label}
              </button>
            ))}
          </div>

          <div
            className={`sidebar-tab-body ${
              activeRightTab === "spells" ? "sidebar-tab-body-fixed" : ""
            }`}
          >
            {activeRightTab === "session" ? (
              <SessionPanel
                assetError={assetError}
                assetStatus={assetStatus}
                canConnect={assetStatus === "ready" && mapPackStatus === "ready"}
                state={state}
                title={title}
                showTileDebug={showTileDebug}
                onEndpointChange={(endpoint) =>
                  dispatch({ type: "connection/setEndpoint", endpoint })
                }
                onCharacterNameChange={(characterName) =>
                  dispatch({ type: "connection/setCharacterName", characterName })
                }
                onBootstrapPasswordChange={(bootstrapPassword) =>
                  dispatch({ type: "connection/setBootstrapPassword", bootstrapPassword })
                }
                onConnect={handleConnect}
                onDisconnect={handleDisconnect}
                onForgetSession={() =>
                  dispatch({ type: "connection/setCredentials", credentials: null })
                }
              />
            ) : null}

            {activeRightTab === "world" ? <WorldStatusPanel state={state} /> : null}

            {activeRightTab === "hud" ? (
              <ClassicHudPanel
                assetCatalog={assetCatalog}
                state={state}
                onSelectSlot={(slotIndex) =>
                  dispatch({ type: "inventory/selectSlot", slotIndex })
                }
                onEquip={(slotIndex) => session.sendEquip(slotIndex)}
                onUse={(slotIndex) => session.sendUse(slotIndex)}
                onDrop={(slotIndex, amount) => session.sendDrop(slotIndex, amount)}
                onAttack={() => session.sendAttack()}
                onStartCommerce={() => session.sendCommerceStart()}
                onStartBank={() => session.sendBankStart()}
                onToggleSafeMode={() => session.sendSafeToggle()}
              />
            ) : null}

            {activeRightTab === "bank" && state.bank.open ? (
              <BankPanel
                assetCatalog={assetCatalog}
                state={state}
                onClose={() => session.sendBankEnd()}
                onSelectBankSlot={(slotIndex) => dispatch({ type: "bank/selectSlot", slotIndex })}
                onSelectInventorySlot={(slotIndex) =>
                  dispatch({ type: "inventory/selectSlot", slotIndex })
                }
                onSetDepositAmount={(amount) =>
                  dispatch({ type: "bank/setDepositAmount", amount })
                }
                onSetWithdrawAmount={(amount) =>
                  dispatch({ type: "bank/setWithdrawAmount", amount })
                }
                onSetDepositGoldAmount={(amount) =>
                  dispatch({ type: "bank/setDepositGoldAmount", amount })
                }
                onSetWithdrawGoldAmount={(amount) =>
                  dispatch({ type: "bank/setWithdrawGoldAmount", amount })
                }
                onDeposit={(inventorySlotIndex, amount, bankSlotIndex) =>
                  session.sendBankDeposit(inventorySlotIndex, amount, bankSlotIndex)
                }
                onWithdraw={(bankSlotIndex, amount, inventorySlotIndex) =>
                  session.sendBankExtractItem(bankSlotIndex, amount, inventorySlotIndex)
                }
                onDepositGold={(amount) => session.sendBankDepositGold(amount)}
                onWithdrawGold={(amount) => session.sendBankExtractGold(amount)}
              />
            ) : null}

            {activeRightTab === "commerce" && state.commerce.open ? (
              <MerchantPanel
                assetCatalog={assetCatalog}
                state={state}
                onClose={() => session.sendCommerceEnd()}
                onSelectMerchantSlot={(slotIndex) =>
                  dispatch({ type: "commerce/selectSlot", slotIndex })
                }
                onSelectInventorySlot={(slotIndex) =>
                  dispatch({ type: "inventory/selectSlot", slotIndex })
                }
                onSetBuyAmount={(amount) => dispatch({ type: "commerce/setBuyAmount", amount })}
                onSetSellAmount={(amount) => dispatch({ type: "commerce/setSellAmount", amount })}
                onBuy={(slotIndex, amount) => session.sendCommerceBuy(slotIndex, amount)}
                onSell={(slotIndex, amount) => session.sendCommerceSell(slotIndex, amount)}
              />
            ) : null}

            {activeRightTab === "trade" && state.trade.open ? (
              <TradePanel
                assetCatalog={assetCatalog}
                state={state}
                onSelectInventorySlot={(slotIndex) =>
                  dispatch({ type: "inventory/selectSlot", slotIndex })
                }
                onSetOfferAmount={(amount) => dispatch({ type: "trade/setOfferAmount", amount })}
                onOffer={(itemId, amount) => session.sendUserTradeOffer(itemId, amount)}
                onAccept={() => session.sendUserTradeAccept()}
                onReject={() => session.sendUserTradeReject()}
                onClose={() => session.sendUserTradeEnd()}
              />
            ) : null}

            {state.party.open ? (
              <PartyPanel
                state={state}
                onSendChat={(msg) => session.sendChat(msg)}
                onSendPartySafeToggle={() => session.sendPartySafeToggle()}
                onClose={() => dispatch({ type: "party/toggle" })}
              />
            ) : null}

            {state.clan.open ? (
              <ClansPanel
                state={state}
                onSendChat={(msg) => session.sendChat(msg)}
                onClose={() => dispatch({ type: "clan/toggle" })}
              />
            ) : null}

            {activeRightTab === "skills" ? (
              <SkillsPanel
                state={state}
                onSelectSkill={(key) => dispatch({ type: "skills/select", key })}
              />
            ) : null}

            {activeRightTab === "spells" ? (
              <div className="hud-stack">
                <HechizosPanel
                  compact
                  connected={state.connection.status === "connected"}
                  spellHotkeys={spellHotkeys}
                  state={state}
                  onCast={(slotIndex) => session.sendCastSpell(slotIndex)}
                  onBindHotkey={(hotkeyIndex, slotIndex) =>
                    setSpellHotkeys((current) => {
                      const next = [...current];
                      next[hotkeyIndex] = slotIndex;
                      return next;
                    })
                  }
                  onSelectSlot={(slotIndex) =>
                    dispatch({ type: "spellbook/selectSlot", slotIndex })
                  }
                />
              </div>
            ) : null}

            {activeRightTab === "chat" ? (
              <ChatPanel
                onSend={handleChatSend}
                onPickUp={() => session.sendPickUp()}
                onRequestPosition={() => session.requestPositionUpdate()}
                onRequestStats={() => session.sendRequestAttributes()}
                onRequestSkills={() => session.sendRequestSkills()}
                onRequestMiniStats={() => session.sendRequestMiniStats()}
                onRest={() => session.sendRest()}
                onMeditate={() => session.sendMeditate()}
                onHeal={() => session.sendHeal()}
                onResucitate={() => session.sendResucitate()}
              />
            ) : null}

            {activeRightTab === "debug" ? (
              <>
                {showMoveDebug ? (
                  <section className="panel">
                    <div className="panel-header">
                      <h2>Movement Debug</h2>
                      <span className="panel-tag">F2</span>
                    </div>
                    <pre className="debug-panel">{moveDebugText}</pre>
                  </section>
                ) : (
                  <section className="panel">
                    <div className="panel-header">
                      <h2>Movement Debug</h2>
                      <span className="panel-tag">F2</span>
                    </div>
                    <p className="panel-copy compact">
                      Press <code>F2</code> to show the movement debug panel.
                    </p>
                  </section>
                )}
                <PacketLogPanel state={state} onClear={() => dispatch({ type: "log/clear" })} />
              </>
            ) : null}
          </div>

          <div className="ao-utility-strip">
            {UTILITY_ACTIONS.map((action) => (
              <button
                className={`ghost-button ${
                  (action.key === "world" ||
                    action.key === "hud" ||
                    action.key === "session") &&
                  activeRightTab === action.key
                    ? "tab-active"
                    : ""
                }`}
                key={action.key}
                onClick={() => {
                  if (action.key === "party") {
                    dispatch({ type: "party/toggle" });
                    return;
                  }

                  if (action.key === "clans") {
                    dispatch({ type: "clan/toggle" });
                    return;
                  }

                  setActiveRightTab(action.key);
                }}
                type="button"
              >
                {action.label}
              </button>
            ))}
          </div>
        </section>
      </aside>
    </div>
  );
}
