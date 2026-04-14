import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..", "..");

const npcDataPath = path.join(repoRoot, "resources/raw/Dat/npcs.dat");
const bodyDataPath = path.join(repoRoot, "resources/raw/init/cuerpos.dat");
const moldeDataPath = path.join(repoRoot, "resources/raw/init/moldes.ini");
const grhFullPath = path.join(repoRoot, "resources/indices/graficos_full.json");
const grhCharPath = path.join(repoRoot, "resources/indices/graficos.json");
const outputPath = path.join(repoRoot, "client/src/render/npcRawBodies.generated.ts");

const BASE_FRAME_MS = 1000 / 18;

function parseIndexedSections(source, prefix) {
  const sections = new Map();
  const lines = source.split(/\r?\n/);
  let current = null;

  for (const rawLine of lines) {
    const line = rawLine.trim();
    const sectionMatch = line.match(/^\[([A-Za-z]+)(\d+)\]$/);
    if (sectionMatch) {
      if (current) {
        sections.set(current.id, current.values);
      }

      const [, sectionPrefix, idText] = sectionMatch;
      current =
        sectionPrefix === prefix
          ? { id: Number(idText), values: new Map() }
          : null;
      continue;
    }

    if (!current || line.length === 0 || line.startsWith("'")) {
      continue;
    }

    const separator = line.indexOf("=");
    if (separator <= 0) {
      continue;
    }

    current.values.set(line.slice(0, separator).trim(), line.slice(separator + 1).trim());
  }

  if (current) {
    sections.set(current.id, current.values);
  }

  return sections;
}

function readNumber(values, key, fallback = 0) {
  const raw = values.get(key);
  if (raw == null) {
    return fallback;
  }

  const numericPrefix = raw.match(/^-?\d+(?:\.\d+)?/);
  if (!numericPrefix) {
    return fallback;
  }

  const value = Number(numericPrefix[0]);
  return Number.isFinite(value) ? value : fallback;
}

function formatNumber(value) {
  if (Number.isInteger(value)) {
    return String(value);
  }

  return value.toFixed(4).replace(/\.?0+$/, "");
}

function formatValue(value) {
  if (Array.isArray(value)) {
    return `[${value.map(formatValue).join(", ")}]`;
  }

  if (value && typeof value === "object") {
    return `{ ${Object.entries(value)
      .map(([key, entryValue]) => `${key}: ${formatValue(entryValue)}`)
      .join(", ")} }`;
  }

  if (typeof value === "string") {
    return JSON.stringify(value);
  }

  if (typeof value === "number") {
    return formatNumber(value);
  }

  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }

  throw new Error(`Unsupported value ${String(value)}`);
}

function buildMoldedFrames(molde, row, count) {
  const frames = [];
  for (let index = 0; index < count; index += 1) {
    frames.push({
      x: molde.x + index * molde.width,
      y: molde.y + row * molde.height
    });
  }
  return frames;
}

function frameVelocity(frameCount, speed) {
  const effectiveSpeed = speed > 0 ? speed : 1;
  return Math.round((frameCount * (BASE_FRAME_MS / effectiveSpeed)) * 10000) / 10000;
}

function buildDirectBodyDef(values) {
  const walk1 = readNumber(values, "Walk1");
  const walk2 = readNumber(values, "Walk2");
  const walk3 = readNumber(values, "Walk3");
  const walk4 = readNumber(values, "Walk4");

  if (walk1 <= 0 || walk2 <= 0 || walk3 <= 0 || walk4 <= 0) {
    return null;
  }

  const bodyOffsetX = readNumber(values, "BodyOffsetX");
  const bodyOffsetY = readNumber(values, "BodyOffsetY");

  return {
    type: "direct",
    bodyOffsetX,
    bodyOffsetY,
    offHeadX: bodyOffsetX + readNumber(values, "HeadOffsetX"),
    offHeadY: bodyOffsetY + readNumber(values, "HeadOffsetY"),
    north: walk1,
    east: walk2,
    south: walk3,
    west: walk4
  };
}

function buildMoldedBodyDef(values, moldeDefs) {
  const molde = moldeDefs.get(readNumber(values, "Std"));
  const fileNum = readNumber(values, "FileNum");

  if (!molde || fileNum <= 0) {
    return null;
  }

  const bodyOffsetX = readNumber(values, "BodyOffsetX");
  const bodyOffsetY = readNumber(values, "BodyOffsetY");
  const speed = readNumber(values, "Speed", 1);

  return {
    type: "molded",
    bodyOffsetX,
    bodyOffsetY,
    offHeadX: bodyOffsetX + readNumber(values, "HeadOffsetX"),
    offHeadY: bodyOffsetY + readNumber(values, "HeadOffsetY"),
    fileNum,
    width: molde.width,
    height: molde.height,
    directions: {
      north: {
        velocity: frameVelocity(molde.northFrames, speed),
        frames: buildMoldedFrames(molde, 1, molde.northFrames)
      },
      east: {
        velocity: frameVelocity(molde.eastFrames, speed),
        frames: buildMoldedFrames(molde, 3, molde.eastFrames)
      },
      south: {
        velocity: frameVelocity(molde.southFrames, speed),
        frames: buildMoldedFrames(molde, 0, molde.southFrames)
      },
      west: {
        velocity: frameVelocity(molde.westFrames, speed),
        frames: buildMoldedFrames(molde, 2, molde.westFrames)
      }
    }
  };
}

