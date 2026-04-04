import type { ClientState } from "../app/types";
import type { AssetCatalog } from "../render/assetCatalog";
import { getObjectIconFrame, getObjectName } from "../render/assetCatalog";

interface BankPanelProps {
  assetCatalog: AssetCatalog | null;
  state: ClientState;
  onClose: () => void;
  onSelectBankSlot: (slotIndex: number | null) => void;
  onSelectInventorySlot: (slotIndex: number | null) => void;
  onSetDepositAmount: (amount: number) => void;
  onSetWithdrawAmount: (amount: number) => void;
  onSetDepositGoldAmount: (amount: number) => void;
  onSetWithdrawGoldAmount: (amount: number) => void;
  onDeposit: (inventorySlotIndex: number, amount: number, bankSlotIndex: number | null) => void;
  onWithdraw: (bankSlotIndex: number, amount: number, inventorySlotIndex: number | null) => void;
  onDepositGold: (amount: number) => void;
  onWithdrawGold: (amount: number) => void;
}

function ItemIcon({
  assetCatalog,
  itemId
}: {
  assetCatalog: AssetCatalog | null;
  itemId: number;
}) {
  const icon = getObjectIconFrame(assetCatalog, itemId);

  if (!icon) {
    return <div className="merchant-icon merchant-icon-fallback inventory-slot-icon-fallback">?</div>;
  }

  return (
    <div
      className="merchant-icon inventory-slot-icon"
      style={{
        width: `${icon.width}px`,
        height: `${icon.height}px`,
        backgroundImage: `url(${icon.url})`,
        backgroundPosition: `-${icon.offX}px -${icon.offY}px`
      }}
    />
  );
}

