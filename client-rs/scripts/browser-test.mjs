// Browser behaviour that cannot be asserted from Rust.
//
// Canvas sizing, page overflow and resize handling live in the browser's layout
// engine, not in the client's arithmetic. A Bevy test can prove the shell
// *computes* the right rectangles; only a browser can prove the canvas it draws
// into is the size the page actually gave it.
//
// Exits non-zero on the first failure, so it can gate a task closure.
//
// Usage, from client-rs:
//   node scripts/browser-test.mjs
//   node scripts/browser-test.mjs --url http://host --any-build

import { chromium } from "../../client/node_modules/playwright-core/index.mjs";
import { execFileSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const clientDir = resolve(here, "..");

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  return at === -1 ? fallback : args[at + 1];
};

const url = flag("url", "http://127.0.0.1:8080");
const skipVersionCheck = args.includes("--any-build");

/// Sizes the task requires, plus a deliberately awkward one.
const VIEWPORTS = [
  { name: "720p", width: 1280, height: 720 },
  { name: "1080p", width: 1920, height: 1080 },
  { name: "1440p", width: 2560, height: 1440 },
  { name: "small-laptop", width: 1024, height: 768 },
  { name: "narrow", width: 900, height: 700 },
];

let failures = 0;

function check(name, condition, detail) {
  if (condition) {
    console.log(`    ok   ${name}`);
  } else {
    console.error(`    FAIL ${name}${detail ? `: ${detail}` : ""}`);
    failures += 1;
  }
}

function headStamp() {
  try {
    return execFileSync("bash", [join(here, "build-stamp.sh")], {
      cwd: clientDir,
      encoding: "utf8",
    }).trim();
  } catch {
    return null;
  }
}

async function waitForClient(page) {
  await page.waitForSelector("#ao-canvas", { timeout: 30_000 });
  await page.waitForFunction(() => document.getElementById("boot")?.hidden === true, {
    timeout: 60_000,
  });
  await page.waitForFunction(
    () => {
      const canvas = document.getElementById("ao-canvas");
      return canvas instanceof HTMLCanvasElement && canvas.width > 0 && canvas.height > 0;
    },
    { timeout: 30_000 }
  );
  await page.waitForTimeout(2_000);
}

/// The client's bounded playing size, from web/index.html.
///
/// The canvas fills the content area only while the content area is smaller
/// than this; beyond it the client is a centred window with fullscreen
/// available. An unbounded canvas on a wide browser made every element enormous
/// for no gain.
const DESIGN = { width: 1280, height: 760 };

/// Whether the client is the smaller of the playing size and the window.
function fitsWindow(m) {
  return (
    Math.abs(m.shellWidth - Math.min(DESIGN.width, m.innerWidth)) <= 1 &&
    Math.abs(m.shellHeight - Math.min(DESIGN.height, m.innerHeight)) <= 1
  );
}

/// Whether the canvas fills the client, allowing for its decorative border.
///
/// The border is drawn inside the shell, so the canvas is a couple of pixels
/// smaller than the shell's outer box. That is correct, and measuring the
/// canvas against the *window* reported it as a two-pixel shortfall.
function fillsShell(m) {
  const border = 2;
  return (
    m.shellWidth - m.cssWidth <= border + 1 &&
    m.shellHeight - m.cssHeight <= border + 1 &&
    m.cssWidth > 0 &&
    m.cssHeight > 0
  );
}

/// What the page says about its own canvas and overflow.
async function measure(page) {
  return page.evaluate(() => {
    const canvas = document.getElementById("ao-canvas");
    const shell = document.getElementById("shell");
    const box = canvas.getBoundingClientRect();
    const shellBox = shell.getBoundingClientRect();
    return {
      cssWidth: box.width,
      cssHeight: box.height,
      shellWidth: shellBox.width,
      shellHeight: shellBox.height,
      backingWidth: canvas.width,
      backingHeight: canvas.height,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      ratio: window.devicePixelRatio,
      scrollsHorizontally: document.documentElement.scrollWidth > window.innerWidth,
      scrollsVertically: document.documentElement.scrollHeight > window.innerHeight,
    };
  });
}

