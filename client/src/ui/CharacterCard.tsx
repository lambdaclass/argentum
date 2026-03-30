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
  const badge = state.world.self.charIndex != null ? String(state.world.self.charIndex) : "AO";
  const statusLabel =
    state.connection.status === "connected"
      ? "Connected"
      : state.connection.status === "connecting"
        ? "Connecting"
        : "Offline";
  const sessionSummary = state.connection.credentials
    ? `Saved session · char_id ${state.connection.credentials.charId}`
    : "Fresh session";

  return (
    <section className="panel character-hero">
      <div className="character-hero-top">
        <div className="character-badge">{badge}</div>
        <div className="character-meta">
          <p className="eyebrow">Character</p>
          <h2 title={characterName}>{characterName}</h2>
          <p className="character-subtitle">{sessionSummary}</p>
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

      <div className="hero-chip-row">
        <span className="status-pill" data-state={state.connection.status}>
          {statusLabel}
        </span>
        <span className="hero-chip">World {state.world.mapStatus}</span>
        {state.world.self.charIndex != null ? (
          <span className="hero-chip">Char {state.world.self.charIndex}</span>
        ) : null}
      </div>
    </section>
  );
}
