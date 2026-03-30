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
        <div>
          <p className="eyebrow">Vitals</p>
          <h2>HUD</h2>
        </div>
        <span className="panel-tag">Live</span>
      </div>

      <Bar label="HP" current={state.stats.hpCurrent} max={state.stats.hpMax} />
      <Bar label="Mana" current={state.stats.manaCurrent} max={state.stats.manaMax} />
      <Bar
        label="Stamina"
        current={state.stats.staminaCurrent}
        max={state.stats.staminaMax}
      />

      <div className="hud-meta-grid hud-meta-grid-compact">
        <div className="meta-card">
          <span>Heading</span>
          <strong>{state.world.self.heading}</strong>
        </div>
        <div className="meta-card">
          <span>Speed</span>
          <strong>{state.world.self.speed}</strong>
        </div>
        <div className="meta-card">
          <span>Char Idx</span>
          <strong>{state.world.self.charIndex ?? "--"}</strong>
        </div>
        <div className="meta-card">
          <span>Others</span>
          <strong>{Object.keys(state.world.others).length}</strong>
        </div>
      </div>
    </section>
  );
}
