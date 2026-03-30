import type { ClientState } from "../app/types";

interface HechizosPanelProps {
  compact?: boolean;
  state: ClientState;
  onSelectSlot: (slotIndex: number | null) => void;
}

export function HechizosPanel({
  compact = false,
  state,
  onSelectSlot
}: HechizosPanelProps) {
  const slots = state.spellbook.slots;
  const selectedSlotIndex = state.spellbook.selectedSlot;
  const selectedSlot = selectedSlotIndex == null ? null : slots[selectedSlotIndex];

  return (
    <section className={`panel spellbook-panel ${compact ? "spellbook-panel-compact" : ""}`}>
      <div className="panel-header">
        <h2>Hechizos</h2>
        <span className="panel-tag">{slots.filter(Boolean).length} slots</span>
      </div>

      <div className={`spellbook-list ${compact ? "spellbook-list-compact" : ""}`}>
        {slots.map((spell, index) => (
          <button
            className={`spellbook-row ${
              selectedSlotIndex === index ? "spellbook-row-selected" : ""
            } ${spell == null ? "spellbook-row-empty" : ""}`}
            key={`${spell?.spellId ?? "empty"}-${index}`}
            onClick={() => onSelectSlot(index)}
            type="button"
          >
            <span>{index + 1}.</span>
            <strong>{spell?.name ?? "(vacio)"}</strong>
          </button>
        ))}
      </div>

      <div className="inventory-actions">
        <button
          className="ghost-button"
          disabled={selectedSlot == null}
          title={selectedSlot ? `Lanzar ${selectedSlot.name}` : "Selecciona un hechizo primero"}
          type="button"
        >
          Lanzar
        </button>
        <button
          className="ghost-button"
          disabled={selectedSlot == null}
          title={selectedSlot ? `Informacion de ${selectedSlot.name}` : "Selecciona un hechizo primero"}
          type="button"
        >
          Info
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
            </div>
          </>
        ) : (
          <p className="panel-copy compact">
            Selecciona un hechizo para verlo aqui.
          </p>
        )}
      </div>
    </section>
  );
}
