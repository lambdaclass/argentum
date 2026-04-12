import { memo, useState } from "react";
import type { ClientState } from "../app/types";
import type { AssetCatalog } from "../render/assetCatalog";
import { getObjectIconFrame, getObjectName } from "../render/assetCatalog";

function factionLabel(factionStatus: number | null): string {
  switch (factionStatus) {
    case 1:
      return "Ejercito Real";
    case 2:
      return "Legion del Caos";
    case 3:
      return "Criminal";
    case 0:
    default:
      return "Ciudadano";
  }
}

interface ClassicHudPanelProps {
  assetCatalog: AssetCatalog | null;
  combat: ClientState["combat"];
  connection: ClientState["connection"];
  inventory: ClientState["inventory"];
  onSelectSlot: (slotIndex: number | null) => void;
  onEquip: (slotIndex: number) => void;
  onUse: (slotIndex: number) => void;
  onDrop: (slotIndex: number, amount: number) => void;
  onAttack: () => void;
  onStartCommerce: () => void;
  onStartBank: () => void;
  stats: ClientState["stats"];
  onToggleSafeMode: () => void;
  world: ClientState["world"];
}

function HudBar({
  label,
  current,
  max,
  tone
}: {
  label: string;
  current: number;
  max: number;
  tone: "energy" | "mana" | "health" | "hunger" | "thirst";
}) {
  const width = max > 0 ? Math.max(0, Math.min(100, Math.round((current / max) * 100))) : 0;

  return (
    <div className="hud-stat">
      <div className="hud-stat-label-row">
        <span>{label}</span>
        <strong>
          {current}/{max}
        </strong>
      </div>
      <div className={`hud-bar hud-bar-${tone}`}>
        <div className={`hud-bar-fill hud-bar-fill-${tone}`} style={{ width: `${width}%` }} />
      </div>
    </div>
  );
}

