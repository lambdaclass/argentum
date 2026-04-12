import { memo, useEffect, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import {
  DEFAULT_KEY_BINDINGS,
  KEY_BINDING_FIELDS,
  formatBindingKey,
  normalizeBindingKey
} from "../app/settings";
import type { ClientState, KeyBindingAction } from "../app/types";

interface SessionPanelProps {
  assetError: string | null;
  assetStatus: "loading" | "ready" | "error";
  canConnect: boolean;
  connection: ClientState["connection"];
  mapPackError: string | null;
  mapPackProgressLabel: string;
  mapPackStatus: "loading" | "ready" | "error";
  settings: ClientState["settings"];
  title: string;
  showTileDebug: boolean;
  world: ClientState["world"];
  onEndpointChange: (value: string) => void;
  onCharacterNameChange: (value: string) => void;
  onBootstrapPasswordChange: (value: string) => void;
  onConnect: () => void;
  onDisconnect: () => void;
  onForgetSession: () => void;
  onReloadPage: () => void;
  onResetKeyBindings: () => void;
  onResetRuntime: () => void;
  onRetryAssets: () => void;
  onRetryBootstrap: () => void;
  onRetryMapPack: () => void;
  onSetKeyBinding: (action: KeyBindingAction, key: string | null) => void;
  onSetMusicEnabled: (enabled: boolean) => void;
  onSetMusicVolume: (volume: number) => void;
  onSetSoundEnabled: (enabled: boolean) => void;
  onSetSoundVolume: (volume: number) => void;
}

function describeRecoveryPath(error: string, hasSavedSession: boolean) {
  if (error === "Invalid session token." || error === "Character not found.") {
    return {
      tone: "warning" as const,
      title: "Saved session rejected",
      copy: hasSavedSession
        ? "The stored reconnect session is no longer valid. Forget it and sign in again with account name and password."
        : "This reconnect session is no longer valid. Sign in again with account name and password."
    };
  }

  if (error === "Wrong password.") {
    return {
      tone: "danger" as const,
      title: "Wrong password",
      copy: "Keep the same account name, correct the password, and try again."
    };
  }

  if (error === "Character name already taken.") {
    return {
      tone: "warning" as const,
      title: "Name already in use",
      copy: "Use the correct account for that character, or change the name you are trying to enter with."
    };
  }

  if (error === "WebSocket error.") {
    return {
      tone: "danger" as const,
      title: "Network path failed",
      copy: "Check the endpoint in Advanced only if the default one is not the gateway you want."
    };
  }

  if (error.includes("Connection closed during bootstrap")) {
    return {
      tone: "warning" as const,
      title: "Login did not finish",
      copy: "Your typed account name and password stay in place. Retry directly from this panel."
    };
  }

  const normalized = error.toLowerCase();

  if (normalized.includes("banned")) {
    return {
      tone: "danger" as const,
      title: "Account banned",
      copy: "This account is blocked until the backend or an admin clears the ban."
    };
  }

  if (normalized.includes("muted")) {
    return {
      tone: "warning" as const,
      title: "Chat muted",
      copy: "The account is present, but chat actions are restricted until the mute is cleared."
    };
  }

  if (normalized.includes("server full") || normalized.includes("server-full") || normalized.includes("full")) {
    return {
      tone: "warning" as const,
      title: "Server full",
      copy: "The world reached its capacity limit. Retry once a slot opens up."
    };
  }

  if (normalized.includes("maintenance")) {
    return {
      tone: "warning" as const,
      title: "Maintenance mode",
      copy: "The world is offline for maintenance. Try again when the server comes back."
    };
  }

  if (normalized.includes("token expired")) {
    return {
      tone: "danger" as const,
      title: "Session expired",
      copy: hasSavedSession
        ? "The saved reconnect token expired. Sign in again to get a fresh session."
        : "Your session expired. Sign in again to get a fresh token."
    };
  }

  return {
    tone: "neutral" as const,
    title: "Retry from this state",
    copy: "The client kept your current session form intact so you can correct the problem and reconnect."
  };
}

function describeBootstrapRecovery(
  assetStatus: SessionPanelProps["assetStatus"],
  assetError: string | null,
  mapPackStatus: SessionPanelProps["mapPackStatus"],
  mapPackError: string | null,
  mapPackProgressLabel: string
) {
  if (assetStatus === "error") {
    const message = assetError ?? "The sprite index files could not be loaded.";
    const normalized = message.toLowerCase();

    if (normalized.includes("unexpected token") || normalized.includes("not valid json")) {
      return {
        tone: "danger" as const,
        title: "Sprite indices returned HTML",
        copy: "The client asked for JSON but received an HTML page instead. Retry the asset bootstrap first. If it repeats, reload the page or check the asset route/origin."
      };
    }

    return {
      tone: "danger" as const,
      title: "Asset catalog failed",
      copy: "The browser could not load the sprite/object/NPC index data. Retry assets first, then reload the page if the endpoint is correct."
    };
  }

  if (mapPackStatus === "error") {
    const message = mapPackError ?? "The map pack could not be loaded.";
    const normalized = message.toLowerCase();

    if (normalized.includes("unsupported map pack")) {
      return {
        tone: "warning" as const,
        title: "World data version mismatch",
        copy: "The browser world pack does not match the client build. Retry world data, and reload the page if a stale cache is serving an old pack."
      };
    }

    if (normalized.includes("invalid map pack magic")) {
      return {
        tone: "danger" as const,
        title: "World pack was not valid",
        copy: "The browser downloaded something that is not a valid map pack. Retry world data, then reload the page if a stale cache or wrong route keeps responding."
      };
    }

    return {
      tone: "danger" as const,
      title: "World data failed",
      copy: "The browser could not finish the map bootstrap. Retry world data, or reload the page if the pack route changed."
    };
  }

  if (assetStatus === "loading" || mapPackStatus === "loading") {
    return {
      tone: "neutral" as const,
      title: "Preparing client data",
      copy:
        mapPackStatus === "loading"
          ? mapPackProgressLabel
          : "Loading the sprite and metadata indices used by the browser client."
    };
  }

  return {
    tone: "neutral" as const,
    title: "Client ready",
    copy: "Sprite indices and world data are loaded. You can connect or reconnect without touching the bootstrap."
  };
}

export const SessionPanel = memo(function SessionPanel({
  assetError,
  assetStatus,
  canConnect,
  connection,
  mapPackError,
  mapPackProgressLabel,
  mapPackStatus,
  settings,
  title,
  showTileDebug,
  world,
  onEndpointChange,
  onCharacterNameChange,
  onBootstrapPasswordChange,
  onConnect,
  onDisconnect,
  onForgetSession,
  onReloadPage,
  onResetKeyBindings,
  onResetRuntime,
  onRetryAssets,
  onRetryBootstrap,
  onRetryMapPack,
  onSetKeyBinding,
  onSetMusicEnabled,
  onSetMusicVolume,
  onSetSoundEnabled,
  onSetSoundVolume
}: SessionPanelProps) {
  const connected = connection.status === "connected";
  const credentials = connection.credentials;
  const reconnectReady = credentials != null && !connected;
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [capturingBinding, setCapturingBinding] = useState<KeyBindingAction | null>(null);
  const advancedVisible = showAdvanced;
  const recovery =
    connection.lastError == null
      ? null
      : describeRecoveryPath(connection.lastError, credentials != null);
  const bootstrap = describeBootstrapRecovery(
    assetStatus,
    assetError,
    mapPackStatus,
    mapPackError,
    mapPackProgressLabel
  );
  const sessionLabel =
    connected
      ? "Connected"
      : reconnectReady
        ? "Saved reconnect ready"
        : "Manual sign in";
  const accountLabel = connection.characterName.trim() || "No account name";
  const statusItems = [
    { label: "Status", value: sessionLabel },
    { label: "Account", value: accountLabel },
    { label: "Reconnect", value: credentials ? `char_id ${credentials.charId}` : "None saved" },
    { label: "World", value: connected ? title : world.mapStatus },
    { label: "Assets", value: assetStatus },
    { label: "World data", value: mapPackStatus === "loading" ? "Loading" : mapPackStatus }
  ];
  const musicPercent = Math.round(settings.audio.musicVolume * 100);
  const soundPercent = Math.round(settings.audio.soundVolume * 100);
  const rawBootstrapError = assetStatus === "error" ? assetError : mapPackStatus === "error" ? mapPackError : null;

  useEffect(() => {
    if (connected) {
      setShowAdvanced(false);
    }
  }, [connected]);

  useEffect(() => {
    if (!advancedVisible) {
      setCapturingBinding(null);
    }
  }, [advancedVisible]);

  const handleBindingCapture = (
    action: KeyBindingAction,
    event: ReactKeyboardEvent<HTMLButtonElement>
  ) => {
    if (capturingBinding !== action) {
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      setCapturingBinding(null);
      return;
    }

    if (event.key === "Backspace" || event.key === "Delete") {
      event.preventDefault();
      onSetKeyBinding(action, null);
      setCapturingBinding(null);
      return;
    }

    if (event.key === "Tab") {
      return;
    }

    const normalized = normalizeBindingKey(event.key);
    if (!normalized) {
      return;
    }

    event.preventDefault();
    onSetKeyBinding(action, normalized);
    setCapturingBinding(null);
  };

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
            : assetStatus === "loading" || mapPackStatus === "loading"
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
        <div
          className={`session-card session-recovery-card session-recovery-card-${recovery.tone}`}
          data-testid="session-error-banner"
        >
          <div>
            <div className="session-recovery-pill">
              {recovery.tone === "danger" ? "Critical" : recovery.tone === "warning" ? "Warning" : "Info"}
            </div>
            <p className="session-card-title">{recovery.title}</p>
            <p>{recovery.copy}</p>
          </div>
          <div className="session-card-actions">
            {credentials ? (
              <button className="ghost-button" onClick={onForgetSession} type="button">
                Forget saved session
              </button>
            ) : null}
            {!connected ? (
              <button className="ghost-button" disabled={!canConnect} onClick={onConnect} type="button">
                Retry login
              </button>
            ) : null}
          </div>
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

      <div className={`session-card bootstrap-status-card bootstrap-status-card-${bootstrap.tone}`}>
        <div>
          <p className="session-card-title">Client Bootstrap</p>
          <h3 className="selected-slot-name">{bootstrap.title}</h3>
          <p>{bootstrap.copy}</p>
          {rawBootstrapError ? <code className="session-error-detail">{rawBootstrapError}</code> : null}
        </div>
        <div className="session-card-actions">
          {assetStatus === "error" ? (
            <button className="ghost-button" onClick={onRetryAssets} type="button">
              Retry assets
            </button>
          ) : null}
          {mapPackStatus === "error" ? (
            <button className="ghost-button" onClick={onRetryMapPack} type="button">
              Retry world data
            </button>
          ) : null}
          <button className="ghost-button" onClick={onRetryBootstrap} type="button">
            Retry bootstrap
          </button>
          <button className="ghost-button" onClick={onReloadPage} type="button">
            Reload page
          </button>
          <button className="ghost-button" onClick={onResetRuntime} type="button">
            Reset runtime
          </button>
        </div>
      </div>

      {!connected ? (
        <div className="session-auth-fields">
          <label className="field">
            <span>Account or Character Name</span>
            <input
              disabled={reconnectReady}
              type="text"
              value={connection.characterName}
              onChange={(event) => onCharacterNameChange(event.target.value)}
            />
          </label>

          <label className="field">
            <span>Password</span>
            <input
              disabled={reconnectReady}
              type="password"
              value={connection.bootstrapPassword}
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
              value={connection.endpoint}
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
              <strong>
                {formatBindingKey(settings.controls.bindings.tileDebug)} tile debug{" "}
                {showTileDebug ? "on" : "off"}
              </strong>
            </div>
          </div>

          <div className="session-preferences-grid">
            <label className="session-setting-card">
              <div className="session-setting-header">
                <div>
                  <p className="session-card-title">Map music</p>
                  <strong>{settings.audio.musicEnabled ? `${musicPercent}%` : "Off"}</strong>
                </div>
                <input
                  checked={settings.audio.musicEnabled}
                  onChange={(event) => onSetMusicEnabled(event.target.checked)}
                  type="checkbox"
                />
              </div>
              <input
                disabled={!settings.audio.musicEnabled}
                max="100"
                min="0"
                onChange={(event) => onSetMusicVolume(Number(event.target.value) / 100)}
                type="range"
                value={musicPercent}
              />
              <small>Persisted locally for this browser client.</small>
            </label>

            <label className="session-setting-card">
              <div className="session-setting-header">
                <div>
                  <p className="session-card-title">Sound effects</p>
                  <strong>{settings.audio.soundEnabled ? `${soundPercent}%` : "Off"}</strong>
                </div>
                <input
                  checked={settings.audio.soundEnabled}
                  onChange={(event) => onSetSoundEnabled(event.target.checked)}
                  type="checkbox"
                />
              </div>
              <input
                disabled={!settings.audio.soundEnabled}
                max="100"
                min="0"
                onChange={(event) => onSetSoundVolume(Number(event.target.value) / 100)}
                type="range"
                value={soundPercent}
              />
              <small>Used for combat, UI, and world WAV effects.</small>
            </label>
          </div>

          <div className="selected-slot-card session-keybind-card">
            <div className="panel-header">
              <div>
                <p className="eyebrow">Controles</p>
                <h3>Utility bindings</h3>
              </div>
              <button className="ghost-button" onClick={onResetKeyBindings} type="button">
                Defaults
              </button>
            </div>
            <div className="session-keybind-list">
              {KEY_BINDING_FIELDS.map((field) => {
                const currentBinding = settings.controls.bindings[field.action];
                const captureArmed = capturingBinding === field.action;

                return (
                  <div className="session-keybind-row" key={field.action}>
                    <div className="session-keybind-copy">
                      <strong>{field.label}</strong>
                      <small>{field.description}</small>
                    </div>
                    <div className="session-keybind-actions">
                      <button
                        className={`ghost-button session-keybind-trigger ${
                          captureArmed ? "session-keybind-trigger-armed" : ""
                        }`}
                        onClick={() =>
                          setCapturingBinding((current) =>
                            current === field.action ? null : field.action
                          )
                        }
                        onKeyDown={(event) => handleBindingCapture(field.action, event)}
                        type="button"
                      >
                        {captureArmed ? "Press key..." : formatBindingKey(currentBinding)}
                      </button>
                      <button
                        className="ghost-button"
                        onClick={() => onSetKeyBinding(field.action, DEFAULT_KEY_BINDINGS[field.action])}
                        type="button"
                      >
                        Reset
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
            <small className="panel-copy compact">
              Movement stays on arrows/WASD. Spell macros stay in Hechizos on keys 1-0. Click a
              binding, then press a replacement key. Esc cancels. Delete clears the binding.
            </small>
          </div>

          <p className="field-hint session-help-text">
            Change the endpoint only when you want to target a different gateway. The normal path
            is account login first, then saved reconnect on later visits.
          </p>
        </div>
      ) : null}
    </section>
  );
});

SessionPanel.displayName = "SessionPanel";
