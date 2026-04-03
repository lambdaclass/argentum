import { useEffect, useState } from "react";
import type { ClientState } from "../app/types";
import {
  getSpellMetadata,
  getSpellTargetLabel,
  getSpellTypeLabel
} from "../data/gameData";

interface HechizosPanelProps {
  compact?: boolean;
  connected?: boolean;
  state: ClientState;
  onSelectSlot: (slotIndex: number | null) => void;
  onCast: (slotIndex: number) => void;
}

export function HechizosPanel({
  compact = false,
  connected = false,
  state,
  onSelectSlot,
  onCast
}: HechizosPanelProps) {
  const [showInfo, setShowInfo] = useState(false);
  const slots = state.spellbook.slots;
  const learnedCount = slots.filter(Boolean).length;
  const selectedSlotIndex = state.spellbook.selectedSlot;
  const selectedSlot = selectedSlotIndex == null ? null : slots[selectedSlotIndex];
  const selectedMetadata =
    selectedSlot == null ? null : getSpellMetadata(selectedSlot.spellId);
  const canCast = connected && selectedSlotIndex != null && selectedSlot != null;
  const targetTile = state.world.targetTile;

  useEffect(() => {
    if (selectedSlot == null) {
      setShowInfo(false);
    }
  }, [selectedSlot]);

  return (
    <section className={`panel spellbook-panel ${compact ? "spellbook-panel-compact" : ""}`}>
      <div className="panel-header">
        <h2>Hechizos</h2>
        <span className="panel-tag">{learnedCount} slots</span>
      </div>

      <div className={`spellbook-banner ${learnedCount > 0 ? "spellbook-banner-active" : ""}`}>
        <div>
          <p className="session-card-title">{connected ? "Spellbook live" : "Spellbook offline"}</p>
          <strong>
            {learnedCount > 0
              ? `${learnedCount} learned spell${learnedCount === 1 ? "" : "s"}`
              : "No learned spells received yet"}
          </strong>
        </div>
        <small>
          {connected
            ? selectedSlot
              ? targetTile
                ? `Objetivo ${targetTile.x},${targetTile.y} listo para lanzar.`
                : "Marca un objetivo en el mapa o usa el hechizo sobre ti mismo."
              : "Select a learned spell to inspect or cast it."
            : "Connect first to cast spells from this list."}
        </small>
      </div>

      <div className={`spellbook-list ${compact ? "spellbook-list-compact" : ""}`}>
        {slots.map((spell, index) => {
          const metadata = spell == null ? null : getSpellMetadata(spell.spellId);

          return (
            <button
              className={`spellbook-row ${
                selectedSlotIndex === index ? "spellbook-row-selected" : ""
              } ${spell == null ? "spellbook-row-empty" : ""}`}
              key={`${spell?.spellId ?? "empty"}-${index}`}
              onClick={() => onSelectSlot(index)}
              onDoubleClick={() => {
                if (spell != null && connected) {
                  onCast(index);
                }
              }}
              type="button"
            >
              <span>{index + 1}.</span>
              <strong>{spell?.name ?? "(vacio)"}</strong>
              {spell ? (
                <small className="spellbook-row-cost">
                  {metadata ? `M ${metadata.manaRequired}` : `#${spell.spellId}`}
                </small>
              ) : null}
            </button>
          );
        })}
      </div>

      <div className="inventory-actions">
        <button
          className="ghost-button"
          disabled={!canCast}
          onClick={() => {
            if (selectedSlotIndex != null && connected) {
              onCast(selectedSlotIndex);
            }
          }}
          title={
            selectedSlot == null
              ? "Selecciona un hechizo primero"
              : connected
                ? `Lanzar ${selectedSlot.name}`
                : "Conecta la sesion para lanzar hechizos"
          }
          type="button"
        >
          Lanzar
        </button>
        <button
          className="ghost-button"
          disabled={selectedSlot == null}
          onClick={() => setShowInfo((current) => !current)}
          title={selectedSlot ? `Informacion de ${selectedSlot.name}` : "Selecciona un hechizo primero"}
          type="button"
        >
          {showInfo ? "Ocultar" : "Info"}
        </button>
      </div>

      <div className="selected-slot-card spellbook-detail-card">
        {selectedSlot ? (
          <>
            <p className="session-card-title">Hechizo seleccionado</p>
            <h3 className="selected-slot-name">{selectedSlot.name}</h3>
            <div className="selected-slot-grid">
              <div className="selected-slot-item">
                <span>Slot</span>
                <strong>#{selectedSlotIndex == null ? "--" : selectedSlotIndex + 1}</strong>
              </div>
              <div className="selected-slot-item">
                <span>ID</span>
                <strong>{selectedSlot.spellId}</strong>
              </div>
              <div className="selected-slot-item">
                <span>Mana</span>
                <strong>{selectedMetadata?.manaRequired ?? "--"}</strong>
              </div>
              <div className="selected-slot-item">
              <span>Objetivo</span>
              <strong>
                {selectedMetadata ? getSpellTargetLabel(selectedMetadata.target) : "Desconocido"}
              </strong>
            </div>
            <div className="selected-slot-item">
              <span>Tile</span>
              <strong>{targetTile ? `${targetTile.x},${targetTile.y}` : "--,--"}</strong>
            </div>
          </div>
        </>
        ) : (
          <p className="panel-copy compact">
            Selecciona un hechizo para verlo aqui.
          </p>
        )}
      </div>

      {selectedSlot && showInfo ? (
        <div className="selected-slot-card spellbook-info-card">
          <p className="session-card-title">Info del hechizo</p>
          <h3 className="selected-slot-name">{selectedSlot.name}</h3>
          <p className="spellbook-description">
            {selectedMetadata?.description || "Sin descripcion local disponible."}
          </p>
          <div className="selected-slot-grid">
            <div className="selected-slot-item">
              <span>Tipo</span>
              <strong>
                {selectedMetadata ? getSpellTypeLabel(selectedMetadata.type) : "Desconocido"}
              </strong>
            </div>
            <div className="selected-slot-item">
              <span>Stamina</span>
              <strong>{selectedMetadata?.staminaRequired ?? "--"}</strong>
            </div>
            <div className="selected-slot-item">
              <span>Skill min.</span>
              <strong>{selectedMetadata?.minSkill ?? "--"}</strong>
            </div>
            <div className="selected-slot-item">
              <span>Icono</span>
              <strong>{selectedMetadata?.iconIndex || "--"}</strong>
            </div>
          </div>
          <div className="spellbook-chant">
            <span>Palabras magicas</span>
            <strong>{selectedMetadata?.magicWords || "No registradas"}</strong>
          </div>
        </div>
      ) : null}
    </section>
  );
}
