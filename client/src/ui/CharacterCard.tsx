import { useEffect, useRef } from "react";
import type { ClientState } from "../app/types";
import { getLevelProgress } from "../data/gameData";
import { drawMinimap } from "./minimap";

interface CharacterCardProps {
  canConnect: boolean;
  state: ClientState;
  onConnect: () => void;
  onDisconnect: () => void;
  onOpenMap: () => void;
}

export function CharacterCard({
  canConnect,
  state,
  onConnect,
  onDisconnect,
  onOpenMap
}: CharacterCardProps) {
  const minimapRef = useRef<HTMLCanvasElement | null>(null);
  const connected = state.connection.status === "connected";
  const characterName = state.world.self.name || state.connection.characterName || "Adventurer";
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

  useEffect(() => {
    if (minimapRef.current) {
      drawMinimap(minimapRef.current, state, 108);
    }
  }, [state]);

  return (
    <section className="character-hero">
      <div className="character-hero-top">
        <div className="character-badge">{badge}</div>
        <div className="character-meta">
          <p className="eyebrow">Nivel {state.stats.level}</p>
          <h2 title={characterName}>{characterName}</h2>
          <p className="character-subtitle">{mapLabel}</p>
        </div>
        <button
          className="ghost-button hero-action"
          disabled={!connected && !canConnect}
          onClick={connected ? onDisconnect : onConnect}
          type="button"
        >
          {connected ? "Exit" : "Enter"}
        </button>
      </div>

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
        <div className={`character-status-fill character-status-fill-${state.connection.status}`} />
      </div>

      <div className="hero-chip-row">
        <span className="status-pill" data-state={state.connection.status}>
          {statusLabel}
        </span>
        <span className="hero-chip">{mapSummary}</span>
        <span className="hero-chip">World {state.world.mapStatus}</span>
      </div>
    </section>
  );
}
