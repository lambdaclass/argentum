import type { ClientState } from "../app/types";

interface HudPanelProps {
  state: ClientState;
}

function Bar({
  label,
  current,
  max
}: {
  label: string;
  current: number;
  max: number;
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
      <div className="hud-bar">
        <div className="hud-bar-fill" style={{ width: `${width}%` }} />
      </div>
    </div>
  );
}

export function HudPanel({ state }: HudPanelProps) {
  return (
    <section className="panel">
      <div className="panel-header">
        <h2>HUD</h2>
        <span className="panel-tag">Live</span>
      </div>

      <Bar label="HP" current={state.stats.hpCurrent} max={state.stats.hpMax} />
      <Bar label="Mana" current={state.stats.manaCurrent} max={state.stats.manaMax} />
      <Bar
        label="Stamina"
        current={state.stats.staminaCurrent}
        max={state.stats.staminaMax}
      />

      <div className="hud-meta-grid">
        <div className="meta-card">
          <span>Map</span>
          <strong>{state.world.map?.name ?? state.world.mapId ?? "--"}</strong>
        </div>
        <div className="meta-card">
          <span>Gold</span>
          <strong>{state.stats.gold}</strong>
        </div>
        <div className="meta-card">
          <span>Hunger</span>
          <strong>{state.stats.hunger}</strong>
        </div>
        <div className="meta-card">
          <span>Thirst</span>
          <strong>{state.stats.thirst}</strong>
        </div>
      </div>
    </section>
  );
}
