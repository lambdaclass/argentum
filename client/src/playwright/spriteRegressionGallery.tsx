import { useEffect, useMemo, useState } from "react";
import bodies from "../../../resources/indices/cuerpos.json";
import heads from "../../../resources/indices/cabezas.json";
import objects from "../../../resources/indices/objs.json";
import grhFull from "../../../resources/indices/graficos_full.json";
import {
  getRawNpcBodyDef,
  getRawNpcBodySheetUrl,
  type RawNpcDirection
} from "../render/npcRawBodies.generated";

type Direction = RawNpcDirection;

interface SpriteFrame {
  url: string;
  offX: number;
  offY: number;
  width: number;
  height: number;
}

interface SpriteLayer extends SpriteFrame {
  offsetX?: number;
  offsetY?: number;
}

interface PlayerSample {
  label: string;
  bodyId: number;
  headId: number;
  weaponId: number;
  shieldId: number;
  helmetId: number;
}

interface BodySample {
  label: string;
  bodyId: number;
}

interface RawNpcSample {
  label: string;
  npcId: number;
}

const DIRECTIONS: Direction[] = ["north", "east", "south", "west"];
const DISPLAY_SCALE = 2.5;
const STAGE_SIZE = 176;
const STAGE_CENTER = STAGE_SIZE / 2;

const spriteSheetUrls = import.meta.glob(
  "../../../resources/raw/Graficos/{100,102,1115,112,2086,2331,2335,2336,5026,5088}.png",
  {
    eager: true,
    query: "?url",
    import: "default"
  }
) as Record<string, string>;

const PLAYER_SAMPLES: PlayerSample[] = [
  {
    label: "Body 1 + head 1 + sword/shield/helmet",
    bodyId: 1,
    headId: 1,
    weaponId: 49167,
    shieldId: 37975,
    helmetId: 559
  },
  {
    label: "Body 5 + head 1 + dagger/shield/helmet",
    bodyId: 5,
    headId: 1,
    weaponId: 5603,
    shieldId: 37976,
    helmetId: 17517
  }
];

const BODY_SAMPLES: BodySample[] = [
  { label: "Body 1", bodyId: 1 },
  { label: "Body 5", bodyId: 5 }
];

const RAW_NPC_SAMPLES: RawNpcSample[] = [
  { label: "NPC 604", npcId: 604 },
  { label: "NPC 634", npcId: 634 },
  { label: "NPC 645", npcId: 645 }
];

interface ResolvedFrame {
  url: string;
  offX: number;
  offY: number;
  width: number;
  height: number;
}

interface GrhEntry {
  grafico?: number | string;
  offX?: number;
  offY?: number;
  width?: number;
  height?: number;
  frames?: number[];
}

function frameForSpriteFrame(frame: SpriteFrame): ResolvedFrame {
  return {
    url: frame.url,
    offX: frame.offX,
    offY: frame.offY,
    width: frame.width,
    height: frame.height
  };
}

