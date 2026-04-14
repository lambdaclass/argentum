import { describe, expect, it } from "vitest";
import {
  canStartInitialSceneBootstrap,
  describeConnectionIssue,
  describeViewportNotice
} from "./viewportState";

describe("canStartInitialSceneBootstrap", () => {
  const readyInput = {
    isGameplayRoute: true,
    assetStatus: "ready" as const,
    mapPackStatus: "ready" as const,
    connectionStatus: "connected" as const,
    mapStatus: "ready" as const,
    hasMap: true,
    hasAssetCatalog: true,
    hasSelfCharIndex: true,
    hasSelfPosition: true
  };

  it("only starts once the first scene can really preload", () => {
    expect(canStartInitialSceneBootstrap(readyInput)).toBe(true);
  });

  it("refuses to start while required world state is still missing", () => {
    expect(canStartInitialSceneBootstrap({ ...readyInput, connectionStatus: "connecting" })).toBe(false);
    expect(canStartInitialSceneBootstrap({ ...readyInput, hasMap: false })).toBe(false);
    expect(canStartInitialSceneBootstrap({ ...readyInput, hasSelfPosition: false })).toBe(false);
  });
});

describe("describeViewportNotice", () => {
  it("keeps map loading ahead of a stale scene bootstrap loading flag", () => {
    expect(
      describeViewportNotice({
        assetStatus: "ready",
        mapPackStatus: "ready",
        connectionStatus: "connected",
        hasSavedSession: false,
        connectionError: null,
        mapStatus: "loading",
        mapError: null,
        hasMap: false,
        sceneBootstrapStatus: "loading",
        sceneBootstrapError: null
      })
    ).toMatchObject({
      title: "Loading Map",
      tone: "loading"
    });
  });

  it("returns reconnect-ready copy when the player is offline with assets already loaded", () => {
    expect(
      describeViewportNotice({
        assetStatus: "ready",
        mapPackStatus: "ready",
        connectionStatus: "offline",
        hasSavedSession: false,
        connectionError: null,
        mapStatus: "idle",
        mapError: null,
        hasMap: false,
        sceneBootstrapStatus: "idle",
        sceneBootstrapError: null
      })
    ).toMatchObject({
      title: "Ready To Enter",
      tone: "reconnect"
    });
  });

  it("surfaces scene bootstrap failures only after map loading is done", () => {
    expect(
      describeViewportNotice({
        assetStatus: "ready",
        mapPackStatus: "ready",
        connectionStatus: "connected",
        hasSavedSession: false,
        connectionError: null,
        mapStatus: "ready",
        mapError: null,
        hasMap: true,
        sceneBootstrapStatus: "error",
        sceneBootstrapError: "Failed to preload scene asset"
      })
    ).toMatchObject({
      title: "Scene Load Failed",
      tone: "error"
    });
  });
});

describe("describeConnectionIssue", () => {
  it("turns expired reconnect tokens into a specific viewport notice", () => {
    expect(describeConnectionIssue("token expired", true)).toEqual({
      eyebrow: "Access",
      title: "Session expired",
      copy: "The saved reconnect token expired. Sign in again to get a fresh session.",
      tone: "danger"
    });
  });
});
