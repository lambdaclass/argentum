import type { ClientState, TradeOfferSlot } from "../app/types";
import type { AssetCatalog } from "../render/assetCatalog";
import { getObjectIconFrame, getObjectName } from "../render/assetCatalog";

interface TradePanelProps {
  assetCatalog: AssetCatalog | null;
  state: ClientState;
  onSelectInventorySlot: (slotIndex: number | null) => void;
  onSetOfferAmount: (amount: number) => void;
  onOffer: (itemId: number, amount: number) => void;
  onAccept: () => void;
  onReject: () => void;
  onClose: () => void;
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

function TradeOfferList({
  assetCatalog,
  title,
  gold,
  items
}: {
  assetCatalog: AssetCatalog | null;
  title: string;
  gold: number;
  items: Array<TradeOfferSlot | null>;
}) {
  return (
    <div className="trade-section">
      <div className="trade-section-header">
        <h3>{title}</h3>
        <span className="panel-tag">{gold} oro</span>
      </div>
      <div className="trade-list">
        {items.map((item, index) => (
          <div
            className={`trade-row ${item == null ? "trade-row-empty" : ""}`}
            key={`${title}-${index}`}
          >
            <span className="trade-row-slot">{index + 1}</span>
            {item ? (
              <>
                <ItemIcon assetCatalog={assetCatalog} itemId={item.itemId} />
                <div className="trade-row-copy">
                  <strong>{getObjectName(assetCatalog, item.itemId)}</strong>
                  <small>x{item.amount}</small>
                </div>
              </>
            ) : (
              <div className="trade-row-copy">
                <strong>(vacio)</strong>
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

export function TradePanel({
  assetCatalog,
  state,
  onSelectInventorySlot,
  onSetOfferAmount,
  onOffer,
  onAccept,
  onReject,
  onClose
}: TradePanelProps) {
  const selectedInventorySlotIndex = state.inventory.selectedSlot;
  const selectedInventorySlot =
    selectedInventorySlotIndex == null ? null : state.inventory.slots[selectedInventorySlotIndex];
  const selectedInventoryName =
    selectedInventorySlot == null ? null : getObjectName(assetCatalog, selectedInventorySlot.itemId);
  const offerAmount = Math.max(1, state.trade.offerAmount);
  const selectedOfferAmount = Math.min(offerAmount, selectedInventorySlot?.amount ?? offerAmount);
  const canOffer =
    selectedInventorySlotIndex != null &&
    selectedInventorySlot != null &&
    !selectedInventorySlot.equipped &&
    selectedOfferAmount > 0;

  return (
    <section className="panel trade-panel">
      <div className="merchant-panel-header">
        <div>
          <p className="eyebrow">Trueque</p>
          <h2>Comercio entre jugadores</h2>
        </div>
        <button className="ghost-button" onClick={onClose} type="button">
          Cerrar
        </button>
      </div>

      <div className="trade-banner">
        <div className="trade-banner-copy">
          <div>
            <span>Estado</span>
            <strong>{state.trade.accepted ? "Tu oferta aceptada" : "Editando oferta"}</strong>
          </div>
          <div>
            <span>Rival</span>
            <strong>{state.trade.partnerAccepted ? "Acepto" : "Esperando respuesta"}</strong>
          </div>
        </div>
        <small>Cada cambio en una oferta reinicia ambas aceptaciones.</small>
      </div>

      <div className="trade-offer-grid">
        <TradeOfferList
          assetCatalog={assetCatalog}
          title="Tu oferta"
          gold={state.trade.myOffer.gold}
          items={state.trade.myOffer.items}
        />
        <TradeOfferList
          assetCatalog={assetCatalog}
          title="Oferta rival"
          gold={state.trade.otherOffer.gold}
          items={state.trade.otherOffer.items}
        />
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

      <div className="merchant-action-card trade-action-card">
        <div>
          <p className="eyebrow">Ofrecer</p>
          <strong>{selectedInventoryName ?? "Selecciona un item de tu inventario"}</strong>
          <small className="trade-selection-copy">
            {selectedInventorySlot?.equipped
              ? "Los items equipados no pueden ofrecerse."
              : "La oferta actual usa el item seleccionado y se acumula si lo repites."}
          </small>
        </div>
        <div className="merchant-action-row">
          <input
            min={1}
            step={1}
            type="number"
            value={offerAmount}
            onChange={(event) => onSetOfferAmount(Number.parseInt(event.target.value, 10) || 1)}
          />
          <button
            className="ghost-button"
            disabled={!canOffer}
            onClick={() => {
              if (selectedInventorySlot) {
                onOffer(selectedInventorySlot.itemId, selectedOfferAmount);
              }
            }}
            type="button"
          >
            Ofrecer
          </button>
        </div>
      </div>

      <div className="trade-footer-actions">
        <button
          className={`ghost-button ${state.trade.accepted ? "classic-hud-action-primary" : ""}`}
          disabled={state.trade.accepted}
          onClick={onAccept}
          type="button"
        >
          {state.trade.accepted ? "Aceptado" : "Aceptar"}
        </button>
        <button className="ghost-button" onClick={onReject} type="button">
          Rechazar
        </button>
        <button className="ghost-button classic-hud-action-danger" onClick={onClose} type="button">
          Salir
        </button>
      </div>
    </section>
  );
}
