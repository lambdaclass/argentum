import type { Dispatch } from "react";
import type { ClientAction, ClientState, Direction, ServerPacket } from "../app/types";
import { fetchMapData } from "./mapApi";
import {
  encodeChangeHeading,
  encodeCreateCharacter,
  encodeDrop,
  encodeEquipItem,
  encodeLoginExisting,
  encodePickUp,
  encodeQuit,
  encodeRequestPositionUpdate,
  encodeTalk,
  encodeUseItem,
  encodeWalk
} from "../protocol/clientPackets";
import { decodeServerPackets } from "../protocol/serverPackets";

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

export class SessionClient {
  private ws: WebSocket | null = null;
  private readonly dispatch: Dispatch<ClientAction>;
  private getState: () => ClientState;
  private mapRequestId = 0;
  private movementKeys: Direction[] = [];
  private lastWalkAt = Number.NEGATIVE_INFINITY;
  private pendingWalkSteps: Array<{ x: number; y: number; timeoutId: number }> = [];
  private selfCharIndex: number | null = null;
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

  constructor(dispatch: Dispatch<ClientAction>, getState: () => ClientState) {
    this.dispatch = dispatch;
    this.getState = getState;
  }

  connect(endpoint: string, characterName: string) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.dispatch({ type: "log/add", level: "warn", message: "Already connected." });
      return;
    }

    this.resetDebugTracking();
    this.predictionEnabled = false;
    this.transferTargetMapId = null;
    this.transferBootstrapReceived = false;
    this.transferMapDataReady = false;
    this.selfCharIndex = null;
    this.dispatch({ type: "connection/setStatus", status: "connecting" });
    this.dispatch({
      type: "log/add",
      level: "info",
      message: `Connecting to ${endpoint}`
    });

    try {
      this.ws = new WebSocket(endpoint);
    } catch (error) {
      const message = error instanceof Error ? error.message : "WebSocket failed.";
      this.dispatch({ type: "connection/setStatus", status: "offline", lastError: message });
      this.dispatch({ type: "log/add", level: "error", message });
      return;
    }

    this.ws.binaryType = "arraybuffer";

    this.ws.addEventListener("open", () => {
      this.dispatch({ type: "connection/setStatus", status: "connected" });

      const credentials = this.getState().connection.credentials;
      if (credentials) {
        this.sendRaw(encodeLoginExisting(credentials.charId, credentials.token));
        this.dispatch({
          type: "log/add",
          level: "packet-out",
          message: `LOGIN char_id=${credentials.charId}`
        });
      } else {
        this.sendRaw(encodeCreateCharacter(characterName));
        this.dispatch({
          type: "log/add",
          level: "packet-out",
          message: `CREATE ${characterName}`
        });
      }
    });

    this.ws.addEventListener("message", (event) => {
      if (!(event.data instanceof ArrayBuffer)) {
        return;
      }

      for (const packet of decodeServerPackets(event.data)) {
        this.handlePacket(packet);
      }
    });

    this.ws.addEventListener("close", () => {
      this.mapRequestId += 1;
      this.clearMovementKeys();
      this.clearPendingWalkSteps();
      this.lastWalkAt = Number.NEGATIVE_INFINITY;
      this.resetDebugTracking();
      this.predictionEnabled = false;
      this.transferTargetMapId = null;
      this.transferBootstrapReceived = false;
      this.transferMapDataReady = false;
      this.selfCharIndex = null;
      this.dispatch({ type: "connection/setStatus", status: "offline" });
      this.dispatch({ type: "session/resetRuntime" });
      this.dispatch({ type: "log/add", level: "warn", message: "Connection closed." });
      this.ws = null;
    });

    this.ws.addEventListener("error", () => {
      this.dispatch({
        type: "connection/setStatus",
        status: "offline",
        lastError: "WebSocket error."
      });
      this.dispatch({ type: "log/add", level: "error", message: "WebSocket error." });
    });
  }

  disconnect() {
    if (!this.ws) {
      return;
    }

    if (this.ws.readyState === WebSocket.OPEN) {
      this.sendRaw(encodeQuit());
    }

    this.ws.close();
  }

  destroy() {
    this.mapRequestId += 1;
    this.clearMovementKeys();
    this.clearPendingWalkSteps();
    this.resetDebugTracking();
    this.predictionEnabled = false;
    this.transferTargetMapId = null;
    this.transferBootstrapReceived = false;
    this.transferMapDataReady = false;
    this.selfCharIndex = null;
    this.ws?.close();
  }

  sendWalk(direction: Direction) {
    this.sendRaw(encodeWalk(direction));
    this.dispatch({ type: "log/add", level: "packet-out", message: `WALK ${direction}` });
  }

  sendHeading(direction: Direction) {
    this.sendRaw(encodeChangeHeading(direction));
    this.dispatch({ type: "log/add", level: "packet-out", message: `HEADING ${direction}` });
  }

  sendChat(message: string) {
    this.sendRaw(encodeTalk(message));
    this.dispatch({ type: "log/add", level: "packet-out", message: `CHAT "${message}"` });
  }

  sendPickUp() {
    this.sendRaw(encodePickUp());
    this.dispatch({ type: "log/add", level: "packet-out", message: "PICK_UP" });
  }

  sendUse(slotIndex: number) {
    this.sendRaw(encodeUseItem(slotIndex));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `USE slot=${slotIndex + 1}`
    });
  }

  sendEquip(slotIndex: number) {
    this.sendRaw(encodeEquipItem(slotIndex));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `EQUIP slot=${slotIndex + 1}`
    });
  }

  sendDrop(slotIndex: number, amount: number) {
    this.sendRaw(encodeDrop(slotIndex, amount));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `DROP slot=${slotIndex + 1} amount=${amount}`
    });
  }

  requestPositionUpdate() {
    this.requestCount += 1;
    this.lastRequestAt = Date.now();
    this.sendRaw(encodeRequestPositionUpdate());
    this.dispatch({ type: "log/add", level: "packet-out", message: "REQUEST_POSITION" });
  }

  getDebugSnapshot(): MovementDebugSnapshot {
    const self = this.getState().world.self;

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

  private sendRaw(payload: Uint8Array) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return;
    }

    this.ws.send(payload);
  }

  private async loadMap(mapId: number) {
    const requestId = ++this.mapRequestId;
    const endpoint = this.getState().connection.endpoint;

    this.dispatch({ type: "world/setMapLoading", mapId });

    try {
      const { map, groundObjects } = await fetchMapData(endpoint, mapId);

      if (requestId !== this.mapRequestId) {
        return;
      }

      this.dispatch({ type: "world/setMapData", map, groundObjects });

      if (this.transferTargetMapId == null) {
        this.predictionEnabled = true;
      } else {
        this.transferMapDataReady = true;
        this.tryFinishTransferBootstrap(mapId);
      }
      this.dispatch({
        type: "log/add",
        level: "info",
        message: `Map loaded: ${map.name} (${map.npcs.length} NPCs, ${Object.keys(groundObjects).length} objects, ${map.exits.length} exits)`
      });
    } catch (error) {
      if (requestId !== this.mapRequestId) {
        return;
      }

      const message = error instanceof Error ? error.message : "Map fetch failed.";
      this.predictionEnabled = false;
      this.transferMapDataReady = false;
      this.dispatch({ type: "world/setMapError", mapId, message });
      this.dispatch({ type: "log/add", level: "error", message });
    }
  }

  private clearPendingWalkSteps() {
    for (const step of this.pendingWalkSteps) {
      window.clearTimeout(step.timeoutId);
    }
    this.pendingWalkSteps = [];
  }

  private activeMovementDirection() {
    return this.movementKeys.length > 0 ? this.movementKeys[this.movementKeys.length - 1] : null;
  }

  private currentWalkIntervalMs() {
    const state = this.getState();
    const speed = state.world.self.speed > 0 ? state.world.self.speed : 1;
    return Math.max(40, state.world.walkIntervalMs / speed);
  }

  private tileIndex(x: number, y: number, width: number) {
    return (y - 1) * width + (x - 1);
  }

  private isTileBlocked(x: number, y: number) {
    const map = this.getState().world.map;
    if (!map) {
      return false;
    }

    if (x < 1 || x > map.width || y < 1 || y > map.height) {
      return true;
    }

    return (map.tiles[this.tileIndex(x, y, map.width)] ?? 0) !== 0;
  }

  private predictedDestination(direction: Direction) {
    const self = this.getState().world.self;
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
      timeoutId: window.setTimeout(() => {
        if (this.pendingWalkSteps.length > 0 && this.pendingWalkSteps[this.pendingWalkSteps.length - 1] === step) {
          this.requestPositionUpdate();
        }
      }, timeoutMs)
    };

    this.pendingWalkSteps.push(step);
  }

  private consumePendingStep(x: number, y: number) {
    for (let index = 0; index < this.pendingWalkSteps.length; index += 1) {
      const step = this.pendingWalkSteps[index];
      if (step.x === x && step.y === y) {
        for (let consumed = 0; consumed <= index; consumed += 1) {
          window.clearTimeout(this.pendingWalkSteps[consumed].timeoutId);
        }
        this.pendingWalkSteps = this.pendingWalkSteps.slice(index + 1);
        return true;
      }
    }

    return false;
  }

  private tryPredictedWalk(direction: Direction, now: number) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return false;
    }

    const world = this.getState().world;
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

    if (this.isTileBlocked(destination.x, destination.y)) {
      if (this.getState().world.self.heading !== destination.heading) {
        this.sendHeading(direction);
        this.dispatch({ type: "world/setSelfHeading", heading: destination.heading });
      }
      return false;
    }

    this.sendWalk(direction);
    this.lastWalkAt = now;

    if (this.getState().world.self.heading !== destination.heading) {
      this.dispatch({ type: "world/setSelfHeading", heading: destination.heading });
    }

    this.dispatch({
      type: "world/setSelfPosition",
      x: destination.x,
      y: destination.y
    });
    this.pushPendingWalkStep(destination.x, destination.y);
    return true;
  }

  private handlePacket(packet: ServerPacket) {
    switch (packet.type) {
      case "logged":
        this.dispatch({
          type: "log/add",
          level: "packet-in",
          message: `LOGGED new_user=${packet.newUser}`
        });
        return;

      case "change_map":
        {
          const hadActiveMap = this.getState().world.map != null;
        this.clearPendingWalkSteps();
        this.authorityX = null;
        this.authorityY = null;
        this.predictionEnabled = false;
        this.transferTargetMapId = hadActiveMap ? packet.mapId : null;
        this.transferBootstrapReceived = false;
        this.transferMapDataReady = false;
        this.dispatch({ type: "world/setMap", mapId: packet.mapId });
        this.dispatch({
          type: "log/add",
          level: "packet-in",
          message: `MAP ${packet.mapId}`
        });
        void this.loadMap(packet.mapId);
        return;
        }

      case "pos_update":
        if (
          this.authorityX !== packet.x ||
          this.authorityY !== packet.y ||
          this.getState().world.self.x !== packet.x ||
          this.getState().world.self.y !== packet.y
        ) {
          this.lastCorrectionAt = Date.now();
          this.correctionCount += 1;
        }

        this.authorityX = packet.x;
        this.authorityY = packet.y;
        if (!this.consumePendingStep(packet.x, packet.y)) {
          this.dispatch({ type: "world/setSelfPosition", x: packet.x, y: packet.y });
        }
        this.noteTransferBootstrap();
        return;

      case "user_char_index_in_server":
        this.selfCharIndex = packet.charIndex;
        this.dispatch({ type: "world/setCharIndex", charIndex: packet.charIndex });
        this.dispatch({
          type: "log/add",
          level: "packet-in",
          message: `CHAR_IDX ${packet.charIndex}`
        });
        return;

      case "character_create": {
        const isSelf = this.selfCharIndex === packet.character.charIndex;
        if (isSelf) {
          this.authorityX = packet.character.x;
          this.authorityY = packet.character.y;
        }
        this.dispatch({
          type: "world/upsertCharacter",
          character: packet.character,
          self: isSelf
        });
        this.dispatch({
          type: "log/add",
          level: "packet-in",
          message: `CHAR_CREATE ${packet.character.name} (${packet.character.x},${packet.character.y})`
        });
        if (isSelf) {
          this.noteTransferBootstrap();
        }
        return;
      }

      case "character_move":
        this.updateRemoteHeadingFromMovement(packet.charIndex, packet.x, packet.y);
        this.dispatch({
          type: "world/moveOther",
          charIndex: packet.charIndex,
          x: packet.x,
          y: packet.y
        });
        return;

      case "character_remove":
        this.dispatch({ type: "world/removeOther", charIndex: packet.charIndex });
        return;

      case "character_change_heading":
        if (packet.charIndex === this.getState().world.self.charIndex) {
          this.dispatch({ type: "world/setSelfHeading", heading: packet.heading });
        } else {
          this.dispatch({
            type: "world/setOtherHeading",
            charIndex: packet.charIndex,
            heading: packet.heading
          });
        }
        return;

      case "change_inventory_slot":
        this.dispatch({
          type: "inventory/setSlot",
          slotIndex: packet.slotIndex,
          slot: packet.slot
        });
        return;

      case "update_hunger_and_thirst":
        this.dispatch({
          type: "stats/setHungerThirst",
          hunger: packet.hunger,
          thirst: packet.thirst
        });
        return;

      case "update_gold":
        this.dispatch({ type: "stats/setGold", gold: packet.gold });
        return;

      case "update_hp":
        this.dispatch({ type: "stats/setHp", current: packet.current });
        return;

      case "update_mana":
        this.dispatch({ type: "stats/setMana", current: packet.current });
        return;

      case "update_stamina":
        this.dispatch({ type: "stats/setStamina", current: packet.current });
        return;

      case "intervals":
        this.dispatch({ type: "world/setWalkInterval", walkIntervalMs: packet.walk });
        return;

      case "console_msg":
        this.dispatch({ type: "log/add", level: "info", message: packet.message });
        return;

      case "error_msg":
      {
        const world = this.getState().world;
        const bootstrapError = world.map == null && world.self.charIndex == null;
        this.dispatch({
          type: "connection/setStatus",
          status: bootstrapError ? "offline" : "connected",
          lastError: packet.message
        });
        this.dispatch({ type: "log/add", level: "error", message: packet.message });
        return;
      }

      case "session_token":
        this.dispatch({ type: "connection/setCredentials", credentials: packet.credentials });
        this.dispatch({
          type: "log/add",
          level: "info",
          message: `Session saved for char_id=${packet.credentials.charId}`
        });
        return;

      case "chat_over_head":
        this.dispatch({
          type: "world/addChatBubble",
          bubble: {
            id: Date.now() + Math.floor(Math.random() * 10_000),
            message: packet.message,
            x: packet.x,
            y: packet.y,
            createdAt: Date.now(),
            ttlMs: 4_000
          }
        });
        this.dispatch({
          type: "log/add",
          level: "packet-in",
          message: `CHAT[${packet.charIndex}] ${packet.message} @ ${packet.x},${packet.y}`
        });
        return;

      case "object_create":
        this.dispatch({
          type: "world/upsertGroundObject",
          object: {
            x: packet.x,
            y: packet.y,
            id: packet.objIndex,
            amount: packet.amount
          }
        });
        return;

      case "object_delete":
        this.dispatch({
          type: "world/removeGroundObject",
          x: packet.x,
          y: packet.y
        });
        return;

      case "user_index_in_server":
        return;

      case "unknown":
        this.dispatch({
          type: "log/add",
          level: "warn",
          message: `Unhandled packet ${packet.packetId}`
        });
        return;
    }
  }

  private updateRemoteHeadingFromMovement(charIndex: number, x: number, y: number) {
    const other = this.getState().world.others[charIndex];
    if (!other) {
      return;
    }

    let heading = other.heading;
    const dx = x - other.x;
    const dy = y - other.y;

    if (dy < 0) {
      heading = 1;
    } else if (dx > 0) {
      heading = 2;
    } else if (dy > 0) {
      heading = 3;
    } else if (dx < 0) {
      heading = 4;
    }

    if (heading !== other.heading) {
      this.dispatch({ type: "world/setOtherHeading", charIndex, heading });
    }
  }

  private resetDebugTracking() {
    this.authorityX = null;
    this.authorityY = null;
    this.requestCount = 0;
    this.lastRequestAt = null;
    this.correctionCount = 0;
    this.lastCorrectionAt = null;
  }

  private tryFinishTransferBootstrap(mapId: number) {
    if (this.transferTargetMapId == null || this.transferTargetMapId != mapId) {
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
  }

  private noteTransferBootstrap() {
    if (this.transferTargetMapId == null) {
      return;
    }

    this.transferBootstrapReceived = true;
    this.tryFinishTransferBootstrap(this.transferTargetMapId);
  }
}
