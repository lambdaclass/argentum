import { BaseTexture, MIPMAP_MODES, Rectangle, SCALE_MODES, Texture } from "pixi.js";
import { buildAssetOriginCandidates, buildAssetUrlFromOrigin, fetchJsonWithFallback } from "../net/assetHost";
import type { GroundObject, WorldMapData } from "../app/types";

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

const catalogCache = new Map<string, Promise<AssetCatalog>>();
const baseTextureCache = new Map<string, BaseTexture>();
const textureCache = new Map<string, Texture>();
const imagePreloadCache = new Map<string, Promise<void>>();

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

  const texture = new Texture(
    baseTexture,
    new Rectangle(entry.offX, entry.offY, entry.width, entry.height)
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

export function getObjectFrameDef(catalog: AssetCatalog | null, objectId: number) {
  const grhId = getObjectGrh(catalog, objectId);
  if (!catalog || !grhId) {
    return null;
  }

  return getGrhFrameDef(catalog, grhId);
}

function preloadImage(url: string) {
  const existing = imagePreloadCache.get(url);
  if (existing) {
    return existing;
  }

  const promise = new Promise<void>((resolve) => {
    const image = new Image();

    const finish = () => {
      image.onload = null;
      image.onerror = null;
      resolve();
    };

    image.onload = finish;
    image.onerror = finish;
    image.decoding = "async";
    image.src = url;

    if (image.complete) {
      finish();
    }
  });

  imagePreloadCache.set(url, promise);
  return promise;
}

export function collectSceneAssetUrls(
  catalog: AssetCatalog,
  map: WorldMapData,
  characters: SceneCharacterAssetDescriptor[] = [],
  groundObjects: GroundObject[] = []
) {
  const urls = new Set<string>();

  const addFrameUrl = (grhId: number | null | undefined, useCharIndex = false) => {
    if (!grhId) {
      return;
    }

    const frame = getGrhFrameDef(catalog, grhId, useCharIndex);
    if (frame) {
      urls.add(frame.url);
    }
  };

  for (const layer of map.layers) {
    for (const tile of layer ?? []) {
      addFrameUrl(tile.grhIndex, false);
    }
  }

  for (const object of groundObjects) {
    addFrameUrl(getObjectGrh(catalog, object.id), false);
  }

  for (const character of characters) {
    const direction = headingToDirection(character.heading);
    addFrameUrl(bodyGrhForDirection(catalog, character.bodyId, direction), true);
    addFrameUrl(headGrhForDirection(catalog, character.headId, direction), true);
    addFrameUrl(character.weaponId, true);
    addFrameUrl(character.shieldId, true);
    addFrameUrl(character.helmetId, true);
    addFrameUrl(character.cartId, true);
    addFrameUrl(character.backpackId, true);
    addFrameUrl(character.effectId, true);
  }

  return [...urls];
}

export async function preloadSceneAssets(urls: Iterable<string>) {
  await Promise.all([...new Set(urls)].map((url) => preloadImage(url)));
}

export function getUncachedSceneAssetUrls(urls: Iterable<string>) {
  return [...new Set(urls)].filter((url) => !imagePreloadCache.has(url));
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
