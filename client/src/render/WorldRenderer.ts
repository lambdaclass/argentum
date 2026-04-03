import {
  Application,
  Container,
  Graphics,
  Sprite,
  Text,
  TextStyle,
  Texture
} from "pixi.js";
import type {
  ChatBubble,
  Direction,
  GroundObject,
  WorldMapData,
  WorldState
} from "../app/types";
import {
  bodyGrhForDirection,
  getGrhAnimation,
  getGrhTexture,
  getObjectGrh,
  type AssetCatalog,
  headGrhForDirection
} from "./assetCatalog";
import { getMapPackRecord } from "../net/mapApi";

const TILE_SIZE = 32;
const DEFAULT_MAP_SIZE = 100;
const VIEWPORT_WIDTH = 736;
const VIEWPORT_HEIGHT = 608;

const hudStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 12,
  fill: 0xeed7b7
});

const selfNameStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 10,
  fill: 0xffffff,
  stroke: 0x000000,
  strokeThickness: 2
});

const otherNameStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 10,
  fill: 0xffcc66,
  stroke: 0x000000,
  strokeThickness: 2
});

const npcNameStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 10,
  fill: 0xf0c989,
  stroke: 0x000000,
  strokeThickness: 2
});

const amountStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 10,
  fill: 0xf7ddb5,
  stroke: 0x000000,
  strokeThickness: 2
});

const bubbleStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 12,
  fill: 0xffff00,
  stroke: 0x000000,
  strokeThickness: 3
});

const damageTextStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 14,
  fontWeight: "700",
  fill: 0xff8a73,
  stroke: 0x000000,
  strokeThickness: 3
});

const blockTextStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 12,
  fontWeight: "700",
  fill: 0xa5d4ff,
  stroke: 0x000000,
  strokeThickness: 3
});

const statusTextStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 12,
  fontWeight: "700",
  fill: 0xffdd85,
  stroke: 0x000000,
  strokeThickness: 3
});

const infoTextStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 11,
  fill: 0xf0f2ff,
  stroke: 0x000000,
  strokeThickness: 3
});

const exitStyle = new TextStyle({
  fontFamily: "monospace",
  fontSize: 10,
  fill: 0xc8f0a0,
  stroke: 0x000000,
  strokeThickness: 2
});

interface MotionState {
  initialized: boolean;
  startX: number;
  startY: number;
  targetX: number;
  targetY: number;
  renderX: number;
  renderY: number;
  startedAt: number;
  durationMs: number;
}

interface CharacterNode {
  container: Container;
  bodySprite: Sprite | null;
  bodyFrames: Texture[] | null;
  frameVelocity: number;
  frameIndex: number;
  lastFrameAt: number;
  motion: MotionState;
  name: string;
  bodyId: number;
  headId: number;
  heading: number;
  speed: number;
  kind: "self" | "other" | "npc";
  desiredX: number;
  desiredY: number;
}

interface CharacterVisual {
  container: Container;
  bodySprite: Sprite | null;
  bodyFrames: Texture[] | null;
  frameVelocity: number;
}

interface StaticSceneLayers {
  belowCharacters: Container;
  staticEntities: Container;
  overlay: Container;
}

export interface TileInteractionPayload {
  x: number;
  y: number;
  detail: number;
}

function worldX(tileX: number) {
  return (tileX - 1) * TILE_SIZE;
}

function worldY(tileY: number) {
  return (tileY - 1) * TILE_SIZE;
}

function tileCenterX(tileX: number) {
  return worldX(tileX) + TILE_SIZE / 2;
}

function tileCenterY(tileY: number) {
  return worldY(tileY) + TILE_SIZE / 2;
}

