import { useEffect, useMemo, useReducer, useRef, useState } from "react";
import { appReducer, createInitialState } from "./appReducer";
import type { Direction } from "./types";
import { SessionClient, type MovementDebugSnapshot } from "../net/SessionClient";
import { MapMusicController } from "../audio/mapMusic";
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

const RIGHT_TABS = [
  { key: "hud", label: "HUD" },
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
    "hud" | "spells" | "world" | "session" | "chat" | "debug"
  >("hud");
  const [showTileDebug, setShowTileDebug] = useState(false);
  const [showMoveDebug, setShowMoveDebug] = useState(false);
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

  useEffect(() => {
    stateRef.current = state;
  }, [state]);

  useEffect(() => {
    if (state.world.mapStatus === "ready" && state.world.map) {
      enteredWorldRef.current = true;
      if (bootConnectAttempts !== 0) {
        setBootConnectAttempts(0);
      }
    }
  }, [bootConnectAttempts, state.world.map, state.world.mapStatus]);

  const sessionRef = useRef<SessionClient | null>(null);
  const musicRef = useRef<MapMusicController | null>(null);

  if (sessionRef.current == null) {
    sessionRef.current = new SessionClient(dispatch, () => stateRef.current);
  }

  if (musicRef.current == null) {
    musicRef.current = new MapMusicController();
  }

  const session = sessionRef.current;
  const music = musicRef.current;

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
  }, [session]);

  useEffect(() => {
    const intervalId = window.setInterval(() => {
      dispatch({ type: "world/pruneChatBubbles", now: Date.now() });
    }, 250);

    return () => {
      window.clearInterval(intervalId);
    };
  }, []);

  useEffect(() => {
    return () => {
      session.destroy();
      music.destroy();
    };
  }, [music, session]);

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
        eyebrow: "Session",
        title: "Connecting",
        copy: "Opening the AO session flow with saved-token reconnect or packet 74 account auth."
      };
    }

    if (state.connection.status === "offline" && !state.world.map) {
      return {
        eyebrow: "Session",
        title: state.connection.lastError ? "Connection Failed" : "Ready To Enter",
        copy:
          state.connection.lastError ??
          (state.connection.credentials
            ? "Assets are loaded. The client will reconnect automatically with the saved session token."
            : "Assets are loaded. Enter a character name and password in Session, then connect.")
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
                  session={session}
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
            {RIGHT_TABS.map((tab) => (
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
              />
            ) : null}

            {activeRightTab === "spells" ? (
              <div className="hud-stack">
                <HechizosPanel
                  compact
                  state={state}
                  onCast={(slotIndex) => session.sendCastSpell(slotIndex)}
                  onSelectSlot={(slotIndex) =>
                    dispatch({ type: "spellbook/selectSlot", slotIndex })
                  }
                />
              </div>
            ) : null}

            {activeRightTab === "chat" ? (
              <ChatPanel
                onSend={(message) => session.sendChat(message)}
                onPickUp={() => session.sendPickUp()}
                onRequestPosition={() => session.requestPositionUpdate()}
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
                    dispatch({
                      type: "log/add",
                      level: "info",
                      message: "Grupo panel not wired yet."
                    });
                    return;
                  }

                  if (action.key === "clans") {
                    dispatch({
                      type: "log/add",
                      level: "info",
                      message: "Clanes panel not wired yet."
                    });
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
