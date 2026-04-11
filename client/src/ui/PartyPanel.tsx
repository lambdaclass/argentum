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
  const memberCount = party.members.length;
  const inviteLabel =
    party.invited && party.inviterName.length > 0
      ? `Invitacion pendiente de ${party.inviterName}`
      : "Sin invitaciones";
  const partyLabel = inParty ? `${memberCount} miembros sincronizados` : "Sin grupo activo";
  const safeLabel = party.safeMode ? "Modo seguro activado" : "Modo seguro desactivado";

  return (
    <section className="panel trade-panel" data-testid="party-panel">
      <div className="merchant-panel-header">
        <div>
          <p className="eyebrow">Grupo</p>
          <h2>Party</h2>
          <p className="panel-copy compact">
            El panel muestra el estado real que ya conoce el cliente: miembros sincronizados,
            invitaciones pendientes y el modo seguro del grupo.
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
            <strong>{partyLabel}</strong>
          </div>
          <div>
            <span>Seguridad</span>
            <strong>{safeLabel}</strong>
          </div>
          <div>
            <span>Invitacion</span>
            <strong>{inviteLabel}</strong>
          </div>
        </div>
        <div className="hero-chip-row">
          <span className="status-pill" data-state={inParty ? "connected" : "connecting"}>
            {inParty ? "Grupo activo" : "Esperando grupo"}
          </span>
          <span className="status-pill" data-state={party.safeMode ? "connected" : "connecting"}>
            {party.safeMode ? "Seguro" : "Libre"}
          </span>
        </div>
      </div>

      {party.invited && party.inviterName ? (
        <div className="trade-banner">
          <div className="trade-banner-copy">
            <div>
              <span>Invitacion de</span>
              <strong>{party.inviterName}</strong>
              <small className="panel-copy compact">
                Acepta para sincronizarte con el grupo que ya reporta el servidor.
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
                {memberCount}
              </span>
            </div>
            <div className="trade-list" data-testid="party-member-list">
              {party.members.map((member) => (
                <div className="trade-row" key={member} data-testid={`party-member-${member}`}>
                  <div className="trade-row-copy">
                    <strong>{member}</strong>
                    <small>{member === selfName ? "Tu presencia está sincronizada" : "Miembro del grupo"}</small>
                  </div>
                  {member === selfName ? (
                    <span className="status-pill" data-state="connected">
                      Tú
                    </span>
                  ) : null}
                  {member !== selfName ? (
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
              ))}
              {party.members.length === 0 ? (
                <div className="trade-row trade-row-empty">
                  <div className="trade-row-copy">
                    <strong>Tu grupo todavía no tiene miembros sincronizados.</strong>
                    <small>El cliente solo presenta la lista que ya envía el servidor.</small>
                  </div>
                </div>
              ) : null}
            </div>
          </div>

          <div className="merchant-action-card trade-action-card">
            <div>
              <p className="eyebrow">Modo seguro</p>
              <small>
                Alterna la protección del grupo con el estado real que ya conoce el cliente.
              </small>
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

          <div className="trade-footer-actions">
            <span className="panel-copy compact">
              {inParty
                ? "Solo puedes expulsar o salir con el estado de grupo que ya fue sincronizado."
                : "Usa la invitación o envía una invitación al jugador correcto."}
            </span>
          </div>
        </>
      ) : (
        <div className="merchant-action-card trade-action-card">
          <div>
            <p className="eyebrow">Invitar jugador</p>
            <small>Escribe el nombre del jugador que quieras invitar al grupo. El panel solo usa la
              información que ya vive en el cliente.</small>
          </div>
          <div className="merchant-action-row">
            <input
              type="text"
              data-testid="party-invite-input"
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