function slugify(value: string) {
  return value
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^\w\s-]+/g, " ")
    .replace(/[\s_]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

function toBodyDirectionKey(direction: Direction): "up" | "right" | "down" | "left" {
  switch (direction) {
    case "north":
      return "up";
    case "east":
      return "right";
    case "south":
      return "down";
    case "west":
      return "left";
  }
}

function toNpcDirectionKey(direction: Direction): "north" | "east" | "south" | "west" {
  return direction;
}

function resolveGrhFrame(grhId: number | null): ResolvedFrame | null {
  if (!grhId) {
    return null;
  }

  const entries = grhFull as Array<GrhEntry | null>;
  let entry: GrhEntry | null = entries[grhId] ?? null;
  if (!entry) {
    return null;
  }

  while (entry.frames && entry.frames.length > 0) {
    const next: GrhEntry | null = entries[entry.frames[0]] ?? null;
    if (!next || next === entry) {
      break;
    }
    entry = next;
  }

  if (entry.grafico == null || entry.offX == null || entry.offY == null || entry.width == null || entry.height == null) {
    return null;
  }

  const sheetUrl = spriteSheetUrls[`../../../resources/raw/Graficos/${entry.grafico}.png`];
  if (!sheetUrl) {
    return null;
  }

  return {
    url: sheetUrl,
    offX: entry.offX,
    offY: entry.offY,
    width: entry.width,
    height: entry.height
  };
}

function resolveBodyFrame(bodyId: number, direction: Direction) {
  const body = (bodies as Array<{
    id: number;
    up: number;
    right: number;
    down: number;
    left: number;
    offHeadX: number;
    offHeadY: number;
  } | null>)[bodyId];

  if (!body) {
    return null;
  }

  const directionKey = toBodyDirectionKey(direction);
  return resolveGrhFrame(body[directionKey]);
}

function resolveHeadFrame(headId: number, direction: Direction) {
  const head = (heads as Array<{
    id: number;
    up: number;
    right: number;
    down: number;
    left: number;
  } | null>)[headId];

  if (!head) {
    return null;
  }

  const directionKey = toBodyDirectionKey(direction);
  return resolveGrhFrame(head[directionKey]);
}

function resolveObjectFrame(objectId: number) {
  const object = (objects as Array<{ name: string; grh: number } | null>)[objectId];
  return object ? resolveGrhFrame(object.grh) : null;
}

function resolveRawNpcLayers(npcId: number, direction: Direction): Array<ResolvedFrame & { offsetX: number; offsetY: number }> {
  const def = getRawNpcBodyDef(npcId);
  if (!def) {
    return [];
  }

  if (def.type === "direct") {
    const directionKey = toNpcDirectionKey(direction);
    const frame = resolveGrhFrame((def as Record<Direction, number>)[directionKey]);
    return frame ? [{ ...frame, offsetX: def.bodyOffsetX, offsetY: def.bodyOffsetY }] : [];
  }

  const sheetUrl = getRawNpcBodySheetUrl(def.fileNum);
  if (!sheetUrl) {
    return [];
  }

  const frame = def.directions[direction].frames[0];
  if (!frame) {
    return [];
  }

  return [
    {
      url: sheetUrl,
      offX: frame.x,
      offY: frame.y,
      width: def.width,
      height: def.height,
      offsetX: def.bodyOffsetX,
      offsetY: def.bodyOffsetY
    }
  ];
}

function usePreloadedUrls(urls: string[]) {
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let cancelled = false;
    const uniqueUrls = Array.from(new Set(urls)).filter(Boolean);

    if (uniqueUrls.length === 0) {
      setReady(true);
      return () => {
        cancelled = true;
      };
    }

    setReady(false);
    Promise.all(
      uniqueUrls.map(
        (url) =>
          new Promise<void>((resolve) => {
            const image = new Image();
            image.onload = () => resolve();
            image.onerror = () => resolve();
            image.src = url;
          })
      )
    ).then(() => {
      if (!cancelled) {
        setReady(true);
      }
    });

    return () => {
      cancelled = true;
    };
  }, [urls]);

  return ready;
}

function Stage({
  layers,
  title,
  subtitle
}: {
  layers: SpriteLayer[];
  title: string;
  subtitle: string;
}) {
  return (
    <div
      style={{
        position: "relative",
        width: `${STAGE_SIZE}px`,
        height: `${STAGE_SIZE}px`,
        overflow: "hidden",
        border: "1px solid rgba(240, 194, 94, 0.4)",
        borderRadius: "14px",
        background:
          "linear-gradient(180deg, rgba(27, 22, 18, 0.96), rgba(16, 12, 10, 0.96)), radial-gradient(circle at top, rgba(255,255,255,0.08), transparent 60%)"
      }}
    >
      <div
        aria-hidden="true"
        style={{
          position: "absolute",
          inset: 0,
          backgroundImage:
            "linear-gradient(rgba(255, 255, 255, 0.035) 1px, transparent 1px), linear-gradient(90deg, rgba(255, 255, 255, 0.035) 1px, transparent 1px)",
          backgroundSize: "22px 22px"
        }}
      />
      {layers.map((layer, index) => {
        const anchorX = ((layer.width - 32) / 2) * DISPLAY_SCALE;
        const anchorY = (layer.height - 32) * DISPLAY_SCALE;
        const left = STAGE_CENTER + (layer.offsetX ?? 0) * DISPLAY_SCALE - anchorX;
        const top = STAGE_CENTER + (layer.offsetY ?? 0) * DISPLAY_SCALE - anchorY;

        return (
          <div
            key={`${title}-${subtitle}-${index}-${layer.url}-${layer.offX}-${layer.offY}`}
            style={{
              position: "absolute",
              left: `${left}px`,
              top: `${top}px`,
              width: `${layer.width * DISPLAY_SCALE}px`,
              height: `${layer.height * DISPLAY_SCALE}px`,
              overflow: "hidden"
            }}
          >
            <div
              style={{
                position: "relative",
                width: `${layer.width}px`,
                height: `${layer.height}px`,
                transform: `scale(${DISPLAY_SCALE})`,
                transformOrigin: "top left",
                imageRendering: "pixelated"
              }}
            >
              <img
                alt=""
                draggable={false}
                src={layer.url}
                style={{
                  position: "absolute",
                  left: `-${layer.offX}px`,
                  top: `-${layer.offY}px`,
                  userSelect: "none",
                  pointerEvents: "none",
                  imageRendering: "pixelated"
                }}
              />
            </div>
          </div>
        );
      })}
      <div
        style={{
          position: "absolute",
          left: "8px",
          right: "8px",
          bottom: "8px",
          zIndex: 1,
          padding: "0.4rem 0.55rem",
          borderRadius: "10px",
          background: "rgba(8, 8, 10, 0.72)",
          color: "#f4e8d4",
          fontSize: "11px",
          lineHeight: 1.2
        }}
      >
        <strong>{title}</strong>
        <div>{subtitle}</div>
      </div>
    </div>
  );
}

