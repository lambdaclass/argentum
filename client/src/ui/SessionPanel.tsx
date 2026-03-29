import type { ClientState } from "../app/types";

interface SessionPanelProps {
  assetError: string | null;
  assetStatus: "loading" | "ready" | "error";
  canConnect: boolean;
  state: ClientState;
  title: string;
  showTileDebug: boolean;
  onEndpointChange: (value: string) => void;
  onCharacterNameChange: (value: string) => void;
  onConnect: () => void;
  onDisconnect: () => void;
  onForgetSession: () => void;
}

export function SessionPanel({
  assetError,
  assetStatus,
  canConnect,
  state,
  title,
  showTileDebug,
  onEndpointChange,
  onCharacterNameChange,
  onConnect,
  onDisconnect,
  onForgetSession
}: SessionPanelProps) {
  const connected = state.connection.status === "connected";
  const credentials = state.connection.credentials;

  return (
    <section className="panel connection-panel">
      <div className="panel-header">
        <div>
          <p className="eyebrow">Argentum Online</p>
          <h2>Web Client</h2>
        </div>
        <button
          className="ghost-button"
          disabled={!connected && !canConnect}
          onClick={connected ? onDisconnect : onConnect}
          type="button"
        >
          {connected ? "Disconnect" : assetStatus === "loading" ? "Loading…" : "Connect"}
        </button>
      </div>

      <p className="panel-copy compact">{title}</p>

      <label className="field">
        <span>Endpoint</span>
        <input
          type="text"
          value={state.connection.endpoint}
          onChange={(event) => onEndpointChange(event.target.value)}
        />
      </label>

      <label className="field">
        <span>Character Name</span>
        <input
          type="text"
          value={state.connection.characterName}
          onChange={(event) => onCharacterNameChange(event.target.value)}
        />
      </label>

      <p className="field-hint">
        Reconnect uses packet <code>200</code> session credentials. If no saved
        session exists, the client creates a new character with dev defaults. The
        web client waits for the sprite/index catalog before connecting, like the
        old test client boot flow.
      </p>

      <div className="status-row">
        <span className="status-pill" data-state={state.connection.status}>
          {state.connection.status}
        </span>
        <span className="status-pill subtle">Map {state.world.mapId ?? "--"}</span>
        <span className="status-pill subtle">{state.world.mapStatus}</span>
        <span className="status-pill subtle">Assets {assetStatus}</span>
        <span className="status-pill subtle">F1 {showTileDebug ? "on" : "off"}</span>
      </div>

      {credentials ? (
        <div className="session-card">
          <p className="session-card-title">Saved Session</p>
          <p>char_id: {credentials.charId}</p>
          <button className="ghost-button" onClick={onForgetSession} type="button">
            Forget Saved Session
          </button>
        </div>
      ) : null}

      {state.connection.lastError ? (
        <div className="error-banner">{state.connection.lastError}</div>
      ) : null}

      {assetError ? (
        <div className="error-banner">{assetError}</div>
      ) : null}
    </section>
  );
}
