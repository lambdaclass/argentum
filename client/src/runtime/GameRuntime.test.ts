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

  it("does not predict a water step while not navigating", () => {
    const state = createInitialState();
    state.connection.status = "connected";
    state.world.mapStatus = "ready";
    state.world.map = {
      mapId: 78,
      name: "Costas de nix",
      width: 5,
      height: 5,
      tiles: new Uint8Array(25),
      musicHi: 0,
      musicLow: 0,
      layers: [[], [], [], []],
      npcs: [],
      exits: []
    };
    state.world.map.tiles[(2 - 1) * state.world.map.width + (3 - 1)] = 2;
    state.world.self.x = 2;
    state.world.self.y = 2;
    state.world.self.heading = 1;
    state.world.self.speed = 1;
    state.world.self.navigating = false;

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
    runtime.onMapLoaded(78);
    runtime.rememberMovementKey("east");
    runtime.tick(1_000);

    expect(transport.sendWalk).not.toHaveBeenCalled();
    expect(transport.sendHeading).toHaveBeenCalledWith("east");
    expect(state.world.self.x).toBe(2);
    expect(state.world.self.y).toBe(2);
  });

  it("predicts a water step while navigating", () => {
    const state = createInitialState();
    state.connection.status = "connected";
    state.world.mapStatus = "ready";
    state.world.map = {
      mapId: 78,
      name: "Costas de nix",
      width: 5,
      height: 5,
      tiles: new Uint8Array(25),
      musicHi: 0,
      musicLow: 0,
      layers: [[], [], [], []],
      npcs: [],
      exits: []
    };
    state.world.map.tiles[(2 - 1) * state.world.map.width + (3 - 1)] = 2;
    state.world.self.x = 2;
    state.world.self.y = 2;
    state.world.self.heading = 1;
    state.world.self.speed = 1;
    state.world.self.navigating = true;

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
    runtime.onMapLoaded(78);
    runtime.rememberMovementKey("east");
    runtime.tick(1_000);

    expect(transport.sendWalk).toHaveBeenCalledWith("east");
    expect(state.world.self.x).toBe(3);
    expect(state.world.self.y).toBe(2);
    expect(state.world.self.heading).toBe(2);
  });

  it("keeps consecutive predicted steps moving even when UI position sync is throttled", () => {
    const state = createInitialState();
    state.connection.status = "connected";
    state.world.mapStatus = "ready";
    state.world.map = {
      mapId: 1,
      name: "Test",
      width: 8,
      height: 5,
      tiles: new Uint8Array(40),
      musicHi: 0,
      musicLow: 0,
      layers: [[], [], [], []],
      npcs: [],
      exits: []
    };
    state.world.self.x = 2;
    state.world.self.y = 2;
    state.world.self.heading = 2;
    state.world.self.speed = 1;
    state.world.walkIntervalMs = 210;

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
    runtime.tick(1_210);

    expect(transport.sendWalk).toHaveBeenCalledTimes(2);
    expect(state.world.self.x).toBe(3);
    expect(state.world.self.y).toBe(2);
    expect(runtime.getDebugSnapshot().predictedX).toBe(4);
    expect(runtime.getDebugSnapshot().predictedY).toBe(2);
  });
});

describe("GameRuntime tick keeps the render loop alive", () => {
  // The render loop stops itself when no sprite is animating, and the visual
  // step is shorter than the walk interval, so there is a dead gap between
  // steps. tick() must report that it still wants ticking while a key is held;
  // otherwise the loop halts in that gap and the next step waits for an OS key
  // auto-repeat (~500ms on a default Linux desktop) instead of the walk
  // interval. See WorldRenderer.tick / VISUAL_WALK_DURATION_SCALE.
  function setup() {
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
    return { runtime, transport };
  }

  it("reports no tick needed when no movement key is held", () => {
    const { runtime } = setup();

    expect(runtime.tick(1_000)).toBe(false);
  });

  it("reports tick still needed while a movement key is held", () => {
    const { runtime } = setup();
    runtime.rememberMovementKey("east");

    expect(runtime.tick(1_000)).toBe(true);
  });

  it("keeps reporting tick needed in the gap between steps", () => {
    const { runtime, transport } = setup();
    runtime.rememberMovementKey("east");

    expect(runtime.tick(1_000)).toBe(true);
    expect(transport.sendWalk).toHaveBeenCalledTimes(1);

    // Immediately after a step the walk is interval-gated, so no packet goes
    // out — but the loop must stay alive or nothing will drive the next step.
    expect(runtime.tick(1_010)).toBe(true);
    expect(transport.sendWalk).toHaveBeenCalledTimes(1);
  });

  it("stops requesting ticks once the key is released", () => {
    const { runtime } = setup();
    runtime.rememberMovementKey("east");
    runtime.tick(1_000);
    runtime.releaseMovementKey("east");

    expect(runtime.tick(2_000)).toBe(false);
  });
});
