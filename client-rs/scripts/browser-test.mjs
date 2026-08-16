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

/// What the page says about its own canvas and overflow.
async function measure(page) {
  return page.evaluate(() => {
    const canvas = document.getElementById("ao-canvas");
    const box = canvas.getBoundingClientRect();
    return {
      cssWidth: box.width,
      cssHeight: box.height,
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
        "canvas fills the content area on first load",
        Math.abs(first.cssWidth - first.innerWidth) <= 1 &&
          Math.abs(first.cssHeight - first.innerHeight) <= 1,
        `canvas ${first.cssWidth}x${first.cssHeight} against window ${first.innerWidth}x${first.innerHeight}`
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
        `canvas follows a resize to ${size.width}x${size.height}`,
        Math.abs(after.cssWidth - after.innerWidth) <= 1 &&
          Math.abs(after.cssHeight - after.innerHeight) <= 1,
        `canvas ${after.cssWidth}x${after.cssHeight} against window ${after.innerWidth}x${after.innerHeight}`
      );
      check(
        `no scrollbars after resize to ${size.width}x${size.height}`,
        !after.scrollsHorizontally && !after.scrollsVertically
      );
    }

    await context.close();

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
        `canvas fills the content area at ${ratio}x`,
        Math.abs(measured.cssWidth - measured.innerWidth) <= 1 &&
          Math.abs(measured.cssHeight - measured.innerHeight) <= 1,
        `canvas ${measured.cssWidth}x${measured.cssHeight} against window ${measured.innerWidth}x${measured.innerHeight}`
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
