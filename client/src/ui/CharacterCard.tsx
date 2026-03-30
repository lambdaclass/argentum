import type { ClientState } from "../app/types";

interface CharacterCardProps {
  canConnect: boolean;
  state: ClientState;
  onConnect: () => void;
  onDisconnect: () => void;
}

export function CharacterCard({ canConnect, state, onConnect, onDisconnect }: CharacterCardProps) {
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
  const xpCurrent = Math.max(state.stats.xpCurrent, 0);
  const xpNext = Math.max(state.stats.xpNext, 1);
  const xpPercent = Math.max(0, Math.min(100, Math.round((xpCurrent / xpNext) * 100)));

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

      <div className="character-xp">
        <div className="character-xp-row">
          <span>Experiencia</span>
          <strong>
            {xpCurrent}/{xpNext}
          </strong>
        </div>
        <div className="character-xp-track">
          <div className="character-xp-fill" style={{ width: `${xpPercent}%` }} />
        </div>
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
