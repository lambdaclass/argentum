import { describe, expect, it } from "vitest";
import { getRawNpcBodyDef, getRawNpcBodySheetUrl } from "./npcRawBodies.generated";

describe("npcRawBodies.generated", () => {
  it("includes direct NPC bodies that were previously missing from the partial table", () => {
    expect(getRawNpcBodyDef(4505)).toEqual({
      type: "direct",
      bodyOffsetX: 0,
      bodyOffsetY: 0,
      offHeadX: 0,
      offHeadY: -2,
      north: 55759,
      east: 55761,
      south: 55758,
      west: 55760
    });
  });

  it("includes molded NPC bodies from the legacy body data", () => {
    const body = getRawNpcBodyDef(1109);
    expect(body?.type).toBe("molded");
    if (!body || body.type !== "molded") {
      throw new Error("expected molded body");
    }

    expect(body.fileNum).toBe(1402);
    expect(body.width).toBe(27);
    expect(body.height).toBe(47);
    expect(body.offHeadY).toBe(-2);
  });

  it("marks direct character-grh NPC bodies as precomposed sprites", () => {
    expect(getRawNpcBodyDef(1032)).toEqual({
      type: "direct",
      useCharIndex: true,
      includesHead: true,
      bodyOffsetX: 0,
      bodyOffsetY: 0,
      offHeadX: 0,
      offHeadY: 0,
      north: 1032,
      east: 1032,
      south: 1032,
      west: 1032
    });
  });

  it("resolves raw sprite sheets for molded bodies in the generated table", () => {
    expect(getRawNpcBodySheetUrl(1402)).not.toBeNull();
  });
});
