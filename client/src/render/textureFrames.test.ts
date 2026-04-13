import { describe, expect, it } from "vitest";
import { fitFrameWithinTexture } from "./textureFrames";

describe("fitFrameWithinTexture", () => {
  it("keeps valid frames unchanged", () => {
    expect(
      fitFrameWithinTexture(
        { x: 256, y: 480, width: 32, height: 32 },
        { width: 1024, height: 1024 }
      )
    ).toEqual({ x: 256, y: 480, width: 32, height: 32 });
  });

  it("clamps legacy out-of-bounds frames to the sheet edge", () => {
    expect(
      fitFrameWithinTexture(
        { x: 256, y: 480, width: 32, height: 64 },
        { width: 512, height: 512 }
      )
    ).toEqual({ x: 256, y: 448, width: 32, height: 64 });
  });

  it("returns null when the texture size is unavailable", () => {
    expect(
      fitFrameWithinTexture(
        { x: 0, y: 0, width: 32, height: 32 },
        { width: 0, height: 512 }
      )
    ).toBeNull();
  });
});
