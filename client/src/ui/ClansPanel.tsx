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
  const selfName = state.world.self.name;
  const clanRank = clan.rank.length > 0 ? clan.rank : "Rango pendiente";
  const clanStateLabel = inClan ? `${clan.members.length} miembros sincronizados` : "Sin clan activo";
  const clanNameLabel = inClan ? clan.name : "Sin clan";

  return (
    <section className="panel trade-panel" data-testid="clan-panel">
      <div className="merchant-panel-header">
        <div>
          <p className="eyebrow">Clanes</p>
          <h2>{clanNameLabel}</h2>
          <p className="panel-copy compact">
            El panel refleja el clan que ya está sincronizado en el estado del cliente, sin
            inventar miembros ni rangos que el servidor no haya enviado.
          </p>
        </div>
        <button className="ghost-button" onClick={onClose} type="button">
          Cerrar
        </button>
      </div>

      <div className="trade-banner" data-testid="clan-status-banner">
        <div className="trade-banner-copy">
          <div>
            <span>Estado</span>
            <strong>{clanStateLabel}</strong>
          </div>
          <div>
            <span>Rango</span>
            <strong>{clanRank}</strong>
          </div>
          <div>
            <span>Clan</span>
            <strong>{clanNameLabel}</strong>
          </div>
        </div>
        <div className="hero-chip-row">
          <span className="status-pill" data-state={inClan ? "connected" : "connecting"}>
            {inClan ? "Clan activo" : "Esperando clan"}
          </span>
          <span className="status-pill" data-state={clan.rank.length > 0 ? "connected" : "connecting"}>
            {clan.rank.length > 0 ? clan.rank : "Rango no enviado"}
          </span>
        </div>
      </div>

      {inClan ? (
        <>
          <div className="merchant-section">
            <div className="merchant-section-header">
              <h3>Miembros</h3>
              <span className="panel-tag" data-testid="clan-member-count">
                {clan.members.length}
              </span>
            </div>
            <div className="trade-list" data-testid="clan-member-list">
              {clan.members.map((member) => (
                <div className="trade-row" key={member} data-testid={`clan-member-${member}`}>
                  <div className="trade-row-copy">
                    <strong>{member}</strong>
                    <small>{member === selfName ? "Tu presencia está sincronizada" : "Miembro del clan"}</small>
                  </div>
                  {member === selfName ? (
                    <span className="status-pill" data-state="connected">
                      Tú
                    </span>
                  ) : null}
                </div>
              ))}
              {clan.members.length === 0 ? (
                <div className="trade-row trade-row-empty">
                  <div className="trade-row-copy">
                    <strong>(sin datos)</strong>
                    <small>El backend todavía no envió una lista de miembros.</small>
                  </div>
                </div>
              ) : null}
            </div>
          </div>

          <div className="merchant-action-card trade-action-card">
            <div>
              <p className="eyebrow">Invitar al clan</p>
              <small>Escribe el nombre del jugador que quieras invitar. El panel solo usa el clan
                sincronizado por el cliente.</small>
            </div>
            <div className="merchant-action-row">
              <input
                type="text"
                data-testid="clan-invite-input"
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
                data-testid="clan-invite-submit"
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
              <small>El chat usa comandos ya existentes del cliente, sin fabricar respuestas.</small>
            </div>
            <div className="merchant-action-row">
              <input
                type="text"
                data-testid="clan-chat-input"
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
                data-testid="clan-chat-submit"
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
              data-testid="clan-leave"
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
              <small>Escribe el nombre para tu nuevo clan. La UI no inventa estado de clan.</small>
            </div>
            <div className="merchant-action-row">
              <input
                type="text"
                data-testid="clan-create-input"
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
                data-testid="clan-create-submit"
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
