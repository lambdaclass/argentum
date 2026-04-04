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
  cooldown?: number;
  areaAfecta?: number;
  areaRadio?: number;
  maxLevelCasteable?: number;
  needStaff?: boolean;
  requirementMask?: number;
  workOnDead?: boolean;
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

const SPELL_AREA_TARGET_LABELS: Record<number, string> = {
  1: "Usuarios",
  2: "NPCs",
  3: "Usuarios y NPCs"
};

const FACTION_STATUS_LABELS: Record<number, string> = {
  0: "Ciudadano",
  1: "Criminal",
  2: "Caos",
  3: "Armada"
};

const SPELL_REQUIREMENT = {
  weapon: 0x001,
  shield: 0x002,
  armor: 0x004,
  helm: 0x008,
  projectile: 0x020,
  ship: 0x040,
  onLand: 0x200,
  onWater: 0x400
} as const;

export function getSpellMetadata(spellId: number): SpellMetadata | null {
  return spellMetadataById.get(spellId) ?? null;
}

export function getSpellTargetLabel(target: number): string {
  return SPELL_TARGET_LABELS[target] ?? "Desconocido";
}

export function getSpellTypeLabel(type: number): string {
  return SPELL_TYPE_LABELS[type] ?? "Desconocido";
}

export function getSpellAreaTargetLabel(areaAfecta: number): string {
  return SPELL_AREA_TARGET_LABELS[areaAfecta] ?? "Objetivo flexible";
}

export function getFactionStatusLabel(status: number | null): string {
  if (status == null) {
    return "Sin faccion";
  }

  return FACTION_STATUS_LABELS[status] ?? `Estado ${status}`;
}

export function getSpellRequirementLabels(spell: SpellMetadata | null): string[] {
  if (!spell) {
    return [];
  }

  const mask = spell.requirementMask ?? 0;
  const labels: string[] = [];

  if (spell.needStaff) {
    labels.push("Baston");
  }
  if (mask & SPELL_REQUIREMENT.weapon) {
    labels.push("Arma");
  }
  if (mask & SPELL_REQUIREMENT.shield) {
    labels.push("Escudo");
  }
  if (mask & SPELL_REQUIREMENT.armor) {
    labels.push("Armadura");
  }
  if (mask & SPELL_REQUIREMENT.helm) {
    labels.push("Casco");
  }
  if (mask & SPELL_REQUIREMENT.projectile) {
    labels.push("Municion");
  }
  if (mask & SPELL_REQUIREMENT.ship) {
    labels.push("Barca");
  }
  if (mask & SPELL_REQUIREMENT.onLand) {
    labels.push("Objetivo en tierra");
  }
  if (mask & SPELL_REQUIREMENT.onWater) {
    labels.push("Objetivo en agua");
  }
  if (spell.workOnDead) {
    labels.push("Funciona en muertos");
  }

  return labels;
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
