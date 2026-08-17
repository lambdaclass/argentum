// Capture the running client in a real browser.
//
// This exists because "it compiles and the tests pass" has repeatedly not been
// the same thing as "it works". Every layout fault found so far — the rail off
// the right-hand edge, the whole shell clipped by one camera's viewport, the
// grid wrapping at five columns, empty boxes where Spanish should be — was
// invisible to the unit tests and obvious in a screenshot.
//
// Two rules it enforces so a capture can be trusted as evidence:
//
//   1. The build the browser loaded must be the commit under discussion. A
//      screenshot of a stale bundle is worse than none, because it is used to
//      argue that something is or is not fixed.
//   2. The boot overlay must be gone and the canvas presenting, or the capture
//      is of a loading screen.
//
// Usage, from client-rs:
//   node scripts/capture.mjs                     # every viewport
//   node scripts/capture.mjs --out captures/x    # somewhere else
//   node scripts/capture.mjs --url http://host   # a different server

import { chromium } from "../../client/node_modules/playwright-core/index.mjs";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
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
const outDir = resolve(flag("out", join(clientDir, "captures")));
const skipVersionCheck = args.includes("--any-build");

/// Viewports the roadmap names as targets, plus the smallest supported size.
const VIEWPORTS = [
  { name: "720p", width: 1280, height: 720 },
  { name: "1080p", width: 1920, height: 1080 },
  { name: "1440p", width: 2560, height: 1440 },
  { name: "small-laptop", width: 1024, height: 768 },
];

/// The rail's compact breakpoint, in logical pixels of window width.
///
/// Derived from the same constants the client uses, not pasted: the world
/// gives up WORLD_MIN_WIDTH once the rail has taken its clamped share, and at
/// this width the rail is at its RAIL_MIN_WIDTH floor.
/// Written as a literal, and checked against the client's own constants by
/// `the_capture_harness_targets_the_real_breakpoint_and_minimum` in layout.rs —
/// which is what keeps it honest. Recomputing the arithmetic here would only
/// duplicate the derivation, not the value it has to agree with.
const RAIL_BREAKPOINT = 920;

/// The smallest window the client claims to support: the whole area of interest
/// beside a compact rail, under the top bar. Checked by the same test.
const MINIMUM_SUPPORTED_WIDTH = 792;
const MINIMUM_SUPPORTED_HEIGHT = 638;

/// Sizes where the layout is meant to change character rather than just scale.
///
/// The two breakpoint shots are one pixel apart on purpose: side by side they
/// are the evidence that the mode change is a deliberate transition and not a
/// rail that has silently fallen off the edge. `maximize` is set where the
/// windowed shell would clamp to its 1280px default and never reach the size
/// under test at all — an "ultrawide" capture of a 1280px shell proves nothing.
///
/// `client` sizes are the window the *client* sees, not the browser viewport.
/// The shell is inset from the viewport by its border, so a 921px viewport gives
/// the client a 919px window — which is on the other side of the breakpoint.
/// The first pass at these captures got exactly that wrong and produced two
/// identical compact shells labelled "minus 1" and "plus 1".
const RESPONSIVE = [
  { name: "breakpoint-minus-1", client: { width: RAIL_BREAKPOINT - 1 } },
  { name: "breakpoint-plus-1", client: { width: RAIL_BREAKPOINT + 1 } },
  {
    name: "minimum-supported",
    client: { width: MINIMUM_SUPPORTED_WIDTH, height: MINIMUM_SUPPORTED_HEIGHT },
  },
  { name: "ultrawide", width: 3440, height: 1440, maximize: true },
  { name: "short-window", client: { height: 560 } },
];

