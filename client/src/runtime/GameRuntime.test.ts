import { describe, expect, it, vi } from "vitest";
import { createInitialState } from "../app/appReducer";
import { GameRuntime } from "./GameRuntime";

describe("GameRuntime movement prediction", () => {
  it("does not predict a step into an occupied character tile", () => {
    const state = createInitialState();
    state.connection.status = "connected";
    state.world.mapStatus = "ready";
    state.world.map = {
      mapId: 1,
      name: "Test",
      width: 5,
      height: 5,
      tiles: new Uint8Array(25),
      musicHi: 0,
      musicLow: 0,
      layers: [[], [], [], []],
      npcs: [],
      exits: []
    };
    state.world.self.x = 2;
    state.world.self.y = 2;
    state.world.self.heading = 1;
    state.world.self.speed = 1;
    state.world.others = {
      99: {
        charIndex: 99,
        name: "Blocker",
        x: 3,
        y: 2,
        dead: false,
        heading: 3,
        bodyId: 1,
        headId: 1,
        weaponId: 0,
        shieldId: 0,
        helmetId: 0,
        cartId: 0,
        backpackId: 0,
        effectId: 0,
        effectLoops: 0,
        speed: 1,
        isNpc: false
      }
    };

    const transport = {
      sendWalk: vi.fn(),
      sendHeading: vi.fn(),
      requestPositionUpdate: vi.fn()
    };
    const ui = {
      getState: () => state,
      setSelfPosition: (x: number, y: number) => {
        state.world.self.x = x;
        state.world.self.y = y;
      },
      setSelfHeading: (heading: number) => {
        state.world.self.heading = heading;
      }
    };

    const runtime = new GameRuntime(transport, ui);
    runtime.onMapLoaded(1);
    runtime.rememberMovementKey("east");
    runtime.tick(1_000);

    expect(transport.sendWalk).not.toHaveBeenCalled();
    expect(transport.sendHeading).toHaveBeenCalledWith("east");
    expect(state.world.self.x).toBe(2);
    expect(state.world.self.y).toBe(2);
    expect(state.world.self.heading).toBe(2);
  });
});
