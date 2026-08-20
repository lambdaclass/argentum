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
  // Windowed, deliberately: this is the size at which the host page's second
  // whole step engages, and the shell should be 2560x1520 inside it rather than
  // the 1280x760 it uses on every smaller display.
  { name: "stepped-4k", width: 3840, height: 2160 },
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

/// Check the asset origin is actually there before opening a browser at all.
///
/// This is the failure that produced twenty-four screenshots of a bare green
/// grid: the game server was down, every asset fetch failed, the client drew its
/// placeholder grid, and the harness waited four seconds and called it loaded.
/// Nothing downstream can recover from a dead origin, so it is worth failing
/// here with the reason rather than later with a picture.
async function preflight(page) {
  const origin = await page.evaluate(
    () =>
      document.querySelector('meta[name="ao:asset-origin"]')?.content || window.location.origin
  );

  const manifestUrl = `${origin}/api/meta/world-pack`;
  // Named explicitly: a bare `fetch failed` from a refused connection is what a
  // dead asset origin looks like, and it is the single most likely reason a
  // capture run is worthless. Say which host and what to start.
  let response;
  try {
    response = await fetch(manifestUrl, { cache: "no-store" });
  } catch (error) {
    throw new Error(
      `cannot reach the asset origin at ${origin} (${error.message}).\n` +
        `The client would draw its placeholder grid and the captures would be ` +
        `worthless. Start the game server: nix develop --command mix phx.server, ` +
        `from server/ — the umbrella root, not apps/arena, or the endpoint that ` +
        `serves /api/meta/world-pack is not loaded.`
    );
  }
  if (!response.ok) {
    throw new Error(
      `${manifestUrl} returned ${response.status}. The asset origin is not serving the ` +
        `world; a capture taken now would be of the placeholder grid.`
    );
  }
  const manifest = await response.json();
  for (const field of ["filename", "hash", "maps"]) {
    if (manifest[field] === undefined) {
      throw new Error(`${manifestUrl} has no ${field}: ${JSON.stringify(manifest)}`);
    }
  }

  // The pack itself and one index, by HEAD: a manifest that names a file the
  // server cannot serve is the same outage one step later.
  for (const path of [`/data/packs/${manifest.filename}`, "/indices/graficos.json"]) {
    const probe = await fetch(`${origin}${path}`, { method: "HEAD", cache: "no-store" });
    if (!probe.ok) {
      throw new Error(`${origin}${path} returned ${probe.status}`);
    }
  }

  return { origin, ...manifest };
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

  // And that the world is painted from the real artwork, which the client
  // reports on `window.aoLoaded`. This replaces a four-second sleep. The
  // distinction that matters is `painted` against `placeholders`: the
  // placeholder grid is present from the first frame and is not evidence of
  // anything, which is exactly why a timer could not tell the difference.
  await page.waitForFunction(
    () => {
      const loaded = window.aoLoaded;
      return loaded && loaded.sheets > 0 && loaded.painted > 0;
    },
    { timeout: 60_000 }
  );

  // A short settle so the visible tiles finish arriving, now that readiness
  // itself is no longer a guess.
  await page.waitForTimeout(1_500);
}

