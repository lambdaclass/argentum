import { BinaryReader } from "../protocol/BinaryReader";
import type {
  GroundObject,
  MapExit,
  MapLayerTile,
  MapNpc,
  WorldMapData
} from "../app/types";

const MAP_PACK_MAGIC = "AOMP";
const MAP_PACK_VERSION = 1;

interface PackedMapRecord {
  map: WorldMapData;
  groundObjects: Record<string, GroundObject>;
}

export interface MapPackProgress {
  phase: "download" | "decode" | "ready";
  loadedBytes: number;
  totalBytes: number | null;
}

interface MapPackManifest {
  filename: string;
  hash: string;
  bytes: number;
  maps: number;
  version: number;
}

let mapPackPromise: Promise<Map<number, PackedMapRecord>> | null = null;
let decodedMapCache: Map<number, PackedMapRecord> | null = null;

function normalizeLayerTile(x: number, y: number, grhIndex: number): MapLayerTile {
  return { x, y, grhIndex };
}

function normalizeNpc(x: number, y: number, id: number): MapNpc {
  return { x, y, id };
}

function normalizeExit(
  x: number,
  y: number,
  destMap: number,
  destX: number,
  destY: number
): MapExit {
  return {
    x,
    y,
    destMap,
    destX,
    destY
  };
}

function normalizeGroundObject(x: number, y: number, id: number, amount: number): GroundObject {
  return {
    x,
    y,
    id,
    amount
  };
}

export function buildGroundObjectRecord(objects: GroundObject[]) {
  return Object.fromEntries(objects.map((object) => [`${object.x},${object.y}`, object]));
}

function buildManifestUrls() {
  if (typeof window === "undefined") {
    return ["/client/data/map-pack.json", "/data/map-pack.json"];
  }

  const origin = window.location.origin;
  const urls = [
    new URL("/client/data/map-pack.json", origin).toString(),
    new URL("/data/map-pack.json", origin).toString()
  ];

  if (import.meta.env.BASE_URL) {
    urls.push(new URL("data/map-pack.json", new URL(import.meta.env.BASE_URL, origin)).toString());
  }

  return Array.from(new Set(urls));
}

async function loadManifest() {
  let lastError: Error | null = null;

  for (const url of buildManifestUrls()) {
    try {
      const response = await fetch(url, { cache: "no-cache" });

      if (!response.ok) {
        throw new Error(`Map pack manifest fetch failed with status ${response.status} at ${url}`);
      }

      const manifest = (await response.json()) as MapPackManifest;

      if (manifest.version !== MAP_PACK_VERSION) {
        throw new Error(
          `Unsupported map pack manifest version ${manifest.version}; expected ${MAP_PACK_VERSION}`
        );
      }

      return {
        manifest,
        manifestUrl: url
      };
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
    }
  }

  throw lastError ?? new Error("Map pack manifest fetch failed.");
}

async function fetchMapPack(onProgress?: (progress: MapPackProgress) => void) {
  const { manifest, manifestUrl } = await loadManifest();
  const packUrl = new URL(`packs/${manifest.filename}`, manifestUrl).toString();
  const response = await fetch(packUrl, { cache: "force-cache" });

  if (!response.ok) {
    throw new Error(`Map pack fetch failed with status ${response.status} at ${packUrl}`);
  }

  return await readResponseWithProgress(response, onProgress);
}

function readMagic(reader: BinaryReader) {
  let magic = "";

  for (let index = 0; index < MAP_PACK_MAGIC.length; index += 1) {
    magic += String.fromCharCode(reader.readUint8());
  }

  return magic;
}