function buildModuleSource(bodyIds, bodyDefs, fileNums) {
  const fileNumList = fileNums.join(",");
  const bodyEntries = bodyIds
    .map((bodyId) => `  ${bodyId}: ${formatValue(bodyDefs.get(bodyId))},`)
    .join("\n");

  return `// Generated by client/scripts/generateNpcRawBodies.mjs from resources/raw/Dat/npcs.dat + resources/raw/init/cuerpos.dat + moldes.ini
export type RawNpcDirection = "north" | "east" | "south" | "west";

export interface RawNpcBodyBase {
  bodyOffsetX: number;
  bodyOffsetY: number;
  offHeadX: number;
  offHeadY: number;
}

export interface DirectRawNpcBodyDef extends RawNpcBodyBase {
  type: "direct";
  useCharIndex?: boolean;
  includesHead?: boolean;
  north: number;
  east: number;
  south: number;
  west: number;
}

export interface MoldedRawNpcDirectionDef {
  velocity: number;
  frames: Array<{ x: number; y: number }>;
}

export interface MoldedRawNpcBodyDef extends RawNpcBodyBase {
  type: "molded";
  fileNum: number;
  width: number;
  height: number;
  directions: Record<RawNpcDirection, MoldedRawNpcDirectionDef>;
}

export type RawNpcBodyDef = DirectRawNpcBodyDef | MoldedRawNpcBodyDef;

const rawNpcBodySheetUrls = import.meta.glob("../../../resources/raw/Graficos/{${fileNumList}}.png", { eager: true, query: "?url", import: "default" }) as Record<string, string>;

const rawNpcBodies: Record<number, RawNpcBodyDef> = {
${bodyEntries}
};

export function getRawNpcBodyDef(bodyId: number): RawNpcBodyDef | null {
  return rawNpcBodies[bodyId] ?? null;
}

export function getRawNpcBodySheetUrl(fileNum: number): string | null {
  return rawNpcBodySheetUrls[\`../../../resources/raw/Graficos/\${fileNum}.png\`] ?? null;
}
`;
}

async function main() {
  const [npcData, bodyData, moldeData, grhFullData, grhCharData] = await Promise.all([
    readFile(npcDataPath, "latin1"),
    readFile(bodyDataPath, "latin1"),
    readFile(moldeDataPath, "latin1"),
    readFile(grhFullPath, "utf8"),
    readFile(grhCharPath, "utf8")
  ]);

  const bodyIds = [...new Set([...npcData.matchAll(/^Body=(\d+)$/gm)].map((match) => Number(match[1])))]
    .filter((bodyId) => bodyId > 0)
    .sort((left, right) => left - right);

  const bodySections = parseIndexedSections(bodyData, "BODY");
  const moldeSections = parseIndexedSections(moldeData, "Molde");
  const grhFull = JSON.parse(grhFullData);
  const grhChar = JSON.parse(grhCharData);
  const moldeDefs = new Map(
    [...moldeSections.entries()].map(([moldeId, values]) => [
      moldeId,
      {
        x: readNumber(values, "X"),
        y: readNumber(values, "Y"),
        width: readNumber(values, "Width"),
        height: readNumber(values, "Height"),
        southFrames: readNumber(values, "Dir1"),
        northFrames: readNumber(values, "Dir2"),
        westFrames: readNumber(values, "Dir3"),
        eastFrames: readNumber(values, "Dir4")
      }
    ])
  );

  const bodyDefs = new Map();
  const fileNums = new Set();

  for (const bodyId of bodyIds) {
    const values = bodySections.get(bodyId);
    if (!values) {
      const useCharIndex = grhChar[bodyId] != null;
      const includesHead = useCharIndex;
      if (useCharIndex || grhFull[bodyId] != null) {
        bodyDefs.set(bodyId, {
          type: "direct",
          useCharIndex,
          includesHead,
          bodyOffsetX: 0,
          bodyOffsetY: 0,
          offHeadX: 0,
          offHeadY: 0,
          north: bodyId,
          east: bodyId,
          south: bodyId,
          west: bodyId
        });
        continue;
      }

      throw new Error(`Missing [BODY${bodyId}] in cuerpos.dat`);
    }

    const directBody = buildDirectBodyDef(values);
    if (directBody) {
      bodyDefs.set(bodyId, directBody);
      continue;
    }

    const moldedBody = buildMoldedBodyDef(values, moldeDefs);
    if (moldedBody) {
      bodyDefs.set(bodyId, moldedBody);
      fileNums.add(moldedBody.fileNum);
      continue;
    }

    throw new Error(`Unsupported NPC body ${bodyId}`);
  }

  await writeFile(
    outputPath,
    buildModuleSource(bodyIds, bodyDefs, [...fileNums].sort((left, right) => left - right))
  );

  console.log(
    `Generated ${path.relative(repoRoot, outputPath)} with ${bodyIds.length} body defs and ${fileNums.size} molded sheets.`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
