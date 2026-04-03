import type { ClientState } from "../app/types";
import type { AssetCatalog } from "../render/assetCatalog";
import { getObjectIconFrame, getObjectName } from "../render/assetCatalog";

interface MerchantPanelProps {
  assetCatalog: AssetCatalog | null;
  state: ClientState;
  onClose: () => void;
  onSelectMerchantSlot: (slotIndex: number | null) => void;
  onSelectInventorySlot: (slotIndex: number | null) => void;
  onSetBuyAmount: (amount: number) => void;
  onSetSellAmount: (amount: number) => void;
  onBuy: (slotIndex: number, amount: number) => void;
  onSell: (slotIndex: number, amount: number) => void;
}

function MerchantIcon({
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

export function MerchantPanel({
  assetCatalog,
  state,
  onClose,
  onSelectMerchantSlot,
  onSelectInventorySlot,
  onSetBuyAmount,
  onSetSellAmount,
  onBuy,
  onSell
}: MerchantPanelProps) {
  const merchantSlots = state.commerce.slots;
  const selectedMerchantSlotIndex = state.commerce.selectedSlot;
  const selectedMerchantSlot =
    selectedMerchantSlotIndex == null ? null : merchantSlots[selectedMerchantSlotIndex];
  const selectedMerchantName =
    selectedMerchantSlot == null ? null : getObjectName(assetCatalog, selectedMerchantSlot.itemId);
  const selectedInventorySlotIndex = state.inventory.selectedSlot;
  const selectedInventorySlot =
    selectedInventorySlotIndex == null ? null : state.inventory.slots[selectedInventorySlotIndex];
  const selectedInventoryName =
    selectedInventorySlot == null ? null : getObjectName(assetCatalog, selectedInventorySlot.itemId);
  const buyAmount = Math.max(1, state.commerce.buyAmount);
  const sellAmount = Math.max(1, state.commerce.sellAmount);
  const canBuy = selectedMerchantSlotIndex != null && selectedMerchantSlot != null;
  const canSell = selectedInventorySlotIndex != null && selectedInventorySlot != null;

  return (
    <section className="panel merchant-panel">
      <div className="merchant-panel-header">
        <div>
          <p className="eyebrow">Comercio</p>
          <h2>{state.commerce.npcName ?? "Mercader"}</h2>
        </div>
        <button className="ghost-button" onClick={onClose} type="button">
          Cerrar
        </button>
      </div>

      <div className="merchant-banner">
        <div>
          <span>Objetivo activo</span>
          <strong>
            {state.world.targetTile
              ? `${state.world.targetTile.x},${state.world.targetTile.y}`
              : "Sin objetivo"}
          </strong>
        </div>
        <small>
          Compra del mercader y selecciona un item propio para venderlo.
        </small>
      </div>

      <div className="merchant-section">
        <div className="merchant-section-header">
          <h3>Tienda</h3>
          <span className="panel-tag">
            {merchantSlots.filter((slot) => slot != null).length} items
          </span>
        </div>
        <div className="merchant-list">
          {merchantSlots.map((slot, index) => (
            <button
              className={`merchant-row ${
                selectedMerchantSlotIndex === index ? "merchant-row-selected" : ""
              } ${slot == null ? "merchant-row-empty" : ""}`}
              key={index}
              onClick={() => onSelectMerchantSlot(slot == null ? null : index)}
              type="button"
            >
              <span className="merchant-row-slot">{index + 1}</span>
              {slot ? (
                <>
                  <MerchantIcon assetCatalog={assetCatalog} itemId={slot.itemId} />
                  <div className="merchant-row-copy">
                    <strong>{getObjectName(assetCatalog, slot.itemId)}</strong>
                    <small>
                      x{slot.amount} · {Math.floor(slot.price)} oro
                    </small>
                  </div>
                </>
              ) : (
                <div className="merchant-row-copy">
                  <strong>(vacio)</strong>
                </div>
              )}
            </button>
          ))}
        </div>
      </div>

      <div className="merchant-action-card">
        <div>
          <p className="eyebrow">Comprar</p>
          <strong>{selectedMerchantName ?? "Selecciona un item de la tienda"}</strong>
        </div>
        <div className="merchant-action-row">
          <input
            min={1}
            step={1}
            type="number"
            value={buyAmount}
            onChange={(event) => onSetBuyAmount(Number.parseInt(event.target.value, 10) || 1)}
          />
          <button
            className="ghost-button"
            disabled={!canBuy}
            onClick={() => {
              if (selectedMerchantSlotIndex != null) {
                onBuy(selectedMerchantSlotIndex, buyAmount);
              }
            }}
            type="button"
          >
            Comprar
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
              onClick={() => onSelectInventorySlot(slot == null ? null : index)}
              type="button"
            >
              {slot?.equipped ? <div className="inventory-slot-corner-badge">E</div> : null}
              {slot ? (
                <>
                  <div className="inventory-slot-icon-wrap">
                    <MerchantIcon assetCatalog={assetCatalog} itemId={slot.itemId} />
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

      <div className="merchant-action-card">
        <div>
          <p className="eyebrow">Vender</p>
          <strong>{selectedInventoryName ?? "Selecciona un item de tu inventario"}</strong>
        </div>
        <div className="merchant-action-row">
          <input
            min={1}
            step={1}
            type="number"
            value={sellAmount}
            onChange={(event) => onSetSellAmount(Number.parseInt(event.target.value, 10) || 1)}
          />
          <button
            className="ghost-button"
            disabled={!canSell}
            onClick={() => {
              if (selectedInventorySlotIndex != null) {
                onSell(selectedInventorySlotIndex, Math.min(sellAmount, selectedInventorySlot?.amount ?? sellAmount));
              }
            }}
            type="button"
          >
            Vender
          </button>
        </div>
      </div>
    </section>
  );
}
