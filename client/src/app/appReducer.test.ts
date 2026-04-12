import { describe, expect, it } from "vitest";
import { appReducer, createInitialState } from "./appReducer";

describe("appReducer", () => {
  it("returns the same state when transient pruning has nothing to remove", () => {
    const state = createInitialState();
    const next = appReducer(state, { type: "world/pruneTransient", now: Date.now() });

    expect(next).toBe(state);
  });

  it("removes expired transient world entries and preserves live ones", () => {
    const now = 10_000;
    const state = appReducer(
      appReducer(
        appReducer(createInitialState(), {
          type: "world/addChatBubble",
          bubble: {
            id: 1,
            message: "alive",
            x: 4,
            y: 4,
            createdAt: now - 200,
            ttlMs: 1_000
          }
        }),
        {
          type: "world/addCombatText",
          event: {
            id: 2,
            x: 4,
            y: 4,
            text: "12",
            tone: "damage",
            createdAt: now - 2_000,
            ttlMs: 500
          }
        }
      ),
      {
        type: "world/addFx",
        event: {
          id: 3,
          x: 4,
          y: 4,
          fxId: 99,
          loops: 1,
          createdAt: now - 100,
          ttlMs: 1_000
        }
      }
    );

    const next = appReducer(state, { type: "world/pruneTransient", now });

    expect(next).not.toBe(state);
    expect(next.world.chatBubbles).toHaveLength(1);
    expect(next.world.chatBubbles[0]?.message).toBe("alive");
    expect(next.world.combatTexts).toHaveLength(0);
    expect(next.world.fxEvents).toHaveLength(1);
  });

  it("keeps weather and death state deterministic across updates", () => {
    const state = createInitialState();
    const afterRain = appReducer(state, { type: "weather/rain", raining: true });
    const afterSnow = appReducer(afterRain, { type: "weather/snow", snowing: true });
    const afterDeath = appReducer(afterSnow, { type: "world/setSelfDead", dead: true });

    expect(afterRain.weather.raining).toBe(true);
    expect(afterRain.weather.snowing).toBe(false);
    expect(afterSnow.weather).toEqual({ raining: true, snowing: true });
    expect(afterDeath.world.self.dead).toBe(true);
    expect(afterDeath.weather).toEqual({ raining: true, snowing: true });
  });
});
