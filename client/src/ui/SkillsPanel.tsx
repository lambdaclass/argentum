import type { ClientState, SkillEntry } from "../app/types";

interface SkillsPanelProps {
  state: ClientState;
  onSelectSkill: (key: string | null) => void;
}

type SkillGroup = "Combat" | "Magic" | "Craft" | "Utility" | "General";

const GROUP_ORDER: SkillGroup[] = ["Combat", "Magic", "Craft", "Utility", "General"];

const SKILL_METADATA: Record<
  string,
  { label: string; group: SkillGroup; description: string }
> = {
  combat: {
    label: "Combat",
    group: "Combat",
    description: "General combat effectiveness and weapon handling."
  },
  magic: {
    label: "Magic",
    group: "Magic",
    description: "General spell control and arcane discipline."
  },
  meditation: {
    label: "Meditation",
    group: "Magic",
    description: "Mana recovery and sustained magical focus."
  },
  leadership: {
    label: "Leadership",
    group: "Utility",
    description: "Party coordination and social command."
  },
  mining: {
    label: "Mining",
    group: "Craft",
    description: "Ore extraction and raw material gathering."
  },
  woodcutting: {
    label: "Woodcutting",
    group: "Craft",
    description: "Harvesting timber and natural resources."
  },
  fishing: {
    label: "Fishing",
    group: "Craft",
    description: "Gathering food and trade resources from water."
  },
  alchemy: {
    label: "Alchemy",
    group: "Craft",
    description: "Potion work, reagents, and recipe handling."
  },
  crafting: {
    label: "Crafting",
    group: "Craft",
    description: "General item creation and assembly."
  },
  survival: {
    label: "Survival",
    group: "Utility",
    description: "Field endurance and practical adventuring sense."
  }
};

function humanizeSkillKey(key: string) {
  return key
    .replace(/[_\-]+/g, " ")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function inferSkillGroup(key: string): SkillGroup {
  if (/(combat|attack|defen|weapon|sword|axe|bow|arch|shield)/.test(key)) {
    return "Combat";
  }

  if (/(magic|spell|mana|medit|cast|summon)/.test(key)) {
    return "Magic";
  }

  if (/(mine|mining|wood|fish|craft|smith|forge|alchemy|cook|tailor|build)/.test(key)) {
    return "Craft";
  }

  if (/(lead|stealth|surviv|trade|sail|heal|utility|social)/.test(key)) {
    return "Utility";
  }

  return "General";
}

function describeSkill(entry: SkillEntry) {
  const key = entry.key.toLowerCase();
  const metadata = SKILL_METADATA[key];

  if (metadata) {
    return metadata;
  }

  return {
    label: humanizeSkillKey(entry.key),
    group: inferSkillGroup(key),
    description: "Server-defined skill ready for UI display."
  };
}

function groupEntries(entries: SkillEntry[]) {
  const groups = new Map<SkillGroup, Array<SkillEntry & ReturnType<typeof describeSkill>>>();

  for (const entry of entries) {
    const metadata = describeSkill(entry);
    const bucket = groups.get(metadata.group) ?? [];
    bucket.push({ ...entry, ...metadata });
    groups.set(metadata.group, bucket);
  }

  return GROUP_ORDER.flatMap((group) => {
    const rows = groups.get(group);
    if (!rows || rows.length === 0) {
      return [];
    }

    return [
      {
        group,
        rows: rows.sort((left, right) => {
          if (right.level !== left.level) {
            return right.level - left.level;
          }

          return left.label.localeCompare(right.label);
        })
      }
    ];
  });
}

export function SkillsPanel({ state, onSelectSkill }: SkillsPanelProps) {
  const { entries, selectedKey, source } = state.skills;
  const grouped = groupEntries(entries);
  const selectedEntry =
    entries.find((entry) => entry.key === selectedKey) ?? entries[0] ?? null;
  const selectedSkill = selectedEntry == null ? null : describeSkill(selectedEntry);
  const highestSkill = entries[0] ?? null;
  const highestMeta = highestSkill == null ? null : describeSkill(highestSkill);
  const connected = state.connection.status === "connected";

  return (
    <section className="panel skills-panel">
      <div className="panel-header">
        <div>
          <p className="eyebrow">Character</p>
          <h2>Skills</h2>
        </div>
        <span className="panel-tag">
          {entries.length > 0
            ? `${entries.length} loaded`
            : connected
              ? "Waiting server"
              : "Offline"}
        </span>
      </div>

      <div className="skills-summary-grid">
        <div className="session-status-card">
          <span>Visible</span>
          <strong>{entries.length}</strong>
        </div>
        <div className="session-status-card">
          <span>Top Skill</span>
          <strong>{highestMeta ? `${highestMeta.label} ${highestSkill?.level}` : "--"}</strong>
        </div>
        <div className="session-status-card">
          <span>Status</span>
          <strong>{source === "server" ? "Live data" : connected ? "Awaiting sync" : "Not loaded"}</strong>
        </div>
      </div>

      {entries.length === 0 ? (
        <div className="selected-slot-card skills-empty-card">
          <p className="session-card-title">Skills snapshot</p>
          <h3 className="selected-slot-name">
            {connected ? "No skills received yet" : "Connect to load skills"}
          </h3>
          <p className="panel-copy compact">
            {connected
              ? "This client is ready to display normalized skills, but this session has not received a skills snapshot from the gateway yet."
              : "Account login, learned spells, XP, inventory, and reconnect are already wired. Skills will appear here as soon as the server starts sending them."}
          </p>
        </div>
      ) : (
        <>
          <div className="skills-list">
            {grouped.map(({ group, rows }) => (
              <div className="skills-group" key={group}>
                <div className="skills-group-header">
                  <p className="eyebrow">{group}</p>
                  <span className="panel-tag">{rows.length}</span>
                </div>
                <div className="skills-group-rows">
                  {rows.map((entry) => (
                    <button
                      className={`skills-row ${
                        selectedEntry?.key === entry.key ? "skills-row-selected" : ""
                      }`}
                      key={entry.key}
                      onClick={() => onSelectSkill(entry.key)}
                      type="button"
                    >
                      <div className="skills-row-copy">
                        <strong>{entry.label}</strong>
                        <span>{entry.key}</span>
                      </div>
                      <div className="skills-row-value">{entry.level}</div>
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </div>

          {selectedEntry && selectedSkill ? (
            <div className="selected-slot-card skills-detail-card">
              <p className="session-card-title">Selected skill</p>
              <h3 className="selected-slot-name">{selectedSkill.label}</h3>
              <p className="spellbook-description">{selectedSkill.description}</p>
              <div className="selected-slot-grid">
                <div className="selected-slot-item">
                  <span>Level</span>
                  <strong>{selectedEntry.level}</strong>
                </div>
                <div className="selected-slot-item">
                  <span>Group</span>
                  <strong>{selectedSkill.group}</strong>
                </div>
                <div className="selected-slot-item">
                  <span>Key</span>
                  <strong>{selectedEntry.key}</strong>
                </div>
                <div className="selected-slot-item">
                  <span>Rank</span>
                  <strong>
                    #{entries.findIndex((entry) => entry.key === selectedEntry.key) + 1}
                  </strong>
                </div>
              </div>
            </div>
          ) : null}
        </>
      )}
    </section>
  );
}