/// How much wider the browser viewport has to be than the window the client gets.
///
/// Measured rather than assumed: the host page owns its own border and padding,
/// and a capture that silently lands on the wrong side of a breakpoint is worse
/// than no capture, because it is filed as evidence that the boundary was
/// inspected.
async function measureChrome(browser, url) {
  // Below the shell's own 1280x760 windowed clamp on both axes, or the clamp is
  // measured as chrome and every derived viewport is wrong by the difference.
  const probe = 700;
  const context = await browser.newContext({
    viewport: { width: probe, height: probe },
    deviceScaleFactor: 1,
  });
  const page = await context.newPage();
  await page.goto(url, { waitUntil: "load" });
  await page.waitForSelector("#ao-canvas");
  const size = await page.evaluate(() => {
    const canvas = document.getElementById("ao-canvas");
    return { width: canvas.clientWidth, height: canvas.clientHeight };
  });
  await context.close();
  return { width: probe - size.width, height: probe - size.height };
}

function headStamp() {
  // The same rule build.sh uses, from the same script — computing it a third
  // time here is how the capture harness starts disagreeing with the build it
  // is supposed to be verifying.
  try {
    return execFileSync("bash", [join(here, "build-stamp.sh")], {
      cwd: clientDir,
      encoding: "utf8",
    }).trim();
  } catch {
    return null;
  }
}

async function servedStamp() {
  const response = await fetch(`${url}/pkg/build-id.txt`, { cache: "no-store" });
  if (!response.ok) throw new Error(`no build id at ${url} (${response.status})`);
  return (await response.text()).trim();
}

/// Wait until the client is actually presenting, not merely loaded.
async function waitForClient(page) {
  await page.waitForSelector("#ao-canvas", { timeout: 30_000 });
  // The boot overlay hides itself two animation frames after init resolves.
  await page.waitForFunction(() => document.getElementById("boot")?.hidden === true, {
    timeout: 60_000,
  });
  // A canvas with no backing store has loaded but drawn nothing.
  await page.waitForFunction(
    () => {
      const canvas = document.getElementById("ao-canvas");
      return canvas instanceof HTMLCanvasElement && canvas.width > 0 && canvas.height > 0;
    },
    { timeout: 30_000 }
  );
  // Map data and texture sheets arrive over HTTP; without this the capture is
  // of an empty world that has technically finished booting.
  await page.waitForTimeout(4_000);
}

async function shoot(page, name) {
  const file = join(outDir, `${name}.png`);
  await page.screenshot({ path: file });
  const bytes = (await page.screenshot()).length;
  console.log(`    ${name.padEnd(28)} ${String(bytes).padStart(8)} bytes`);
  return { name, file, bytes };
}

