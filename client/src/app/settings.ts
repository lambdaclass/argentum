import type { ClientState, KeyBindingAction } from "./types";

const SETTINGS_STORAGE_KEY = "ao_client_settings_v1";

export const DEFAULT_KEY_BINDINGS: ClientState["settings"]["controls"]["bindings"] = {
  openHud: "i",
  pickUp: "p",
  attack: "f",
  safeToggle: "g",
  commerce: "e",
  bank: "b",
  resyncPosition: "l",
  tileDebug: "F1",
  moveDebug: "F2"
};

export const KEY_BINDING_FIELDS: Array<{
  action: KeyBindingAction;
  label: string;
  description: string;
}> = [
  { action: "openHud", label: "HUD", description: "Open the HUD/inventory tab." },
  { action: "pickUp", label: "Pick Up", description: "Grab the ground object on your tile." },
  { action: "attack", label: "Attack", description: "Trigger the basic attack action." },
  { action: "safeToggle", label: "Safe Mode", description: "Toggle attack safe mode." },
  { action: "commerce", label: "Commerce", description: "Open the merchant window with an NPC." },
  { action: "bank", label: "Bank", description: "Open the bank window with a banker." },
  {
    action: "resyncPosition",
    label: "Resync Position",
    description: "Ask the server for your authoritative position and recenter there."
  },
  { action: "tileDebug", label: "Tile Debug", description: "Toggle tile debug overlay." },
  { action: "moveDebug", label: "Move Debug", description: "Toggle movement debug panel." }
];

export function clampVolume(value: number, fallback = 1) {
  if (!Number.isFinite(value)) {
    return fallback;
  }

  return Math.max(0, Math.min(1, value));
}

export function createDefaultSettings(): ClientState["settings"] {
  return {
    audio: {
      musicEnabled: true,
      musicVolume: 0.6,
      soundEnabled: true,
      soundVolume: 0.85
    },
    controls: {
      bindings: { ...DEFAULT_KEY_BINDINGS }
    }
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value != null;
}

export function normalizeBindingKey(key: string): string | null {
  if (key === " ") {
    return "Space";
  }

  if (!key.trim()) {
    return null;
  }

  return key.length === 1 ? key.toLowerCase() : key;
}

export function formatBindingKey(key: string | null) {
  if (!key) {
    return "Unbound";
  }

  return key.length === 1 ? key.toUpperCase() : key;
}

export function bindingMatches(eventKey: string, binding: string | null) {
  if (!binding) {
    return false;
  }

  return normalizeBindingKey(eventKey) === binding;
}

export function applyKeyBinding(
  bindings: ClientState["settings"]["controls"]["bindings"],
  action: KeyBindingAction,
  key: string | null
) {
  const normalized = key == null ? null : normalizeBindingKey(key);
  const next = { ...bindings };

  for (const currentAction of Object.keys(next) as KeyBindingAction[]) {
    if (currentAction !== action && normalized != null && next[currentAction] === normalized) {
      next[currentAction] = null;
    }
  }

  next[action] = normalized;
  return next;
}

export function loadStoredSettings(): ClientState["settings"] {
  const defaults = createDefaultSettings();

  if (typeof window === "undefined") {
    return defaults;
  }

  try {
    const raw = window.localStorage.getItem(SETTINGS_STORAGE_KEY);
    if (!raw) {
      return defaults;
    }

    const parsed = JSON.parse(raw);
    if (!isRecord(parsed)) {
      return defaults;
    }

    const audio = isRecord(parsed.audio) ? parsed.audio : {};
    const controlBindings = isRecord(parsed.controls) && isRecord(parsed.controls.bindings)
      ? parsed.controls.bindings
      : {};

    const bindings = { ...DEFAULT_KEY_BINDINGS };

    for (const action of Object.keys(bindings) as KeyBindingAction[]) {
      const rawBinding = controlBindings[action];
      bindings[action] = typeof rawBinding === "string" ? normalizeBindingKey(rawBinding) : bindings[action];
    }

    return {
      audio: {
        musicEnabled:
          typeof audio.musicEnabled === "boolean" ? audio.musicEnabled : defaults.audio.musicEnabled,
        musicVolume: clampVolume(
          typeof audio.musicVolume === "number" ? audio.musicVolume : defaults.audio.musicVolume,
          defaults.audio.musicVolume
        ),
        soundEnabled:
          typeof audio.soundEnabled === "boolean" ? audio.soundEnabled : defaults.audio.soundEnabled,
        soundVolume: clampVolume(
          typeof audio.soundVolume === "number" ? audio.soundVolume : defaults.audio.soundVolume,
          defaults.audio.soundVolume
        )
      },
      controls: {
        bindings
      }
    };
  } catch {
    return defaults;
  }
}

export function persistSettings(settings: ClientState["settings"]) {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(settings));
}
