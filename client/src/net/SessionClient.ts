import type { Dispatch } from "react";
import type { ClientAction, ClientState, Direction, ServerPacket } from "../app/types";
import type { WorldRenderer } from "../render/WorldRenderer";
import { GameRuntime, type MovementDebugSnapshot } from "../runtime/GameRuntime";
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
export type { MovementDebugSnapshot } from "../runtime/GameRuntime";

export class SessionClient {
  private ws: WebSocket | null = null;
  private readonly dispatch: Dispatch<ClientAction>;
  private getState: () => ClientState;
  private readonly runtime: GameRuntime;
  private mapRequestId = 0;
  private selfCharIndex: number | null = null;

  constructor(dispatch: Dispatch<ClientAction>, getState: () => ClientState) {
    this.dispatch = dispatch;
    this.getState = getState;
    this.runtime = new GameRuntime(
      {
        sendWalk: (direction) => {
          this.sendRaw(encodeWalk(direction));
          this.dispatch({ type: "log/add", level: "packet-out", message: `WALK ${direction}` });
        },
        sendHeading: (direction) => {
          this.sendRaw(encodeChangeHeading(direction));
          this.dispatch({
            type: "log/add",
            level: "packet-out",
            message: `HEADING ${direction}`
          });
        },
        requestPositionUpdate: () => {
          this.sendRaw(encodeRequestPositionUpdate());
          this.dispatch({
            type: "log/add",
            level: "packet-out",
            message: "REQUEST_POSITION"
          });
        }
      },
      {
        getState: () => this.getState(),
        setSelfPosition: (x, y) => {
          this.dispatch({ type: "world/setSelfPosition", x, y });
        },
        setSelfHeading: (heading) => {
          this.dispatch({ type: "world/setSelfHeading", heading });
        }
      }
    );
  }

  setRenderer(renderer: WorldRenderer | null) {
    this.runtime.setRenderer(renderer);
  }

  connect(endpoint: string, characterName: string) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.dispatch({ type: "log/add", level: "warn", message: "Already connected." });
      return;
    }

    this.runtime.resetConnection();
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
      this.runtime.resetConnection();
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
    this.runtime.resetConnection();
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
    this.runtime.requestPositionUpdate();
  }

  getDebugSnapshot(): MovementDebugSnapshot {
    return this.runtime.getDebugSnapshot();
  }

  rememberMovementKey(direction: Direction) {
    this.runtime.rememberMovementKey(direction);
  }

  releaseMovementKey(direction: Direction) {
    this.runtime.releaseMovementKey(direction);
  }

  clearMovementKeys() {
    this.runtime.clearMovementKeys();
  }

  tick(now: number) {
    this.runtime.tick(now);
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

      this.runtime.onMapLoaded(mapId);
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
      this.runtime.onMapLoadError();
      this.dispatch({ type: "world/setMapError", mapId, message });
      this.dispatch({ type: "log/add", level: "error", message });
    }
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
          this.runtime.onMapChange(packet.mapId, hadActiveMap);
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
        this.runtime.onServerPosition(packet.x, packet.y);
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
          this.runtime.onSelfCharacter(packet.character);
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
          this.runtime.onSelfHeading(packet.heading);
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
}
