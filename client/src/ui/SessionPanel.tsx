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
  onBootstrapPasswordChange: (value: string) => void;
  onConnect: () => void;
  onDisconnect: () => void;
  onForgetSession: () => void;
}

function describeRecoveryPath(error: string, hasSavedSession: boolean) {
  if (error === "Invalid session token." || error === "Character not found.") {
    return {
      title: "Saved session rejected",
      copy: hasSavedSession
        ? "The stored reconnect session is no longer valid. Forget it and sign in again with account name and password."
        : "This reconnect session is no longer valid. Sign in again with account name and password."
    };
  }

  if (error === "Wrong password.") {
    return {
      title: "Wrong password",
      copy: "Keep the same account name, correct the password, and try again."
    };
  }

  if (error === "Character name already taken.") {
    return {
      title: "Name already in use",
      copy: "Use the correct account for that character, or change the name you are trying to enter with."
    };
  }

  if (error === "WebSocket error.") {
    return {
      title: "Network path failed",
      copy: "Check the endpoint in Advanced only if the default one is not the gateway you want."
    };
  }

  if (error.includes("Connection closed during bootstrap")) {
    return {
      title: "Login did not finish",
      copy: "Your typed account name and password stay in place. Retry directly from this panel."
    };
  }

  return {
    title: "Retry from this state",
    copy: "The client kept your current session form intact so you can correct the problem and reconnect."
  };
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
  onBootstrapPasswordChange,
  onConnect,
  onDisconnect,
  onForgetSession
}: SessionPanelProps) {
  const connected = state.connection.status === "connected";
  const credentials = state.connection.credentials;
  const reconnectReady = credentials != null && !connected;
  const [showAdvanced, setShowAdvanced] = useState(false);
  const advancedVisible = showAdvanced;
  const recovery =
    state.connection.lastError == null
      ? null
      : describeRecoveryPath(state.connection.lastError, credentials != null);
  const sessionLabel =
    connected
      ? "Connected"
      : reconnectReady
        ? "Saved reconnect ready"
        : "Manual sign in";
  const accountLabel = state.connection.characterName.trim() || "No account name";
  const statusItems = [
    { label: "Status", value: sessionLabel },
    { label: "Account", value: accountLabel },
    { label: "Reconnect", value: credentials ? `char_id ${credentials.charId}` : "None saved" },
    { label: "World", value: connected ? title : state.world.mapStatus },
    { label: "Assets", value: assetStatus }
  ];

  useEffect(() => {
    if (connected) {
      setShowAdvanced(false);
    }
  }, [connected]);

  return (
    <section className="panel connection-panel">
      <div className="panel-header">
        <div>
          <p className="eyebrow">Cuenta</p>
          <h2>{connected ? "Sesion activa" : reconnectReady ? "Reconectar" : "Entrar"}</h2>
        </div>
        <button
          className="ghost-button session-primary-button"
          disabled={!connected && !canConnect}
          onClick={connected ? onDisconnect : onConnect}
          type="button"
        >
          {connected
            ? "Salir"
            : assetStatus === "loading"
              ? "Cargando..."
              : reconnectReady
                ? "Reconectar"
                : "Entrar"}
        </button>
      </div>

      <p className="panel-copy compact session-title-copy">
        {connected
          ? "This account is live. If the gateway issues a reconnect token, the client can reuse it on the next load."
          : reconnectReady
            ? "A saved reconnect session is ready. Enter directly, or forget it to switch to another account."
            : "First login creates or verifies the account tied to this character name."}
      </p>

      <div className="session-status-grid">
        {statusItems.map((item) => (
          <div className="session-status-card" key={item.label}>
            <span>{item.label}</span>
            <strong>{item.value}</strong>
          </div>
        ))}
      </div>

      {recovery ? (
        <div className="session-card session-recovery-card">
          <div>
            <p className="session-card-title">{recovery.title}</p>
            <p>{recovery.copy}</p>
          </div>
          {credentials ? (
            <button className="ghost-button" onClick={onForgetSession} type="button">
              Forget saved session
            </button>
          ) : null}
        </div>
      ) : null}

      {credentials ? (
        <div className="session-card saved-session-card">
          <div>
            <p className="session-card-title">Saved Reconnect</p>
            <p>
              char_id: {credentials.charId}
              {connected ? " · active now" : " · used on the next reconnect"}
            </p>
          </div>
          <button className="ghost-button" onClick={onForgetSession} type="button">
            Forget
          </button>
        </div>
      ) : null}

      {!connected ? (
        <div className="session-auth-fields">
          <label className="field">
            <span>Account or Character Name</span>
            <input
              disabled={reconnectReady}
              type="text"
              value={state.connection.characterName}
              onChange={(event) => onCharacterNameChange(event.target.value)}
            />
          </label>

          <label className="field">
            <span>Password</span>
            <input
              disabled={reconnectReady}
              type="password"
              value={state.connection.bootstrapPassword}
              autoComplete="current-password"
              onChange={(event) => onBootstrapPasswordChange(event.target.value)}
            />
          </label>

          <p className="field-hint session-help-text">
            {reconnectReady
              ? "Forget the saved reconnect session to sign in with another account or character name."
              : "Use the same name and password to come back later. After a successful login, the client stores the reconnect session automatically when the gateway provides one."}
          </p>
        </div>
      ) : null}

      <div className="session-inline-actions">
        <button
          className="ghost-button"
          onClick={() => setShowAdvanced((value) => !value)}
          type="button"
        >
          {advancedVisible ? "Hide Advanced" : "Advanced"}
        </button>
        <div className="session-inline-note">
          <span>Reconnect</span>
          <strong>{credentials ? "Saved session ready" : "Manual login only"}</strong>
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

          <div className="session-note-grid">
            <div className="session-note">
              <span>Gateway</span>
              <strong>Saved reconnect or manual account login</strong>
            </div>
            <div className="session-note">
              <span>Debug</span>
              <strong>F1 tile debug {showTileDebug ? "on" : "off"}</strong>
            </div>
          </div>

          <p className="field-hint session-help-text">
            Change the endpoint only when you want to target a different gateway. The
            normal path is account login first, then saved reconnect on later visits.
          </p>
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
