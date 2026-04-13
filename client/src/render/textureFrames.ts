import type { BaseTexture } from "pixi.js";

export interface TextureFrameRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface TextureSize {
  width: number;
  height: number;
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

export function resolveBaseTextureSize(baseTexture: BaseTexture): TextureSize {
  const resource = baseTexture.resource as
    | {
        source?: {
          naturalWidth?: number;
          naturalHeight?: number;
          videoWidth?: number;
          videoHeight?: number;
          width?: number;
          height?: number;
        };
      }
    | undefined;
  const source = resource?.source;
  const width =
    source?.naturalWidth ??
    source?.videoWidth ??
    source?.width ??
    baseTexture.realWidth ??
    baseTexture.width ??
    0;
  const height =
    source?.naturalHeight ??
    source?.videoHeight ??
    source?.height ??
    baseTexture.realHeight ??
    baseTexture.height ??
    0;

  return { width, height };
}

export function fitFrameWithinTexture(
  frame: TextureFrameRect,
  textureSize: TextureSize
): TextureFrameRect | null {
  if (
    textureSize.width <= 0 ||
    textureSize.height <= 0 ||
    frame.width <= 0 ||
    frame.height <= 0
  ) {
    return null;
  }

  const width = Math.min(frame.width, textureSize.width);
  const height = Math.min(frame.height, textureSize.height);
  const x = clamp(frame.x, 0, Math.max(0, textureSize.width - width));
  const y = clamp(frame.y, 0, Math.max(0, textureSize.height - height));

  if (x + width > textureSize.width || y + height > textureSize.height) {
    return null;
  }

  return { x, y, width, height };
}
