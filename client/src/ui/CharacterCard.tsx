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

  return (
    <section className="panel character-hero">
      <div className="character-hero-top">
        <div className="character-badge">{badge}</div>
        <div className="character-meta">
          <p className="eyebrow">Character</p>
          <h2>{characterName}</h2>
          <p className="character-subtitle">
            {mapLabel} · Pos {position}
          </p>
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
        <strong>{connected ? "Connected" : state.connection.status}</strong>
      </div>
      <div className="hero-progress-track" aria-hidden="true">
        <div className="hero-progress-fill" style={{ width: `${hpWidth}%` }} />
      </div>

      <div className="hero-chip-row">
        <span className="hero-chip">{mapLabel}</span>
        <span className="hero-chip">HP {state.stats.hpCurrent}</span>
        <span className="hero-chip">Mana {state.stats.manaCurrent}</span>
      </div>
    </section>
  );
}
