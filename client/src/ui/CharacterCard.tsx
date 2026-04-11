import { useEffect, useRef, useState } from "react";
import type { ClientState } from "../app/types";
import { getFactionStatusLabel, getLevelProgress } from "../data/gameData";
import { drawMinimap } from "./minimap";

const SIDEBAR_COLLAPSE_STORAGE_KEY = "ao_sidebar_hero_collapsed";

interface CharacterCardProps {
  canConnect: boolean;
  dense?: boolean;
  state: ClientState;
  onConnect: () => void;
  onDisconnect: () => void;
  onOpenMap: () => void;
}

function resolveDisplayName(worldName: string, sessionName: string) {
  const serverName = worldName.trim();
  const loginName = sessionName.trim();

  if (!serverName) {
    return loginName || "Adventurer";
  }

  if (!loginName || serverName === loginName) {
    return serverName;
  }

  if (
    serverName.length > loginName.length + 2 &&
    serverName.toLowerCase().startsWith(loginName.toLowerCase())
  ) {
    const suffix = serverName.slice(loginName.length).replace(/^[_\-\s:]+/, "").trim();

    if (suffix.length >= 3) {
      return suffix;
    }
  }

  return serverName;
}

export function CharacterCard({
  canConnect,
  dense = false,
  state,
  onConnect,
  onDisconnect,
  onOpenMap
}: CharacterCardProps) {
  const minimapRef = useRef<HTMLCanvasElement | null>(null);
  const [isShortViewport, setIsShortViewport] = useState(() => {
    if (typeof window === "undefined") {
      return false;
    }

    return window.innerHeight <= 860;
  });
  const [collapsed, setCollapsed] = useState(() => {
    if (typeof window === "undefined") {
      return false;
    }

    const stored = window.localStorage.getItem(SIDEBAR_COLLAPSE_STORAGE_KEY);
    if (stored === "1") {
      return true;
    }
    if (stored === "0") {
      return false;
    }

    return window.innerHeight <= 900;
  });
  const connected = state.connection.status === "connected";
  const characterName = resolveDisplayName(
    state.world.self.name,
    state.connection.characterName
  );
  const badge = String(state.stats.level);
  const statusLabel =
    state.connection.status === "connected"
      ? "Connected"
      : state.connection.status === "connecting"
        ? "Connecting"
        : "Offline";
  const mapLabel = state.world.map?.name ?? "Mundo";
  const mapSummary = state.world.mapId == null ? "Map --" : `Map ${state.world.mapId}`;
  const position =
    state.world.self.x != null && state.world.self.y != null
      ? `${state.world.self.x},${state.world.self.y}`
      : "--,--";
  const progression = getLevelProgress(
    state.stats.level,
    state.stats.xpCurrent,
    state.stats.xpNext
  );
  const factionLabel = getFactionStatusLabel(state.world.self.factionStatus);
  const deathLabel = state.world.self.dead ? "Fantasma" : null;
  const deadCopy = state.world.self.dead
    ? "Revive before attacking, using items, or re-entering combat flows."
    : null;
  const effectiveCollapsed = dense || collapsed || isShortViewport;

  useEffect(() => {
    if (minimapRef.current) {
      drawMinimap(minimapRef.current, state, 108);
    }
  }, [state]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    const onResize = () => {
      setIsShortViewport(window.innerHeight <= 860);
    };

    window.addEventListener("resize", onResize);
    return () => {
      window.removeEventListener("resize", onResize);
    };
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }

    window.localStorage.setItem(
      SIDEBAR_COLLAPSE_STORAGE_KEY,
      collapsed ? "1" : "0"
    );
  }, [collapsed]);

  if (dense) {
    return (
      <section className={`character-hero character-hero-dense ${state.world.self.dead ? "character-hero-dead" : ""}`}>
        <div className="character-hero-top">
          <div className="character-badge">{badge}</div>
          <div className="character-meta">
            <p className="eyebrow">Nivel {state.stats.level}</p>
            <h2 title={characterName}>{characterName}</h2>
            <p className="character-subtitle">{mapLabel}</p>
          </div>
          <div className="hero-actions">
            <button
              className="ghost-button hero-action"
              disabled={!connected && !canConnect}
              onClick={connected ? onDisconnect : onConnect}
              type="button"
            >
              {connected ? "Exit" : "Enter"}
            </button>
          </div>
        </div>

        <div className="character-dense-strip">
          <button className="character-summary-map" onClick={onOpenMap} type="button">
            <span>Mapa activo</span>
            <strong>{mapSummary}</strong>
            <small>{position}</small>
          </button>
          <div className="character-dense-xp">
            <div className="character-xp-row">
              <span>XP</span>
              <strong>
                {progression.xpIntoLevel}/{progression.xpRequiredThisLevel}
              </strong>
            </div>
            <div className="character-xp-track">
              <div
                className="character-xp-fill"
                style={{ width: `${progression.progressPercent}%` }}
              />
            </div>
          </div>
        </div>
        <div className="hero-chip-row hero-chip-row-dense">
          <span className="status-pill" data-state={state.connection.status}>
            {statusLabel}
          </span>
          {deathLabel ? <span className="hero-chip hero-chip-dead">{deathLabel}</span> : null}
          <span className="hero-chip">{factionLabel}</span>
          {state.world.self.navigating ? <span className="hero-chip hero-chip-sailing">Navegando</span> : null}
        </div>
        {deadCopy ? (
          <div className="character-dead-callout" data-testid="character-dead-callout">
            <strong>Ghost state</strong>
            <span>{deadCopy}</span>
          </div>
        ) : null}
      </section>
    );
  }

  return (
    <section
      className={`character-hero ${effectiveCollapsed ? "character-hero-collapsed" : ""} ${state.world.self.dead ? "character-hero-dead" : ""}`}
    >
      <div className="character-hero-top">
        <div className="character-badge">{badge}</div>
        <div className="character-meta">
          <p className="eyebrow">Nivel {state.stats.level}</p>
          <h2 title={characterName}>{characterName}</h2>
          <p className="character-subtitle">{mapLabel}</p>
        </div>
        <div className="hero-actions">
          <button
            className="ghost-button hero-action"
            disabled={!connected && !canConnect}
            onClick={connected ? onDisconnect : onConnect}
            type="button"
          >
            {connected ? "Exit" : "Enter"}
          </button>
          {!isShortViewport && !dense ? (
            <button
              aria-expanded={!effectiveCollapsed}
              className="ghost-button hero-toggle"
              onClick={() => setCollapsed((value) => !value)}
              type="button"
            >
              {effectiveCollapsed ? "Expand" : "Compact"}
            </button>
          ) : null}
        </div>
      </div>

      {effectiveCollapsed ? (
        <div className="character-hero-summary">
          <button
            className="character-summary-map"
            onClick={onOpenMap}
            type="button"
          >
            <span>Mapa activo</span>
            <strong>{mapSummary}</strong>
            <small>{position}</small>
          </button>
          <div className="character-summary-xp">
            <div className="character-xp-row">
              <span>XP</span>
              <strong>
                {progression.xpIntoLevel}/{progression.xpRequiredThisLevel}
              </strong>
            </div>
            <div className="character-xp-track">
              <div
                className="character-xp-fill"
                style={{ width: `${progression.progressPercent}%` }}
              />
            </div>
          </div>
        </div>
      ) : (
        <>
          <div className="character-hero-body">
            <div className="character-progression-card">
              <div className="character-xp-row">
                <span>Experiencia de este nivel</span>
                <strong>
                  {progression.xpIntoLevel}/{progression.xpRequiredThisLevel}
                </strong>
              </div>
              <div className="character-xp-track">
                <div
                  className="character-xp-fill"
                  style={{ width: `${progression.progressPercent}%` }}
                />
              </div>
              <div className="character-progress-meta">
                <div className="character-progress-chip">
                  <span>Restante</span>
                  <strong>{progression.xpRemaining} XP</strong>
                </div>
                <div className="character-progress-chip">
                  <span>Total</span>
                  <strong>
                    {state.stats.xpCurrent}/{progression.levelCeilXp}
                  </strong>
                </div>
              </div>
            </div>

            <button className="character-minimap-card" onClick={onOpenMap} type="button">
              <canvas className="character-minimap" ref={minimapRef} />
              <div className="character-minimap-copy">
                <span className="character-minimap-label">Mapa activo</span>
                <strong>{mapSummary}</strong>
                <small>{position}</small>
              </div>
            </button>
          </div>

          <div className="character-status-track">
            <div
              className={`character-status-fill character-status-fill-${state.connection.status}`}
            />
          </div>
        </>
      )}

      {!dense ? (
        <div className="hero-chip-row">
          <span className="status-pill" data-state={state.connection.status}>
            {statusLabel}
          </span>
          {deathLabel ? <span className="hero-chip hero-chip-dead">{deathLabel}</span> : null}
          <span className="hero-chip">{factionLabel}</span>
          {state.world.self.navigating ? <span className="hero-chip hero-chip-sailing">Navegando</span> : null}
          <span className="hero-chip">{mapSummary}</span>
          <span className="hero-chip">World {state.world.mapStatus}</span>
        </div>
      ) : null}
      {deadCopy ? (
        <div className="character-dead-callout" data-testid="character-dead-callout">
          <strong>Ghost state</strong>
          <span>{deadCopy}</span>
        </div>
      ) : null}
    </section>
  );
}
