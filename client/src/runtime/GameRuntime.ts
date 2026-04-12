import type {
  CharacterCreatePacket,
  ClientState,
  Direction
} from "../app/types";
import type { WorldRenderer } from "../render/WorldRenderer";

export interface MovementDebugSnapshot {
  predictedX: number | null;
  predictedY: number | null;
  authorityX: number | null;
  authorityY: number | null;
  pendingSteps: number;
  requestCount: number;
  lastRequestAt: number | null;
  correctionCount: number;
  lastCorrectionAt: number | null;
}

interface RuntimeTransport {
  sendWalk(direction: Direction): void;
  sendHeading(direction: Direction): void;
  requestPositionUpdate(): void;
}

interface RuntimeUiBridge {
  getState: () => ClientState;
  setSelfPosition(x: number, y: number): void;
  setSelfHeading(heading: number): void;
}

const runtimeTimers = {
  setTimeout: globalThis.setTimeout.bind(globalThis),
  clearTimeout: globalThis.clearTimeout.bind(globalThis)
};

export class GameRuntime {
  private readonly transport: RuntimeTransport;
  private readonly ui: RuntimeUiBridge;
  private renderer: WorldRenderer | null = null;
  private movementKeys: Direction[] = [];
  private lastWalkAt = Number.NEGATIVE_INFINITY;
  private pendingWalkSteps: Array<{ x: number; y: number; timeoutId: number }> = [];
  private authorityX: number | null = null;
  private authorityY: number | null = null;
  private requestCount = 0;
  private lastRequestAt: number | null = null;
  private correctionCount = 0;
  private lastCorrectionAt: number | null = null;
  private predictionEnabled = false;
  private transferTargetMapId: number | null = null;
  private transferBootstrapReceived = false;
  private transferMapDataReady = false;

  constructor(transport: RuntimeTransport, ui: RuntimeUiBridge) {
    this.transport = transport;
    this.ui = ui;
  }

  setRenderer(renderer: WorldRenderer | null) {
    this.renderer = renderer;
  }

  resetConnection() {
    this.clearMovementKeys();
    this.clearPendingWalkSteps();
    this.lastWalkAt = Number.NEGATIVE_INFINITY;
    this.authorityX = null;
    this.authorityY = null;
    this.requestCount = 0;
    this.lastRequestAt = null;
    this.correctionCount = 0;
    this.lastCorrectionAt = null;
    this.predictionEnabled = false;
    this.transferTargetMapId = null;
    this.transferBootstrapReceived = false;
    this.transferMapDataReady = false;
  }

  rememberMovementKey(direction: Direction) {
    this.movementKeys = this.movementKeys.filter((key) => key !== direction);
    this.movementKeys.push(direction);
  }

  releaseMovementKey(direction: Direction) {
    this.movementKeys = this.movementKeys.filter((key) => key !== direction);
  }

  clearMovementKeys() {
    this.movementKeys = [];
  }

  tick(now: number) {
    const direction = this.activeMovementDirection();
    if (!direction) {
      return;
    }

    this.tryPredictedWalk(direction, now);
  }

  requestPositionUpdate() {
    this.requestCount += 1;
    this.lastRequestAt = Date.now();
    this.transport.requestPositionUpdate();
  }

  onMapChange(mapId: number, hadActiveMap: boolean) {
    this.clearPendingWalkSteps();
    this.authorityX = null;
    this.authorityY = null;
    this.predictionEnabled = false;
    this.transferTargetMapId = hadActiveMap ? mapId : null;
    this.transferBootstrapReceived = false;
    this.transferMapDataReady = false;
    if (hadActiveMap) {
      this.renderer?.beginMapTransfer();
    } else {
      this.renderer?.finishMapTransfer();
    }
  }

  onMapLoaded(mapId: number) {
    if (this.transferTargetMapId == null) {
      this.predictionEnabled = true;
      this.renderer?.finishMapTransfer();
      return;
    }

    this.transferMapDataReady = true;
    this.tryFinishTransferBootstrap(mapId);
  }

  onMapLoadError() {
    this.predictionEnabled = false;
    this.transferMapDataReady = false;
    this.renderer?.finishMapTransfer();
  }

  onServerPosition(x: number, y: number) {
    if (
      this.authorityX !== x ||
      this.authorityY !== y ||
      this.ui.getState().world.self.x !== x ||
      this.ui.getState().world.self.y !== y
    ) {
      this.lastCorrectionAt = Date.now();
      this.correctionCount += 1;
    }

    this.authorityX = x;
    this.authorityY = y;

    if (!this.consumePendingStep(x, y)) {
      this.renderer?.snapSelfPosition(x, y);
      this.ui.setSelfPosition(x, y);
    }

    this.noteTransferBootstrap();
  }

  onSelfCharacter(character: CharacterCreatePacket) {
    // Match the old client bootstrap/handoff behavior: once the server
    // re-creates our own character, any locally pending walk confirmations
    // are stale and should not keep influencing movement/reconciliation.
    this.clearPendingWalkSteps();
    this.authorityX = character.x;
    this.authorityY = character.y;
    this.renderer?.snapSelfPosition(character.x, character.y);
    this.renderer?.setSelfHeading(character.heading);
    this.noteTransferBootstrap();
  }

  onSelfHeading(heading: number) {
    this.renderer?.setSelfHeading(heading);
    this.ui.setSelfHeading(heading);
  }

  getDebugSnapshot(): MovementDebugSnapshot {
    const self = this.ui.getState().world.self;

    return {
      predictedX: self.x,
      predictedY: self.y,
      authorityX: this.authorityX,
      authorityY: this.authorityY,
      pendingSteps: this.pendingWalkSteps.length,
      requestCount: this.requestCount,
      lastRequestAt: this.lastRequestAt,
      correctionCount: this.correctionCount,
      lastCorrectionAt: this.lastCorrectionAt
    };
  }

