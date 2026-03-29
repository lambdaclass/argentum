import { useState } from "react";

interface ChatPanelProps {
  onSend: (message: string) => void;
  onPickUp: () => void;
  onRequestPosition: () => void;
}

export function ChatPanel({ onSend, onPickUp, onRequestPosition }: ChatPanelProps) {
  const [message, setMessage] = useState("");

  return (
    <section className="panel">
      <div className="panel-header">
        <h2>Actions</h2>
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

      <label className="field">
        <span>Chat</span>
        <input
          type="text"
          value={message}
          onChange={(event) => setMessage(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && message.trim().length > 0) {
              onSend(message.trim());
              setMessage("");
            }
          }}
          placeholder="Type a message and press Enter"
        />
      </label>
    </section>
  );
}
