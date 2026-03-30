interface HechizosPanelProps {
  compact?: boolean;
}

export function HechizosPanel({ compact = false }: HechizosPanelProps) {
  const placeholderSpells = [
    "(vacio)",
    "(vacio)",
    "(vacio)",
    "(vacio)",
    "(vacio)",
    "(vacio)",
    "(vacio)",
    "(vacio)"
  ];

  return (
    <section className={`panel spellbook-panel ${compact ? "spellbook-panel-compact" : ""}`}>
      <div className="panel-header">
        <h2>Hechizos</h2>
        <span className="panel-tag">Pending</span>
      </div>

      <div className={`spellbook-list ${compact ? "spellbook-list-compact" : ""}`}>
        {placeholderSpells.map((spell, index) => (
          <div className="spellbook-row" key={`${spell}-${index}`}>
            <span>{index + 1}.</span>
            <strong>{spell}</strong>
          </div>
        ))}
      </div>

      <div className="inventory-actions">
        <button className="ghost-button" disabled type="button">
          Lanzar
        </button>
        <button className="ghost-button" disabled type="button">
          Info
        </button>
      </div>

      {!compact ? (
        <p className="inventory-hint">
          The spellbook UI is in place, but real spell data has not been wired from the
          server yet.
        </p>
      ) : null}
    </section>
  );
}
