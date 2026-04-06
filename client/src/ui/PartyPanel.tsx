import { useState } from "react";
import type { ClientState } from "../app/types";

interface PartyPanelProps {
  state: ClientState;
  onSendChat: (msg: string) => void;
  onSendPartySafeToggle: () => void;
  onClose: () => void;
}

export function PartyPanel({
  state,
  onSendChat,
  onSendPartySafeToggle,
  onClose
}: PartyPanelProps) {
  const [inviteName, setInviteName] = useState("");
  const party = state.party;
  const inParty = party.members.length > 0;
  const selfName = state.world.self.name;

  return (
    <section className="panel trade-panel">
      <div className="merchant-panel-header">
        <div>
          <p className="eyebrow">Grupo</p>
          <h2>Party</h2>
        </div>
        <button className="ghost-button" onClick={onClose} type="button">
          Cerrar
        </button>
      </div>

      {party.invited && party.inviterName ? (
        <div className="trade-banner">
          <div className="trade-banner-copy">
            <div>
              <span>Invitacion de</span>
              <strong>{party.inviterName}</strong>
            </div>
          </div>
          <button
            className="ghost-button classic-hud-action-primary"
            onClick={() => onSendChat("/ACEPTARGRUPO")}
            type="button"
          >
            Aceptar
          </button>
        </div>
      ) : null}

      {inParty ? (
        <>
          <div className="merchant-section">
            <div className="merchant-section-header">
              <h3>Miembros</h3>
              <span className="panel-tag">{party.members.length}</span>
            </div>
            <div className="trade-list">
              {party.members.map((member) => (
                <div className="trade-row" key={member}>
                  <div className="trade-row-copy">
                    <strong>{member}</strong>
                  </div>
                  {member !== selfName ? (
                    <button
                      className="ghost-button classic-hud-action-danger"
                      onClick={() => onSendChat(`/ECHARGRUPO ${member}`)}
                      type="button"
                    >
                      Echar
                    </button>
                  ) : null}
                </div>
              ))}
            </div>
          </div>

          <div className="trade-footer-actions">
            <button
              className={`ghost-button ${party.safeMode ? "classic-hud-action-primary" : ""}`}
              onClick={onSendPartySafeToggle}
              type="button"
            >
              {party.safeMode ? "Seguro: ON" : "Seguro: OFF"}
            </button>
            <button
              className="ghost-button classic-hud-action-danger"
              onClick={() => onSendChat("/SALIRGRUPO")}
              type="button"
            >
              Salir
            </button>
          </div>
        </>
      ) : (
        <div className="merchant-action-card trade-action-card">
          <div>
            <p className="eyebrow">Invitar jugador</p>
            <small>Escribe el nombre del jugador que quieras invitar al grupo.</small>
          </div>
          <div className="merchant-action-row">
            <input
              type="text"
              placeholder="Nombre del jugador"
              value={inviteName}
              onChange={(e) => setInviteName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && inviteName.trim()) {
                  onSendChat(`/PARTY ${inviteName.trim()}`);
                  setInviteName("");
                }
              }}
            />
            <button
              className="ghost-button"
              disabled={!inviteName.trim()}
              onClick={() => {
                if (inviteName.trim()) {
                  onSendChat(`/PARTY ${inviteName.trim()}`);
                  setInviteName("");
                }
              }}
              type="button"
            >
              Invitar
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
