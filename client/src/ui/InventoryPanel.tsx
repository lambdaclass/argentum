import { useState } from "react";
import type { ClientState } from "../app/types";
import type { AssetCatalog } from "../render/assetCatalog";
import { getObjectName } from "../render/assetCatalog";

interface InventoryPanelProps {
  assetCatalog: AssetCatalog | null;
  state: ClientState;
  onSelectSlot: (slotIndex: number | null) => void;
  onEquip: (slotIndex: number) => void;
  onUse: (slotIndex: number) => void;
  onDrop: (slotIndex: number, amount: number) => void;
}

export function InventoryPanel({
  assetCatalog,
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

  return (
    <section className="panel">
      <div className="panel-header">
        <h2>Inventory</h2>
        <span className="panel-tag">24 slots</span>
      </div>

      <div className="inventory-stat-row">
        <span>Gold {state.stats.gold}</span>
        <span>Hunger {state.stats.hunger}</span>
        <span>Thirst {state.stats.thirst}</span>
      </div>

      <div className="inventory-grid">
        {state.inventory.slots.map((slot, index) => {
          const selectedSlot = state.inventory.selectedSlot === index;
          const itemName = slot ? getObjectName(assetCatalog, slot.itemId) : null;
          const tooltipLines = slot
            ? [
                `${itemName} (#${slot.itemId})`,
                `Amount: ${slot.amount}`,
                `Value: ${Math.floor(slot.value)}`,
                `Usable: ${slot.canUse > 0 ? "yes" : "no"}`,
                slot.equipped ? "Equipped" : null
              ]
                .filter((line): line is string => line != null)
            : [`Slot ${index + 1}`];

          return (
            <button
              className={`inventory-slot ${slot ? "" : "inventory-slot-empty"} ${
                selectedSlot ? "inventory-slot-selected" : ""
              }`}
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
              <span>Slot {index + 1}</span>
              {slot ? (
                <>
                  <strong className="inventory-slot-name">{itemName}</strong>
                  <div className="inventory-slot-meta">
                    <small>x{slot.amount}</small>
                    {slot.equipped ? <em>Equipped</em> : null}
                  </div>
                </>
              ) : (
                <strong>Empty</strong>
              )}
            </button>
          );
        })}
      </div>

      <div className="inventory-actions">
        <button
          className="ghost-button"
          disabled={state.inventory.selectedSlot == null}
          onClick={() => {
            if (state.inventory.selectedSlot != null) {
              onEquip(state.inventory.selectedSlot);
            }
          }}
          type="button"
        >
          Equip / Unequip
        </button>
        <button
          className="ghost-button"
          disabled={state.inventory.selectedSlot == null}
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
          disabled={state.inventory.selectedSlot == null}
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

      <p className="inventory-hint">
        Click to equip, right-click to use, shift-click to drop an amount, and press
        <code> P </code>
        to pick up from the ground.
      </p>

      <div className="selected-slot-card">
        {selected ? (
          <>
            <p className="session-card-title">Selected Slot</p>
            <p>Item: {selectedName}</p>
            <p>ID: #{selected.itemId}</p>
            <p>Amount: {selected.amount}</p>
            <p>Equipped: {selected.equipped ? "yes" : "no"}</p>
            <p>Value: {selected.value}</p>
            <p>Usable: {selected.canUse > 0 ? "yes" : "no"}</p>
          </>
        ) : (
          <p className="panel-copy compact">Select a slot to use, equip, or drop items.</p>
        )}
      </div>

      {tooltip ? (
        <div
          className="inventory-tooltip-panel"
          style={{ left: tooltip.x, top: tooltip.y }}
        >
          {tooltip.lines.map((line) => (
            <p key={line}>{line}</p>
          ))}
        </div>
      ) : null}
    </section>
  );
}