  private activeMovementDirection() {
    return this.movementKeys.length > 0 ? this.movementKeys[this.movementKeys.length - 1] : null;
  }

  private currentWalkIntervalMs() {
    const state = this.ui.getState();
    const speed = state.world.self.speed > 0 ? state.world.self.speed : 1;
    return Math.max(40, state.world.walkIntervalMs / speed);
  }

  private tileIndex(x: number, y: number, width: number) {
    return (y - 1) * width + (x - 1);
  }

  private tileValueAt(x: number, y: number) {
    const map = this.ui.getState().world.map;
    if (!map) {
      return 0;
    }

    if (x < 1 || x > map.width || y < 1 || y > map.height) {
      return 1;
    }

    return map.tiles[this.tileIndex(x, y, map.width)] ?? 0;
  }

  private isTileBlocked(x: number, y: number) {
    const tileValue = this.tileValueAt(x, y);

    if (tileValue === 0 || tileValue === 4) {
      return false;
    }

    if (tileValue === 2) {
      return !this.ui.getState().world.self.navigating;
    }

    return true;
  }

  private isTileOccupied(x: number, y: number) {
    const world = this.ui.getState().world;

    for (const other of Object.values(world.others)) {
      if (!other.dead && other.x === x && other.y === y) {
        return true;
      }
    }

    const hasLiveNpc = Object.values(world.others).some((other) => other.isNpc && !other.dead);
    if (!hasLiveNpc && world.map) {
      return world.map.npcs.some((npc) => npc.x === x && npc.y === y);
    }

    return false;
  }

  private predictedDestination(direction: Direction) {
    const self = this.ui.getState().world.self;
    if (self.x == null || self.y == null) {
      return null;
    }

    switch (direction) {
      case "north":
        return { x: self.x, y: self.y - 1, heading: 1 };
      case "east":
        return { x: self.x + 1, y: self.y, heading: 2 };
      case "south":
        return { x: self.x, y: self.y + 1, heading: 3 };
      case "west":
        return { x: self.x - 1, y: self.y, heading: 4 };
    }
  }

  private pushPendingWalkStep(x: number, y: number) {
    const timeoutMs = Math.max(300, Math.round(this.currentWalkIntervalMs() * 2));
    const step = {
      x,
      y,
      timeoutId: runtimeTimers.setTimeout(() => {
        if (
          this.pendingWalkSteps.length > 0 &&
          this.pendingWalkSteps[this.pendingWalkSteps.length - 1] === step
        ) {
          this.requestPositionUpdate();
        }
      }, timeoutMs)
    };

    this.pendingWalkSteps.push(step);
  }

  private clearPendingWalkSteps() {
    for (const step of this.pendingWalkSteps) {
      runtimeTimers.clearTimeout(step.timeoutId);
    }
    this.pendingWalkSteps = [];
  }

  private consumePendingStep(x: number, y: number) {
    for (let index = 0; index < this.pendingWalkSteps.length; index += 1) {
      const step = this.pendingWalkSteps[index];
      if (step.x === x && step.y === y) {
        for (let consumed = 0; consumed <= index; consumed += 1) {
          runtimeTimers.clearTimeout(this.pendingWalkSteps[consumed].timeoutId);
        }
        this.pendingWalkSteps = this.pendingWalkSteps.slice(index + 1);
        return true;
      }
    }

    return false;
  }

  private tryPredictedWalk(direction: Direction, now: number) {
    const state = this.ui.getState();

    if (state.connection.status !== "connected") {
      return false;
    }

    const world = state.world;
    if (!this.predictionEnabled || world.mapStatus !== "ready" || !world.map) {
      return false;
    }

    if (now - this.lastWalkAt < this.currentWalkIntervalMs()) {
      return false;
    }

    const destination = this.predictedDestination(direction);
    if (!destination) {
      return false;
    }

    if (this.isTileBlocked(destination.x, destination.y) || this.isTileOccupied(destination.x, destination.y)) {
      if (state.world.self.heading !== destination.heading) {
        this.transport.sendHeading(direction);
        this.renderer?.setSelfHeading(destination.heading);
        this.ui.setSelfHeading(destination.heading);
      }
      return false;
    }

    this.transport.sendWalk(direction);
    this.lastWalkAt = now;

    if (state.world.self.heading !== destination.heading) {
      this.renderer?.setSelfHeading(destination.heading);
      this.ui.setSelfHeading(destination.heading);
    }

    const walkInterval = this.currentWalkIntervalMs();
    const speed = state.world.self.speed;
    this.renderer?.pushSelfMovement(destination.x, destination.y, walkInterval, speed);
    this.ui.setSelfPosition(destination.x, destination.y);
    this.pushPendingWalkStep(destination.x, destination.y);
    return true;
  }

  private noteTransferBootstrap() {
    if (this.transferTargetMapId == null) {
      return;
    }

    this.transferBootstrapReceived = true;
    this.tryFinishTransferBootstrap(this.transferTargetMapId);
  }

  private tryFinishTransferBootstrap(mapId: number) {
    if (this.transferTargetMapId == null || this.transferTargetMapId !== mapId) {
      return;
    }

    if (!this.transferMapDataReady || !this.transferBootstrapReceived) {
      this.predictionEnabled = false;
      return;
    }

    this.transferTargetMapId = null;
    this.transferBootstrapReceived = false;
    this.transferMapDataReady = false;
    this.predictionEnabled = true;
    this.renderer?.finishMapTransfer();
  }
}
