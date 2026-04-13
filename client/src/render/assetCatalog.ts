import { BaseTexture, MIPMAP_MODES, Rectangle, SCALE_MODES, Texture } from "pixi.js";
import { buildAssetOriginCandidates, buildAssetUrlFromOrigin, fetchJsonWithFallback } from "../net/assetHost";
import type { GroundObject, WorldMapData } from "../app/types";
import { getRawNpcBodyDef, getRawNpcBodySheetUrl } from "./npcRawBodies.generated";
import { fitFrameWithinTexture, resolveBaseTextureSize } from "./textureFrames";

interface DirectionalFrames {
  up: number;
  right: number;
  down: number;
  left: number;
}

export interface BodyDef extends DirectionalFrames {
  id: number;
  offHeadX: number;
  offHeadY: number;
}

export interface HeadDef extends DirectionalFrames {
  id: number;
}

export interface ObjectDef {
  name: string;
  grh: number;
}

export interface NpcDef {
  name: string;
  body: number;
  head: number;
  heading: number;
}

export interface GrhDef {
  id: number;
  grafico: string | number;
  offX: number;
  offY: number;
  width: number;
  height: number;
  css?: number;
  velocidad?: number;
  frames?: number[];
}

export interface AssetCatalog {
  endpoint: string;
  assetOrigin: string;
  bodies: Array<BodyDef | null>;
  heads: Array<HeadDef | null>;
  objects: Array<ObjectDef | null>;
  npcs: Array<NpcDef | null>;
  grhMap: Array<GrhDef | null>;
  grhChar: Array<GrhDef | null>;
}

export interface GrhAnimation {
  textures: Texture[];
  velocidad: number;
}

export interface GrhFrameDef {
  url: string;
  offX: number;
  offY: number;
  width: number;
  height: number;
}

const GHOST_BODY_ID = 829;
const GHOST_BODY_DEF = {
  north: 51672,
  east: 51673,
  south: 51671,
  west: 51674
} as const;

const catalogCache = new Map<string, Promise<AssetCatalog>>();
const baseTextureCache = new Map<string, BaseTexture>();
const textureCache = new Map<string, Texture>();
const scenePreloadCache = new Map<string, Promise<void>>();

const sceneBaseTextureOptions = {
  scaleMode: SCALE_MODES.NEAREST,
  mipmap: MIPMAP_MODES.OFF,
  resourceOptions: {
    autoLoad: false
  }
} as const;

export function loadAssetCatalog(endpoint: string) {
  if (!catalogCache.has(endpoint)) {
    const promise = Promise.all([
      fetchJsonWithFallback<Array<BodyDef | null>>(endpoint, "/indices/cuerpos.json"),
      fetchJsonWithFallback<Array<HeadDef | null>>(endpoint, "/indices/cabezas.json"),
      fetchJsonWithFallback<Array<ObjectDef | null>>(endpoint, "/indices/objs.json"),
      fetchJsonWithFallback<Array<NpcDef | null>>(endpoint, "/indices/npcs.json"),
      fetchJsonWithFallback<Array<GrhDef | null>>(endpoint, "/indices/graficos_full.json"),
      fetchJsonWithFallback<Array<GrhDef | null>>(endpoint, "/indices/graficos.json")
    ])
      .then(([bodies, heads, objects, npcs, grhMap, grhChar]) => {
        const originCandidates = buildAssetOriginCandidates(endpoint);
        const endpointOrigin = originCandidates[originCandidates.length - 1] ?? bodies.origin;
        const resolvedOrigins = [
          bodies.origin,
          heads.origin,
          objects.origin,
          npcs.origin,
          grhMap.origin,
          grhChar.origin
        ];
        const assetOrigin = resolvedOrigins.includes(endpointOrigin)
          ? endpointOrigin
          : grhMap.origin;

        return {
          endpoint,
          assetOrigin,
          bodies: bodies.data,
          heads: heads.data,
          objects: objects.data,
          npcs: npcs.data,
          grhMap: grhMap.data,
          grhChar: grhChar.data
        };
      })
      .catch((error) => {
        catalogCache.delete(endpoint);
        throw error;
      });

    catalogCache.set(endpoint, promise);
  }

  return catalogCache.get(endpoint)!;
}

function getDirectionalGrh(direction: "north" | "east" | "south" | "west", entry: DirectionalFrames) {
  switch (direction) {
    case "north":
      return entry.up;
    case "east":
      return entry.right;
    case "west":
      return entry.left;
    case "south":
      return entry.down;
  }
}

