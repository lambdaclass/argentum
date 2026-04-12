import { describe, expect, test } from "vitest";
import { browserBasePath, buildBrowserPath, normalizeBrowserRoute } from "./browserRoutes";

describe("browserRoutes", () => {
  test("detects the /client base path", () => {
    expect(browserBasePath("/client")).toBe("/client");
    expect(browserBasePath("/client/ranking")).toBe("/client");
    expect(browserBasePath("/ranking")).toBe("");
  });

  test("normalizes known browser routes", () => {
    expect(normalizeBrowserRoute("/client")).toBe("/");
    expect(normalizeBrowserRoute("/client/create-character")).toBe("/create-character");
    expect(normalizeBrowserRoute("/ranking")).toBe("/ranking");
    expect(normalizeBrowserRoute("/unknown")).toBe("/");
  });

  test("builds paths relative to the current base", () => {
    expect(buildBrowserPath("/", "/client/ranking")).toBe("/client");
    expect(buildBrowserPath("/play", "/client")).toBe("/client/play");
    expect(buildBrowserPath("/ranking", "/")).toBe("/ranking");
  });
});
