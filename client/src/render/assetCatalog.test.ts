import { describe, expect, it } from "vitest";
import { collectSceneAssetUrls, type AssetCatalog } from "./assetCatalog";

describe("collectSceneAssetUrls", () => {
  it("includes ground object sprite sheets in the scene preload set", () => {
    const bodies = [];
    bodies[1] = {
      id: 1,
      offHeadX: 0,
      offHeadY: 0,
      up: 11,
      right: 12,
      down: 13,
      left: 14
    };

    const heads = [];
    heads[1] = {
      id: 1,
      up: 21,
      right: 22,
      down: 23,
      left: 24
    };

    const objects = [];
    objects[1] = {
      name: "Church facade",
      grh: 31
    };

    const grhMap = [];
    grhMap[11] = { id: 11, grafico: 4111, offX: 0, offY: 0, width: 32, height: 32 };
    grhMap[12] = { id: 12, grafico: 4112, offX: 0, offY: 0, width: 32, height: 32 };
    grhMap[13] = { id: 13, grafico: 4113, offX: 0, offY: 0, width: 32, height: 32 };
    grhMap[14] = { id: 14, grafico: 4114, offX: 0, offY: 0, width: 32, height: 32 };
    grhMap[31] = { id: 31, grafico: 9999, offX: 0, offY: 0, width: 64, height: 96 };

    const grhChar = [];
    grhChar[11] = { id: 11, grafico: 5111, offX: 0, offY: 0, width: 32, height: 32 };
    grhChar[12] = { id: 12, grafico: 5112, offX: 0, offY: 0, width: 32, height: 32 };
    grhChar[13] = { id: 13, grafico: 5113, offX: 0, offY: 0, width: 32, height: 32 };
    grhChar[14] = { id: 14, grafico: 5114, offX: 0, offY: 0, width: 32, height: 32 };
    grhChar[21] = { id: 21, grafico: 6111, offX: 0, offY: 0, width: 32, height: 32 };
    grhChar[22] = { id: 22, grafico: 6112, offX: 0, offY: 0, width: 32, height: 32 };
    grhChar[23] = { id: 23, grafico: 6113, offX: 0, offY: 0, width: 32, height: 32 };
    grhChar[24] = { id: 24, grafico: 6114, offX: 0, offY: 0, width: 32, height: 32 };

    const catalog: AssetCatalog = {
      endpoint: "ws://127.0.0.1:7667/ao",
      assetOrigin: "http://127.0.0.1:7667",
      bodies,
      heads,
      objects,
      npcs: [],
      grhMap,
      grhChar
    };

    const urls = collectSceneAssetUrls(
      catalog,
      {
        mapId: 34,
        name: "Ciudad de Nix",
        width: 2,
        height: 2,
        tiles: new Uint8Array(4),
        musicHi: 0,
        musicLow: 0,
        layers: [[{ x: 1, y: 1, grhIndex: 11 }], [], [], []],
        npcs: [],
        exits: []
      },
      [
        {
          bodyId: 1,
          headId: 1,
          weaponId: 0,
          shieldId: 0,
          helmetId: 0,
          cartId: 0,
          backpackId: 0,
          effectId: 0,
          heading: 3
        }
      ],
      [{ x: 2, y: 2, id: 1, amount: 1 }]
    );

    expect(urls).toContain("http://127.0.0.1:7667/graficos/4111.png");
    expect(urls).toContain("http://127.0.0.1:7667/graficos_char/5113.png");
    expect(urls).toContain("http://127.0.0.1:7667/graficos_char/6113.png");
    expect(urls).toContain("http://127.0.0.1:7667/graficos/9999.png");
  });
});