function DirectionGrid({
  title,
  subtitle,
  directions,
  renderStage
}: {
  title: string;
  subtitle: string;
  directions: Direction[];
  renderStage: (direction: Direction) => SpriteLayer[];
}) {
  const testId = slugify(title);

  return (
    <section
      data-testid={testId}
      style={{
        display: "grid",
        gap: "0.9rem",
        padding: "1rem",
        borderRadius: "18px",
        border: "1px solid rgba(240, 194, 94, 0.18)",
        background: "rgba(17, 14, 11, 0.78)"
      }}
    >
      <div>
        <p style={{ margin: 0, color: "#c7b08a", fontSize: "0.78rem", letterSpacing: "0.12em" }}>
          Sprite regression
        </p>
        <h2 style={{ margin: "0.1rem 0 0", fontSize: "1.3rem" }}>{title}</h2>
        <p style={{ margin: "0.4rem 0 0", color: "#e4d0ad" }}>{subtitle}</p>
      </div>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(4, minmax(176px, 1fr))",
          gap: "0.75rem"
        }}
      >
        {directions.map((direction) => (
          <div key={direction} style={{ display: "grid", gap: "0.4rem" }}>
            <div style={{ color: "#ccb48f", fontSize: "0.8rem", textTransform: "uppercase" }}>
              {direction}
            </div>
            <Stage
              layers={renderStage(direction)}
              subtitle={subtitle}
              title={direction}
            />
          </div>
        ))}
      </div>
    </section>
  );
}

