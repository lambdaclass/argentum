import type { ClientState } from "../app/types";

interface PacketLogPanelProps {
  state: ClientState;
  onClear: () => void;
}

export function PacketLogPanel({ state, onClear }: PacketLogPanelProps) {
  return (
    <section className="panel">
      <div className="panel-header">
        <div>
          <p className="eyebrow">Activity</p>
          <h2>Log</h2>
        </div>
        <button className="ghost-button" onClick={onClear} type="button">
          Clear
        </button>
      </div>

      <div className="packet-log">
        {state.log.map((entry) => (
          <div className={`packet-entry packet-entry-${entry.level}`} key={entry.id}>
            <span>{entry.level.toUpperCase()}</span>
            <p>{entry.message}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
