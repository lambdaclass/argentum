import { afterEach, describe, expect, it, vi } from "vitest";
import {
  getLoadedMapPackManifest,
  loadMapPack,
  loadedMapPackMatches,
  resetMapPackCacheForTests
} from "./mapApi";

function buildTestPack() {
  const bytes: number[] = [];
  const pushUint8 = (value: number) => bytes.push(value & 0xff);
  const pushUint16 = (value: number) => {
    bytes.push(value & 0xff, (value >>> 8) & 0xff);
  };
  const pushInt32 = (value: number) => {
    const buffer = new ArrayBuffer(4);
    new DataView(buffer).setInt32(0, value, true);
    bytes.push(...new Uint8Array(buffer));
  };
  const pushString = (value: string) => {
    const encoded = new TextEncoder().encode(value);
    pushUint16(encoded.length);
    bytes.push(...encoded);
  };

  bytes.push(...new TextEncoder().encode("AOMP"));
  pushUint16(1);
  pushUint16(1);
  pushUint16(1);
  pushString("Test Map");
  pushUint16(2);
  pushUint16(2);
  pushInt32(0);
  pushInt32(0);
  bytes.push(0, 2, 0, 0);

  for (let layer = 0; layer < 4; layer += 1) {
    pushUint16(0);
  }

  pushUint16(0);
  pushUint16(0);
  pushUint16(0);

  return new Uint8Array(bytes);
}

describe("mapApi", () => {
  afterEach(() => {
    resetMapPackCacheForTests();
    vi.restoreAllMocks();
  });

  it("records the loaded browser world-pack manifest for bootstrap verification", async () => {
    const pack = buildTestPack();
    const browserManifest = {
      version: 1,
      maps: 1,
      filename: "maps.browser.pack",
      bytes: pack.byteLength,
      hash: "browser-hash"
    };

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);

        if (url.endsWith("/client/data/map-pack.json") || url.endsWith("/data/map-pack.json")) {
          return new Response(JSON.stringify(browserManifest), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          });
        }

        if (
          url.endsWith("/client/data/packs/maps.browser.pack") ||
          url.endsWith("/data/packs/maps.browser.pack")
        ) {
          return new Response(pack, {
            status: 200,
            headers: { "Content-Length": String(pack.byteLength) }
          });
        }

        return new Response("Not found", { status: 404 });
      })
    );

    const maps = await loadMapPack("ws://127.0.0.1:7667/ao");
    expect(maps.get(1)?.map.name).toBe("Test Map");
    expect(getLoadedMapPackManifest()).toEqual(browserManifest);
    expect(loadedMapPackMatches(1, "browser-hash")).toBe(true);
    expect(loadedMapPackMatches(1, "server-hash")).toBe(false);
  });
});