async function main() {
  const head = headStamp();
  const served = await servedStamp();

  if (!skipVersionCheck) {
    if (!head) throw new Error("no git identity; pass --any-build to capture anyway");
    if (head !== served) {
      throw new Error(
        `the server is serving ${served} but HEAD is ${head}.\n` +
          `A capture of a stale build cannot be used as evidence. Run ./build.sh first.`
      );
    }
  }
  console.log(`==> capturing build ${served}`);

  mkdirSync(outDir, { recursive: true });

  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM ?? "chromium",
    args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"],
  });

  const shots = [];
  try {
    for (const viewport of VIEWPORTS) {
      console.log(`  ${viewport.name} (${viewport.width}x${viewport.height})`);
      const context = await browser.newContext({
        viewport: { width: viewport.width, height: viewport.height },
        deviceScaleFactor: 1,
      });
      const page = await context.newPage();
      page.on("pageerror", (error) => console.error(`    page error: ${error.message}`));

      await page.goto(url, { waitUntil: "load" });
      await waitForClient(page);
      shots.push(await shoot(page, `${viewport.name}-windowed`));

      // Maximised: the host mode a player reaches from the top bar. Not
      // fullscreen, which needs a user gesture automation cannot supply.
      await page.evaluate(() => window.aoWindow?.setMode("maximized"));
      await page.waitForTimeout(1_500);
      shots.push(await shoot(page, `${viewport.name}-maximized`));

      // And back, which is where a restore that leaves scrollbars shows up.
      await page.evaluate(() => window.aoWindow?.setMode("windowed"));
      await page.waitForTimeout(1_500);
      shots.push(await shoot(page, `${viewport.name}-restored`));

      const overflow = await page.evaluate(() => ({
        horizontal: document.documentElement.scrollWidth > window.innerWidth,
        vertical: document.documentElement.scrollHeight > window.innerHeight,
      }));
      if (overflow.horizontal || overflow.vertical) {
        throw new Error(`${viewport.name}: the page scrolls after restore (${JSON.stringify(overflow)})`);
      }

      await context.close();
    }

    // Sizes where the layout changes character. No maximise/restore cycle —
    // these are about what the shell does at the size, not about host modes.
    const chrome = await measureChrome(browser, url);
    console.log(`  host chrome: ${chrome.width}x${chrome.height}px around the client window`);

    for (const size of RESPONSIVE) {
      // Only the axes a capture actually constrains are derived from a client
      // size; the rest keep a roomy default. The shell clamps at 1280x760
      // before its border, so a client window of exactly 1280 or 760 on that
      // axis is not reachable at all — asking for one is a mistake worth an
      // error, not a silent near miss.
      const viewport = {
        width: size.client?.width ? size.client.width + chrome.width : (size.width ?? 1400),
        height: size.client?.height ? size.client.height + chrome.height : (size.height ?? 900),
      };
      console.log(`  ${size.name} (${viewport.width}x${viewport.height})`);
      const context = await browser.newContext({ viewport, deviceScaleFactor: 1 });
      const page = await context.newPage();
      page.on("pageerror", (error) => console.error(`    page error: ${error.message}`));

      await page.goto(url, { waitUntil: "load" });
      await waitForClient(page);
      if (size.maximize) {
        await page.evaluate(() => window.aoWindow?.setMode("maximized"));
        await page.waitForTimeout(1_500);
      }

      // The whole point of the breakpoint pair is that the two shots sit on
      // opposite sides of one pixel. If the client did not get the width this
      // capture is named after, the file is mislabelled evidence.
      if (size.client) {
        const actual = await page.evaluate(() => {
          const canvas = document.getElementById("ao-canvas");
          return { width: canvas.clientWidth, height: canvas.clientHeight };
        });
        for (const axis of ["width", "height"]) {
          if (size.client[axis] && actual[axis] !== size.client[axis]) {
            throw new Error(
              `${size.name}: asked for a client ${axis} of ${size.client[axis]}, ` +
                `got ${actual[axis]}`
            );
          }
        }
      }

      shots.push(await shoot(page, size.name));

      // "No application panel requires page scrolling" — at the minimum
      // supported size this is the assertion that the claim is real, and it is
      // exactly where a layout that merely looks fine at 1080p gives way.
      const overflow = await page.evaluate(() => ({
        horizontal: document.documentElement.scrollWidth > window.innerWidth,
        vertical: document.documentElement.scrollHeight > window.innerHeight,
      }));
      if (overflow.horizontal || overflow.vertical) {
        throw new Error(`${size.name}: the page scrolls (${JSON.stringify(overflow)})`);
      }

      await context.close();
    }

    // A resize while running, which is the case a fixed-size layout survives
    // by accident and a responsive one has to handle.
    console.log("  resize 1280x720 -> 1920x1080");
    const context = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      deviceScaleFactor: 1,
    });
    const page = await context.newPage();
    await page.goto(url, { waitUntil: "load" });
    await waitForClient(page);
    await page.setViewportSize({ width: 1920, height: 1080 });
    await page.waitForTimeout(1_500);
    shots.push(await shoot(page, "resized-1280-to-1920"));
    await context.close();
  } finally {
    await browser.close();
  }

  const manifest = {
    build: served,
    capturedFrom: url,
    shots: shots.map(({ name, bytes }) => ({ name, bytes })),
  };
  writeFileSync(join(outDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`==> ${shots.length} captures in ${outDir}`);
}

main().catch((error) => {
  console.error(`capture failed: ${error.message}`);
  process.exit(1);
});
