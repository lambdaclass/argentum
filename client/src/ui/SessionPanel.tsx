import { useEffect, useState } from "react";
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
  const [showAdvanced, setShowAdvanced] = useState(false);
  const advancedVisible = !connected || showAdvanced;
  const statusItems = [
    { label: "Connection", value: state.connection.status },
    { label: "Map", value: state.world.mapId != null ? String(state.world.mapId) : "--" },
    { label: "World", value: state.world.mapStatus },
    { label: "Assets", value: assetStatus }
  ];

  useEffect(() => {
    setShowAdvanced(!connected);
  }, [connected]);

  return (
    <section className="panel connection-panel">
      <div className="panel-header">
        <div>
          <p className="eyebrow">Connection</p>
          <h2>Session</h2>
        </div>
        <button
          className="ghost-button session-primary-button"
          disabled={!connected && !canConnect}
          onClick={connected ? onDisconnect : onConnect}
          type="button"
        >
          {connected ? "Disconnect" : assetStatus === "loading" ? "Loading…" : "Connect"}
        </button>
      </div>

      <p className="panel-copy compact session-title-copy">
        {connected
          ? "Connected session. Use Advanced only for endpoint/dev changes."
          : title}
      </p>

      <div className="session-status-grid">
        {statusItems.map((item) => (
          <div className="session-status-card" key={item.label}>
            <span>{item.label}</span>
            <strong>{item.value}</strong>
          </div>
        ))}
      </div>

      <div className="session-inline-actions">
        <button
          className="ghost-button"
          onClick={() => setShowAdvanced((value) => !value)}
          type="button"
        >
          {advancedVisible ? "Hide Advanced" : "Advanced"}
        </button>
        <div className="session-inline-note">
          <span>Debug</span>
          <strong>F1 tile debug {showTileDebug ? "on" : "off"}</strong>
        </div>
      </div>

      {advancedVisible ? (
        <div className="session-advanced-fields">
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

          <div className="session-note-grid">
            <div className="session-note">
              <span>Reconnect</span>
              <strong>Packet 200 credentials</strong>
            </div>
            <div className="session-note">
              <span>Bootstrap</span>
              <strong>Assets + map pack first</strong>
            </div>
          </div>

          <p className="field-hint session-help-text">
            If no saved session exists, the client creates a new character with dev
            defaults after assets and map data finish loading.
          </p>
        </div>
      ) : null}

      {credentials ? (
        <div className="session-card saved-session-card">
          <div>
            <p className="session-card-title">Saved Session</p>
            <p>char_id: {credentials.charId}</p>
          </div>
          <button className="ghost-button" onClick={onForgetSession} type="button">
            Forget
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
