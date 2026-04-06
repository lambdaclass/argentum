import { useState } from "react";
import type { ClientState } from "../app/types";

interface ClansPanelProps {
  state: ClientState;
  onSendChat: (msg: string) => void;
  onClose: () => void;
}

export function ClansPanel({
  state,
  onSendChat,
  onClose
}: ClansPanelProps) {
  const [createName, setCreateName] = useState("");
  const [inviteName, setInviteName] = useState("");
  const [chatMsg, setChatMsg] = useState("");
  const clan = state.clan;
  const inClan = clan.name.length > 0;

  return (
    <section className="panel trade-panel">
      <div className="merchant-panel-header">
        <div>
          <p className="eyebrow">Clanes</p>
          <h2>{inClan ? clan.name : "Sin clan"}</h2>
        </div>
        <button className="ghost-button" onClick={onClose} type="button">
          Cerrar
        </button>
      </div>

      {inClan ? (
        <>
          <div className="merchant-section">
            <div className="merchant-section-header">
              <h3>Miembros</h3>
              <span className="panel-tag">{clan.members.length}</span>
            </div>
            <div className="trade-list">
              {clan.members.map((member) => (
                <div className="trade-row" key={member}>
                  <div className="trade-row-copy">
                    <strong>{member}</strong>
                  </div>
                </div>
              ))}
              {clan.members.length === 0 ? (
                <div className="trade-row trade-row-empty">
                  <div className="trade-row-copy">
                    <strong>(sin datos)</strong>
                  </div>
                </div>
              ) : null}
            </div>
          </div>

          <div className="merchant-action-card trade-action-card">
            <div>
              <p className="eyebrow">Invitar al clan</p>
              <small>Escribe el nombre del jugador que quieras invitar.</small>
            </div>
            <div className="merchant-action-row">
              <input
                type="text"
                placeholder="Nombre del jugador"
                value={inviteName}
                onChange={(e) => setInviteName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && inviteName.trim()) {
                    onSendChat(`/INVITARCLAN ${inviteName.trim()}`);
                    setInviteName("");
                  }
                }}
              />
              <button
                className="ghost-button"
                disabled={!inviteName.trim()}
                onClick={() => {
                  if (inviteName.trim()) {
                    onSendChat(`/INVITARCLAN ${inviteName.trim()}`);
                    setInviteName("");
                  }
                }}
                type="button"
              >
                Invitar
              </button>
            </div>
          </div>

          <div className="merchant-action-card trade-action-card">
            <div>
              <p className="eyebrow">Chat del clan</p>
            </div>
            <div className="merchant-action-row">
              <input
                type="text"
                placeholder="Mensaje al clan"
                value={chatMsg}
                onChange={(e) => setChatMsg(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && chatMsg.trim()) {
                    onSendChat(`/CC ${chatMsg.trim()}`);
                    setChatMsg("");
                  }
                }}
              />
              <button
                className="ghost-button"
                disabled={!chatMsg.trim()}
                onClick={() => {
                  if (chatMsg.trim()) {
                    onSendChat(`/CC ${chatMsg.trim()}`);
                    setChatMsg("");
                  }
                }}
                type="button"
              >
                Enviar
              </button>
            </div>
          </div>

          <div className="trade-footer-actions">
            <button
              className="ghost-button classic-hud-action-danger"
              onClick={() => onSendChat("/SALIRCLAN")}
              type="button"
            >
              Salir del clan
            </button>
          </div>
        </>
      ) : (
        <>
          <div className="merchant-action-card trade-action-card">
            <div>
              <p className="eyebrow">Crear clan</p>
              <small>Escribe el nombre para tu nuevo clan.</small>
            </div>
            <div className="merchant-action-row">
              <input
                type="text"
                placeholder="Nombre del clan"
                value={createName}
                onChange={(e) => setCreateName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && createName.trim()) {
                    onSendChat(`/CREARCLAN ${createName.trim()}`);
                    setCreateName("");
                  }
                }}
              />
              <button
                className="ghost-button"
                disabled={!createName.trim()}
                onClick={() => {
                  if (createName.trim()) {
                    onSendChat(`/CREARCLAN ${createName.trim()}`);
                    setCreateName("");
                  }
                }}
                type="button"
              >
                Crear Clan
              </button>
            </div>
          </div>

          <div className="trade-footer-actions">
            <button
              className="ghost-button classic-hud-action-primary"
              onClick={() => onSendChat("/ACEPTARCLAN")}
              type="button"
            >
              Aceptar invitacion
            </button>
          </div>
        </>
      )}
    </section>
  );
}