async function main() {
  if (!skipVersionCheck) {
    const head = headStamp();
    const response = await fetch(`${url}/pkg/build-id.txt`, { cache: "no-store" });
    const served = (await response.text()).trim();
    if (head && head !== served) {
      throw new Error(`the server is serving ${served} but HEAD is ${head}; run ./build.sh first`);
    }
    console.log(`==> testing build ${served}`);
  }

  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM ?? "chromium",
    args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"],
  });

  try {
    for (const viewport of VIEWPORTS) {
      console.log(`  ${viewport.name} (${viewport.width}x${viewport.height})`);
      const context = await browser.newContext({
        viewport: { width: viewport.width, height: viewport.height },
        deviceScaleFactor: 1,
      });
      const page = await context.newPage();
      await page.goto(url, { waitUntil: "load" });
      await waitForClient(page);

      const first = await measure(page);
      check(
        "the client is the content area bounded by the playing size",
        fitsWindow(first),
        `shell ${first.shellWidth}x${first.shellHeight} against window ${first.innerWidth}x${first.innerHeight}`
      );
      check(
        "the canvas fills the client",
        fillsShell(first),
        `canvas ${first.cssWidth}x${first.cssHeight} inside shell ${first.shellWidth}x${first.shellHeight}`
      );
      check(
        "the page does not scroll",
        !first.scrollsHorizontally && !first.scrollsVertically,
        JSON.stringify({ x: first.scrollsHorizontally, y: first.scrollsVertically })
      );
      await context.close();
    }

    // Resizing while running is the case a fixed layout survives by accident.
    console.log("  resize while running");
    const context = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      deviceScaleFactor: 1,
    });
    const page = await context.newPage();
    await page.goto(url, { waitUntil: "load" });
    await waitForClient(page);

    for (const size of [
      { width: 1920, height: 1080 },
      { width: 1024, height: 768 },
      { width: 1600, height: 900 },
    ]) {
      await page.setViewportSize(size);
      await page.waitForTimeout(1_200);
      const after = await measure(page);
      check(
        `client follows a resize to ${size.width}x${size.height}`,
        fitsWindow(after) && fillsShell(after),
        `shell ${after.shellWidth}x${after.shellHeight}, canvas ${after.cssWidth}x${after.cssHeight}, window ${after.innerWidth}x${after.innerHeight}`
      );
      check(
        `no scrollbars after resize to ${size.width}x${size.height}`,
        !after.scrollsHorizontally && !after.scrollsVertically
      );
    }

    await context.close();

    // Host modes: windowed, maximized, fullscreen and back.
    console.log("  host modes");
    {
      const modeContext = await browser.newContext({
        viewport: { width: 1600, height: 900 },
        deviceScaleFactor: 1,
      });
      const modePage = await modeContext.newPage();
      await modePage.goto(url, { waitUntil: "load" });
      await waitForClient(modePage);

      const windowed = await measure(modePage);
      check(
        "windowed is the bounded playing size",
        fitsWindow(windowed),
        `shell ${windowed.shellWidth}x${windowed.shellHeight} in ${windowed.innerWidth}x${windowed.innerHeight}`
      );
      check(
        "windowed is smaller than the viewport it sits in",
        windowed.shellWidth < windowed.innerWidth,
        `shell ${windowed.shellWidth} against window ${windowed.innerWidth}`
      );

      const reached = await modePage.evaluate(() => window.aoWindow.setMode("maximized"));
      await modePage.waitForTimeout(1_200);
      const maximized = await measure(modePage);
      check("maximize is reported as reached", reached === "maximized", `got ${reached}`);
      check(
        "maximize fills the browser content area",
        Math.abs(maximized.shellWidth - maximized.innerWidth) <= 1 &&
          Math.abs(maximized.shellHeight - maximized.innerHeight) <= 1,
        `shell ${maximized.shellWidth}x${maximized.shellHeight} against window ${maximized.innerWidth}x${maximized.innerHeight}`
      );
      check(
        "the canvas followed the host into maximize",
        fillsShell(maximized),
        `canvas ${maximized.cssWidth}x${maximized.cssHeight} in shell ${maximized.shellWidth}x${maximized.shellHeight}`
      );
      check(
        "maximize does not scroll the page",
        !maximized.scrollsHorizontally && !maximized.scrollsVertically
      );

      // Fullscreen needs a user gesture. Automation has none, so the adapter is
      // expected to report the fallback it actually reached rather than
      // claiming success — which is the behaviour worth testing here.
      const fullscreenResult = await modePage.evaluate(() =>
        window.aoWindow.setMode("fullscreen")
      );
      check(
        "a refused fullscreen reports the mode actually reached",
        fullscreenResult === "fullscreen" || fullscreenResult === "maximized",
        `got ${fullscreenResult}`
      );

      await modePage.evaluate(() => window.aoWindow.setMode("windowed"));
      await modePage.waitForTimeout(1_200);
      const restored = await measure(modePage);
      check(
        "restore returns to the bounded window",
        fitsWindow(restored) && restored.shellWidth < restored.innerWidth,
        `shell ${restored.shellWidth}x${restored.shellHeight} in ${restored.innerWidth}x${restored.innerHeight}`
      );
      check(
        "restore leaves no scrollbars",
        !restored.scrollsHorizontally && !restored.scrollsVertically
      );
      check(
        "restore returns to exactly the size it started at",
        Math.abs(restored.shellWidth - windowed.shellWidth) <= 1 &&
          Math.abs(restored.shellHeight - windowed.shellHeight) <= 1,
        `restored ${restored.shellWidth}x${restored.shellHeight}, started ${windowed.shellWidth}x${windowed.shellHeight}`
      );
      check(
        "the host reports itself windowed again",
        (await modePage.evaluate(() => window.aoWindow.getMode())) === "windowed"
      );

      await modeContext.close();
    }

    // Device pixel ratio is checked only for "the client still works", not for
    // rasterization sharpness.
    //
    // Playwright's deviceScaleFactor is an emulation: it changes
    // window.devicePixelRatio, but headless Chromium composites at 1x and winit
    // does not observe the emulated value. Measured here, the canvas backing
    // store stays at CSS size for every ratio, which is indistinguishable from
    // a genuine bug in how the client sizes it. Asserting either way from this
    // environment would be inventing evidence.
    //
    // Verifying that the backing store follows a *real* device pixel ratio
    // needs a physical high-DPI display, and is recorded as an environment
    // limitation on W-0003 rather than silently passed here.
    for (const ratio of [1.25, 1.5, 2]) {
      console.log(`  device pixel ratio ${ratio} (emulated)`);
      const dprContext = await browser.newContext({
        viewport: { width: 1280, height: 720 },
        deviceScaleFactor: ratio,
      });
      const dprPage = await dprContext.newPage();
      await dprPage.goto(url, { waitUntil: "load" });
      await waitForClient(dprPage);

      const measured = await measure(dprPage);
      check(
        `client is correctly sized at ${ratio}x`,
        fitsWindow(measured) && fillsShell(measured),
        `shell ${measured.shellWidth}x${measured.shellHeight}, canvas ${measured.cssWidth}x${measured.cssHeight}, window ${measured.innerWidth}x${measured.innerHeight}`
      );
      check(`no scrollbars at ${ratio}x`, !measured.scrollsHorizontally && !measured.scrollsVertically);
      await dprContext.close();
    }
  } finally {
    await browser.close();
  }

  if (failures > 0) {
    console.error(`\n${failures} browser check(s) failed`);
    process.exit(1);
  }
  console.log("\nall browser checks passed");
}

main().catch((error) => {
  console.error(`browser test failed: ${error.message}`);
  process.exit(1);
});