function headingToDirection(heading: number): "north" | "east" | "south" | "west" {
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

function sheetUrl(assetOrigin: string, sheet: string | number, useCharIndex: boolean) {
  const basePath = useCharIndex ? "/graficos_char" : "/graficos";
  return buildAssetUrlFromOrigin(assetOrigin, `${basePath}/${sheet}.png`);
}

export function getGrhFrameDef(
  catalog: AssetCatalog,
  grhId: number,
  useCharIndex = false
): GrhFrameDef | null {
  const index = useCharIndex ? catalog.grhChar : catalog.grhMap;
  let entry = index[grhId];
  if (!entry) {
    return null;
  }

  if (entry.frames && entry.frames.length > 0) {
    const firstFrame = entry.frames[0];
    entry = index[firstFrame];
    if (!entry) {
      return null;
    }
  }

  return {
    url: sheetUrl(catalog.assetOrigin, entry.grafico, useCharIndex),
    offX: entry.offX,
    offY: entry.offY,
    width: entry.width,
    height: entry.height
  };
}

function getGrhUrls(catalog: AssetCatalog, grhId: number, useCharIndex = false) {
  const index = useCharIndex ? catalog.grhChar : catalog.grhMap;
  const entry = index[grhId];
  if (!entry) {
    return [];
  }

  if (entry.frames && entry.frames.length > 0) {
    const urls = new Set<string>();
    for (const frameId of entry.frames) {
      const frame = index[frameId];
      if (frame) {
        urls.add(sheetUrl(catalog.assetOrigin, frame.grafico, useCharIndex));
      }
    }
    return [...urls];
  }

  return [sheetUrl(catalog.assetOrigin, entry.grafico, useCharIndex)];
}

export function getGrhTexture(
  catalog: AssetCatalog,
  grhId: number,
  useCharIndex = false
): Texture | null {
  const cacheKey = `${catalog.assetOrigin}:${useCharIndex ? "char" : "map"}:${grhId}`;
  const cached = textureCache.get(cacheKey);
  if (cached) {
    return cached;
  }

  const index = useCharIndex ? catalog.grhChar : catalog.grhMap;
  let entry = index[grhId];
  if (!entry) {
    return null;
  }

  if (entry.frames && entry.frames.length > 0) {
    const firstFrame = entry.frames[0];
    entry = index[firstFrame];
    if (!entry) {
      return null;
    }
  }

  const textureKey = `${catalog.assetOrigin}:${useCharIndex ? "char" : "map"}:${entry.grafico}`;
  let baseTexture = baseTextureCache.get(textureKey);
  if (!baseTexture) {
    baseTexture = BaseTexture.from(sheetUrl(catalog.assetOrigin, entry.grafico, useCharIndex), {
      scaleMode: SCALE_MODES.NEAREST,
      mipmap: MIPMAP_MODES.OFF
    });
    baseTextureCache.set(textureKey, baseTexture);
  }

  const frame = fitFrameWithinTexture(
    {
      x: entry.offX,
      y: entry.offY,
      width: entry.width,
      height: entry.height
    },
    resolveBaseTextureSize(baseTexture)
  );
  if (!frame) {
    return null;
  }

  const texture = new Texture(
    baseTexture,
    new Rectangle(frame.x, frame.y, frame.width, frame.height)
  );

  textureCache.set(cacheKey, texture);
  return texture;
}

export function getGrhAnimation(
  catalog: AssetCatalog,
  grhId: number,
  useCharIndex = false
): GrhAnimation | null {
  const index = useCharIndex ? catalog.grhChar : catalog.grhMap;
  const entry = index[grhId];

  if (!entry || !entry.frames || entry.frames.length === 0) {
    return null;
  }

  const textures = entry.frames
    .map((frameId) => getGrhTexture(catalog, frameId, useCharIndex))
    .filter((texture): texture is Texture => texture != null);

  if (textures.length === 0) {
    return null;
  }

  return {
    textures,
    velocidad: entry.velocidad ?? 333
  };
}

export function bodyGrhForDirection(catalog: AssetCatalog, bodyId: number, direction: "north" | "east" | "south" | "west") {
  const body = catalog.bodies[bodyId];
  if (!body) {
    return null;
  }

  return getDirectionalGrh(direction, body);
}

export function headGrhForDirection(catalog: AssetCatalog, headId: number, direction: "north" | "east" | "south" | "west") {
  const head = catalog.heads[headId];
  if (!head) {
    return null;
  }

  return getDirectionalGrh(direction, head);
}

export function getObjectName(catalog: AssetCatalog | null, objectId: number) {
  return catalog?.objects[objectId]?.name ?? `#${objectId}`;
}

export function getObjectGrh(catalog: AssetCatalog | null, objectId: number) {
  return catalog?.objects[objectId]?.grh ?? null;
}

export interface SceneCharacterAssetDescriptor {
  x?: number;
  y?: number;
  bodyId: number;
  headId: number;
  weaponId: number;
  shieldId: number;
  helmetId: number;
  cartId: number;
  backpackId: number;
  effectId: number;
  heading: number;
}

export interface SceneAssetBounds {
  minX: number;
  maxX: number;
  minY: number;
  maxY: number;
}

export function getObjectFrameDef(catalog: AssetCatalog | null, objectId: number) {
  const grhId = getObjectGrh(catalog, objectId);
  if (!catalog || !grhId) {
    return null;
  }

  return getGrhFrameDef(catalog, grhId);
}

function evictFailedSceneTexture(url: string, baseTexture: BaseTexture) {
  scenePreloadCache.delete(url);
  Texture.removeFromCache(url);
  BaseTexture.removeFromCache(url);
  if (!baseTexture.destroyed) {
    baseTexture.destroy();
  }
}

function preloadSceneTexture(url: string) {
  const existing = scenePreloadCache.get(url);
  if (existing) {
    return existing;
  }

  const promise = (async () => {
    const baseTexture = BaseTexture.from(url, sceneBaseTextureOptions, false);
    if (baseTexture.valid) {
      return;
    }

    const { resource } = baseTexture;
    if (!resource) {
      evictFailedSceneTexture(url, baseTexture);
      throw new Error(`Failed to preload scene asset ${url}`);
    }

    try {
      await resource.load();
    } catch {
      evictFailedSceneTexture(url, baseTexture);
      throw new Error(`Failed to preload scene asset ${url}`);
    }

    if (!baseTexture.valid) {
      evictFailedSceneTexture(url, baseTexture);
      throw new Error(`Failed to preload scene asset ${url}`);
    }
  })().catch((error) => {
    scenePreloadCache.delete(url);
    throw error;
  });

  scenePreloadCache.set(url, promise);
  return promise;
}

export function collectSceneAssetUrls(
  catalog: AssetCatalog,
  map: WorldMapData,
  characters: SceneCharacterAssetDescriptor[] = [],
  groundObjects: GroundObject[] = [],
  bounds?: SceneAssetBounds
) {
  const urls = new Set<string>();
  const isInBounds = (x: number, y: number) =>
    !bounds || (x >= bounds.minX && x <= bounds.maxX && y >= bounds.minY && y <= bounds.maxY);

  const addGrhUrls = (grhId: number | null | undefined, useCharIndex = false) => {
    if (!grhId) {
      return;
    }

    for (const url of getGrhUrls(catalog, grhId, useCharIndex)) {
      urls.add(url);
    }
  };

  for (const layer of map.layers) {
    for (const tile of layer ?? []) {
      if (!isInBounds(tile.x, tile.y)) {
        continue;
      }

      addGrhUrls(tile.grhIndex, false);
    }
  }

  for (const object of groundObjects) {
    if (!isInBounds(object.x, object.y)) {
      continue;
    }

    addGrhUrls(getObjectGrh(catalog, object.id), false);
  }

  for (const character of characters) {
    if (character.x != null && character.y != null && !isInBounds(character.x, character.y)) {
      continue;
    }

    const direction = headingToDirection(character.heading);
    if (character.bodyId === GHOST_BODY_ID) {
      addGrhUrls(GHOST_BODY_DEF[direction], false);
    } else {
      const rawNpcBody =
        character.bodyId > 0 && !catalog.bodies[character.bodyId]
          ? getRawNpcBodyDef(character.bodyId)
          : null;

      if (rawNpcBody?.type === "molded") {
        const rawSheetUrl = getRawNpcBodySheetUrl(rawNpcBody.fileNum);
        if (rawSheetUrl) {
          urls.add(rawSheetUrl);
        }
      } else if (rawNpcBody?.type === "direct") {
        addGrhUrls(rawNpcBody[direction], true);
      } else {
        addGrhUrls(bodyGrhForDirection(catalog, character.bodyId, direction), true);
      }

      addGrhUrls(headGrhForDirection(catalog, character.headId, direction), true);
      addGrhUrls(character.weaponId, true);
      addGrhUrls(character.shieldId, true);
      addGrhUrls(character.helmetId, true);
      addGrhUrls(character.cartId, true);
      addGrhUrls(character.backpackId, true);
      addGrhUrls(character.effectId, true);
    }
  }

  return [...urls];
}

export async function preloadSceneAssets(urls: Iterable<string>) {
  const pending = [...new Set(urls)];
  const concurrency = Math.min(6, pending.length);
  let nextIndex = 0;

  async function loadOne(url: string) {
    let lastError: unknown = null;

    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        await preloadSceneTexture(url);
        return;
      } catch (error) {
        lastError = error;
        if (attempt < 2) {
          await new Promise((resolve) => globalThis.setTimeout(resolve, 60 * (attempt + 1)));
        }
      }
    }

    throw lastError;
  }

  async function worker() {
    while (nextIndex < pending.length) {
      const url = pending[nextIndex];
      nextIndex += 1;
      await loadOne(url);
    }
  }

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
}

export function getUncachedSceneAssetUrls(urls: Iterable<string>) {
  return [...new Set(urls)].filter((url) => !scenePreloadCache.has(url));
}

export function getObjectIconFrame(catalog: AssetCatalog | null, objectId: number) {
  if (!catalog) {
    return null;
  }

  const grhId = getObjectGrh(catalog, objectId);
  if (!grhId) {
    return null;
  }

  return getGrhFrameDef(catalog, grhId, false);
}

export function getNpcDef(catalog: AssetCatalog | null, npcId: number) {
  return npcId >= 0 ? catalog?.npcs[npcId] ?? null : null;
}
