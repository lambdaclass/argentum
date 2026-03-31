import type { ClientState } from "../app/types";

interface HudPanelProps {
  compact?: boolean;
  showHeader?: boolean;
  state: ClientState;
}

function Bar({
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

export function HudPanel({ compact = false, showHeader = true, state }: HudPanelProps) {
  const labels = compact
    ? {
        gold: "Oro",
        speed: "Vel",
        others: "Otros",
        position: "Pos"
      }
    : {
        gold: "Gold",
        speed: "Velocidad",
        others: "Others",
        position: "Posicion"
      };

  return (
    <section className={`panel hud-panel ${compact ? "hud-panel-compact" : ""}`}>
      {showHeader ? (
        <div className="panel-header">
          <div>
            <p className="eyebrow">Vitales</p>
            <h2>HUD</h2>
          </div>
          <span className="panel-tag">Live</span>
        </div>
      ) : null}

      <Bar
        label="Energia"
        current={state.stats.staminaCurrent}
        max={state.stats.staminaMax}
        tone="energy"
      />
      <Bar
        label="Mana"
        current={state.stats.manaCurrent}
        max={state.stats.manaMax}
        tone="mana"
      />
      <Bar
        label="Salud"
        current={state.stats.hpCurrent}
        max={state.stats.hpMax}
        tone="health"
      />
      <Bar label="Hambre" current={state.stats.hunger} max={100} tone="hunger" />
      <Bar label="Sed" current={state.stats.thirst} max={100} tone="thirst" />

      <div
        className={`hud-meta-grid ${
          compact ? "hud-meta-grid-classic" : "hud-meta-grid-compact"
        }`}
      >
        <div className="meta-card">
          <span>{labels.gold}</span>
          <strong>{state.stats.gold}</strong>
        </div>
        <div className="meta-card">
          <span>{labels.speed}</span>
          <strong>{state.world.self.speed}</strong>
        </div>
        <div className="meta-card">
          <span>{labels.others}</span>
          <strong>{Object.keys(state.world.others).length}</strong>
        </div>
        <div className="meta-card">
          <span>{labels.position}</span>
          <strong>
            {state.world.self.x ?? "--"},{state.world.self.y ?? "--"}
          </strong>
        </div>
      </div>
    </section>
  );
}