export function BankPanel({
  assetCatalog,
  state,
  onClose,
  onSelectBankSlot,
  onSelectInventorySlot,
  onSetDepositAmount,
  onSetWithdrawAmount,
  onSetDepositGoldAmount,
  onSetWithdrawGoldAmount,
  onDeposit,
  onWithdraw,
  onDepositGold,
  onWithdrawGold
}: BankPanelProps) {
  const bankSlots = state.bank.slots;
  const selectedBankSlotIndex = state.bank.selectedSlot;
  const selectedBankSlot = selectedBankSlotIndex == null ? null : bankSlots[selectedBankSlotIndex];
  const selectedBankName =
    selectedBankSlot == null ? null : getObjectName(assetCatalog, selectedBankSlot.itemId);
  const selectedInventorySlotIndex = state.inventory.selectedSlot;
  const selectedInventorySlot =
    selectedInventorySlotIndex == null ? null : state.inventory.slots[selectedInventorySlotIndex];
  const selectedInventoryName =
    selectedInventorySlot == null ? null : getObjectName(assetCatalog, selectedInventorySlot.itemId);
  const depositAmount = Math.max(1, state.bank.depositAmount);
  const withdrawAmount = Math.max(1, state.bank.withdrawAmount);
  const depositGoldAmount = Math.max(1, state.bank.depositGoldAmount);
  const withdrawGoldAmount = Math.max(1, state.bank.withdrawGoldAmount);
  const canDeposit = selectedInventorySlotIndex != null && selectedInventorySlot != null;
  const canWithdraw = selectedBankSlotIndex != null && selectedBankSlot != null;

  return (
    <section className="panel bank-panel">
      <div className="merchant-panel-header">
        <div>
          <p className="eyebrow">Banco</p>
          <h2>Deposito personal</h2>
        </div>
        <button className="ghost-button" onClick={onClose} type="button">
          Cerrar
        </button>
      </div>

      <div className="merchant-banner bank-banner">
        <div className="bank-banner-copy">
          <div>
            <span>Objetivo activo</span>
            <strong>
              {state.world.targetTile
                ? `${state.world.targetTile.x},${state.world.targetTile.y}`
                : "Sin objetivo"}
            </strong>
          </div>
          <div>
            <span>Oro en banco</span>
            <strong>{state.bank.bankGold}</strong>
          </div>
          <div>
            <span>Oro en mano</span>
            <strong>{state.stats.gold}</strong>
          </div>
        </div>
        <small>Selecciona un slot del banco o de tu mochila para mover objetos y oro.</small>
      </div>

      <div className="merchant-section">
        <div className="merchant-section-header">
          <h3>Banco</h3>
          <span className="panel-tag">
            {selectedBankSlotIndex == null
              ? `${bankSlots.length} slots`
              : `Slot ${selectedBankSlotIndex + 1}`}
          </span>
        </div>
        <div className="inventory-grid inventory-grid-compact bank-grid">
          {bankSlots.map((slot, index) => (
            <button
              className={`inventory-slot inventory-slot-compact ${
                slot ? "" : "inventory-slot-empty"
              } ${selectedBankSlotIndex === index ? "inventory-slot-selected" : ""}`}
              key={index}
              onClick={() => onSelectBankSlot(selectedBankSlotIndex === index ? null : index)}
              type="button"
            >
              {slot ? (
                <>
                  <div className="inventory-slot-icon-wrap">
                    <ItemIcon assetCatalog={assetCatalog} itemId={slot.itemId} />
                  </div>
                  <div className="inventory-slot-meta">
                    <small className="inventory-stack-badge">x{slot.amount}</small>
                  </div>
                </>
              ) : (
                <div className="inventory-slot-empty-copy" />
              )}
            </button>
          ))}
        </div>
      </div>

      <div className="merchant-action-card bank-action-card">
        <div>
          <p className="eyebrow">Depositar item</p>
          <strong>{selectedInventoryName ?? "Selecciona un item de tu inventario"}</strong>
          <small className="trade-selection-copy">
            {selectedBankSlotIndex == null
              ? "Se apila automaticamente o usa el primer slot libre."
              : `Destino sugerido: slot banco ${selectedBankSlotIndex + 1}.`}
          </small>
        </div>
        <div className="merchant-action-row">
          <input
            min={1}
            step={1}
            type="number"
            value={depositAmount}
            onChange={(event) => onSetDepositAmount(Number.parseInt(event.target.value, 10) || 1)}
          />
          <button
            className="ghost-button"
            disabled={!canDeposit}
            onClick={() => {
              if (selectedInventorySlotIndex != null) {
                onDeposit(
                  selectedInventorySlotIndex,
                  Math.min(depositAmount, selectedInventorySlot?.amount ?? depositAmount),
                  selectedBankSlotIndex
                );
              }
            }}
            type="button"
          >
            Depositar
          </button>
        </div>
      </div>

      <div className="merchant-section">
        <div className="merchant-section-header">
          <h3>Inventario</h3>
          <span className="panel-tag">
            {selectedInventorySlotIndex == null
              ? `${state.inventory.slots.length} slots`
              : `Slot ${selectedInventorySlotIndex + 1}`}
          </span>
        </div>
        <div className="inventory-grid inventory-grid-compact merchant-inventory-grid">
          {state.inventory.slots.map((slot, index) => (
            <button
              className={`inventory-slot inventory-slot-compact ${
                slot ? "" : "inventory-slot-empty"
              } ${selectedInventorySlotIndex === index ? "inventory-slot-selected" : ""}`}
              key={index}
              onClick={() =>
                onSelectInventorySlot(selectedInventorySlotIndex === index ? null : index)
              }
              type="button"
            >
              {slot?.equipped ? <div className="inventory-slot-corner-badge">E</div> : null}
              {slot ? (
                <>
                  <div className="inventory-slot-icon-wrap">
                    <ItemIcon assetCatalog={assetCatalog} itemId={slot.itemId} />
                  </div>
                  <div className="inventory-slot-meta">
                    <small className="inventory-stack-badge">x{slot.amount}</small>
                  </div>
                </>
              ) : (
                <div className="inventory-slot-empty-copy" />
              )}
            </button>
          ))}
        </div>
      </div>

      <div className="merchant-action-card bank-action-card">
        <div>
          <p className="eyebrow">Retirar item</p>
          <strong>{selectedBankName ?? "Selecciona un item del banco"}</strong>
          <small className="trade-selection-copy">
            {selectedInventorySlotIndex == null
              ? "El banco usara el primer slot compatible del inventario."
              : `Destino sugerido: slot mochila ${selectedInventorySlotIndex + 1}.`}
          </small>
        </div>
        <div className="merchant-action-row">
          <input
            min={1}
            step={1}
            type="number"
            value={withdrawAmount}
            onChange={(event) => onSetWithdrawAmount(Number.parseInt(event.target.value, 10) || 1)}
          />
          <button
            className="ghost-button"
            disabled={!canWithdraw}
            onClick={() => {
              if (selectedBankSlotIndex != null) {
                onWithdraw(
                  selectedBankSlotIndex,
                  Math.min(withdrawAmount, selectedBankSlot?.amount ?? withdrawAmount),
                  selectedInventorySlotIndex
                );
              }
            }}
            type="button"
          >
            Retirar
          </button>
        </div>
      </div>

      <div className="bank-gold-grid">
        <div className="merchant-action-card bank-action-card">
          <div>
            <p className="eyebrow">Depositar oro</p>
            <strong>{state.stats.gold} disponible</strong>
          </div>
          <div className="merchant-action-row">
            <input
              min={1}
              step={1}
              type="number"
              value={depositGoldAmount}
              onChange={(event) =>
                onSetDepositGoldAmount(Number.parseInt(event.target.value, 10) || 1)
              }
            />
            <button
              className="ghost-button"
              disabled={state.stats.gold <= 0}
              onClick={() => onDepositGold(Math.min(depositGoldAmount, state.stats.gold))}
              type="button"
            >
              Depositar oro
            </button>
          </div>
        </div>

        <div className="merchant-action-card bank-action-card">
          <div>
            <p className="eyebrow">Retirar oro</p>
            <strong>{state.bank.bankGold} en banco</strong>
          </div>
          <div className="merchant-action-row">
            <input
              min={1}
              step={1}
              type="number"
              value={withdrawGoldAmount}
              onChange={(event) =>
                onSetWithdrawGoldAmount(Number.parseInt(event.target.value, 10) || 1)
              }
            />
            <button
              className="ghost-button"
              disabled={state.bank.bankGold <= 0}
              onClick={() => onWithdrawGold(Math.min(withdrawGoldAmount, state.bank.bankGold))}
              type="button"
            >
              Retirar oro
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}
