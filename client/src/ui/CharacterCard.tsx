import { memo, useEffect, useRef, useState } from "react";
import type { ClientState } from "../app/types";
import { getFactionStatusLabel, getLevelProgress } from "../data/gameData";
import { drawMinimap } from "./minimap";

const SIDEBAR_COLLAPSE_STORAGE_KEY = "ao_sidebar_hero_collapsed";

interface CharacterCardProps {
  canConnect: boolean;
  connection: ClientState["connection"];
  dense?: boolean;
  stats: ClientState["stats"];
  world: ClientState["world"];
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

export const CharacterCard = memo(function CharacterCard({
  canConnect,
  connection,
  dense = false,
  stats,
  world,
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
  const connected = connection.status === "connected";
  const characterName = resolveDisplayName(world.self.name, connection.characterName);
  const badge = String(stats.level);
  const statusLabel =
    connection.status === "connected"
      ? "Connected"
      : connection.status === "connecting"
        ? "Connecting"
        : "Offline";
  const mapLabel = world.map?.name ?? "Mundo";
  const mapSummary = world.mapId == null ? "Map --" : `Map ${world.mapId}`;
  const position =
    world.self.x != null && world.self.y != null
      ? `${world.self.x},${world.self.y}`
      : "--,--";
  const progression = getLevelProgress(
    stats.level,
    stats.xpCurrent,
    stats.xpNext
  );
  const factionLabel = getFactionStatusLabel(world.self.factionStatus);
  const deathLabel = world.self.dead ? "Fantasma" : null;
  const effectiveCollapsed = dense || collapsed || isShortViewport;

  useEffect(() => {
    if (minimapRef.current) {
      drawMinimap(minimapRef.current, world, 108);
    }
  }, [world]);

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
      <section className={`character-hero character-hero-dense ${world.self.dead ? "character-hero-dead" : ""}`}>
        <div className="character-hero-top">
          <div className="character-badge">{badge}</div>
          <div className="character-meta">
            <p className="eyebrow">Nivel {stats.level}</p>
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
          <span className="status-pill" data-state={connection.status}>
            {statusLabel}
          </span>
          {deathLabel ? <span className="hero-chip hero-chip-dead">{deathLabel}</span> : null}
          <span className="hero-chip">{factionLabel}</span>
          {world.self.navigating ? <span className="hero-chip hero-chip-sailing">Navegando</span> : null}
        </div>
      </section>
    );
  }

  return (
    <section
      className={`character-hero ${effectiveCollapsed ? "character-hero-collapsed" : ""} ${world.self.dead ? "character-hero-dead" : ""}`}
    >
      <div className="character-hero-top">
        <div className="character-badge">{badge}</div>
        <div className="character-meta">
          <p className="eyebrow">Nivel {stats.level}</p>
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
                    {stats.xpCurrent}/{progression.levelCeilXp}
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
            <div className={`character-status-fill character-status-fill-${connection.status}`} />
          </div>
        </>
      )}

      {!dense ? (
        <div className="hero-chip-row">
          <span className="status-pill" data-state={connection.status}>
            {statusLabel}
          </span>
          {deathLabel ? <span className="hero-chip hero-chip-dead">{deathLabel}</span> : null}
          <span className="hero-chip">{factionLabel}</span>
          {world.self.navigating ? <span className="hero-chip hero-chip-sailing">Navegando</span> : null}
          <span className="hero-chip">{mapSummary}</span>
          <span className="hero-chip">World {world.mapStatus}</span>
        </div>
      ) : null}
    </section>
  );
});

CharacterCard.displayName = "CharacterCard";
