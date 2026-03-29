import { useEffect, useRef } from "react";
import type { ClientState } from "../app/types";

interface WorldStatusPanelProps {
  state: ClientState;
}

function clampPercent(current: number, max: number) {
  if (max <= 0) {
    return 0;
  }

  return Math.max(0, Math.min(100, Math.round((current / max) * 100)));
}

function drawMinimap(canvas: HTMLCanvasElement, state: ClientState) {
  const size = 110;
  canvas.width = size;
  canvas.height = size;

  const context = canvas.getContext("2d");
  if (!context) {
    return;
  }

  context.fillStyle = "#09111a";
  context.fillRect(0, 0, size, size);

  const map = state.world.map;
  if (!map) {
    context.strokeStyle = "rgba(255, 220, 146, 0.22)";
    context.strokeRect(0.5, 0.5, size - 1, size - 1);
    return;
  }

  const scaleX = size / map.width;
  const scaleY = size / map.height;

  for (let y = 1; y <= map.height; y += 1) {
    for (let x = 1; x <= map.width; x += 1) {
      const tile = map.tiles[(y - 1) * map.width + (x - 1)] ?? 0;
      context.fillStyle = tile === 0 ? "#26422f" : "#13222a";
      context.fillRect((x - 1) * scaleX, (y - 1) * scaleY, Math.ceil(scaleX), Math.ceil(scaleY));
    }
  }

  context.fillStyle = "#d2a04e";
  for (const exit of map.exits) {
    context.fillRect((exit.x - 1) * scaleX, (exit.y - 1) * scaleY, Math.max(2, scaleX), Math.max(2, scaleY));
  }

  if (state.world.self.x != null && state.world.self.y != null) {
    context.fillStyle = "#ff6a54";
    context.beginPath();
    context.arc((state.world.self.x - 0.5) * scaleX, (state.world.self.y - 0.5) * scaleY, 3, 0, Math.PI * 2);
    context.fill();
  }

  context.strokeStyle = "rgba(255, 220, 146, 0.28)";
  context.strokeRect(0.5, 0.5, size - 1, size - 1);
}

function StatBar({
  label,
  current,
  max,
  tone
}: {
  label: string;
  current: number;
  max: number;
  tone: "health" | "mana";
}) {
  const width = clampPercent(current, max);

  return (
    <div className="status-bar">
      <div className="status-bar-label-row">
        <span>{label}</span>
        <strong>
          {current}/{max}
        </strong>
      </div>
      <div className={`status-bar-track status-bar-track-${tone}`}>
        <div className={`status-bar-fill status-bar-fill-${tone}`} style={{ width: `${width}%` }} />
      </div>
    </div>
  );
}

export function WorldStatusPanel({ state }: WorldStatusPanelProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    if (canvasRef.current) {
      drawMinimap(canvasRef.current, state);
    }
  }, [state]);

  return (
    <section className="panel world-status-card">
      <div className="panel-header">
        <div>
          <p className="eyebrow">World</p>
          <h2>{state.world.map?.name ?? `Map ${state.world.mapId ?? "--"}`}</h2>
        </div>
        <span className="panel-tag">
          {state.world.self.x ?? "--"},{state.world.self.y ?? "--"}
        </span>
      </div>

      <div className="world-status-grid">
        <div className="world-bars">
          <StatBar label="Health" current={state.stats.hpCurrent} max={state.stats.hpMax} tone="health" />
          <StatBar label="Mana" current={state.stats.manaCurrent} max={state.stats.manaMax} tone="mana" />
        </div>

        <div className="world-minimap-shell">
          <canvas className="world-minimap" ref={canvasRef} />
          <p className="world-minimap-caption">Map {state.world.mapId ?? "--"}</p>
        </div>
      </div>

      <div className="world-status-chip-grid">
        <div className="world-status-chip">
          <span>Gold</span>
          <strong>{state.stats.gold}</strong>
        </div>
        <div className="world-status-chip">
          <span>Stamina</span>
          <strong>
            {state.stats.staminaCurrent}/{state.stats.staminaMax}
          </strong>
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
    </section>
  );
}
