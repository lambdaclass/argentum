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

  it("clamps persisted audio settings through reducer updates", () => {
    const state = createInitialState();
    const next = appReducer(
      appReducer(state, { type: "settings/setMusicVolume", volume: 2 }),
      { type: "settings/setSoundVolume", volume: -1 }
    );

    expect(next.settings.audio.musicVolume).toBe(1);
    expect(next.settings.audio.soundVolume).toBe(0);
  });

  it("deduplicates utility key bindings when the same key is reassigned", () => {
    const state = createInitialState();
    const next = appReducer(state, {
      type: "settings/setKeyBinding",
      action: "pickUp",
      key: "f"
    });

    expect(next.settings.controls.bindings.pickUp).toBe("f");
    expect(next.settings.controls.bindings.attack).toBeNull();
  });

  it("keeps settings intact when runtime state resets", () => {
    const state = appReducer(createInitialState(), {
      type: "settings/setMusicEnabled",
      enabled: false
    });
    const next = appReducer(state, { type: "session/resetRuntime" });

    expect(next.settings.audio.musicEnabled).toBe(false);
    expect(next.connection.status).toBe("offline");
    expect(next.world.map).toBeNull();
  });

  it("stores authoritative party snapshots", () => {
    const state = appReducer(createInitialState(), {
      type: "party/setSnapshot",
      members: ["Ari", "Niora"],
      leaderName: "Ari"
    });

    expect(state.party.members).toEqual(["Ari", "Niora"]);
    expect(state.party.leaderName).toBe("Ari");
    expect(state.party.invited).toBe(false);
  });

  it("stores guild details and news together", () => {
    const withDetails = appReducer(createInitialState(), {
      type: "clan/setDetails",
      name: "Luz del Alba",
      founderName: "Ari",
      createdAt: "2026-04-13",
      leaderName: "Ari",
      memberCount: 3,
      alignment: "Ciudadano",
      description: "Cronistas de la aurora",
      level: 2
    });
    const next = appReducer(withDetails, {
      type: "clan/setNews",
      news: "Guardia lista.",
      guildList: ["Luz del Alba"],
      memberList: ["Ari", "Niora", "Korin"],
      level: 2,
      currentExp: 14,
      neededExp: 25
    });

    expect(next.clan.name).toBe("Luz del Alba");
    expect(next.clan.memberCount).toBe(3);
    expect(next.clan.news).toBe("Guardia lista.");
    expect(next.clan.members).toEqual(["Ari", "Niora", "Korin"]);
  });

  it("does not mark NPCs dead just because character_create reports zero HP", () => {
    const state = appReducer(createInitialState(), {
      type: "world/upsertCharacter",
      self: false,
      character: {
        charIndex: 77,
        bodyId: 117,
        headId: 3,
        weaponId: 0,
        shieldId: 0,
        helmetId: 0,
        cartId: 0,
        backpackId: 0,
        effectId: 0,
        effectLoops: 0,
        heading: 3,
        x: 50,
        y: 50,
        name: "Guardia Imperial",
        speed: 1,
        minHp: 0,
        maxHp: 0,
        minMana: 0,
        maxMana: 0,
        isNpc: true,
        clanIndex: 0,
        clanLevel: 0
      }
    });

    expect(state.world.others[77]?.dead).toBe(false);
  });
});