function decodeMapPack(buffer: ArrayBuffer) {
  const reader = new BinaryReader(buffer);
  const magic = readMagic(reader);

  if (magic !== MAP_PACK_MAGIC) {
    throw new Error(`Invalid map pack magic: ${magic}`);
  }

  const version = reader.readUint16();
  if (version !== MAP_PACK_VERSION) {
    throw new Error(`Unsupported map pack version: ${version}`);
  }

  const mapCount = reader.readUint16();
  const maps = new Map<number, PackedMapRecord>();

  for (let mapIndex = 0; mapIndex < mapCount; mapIndex += 1) {
    const mapId = reader.readUint16();
    const name = reader.readString8();
    const width = reader.readUint16();
    const height = reader.readUint16();
    const musicHi = reader.readInt32();
    const musicLow = reader.readInt32();

    const tiles = new Uint8Array(width * height);
    for (let tileIndex = 0; tileIndex < tiles.length; tileIndex += 1) {
      tiles[tileIndex] = reader.readUint8();
    }

    const layers = Array.from({ length: 4 }, () => {
      const layerTileCount = reader.readUint16();
      const layer: MapLayerTile[] = [];

      for (let index = 0; index < layerTileCount; index += 1) {
        layer.push(
          normalizeLayerTile(reader.readUint8(), reader.readUint8(), reader.readInt32())
        );
      }

      return layer;
    });

    const npcCount = reader.readUint16();
    const npcs: MapNpc[] = [];
    for (let index = 0; index < npcCount; index += 1) {
      npcs.push(normalizeNpc(reader.readUint8(), reader.readUint8(), reader.readUint16()));
    }

    const objectCount = reader.readUint16();
    const objects: GroundObject[] = [];
    for (let index = 0; index < objectCount; index += 1) {
      objects.push(
        normalizeGroundObject(
          reader.readUint8(),
          reader.readUint8(),
          reader.readUint16(),
          reader.readUint16()
        )
      );
    }

    const exitCount = reader.readUint16();
    const exits: MapExit[] = [];
    for (let index = 0; index < exitCount; index += 1) {
      exits.push(
        normalizeExit(
          reader.readUint8(),
          reader.readUint8(),
          reader.readUint16(),
          reader.readUint8(),
          reader.readUint8()
        )
      );
    }

    maps.set(mapId, {
      map: {
        mapId,
        name,
        width,
        height,
        tiles,
        musicHi,
        musicLow,
        layers,
        npcs,
        exits
      },
      groundObjects: buildGroundObjectRecord(objects)
    });
  }

  return maps;
}

function mergeChunks(chunks: Uint8Array[], totalBytes: number) {
  const output = new Uint8Array(totalBytes);
  let offset = 0;

  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return output.buffer;
}

async function readResponseWithProgress(
  response: Response,
  onProgress?: (progress: MapPackProgress) => void
) {
  const totalHeader = response.headers.get("Content-Length");
  const totalBytes =
    totalHeader != null && totalHeader.length > 0 ? Number.parseInt(totalHeader, 10) : null;

  if (!response.body) {
    const buffer = await response.arrayBuffer();
    onProgress?.({
      phase: "download",
      loadedBytes: buffer.byteLength,
      totalBytes
    });
    return buffer;
  }

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let loadedBytes = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }

    if (value) {
      chunks.push(value);
      loadedBytes += value.byteLength;
      onProgress?.({
        phase: "download",
        loadedBytes,
        totalBytes
      });
    }
  }

  return mergeChunks(chunks, loadedBytes);
}

export async function loadMapPack(onProgress?: (progress: MapPackProgress) => void) {
  if (decodedMapCache) {
    onProgress?.({
      phase: "ready",
      loadedBytes: 0,
      totalBytes: 0
    });
    return decodedMapCache;
  }

  if (!mapPackPromise) {
    mapPackPromise = fetchMapPack(onProgress)
      .then((buffer) => {
        onProgress?.({
          phase: "decode",
          loadedBytes: buffer.byteLength,
          totalBytes: buffer.byteLength
        });
        decodedMapCache = decodeMapPack(buffer);
        onProgress?.({
          phase: "ready",
          loadedBytes: buffer.byteLength,
          totalBytes: buffer.byteLength
        });
        return decodedMapCache;
      })
      .catch((error) => {
        mapPackPromise = null;
        throw error;
      });
  }

  return mapPackPromise;
}

export function getMapPackRecord(mapId: number) {
  return decodedMapCache?.get(mapId) ?? null;
}

export async function fetchMapData(_endpoint: string, mapId: number) {
  const maps = await loadMapPack();
  const record = maps.get(mapId);

  if (!record) {
    throw new Error(`Map ${mapId} not found in client map pack.`);
  }

  return {
    map: record.map,
    groundObjects: { ...record.groundObjects }
  };
}