function SpritePreviewPage() {
  const assetUrls = useMemo(() => {
    const urls = new Set<string>();

    for (const sample of PLAYER_SAMPLES) {
      for (const direction of DIRECTIONS) {
        const body = resolveBodyFrame(sample.bodyId, direction);
        const head = resolveHeadFrame(sample.headId, direction);
        if (body) {
          urls.add(body.url);
        }
        if (head) {
          urls.add(head.url);
        }
      }

      [sample.weaponId, sample.shieldId, sample.helmetId].forEach((objectId) => {
        const object = resolveObjectFrame(objectId);
        if (object) {
          urls.add(object.url);
        }
      });
    }

    for (const sample of BODY_SAMPLES) {
      for (const direction of DIRECTIONS) {
        const body = resolveBodyFrame(sample.bodyId, direction);
        if (body) {
          urls.add(body.url);
        }
      }
    }

    for (const sample of RAW_NPC_SAMPLES) {
      for (const direction of DIRECTIONS) {
        resolveRawNpcLayers(sample.npcId, direction).forEach((layer) => urls.add(layer.url));
      }
    }

    return Array.from(urls);
  }, []);

  const ready = usePreloadedUrls(assetUrls);

  return (
    <div style={{ padding: "1.5rem", display: "grid", gap: "1.2rem" }}>
      <header className="panel">
        <p className="eyebrow">Playwright</p>
        <h1>Sprite regression gallery</h1>
        <p className="panel-copy compact">
          Browser-only screenshots for player body overlays, common NPC body sheets, and body/direction
          mapping regressions. The page is fed entirely from checked-in resource metadata.
        </p>
        <p data-testid="sprite-regression-ready" style={{ margin: "0.75rem 0 0", color: "#f0d9af" }}>
          {ready ? "ready" : "loading sprite sheets"}
        </p>
      </header>

      <section style={{ display: "grid", gap: "1rem" }}>
        <div>
          <p style={{ margin: 0, color: "#c7b08a", fontSize: "0.78rem", letterSpacing: "0.12em" }}>
            Player overlays
          </p>
          <h2 style={{ margin: "0.1rem 0 0", fontSize: "1.3rem" }}>Player body and equipment overlays</h2>
          <p style={{ margin: "0.4rem 0 0", color: "#e4d0ad" }}>
            Each sample is isolated so body/head offsets and overlay layering stay readable in screenshots.
          </p>
        </div>
        {PLAYER_SAMPLES.map((sample) => (
          <DirectionGrid
            key={sample.label}
            directions={DIRECTIONS}
            subtitle={sample.label}
            title={sample.label}
            renderStage={(direction) => {
              const layers: SpriteLayer[] = [];
              const body = resolveBodyFrame(sample.bodyId, direction);
              const head = resolveHeadFrame(sample.headId, direction);
              const weapon = resolveObjectFrame(sample.weaponId);
              const shield = resolveObjectFrame(sample.shieldId);
              const helmet = resolveObjectFrame(sample.helmetId);
              const bodyMeta = (bodies as Array<{ offHeadX: number; offHeadY: number } | null>)[
                sample.bodyId
              ];

              if (body) {
                layers.push({
                  ...frameForSpriteFrame(body),
                  offsetX: 0,
                  offsetY: 0
                });
              }
              if (head && bodyMeta) {
                layers.push({
                  ...frameForSpriteFrame(head),
                  offsetX: bodyMeta.offHeadX ?? 0,
                  offsetY: bodyMeta.offHeadY ?? 0
                });
              }
              if (shield) {
                layers.push({ ...frameForSpriteFrame(shield), offsetX: 0, offsetY: 0 });
              }
              if (weapon) {
                layers.push({ ...frameForSpriteFrame(weapon), offsetX: 0, offsetY: 0 });
              }
              if (helmet) {
                layers.push({ ...frameForSpriteFrame(helmet), offsetX: 0, offsetY: 0 });
              }

              return layers;
            }}
          />
        ))}
      </section>

      <section style={{ display: "grid", gap: "1rem" }}>
        <div>
          <p style={{ margin: 0, color: "#c7b08a", fontSize: "0.78rem", letterSpacing: "0.12em" }}>
            Raw NPC bodies
          </p>
          <h2 style={{ margin: "0.1rem 0 0", fontSize: "1.3rem" }}>Common NPC sprite mappings</h2>
          <p style={{ margin: "0.4rem 0 0", color: "#e4d0ad" }}>
            Each NPC is rendered separately so a sheet or frame regression is obvious in screenshot diffs.
          </p>
        </div>
        {RAW_NPC_SAMPLES.map((sample) => (
          <DirectionGrid
            key={sample.label}
            directions={DIRECTIONS}
            subtitle={sample.label}
            title={sample.label}
            renderStage={(direction) => resolveRawNpcLayers(sample.npcId, direction)}
          />
        ))}
      </section>

      <section style={{ display: "grid", gap: "1rem" }}>
        <div>
          <p style={{ margin: 0, color: "#c7b08a", fontSize: "0.78rem", letterSpacing: "0.12em" }}>
            Body mappings
          </p>
          <h2 style={{ margin: "0.1rem 0 0", fontSize: "1.3rem" }}>Body/sprite mapping regressions</h2>
          <p style={{ margin: "0.4rem 0 0", color: "#e4d0ad" }}>
            These body-only rows keep direction and offset regressions visible without equipment layers.
          </p>
        </div>
        {BODY_SAMPLES.map((sample) => (
          <DirectionGrid
            key={sample.label}
            directions={DIRECTIONS}
            subtitle={sample.label}
            title={sample.label}
            renderStage={(direction) => {
              const body = resolveBodyFrame(sample.bodyId, direction);
              return body
                ? [
                    {
                      ...body,
                      offsetX: 0,
                      offsetY: 0
                    }
                  ]
                : [];
            }}
          />
        ))}
      </section>
    </div>
  );
}

export { SpritePreviewPage };
