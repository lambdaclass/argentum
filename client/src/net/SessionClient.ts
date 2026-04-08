import type { Dispatch } from "react";
import type { ClientAction, ClientState, Direction, ServerPacket } from "../app/types";
import type { WorldRenderer } from "../render/WorldRenderer";
import { GameRuntime, type MovementDebugSnapshot } from "../runtime/GameRuntime";
import { fetchMapData } from "./mapApi";
import {
  encodeAttack,
  encodeBankDeposit,
  encodeBankDepositGold,
  encodeBankEnd,
  encodeBankExtractGold,
  encodeBankExtractItem,
  encodeBankStart,
  encodeCastSpell,
  encodeChangeHeading,
  encodeCommerceBuy,
  encodeCommerceEnd,
  encodeCommerceSell,
  encodeCommerceStart,
  encodeCreateCharacter,
  encodeDoubleClick,
  encodeDrop,
  encodeEquipItem,
  encodeHeal,
  encodeLeftClick,
  encodeLoginExisting,
  encodeMeditate,
  encodeOnline,
  encodePartySafeToggle,
  encodePickUp,
  encodeQuit,
  encodeRequestAttributes,
  encodeRequestMiniStats,
  encodeRequestPositionUpdate,
  encodeRequestSkills,
  encodeResucitate,
  encodeRest,
  encodeSafeToggle,
  encodeTalk,
  encodeUserTradeAccept,
  encodeUserTradeEnd,
  encodeUserTradeOffer,
  encodeUserTradeReject,
  encodeUseItem,
  encodeWalk,
  encodeWhisper,
  encodeYell
} from "../protocol/clientPackets";
import { decodeServerPackets } from "../protocol/serverPackets";
export type { MovementDebugSnapshot } from "../runtime/GameRuntime";

export interface SoundEffectPayload {
  wav: number;
  x: number;
  y: number;
  localize: boolean;
  cancelLast: boolean;
}

function transientId() {
  return Date.now() + Math.floor(Math.random() * 10_000);
}

export class SessionClient {
  private ws: WebSocket | null = null;
  private readonly dispatch: Dispatch<ClientAction>;
  private getState: () => ClientState;
  private readonly runtime: GameRuntime;
  private mapRequestId = 0;
  private selfCharIndex: number | null = null;
  private closeReason: string | null = null;
  private soundPlayer: ((payload: SoundEffectPayload) => void) | null = null;

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

  setSoundPlayer(soundPlayer: ((payload: SoundEffectPayload) => void) | null) {
    this.soundPlayer = soundPlayer;
  }

