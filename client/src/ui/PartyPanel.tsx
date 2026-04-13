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
  const leaderName = party.leaderName || party.members[0] || "";

  return (
    <section className="panel trade-panel" data-testid="party-panel">
      <div className="merchant-panel-header">
        <div>
          <p className="eyebrow">Grupo</p>
          <h2>Party</h2>
          <p className="panel-copy compact">
            El panel sigue el snapshot autoritativo del servidor, igual que el cliente VB6.
          </p>
        </div>
        <button className="ghost-button" onClick={onClose} type="button">
          Cerrar
        </button>
      </div>

      <div className="trade-banner" data-testid="party-status-banner">
        <div className="trade-banner-copy">
          <div>
            <span>Estado</span>
            <strong>{inParty ? `${party.members.length} miembros` : "Sin grupo activo"}</strong>
          </div>
          <div>
            <span>Lider</span>
            <strong>{leaderName || "Sin lider"}</strong>
          </div>
          <div>
            <span>Seguridad</span>
            <strong>{party.safeMode ? "Modo seguro activado" : "Modo seguro desactivado"}</strong>
          </div>
        </div>
        <div className="hero-chip-row">
          <span className="status-pill" data-state={inParty ? "connected" : "connecting"}>
            {inParty ? "Grupo activo" : "Esperando grupo"}
          </span>
          <span className="status-pill" data-state={party.safeMode ? "connected" : "connecting"}>
            {party.safeMode ? "Seguro" : "Libre"}
          </span>
          {leaderName ? (
            <span className="status-pill" data-state="connected">
              Lider
            </span>
          ) : null}
        </div>
      </div>

      {party.invited && party.inviterName ? (
        <div className="trade-banner">
          <div className="trade-banner-copy">
            <div>
              <span>Invitacion</span>
              <strong>{party.inviterName}</strong>
              <small className="panel-copy compact">
                Acepta para sincronizarte con el grupo actual.
              </small>
            </div>
          </div>
          <button
            className="ghost-button classic-hud-action-primary"
            data-testid="party-accept-invite"
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
              <span className="panel-tag" data-testid="party-member-count">
                {party.members.length}
              </span>
            </div>
            <div className="trade-list" data-testid="party-member-list">
              {party.members.map((member) => {
                const isLeader = member === leaderName;
                const isSelf = member === selfName;

                return (
                  <div className="trade-row" key={member} data-testid={`party-member-${member}`}>
                    <div className="trade-row-copy">
                      <strong>{member}</strong>
                      <small>
                        {isLeader
                          ? "Lider del grupo"
                          : isSelf
                            ? "Tu presencia esta sincronizada"
                            : "Miembro online del grupo"}
                      </small>
                    </div>
                    {isLeader ? (
                      <span className="status-pill" data-state="connected">
                        Lider
                      </span>
                    ) : null}
                    {isSelf && !isLeader ? (
                      <span className="status-pill" data-state="connected">
                        Tu
                      </span>
                    ) : null}
                    {!isLeader && !isSelf ? (
                      <button
                        className="ghost-button classic-hud-action-danger"
                        data-testid={`party-kick-${member}`}
                        onClick={() => onSendChat(`/ECHARGRUPO ${member}`)}
                        type="button"
                      >
                        Expulsar
                      </button>
                    ) : null}
                  </div>
                );
              })}
            </div>
          </div>

          <div className="merchant-action-card trade-action-card">
            <div>
              <p className="eyebrow">Modo seguro</p>
              <small>Alterna el seguro del grupo con el estado real del servidor.</small>
            </div>
            <div className="merchant-action-row">
              <button
                className={`ghost-button ${party.safeMode ? "classic-hud-action-primary" : ""}`}
                data-testid="party-safe-toggle"
                onClick={onSendPartySafeToggle}
                type="button"
              >
                {party.safeMode ? "Seguro: ON" : "Seguro: OFF"}
              </button>
              <button
                className="ghost-button classic-hud-action-danger"
                data-testid="party-leave"
                onClick={() => onSendChat("/SALIRGRUPO")}
                type="button"
              >
                Salir
              </button>
            </div>
          </div>
        </>
      ) : (
        <div className="merchant-action-card trade-action-card">
          <div>
            <p className="eyebrow">Invitar jugador</p>
            <small>El panel usa la misma invitacion nominal que el cliente VB6.</small>
          </div>
          <div className="merchant-action-row">
            <input
              type="text"
              data-testid="party-invite-input"
              placeholder="Nombre del jugador"
              value={inviteName}
              onChange={(event) => setInviteName(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && inviteName.trim()) {
                  onSendChat(`/PARTY ${inviteName.trim()}`);
                  setInviteName("");
                }
              }}
            />
            <button
              className="ghost-button"
              data-testid="party-invite-submit"
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
