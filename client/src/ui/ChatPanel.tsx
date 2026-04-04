import { useState } from "react";

interface ChatPanelProps {
  onSend: (message: string) => void;
  onPickUp: () => void;
  onRequestPosition: () => void;
  onRequestStats: () => void;
  onRequestSkills: () => void;
  onRequestMiniStats: () => void;
  onRest: () => void;
  onMeditate: () => void;
  onHeal: () => void;
  onResucitate: () => void;
}

export function ChatPanel({
  onSend,
  onPickUp,
  onRequestPosition,
  onRequestStats,
  onRequestSkills,
  onRequestMiniStats,
  onRest,
  onMeditate,
  onHeal,
  onResucitate
}: ChatPanelProps) {
  const [message, setMessage] = useState("");
  const canSend = message.trim().length > 0;

  return (
    <section className="panel">
      <div className="panel-header">
        <h2>Chat & Actions</h2>
        <span className="panel-tag">AO20</span>
      </div>

      <div className="action-row">
        <button className="ghost-button" onClick={onPickUp} type="button">
          Pick Up
        </button>
        <button className="ghost-button" onClick={onRequestPosition} type="button">
          Request Pos
        </button>
        <button className="ghost-button" onClick={onRequestStats} type="button">
          Stats
        </button>
        <button className="ghost-button" onClick={onRequestSkills} type="button">
          Skills
        </button>
        <button className="ghost-button" onClick={onRequestMiniStats} type="button">
          Perfil
        </button>
      </div>

      <div className="action-row">
        <button className="ghost-button" onClick={onRest} type="button">
          Descansar
        </button>
        <button className="ghost-button" onClick={onMeditate} type="button">
          Meditar
        </button>
        <button className="ghost-button" onClick={onHeal} type="button">
          Curar
        </button>
        <button className="ghost-button" onClick={onResucitate} type="button">
          Resucitar
        </button>
      </div>

      <div className="field">
        <span>Chat</span>
        <div className="chat-input-row">
          <input
            type="text"
            value={message}
            onChange={(event) => setMessage(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && canSend) {
                onSend(message.trim());
                setMessage("");
              }
            }}
            placeholder="Type a message and press Enter"
          />
          <button
            className="ghost-button"
            disabled={!canSend}
            onClick={() => {
              if (!canSend) {
                return;
              }

              onSend(message.trim());
              setMessage("");
            }}
            type="button"
          >
            Send
          </button>
        </div>
        <p className="field-hint">
          Slash commands: <code>/yell</code>, <code>/w NOMBRE</code>, <code>/online</code>,{" "}
          <code>/rest</code>, <code>/meditate</code>, <code>/heal</code>,{" "}
          <code>/resucitar</code>, <code>/stats</code>, <code>/skills</code>,{" "}
          <code>/mini</code>.
        </p>
      </div>
    </section>
  );
}