  connect(endpoint: string, characterName: string, bootstrapPassword: string) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.dispatch({ type: "log/add", level: "warn", message: "Already connected." });
      return;
    }

    const trimmedName = characterName.trim();
    const hasSavedSession = this.getState().connection.credentials != null;

    if (!hasSavedSession && trimmedName.length === 0) {
      this.dispatch({
        type: "connection/setStatus",
        status: "offline",
        lastError: "Account or character name is required."
      });
      this.dispatch({
        type: "log/add",
        level: "error",
        message: "Cannot start account login without a name."
      });
      return;
    }

    if (!hasSavedSession && bootstrapPassword.length === 0) {
      this.dispatch({
        type: "connection/setStatus",
        status: "offline",
        lastError: "Password is required."
      });
      this.dispatch({
        type: "log/add",
        level: "error",
        message: "Cannot start account login without a password."
      });
      return;
    }

    this.runtime.resetConnection();
    this.selfCharIndex = null;
    this.closeReason = null;
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
        this.sendRaw(encodeCreateCharacter(trimmedName, bootstrapPassword));
        this.dispatch({
          type: "log/add",
          level: "packet-out",
          message: `LOGIN_OR_CREATE name=${trimmedName}`
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
      const currentState = this.getState();
      const isBootstrapPhase =
        currentState.world.map == null &&
        currentState.world.self.charIndex == null;
      const bootstrapMessage =
        currentState.connection.lastError ??
        this.closeReason ??
        (isBootstrapPhase ? "Connection closed during bootstrap. Retrying…" : null);

      this.mapRequestId += 1;
      this.runtime.resetConnection();
      this.selfCharIndex = null;
      this.closeReason = null;
      this.dispatch({ type: "session/resetRuntime" });
      this.dispatch({
        type: "connection/setStatus",
        status: "offline",
        lastError: isBootstrapPhase ? bootstrapMessage : null
      });
      this.dispatch({
        type: "log/add",
        level: isBootstrapPhase ? "error" : "warn",
        message:
          isBootstrapPhase && bootstrapMessage
            ? bootstrapMessage
            : "Connection closed."
      });
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

  sendYell(message: string) {
    this.sendRaw(encodeYell(message));
    this.dispatch({ type: "log/add", level: "packet-out", message: `YELL "${message}"` });
  }

  sendWhisper(targetName: string, message: string) {
    this.sendRaw(encodeWhisper(targetName, message));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `WHISPER ${targetName}: "${message}"`
    });
  }

  sendPickUp() {
    this.sendRaw(encodePickUp());
    this.dispatch({ type: "log/add", level: "packet-out", message: "PICK_UP" });
  }

  sendAttack() {
    this.sendRaw(encodeAttack());
    this.dispatch({ type: "log/add", level: "packet-out", message: "ATTACK" });
  }

  sendCastSpell(slotIndex: number) {
    this.sendRaw(encodeCastSpell(slotIndex));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `CAST_SPELL slot=${slotIndex + 1}`
    });
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

  sendLeftClick(x: number, y: number) {
    this.sendRaw(encodeLeftClick(x, y));
    this.dispatch({ type: "world/setTargetTile", target: { x, y } });
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `LEFT_CLICK ${x},${y}`
    });
  }

  sendDoubleClick(x: number, y: number) {
    this.sendRaw(encodeDoubleClick(x, y));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `DOUBLE_CLICK ${x},${y}`
    });
  }

  sendSafeToggle() {
    this.sendRaw(encodeSafeToggle());
    this.dispatch({ type: "log/add", level: "packet-out", message: "SAFE_TOGGLE" });
  }

  sendRequestAttributes() {
    this.sendRaw(encodeRequestAttributes());
    this.dispatch({ type: "log/add", level: "packet-out", message: "REQUEST_ATTRIBUTES" });
  }

  sendRequestSkills() {
    this.sendRaw(encodeRequestSkills());
    this.dispatch({ type: "log/add", level: "packet-out", message: "REQUEST_SKILLS" });
  }

  sendCommerceStart() {
    this.sendRaw(encodeCommerceStart());
    this.dispatch({ type: "log/add", level: "packet-out", message: "COMMERCE_START" });
  }

  sendCommerceBuy(slotIndex: number, amount: number) {
    this.sendRaw(encodeCommerceBuy(slotIndex, amount));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `COMMERCE_BUY slot=${slotIndex + 1} amount=${amount}`
    });
  }

  sendCommerceSell(slotIndex: number, amount: number) {
    this.sendRaw(encodeCommerceSell(slotIndex, amount));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `COMMERCE_SELL slot=${slotIndex + 1} amount=${amount}`
    });
  }

  sendCommerceEnd() {
    this.sendRaw(encodeCommerceEnd());
    this.dispatch({ type: "log/add", level: "packet-out", message: "COMMERCE_END" });
  }

  sendBankStart() {
    this.sendRaw(encodeBankStart());
    this.dispatch({ type: "log/add", level: "packet-out", message: "BANK_START" });
  }

  sendBankDeposit(slotIndex: number, amount: number, destinationSlotIndex: number | null) {
    this.sendRaw(encodeBankDeposit(slotIndex, amount, destinationSlotIndex));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `BANK_DEPOSIT slot=${slotIndex + 1} amount=${amount} dest=${destinationSlotIndex == null ? 0 : destinationSlotIndex + 1}`
    });
  }

  sendBankExtractItem(slotIndex: number, amount: number, destinationSlotIndex: number | null) {
    this.sendRaw(encodeBankExtractItem(slotIndex, amount, destinationSlotIndex));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `BANK_EXTRACT slot=${slotIndex + 1} amount=${amount} dest=${destinationSlotIndex == null ? 0 : destinationSlotIndex + 1}`
    });
  }

  sendBankDepositGold(amount: number) {
    this.sendRaw(encodeBankDepositGold(amount));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `BANK_DEPOSIT_GOLD amount=${amount}`
    });
  }

  sendBankExtractGold(amount: number) {
    this.sendRaw(encodeBankExtractGold(amount));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `BANK_EXTRACT_GOLD amount=${amount}`
    });
  }

  sendBankEnd() {
    this.sendRaw(encodeBankEnd());
    this.dispatch({ type: "log/add", level: "packet-out", message: "BANK_END" });
  }

  sendRequestMiniStats() {
    this.sendRaw(encodeRequestMiniStats());
    this.dispatch({ type: "log/add", level: "packet-out", message: "REQUEST_MINI_STATS" });
  }

  sendOnline() {
    this.sendRaw(encodeOnline());
    this.dispatch({ type: "log/add", level: "packet-out", message: "ONLINE" });
  }

  sendRest() {
    this.sendRaw(encodeRest());
    this.dispatch({ type: "log/add", level: "packet-out", message: "REST" });
  }

  sendMeditate() {
    this.sendRaw(encodeMeditate());
    this.dispatch({ type: "log/add", level: "packet-out", message: "MEDITATE" });
  }

  sendHeal() {
    this.sendRaw(encodeHeal());
    this.dispatch({ type: "log/add", level: "packet-out", message: "HEAL" });
  }

  sendResucitate() {
    this.sendRaw(encodeResucitate());
    this.dispatch({ type: "log/add", level: "packet-out", message: "RESUCITATE" });
  }

  sendUserTradeOffer(itemId: number, amount: number) {
    this.dispatch({ type: "trade/markAccepted", accepted: false });
    this.dispatch({ type: "trade/markPartnerAccepted", accepted: false });
    this.sendRaw(encodeUserTradeOffer(itemId, amount));
    this.dispatch({
      type: "log/add",
      level: "packet-out",
      message: `USER_TRADE_OFFER item=${itemId} amount=${amount}`
    });
  }

  sendUserTradeAccept() {
    this.dispatch({ type: "trade/markAccepted", accepted: true });
    this.sendRaw(encodeUserTradeAccept());
    this.dispatch({ type: "log/add", level: "packet-out", message: "USER_TRADE_OK" });
  }

  sendUserTradeReject() {
    this.sendRaw(encodeUserTradeReject());
    this.dispatch({ type: "log/add", level: "packet-out", message: "USER_TRADE_REJECT" });
  }

  sendUserTradeEnd() {
    this.sendRaw(encodeUserTradeEnd());
    this.dispatch({ type: "log/add", level: "packet-out", message: "USER_TRADE_END" });
  }

  sendPartySafeToggle() {
    this.sendRaw(encodePartySafeToggle());
    this.dispatch({ type: "log/add", level: "packet-out", message: "PARTY_SAFE_TOGGLE" });
  }

  sendPartyInvite(name: string) {
    this.sendChat(`/PARTY ${name}`);
  }

  sendPartyAccept() {
    this.sendChat("/ACEPTARGRUPO");
  }

  sendPartyLeave() {
    this.sendChat("/SALIRGRUPO");
  }

  sendPartyKick(name: string) {
    this.sendChat(`/ECHARGRUPO ${name}`);
  }

  sendClanCreate(name: string) {
    this.sendChat(`/CREARCLAN ${name}`);
  }

  sendClanInvite(name: string) {
    this.sendChat(`/INVITARCLAN ${name}`);
  }

  sendClanAccept() {
    this.sendChat("/ACEPTARCLAN");
  }

  sendClanLeave() {
    this.sendChat("/SALIRCLAN");
  }

  sendClanChat(msg: string) {
    this.sendChat(`/CC ${msg}`);
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

  hasTargetTile() {
    return this.getState().world.targetTile != null;
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

  private setLastEvent(message: string | null) {
    this.dispatch({ type: "combat/setLastEvent", message });
  }

  private findCharacterTile(charIndex: number | null) {
    const world = this.getState().world;

    if (charIndex != null && world.self.charIndex === charIndex && world.self.x != null && world.self.y != null) {
      return { x: world.self.x, y: world.self.y };
    }

    if (charIndex != null) {
      const other = world.others[charIndex];
      if (other) {
        return { x: other.x, y: other.y };
      }
    }

    if (world.targetTile) {
      return world.targetTile;
    }

    if (world.self.x != null && world.self.y != null) {
      return { x: world.self.x, y: world.self.y };
    }

    return null;
  }

  private addCombatTextAt(
    x: number,
    y: number,
    text: string,
    tone: "damage" | "block" | "status" | "info",
    ttlMs = 1_100
  ) {
    this.dispatch({
      type: "world/addCombatText",
      event: {
        id: transientId(),
        x,
        y,
        text,
        tone,
        createdAt: Date.now(),
        ttlMs
      }
    });
  }

  private addCombatTextForChar(
    charIndex: number | null,
    text: string,
    tone: "damage" | "block" | "status" | "info",
    ttlMs = 1_100
  ) {
    const tile = this.findCharacterTile(charIndex);
    if (!tile) {
      return;
    }

    this.addCombatTextAt(tile.x, tile.y, text, tone, ttlMs);
  }

  private addFx(packet: Extract<ServerPacket, { type: "create_fx" }>) {
    const tile =
      packet.x > 0 && packet.y > 0
        ? { x: packet.x, y: packet.y }
        : this.findCharacterTile(packet.charIndex);

    if (!tile) {
      return;
    }

    this.dispatch({
      type: "world/addFx",
      event: {
        id: transientId(),
        x: tile.x,
        y: tile.y,
        fxId: packet.fxId,
        loops: packet.loops,
        createdAt: Date.now(),
        ttlMs: Math.max(700, 520 + packet.loops * 220)
      }
    });
  }

  private handlePacket(packet: ServerPacket) {
    switch (packet.type) {
      case "logged":
        this.dispatch({
          type: "log/add",
          level: "packet-in",
          message: `LOGGED new_user=${packet.newUser}`
        });
        this.sendRequestAttributes();
        this.sendRequestSkills();
        this.sendRequestMiniStats();
        return;

      case "navigate_toggle":
        this.dispatch({ type: "world/setSelfNavigation", navigating: packet.navigating });
        this.setLastEvent(packet.navigating ? "Embarcaste." : "Volviste a tierra.");
        this.dispatch({
          type: "log/add",
          level: "info",
          message: packet.navigating ? "Navigation enabled." : "Navigation disabled."
        });
        return;

      case "safe_mode_on":
        this.dispatch({ type: "combat/setSafeMode", safeMode: true });
        this.setLastEvent("Modo seguro activado.");
        this.dispatch({ type: "log/add", level: "info", message: "Safe mode enabled." });
        return;

      case "safe_mode_off":
        this.dispatch({ type: "combat/setSafeMode", safeMode: false });
        this.setLastEvent("Modo seguro desactivado.");
        this.dispatch({ type: "log/add", level: "info", message: "Safe mode disabled." });
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

      case "character_change":
        if (packet.charIndex === this.getState().world.self.charIndex) {
          this.runtime.onSelfHeading(packet.heading);
        }
        this.dispatch({
          type: "world/setCharacterAppearance",
          charIndex: packet.charIndex,
          bodyId: packet.bodyId,
          headId: packet.headId,
          weaponId: packet.weaponId,
          shieldId: packet.shieldId,
          helmetId: packet.helmetId,
          cartId: packet.cartId,
          backpackId: packet.backpackId,
          effectId: packet.effectId,
          effectLoops: packet.effectLoops,
          heading: packet.heading
        });
        return;

      case "char_swing":
        this.addCombatTextForChar(packet.charIndex, "SWING", "info", 700);
        return;

      case "npc_kill_user":
        this.dispatch({ type: "world/setSelfDead", dead: true });
        this.addCombatTextForChar(this.getState().world.self.charIndex, "DEAD", "status", 1_600);
        this.setLastEvent("Has muerto.");
        this.dispatch({ type: "log/add", level: "warn", message: "NPC kill user." });
        return;

      case "blocked_with_shield_user":
        this.addCombatTextForChar(this.getState().world.self.charIndex, "BLOCK", "block");
        this.setLastEvent("Bloqueaste el golpe con escudo.");
        return;

      case "blocked_with_shield_other":
        this.addCombatTextForChar(packet.charIndex, "BLOCK", "block");
        this.setLastEvent("El objetivo bloqueo el golpe.");
        return;

      case "npc_hit_user":
        this.addCombatTextForChar(this.getState().world.self.charIndex, `-${packet.damage}`, "damage");
        this.setLastEvent(`Un NPC te golpeo por ${packet.damage}.`);
        return;

      case "user_hitted_user":
        this.addCombatTextForChar(packet.charIndex, `-${packet.damage}`, "damage");
        this.setLastEvent(`Golpeaste por ${packet.damage}.`);
        return;

      case "user_hitted_by_user":
        this.addCombatTextForChar(this.getState().world.self.charIndex, `-${packet.damage}`, "damage");
        this.setLastEvent(`Recibiste ${packet.damage} de dano.`);
        return;

      case "change_inventory_slot":
        this.dispatch({
          type: "inventory/setSlot",
          slotIndex: packet.slotIndex,
          slot: packet.slot
        });
        return;

      case "change_spell_slot":
        this.dispatch({
          type: "spellbook/setSlot",
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

      case "update_exp":
        this.dispatch({
          type: "stats/setExp",
          current: packet.currentXp,
          next: packet.nextXp
        });
        return;

      case "level_up":
        this.dispatch({ type: "stats/setLevel", level: packet.level });
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

      case "update_user_stats":
        this.dispatch({
          type: "stats/setAll",
          hpCurrent: packet.hpCurrent,
          hpMax: packet.hpMax,
          manaCurrent: packet.manaCurrent,
          manaMax: packet.manaMax,
          staminaCurrent: packet.staminaCurrent,
          staminaMax: packet.staminaMax,
          gold: packet.gold,
          level: packet.level,
          currentXp: packet.currentXp,
          nextXp: packet.nextXp
        });
        return;

      case "intervals":
        this.dispatch({ type: "world/setWalkInterval", walkIntervalMs: packet.walk });
        return;

      case "console_msg":
        if (packet.message === "Has muerto!" || packet.message === "Estas muerto.") {
          this.dispatch({ type: "world/setSelfDead", dead: true });
        }
        if (packet.message === "Has sido resucitado." || packet.message === "Has sido resucitado!") {
          this.dispatch({ type: "world/setSelfDead", dead: false });
        }
        this.parsePartyMessage(packet.message);
        this.setLastEvent(packet.message);
        this.dispatch({ type: "log/add", level: "info", message: packet.message });
        return;

      case "console_faction_message":
        this.dispatch({ type: "log/add", level: "info", message: `[${packet.factionLabel}] ${packet.message}` });
        return;

      case "guild_chat":
        this.dispatch({ type: "log/add", level: "info", message: `[Clan] ${packet.message}` });
        return;

      case "error_msg":
      {
        const credentials = this.getState().connection.credentials;
        const world = this.getState().world;
        const bootstrapError = world.map == null && world.self.charIndex == null;

        if (
          bootstrapError &&
          credentials &&
          (packet.message === "Invalid session token." || packet.message === "Character not found.")
        ) {
          this.dispatch({ type: "connection/setCredentials", credentials: null });
          this.dispatch({
            type: "log/add",
            level: "warn",
            message: "Saved session was rejected and has been cleared."
          });
        }

        this.dispatch({
          type: "connection/setStatus",
          status: bootstrapError ? "offline" : "connected",
          lastError: packet.message
        });
        this.setLastEvent(packet.message);
        this.dispatch({ type: "log/add", level: "error", message: packet.message });

        if (bootstrapError && this.ws && this.ws.readyState === WebSocket.OPEN) {
          this.closeReason = packet.message;
          this.ws.close();
        }
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

      case "rain_toggle":
        this.dispatch({ type: "weather/rain", raining: packet.raining });
        this.dispatch({
          type: "log/add",
          level: "info",
          message: packet.raining ? "Rain started." : "Rain stopped."
        });
        return;

      case "create_fx":
        this.addFx(packet);
        return;

      case "play_wave":
        this.soundPlayer?.({
          wav: packet.wav,
          x: packet.x,
          y: packet.y,
          localize: packet.localize,
          cancelLast: packet.cancelLast
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

      case "commerce_init":
        this.dispatch({ type: "commerce/open", npcName: packet.npcName });
        this.setLastEvent(`Comercio abierto con ${packet.npcName}.`);
        return;

      case "bank_init":
        this.dispatch({ type: "bank/open" });
        this.setLastEvent("Banco abierto.");
        return;

      case "user_commerce_init":
        this.dispatch({ type: "trade/open" });
        this.setLastEvent("Trueque abierto.");
        return;

      case "user_commerce_end":
        this.dispatch({ type: "trade/close" });
        this.setLastEvent("Trueque cerrado.");
        return;

      case "change_npc_inventory_slot":
        this.dispatch({
          type: "commerce/setSlot",
          slotIndex: packet.slotIndex,
          slot: packet.slot
        });
        return;

      case "change_bank_slot":
        this.dispatch({
          type: "bank/setSlot",
          slotIndex: packet.slotIndex,
          slot: packet.slot
        });
        return;

      case "change_user_trade_slot":
        this.dispatch({
          type: "trade/setOffer",
          which: packet.myOffer ? "mine" : "theirs",
          gold: packet.gold,
          items: packet.items
        });
        if (!packet.myOffer) {
          this.setLastEvent("La otra oferta del trueque cambio.");
        }
        return;

      case "commerce_end":
        this.dispatch({ type: "commerce/close" });
        this.setLastEvent("Comercio cerrado.");
        return;

      case "bank_end":
        this.dispatch({ type: "bank/close" });
        this.setLastEvent("Banco cerrado.");
        return;

      case "update_bank_gold":
        this.dispatch({ type: "bank/setGold", bankGold: packet.bankGold });
        return;

      case "send_skills":
        this.dispatch({
          type: "skills/setAll",
          entries: packet.skills,
          source: "server"
        });
        return;

      case "mini_stats":
        this.dispatch({
          type: "world/setMiniStats",
          classId: packet.classId,
          raceId: packet.raceId,
          genderId: packet.genderId,
          factionStatus: packet.factionStatus
        });
        this.dispatch({
          type: "log/add",
          level: "packet-in",
          message: `MINI_STATS class=${packet.classId} race=${packet.raceId} gender=${packet.genderId} faction=${packet.factionStatus}`
        });
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

  private parsePartyMessage(message: string) {
    const lower = message.toLowerCase();

    if (lower.includes("te invita") || lower.includes("has sido invitado")) {
      const nameMatch = message.match(/^(\S+)\s+te invita/i);
      const inviterName = nameMatch ? nameMatch[1] : "";
      this.dispatch({ type: "party/setInvite", invited: true, inviterName });
      return;
    }

    if (lower.includes("has ingresado al grupo") || lower.includes("se ha unido al grupo")) {
      const nameMatch = message.match(/^(\S+)\s+se ha unido/i);
      if (nameMatch) {
        const currentMembers = this.getState().party.members;
        if (!currentMembers.includes(nameMatch[1])) {
          this.dispatch({ type: "party/setMembers", members: [...currentMembers, nameMatch[1]] });
        }
      }
      this.dispatch({ type: "party/setInvite", invited: false, inviterName: "" });
      return;
    }

    if (lower.includes("ha salido del grupo") || lower.includes("has salido del grupo")) {
      const nameMatch = message.match(/^(\S+)\s+ha salido/i);
      if (nameMatch) {
        const currentMembers = this.getState().party.members;
        this.dispatch({
          type: "party/setMembers",
          members: currentMembers.filter((m) => m !== nameMatch[1])
        });
      } else if (lower.startsWith("has salido")) {
        this.dispatch({ type: "party/clear" });
      }
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
      this.dispatch({ type: "world/setCharacterAppearance", charIndex, heading });
    }
  }
}
