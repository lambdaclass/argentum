import { useEffect, useState } from "react";
import type { ClientState } from "../app/types";
import {
  getSpellAreaTargetLabel,
  getSpellMetadata,
  getSpellRequirementLabels,
  getSpellTargetLabel,
  getSpellTypeLabel
} from "../data/gameData";

interface HechizosPanelProps {
  compact?: boolean;
  connected?: boolean;
  spellHotkeys: Array<number | null>;
  state: ClientState;
  onSelectSlot: (slotIndex: number | null) => void;
  onCast: (slotIndex: number) => void;
  onBindHotkey: (hotkeyIndex: number, slotIndex: number | null) => void;
}

export function HechizosPanel({
  compact = false,
  connected = false,
  spellHotkeys,
  state,
  onSelectSlot,
  onCast,
  onBindHotkey
}: HechizosPanelProps) {
  const [showInfo, setShowInfo] = useState(false);
  const slots = state.spellbook.slots;
  const learnedCount = slots.filter(Boolean).length;
  const selectedSlotIndex = state.spellbook.selectedSlot;
  const selectedSlot = selectedSlotIndex == null ? null : slots[selectedSlotIndex];
  const selectedMetadata =
    selectedSlot == null ? null : getSpellMetadata(selectedSlot.spellId);
  const requirementLabels = getSpellRequirementLabels(selectedMetadata);
  const canCast = connected && !state.world.self.dead && selectedSlotIndex != null && selectedSlot != null;
  const spellSummary = selectedMetadata
    ? [
        `Mana ${selectedMetadata.manaRequired}`,
        `Stamina ${selectedMetadata.staminaRequired}`,
        `Skill ${selectedMetadata.minSkill}`,
        `Cooldown ${selectedMetadata.cooldown ?? 2}s`,
        `Tipo ${getSpellTypeLabel(selectedMetadata.type)}`,
        `Objetivo ${getSpellTargetLabel(selectedMetadata.target)}`
      ]
    : [];
  const targetTile = state.world.targetTile;
  const targetTerrain =
    targetTile && state.world.map
      ? state.world.map.tiles[(targetTile.y - 1) * state.world.map.width + (targetTile.x - 1)] === 2
        ? "Agua"
        : "Tierra"
      : null;
  const hotkeyLabels = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"];

  useEffect(() => {
    if (selectedSlot == null) {
      setShowInfo(false);
    }
  }, [selectedSlot]);

  return (
    <section
      className={`panel spellbook-panel ${compact ? "spellbook-panel-compact" : ""}`}
      data-testid="spellbook-panel"
    >
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

      {selectedMetadata ? (
        <div className="spellbook-summary-strip" data-testid="spellbook-summary">
          {spellSummary.map((label) => (
            <span className="spellbook-summary-chip" key={label}>
              {label}
            </span>
          ))}
          {(selectedMetadata.areaRadio ?? 0) > 0 ? (
            <span className="spellbook-summary-chip spellbook-summary-chip-area">
              Area {selectedMetadata.areaRadio} ·{" "}
              {getSpellAreaTargetLabel(selectedMetadata.areaAfecta ?? 0)}
            </span>
          ) : (
            <span className="spellbook-summary-chip spellbook-summary-chip-area">Sin area</span>
          )}
          {selectedMetadata.needStaff ? (
            <span className="spellbook-summary-chip spellbook-summary-chip-warning">Requiere baston</span>
          ) : null}
          {selectedMetadata.workOnDead ? (
            <span className="spellbook-summary-chip spellbook-summary-chip-warning">
              Funciona en muertos
            </span>
          ) : null}
        </div>
      ) : null}

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
                if (spell != null && canCast) {
                  onCast(index);
                }
              }}
              type="button"
            >
              <span>{index + 1}.</span>
              <strong>{spell?.name ?? "(vacio)"}</strong>
              {spell ? (
                <small className="spellbook-row-cost">
                  {metadata
                    ? `M ${metadata.manaRequired} · ${metadata.cooldown ?? 2}s · ${
                        getSpellTargetLabel(metadata.target)
                      }`
                    : `#${spell.spellId}`}
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
            if (selectedSlotIndex != null && canCast) {
              onCast(selectedSlotIndex);
            }
          }}
          title={
            selectedSlot == null
              ? "Selecciona un hechizo primero"
              : !connected
                ? "Conecta la sesion para lanzar hechizos"
                : state.world.self.dead
                  ? "Como fantasma solo puedes caminar"
                  : `Lanzar ${selectedSlot.name}`
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

      <div className="selected-slot-card spellbook-hotkeys-card">
        <p className="session-card-title">Macros locales</p>
        <div className="spellbook-hotkey-grid">
          {spellHotkeys.map((slotIndex, hotkeyIndex) => {
            const spell = slotIndex == null ? null : slots[slotIndex];
            const selectedBinding = selectedSlotIndex != null && slotIndex === selectedSlotIndex;

            return (
              <button
                className={`spellbook-hotkey-button ${selectedBinding ? "spellbook-hotkey-button-active" : ""}`}
                key={hotkeyLabels[hotkeyIndex]}
                onClick={() => onBindHotkey(hotkeyIndex, selectedSlotIndex)}
                onContextMenu={(event) => {
                  event.preventDefault();
                  onBindHotkey(hotkeyIndex, null);
                }}
                type="button"
              >
                <span>{hotkeyLabels[hotkeyIndex]}</span>
                <strong title={spell?.name ?? "Libre"}>{spell?.name ?? "Libre"}</strong>
              </button>
            );
          })}
        </div>
        <small className="panel-copy compact">
          Click asigna el hechizo seleccionado. Click derecho limpia. Teclas 1-0 lanzan la macro, Ctrl+1-0 asigna rapido.
        </small>
      </div>

      <div className="selected-slot-card spellbook-detail-card" data-testid="spellbook-detail">
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
                <span>Cooldown</span>
                <strong>{selectedMetadata?.cooldown ?? 2}s</strong>
              </div>
              <div className="selected-slot-item">
                <span>Area</span>
                <strong>
                  {selectedMetadata && (selectedMetadata.areaRadio ?? 0) > 0
                    ? `R${selectedMetadata.areaRadio} · ${getSpellAreaTargetLabel(selectedMetadata.areaAfecta ?? 0)}`
                    : "Directo"}
                </strong>
              </div>
              <div className="selected-slot-item">
                <span>Tile</span>
                <strong>{targetTile ? `${targetTile.x},${targetTile.y}` : "--,--"}</strong>
              </div>
              <div className="selected-slot-item">
                <span>Terreno</span>
                <strong>{targetTerrain ?? "--"}</strong>
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
              <span>Objetivo</span>
              <strong>
                {selectedMetadata ? getSpellTargetLabel(selectedMetadata.target) : "Desconocido"}
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
              <span>Area</span>
              <strong>
                {selectedMetadata && (selectedMetadata.areaRadio ?? 0) > 0
                  ? `${getSpellAreaTargetLabel(selectedMetadata.areaAfecta ?? 0)} · R${selectedMetadata.areaRadio}`
                  : "Directo"}
              </strong>
            </div>
            <div className="selected-slot-item">
              <span>Nivel max.</span>
              <strong>
                {selectedMetadata?.maxLevelCasteable && selectedMetadata.maxLevelCasteable > 0
                  ? selectedMetadata.maxLevelCasteable
                  : "Sin tope"}
              </strong>
            </div>
            <div className="selected-slot-item">
              <span>Icono</span>
              <strong>{selectedMetadata?.iconIndex || "--"}</strong>
            </div>
          </div>
          {requirementLabels.length > 0 ? (
            <div className="spellbook-requirements">
              <span>Requisitos</span>
              <div className="spellbook-requirement-list">
                {requirementLabels.map((label) => (
                  <strong className="spellbook-requirement-chip" key={label}>
                    {label}
                  </strong>
                ))}
              </div>
            </div>
          ) : null}
          <div className="spellbook-chant">
            <span>Palabras magicas</span>
            <strong>{selectedMetadata?.magicWords || "No registradas"}</strong>
          </div>
        </div>
      ) : null}
    </section>
  );
}
