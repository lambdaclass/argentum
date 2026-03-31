import { useState } from "react";
import type { ClientState } from "../app/types";
import type { AssetCatalog } from "../render/assetCatalog";
import { getObjectIconFrame, getObjectName } from "../render/assetCatalog";

interface InventoryPanelProps {
  assetCatalog: AssetCatalog | null;
  compact?: boolean;
  showHeader?: boolean;
  showSelectedDetails?: boolean;
  state: ClientState;
  onSelectSlot: (slotIndex: number | null) => void;
  onEquip: (slotIndex: number) => void;
  onUse: (slotIndex: number) => void;
  onDrop: (slotIndex: number, amount: number) => void;
}

export function InventoryPanel({
  assetCatalog,
  compact = false,
  showHeader = true,
  showSelectedDetails = true,
  state,
  onSelectSlot,
  onEquip,
  onUse,
  onDrop
}: InventoryPanelProps) {
  const [tooltip, setTooltip] = useState<{
    x: number;
    y: number;
    lines: string[];
  } | null>(null);
  const selected =
    state.inventory.selectedSlot == null
      ? null
      : state.inventory.slots[state.inventory.selectedSlot];

  const selectedName =
    selected == null ? null : getObjectName(assetCatalog, selected.itemId);
  const selectedSlotLabel =
    state.inventory.selectedSlot == null ? null : `Slot ${state.inventory.selectedSlot + 1}`;
  const selectedCanUse = selected != null && selected.canUse > 0;
  const selectedCanDrop = selected != null && selected.amount > 0;

  return (
    <section className={`panel inventory-panel ${compact ? "inventory-panel-compact" : ""}`}>
      {showHeader ? (
        <div className="panel-header">
          <h2>Inventario</h2>
          <span className="panel-tag">24 slots</span>
        </div>
      ) : null}

      {!compact ? (
        <div className="inventory-stat-row">
          <span>Gold {state.stats.gold}</span>
          <span>Hunger {state.stats.hunger}</span>
          <span>Thirst {state.stats.thirst}</span>
        </div>
      ) : null}

      <div className={`inventory-grid ${compact ? "inventory-grid-compact" : ""}`}>
        {state.inventory.slots.map((slot, index) => {
          const selectedSlot = state.inventory.selectedSlot === index;
          const itemName = slot ? getObjectName(assetCatalog, slot.itemId) : null;
          const itemIcon = slot ? getObjectIconFrame(assetCatalog, slot.itemId) : null;
          const tooltipLines = slot
            ? [
                `${itemName} (#${slot.itemId})`,
                `Amount: ${slot.amount}`,
                `Value: ${Math.floor(slot.value)}`,
                `Usable: ${slot.canUse > 0 ? "yes" : "no"}`,
                slot.equipped ? "Equipped" : null
              ].filter((line): line is string => line != null)
            : [`Slot ${index + 1}`];

          return (
            <button
              className={`inventory-slot ${slot ? "" : "inventory-slot-empty"} ${
                selectedSlot ? "inventory-slot-selected" : ""
              } ${compact ? "inventory-slot-compact" : ""}`}
              key={index}
              onClick={(event) => {
                if (slot && event.shiftKey) {
                  const rawAmount = window.prompt("Drop how many?", String(slot.amount));
                  const amount = rawAmount == null ? Number.NaN : Number.parseInt(rawAmount, 10);

                  if (Number.isFinite(amount) && amount > 0) {
                    onDrop(index, Math.min(slot.amount, amount));
                  }
                  return;
                }

                if (slot) {
                  onEquip(index);
                  onSelectSlot(index);
                  return;
                }

                onSelectSlot(selectedSlot ? null : index);
              }}
              onContextMenu={(event) => {
                event.preventDefault();
                if (slot) {
                  onUse(index);
                  onSelectSlot(index);
                }
              }}
              onMouseEnter={(event) => {
                setTooltip({
                  x: event.clientX + 12,
                  y: event.clientY + 12,
                  lines: tooltipLines
                });
              }}
              onMouseMove={(event) => {
                setTooltip((current) =>
                  current
                    ? {
                        ...current,
                        x: event.clientX + 12,
                        y: event.clientY + 12
                      }
                    : current
                );
              }}
              onMouseLeave={() => setTooltip(null)}
              type="button"
            >
              {!compact ? (
                <div className="inventory-slot-topline">
                  <span>Slot {index + 1}</span>
                  {slot?.equipped ? <span className="inventory-slot-id">Eq</span> : null}
                </div>
              ) : slot?.equipped ? (
                <div className="inventory-slot-corner-badge">E</div>
              ) : null}
              {slot ? (
                <>
                  <div className="inventory-slot-icon-wrap">
                    {itemIcon ? (
                      <div
                        className="inventory-slot-icon"
                        style={{
                          width: `${itemIcon.width}px`,
                          height: `${itemIcon.height}px`,
                          backgroundImage: `url(${itemIcon.url})`,
                          backgroundPosition: `-${itemIcon.offX}px -${itemIcon.offY}px`
                        }}
                      />
                    ) : (
                      <div className="inventory-slot-icon inventory-slot-icon-fallback">?</div>
                    )}
                  </div>
                  <div className="inventory-slot-meta">
                    <small className="inventory-stack-badge">x{slot.amount}</small>
                    {!compact && slot.equipped ? <em className="inventory-equip-badge">Eq</em> : null}
                  </div>
                </>
              ) : (
                <div className="inventory-slot-empty-copy">{compact ? "" : "Empty"}</div>
              )}
            </button>
          );
        })}
      </div>

      <div className={`inventory-actions ${compact ? "inventory-actions-compact" : ""}`}>
        <button
          className="ghost-button"
          disabled={state.inventory.selectedSlot == null}
          title={selected ? `Equip or unequip ${selectedName}` : "Select an item first"}
          onClick={() => {
            if (state.inventory.selectedSlot != null) {
              onEquip(state.inventory.selectedSlot);
            }
          }}
          type="button"
        >
          Equip
        </button>
        <button
          className="ghost-button"
          disabled={!selectedCanUse}
          title={
            selected
              ? selectedCanUse
                ? `Use ${selectedName}`
                : `${selectedName} is not usable`
              : "Select an item first"
          }
          onClick={() => {
            if (state.inventory.selectedSlot != null) {
              onUse(state.inventory.selectedSlot);
            }
          }}
          type="button"
        >
          Use
        </button>
        <button
          className="ghost-button"
          disabled={!selectedCanDrop}
          title={selected ? `Drop one ${selectedName}` : "Select an item first"}
          onClick={() => {
            if (state.inventory.selectedSlot != null) {
              onDrop(state.inventory.selectedSlot, 1);
            }
          }}
          type="button"
        >
          Drop 1
        </button>
      </div>

      {!compact ? (
        <p className="inventory-hint">
          Click to equip, right-click to use, shift-click to drop an amount, and press
          <code> P </code>
          to pick up from the ground.
        </p>
      ) : null}

      {showSelectedDetails ? (
        <div className="selected-slot-card">
          {selected ? (
            <>
              <p className="session-card-title">Selected Slot</p>
              <h3 className="selected-slot-name">{selectedName}</h3>
              <div className="selected-slot-grid">
                <div className="selected-slot-item">
                  <span>Slot</span>
                  <strong>{selectedSlotLabel}</strong>
                </div>
                <div className="selected-slot-item">
                  <span>Item</span>
                  <strong>#{selected.itemId}</strong>
                </div>
                <div className="selected-slot-item">
                  <span>Amount</span>
                  <strong>{selected.amount}</strong>
                </div>
                <div className="selected-slot-item">
                  <span>Value</span>
                  <strong>{selected.value}</strong>
                </div>
                <div className="selected-slot-item">
                  <span>Equipped</span>
                  <strong>{selected.equipped ? "Yes" : "No"}</strong>
                </div>
                <div className="selected-slot-item">
                  <span>Usable</span>
                  <strong>{selected.canUse > 0 ? "Yes" : "No"}</strong>
                </div>
              </div>
            </>
          ) : (
            <p className="panel-copy compact">Select a slot to use, equip, or drop items.</p>
          )}
        </div>
      ) : null}

      {tooltip ? (
        <div className="inventory-tooltip-panel" style={{ left: tooltip.x, top: tooltip.y }}>
          {tooltip.lines.map((line) => (
            <p key={line}>{line}</p>
          ))}
        </div>
      ) : null}
    </section>
  );
}
