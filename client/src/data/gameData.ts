import expTableRows from "./exp-table.generated.json";
import spellRows from "./spells.generated.json";

export interface SpellMetadata {
  id: number;
  name: string;
  description: string;
  magicWords: string;
  manaRequired: number;
  staminaRequired: number;
  minSkill: number;
  target: number;
  type: number;
  iconIndex: number;
}

interface ExpTableRow {
  level: number;
  xp: number;
}

export interface LevelProgress {
  levelFloorXp: number;
  levelCeilXp: number;
  xpIntoLevel: number;
  xpRequiredThisLevel: number;
  xpRemaining: number;
  progressPercent: number;
}

const spellMetadataById = new Map<number, SpellMetadata>(
  (spellRows as SpellMetadata[]).map((spell) => [spell.id, spell])
);

const expThresholdsByLevel = new Map<number, number>(
  (expTableRows as ExpTableRow[]).map((row) => [row.level, row.xp])
);

const SPELL_TARGET_LABELS: Record<number, string> = {
  1: "Usuario",
  2: "NPC",
  3: "Usuario / NPC",
  4: "Terreno"
};

const SPELL_TYPE_LABELS: Record<number, string> = {
  1: "Vida / mana / stamina",
  2: "Estados",
  3: "Materializacion",
  4: "Invocacion",
  5: "Area",
  6: "Portales",
  8: "Combinado",
  9: "MultiShot",
  10: "Creacion de equipo",
  11: "Encantamiento",
  12: "Deteccion"
};

export function getSpellMetadata(spellId: number): SpellMetadata | null {
  return spellMetadataById.get(spellId) ?? null;
}

export function getSpellTargetLabel(target: number): string {
  return SPELL_TARGET_LABELS[target] ?? "Desconocido";
}

export function getSpellTypeLabel(type: number): string {
  return SPELL_TYPE_LABELS[type] ?? "Desconocido";
}

export function getLevelProgress(
  level: number,
  currentXp: number,
  serverNextXp: number
): LevelProgress {
  const safeLevel = Math.max(1, Math.trunc(level));
  const safeCurrentXp = Math.max(0, Math.trunc(currentXp));
  const serverCeilXp = Math.max(0, Math.trunc(serverNextXp));
  const levelFloorXp =
    safeLevel > 1 ? Math.max(0, expThresholdsByLevel.get(safeLevel - 1) ?? 0) : 0;
  const localCeilXp = Math.max(0, expThresholdsByLevel.get(safeLevel) ?? 0);
  const fallbackCeilXp = serverCeilXp > safeCurrentXp ? serverCeilXp : safeCurrentXp + 1;
  const levelCeilXp = Math.max(localCeilXp, fallbackCeilXp, levelFloorXp + 1);
  const xpIntoLevel = Math.max(0, safeCurrentXp - levelFloorXp);
  const xpRequiredThisLevel = Math.max(1, levelCeilXp - levelFloorXp);
  const xpRemaining = Math.max(0, levelCeilXp - safeCurrentXp);
  const progressPercent = Math.max(
    0,
    Math.min(100, Math.round((xpIntoLevel / xpRequiredThisLevel) * 100))
  );

  return {
    levelFloorXp,
    levelCeilXp,
    xpIntoLevel,
    xpRequiredThisLevel,
    xpRemaining,
    progressPercent
  };
}