function worldLabel(name: string) {
  return name.length > 14 ? `${name.slice(0, 11)}...` : name;
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

function headingToDirection(heading: number): Direction {
  switch (heading) {
    case 1:
      return "north";
    case 2:
      return "east";
    case 4:
      return "west";
    default:
      return "south";
  }
}

function applyAoAnchor(sprite: Sprite) {
  const width = sprite.texture.width;
  const height = sprite.texture.height;

  if (width <= 0 || height <= 0) {
    sprite.anchor.set(0, 0);
    return;
  }

  sprite.anchor.set((width - TILE_SIZE) / (2 * width), (height - TILE_SIZE) / height);
}

function createMotionState(): MotionState {
  return {
    initialized: false,
    startX: 0,
    startY: 0,
    targetX: 0,
    targetY: 0,
    renderX: 0,
    renderY: 0,
    startedAt: 0,
    durationMs: 0
  };
}

function snapMotionToTile(motion: MotionState, x: number, y: number) {
  const px = worldX(x);
  const py = worldY(y);
  motion.initialized = true;
  motion.startX = px;
  motion.startY = py;
  motion.targetX = px;
  motion.targetY = py;
  motion.renderX = px;
  motion.renderY = py;
  motion.startedAt = performance.now();
  motion.durationMs = 0;
}

function sampleMotion(motion: MotionState, now: number) {
  if (!motion.initialized || motion.durationMs <= 0) {
    return { x: motion.targetX, y: motion.targetY };
  }

  const progress = clamp((now - motion.startedAt) / motion.durationMs, 0, 1);
  return {
    x: motion.startX + (motion.targetX - motion.startX) * progress,
    y: motion.startY + (motion.targetY - motion.startY) * progress
  };
}

function animateMotionToTile(motion: MotionState, x: number, y: number, durationMs: number) {
  const px = worldX(x);
  const py = worldY(y);

  if (!motion.initialized) {
    snapMotionToTile(motion, x, y);
    return;
  }

  if (motion.targetX === px && motion.targetY === py) {
    return;
  }

  const now = performance.now();
  const current = sampleMotion(motion, now);
  motion.startX = current.x;
  motion.startY = current.y;
  motion.targetX = px;
  motion.targetY = py;
  motion.renderX = current.x;
  motion.renderY = current.y;
  motion.startedAt = now;
  motion.durationMs = Math.max(1, durationMs);
}

function createFallbackCharacter(
  name: string,
  heading: number,
  fillColor: number,
  outlineColor: number,
  labelStyle: TextStyle,
  shape: "circle" | "square" | "diamond"
) {
  const container = new Container();
  const displayName = worldLabel(name);
  const marker = new Graphics();
  const centerX = TILE_SIZE / 2;
  const centerY = TILE_SIZE / 2;

  marker.lineStyle(2, outlineColor, 1);
  marker.beginFill(fillColor, 0.95);

  if (shape === "circle") {
    marker.drawCircle(centerX, centerY, 11);
  } else if (shape === "diamond") {
    marker.drawPolygon([
      centerX,
      centerY - 10,
      centerX + 10,
      centerY,
      centerX,
      centerY + 10,
      centerX - 10,
      centerY
    ]);
  } else {
    marker.drawRoundedRect(centerX - 10, centerY - 10, 20, 20, 4);
  }

  marker.endFill();

  marker.lineStyle(3, outlineColor, 0.95);
  switch (headingToDirection(heading)) {
    case "north":
      marker.moveTo(centerX, centerY + 2);
      marker.lineTo(centerX, centerY - 10);
      break;
    case "east":
      marker.moveTo(centerX + 2, centerY);
      marker.lineTo(centerX + 10, centerY);
      break;
    case "south":
      marker.moveTo(centerX, centerY - 2);
      marker.lineTo(centerX, centerY + 10);
      break;
    case "west":
      marker.moveTo(centerX - 2, centerY);
      marker.lineTo(centerX - 10, centerY);
      break;
  }

  const label = new Text(displayName, labelStyle);
  label.anchor.set(0.5, 1);
  label.x = centerX;
  label.y = centerY - 14;

  container.addChild(marker);
  container.addChild(label);
  return container;
}

function createLayerSprite(
  catalog: AssetCatalog,
  grhId: number,
  tileX: number,
  tileY: number,
  useCharIndex = false
) {
  const texture = getGrhTexture(catalog, grhId, useCharIndex);
  if (!texture) {
    return null;
  }

  const sprite = new Sprite(texture);
  applyAoAnchor(sprite);
  sprite.x = worldX(tileX);
  sprite.y = worldY(tileY);
  return sprite;
}

function createObjectNode(catalog: AssetCatalog | null, object: GroundObject) {
  const container = new Container();
  const grhId = getObjectGrh(catalog, object.id);

  if (catalog && grhId) {
    const sprite = createLayerSprite(catalog, grhId, object.x, object.y);
    if (sprite) {
      container.addChild(sprite);
    }
  }

  if (container.children.length === 0) {
    const fallback = new Graphics();
    fallback.lineStyle(2, 0x5f420a, 1);
    fallback.beginFill(0xf0c45e, 0.95);
    fallback.drawRoundedRect(-8, -8, 16, 16, 3);
    fallback.endFill();
    fallback.x = tileCenterX(object.x);
    fallback.y = tileCenterY(object.y);
    container.addChild(fallback);
  }

  if (object.amount > 1) {
    const label = new Text(`x${object.amount}`, amountStyle);
    label.anchor.set(0.5, 1);
    label.x = tileCenterX(object.x);
    label.y = worldY(object.y) - 4;
    container.addChild(label);
  }

  return container;
}

function walkIntervalForSpeed(baseInterval: number, speed: number) {
  return Math.max(40, baseInterval / Math.max(speed, 1));
}

function createCharacterVisual(
  catalog: AssetCatalog | null,
  name: string,
  bodyId: number,
  headId: number,
  heading: number,
  kind: "self" | "other" | "npc"
): CharacterVisual {
  const direction = headingToDirection(heading);
  const displayName = worldLabel(name);
  const labelStyle =
    kind === "self" ? selfNameStyle : kind === "npc" ? npcNameStyle : otherNameStyle;
  const fillColor = kind === "self" ? 0x4cb38a : kind === "npc" ? 0xe29c52 : 0xdc8a43;
  const outlineColor = kind === "self" ? 0xdff7e8 : kind === "npc" ? 0x432a10 : 0x2a1606;

  if (!catalog) {
    return {
      container: createFallbackCharacter(
        name,
        heading,
        fillColor,
        outlineColor,
        labelStyle,
        kind === "npc" ? "diamond" : kind === "self" ? "circle" : "square"
      ),
      bodySprite: null,
      bodyFrames: null,
      frameVelocity: 210
    };
  }

  const container = new Container();
  const body = catalog.bodies[bodyId];
  const bodyGrhId = bodyGrhForDirection(catalog, bodyId, direction);
  const bodyAnimation = bodyGrhId ? getGrhAnimation(catalog, bodyGrhId, true) : null;

  let bodySprite: Sprite | null = null;
  if (bodyAnimation?.textures.length) {
    bodySprite = new Sprite(bodyAnimation.textures[0]);
  } else if (bodyGrhId) {
    const bodyTexture = getGrhTexture(catalog, bodyGrhId, true);
    if (bodyTexture) {
      bodySprite = new Sprite(bodyTexture);
    }
  }

  if (bodySprite) {
    applyAoAnchor(bodySprite);
    bodySprite.x = 0;
    bodySprite.y = 0;
    container.addChild(bodySprite);
  }

  const headGrhId = headGrhForDirection(catalog, headId, direction);
  if (headGrhId) {
    const headTexture = getGrhTexture(catalog, headGrhId, true);
    if (headTexture) {
      const headSprite = new Sprite(headTexture);
      applyAoAnchor(headSprite);
      headSprite.x = body?.offHeadX ?? 0;
      headSprite.y = body?.offHeadY ?? 0;
      container.addChild(headSprite);
    }
  }

  if (container.children.length === 0) {
    return {
      container: createFallbackCharacter(
        name,
        heading,
        fillColor,
        outlineColor,
        labelStyle,
        kind === "npc" ? "diamond" : kind === "self" ? "circle" : "square"
      ),
      bodySprite: null,
      bodyFrames: null,
      frameVelocity: 210
    };
  }

  const label = new Text(displayName, labelStyle);
  label.anchor.set(0.5, 1);
  label.x = TILE_SIZE / 2;
  label.y = -8;
  container.addChild(label);

  return {
    container,
    bodySprite,
    bodyFrames: bodyAnimation?.textures ?? null,
    frameVelocity: bodyAnimation?.velocidad ?? 210
  };
}

function updateCharacterAnimation(entry: CharacterNode, now: number) {
  if (!entry.bodySprite || !entry.bodyFrames || entry.bodyFrames.length === 0) {
    return;
  }

  const moving =
    entry.motion.initialized &&
    entry.motion.durationMs > 0 &&
    now - entry.motion.startedAt < entry.motion.durationMs;

  if (moving) {
    const msPerFrame = entry.frameVelocity / entry.bodyFrames.length;
    if (now - entry.lastFrameAt >= msPerFrame) {
      entry.frameIndex = (entry.frameIndex + 1) % entry.bodyFrames.length;
      entry.lastFrameAt = now;
      entry.bodySprite.texture = entry.bodyFrames[entry.frameIndex];
    }
    return;
  }

  if (entry.frameIndex !== 0) {
    entry.frameIndex = 0;
    entry.lastFrameAt = now;
    entry.bodySprite.texture = entry.bodyFrames[0];
  }
}

export class WorldRenderer {
  private app: Application | null = null;
  private canvas: HTMLCanvasElement | null = null;
  private worldLayer: Container | null = null;
  private belowCharactersLayer: Container | null = null;
  private staticEntityLayer: Container | null = null;
  private dynamicObjectLayer: Container | null = null;
  private charactersLayer: Container | null = null;
  private overlayLayer: Container | null = null;
  private effectsLayer: Container | null = null;
  private chatLayer: Container | null = null;
  private hudText: Text | null = null;
  private mountNode: HTMLDivElement | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private renderedMap: WorldMapData | null = null;
  private renderedCatalog: AssetCatalog | null = null;
  private renderedGroundObjects: WorldState["groundObjects"] | null = null;
  private renderedShowTileDebug = false;
  private lastWorld: WorldState | null = null;
  private selfNode: CharacterNode | null = null;
  private otherNodes = new Map<number, CharacterNode>();
  private staticSceneCache = new Map<string, StaticSceneLayers>();
  private adjacentSceneWarmupTimer: number | null = null;
  private transferInProgress = false;
  private runtimeTick: ((now: number) => void) | null = null;
  private tileInteractionHandler: ((payload: TileInteractionPayload) => void) | null = null;
  private renderLoopActive = false;
  /**
   * Imperative fast path: immediately start a motion animation for the self
   * character without waiting for React to commit state and trigger render().
   * Called directly from SessionClient on predicted walks and blocked turns.
   */
  pushSelfMovement(x: number, y: number, walkIntervalMs: number, speed: number) {
    if (!this.selfNode) {
      return;
    }

    const durationMs = walkIntervalForSpeed(walkIntervalMs, speed);
    animateMotionToTile(this.selfNode.motion, x, y, durationMs);
    this.selfNode.desiredX = x;
    this.selfNode.desiredY = y;

    const now = performance.now();
    const position = sampleMotion(this.selfNode.motion, now);
    this.selfNode.motion.renderX = position.x;
    this.selfNode.motion.renderY = position.y;
    this.selfNode.container.x = position.x;
    this.selfNode.container.y = position.y;
    this.ensureRenderLoop();
  }

  /**
   * Imperative fast path: snap self character position without animation.
   * Used for server corrections where the step wasn't in the pending queue.
   */
  snapSelfPosition(x: number, y: number) {
    if (!this.selfNode) {
      return;
    }

    snapMotionToTile(this.selfNode.motion, x, y);
    this.selfNode.desiredX = x;
    this.selfNode.desiredY = y;
    this.selfNode.container.x = this.selfNode.motion.renderX;
    this.selfNode.container.y = this.selfNode.motion.renderY;
    this.ensureRenderLoop();
  }

  setSelfHeading(heading: number) {
    if (!this.selfNode || this.selfNode.heading === heading) {
      return;
    }

    this.selfNode = this.rebuildCharacterVisual(this.selfNode, heading);
    this.ensureRenderLoop();
  }

  beginMapTransfer() {
    this.transferInProgress = true;
    this.ensureRenderLoop();
  }

  finishMapTransfer() {
    this.transferInProgress = false;
    this.ensureRenderLoop();
  }

  setRuntimeTick(runtimeTick: ((now: number) => void) | null) {
    this.runtimeTick = runtimeTick;
  }

  setTileInteractionHandler(
    tileInteractionHandler: ((payload: TileInteractionPayload) => void) | null
  ) {
    this.tileInteractionHandler = tileInteractionHandler;
  }

  private readonly tick = () => {
    if (!this.app) {
      this.renderLoopActive = false;
      return;
    }

    if (!this.lastWorld) {
      this.stopRenderLoop();
      return;
    }

    const now = performance.now();
    this.runtimeTick?.(now);
    const motionsAnimating = this.updateCharacterMotions(now);
    this.updateCamera(this.lastWorld);
    this.updateHud(this.lastWorld);

    const needsContinuousRender = motionsAnimating || this.transferInProgress;
    if (!needsContinuousRender) {
      this.stopRenderLoop();
    }
  };

  mount(node: HTMLDivElement) {
    this.mountNode = node;
    this.app = new Application({
      width: VIEWPORT_WIDTH,
      height: VIEWPORT_HEIGHT,
      antialias: false,
      backgroundColor: 0x090705,
      resolution: window.devicePixelRatio || 1,
      autoDensity: true
    });

    this.canvas = this.app.view as HTMLCanvasElement;
    node.replaceChildren(this.canvas);
    this.fitCanvas();
    this.resizeObserver = new ResizeObserver(() => {
      this.fitCanvas();
    });
    this.resizeObserver.observe(node);

    this.worldLayer = new Container();
    this.belowCharactersLayer = new Container();
    this.staticEntityLayer = new Container();
    this.dynamicObjectLayer = new Container();
    this.charactersLayer = new Container();
    this.overlayLayer = new Container();
    this.effectsLayer = new Container();
    this.chatLayer = new Container();

    this.worldLayer.addChild(this.belowCharactersLayer);
    this.worldLayer.addChild(this.staticEntityLayer);
    this.worldLayer.addChild(this.dynamicObjectLayer);
    this.worldLayer.addChild(this.charactersLayer);
    this.worldLayer.addChild(this.overlayLayer);
    this.worldLayer.addChild(this.effectsLayer);
    this.worldLayer.addChild(this.chatLayer);

    this.app.stage.addChild(this.worldLayer);

    this.hudText = new Text("", hudStyle);
    this.hudText.x = 12;
    this.hudText.y = 12;
    this.hudText.visible = false;
    this.app.stage.addChild(this.hudText);

    this.canvas.addEventListener("click", this.handleCanvasClick);
    this.app.ticker.add(this.tick);
    this.app.stop();
    this.renderLoopActive = false;
  }

  private ensureRenderLoop() {
    if (!this.app || this.renderLoopActive) {
      return;
    }

    this.renderLoopActive = true;
    this.app.start();
  }

  private stopRenderLoop() {
    if (!this.app || !this.renderLoopActive) {
      return;
    }

    this.app.stop();
    this.renderLoopActive = false;
  }

  private fitCanvas() {
    if (!this.mountNode || !this.canvas) {
      return;
    }

    const availableWidth = this.mountNode.clientWidth;
    const availableHeight = this.mountNode.clientHeight;
    if (availableWidth <= 0 || availableHeight <= 0) {
      return;
    }

    const scale = Math.min(availableWidth / VIEWPORT_WIDTH, availableHeight / VIEWPORT_HEIGHT);
    this.canvas.style.width = `${Math.floor(VIEWPORT_WIDTH * scale)}px`;
    this.canvas.style.height = `${Math.floor(VIEWPORT_HEIGHT * scale)}px`;
  }

  private readonly handleCanvasClick = (event: MouseEvent) => {
    if (!this.canvas || !this.worldLayer || !this.tileInteractionHandler) {
      return;
    }

    const rect = this.canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) {
      return;
    }

    const canvasX = ((event.clientX - rect.left) / rect.width) * VIEWPORT_WIDTH;
    const canvasY = ((event.clientY - rect.top) / rect.height) * VIEWPORT_HEIGHT;
    const tileX = Math.floor((canvasX - this.worldLayer.x) / TILE_SIZE) + 1;
    const tileY = Math.floor((canvasY - this.worldLayer.y) / TILE_SIZE) + 1;

    const mapWidth = this.lastWorld?.map?.width ?? DEFAULT_MAP_SIZE;
    const mapHeight = this.lastWorld?.map?.height ?? DEFAULT_MAP_SIZE;
    if (tileX < 1 || tileY < 1 || tileX > mapWidth || tileY > mapHeight) {
      return;
    }

    this.tileInteractionHandler({
      x: tileX,
      y: tileY,
      detail: event.detail
    });
  };

  render(world: WorldState, assetCatalog: AssetCatalog | null = null, showTileDebug = false) {
    if (
      !this.worldLayer ||
      !this.belowCharactersLayer ||
      !this.staticEntityLayer ||
      !this.dynamicObjectLayer ||
      !this.charactersLayer ||
      !this.overlayLayer ||
      !this.effectsLayer ||
      !this.chatLayer ||
      !this.hudText
    ) {
      return;
    }

    this.lastWorld = world;
    const sceneMap =
      world.map ??
      (world.mapStatus === "loading" || world.mapStatus === "transferring" ? this.renderedMap : null);
    const assetCatalogChanged = assetCatalog !== this.renderedCatalog;
    if (assetCatalogChanged) {
      this.clearStaticSceneCache();
    }

    const staticSceneChanged =
      sceneMap !== this.renderedMap ||
      assetCatalogChanged ||
      showTileDebug !== this.renderedShowTileDebug;

    if (staticSceneChanged) {
      this.renderedMap = sceneMap;
      this.renderedCatalog = assetCatalog;
      this.renderedShowTileDebug = showTileDebug;
      this.renderedGroundObjects = null;
      this.swapStaticScene(sceneMap, assetCatalog, showTileDebug);
      this.scheduleAdjacentSceneWarmup(sceneMap, assetCatalog, showTileDebug);
    }

    if (world.groundObjects !== this.renderedGroundObjects || staticSceneChanged) {
      this.renderedGroundObjects = world.groundObjects;
      this.rebuildGroundObjects(world, assetCatalog);
    }

    this.syncCharacters(world, assetCatalog);
    this.rebuildChatBubbles(world.chatBubbles);
    this.rebuildEffects(world);
    this.ensureRenderLoop();
  }

  private staticSceneCacheKey(map: WorldMapData | null, showTileDebug: boolean) {
    return `${map?.mapId ?? 0}:${showTileDebug ? 1 : 0}`;
  }

  private clearStaticSceneCache() {
    if (this.adjacentSceneWarmupTimer != null) {
      window.clearTimeout(this.adjacentSceneWarmupTimer);
      this.adjacentSceneWarmupTimer = null;
    }

    for (const scene of this.staticSceneCache.values()) {
      scene.belowCharacters.destroy({ children: true });
      scene.staticEntities.destroy({ children: true });
      scene.overlay.destroy({ children: true });
    }

    this.staticSceneCache.clear();
  }

  private scheduleAdjacentSceneWarmup(
    map: WorldMapData | null,
    assetCatalog: AssetCatalog | null,
    showTileDebug: boolean
  ) {
    if (!map || !assetCatalog) {
      return;
    }

    if (this.adjacentSceneWarmupTimer != null) {
      window.clearTimeout(this.adjacentSceneWarmupTimer);
    }

    this.adjacentSceneWarmupTimer = window.setTimeout(() => {
      this.adjacentSceneWarmupTimer = null;

      const destinationMapIds = Array.from(
        new Set(
          map.exits
            .map((exit) => exit.destMap)
            .filter((destMap) => destMap > 0 && destMap !== map.mapId)
        )
      ).slice(0, 6);

      for (const destMapId of destinationMapIds) {
        const record = getMapPackRecord(destMapId);
        if (!record) {
          continue;
        }

        const cacheKey = this.staticSceneCacheKey(record.map, showTileDebug);
        if (!this.staticSceneCache.has(cacheKey)) {
          this.staticSceneCache.set(
            cacheKey,
            this.buildStaticScene(record.map, assetCatalog, showTileDebug)
          );
        }
      }
    }, 40);
  }

  private swapStaticScene(
    map: WorldMapData | null,
    assetCatalog: AssetCatalog | null,
    showTileDebug: boolean
  ) {
    if (
      !this.worldLayer ||
      !this.belowCharactersLayer ||
      !this.staticEntityLayer ||
      !this.overlayLayer
    ) {
      return;
    }

    const cacheKey = this.staticSceneCacheKey(map, showTileDebug);
    let nextScene = this.staticSceneCache.get(cacheKey);

    if (!nextScene) {
      nextScene = this.buildStaticScene(map, assetCatalog, showTileDebug);
      this.staticSceneCache.set(cacheKey, nextScene);
    }

    if (
      this.belowCharactersLayer === nextScene.belowCharacters &&
      this.staticEntityLayer === nextScene.staticEntities &&
      this.overlayLayer === nextScene.overlay
    ) {
      return;
    }

    this.worldLayer.removeChild(this.belowCharactersLayer);
    this.worldLayer.removeChild(this.staticEntityLayer);
    this.worldLayer.removeChild(this.overlayLayer);
    this.belowCharactersLayer = nextScene.belowCharacters;
    this.staticEntityLayer = nextScene.staticEntities;
    this.overlayLayer = nextScene.overlay;
    this.worldLayer.addChildAt(this.belowCharactersLayer, 0);
    this.worldLayer.addChildAt(this.staticEntityLayer, 1);
    this.worldLayer.addChildAt(this.overlayLayer, 4);
  }

  private buildStaticScene(
    map: WorldMapData | null,
    assetCatalog: AssetCatalog | null,
    showTileDebug: boolean
  ): StaticSceneLayers {
    const nextBelowCharactersLayer = new Container();
    const nextStaticEntityLayer = new Container();
    const nextOverlayLayer = new Container();

    const mapWidth = map?.width ?? DEFAULT_MAP_SIZE;
    const mapHeight = map?.height ?? DEFAULT_MAP_SIZE;

    const background = new Graphics();
    background.beginFill(0x120f0b);
    background.drawRect(0, 0, mapWidth * TILE_SIZE, mapHeight * TILE_SIZE);
    background.endFill();
    nextBelowCharactersLayer.addChild(background);

    if (!map) {
      return {
        belowCharacters: nextBelowCharactersLayer,
        staticEntities: nextStaticEntityLayer,
        overlay: nextOverlayLayer
      };
    }

    if (assetCatalog) {
      for (const tile of map.layers[0] ?? []) {
        const sprite = createLayerSprite(assetCatalog, tile.grhIndex, tile.x, tile.y);
        if (sprite) {
          nextBelowCharactersLayer.addChild(sprite);
        }
      }

      for (const tile of map.layers[1] ?? []) {
        const sprite = createLayerSprite(assetCatalog, tile.grhIndex, tile.x, tile.y);
        if (sprite) {
          nextBelowCharactersLayer.addChild(sprite);
        }
      }

      for (const tile of map.layers[2] ?? []) {
        const sprite = createLayerSprite(assetCatalog, tile.grhIndex, tile.x, tile.y);
        if (sprite) {
          nextOverlayLayer.addChild(sprite);
        }
      }

      for (const tile of map.layers[3] ?? []) {
        const sprite = createLayerSprite(assetCatalog, tile.grhIndex, tile.x, tile.y);
        if (sprite) {
          nextOverlayLayer.addChild(sprite);
        }
      }
    }

    if (showTileDebug) {
      const blocked = new Graphics();
      blocked.beginFill(0xff0000, 0.15);
      for (let y = 1; y <= map.height; y += 1) {
        for (let x = 1; x <= map.width; x += 1) {
          const tileValue = map.tiles[(y - 1) * map.width + (x - 1)] ?? 0;
          if (tileValue !== 0) {
            blocked.drawRect(worldX(x), worldY(y), TILE_SIZE, TILE_SIZE);
          }
        }
      }
      blocked.endFill();
      nextOverlayLayer.addChild(blocked);

      const exitOverlay = new Graphics();
      exitOverlay.beginFill(0xa06af0, 0.5);
      for (const exit of map.exits) {
        exitOverlay.drawRect(
          worldX(exit.x) + 4,
          worldY(exit.y) + 4,
          TILE_SIZE - 8,
          TILE_SIZE - 8
        );

        const label = new Text(`→${exit.destMap}`, exitStyle);
        label.anchor.set(0.5, 0);
        label.x = tileCenterX(exit.x);
        label.y = worldY(exit.y) + 2;
        nextOverlayLayer.addChild(label);
      }
      exitOverlay.endFill();
      nextOverlayLayer.addChild(exitOverlay);
    }

    return {
      belowCharacters: nextBelowCharactersLayer,
      staticEntities: nextStaticEntityLayer,
      overlay: nextOverlayLayer
    };
  }

  private rebuildGroundObjects(world: WorldState, assetCatalog: AssetCatalog | null) {
    if (!this.dynamicObjectLayer) {
      return;
    }

    this.dynamicObjectLayer.removeChildren();

    for (const object of Object.values(world.groundObjects)) {
      this.dynamicObjectLayer.addChild(createObjectNode(assetCatalog, object));
    }
  }

  private syncCharacters(world: WorldState, assetCatalog: AssetCatalog | null) {
    if (!this.charactersLayer) {
      return;
    }

    const now = performance.now();
    const shouldSnapAll = world.mapStatus !== "ready" || this.transferInProgress;

    if (world.self.x != null && world.self.y != null) {
      this.selfNode = this.syncCharacterNode(
        this.selfNode,
        "self",
        world.self.name || "You",
        world.self.bodyId,
        world.self.headId,
        world.self.heading,
        world.self.speed,
        world.self.x,
        world.self.y,
        world.walkIntervalMs,
        assetCatalog,
        now,
        shouldSnapAll
      );
    } else if (this.selfNode) {
      this.charactersLayer.removeChild(this.selfNode.container);
      this.selfNode = null;
    }

    const presentOthers = new Set<number>();
    for (const other of Object.values(world.others)) {
      presentOthers.add(other.charIndex);
      const current = this.otherNodes.get(other.charIndex) ?? null;
      const next = this.syncCharacterNode(
        current,
        other.isNpc ? "npc" : "other",
        other.name,
        other.bodyId,
        other.headId,
        other.heading,
        other.speed,
        other.x,
        other.y,
        world.walkIntervalMs,
        assetCatalog,
        now,
        shouldSnapAll
      );
      this.otherNodes.set(other.charIndex, next);
    }

    for (const [charIndex, node] of this.otherNodes.entries()) {
      if (!presentOthers.has(charIndex)) {
        this.charactersLayer.removeChild(node.container);
        this.otherNodes.delete(charIndex);
      }
    }
  }

  private syncCharacterNode(
    current: CharacterNode | null,
    kind: "self" | "other" | "npc",
    name: string,
    bodyId: number,
    headId: number,
    heading: number,
    speed: number,
    x: number,
    y: number,
    walkIntervalMs: number,
    assetCatalog: AssetCatalog | null,
    now: number,
    snapImmediately: boolean
  ): CharacterNode {
    if (!this.charactersLayer) {
      throw new Error("characters layer missing");
    }

    const needsRebuild =
      !current ||
      current.name !== name ||
      current.bodyId !== bodyId ||
      current.headId !== headId ||
      current.heading !== heading;

    let next: CharacterNode;

    if (needsRebuild) {
      const visual = createCharacterVisual(assetCatalog, name, bodyId, headId, heading, kind);
      const motion = current?.motion ?? createMotionState();

      next = {
        container: visual.container,
        bodySprite: visual.bodySprite,
        bodyFrames: visual.bodyFrames,
        frameVelocity: visual.frameVelocity,
        frameIndex: 0,
        lastFrameAt: now,
        motion,
        name,
        bodyId,
        headId,
        heading,
        speed,
        kind,
        desiredX: x,
        desiredY: y
      };

      if (current) {
        this.charactersLayer.removeChild(current.container);
      }

      this.charactersLayer.addChild(next.container);

      if (motion.initialized) {
        next.container.x = motion.renderX;
        next.container.y = motion.renderY;
      }
    } else {
      next = current;
    }

    const shouldSnapMotion =
      snapImmediately ||
      !next.motion.initialized ||
      Math.abs(x - next.desiredX) > 1 ||
      Math.abs(y - next.desiredY) > 1;

    if (shouldSnapMotion) {
      snapMotionToTile(next.motion, x, y);
    } else {
      animateMotionToTile(next.motion, x, y, walkIntervalForSpeed(walkIntervalMs, speed));
    }

    next.desiredX = x;
    next.desiredY = y;
    next.speed = speed;
    next.heading = heading;
    next.name = name;
    next.bodyId = bodyId;
    next.headId = headId;

    const position = sampleMotion(next.motion, now);
    next.motion.renderX = position.x;
    next.motion.renderY = position.y;
    next.container.x = position.x;
    next.container.y = position.y;

    return next;
  }

  private rebuildCharacterVisual(current: CharacterNode, heading: number) {
    if (!this.charactersLayer) {
      return current;
    }

    const visual = createCharacterVisual(
      this.renderedCatalog,
      current.name,
      current.bodyId,
      current.headId,
      heading,
      current.kind
    );
    const next: CharacterNode = {
      ...current,
      container: visual.container,
      bodySprite: visual.bodySprite,
      bodyFrames: visual.bodyFrames,
      frameVelocity: visual.frameVelocity,
      frameIndex: 0,
      lastFrameAt: performance.now(),
      heading
    };

    if (current.motion.initialized) {
      next.container.x = current.motion.renderX;
      next.container.y = current.motion.renderY;
    }

    const childIndex = this.charactersLayer.getChildIndex(current.container);
    this.charactersLayer.removeChild(current.container);
    this.charactersLayer.addChildAt(next.container, Math.min(childIndex, this.charactersLayer.children.length));
    return next;
  }

  private rebuildChatBubbles(chatBubbles: ChatBubble[]) {
    if (!this.chatLayer) {
      return;
    }

    this.chatLayer.removeChildren();
    const now = Date.now();

    for (const bubble of chatBubbles) {
      const age = now - bubble.createdAt;
      const alpha = clamp(1 - age / bubble.ttlMs, 0, 1);
      if (alpha <= 0) {
        continue;
      }

      const text = new Text(bubble.message, bubbleStyle);
      text.anchor.set(0.5, 1);
      text.x = tileCenterX(bubble.x);
      text.y = worldY(bubble.y) - 16;
      text.alpha = alpha;
      this.chatLayer.addChild(text);
    }
  }

  private rebuildEffects(world: WorldState) {
    if (!this.effectsLayer) {
      return;
    }

    this.effectsLayer.removeChildren();
    const now = Date.now();

    if (world.targetTile) {
      const highlight = new Graphics();
      highlight.lineStyle(2, 0xf3d27d, 0.92);
      highlight.beginFill(0xf3d27d, 0.08);
      highlight.drawRoundedRect(
        worldX(world.targetTile.x) + 2,
        worldY(world.targetTile.y) + 2,
        TILE_SIZE - 4,
        TILE_SIZE - 4,
        6
      );
      highlight.endFill();
      highlight.lineStyle(1, 0xf9e4b4, 0.8);
      highlight.moveTo(tileCenterX(world.targetTile.x), worldY(world.targetTile.y) + 4);
      highlight.lineTo(tileCenterX(world.targetTile.x), worldY(world.targetTile.y) + TILE_SIZE - 4);
      highlight.moveTo(worldX(world.targetTile.x) + 4, tileCenterY(world.targetTile.y));
      highlight.lineTo(worldX(world.targetTile.x) + TILE_SIZE - 4, tileCenterY(world.targetTile.y));
      this.effectsLayer.addChild(highlight);
    }

    for (const event of world.fxEvents) {
      const age = now - event.createdAt;
      const progress = clamp(age / event.ttlMs, 0, 1);
      const alpha = clamp(1 - progress, 0, 1);
      if (alpha <= 0) {
        continue;
      }

      const color = [0x85b6ff, 0xcf96ff, 0x8af3cb, 0xffc66b][event.fxId % 4] ?? 0x85b6ff;
      const pulse = new Graphics();
      pulse.lineStyle(2, color, alpha * 0.9);
      pulse.beginFill(color, alpha * 0.12);
      pulse.drawCircle(
        tileCenterX(event.x),
        tileCenterY(event.y) - 8,
        10 + progress * 18
      );
      pulse.endFill();
      this.effectsLayer.addChild(pulse);
    }

    for (const event of world.combatTexts) {
      const age = now - event.createdAt;
      const progress = clamp(age / event.ttlMs, 0, 1);
      const alpha = clamp(1 - progress, 0, 1);
      if (alpha <= 0) {
        continue;
      }

      const style =
        event.tone === "damage"
          ? damageTextStyle
          : event.tone === "block"
            ? blockTextStyle
            : event.tone === "status"
              ? statusTextStyle
              : infoTextStyle;
      const label = new Text(event.text, style);
      label.anchor.set(0.5, 1);
      label.alpha = alpha;
      label.x = tileCenterX(event.x);
      label.y = worldY(event.y) - 14 - progress * 22;
      this.effectsLayer.addChild(label);
    }
  }

  private updateCharacterMotions(now: number) {
    const entries = [
      ...(this.selfNode ? [this.selfNode] : []),
      ...this.otherNodes.values()
    ];

    let anyAnimating = false;

    for (const entry of entries) {
      const position = sampleMotion(entry.motion, now);
      entry.motion.renderX = position.x;
      entry.motion.renderY = position.y;
      entry.container.x = position.x;
      entry.container.y = position.y;
      updateCharacterAnimation(entry, now);

      const motionActive =
        entry.motion.initialized &&
        entry.motion.durationMs > 0 &&
        now - entry.motion.startedAt < entry.motion.durationMs;

      if (motionActive) {
        anyAnimating = true;
      }
    }

    return anyAnimating;
  }

  private updateCamera(world: WorldState) {
    if (!this.worldLayer) {
      return;
    }

    const playerPosition =
      this.selfNode?.motion.initialized
        ? { x: this.selfNode.motion.renderX, y: this.selfNode.motion.renderY }
        : {
            x: worldX(world.self.x ?? 50),
            y: worldY(world.self.y ?? 50)
          };

    const centerX = Math.round(VIEWPORT_WIDTH / 2 - playerPosition.x - TILE_SIZE / 2);
    const centerY = Math.round(VIEWPORT_HEIGHT / 2 - playerPosition.y - TILE_SIZE / 2);

    this.worldLayer.x = centerX;
    this.worldLayer.y = centerY;
  }

  private updateHud(world: WorldState) {
    if (!this.hudText) {
      return;
    }

    const mapName = world.map?.name ?? "--";
    const playerX = world.self.x ?? "--";
    const playerY = world.self.y ?? "--";

    this.hudText.text =
      `Map ${world.mapId ?? "--"} · ${mapName}\n` +
      `Map state ${world.mapStatus}${world.mapError ? ` · ${world.mapError}` : ""}\n` +
      `Pos ${playerX},${playerY} · CharIdx ${world.self.charIndex ?? "--"}\n` +
      `Others ${Object.keys(world.others).length} · Ground ${Object.keys(world.groundObjects).length}`;
  }

  destroy() {
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;

    if (this.app) {
      this.canvas?.removeEventListener("click", this.handleCanvasClick);
      this.app.ticker.remove(this.tick);
      this.stopRenderLoop();
      this.app.destroy(true, {
        children: true,
        texture: false,
        baseTexture: false
      });
      this.app = null;
      this.canvas = null;
    }

    if (this.mountNode) {
      this.mountNode.replaceChildren();
      this.mountNode = null;
    }

    this.renderedMap = null;
    this.renderedCatalog = null;
    this.renderedGroundObjects = null;
    this.lastWorld = null;
    this.selfNode = null;
    this.otherNodes.clear();
    this.effectsLayer = null;
    this.tileInteractionHandler = null;
    this.transferInProgress = false;
    this.clearStaticSceneCache();
  }
}
