import { describe, expect, it } from "vitest";
import { isNonFatalBrowserPayload, isOpaqueCrossOriginError } from "./fatalErrors";

describe("isOpaqueCrossOriginError", () => {
  // A cross-origin script or media failure is reported as "Script error." with
  // no error object, no filename and position 0:0. It used to reach
  // renderFatalBootScreen, which replaces the mount node's innerHTML — ending a
  // live play session over something that says nothing about our code. The
  // client provokes this routinely by probing audio on the gateway origin.
  it("recognises the browser's opaque cross-origin report", () => {
    expect(
      isOpaqueCrossOriginError({
        message: "Script error.",
        error: null,
        filename: "",
        lineno: 0,
        colno: 0
      })
    ).toBe(true);
  });

  it("treats a real application error as fatal", () => {
    expect(
      isOpaqueCrossOriginError({
        message: "Cannot read properties of undefined",
        error: new TypeError("Cannot read properties of undefined"),
        filename: "http://localhost:4000/client/assets/index.js",
        lineno: 412,
        colno: 19
      })
    ).toBe(false);
  });

  it("treats a same-origin error with a position as fatal even without an error object", () => {
    expect(
      isOpaqueCrossOriginError({
        message: "boom",
        error: null,
        filename: "http://localhost:4000/client/assets/index.js",
        lineno: 12,
        colno: 3
      })
    ).toBe(false);
  });

  it("does not classify on message text alone", () => {
    // Same wording, but it carries a real stack — not the opaque report.
    expect(
      isOpaqueCrossOriginError({
        message: "Script error.",
        error: new Error("Script error."),
        filename: "http://localhost:4000/client/assets/index.js",
        lineno: 5,
        colno: 1
      })
    ).toBe(false);
  });
});

describe("isNonFatalBrowserPayload", () => {
  it("treats a resource-load style payload as non-fatal", () => {
    expect(isNonFatalBrowserPayload({ isTrusted: true })).toBe(true);
  });

  it("treats a thrown Error as fatal", () => {
    expect(isNonFatalBrowserPayload(new Error("real failure"))).toBe(false);
  });

  it("treats a plain string as fatal", () => {
    expect(isNonFatalBrowserPayload("some failure")).toBe(false);
  });
});
