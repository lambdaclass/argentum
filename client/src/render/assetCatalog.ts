import { BaseTexture, MIPMAP_MODES, Rectangle, SCALE_MODES, Texture } from "pixi.js";
import { buildAssetOriginCandidates, buildAssetUrlFromOrigin, fetchJsonWithFallback } from "../net/assetHost";

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

export function getObjectFrameDef(catalog: AssetCatalog | null, objectId: number) {
  const grhId = getObjectGrh(catalog, objectId);
  if (!catalog || !grhId) {
    return null;
  }

  return getGrhFrameDef(catalog, grhId);
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
