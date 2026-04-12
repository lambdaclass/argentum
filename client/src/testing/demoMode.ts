import type { Dispatch } from "react";
import type { ClientAction } from "../app/types";

const UI_DEMO_STATE_QUERY_PARAM = "demoState";

type DemoScenario =
  | "default"
  | "dead"
  | "connecting"
  | "reconnect"
  | "error-banned"
  | "error-muted"
  | "error-server-full"
  | "error-maintenance"
  | "error-token-expired"
  | "map-loading";

function readDemoScenario(search: string): DemoScenario {
  const scenario = new URLSearchParams(search).get(UI_DEMO_STATE_QUERY_PARAM);

  switch (scenario) {
    case "dead":
    case "connecting":
    case "reconnect":
    case "error-banned":
    case "error-muted":
    case "error-server-full":
    case "error-maintenance":
    case "error-token-expired":
    case "map-loading":
      return scenario;
    default:
      return "default";
  }
}

function applyDemoScenario(dispatch: Dispatch<ClientAction>, scenario: DemoScenario) {
  switch (scenario) {
    case "dead":
      dispatch({ type: "connection/setStatus", status: "connected" });
      dispatch({ type: "stats/setHp", current: 0, max: 120 });
      dispatch({ type: "world/setSelfDead", dead: true });
      return;

    case "connecting":
      dispatch({ type: "connection/setStatus", status: "connecting" });
      return;

    case "reconnect":
      dispatch({ type: "session/resetRuntime" });
      dispatch({
        type: "connection/setCredentials",
        credentials: { charId: 4701, token: "demo-reconnect-token" }
      });
      dispatch({ type: "connection/setStatus", status: "offline" });
      return;

    case "error-banned":
      dispatch({ type: "session/resetRuntime" });
      dispatch({ type: "connection/setStatus", status: "offline", lastError: "Account banned." });
      return;

    case "error-muted":
      dispatch({ type: "session/resetRuntime" });
      dispatch({ type: "connection/setStatus", status: "offline", lastError: "Account muted." });
      return;

    case "error-server-full":
      dispatch({ type: "session/resetRuntime" });
      dispatch({
        type: "connection/setStatus",
        status: "offline",
        lastError: "Server full."
      });
      return;

    case "error-maintenance":
      dispatch({ type: "session/resetRuntime" });
      dispatch({
        type: "connection/setStatus",
        status: "offline",
        lastError: "Maintenance mode."
      });
      return;

    case "error-token-expired":
      dispatch({ type: "session/resetRuntime" });
      dispatch({
        type: "connection/setStatus",
        status: "offline",
        lastError: "Token expired."
      });
      return;

    case "map-loading":
      dispatch({ type: "session/resetRuntime" });
      dispatch({ type: "world/setMapLoading", mapId: 42 });
      return;

    case "default":
    default:
      return;
  }
}

export function bootstrapUiDemoState(dispatch: Dispatch<ClientAction>, search: string) {
  const scenario = readDemoScenario(search);
  const width = 8;
  const height = 8;
  const tiles = new Uint8Array(width * height).fill(1);
  tiles[4 * width + 4] = 2;

  dispatch({
    type: "world/setMapData",
    map: {
      mapId: 42,
      name: "Demo Coast",
      width,
      height,
      tiles,
      musicHi: 0,
      musicLow: 0,
      layers: [[], [], [], []],
      npcs: [{ x: 4, y: 4, id: 1 }],
      exits: [{ x: 8, y: 8, destMap: 43, destX: 1, destY: 1 }]
    },
    groundObjects: {}
  });
  dispatch({ type: "world/setCharIndex", charIndex: 7 });
  dispatch({ type: "world/setSelfPosition", x: 4, y: 4 });
  dispatch({ type: "world/setTargetTile", target: { x: 5, y: 5 } });
  dispatch({
    type: "stats/setAll",
    hpCurrent: 120,
    hpMax: 120,
    manaCurrent: 90,
    manaMax: 120,
    staminaCurrent: 80,
    staminaMax: 100,
    gold: 875,
    level: 23,
    currentXp: 42_000,
    nextXp: 51_000
  });
  dispatch({
    type: "inventory/setSlot",
    slotIndex: 0,
    slot: { itemId: 501, amount: 12, equipped: false, value: 240, canUse: 0x001f }
  });
  dispatch({
    type: "inventory/setSlot",
    slotIndex: 1,
    slot: { itemId: 777, amount: 1, equipped: true, value: 1200, canUse: 0x0003 }
  });
  dispatch({ type: "inventory/selectSlot", slotIndex: 0 });
  dispatch({
    type: "spellbook/setSlot",
    slotIndex: 0,
    slot: { spellId: 15, name: "Detectar Invisibilidad" }
  });
  dispatch({
    type: "spellbook/setSlot",
    slotIndex: 1,
    slot: { spellId: 16, name: "Invocar Elemental de Fuego" }
  });
  dispatch({
    type: "spellbook/setSlot",
    slotIndex: 2,
    slot: { spellId: 14, name: "Resucitar" }
  });
  dispatch({ type: "spellbook/selectSlot", slotIndex: 0 });
  dispatch({ type: "trade/open" });
  dispatch({
    type: "trade/setOffer",
    which: "mine",
    gold: 150,
    items: [
      { itemId: 501, name: "Vara de exploracion", grhIndex: 231, amount: 3, elementalTags: 0x03 },
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null
    ]
  });
  dispatch({
    type: "trade/setOffer",
    which: "theirs",
    gold: 420,
    items: [
      { itemId: 777, name: "Capa de bruma", grhIndex: 512, amount: 1, elementalTags: 0x09 },
      { itemId: 778, name: "Catalizador", grhIndex: 513, amount: 2, elementalTags: 0x12 },
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null
    ]
  });
  dispatch({ type: "trade/setOfferAmount", amount: 3 });
  dispatch({ type: "weather/rain", raining: true });
  dispatch({ type: "weather/snow", snowing: true });
  dispatch({ type: "trade/markAccepted", accepted: false });
  dispatch({ type: "trade/markPartnerAccepted", accepted: false });
  applyDemoScenario(dispatch, scenario);
}
