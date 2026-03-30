import { BaseTexture, MIPMAP_MODES, Rectangle, SCALE_MODES, Texture } from "pixi.js";

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

function isLocalDevServer() {
  if (typeof window === "undefined") {
    return false;
  }

  return window.location.port === "5173" || window.location.port === "4173";
}

function buildAssetUrl(endpoint: string, path: string) {
  if (typeof window !== "undefined" && !isLocalDevServer()) {
    return new URL(path, window.location.origin).toString();
  }

  const url = new URL(endpoint);
  url.protocol = url.protocol === "wss:" ? "https:" : "http:";
  url.pathname = path;
  url.search = "";
  url.hash = "";
  return url.toString();
}

async function fetchJson<T>(endpoint: string, path: string) {
  const response = await fetch(buildAssetUrl(endpoint, path));

  if (!response.ok) {
    throw new Error(`Failed to load ${path} (${response.status})`);
  }

  return (await response.json()) as T;
}

export function loadAssetCatalog(endpoint: string) {
  if (!catalogCache.has(endpoint)) {
    const promise = Promise.all([
      fetchJson<Array<BodyDef | null>>(endpoint, "/indices/cuerpos.json"),
      fetchJson<Array<HeadDef | null>>(endpoint, "/indices/cabezas.json"),
      fetchJson<Array<ObjectDef | null>>(endpoint, "/indices/objs.json"),
      fetchJson<Array<NpcDef | null>>(endpoint, "/indices/npcs.json"),
      fetchJson<Array<GrhDef | null>>(endpoint, "/indices/graficos_full.json"),
      fetchJson<Array<GrhDef | null>>(endpoint, "/indices/graficos.json")
    ]).then(([bodies, heads, objects, npcs, grhMap, grhChar]) => ({
      endpoint,
      bodies,
      heads,
      objects,
      npcs,
      grhMap,
      grhChar
    })).catch((error) => {
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

function sheetUrl(endpoint: string, sheet: string | number, useCharIndex: boolean) {
  const basePath = useCharIndex ? "/graficos_char" : "/graficos";
  return buildAssetUrl(endpoint, `${basePath}/${sheet}.png`);
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
    url: sheetUrl(catalog.endpoint, entry.grafico, useCharIndex),
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
  const cacheKey = `${catalog.endpoint}:${useCharIndex ? "char" : "map"}:${grhId}`;
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

  const textureKey = `${catalog.endpoint}:${useCharIndex ? "char" : "map"}:${entry.grafico}`;
  let baseTexture = baseTextureCache.get(textureKey);
  if (!baseTexture) {
    baseTexture = BaseTexture.from(sheetUrl(catalog.endpoint, entry.grafico, useCharIndex), {
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
