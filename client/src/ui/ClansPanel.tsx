import { useEffect, useState } from "react";
import type { ClientState } from "../app/types";

interface ClansPanelProps {
  state: ClientState;
  onSendChat: (msg: string) => void;
  onSendClanChat: (msg: string) => void;
  onRefreshInfo: () => void;
  onRefreshNews: () => void;
  onRefreshOnline: () => void;
  onRefreshLeaderInfo: () => void;
  onClose: () => void;
}

export function ClansPanel({
  state,
  onSendChat,
  onSendClanChat,
  onRefreshInfo,
  onRefreshNews,
  onRefreshOnline,
  onRefreshLeaderInfo,
  onClose
}: ClansPanelProps) {
  const [createName, setCreateName] = useState("");
  const [inviteName, setInviteName] = useState("");
  const [chatMsg, setChatMsg] = useState("");
  const clan = state.clan;
  const inClan = clan.name.length > 0;
  const isLeader = state.world.self.name.length > 0 && state.world.self.name === clan.leaderName;

  useEffect(() => {
    if (!inClan) {
      return;
    }

    onRefreshInfo();
    onRefreshNews();
    onRefreshOnline();
    if (isLeader) {
      onRefreshLeaderInfo();
    }
  }, [inClan, isLeader]);

  return (
    <section className="panel trade-panel" data-testid="clan-panel">
      <div className="merchant-panel-header">
        <div>
          <p className="eyebrow">Clanes</p>
          <h2>{inClan ? clan.name : "Sin clan"}</h2>
          <p className="panel-copy compact">
            El panel consume los snapshots VB6-style del servidor: detalles, noticias, online y
            estado del lider.
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
            <strong>{inClan ? `${clan.memberCount || clan.members.length} miembros` : "Sin clan activo"}</strong>
          </div>
          <div>
            <span>Rango</span>
            <strong>{clan.rank || "Sin rango"}</strong>
          </div>
          <div>
            <span>Lider</span>
            <strong>{clan.leaderName || "Sin lider"}</strong>
          </div>
        </div>
        <div className="hero-chip-row">
          <span className="status-pill" data-state={inClan ? "connected" : "connecting"}>
            {inClan ? "Clan activo" : "Esperando clan"}
          </span>
          {clan.alignment ? (
            <span className="status-pill" data-state="connected">
              {clan.alignment}
            </span>
          ) : null}
          {isLeader ? (
            <span className="status-pill" data-state="connected">
              Lider
            </span>
          ) : null}
        </div>
      </div>

      {inClan ? (
        <>
          <div className="clan-refresh-row">
            <button className="ghost-button" onClick={onRefreshInfo} type="button">
              Refrescar ficha
            </button>
            <button className="ghost-button" onClick={onRefreshNews} type="button">
              Noticias
            </button>
            <button className="ghost-button" onClick={onRefreshOnline} type="button">
              Online
            </button>
            {isLeader ? (
              <button className="ghost-button" onClick={onRefreshLeaderInfo} type="button">
                Solicitudes
              </button>
            ) : null}
          </div>

          <div className="merchant-section">
            <div className="merchant-section-header">
              <h3>Ficha</h3>
              <span className="panel-tag">nivel {clan.level}</span>
            </div>
            <div className="trade-list">
              <div className="trade-row">
                <div className="trade-row-copy">
                  <strong>Fundador</strong>
                  <small>{clan.founderName || "Sin dato"}</small>
                </div>
              </div>
              <div className="trade-row">
                <div className="trade-row-copy">
                  <strong>Descripcion</strong>
                  <small>{clan.description || "Sin descripcion."}</small>
                </div>
              </div>
              <div className="trade-row">
                <div className="trade-row-copy">
                  <strong>Noticias</strong>
                  <small>{clan.news || "Sin noticias."}</small>
                </div>
              </div>
              <div className="trade-row">
                <div className="trade-row-copy">
                  <strong>Progreso</strong>
                  <small>
                    EXP {clan.currentExp}/{clan.neededExp > 0 ? clan.neededExp : "max"}
                  </small>
                </div>
              </div>
            </div>
          </div>

          <div className="merchant-section">
            <div className="merchant-section-header">
              <h3>Miembros online</h3>
              <span className="panel-tag" data-testid="clan-member-count">
                {clan.onlineMembers.length}
              </span>
            </div>
            <div className="trade-list" data-testid="clan-member-list">
              {(clan.onlineMembers.length > 0 ? clan.onlineMembers : clan.members).map((member) => (
                <div className="trade-row" key={member} data-testid={`clan-member-${member}`}>
                  <div className="trade-row-copy">
                    <strong>{member}</strong>
                    <small>{member === clan.leaderName ? "Lider" : "Miembro del clan"}</small>
                  </div>
                  {member === clan.leaderName ? (
                    <span className="status-pill" data-state="connected">
                      Lider
                    </span>
                  ) : null}
                </div>
              ))}
            </div>
          </div>

          {isLeader ? (
            <div className="merchant-section">
              <div className="merchant-section-header">
                <h3>Solicitudes pendientes</h3>
                <span className="panel-tag">{clan.pendingRequests.length}</span>
              </div>
              <div className="trade-list">
                {clan.pendingRequests.length > 0 ? (
                  clan.pendingRequests.map((requestName) => (
                    <div className="trade-row" key={requestName}>
                      <div className="trade-row-copy">
                        <strong>{requestName}</strong>
                        <small>Solicitud pendiente</small>
                      </div>
                    </div>
                  ))
                ) : (
                  <div className="trade-row trade-row-empty">
                    <div className="trade-row-copy">
                      <strong>Sin solicitudes.</strong>
                    </div>
                  </div>
                )}
              </div>
            </div>
          ) : null}

          <div className="merchant-action-card trade-action-card">
            <div>
              <p className="eyebrow">Invitar al clan</p>
              <small>Envia la invitacion de clan usando el mismo flujo nominal existente.</small>
            </div>
            <div className="merchant-action-row">
              <input
                type="text"
                data-testid="clan-invite-input"
                placeholder="Nombre del jugador"
                value={inviteName}
                onChange={(event) => setInviteName(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && inviteName.trim()) {
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
              <small>Usa el paquete nativo de chat de clan del cliente VB6.</small>
            </div>
            <div className="merchant-action-row">
              <input
                type="text"
                data-testid="clan-chat-input"
                placeholder="Mensaje al clan"
                value={chatMsg}
                onChange={(event) => setChatMsg(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && chatMsg.trim()) {
                    onSendClanChat(chatMsg.trim());
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
                    onSendClanChat(chatMsg.trim());
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
              <small>El navegador sigue usando el flujo de creacion existente.</small>
            </div>
            <div className="merchant-action-row">
              <input
                type="text"
                data-testid="clan-create-input"
                placeholder="Nombre del clan"
                value={createName}
                onChange={(event) => setCreateName(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && createName.trim()) {
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
