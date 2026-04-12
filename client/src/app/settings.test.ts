import { describe, expect, it } from "vitest";
import {
  DEFAULT_KEY_BINDINGS,
  applyKeyBinding,
  createDefaultSettings,
  formatBindingKey,
  normalizeBindingKey
} from "./settings";

describe("settings helpers", () => {
  it("normalizes browser key strings consistently", () => {
    expect(normalizeBindingKey("F")).toBe("f");
    expect(normalizeBindingKey("F2")).toBe("F2");
    expect(normalizeBindingKey(" ")).toBe("Space");
  });

  it("formats bindings for compact UI display", () => {
    expect(formatBindingKey("f")).toBe("F");
    expect(formatBindingKey("F2")).toBe("F2");
    expect(formatBindingKey(null)).toBe("Unbound");
  });

  it("removes duplicate utility bindings when one action is reassigned", () => {
    const settings = createDefaultSettings();
    const next = applyKeyBinding(settings.controls.bindings, "pickUp", DEFAULT_KEY_BINDINGS.attack);

    expect(next.pickUp).toBe("f");
    expect(next.attack).toBeNull();
  });
});
