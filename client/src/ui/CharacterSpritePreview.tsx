import type { CSSProperties } from "react";
import type { AssetCatalog, GrhFrameDef } from "../render/assetCatalog";
import { bodyGrhForDirection, getGrhFrameDef, getObjectGrh, headGrhForDirection } from "../render/assetCatalog";

interface CharacterSpritePreviewProps {
  assetCatalog: AssetCatalog | null;
  name: string;
  bodyId: number;
  headId: number;
  helmetId?: number | null;
  weaponId?: number | null;
  shieldId?: number | null;
  compact?: boolean;
}

const PREVIEW_WIDTH = 92;
const PREVIEW_HEIGHT = 122;

function layerStyle(frame: GrhFrameDef, scale: number, offsetX = 0, offsetY = 0): CSSProperties {
  return {
    width: `${frame.width}px`,
    height: `${frame.height}px`,
    backgroundImage: `url("${frame.url}")`,
    backgroundPosition: `-${frame.offX}px -${frame.offY}px`,
    transform: `translate(${Math.round(PREVIEW_WIDTH / 2 + offsetX - frame.width / 2)}px, ${Math.round(
      PREVIEW_HEIGHT - 18 + offsetY - frame.height
    )}px) scale(${scale})`,
    transformOrigin: "top left"
  };
}

function resolveOverlayFrame(assetCatalog: AssetCatalog, objectId: number | null | undefined) {
  if (!objectId) {
    return null;
  }

  const grhId = getObjectGrh(assetCatalog, objectId);
  if (!grhId) {
    return null;
  }

  return getGrhFrameDef(assetCatalog, grhId, true);
}

export function CharacterSpritePreview({
  assetCatalog,
  name,
  bodyId,
  headId,
  helmetId,
  weaponId,
  shieldId,
  compact = false
}: CharacterSpritePreviewProps) {
  if (!assetCatalog) {
    return <div className={`character-preview-fallback ${compact ? "compact" : ""}`}>{name.slice(0, 2).toUpperCase()}</div>;
  }

  const direction = "south";
  const bodyGrhId = bodyGrhForDirection(assetCatalog, bodyId, direction);
  const headGrhId = headGrhForDirection(assetCatalog, headId, direction);
  const bodyFrame = bodyGrhId ? getGrhFrameDef(assetCatalog, bodyGrhId, true) : null;
  const headFrame = headGrhId ? getGrhFrameDef(assetCatalog, headGrhId, true) : null;
  const bodyDef = assetCatalog.bodies[bodyId];
  const scale = compact ? 1.15 : 1.45;
  const headOffsetX = bodyDef?.offHeadX ?? 0;
  const headOffsetY = bodyDef?.offHeadY ?? 0;
  const weaponFrame = resolveOverlayFrame(assetCatalog, weaponId);
  const shieldFrame = resolveOverlayFrame(assetCatalog, shieldId);
  const helmetFrame = resolveOverlayFrame(assetCatalog, helmetId);

  if (!bodyFrame && !headFrame) {
    return <div className={`character-preview-fallback ${compact ? "compact" : ""}`}>{name.slice(0, 2).toUpperCase()}</div>;
  }

  return (
    <div className={`character-preview-stage ${compact ? "compact" : ""}`} aria-hidden="true">
      {bodyFrame ? <div className="character-preview-layer" style={layerStyle(bodyFrame, scale)} /> : null}
      {shieldFrame ? <div className="character-preview-layer" style={layerStyle(shieldFrame, scale)} /> : null}
      {weaponFrame ? <div className="character-preview-layer" style={layerStyle(weaponFrame, scale)} /> : null}
      {headFrame ? (
        <div className="character-preview-layer" style={layerStyle(headFrame, scale, headOffsetX, headOffsetY)} />
      ) : null}
      {helmetFrame ? <div className="character-preview-layer" style={layerStyle(helmetFrame, scale)} /> : null}
    </div>
  );
}
