import type { ClientState } from "../app/types";

interface CharacterCardProps {
  canConnect: boolean;
  state: ClientState;
  onConnect: () => void;
  onDisconnect: () => void;
}

function progressWidth(current: number, max: number) {
  if (max <= 0) {
    return 0;
  }

  return Math.max(0, Math.min(100, Math.round((current / max) * 100)));
}

export function CharacterCard({ canConnect, state, onConnect, onDisconnect }: CharacterCardProps) {
  const connected = state.connection.status === "connected";
  const characterName = state.world.self.name || state.connection.characterName || "Adventurer";
  const badge = state.world.self.charIndex != null ? String(state.world.self.charIndex) : "AO";
  const mapLabel = state.world.map?.name ?? `Map ${state.world.mapId ?? "--"}`;
  const position =
    state.world.self.x != null && state.world.self.y != null
      ? `${state.world.self.x},${state.world.self.y}`
      : "--,--";
  const hpWidth = progressWidth(state.stats.hpCurrent, state.stats.hpMax);

  const statusLabel = connected ? "Connected" : state.connection.status;

  return (
    <section className="panel character-hero">
      <div className="character-hero-top">
        <div className="character-badge">{badge}</div>
        <div className="character-meta">
          <p className="eyebrow">Character</p>
          <h2 title={characterName}>{characterName}</h2>
          <p className="character-subtitle">{mapLabel}</p>
          <p className="character-position">Pos {position}</p>
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

      <div className="hero-progress-copy">
        <span>Status</span>
        <strong>{statusLabel}</strong>
      </div>
      <div className="hero-progress-track" aria-hidden="true">
        <div className="hero-progress-fill" style={{ width: `${hpWidth}%` }} />
      </div>

      <div className="hero-stats-grid">
        <div className="hero-stat">
          <span>HP</span>
          <strong>
            {state.stats.hpCurrent}/{state.stats.hpMax}
          </strong>
        </div>
        <div className="hero-stat">
          <span>Mana</span>
          <strong>
            {state.stats.manaCurrent}/{state.stats.manaMax}
          </strong>
        </div>
        <div className="hero-stat">
          <span>Map</span>
          <strong>{state.world.mapId ?? "--"}</strong>
        </div>
      </div>
    </section>
  );
}
