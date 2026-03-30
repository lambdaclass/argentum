import { useEffect, useRef, useState } from "react";
import type { ClientState } from "../app/types";
import { drawMinimap } from "./minimap";

interface WorldStatusPanelProps {
  state: ClientState;
}

function clampPercent(current: number, max: number) {
  if (max <= 0) {
    return 0;
  }

  return Math.max(0, Math.min(100, Math.round((current / max) * 100)));
}

function VitalBar({
  label,
  current,
  max,
  tone
}: {
  label: string;
  current: number;
  max: number;
  tone: "health" | "mana" | "stamina";
}) {
  const width = clampPercent(current, max);

  return (
    <div className="world-vital">
      <div className="world-vital-row">
        <span>{label}</span>
        <strong>
          {current}/{max}
        </strong>
      </div>
      <div className={`world-vital-track world-vital-track-${tone}`}>
        <div className={`world-vital-fill world-vital-fill-${tone}`} style={{ width: `${width}%` }} />
      </div>
    </div>
  );
}

export function WorldStatusPanel({ state }: WorldStatusPanelProps) {
  const [expanded, setExpanded] = useState(false);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const expandedCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const mapLabel = state.world.map?.name ?? `Map ${state.world.mapId ?? "--"}`;
  const position =
    state.world.self.x != null && state.world.self.y != null
      ? `${state.world.self.x},${state.world.self.y}`
      : "--,--";
  const otherCount = Object.keys(state.world.others).length;
  const npcCount = state.world.map?.npcs.length ?? 0;
  const exitCount = state.world.map?.exits.length ?? 0;

  useEffect(() => {
    if (canvasRef.current) {
      drawMinimap(canvasRef.current, state, 156);
    }

    if (expandedCanvasRef.current) {
      drawMinimap(expandedCanvasRef.current, state, 288);
    }
  }, [expanded, state]);

  return (
    <section className="panel world-status-card">
      <div className="panel-header">
        <div>
          <p className="eyebrow">World</p>
          <h2>{mapLabel}</h2>
          <p className="world-status-subtitle">Pos {position}</p>
        </div>
        <span className="panel-tag">Map {state.world.mapId ?? "--"}</span>
      </div>

      <div className="world-status-grid">
        <div className="world-minimap-shell">
          <button
            className="world-minimap-button"
            onClick={() => setExpanded(true)}
            type="button"
          >
            <canvas className="world-minimap world-minimap-large" ref={canvasRef} />
          </button>
          <div className="world-minimap-meta">
            <p className="world-minimap-caption">Click to expand</p>
            <div className="world-minimap-legend">
              <span>Self</span>
              <span>Exits</span>
              <span>NPCs</span>
            </div>
          </div>
        </div>

        <div className="world-status-details">
          <div className="world-vitals">
            <VitalBar
              label="Health"
              current={state.stats.hpCurrent}
              max={state.stats.hpMax}
              tone="health"
            />
            <VitalBar
              label="Mana"
              current={state.stats.manaCurrent}
              max={state.stats.manaMax}
              tone="mana"
            />
            <VitalBar
              label="Stamina"
              current={state.stats.staminaCurrent}
              max={state.stats.staminaMax}
              tone="stamina"
            />
          </div>

          <div className="world-status-chip-grid world-status-chip-grid-dense">
            <div className="world-status-chip">
              <span>Position</span>
              <strong>{position}</strong>
            </div>
            <div className="world-status-chip">
              <span>Others</span>
              <strong>{otherCount}</strong>
            </div>
            <div className="world-status-chip">
              <span>NPCs</span>
              <strong>{npcCount}</strong>
            </div>
            <div className="world-status-chip">
              <span>Exits</span>
              <strong>{exitCount}</strong>
            </div>
            <div className="world-status-chip">
              <span>Gold</span>
              <strong>{state.stats.gold}</strong>
            </div>
            <div className="world-status-chip">
              <span>Hunger</span>
              <strong>{state.stats.hunger}</strong>
            </div>
            <div className="world-status-chip">
              <span>Thirst</span>
              <strong>{state.stats.thirst}</strong>
            </div>
          </div>
        </div>
      </div>

      {expanded ? (
        <div className="minimap-modal" onClick={() => setExpanded(false)} role="presentation">
          <div
            className="minimap-modal-card"
            onClick={(event) => event.stopPropagation()}
            role="dialog"
            aria-modal="true"
          >
            <div className="panel-header">
              <div>
                <p className="eyebrow">World Map</p>
                <h2>{mapLabel}</h2>
                <p className="world-status-subtitle">Pos {position}</p>
              </div>
              <button className="ghost-button" onClick={() => setExpanded(false)} type="button">
                Close
              </button>
            </div>

            <div className="minimap-modal-body">
              <canvas className="world-minimap world-minimap-expanded" ref={expandedCanvasRef} />
              <div className="world-status-chip-grid world-status-chip-grid-dense">
                <div className="world-status-chip">
                  <span>Self</span>
                  <strong>Red marker</strong>
                </div>
                <div className="world-status-chip">
                  <span>Exits</span>
                  <strong>Gold markers</strong>
                </div>
                <div className="world-status-chip">
                  <span>NPCs</span>
                  <strong>Ivory dots</strong>
                </div>
                <div className="world-status-chip">
                  <span>Others</span>
                  <strong>Blue dots</strong>
                </div>
              </div>
            </div>
          </div>
        </div>
      ) : null}
    </section>
  );
}
