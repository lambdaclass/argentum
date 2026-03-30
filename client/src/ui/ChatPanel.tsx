import { useState } from "react";

interface ChatPanelProps {
  onSend: (message: string) => void;
  onPickUp: () => void;
  onRequestPosition: () => void;
}

export function ChatPanel({ onSend, onPickUp, onRequestPosition }: ChatPanelProps) {
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
      </div>
    </section>
  );
}