/// The world-map views this task asks to be captured, each with the input that reaches it.
///
/// Steps rather than a list of names: a file called `panned` that nothing panned is
/// mislabelled evidence, and the only way to be sure is to perform the gesture.
function worldMapViews() {
  const centre = async (page) => {
    const box = await page.evaluate(() => {
      const rect = document.getElementById("ao-canvas").getBoundingClientRect();
      return {
        x: rect.x + (window.aoLoaded?.worldX ?? 0) + (window.aoLoaded?.worldW ?? 0) / 2,
        y: rect.y + (window.aoLoaded?.worldY ?? 0) + (window.aoLoaded?.worldH ?? 0) / 2,
      };
    });
    await page.mouse.move(box.x, box.y);
    return box;
  };

  return [
    ["whole-world", async (page) => {
      await page.keyboard.press("Tab");
      await page.waitForTimeout(600);
    }],
    ["zoomed", async (page) => {
      await centre(page);
      for (let i = 0; i < 8; i += 1) {
        await page.mouse.wheel(0, -120);
      }
    }],
    ["panned", async (page) => {
      const box = await centre(page);
      await page.mouse.down();
      for (let step = 1; step <= 6; step += 1) {
        await page.mouse.move(box.x - step * 18, box.y - step * 10);
        await page.waitForTimeout(60);
      }
      await page.mouse.up();
    }],
    ["filtered", async (page) => {
      const rect = await page.evaluate(
        () => (window.aoLoaded?.controls ?? []).find((c) => c.key === "worldmap.filter.merchant")
      );
      if (!rect) return;
      const origin = await page.evaluate(() => {
        const box = document.getElementById("ao-canvas").getBoundingClientRect();
        return { x: box.x, y: box.y };
      });
      await page.mouse.click(origin.x + rect.x + rect.w / 2, origin.y + rect.y + rect.h / 2);
      await page.waitForTimeout(600);
    }],
    ["closed", async (page) => {
      await page.keyboard.press("Escape");
      await page.waitForTimeout(600);
    }],
  ];
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
  const dprMatrix = [];
  let world = null;
  try {
    // Before anything is captured: is the world even being served?
    {
      const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
      const page = await context.newPage();
      await page.goto(url, { waitUntil: "load" });
      world = await preflight(page);
      console.log(`==> world ${world.filename} (${world.maps} maps, hash ${world.hash})`);
      await context.close();
    }

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

      // The map, open across a host-mode change. The overlay is laid out from the world
      // viewport, so maximising with it open is exactly the case where a fixed-size
      // overlay would be left describing the window it was opened in.
      await page.keyboard.press("Tab");
      await page.waitForTimeout(900);
      shots.push(await shoot(page, `${viewport.name}-maximized-map`));

      // And back, which is where a restore that leaves scrollbars shows up.
      await page.evaluate(() => window.aoWindow?.setMode("windowed"));
      await page.waitForTimeout(1_500);
      shots.push(await shoot(page, `${viewport.name}-restored-map`));

      // Closed again, so the pair shows the map went away rather than being covered.
      await page.keyboard.press("Escape");
      await page.waitForTimeout(900);
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

    // The device pixel ratio matrix. Labelled emulated, because it is — but not
    // for the reason this comment used to give.
    //
    // It said winit never observes deviceScaleFactor. That was wrong, and the
    // wrongness mattered: the client reads window.devicePixelRatio, and reading
    // it was how a ratio change came to halve the client's logical window and
    // collapse the character rail (fixed in c99ed51). A note explaining the
    // evidence away would have buried that.
    //
    // What the emulation genuinely cannot show is rasterisation sharpness:
    // headless Chromium composites at 1x, so a sharper backing store would look
    // no different here. These captures therefore prove the layout holds at
    // every ratio, and say nothing about HiDPI crispness. That needs physical
    // high-DPI hardware and stays open on W-0003.
    for (const ratio of [1, 1.25, 1.5, 1.75, 2]) {
      const name = `dpr-${String(ratio).replace(".", "_")}-emulated`;
      console.log(`  ${name}`);
      const context = await browser.newContext({
        viewport: { width: 1280, height: 800 },
        deviceScaleFactor: ratio,
      });
      const page = await context.newPage();
      await page.goto(url, { waitUntil: "load" });
      await waitForClient(page);

      const observed = await page.evaluate(() => {
        const canvas = document.getElementById("ao-canvas");
        return {
          ratio: window.devicePixelRatio,
          css: [canvas.clientWidth, canvas.clientHeight],
          backing: [canvas.width, canvas.height],
        };
      });
      // The canvas must never be a different size than its backing store
      // divided by the ratio the client believes in — that is CSS resampling,
      // which for pixel art is a blur.
      dprMatrix.push({ requested: ratio, ...observed });

      shots.push(await shoot(page, name));

      // The whole-world map at this ratio: the views the task names, in the order a
      // player reaches them. Captured inside the DPR loop rather than once, because the
      // overlay is laid out from the world viewport and that is exactly what a ratio
      // change moves.
      for (const [view, act] of worldMapViews()) {
        await act(page);
        await page.waitForTimeout(600);
        shots.push(await shoot(page, `${name}-map-${view}`));
      }
      await context.close();

      // An unavailable map is a different boot rather than a different frame: the fixture
      // state is configuration, asked for in the URL, so nothing writes into a running
      // client to stage a photograph.
      {
        const offlineContext = await browser.newContext({
          viewport: { width: 1280, height: 800 },
          deviceScaleFactor: ratio,
        });
        const offline = await offlineContext.newPage();
        await offline.goto(`${url}?scenario=disconnected`, { waitUntil: "load" });
        await waitForClient(offline);
        await offline.keyboard.press("Tab");
        await offline.waitForTimeout(900);
        shots.push(await shoot(offline, `${name}-map-unavailable`));
        await offlineContext.close();
      }
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
    // The world these captures are of, so a screenshot can be tied to a map
    // pack as well as to a commit.
    world: world && {
      assetOrigin: world.origin,
      pack: world.filename,
      hash: world.hash,
      maps: world.maps,
    },
    shots: shots.map(({ name, bytes }) => ({ name, bytes })),
    // Recorded rather than asserted: see the note above the DPR loop. Written
    // down so a reader can see what this environment actually reported instead
    // of inferring that the matrix was verified.
    devicePixelRatioMatrix: {
      note:
        "deviceScaleFactor is a Playwright emulation, and the client DOES " +
        "observe it — reading window.devicePixelRatio is how a ratio change " +
        "once halved the logical window (fixed in c99ed51). What the " +
        "emulation cannot show is rasterisation sharpness, because headless " +
        "Chromium composites at 1x. These entries show the layout holding at " +
        "every ratio, not backing-store crispness.",
      observed: dprMatrix,
    },
  };
  writeFileSync(join(outDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`==> ${shots.length} captures in ${outDir}`);
}

main().catch((error) => {
  console.error(`capture failed: ${error.message}`);
  process.exit(1);
});
