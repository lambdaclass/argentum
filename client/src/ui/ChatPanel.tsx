import { useEffect, useMemo, useState } from "react";
import type { LogChannel, PacketLogEntry } from "../app/types";

type ChatFilter = "all" | "general" | "party" | "guild" | "faction" | "service";
type SendMode = "say" | "party" | "guild" | "faction";

interface ChatPanelProps {
  entries: PacketLogEntry[];
  selfName: string;
  onSend: (message: string) => void;
  onSendParty: (message: string) => void;
  onSendGuild: (message: string) => void;
  onSendFaction: (message: string) => void;
  onPickUp: () => void;
  onRequestPosition: () => void;
  onRequestStats: () => void;
  onRequestSkills: () => void;
  onRequestMiniStats: () => void;
  onRest: () => void;
  onMeditate: () => void;
  onHeal: () => void;
  onResucitate: () => void;
  onRequestHelp: () => void;
  onRequestMotd: () => void;
  onRequestUptime: () => void;
  onRequestInformation: () => void;
  onRequestReward: () => void;
  onRequestAccountState: () => void;
  onRequestPunishments: (name: string) => void;
}

function matchesFilter(filter: ChatFilter, channel: LogChannel) {
  switch (filter) {
    case "all":
      return channel !== "debug";
    case "general":
      return channel === "general" || channel === "system";
    case "party":
      return channel === "party";
    case "guild":
      return channel === "guild";
    case "faction":
      return channel === "faction";
    case "service":
      return channel === "service";
  }
}

export function ChatPanel({
  entries,
  selfName,
  onSend,
  onSendParty,
  onSendGuild,
  onSendFaction,
  onPickUp,
  onRequestPosition,
  onRequestStats,
  onRequestSkills,
  onRequestMiniStats,
  onRest,
  onMeditate,
  onHeal,
  onResucitate,
  onRequestHelp,
  onRequestMotd,
  onRequestUptime,
  onRequestInformation,
  onRequestReward,
  onRequestAccountState,
  onRequestPunishments
}: ChatPanelProps) {
  const [message, setMessage] = useState("");
  const [punishmentsName, setPunishmentsName] = useState(selfName);
  const [filter, setFilter] = useState<ChatFilter>("all");
  const [sendMode, setSendMode] = useState<SendMode>("say");
  const canSend = message.trim().length > 0;
  const canRequestPunishments = punishmentsName.trim().length > 0;

  const filteredEntries = useMemo(
    () => entries.filter((entry) => matchesFilter(filter, entry.channel)),
    [entries, filter]
  );

  useEffect(() => {
    setPunishmentsName((current) => (current.trim().length > 0 ? current : selfName));
  }, [selfName]);

  const sendCurrentMessage = () => {
    const trimmed = message.trim();
    if (!trimmed) {
      return;
    }

    switch (sendMode) {
      case "party":
        onSendParty(trimmed);
        break;
      case "guild":
        onSendGuild(trimmed);
        break;
      case "faction":
        onSendFaction(trimmed);
        break;
      case "say":
        onSend(trimmed);
        break;
    }

    setMessage("");
  };

  return (
    <section className="panel">
      <div className="panel-header">
        <div>
          <p className="eyebrow">Social</p>
          <h2>Chat & Services</h2>
        </div>
        <span className="panel-tag">{filteredEntries.length}</span>
      </div>

      <div className="chat-filter-row">
        {[
          ["all", "Todos"],
          ["general", "General"],
          ["party", "Grupo"],
          ["guild", "Clan"],
          ["faction", "Faccion"],
          ["service", "Servicios"]
        ].map(([key, label]) => (
          <button
            className={`ghost-button ${filter === key ? "chat-tab-active" : ""}`}
            key={key}
            onClick={() => setFilter(key as ChatFilter)}
            type="button"
          >
            {label}
          </button>
        ))}
      </div>

      <div className="packet-log chat-stream-log" data-testid="chat-stream-log">
        {filteredEntries.length > 0 ? (
          filteredEntries.map((entry) => (
            <div className={`packet-entry packet-entry-${entry.level}`} key={entry.id}>
              <span>{entry.channel.toUpperCase()}</span>
              <p>{entry.message}</p>
            </div>
          ))
        ) : (
          <div className="trade-row trade-row-empty">
            <div className="trade-row-copy">
              <strong>Sin mensajes</strong>
              <small>Esta vista se llena con los paquetes sociales y de servicio del servidor.</small>
            </div>
          </div>
        )}
      </div>

      <div className="chat-filter-row">
        {[
          ["say", "Decir"],
          ["party", "Grupo"],
          ["guild", "Clan"],
          ["faction", "Faccion"]
        ].map(([key, label]) => (
          <button
            className={`ghost-button ${sendMode === key ? "chat-tab-active" : ""}`}
            key={key}
            onClick={() => setSendMode(key as SendMode)}
            type="button"
          >
            {label}
          </button>
        ))}
      </div>

      <div className="field">
        <span>Mensaje</span>
        <div className="chat-input-row">
          <input
            type="text"
            placeholder="Escribe un mensaje y pulsa Enter"
            value={message}
            onChange={(event) => setMessage(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && canSend) {
                sendCurrentMessage();
              }
            }}
          />
          <button
            className="ghost-button"
            disabled={!canSend}
            onClick={sendCurrentMessage}
            type="button"
          >
            Enviar
          </button>
        </div>
      </div>

      <div className="action-row">
        <button className="ghost-button" onClick={onPickUp} type="button">
          Pick Up
        </button>
        <button className="ghost-button" onClick={onRequestPosition} type="button">
          Posicion
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

      <div className="chat-service-grid">
        <button className="ghost-button" onClick={onRequestHelp} type="button">
          Ayuda
        </button>
        <button className="ghost-button" onClick={onRequestMotd} type="button">
          MOTD
        </button>
        <button className="ghost-button" onClick={onRequestUptime} type="button">
          Uptime
        </button>
        <button className="ghost-button" onClick={onRequestInformation} type="button">
          Informacion
        </button>
        <button className="ghost-button" onClick={onRequestReward} type="button">
          Recompensa
        </button>
        <button className="ghost-button" onClick={onRequestAccountState} type="button">
          Balance
        </button>
      </div>

      <div className="chat-service-row">
        <input
          type="text"
          placeholder="Nombre para prontuario"
          value={punishmentsName}
          onChange={(event) => setPunishmentsName(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && canRequestPunishments) {
              onRequestPunishments(punishmentsName.trim());
            }
          }}
        />
        <button
          className="ghost-button"
          disabled={!canRequestPunishments}
          onClick={() => onRequestPunishments(punishmentsName.trim())}
          type="button"
        >
          Prontuario
        </button>
      </div>

      <p className="field-hint">
        Las salidas del backend se separan por canal: grupo, clan, faccion y servicios. Los
        envios nativos usan los mismos paquetes que el cliente VB6 cuando existen.
      </p>
    </section>
  );
}