export const ClassicHudPanel = memo(function ClassicHudPanel({
  assetCatalog,
  combat,
  connection,
  inventory,
  onSelectSlot,
  onEquip,
  onUse,
  onDrop,
  onAttack,
  onStartCommerce,
  onStartBank,
  stats,
  onToggleSafeMode,
  world
}: ClassicHudPanelProps) {
  const [tooltip, setTooltip] = useState<{
    x: number;
    y: number;
    lines: string[];
  } | null>(null);
  const isDead = world.self.dead;
  const selected =
    inventory.selectedSlot == null
      ? null
      : inventory.slots[inventory.selectedSlot];
  const selectedName =
    selected == null ? null : getObjectName(assetCatalog, selected.itemId);
  const selectedCanUse = selected != null && selected.canUse > 0 && !isDead;
  const selectedCanDrop = selected != null && selected.amount > 0 && !isDead;
  const selectedEquipped = selected?.equipped === true;
  const targetTile = world.targetTile;
  const slotLabel =
    inventory.selectedSlot == null
      ? `${inventory.slots.length} slots`
      : `Slot ${inventory.selectedSlot + 1} / ${inventory.slots.length}`;
  const connectionLabel =
    connection.status === "connected"
      ? "Conectado"
      : connection.status === "connecting"
        ? "Conectando"
        : "Offline";
  const selectionHint =
    isDead
      ? "Como fantasma solo puedes caminar."
      : selected == null
      ? "Click equipa, clic derecho usa, Shift tira."
      : selectedEquipped
        ? "Equipado ahora."
        : selectedCanUse
          ? "Listo para usar."
          : "Listo para equipar.";
  const targetLabel = targetTile ? `${targetTile.x},${targetTile.y}` : "Sin objetivo";

  return (
    <section className={`panel classic-hud-panel ${isDead ? "classic-hud-panel-dead" : ""}`}>
      <div className="classic-hud-topline">
        <div>
          <p className="eyebrow">Inventario</p>
          <h2 title={selectedName ?? "Mochila"}>{selectedName ?? "Mochila"}</h2>
        </div>
        <span className="panel-tag">{slotLabel}</span>
      </div>

      <div className={`classic-hud-selection ${selected ? "classic-hud-selection-active" : ""}`}>
        <div className="classic-hud-selection-copy">
          <span>{selected ? "Seleccionado" : "Sin seleccion"}</span>
          <strong>{selectedName ?? "Elige un item del inventario"}</strong>
        </div>
        <small>{selectionHint}</small>
      </div>

      <div className="classic-hud-combat-card">
        <div className="classic-hud-combat-copy">
          <div>
            <span>Objetivo</span>
            <strong>{targetLabel}</strong>
          </div>
          <div>
            <span>Ultimo evento</span>
            <strong>{combat.lastEvent ?? "Sin novedades"}</strong>
          </div>
        </div>
        <div className="classic-hud-combat-actions">
          <button
            className={`ghost-button ${targetTile ? "classic-hud-action-primary" : ""}`}
            disabled={targetTile == null || connection.status !== "connected" || isDead}
            onClick={onAttack}
            type="button"
          >
            Atacar
          </button>
          <button
            className={`ghost-button ${targetTile ? "classic-hud-action-primary" : ""}`}
            disabled={targetTile == null || connection.status !== "connected" || isDead}
            onClick={onStartCommerce}
            type="button"
          >
            Comercio
          </button>
          <button
            className={`ghost-button ${targetTile ? "classic-hud-action-primary" : ""}`}
            disabled={targetTile == null || connection.status !== "connected" || isDead}
            onClick={onStartBank}
            type="button"
          >
            Banco
          </button>
          <button
            className={`ghost-button ${
              combat.safeMode ? "classic-hud-action-primary" : ""
            }`}
            disabled={connection.status !== "connected" || isDead}
            onClick={onToggleSafeMode}
            type="button"
          >
            {combat.safeMode ? "Seguro ON" : "Seguro OFF"}
          </button>
        </div>
      </div>

      <div className="classic-hud-inventory-well">
        <div className="inventory-grid inventory-grid-compact classic-hud-inventory-grid">
          {inventory.slots.map((slot, index) => {
            const selectedSlot = inventory.selectedSlot === index;
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
                className={`inventory-slot inventory-slot-compact ${
                  slot ? "" : "inventory-slot-empty"
                } ${selectedSlot ? "inventory-slot-selected" : ""}`}
                key={index}
                onClick={(event) => {
                  if (isDead) {
                    onSelectSlot(selectedSlot ? null : index);
                    return;
                  }

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
                  if (slot && !isDead) {
                    onUse(index);
                    onSelectSlot(index);
                    return;
                  }

                  onSelectSlot(index);
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
                {slot?.equipped ? <div className="inventory-slot-corner-badge">E</div> : null}
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
                    </div>
                  </>
                ) : (
                  <div className="inventory-slot-empty-copy" />
                )}
              </button>
            );
          })}
        </div>

        <div className="inventory-actions inventory-actions-compact classic-hud-actions">
          <button
            className={`ghost-button ${
              selected != null && !selectedCanUse ? "classic-hud-action-primary" : ""
            }`}
            disabled={inventory.selectedSlot == null || isDead}
            title={selected ? `Equip or unequip ${selectedName}` : "Select an item first"}
            onClick={() => {
              if (inventory.selectedSlot != null && !isDead) {
                onEquip(inventory.selectedSlot);
              }
            }}
            type="button"
          >
            Equip
          </button>
          <button
            className={`ghost-button ${selectedCanUse ? "classic-hud-action-primary" : ""}`}
            disabled={!selectedCanUse}
            title={
              selected
                ? selectedCanUse
                  ? `Use ${selectedName}`
                  : `${selectedName} is not usable`
                : "Select an item first"
            }
            onClick={() => {
              if (inventory.selectedSlot != null && !isDead) {
                onUse(inventory.selectedSlot);
              }
            }}
            type="button"
          >
            Use
          </button>
          <button
            className="ghost-button classic-hud-action-danger"
            disabled={!selectedCanDrop}
            title={selected ? `Drop one ${selectedName}` : "Select an item first"}
            onClick={() => {
              if (inventory.selectedSlot != null && !isDead) {
                onDrop(inventory.selectedSlot, 1);
              }
            }}
            type="button"
          >
            Drop 1
          </button>
        </div>
      </div>

      <div className="classic-hud-divider" />

      <div className="classic-hud-vitals-header">
        <div>
          <p className="eyebrow">Vitales</p>
          <h3>Estado</h3>
        </div>
        <span
          className={`panel-tag classic-hud-status-tag classic-hud-status-${connection.status}`}
        >
          {connectionLabel}
        </span>
      </div>

      <div className="classic-hud-vitals-well">
        <div className="classic-hud-vitals">
          <HudBar
            label="Energia"
            current={stats.staminaCurrent}
            max={stats.staminaMax}
            tone="energy"
          />
          <HudBar
            label="Mana"
            current={stats.manaCurrent}
            max={stats.manaMax}
            tone="mana"
          />
          <HudBar
            label="Salud"
            current={stats.hpCurrent}
            max={stats.hpMax}
            tone="health"
          />
          <HudBar label="Hambre" current={stats.hunger} max={100} tone="hunger" />
          <HudBar label="Sed" current={stats.thirst} max={100} tone="thirst" />
        </div>

        <div className="classic-hud-meta-grid">
          <div className="meta-card">
            <span>Oro</span>
            <strong>{stats.gold}</strong>
          </div>
          <div className="meta-card">
            <span>Vel</span>
            <strong>{world.self.speed}</strong>
          </div>
          <div className="meta-card">
            <span>Otros</span>
            <strong>{Object.keys(world.others).length}</strong>
          </div>
          <div className="meta-card">
            <span>Pos</span>
            <strong>
              {world.self.x ?? "--"},{world.self.y ?? "--"}
            </strong>
          </div>
          <div className="meta-card">
            <span>Faccion</span>
            <strong>{factionLabel(world.self.factionStatus)}</strong>
          </div>
        </div>
      </div>

      {tooltip ? (
        <div className="inventory-tooltip-panel" style={{ left: tooltip.x, top: tooltip.y }}>
          {tooltip.lines.map((line) => (
            <p key={line}>{line}</p>
          ))}
        </div>
      ) : null}
    </section>
  );
});

ClassicHudPanel.displayName = "ClassicHudPanel";
