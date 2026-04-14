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

  it("includes all frame sheets for animated GRHs", () => {
    const catalog: AssetCatalog = {
      endpoint: "ws://127.0.0.1:7667/ao",
      assetOrigin: "http://127.0.0.1:7667",
      bodies: [],
      heads: [],
      objects: [],
      npcs: [],
      grhMap: [],
      grhChar: []
    };

    catalog.grhMap[100] = {
      id: 100,
      grafico: 0,
      offX: 0,
      offY: 0,
      width: 32,
      height: 32,
      frames: [101, 102]
    };
    catalog.grhMap[101] = { id: 101, grafico: 5001, offX: 0, offY: 0, width: 32, height: 32 };
    catalog.grhMap[102] = { id: 102, grafico: 5002, offX: 0, offY: 0, width: 32, height: 32 };

    const urls = collectSceneAssetUrls(
      catalog,
      {
        mapId: 1,
        name: "Anim",
        width: 1,
        height: 1,
        tiles: new Uint8Array(1),
        musicHi: 0,
        musicLow: 0,
        layers: [[{ x: 1, y: 1, grhIndex: 100 }], [], [], []],
        npcs: [],
        exits: []
      }
    );

    expect(urls).toContain("http://127.0.0.1:7667/graficos/5001.png");
    expect(urls).toContain("http://127.0.0.1:7667/graficos/5002.png");
  });

  it("includes ghost body sheets for dead characters", () => {
    const catalog: AssetCatalog = {
      endpoint: "ws://127.0.0.1:7667/ao",
      assetOrigin: "http://127.0.0.1:7667",
      bodies: [],
      heads: [],
      objects: [],
      npcs: [],
      grhMap: [],
      grhChar: []
    };

    catalog.grhMap[51671] = { id: 51671, grafico: 6215, offX: 0, offY: 0, width: 32, height: 32 };
    catalog.grhMap[51672] = { id: 51672, grafico: 6215, offX: 0, offY: 0, width: 32, height: 32 };
    catalog.grhMap[51673] = { id: 51673, grafico: 6215, offX: 0, offY: 0, width: 32, height: 32 };
    catalog.grhMap[51674] = { id: 51674, grafico: 6215, offX: 0, offY: 0, width: 32, height: 32 };

    const urls = collectSceneAssetUrls(
      catalog,
      {
        mapId: 2,
        name: "Ghost",
        width: 1,
        height: 1,
        tiles: new Uint8Array(1),
        musicHi: 0,
        musicLow: 0,
        layers: [[], [], [], []],
        npcs: [],
        exits: []
      },
      [
        {
          x: 1,
          y: 1,
          bodyId: 829,
          headId: 0,
          weaponId: 0,
          shieldId: 0,
          helmetId: 0,
          cartId: 0,
          backpackId: 0,
          effectId: 0,
          heading: 3
        }
      ]
    );

    expect(urls).toContain("http://127.0.0.1:7667/graficos/6215.png");
  });

  it("loads direct raw NPC bodies from the full graphics index", () => {
    const catalog: AssetCatalog = {
      endpoint: "ws://127.0.0.1:7667/ao",
      assetOrigin: "http://127.0.0.1:7667",
      bodies: [],
      heads: [],
      objects: [],
      npcs: [],
      grhMap: [],
      grhChar: []
    };

    catalog.grhMap[55759] = {
      id: 55759,
      grafico: 0,
      offX: 0,
      offY: 0,
      width: 24,
      height: 50,
      frames: [55742, 55743, 55744, 55745, 55746, 55747]
    };
    catalog.grhMap[55742] = {
      id: 55742,
      grafico: 4015,
      offX: 0,
      offY: 48,
      width: 24,
      height: 50
    };
    catalog.grhMap[55743] = {
      id: 55743,
      grafico: 4015,
      offX: 24,
      offY: 48,
      width: 24,
      height: 50
    };

    const urls = collectSceneAssetUrls(
      catalog,
      {
        mapId: 3,
        name: "Raw NPC",
        width: 1,
        height: 1,
        tiles: new Uint8Array(1),
        musicHi: 0,
        musicLow: 0,
        layers: [[], [], [], []],
        npcs: [],
        exits: []
      },
      [
        {
          x: 1,
          y: 1,
          bodyId: 4505,
          headId: 0,
          weaponId: 0,
          shieldId: 0,
          helmetId: 0,
          cartId: 0,
          backpackId: 0,
          effectId: 0,
          heading: 1
        }
      ]
    );

    expect(urls).toContain("http://127.0.0.1:7667/graficos/4015.png");
  });
});
