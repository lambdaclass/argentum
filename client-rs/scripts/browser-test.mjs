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

/// Run one section instead of all of them.
///
/// `--only hits` runs the pointer battery alone. The whole suite takes the better part
/// of an hour under software rendering, and iterating on one question at that cost is
/// how a harness stops being run at all.
const only = flag("only", null);
const SECTIONS = ["layout", "hits"];
if (only && !SECTIONS.includes(only)) {
  throw new Error(`--only takes one of ${SECTIONS.join(", ")}`);
}
const runs = (section) => !only || only === section;

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

/// Whole design-sized steps that fit a viewport. Mirrors the host page, and
/// `the_host_page_steps_the_window_the_way_this_harness_expects` compares the
/// two against each other rather than trusting that they agree.
const MARGIN = 0.94;
function steps(innerWidth, innerHeight) {
  const fit = Math.min((innerWidth * MARGIN) / DESIGN.width, (innerHeight * MARGIN) / DESIGN.height);
  return Math.max(1, Math.floor(fit));
}

/// Whether the client is the smaller of its stepped playing size and the window.
function fitsWindow(m) {
  const step = steps(m.innerWidth, m.innerHeight);
  return (
    Math.abs(m.shellWidth - Math.min(DESIGN.width * step, m.innerWidth)) <= 1 &&
    Math.abs(m.shellHeight - Math.min(DESIGN.height * step, m.innerHeight)) <= 1
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


/// Click-accuracy checks against the client's published geometry.
///
/// Takes the page rather than building one, so the same checks run at every device
/// pixel ratio and in both reachable host modes.
async function runHitTests(hitPage, label, ratio) {
    const canvasBox = await hitPage.evaluate(() => {
      const box = document.getElementById("ao-canvas").getBoundingClientRect();
      return { x: box.x, y: box.y };
    });
    // Polled, because the grid is built as the snapshot and geometry settle and at a
    // device pixel ratio of 2 this software renderer takes seconds to get there.
    // Read once, immediately after boot, the list was sometimes published before the
    // inventory existed — and the test then reported a missing control as a client
    // fault rather than as its own impatience.
    const wanted = ["inventory.slot.0", "hotbar.slot.0"];
    let controls = [];
    const controlsDeadline = Date.now() + 20_000;
    while (Date.now() < controlsDeadline) {
      controls = await hitPage.evaluate(() => window.aoLoaded?.controls ?? []);
      const laidOut = wanted.every((key) =>
        controls.some((c) => c.key === key && c.w > 4 && c.h > 4)
      );
      if (laidOut) break;
      await hitPage.waitForTimeout(100);
    }
    check(`${label}: `+"the client publishes its control rectangles", controls.length > 0, `${controls.length}`);

    /// Wait until the client is running steadily, not merely loaded.
    ///
    /// Controls appear as soon as the panels are laid out, but at that point the client
    /// is still decoding sheets and a frame can take seconds. A click then activates
    /// correctly and republishes after the probe's budget has expired, so the *next*
    /// probe reads it — which is how a click one pixel outside a control came to
    /// "activate" it while the same click, measured in isolation, behaved perfectly.
    /// Measured against the published frame counter rather than a sleep, because the
    /// speed of a software renderer on a loaded machine is not a constant. The budget a
    /// click is then given is derived from that measurement rather than fixed: this
    /// renderer manages three frames a second at ratio 1 and under one at ratio 2, so a
    /// fixed rate is a requirement about the machine, not about the client. Twenty
    /// frames is the budget either way — enough for a click to be seen, pressed,
    /// released, applied and republished several times over.
    const frames = () => hitPage.evaluate(() => window.aoLoaded?.frames ?? 0);
    const SAMPLE_MS = 3_000;
    let frameMs = SAMPLE_MS;
    const readyDeadline = Date.now() + 45_000;
    while (Date.now() < readyDeadline) {
      const first = await frames();
      await hitPage.waitForTimeout(SAMPLE_MS);
      const advanced = (await frames()) - first;
      // Zero frames in the sample means slower than the sample, not stopped: charge it
      // one frame so the budget is finite and the floor below can judge it.
      frameMs = SAMPLE_MS / Math.max(advanced, 1);
      if (advanced >= 2) break;
    }
    // A frame slower than this makes the timing meaningless rather than the client
    // wrong, and saying so is the point: a failure here is about the machine.
    const SLOWEST_USABLE_FRAME_MS = 3_000;
    const CLICK_BUDGET_MS = Math.min(Math.max(20 * frameMs, 10_000), 60_000);
    // Six frames. Measured: an activation is published within one to three frames of
    // the release, so a control that has not answered in six did not answer.
    const NEGATIVE_BUDGET_MS = Math.min(Math.max(6 * frameMs, 3_000), 20_000);
    check(
      `${label}: `+"the client renders fast enough to time a click against",
      frameMs <= SLOWEST_USABLE_FRAME_MS,
      `${frameMs.toFixed(0)}ms per frame, clicks allowed ${(CLICK_BUDGET_MS / 1000).toFixed(0)}s`
    );

    /// Click a point in canvas coordinates and report what activated, if anything.
    ///
    /// Compares the activation *counter* before and after rather than reading the
    /// last key: the client republishes its report every frame, so the previous
    /// activation is still there and every "this must not activate" check would
    /// pass or fail on stale data. Clearing the field from here achieved nothing —
    /// it is the client's resource that holds it.
    /// The control's rectangle as of right now.
    ///
    /// Re-read before every click rather than sampled once. Selecting a slot rebuilds
    /// the panel, which respawns its entities, so a cached rectangle can describe a
    /// control that no longer exists — and clicks then land a couple of pixels out,
    /// which reads as a hit-testing fault in the client rather than as a stale
    /// measurement in the test.
    const rectOf = async (key) =>
      hitPage.evaluate(
        (wanted) => (window.aoLoaded?.controls ?? []).find((c) => c.key === wanted) ?? null,
        key
      );

    /// The same, waiting for a control that is on its way.
    ///
    /// A panel that has just been switched to is rebuilt a frame or two after the click
    /// that asked for it, and at half a frame a second that is seconds away. Read once,
    /// the spellbook looked empty — which is this harness's impatience reported as a
    /// missing control.
    const rectSoon = async (key) => {
      const deadline = Date.now() + Math.max(10 * frameMs, 5_000);
      while (Date.now() < deadline) {
        const rect = await rectOf(key);
        if (rect && rect.w > 4 && rect.h > 4) {
          return rect;
        }
        await hitPage.waitForTimeout(100);
      }
      return null;
    };

    /// Wait until no activation has arrived for a moment.
    ///
    /// Without this, a click whose activation lands after its own probe gave up is
    /// counted against the *next* probe — so a click one pixel outside a control
    /// "activated" it, using the previous click's result. The failures that produced
    /// were real observations of the wrong thing: measured in isolation, every one of
    /// those clicks behaved correctly.
    /// The gap between reads is a frame and a half, not a fixed 150ms: two reads inside
    /// one frame cannot see a counter move, so at one frame a second "quiet" meant
    /// nothing at all and an activation still in flight was charged to the next probe —
    /// which reported a hit one pixel outside a control after 1ms, from a click that had
    /// happened before it.
    const settle = async () => {
      const gap = Math.max(1.5 * frameMs, 200);
      let last = -1;
      for (let attempt = 0; attempt < 40; attempt += 1) {
        const now = await hitPage.evaluate(() => window.aoLoaded?.activations ?? 0);
        if (now === last) return now;
        last = now;
        await hitPage.waitForTimeout(gap);
      }
      return last;
    };

    /// Put the pointer somewhere and wait until the client agrees it is there.
    ///
    /// The published pointer position is the client's own answer to "where is the
    /// cursor", so this is the only way to know a subsequent press will be attributed
    /// to the right place rather than to wherever the pointer was last frame.
    /// `expectKey` is the control the caller is aiming at, when there is one. The
    /// pointer's *position* is not enough: the client can report the cursor where it was
    /// put and not yet have that control under it, and the first click of a
    /// configuration then landed on nothing while every click after it worked. Waiting
    /// for the client to say the control is hovered is waiting for the thing the click
    /// actually depends on.
    const pointerTo = async (x, y, expectKey = null) => {
      await hitPage.mouse.move(canvasBox.x + x, canvasBox.y + y);
      const deadline = Date.now() + Math.max(8 * frameMs, 5_000);
      while (Date.now() < deadline) {
        const at = await hitPage.evaluate(() => ({
          x: window.aoLoaded?.pointerX,
          y: window.aoLoaded?.pointerY,
          hovered: window.aoLoaded?.hovered ?? [],
        }));
        const there =
          typeof at.x === "number" && Math.abs(at.x - x) <= 1.5 && Math.abs(at.y - y) <= 1.5;
        if (there && (!expectKey || at.hovered.includes(expectKey))) {
          return true;
        }
        await hitPage.waitForTimeout(50);
      }
      return false;
    };

    /// Click a point in canvas coordinates and report what activated, if anything.
    ///
    /// `budget` is how long to wait for an answer. A probe that expects an activation
    /// waits generously, because a missed one would be charged to the client. A probe
    /// that expects *nothing* waits only a few frames: it is conclusive as soon as the
    /// client has had time to answer, and giving every negative probe the full budget
    /// made a single configuration at ratio 2 take half an hour — which is its own kind
    /// of wrong answer, since nobody runs a suite that slow often enough to trust it.
    const clickAt = async (x, y, budget = CLICK_BUDGET_MS, expectKey = null) => {
      const before = await settle();

      // Moved, seen, then pressed — not `mouse.click`, which delivers move, press and
      // release within a few milliseconds. At one frame a second, which is what this
      // software renderer manages at a device pixel ratio of 1.5, all three arrive in
      // a single frame: the press is then attributed using a hover map computed before
      // the pointer had moved, so the click belongs to nothing and vanishes. A player
      // moves the cursor, sees the control light up, and only then presses.
      const arrived = await pointerTo(x, y, expectKey);
      await hitPage.mouse.down();
      await hitPage.waitForTimeout(Math.min(Math.max(frameMs, 60), 1_500));
      await hitPage.mouse.up();
      if (!arrived) {
        return {
          key: null,
          ms: 0,
          before,
          after: before,
          note: expectKey
            ? `the client never reported ${expectKey} under the pointer`
            : "the client never saw the pointer arrive",
        };
      }

      // Polled, not slept. Under software rendering this client runs at about six
      // frames a second, so a fixed 120ms wait was shorter than a single frame and
      // every click "did not activate" — the same mistake as the capture harness's
      // four-second sleep, in the other direction. A deadline instead: the answer
      // arrives when it arrives, and only a genuine non-activation waits out the
      // whole budget.
      // Ten seconds, not three. Measured: at a device pixel ratio of 2 this
      // software renderer takes about 2.4 seconds to process a click and republish,
      // and the suite's pages are busier than a bare probe. The loop returns as
      // soon as the counter moves, so a fast click costs nothing and only a genuine
      // non-activation waits out the budget.
      // Reports the measurement alongside the answer. A bare null cannot distinguish
      // "nothing activated" from "the activation arrived after we gave up", and those
      // are opposite faults: the first is the client hit-testing correctly, the second
      // is this harness being impatient and mis-attributing the result to the next
      // probe.
      const started = Date.now();
      const deadline = started + budget;
      while (Date.now() < deadline) {
        const now = await hitPage.evaluate(() => ({
          count: window.aoLoaded?.activations ?? 0,
          key: window.aoLoaded?.lastActivated ?? null,
        }));
        if (now.count > before) {
          // Kept watching for three more frames. This task requires that the expected
          // entity activates *exactly once*, and a second activation arrives a frame
          // or two after the first — the whole shape of the double-activation bug was
          // that the extra one appeared too late for the probe that caused it and was
          // charged to the next. Returning at the first sight of movement is how a
          // click that fired twice reads as a click that fired.
          await hitPage.waitForTimeout(Math.min(Math.max(3 * frameMs, 200), 6_000));
          const settled = await hitPage.evaluate(() => ({
            count: window.aoLoaded?.activations ?? 0,
            key: window.aoLoaded?.lastActivated ?? null,
            recent: window.aoLoaded?.recentActivations ?? "",
          }));
          return {
            key: settled.count > now.count ? settled.key : now.key,
            ms: Date.now() - started,
            before,
            after: settled.count,
            // Carried into the failure message: two activations from one entity and two
            // from two entities are opposite faults.
            note: settled.count - before === 1 ? undefined : `recent: ${settled.recent}`,
          };
        }
        await hitPage.waitForTimeout(50);
      }
      return { key: null, ms: Date.now() - started, before, after: before };
    };

    /// How a click came out, for a failure message.
    const shown = (at, result) =>
      `at ${at.map((v) => v.toFixed(1)).join(",")} -> ${result.key ?? "nothing"}` +
      ` after ${result.ms}ms (${result.before}->${result.after})` +
      (result.note ? ` — ${result.note}` : "");

    // A representative spread rather than every control: four different panels, four
    // different sizes and four different builders. The top-bar icon goes last, because
    // activating it is the one that may put something else on screen.
    //
    // Spell and dialog controls are named in this task's contract and are absent from
    // the sample because they do not exist yet — the spellbook is W-0007 and dialogs
    // are W-0009. Missing keys are reported rather than dropped: a sample that quietly
    // shrinks to one control still passes a "sample is available" check.
    // The compact navigation strip exists only in the compact rail — in the full rail
    // those actions live in the top bar — so which controls *ought* to be present
    // depends on the mode the shell chose, which it publishes rather than this harness
    // re-deriving the breakpoint.
    const compactRail = await hitPage.evaluate(() => window.aoLoaded?.railCompact === true);
    const WANTED_CONTROLS = [
      "inventory.slot.0",
      "hotbar.slot.0",
      // The tab this task's contract asks for. Deliberately the *active* tab:
      // activating it is a no-op for the panel, where clicking Skills would replace
      // the inventory grid that the drag probe below needs.
      "rail.tab.inventory",
      "action.settings",
      ...(compactRail ? ["rail.compact.nav.0"] : []),
    ];
    const sample = WANTED_CONTROLS.map((key) =>
      controls.find((c) => c.key === key && c.enabled && c.w > 4 && c.h > 4)
    ).filter(Boolean);
    const absent = WANTED_CONTROLS.filter((key) => !sample.some((c) => c.key === key));
    check(
      `${label}: `+"every sampled control kind is on screen",
      absent.length === 0,
      `missing ${JSON.stringify(absent)} of ${JSON.stringify(WANTED_CONTROLS)}`
    );

    for (const sampled of sample) {
      const control = (await rectOf(sampled.key)) ?? sampled;
      const cx = control.x + control.w / 2;
      const cy = control.y + control.h / 2;

      const centred = await clickAt(cx, cy, CLICK_BUDGET_MS, control.key);
      check(
        `clicking the centre of ${control.key} activates it`,
        centred.key === control.key,
        shown([cx, cy], centred)
      );
      check(
        `clicking the centre of ${control.key} activates it exactly once`,
        centred.after - centred.before === 1,
        shown([cx, cy], centred)
      );

      // One pixel inside each edge is still this control.
      for (const [dx, dy, edge] of [
        [1, 0, "left"],
        [-1, 0, "right"],
        [0, 1, "top"],
        [0, -1, "bottom"],
      ]) {
        const now = (await rectOf(sampled.key)) ?? control;
        const inset = ratio === 1 ? 1 : 2;
        const centreX = now.x + now.w / 2;
        const centreY = now.y + now.h / 2;
        const x = dx === 0 ? centreX : dx > 0 ? now.x + inset : now.x + now.w - inset;
        const y = dy === 0 ? centreY : dy > 0 ? now.y + inset : now.y + now.h - inset;
        const inside = await clickAt(x, y, CLICK_BUDGET_MS, control.key);
        check(
          `${inset}px inside the ${edge} edge of ${control.key} still activates it`,
          inside.key === control.key && inside.after - inside.before === 1,
          shown([x, y], inside)
        );
      }

      // Outside each edge is not. Half-open rectangles mean the pixel at the far
      // edge belongs to the neighbour, and a grid of controls that each claim it
      // puts every click one place out along the row.
      //
      // The margin is one CSS pixel only at ratio 1, where a CSS pixel *is* a device
      // pixel and the boundary is exact. Above it a control's edge can fall
      // mid-pixel — at 2x the published rectangle is a physical one halved — so a
      // one-pixel probe measures the browser's rounding rather than the client's hit
      // testing. Two pixels is still far finer than anything a player can aim.
      const margin = ratio === 1 ? 1 : 2;
      const outer = (await rectOf(sampled.key)) ?? control;
      const ox = outer.x + outer.w / 2;
      const oy = outer.y + outer.h / 2;
      for (const [x, y, edge] of [
        [outer.x - margin, oy, "left"],
        [outer.x + outer.w + margin, oy, "right"],
        [ox, outer.y - margin, "top"],
        [ox, outer.y + outer.h + margin, "bottom"],
      ]) {
        const fired = await clickAt(x, y, NEGATIVE_BUDGET_MS);
        check(
          `${margin}px outside the ${edge} edge of ${control.key} does not activate it`,
          fired.key !== control.key,
          shown([x, y], fired)
        );
      }
    }

    // The spell control this task's contract names, which needs the spellbook on screen:
    // the tab is switched, the row is probed, and the inventory is put back for the
    // checks below. Done here rather than in the sample above because activating the
    // Skills or Spells tab replaces the grid those checks aim at.
    const edge = ratio === 1 ? 1 : 2;
    const tabRect = await rectOf("rail.tab.spells");
    if (tabRect) {
      const at = [tabRect.x + tabRect.w / 2, tabRect.y + tabRect.h / 2];
      const opened = await clickAt(at[0], at[1], CLICK_BUDGET_MS, "rail.tab.spells");
      check(
        `${label}: `+"the spells tab activates",
        opened.key === "rail.tab.spells" && opened.after - opened.before === 1,
        shown(at, opened)
      );

      const row = await rectSoon("spell.row.0");
      check(`${label}: `+"the spellbook publishes a row to aim at", row !== null);
      if (row) {
        const centred = await clickAt(
          row.x + row.w / 2,
          row.y + row.h / 2,
          CLICK_BUDGET_MS,
          "spell.row.0"
        );
        check(
          "clicking the centre of spell.row.0 activates it exactly once",
          centred.key === "spell.row.0" && centred.after - centred.before === 1,
          shown([row.x + row.w / 2, row.y + row.h / 2], centred)
        );
        const outside = await clickAt(row.x - edge, row.y + row.h / 2, NEGATIVE_BUDGET_MS);
        check(
          `${edge}px outside the left edge of spell.row.0 does not activate it`,
          outside.key !== "spell.row.0",
          shown([row.x - edge, row.y + row.h / 2], outside)
        );
      }

      const back = await rectSoon("rail.tab.inventory");
      if (back) {
        await clickAt(
          back.x + back.w / 2,
          back.y + back.h / 2,
          CLICK_BUDGET_MS,
          "rail.tab.inventory"
        );
      }
    }

    // Dragging an item, driven by a real pointer.
    //
    // This cannot be tested in a headless Bevy app for the same reason clicking
    // cannot: with no render target there is nothing to map a pointer through, so the
    // drag events never name a slot. And its whole observable result is that two slots
    // exchanged contents, which is why the client publishes them.
    const slotIds = () => hitPage.evaluate(() => window.aoLoaded?.inventorySlots ?? []);
    const before = await slotIds();
    const source = before.findIndex((id) => id > 0);
    const target = before.findIndex((id, at) => at > source && id > 0 && id !== before[source]);
    check(
      `${label}: `+"two distinguishable items are available to drag between",
      source >= 0 && target > source,
      `slots ${JSON.stringify(before.slice(0, 8))}`
    );
    const from = source >= 0 ? await rectOf(`inventory.slot.${source}`) : null;
    const onto = target > source ? await rectOf(`inventory.slot.${target}`) : null;
    if (from && onto) {
      // Seen before pressed, for the same reason as a click: a press attributed to
      // where the pointer used to be starts a drag on the wrong slot, or on none.
      const startX = from.x + from.w / 2;
      const startY = from.y + from.h / 2;
      const endX = onto.x + onto.w / 2;
      const endY = onto.y + onto.h / 2;
      await pointerTo(startX, startY, `inventory.slot.${source}`);
      await hitPage.mouse.down();

      // Paced by frames rather than delivered as twelve events in a few milliseconds.
      // A drag is only a drag if the client *observes* movement while the button is
      // held; at three seconds a frame — which is what a device pixel ratio change to 2
      // leaves this software renderer — a burst of moves and a release can all land in
      // one frame, and the gesture reads as a click that ended somewhere else. That is
      // the one configuration in which this check failed.
      const STEPS = 4;
      for (let step = 1; step <= STEPS; step += 1) {
        const at = step / STEPS;
        await hitPage.mouse.move(
          canvasBox.x + startX + (endX - startX) * at,
          canvasBox.y + startY + (endY - startY) * at
        );
        await hitPage.waitForTimeout(Math.min(Math.max(1.5 * frameMs, 120), 4_000));
      }
      const held = await hitPage.evaluate(() => ({
        from: window.aoLoaded?.dragFrom ?? -1,
        over: window.aoLoaded?.dragOver ?? -1,
      }));
      await hitPage.mouse.up();

      const wanted = [before[target], before[source]];
      let after = before;
      const dragDeadline = Date.now() + 15_000;
      while (Date.now() < dragDeadline) {
        after = await slotIds();
        if (after[source] === wanted[0] && after[target] === wanted[1]) break;
        await hitPage.waitForTimeout(50);
      }
      check(
        `${label}: `+`the client saw the drag from slot ${source} reach slot ${target}`,
        held.from === source && held.over === target,
        `mid-drag the client held from=${held.from} over=${held.over}`
      );
      check(
        `dragging inventory.slot.${source} onto inventory.slot.${target} exchanges them`,
        after[source] === wanted[0] && after[target] === wanted[1],
        `${JSON.stringify(before.slice(0, 8))} -> ${JSON.stringify(after.slice(0, 8))}`
      );
    }

    // The world half of the same question: clicking the middle of the viewport must
    // select the tile drawn in the middle of the viewport. The camera follows the
    // player, so that tile is the player's own — an off-by-one anywhere in the
    // chain shows up as a neighbour.
    // The world's rectangle as the shell computed it, not as a test guessed from a
    // control's position — which measured into the rail and off the top bar.
    const worldRect = await hitPage.evaluate(() => ({
      x: window.aoLoaded?.worldX,
      y: window.aoLoaded?.worldY,
      w: window.aoLoaded?.worldW,
      h: window.aoLoaded?.worldH,
    }));
    check(
      "the client publishes its world rectangle",
      typeof worldRect.w === "number" && worldRect.w > 0,
      JSON.stringify(worldRect)
    );

    /// Move the pointer and read the tile the client resolves *for that position*.
    ///
    /// Waits for the client's published pointer position to match the one just
    /// moved to. Returning as soon as the target says "world" read whatever was
    /// published for the *previous* position, so every measurement was one move
    /// stale — which made the world mapping look inverted.
    const tileAt = async (x, y) => {
      await hitPage.mouse.move(canvasBox.x + x, canvasBox.y + y);
      const deadline = Date.now() + 3_000;
      while (Date.now() < deadline) {
        const report = await hitPage.evaluate(() => ({
          target: window.aoLoaded?.pointerTarget,
          tile: window.aoLoaded?.pointerTile,
          px: window.aoLoaded?.pointerX,
          py: window.aoLoaded?.pointerY,
        }));
        const arrived =
          typeof report.px === "number" &&
          Math.abs(report.px - x) <= 1.5 &&
          Math.abs(report.py - y) <= 1.5;
        if (arrived) {
          if (report.target === "world" && report.tile) return report.tile;
          if (report.target !== "world") return null;
        }
        await hitPage.waitForTimeout(50);
      }
      throw new Error(`the client never reported the pointer at ${x},${y}`);
    };

    const player = await hitPage.evaluate(() => [
      window.aoLoaded?.playerX,
      window.aoLoaded?.playerY,
    ]);
    const centre = await tileAt(worldRect.x + worldRect.w / 2, worldRect.y + worldRect.h / 2);
    check(
      "the centre of the world viewport selects the player's own tile",
      Array.isArray(centre) && centre[0] === player[0] && centre[1] === player[1],
      `centre selected ${JSON.stringify(centre)}, player is at ${JSON.stringify(player)}`
    );

    // The four edges, one pixel inside. Each must be a different tile, and each
    // must lie on the expected side of the centre — a sign error in the mapping
    // passes a "different tile" check and fails this one.
    const edges = {
      left: await tileAt(worldRect.x + 1, worldRect.y + worldRect.h / 2),
      right: await tileAt(worldRect.x + worldRect.w - 2, worldRect.y + worldRect.h / 2),
      top: await tileAt(worldRect.x + worldRect.w / 2, worldRect.y + 1),
      bottom: await tileAt(worldRect.x + worldRect.w / 2, worldRect.y + worldRect.h - 2),
    };
    check(`${label}: `+"the left edge of the world is west of centre", edges.left?.[0] < centre?.[0],
      `left ${JSON.stringify(edges.left)} vs centre ${JSON.stringify(centre)}`);
    check(`${label}: `+"the right edge of the world is east of centre", edges.right?.[0] > centre?.[0],
      `right ${JSON.stringify(edges.right)}`);
    check(`${label}: `+"the top edge of the world is north of centre", edges.top?.[1] < centre?.[1],
      `top ${JSON.stringify(edges.top)}`);
    check(`${label}: `+"the bottom edge of the world is south of centre", edges.bottom?.[1] > centre?.[1],
      `bottom ${JSON.stringify(edges.bottom)}`);

    // And the interface is not the world, however close to the seam.
    check(
      "a pixel just inside the rail is not a world tile",
      (await tileAt(worldRect.x + worldRect.w + 2, worldRect.y + worldRect.h / 2)) === null
    );

    // Interception, which is the other half of "the control under the pointer receives
    // the event": the hotbar floats *inside* the world viewport, so a click on a slot
    // must not also be a click on the ground under it. A player who means to drink a
    // potion and walks two tiles instead has met this bug.
    const floating = await rectOf("hotbar.slot.0");
    if (floating) {
      const inside =
        floating.x > worldRect.x &&
        floating.x + floating.w < worldRect.x + worldRect.w &&
        floating.y > worldRect.y &&
        floating.y + floating.h < worldRect.y + worldRect.h;
      check(
        `${label}: `+"the hotbar is inside the world viewport, where interception matters",
        inside,
        `hotbar ${JSON.stringify(floating)} against world ${JSON.stringify(worldRect)}`
      );
      check(
        "a control floating over the world intercepts the click",
        (await tileAt(floating.x + floating.w / 2, floating.y + floating.h / 2)) === null
      );
    }

    // The whole-world map, driven by the keys and the wheel a player uses. Bevy app tests
    // cover the camera arithmetic; what only a browser can answer is whether a real Tab
    // press reaches the client, whether the world underneath stops being clickable, and
    // whether the rail is still there while it is open.
    const mapState = () =>
      hitPage.evaluate(() => ({
        open: window.aoLoaded?.worldMapOpen === true,
        scale: window.aoLoaded?.worldMapScale ?? 0,
        centre: [window.aoLoaded?.worldMapCentreX ?? 0, window.aoLoaded?.worldMapCentreY ?? 0],
        markers: window.aoLoaded?.worldMapMarkers ?? 0,
      }));
    const settleMap = async () => {
      await hitPage.waitForTimeout(Math.min(Math.max(3 * frameMs, 300), 6_000));
      return mapState();
    };

    await hitPage.keyboard.press("Tab");
    let map = await settleMap();
    check(`${label}: `+"Tab opens the world map", map.open, JSON.stringify(map));
    check(
      `${label}: `+"the open map draws its markers",
      map.markers > 0,
      `${map.markers} markers`
    );

    if (map.open) {
      // The world is not clickable through it. Checked with the pointer over the middle of
      // the world, where the map is: the classification has to say interface, or a click on
      // the map is also a click on the ground behind it.
      const covered = await tileAt(worldRect.x + worldRect.w / 2, worldRect.y + worldRect.h / 2);
      check("the world is not clickable through the open map", covered === null);

      // Nothing the world would act on. A hotbar key must not cast while the map is up.
      const before = await hitPage.evaluate(() => window.aoLoaded?.activations ?? 0);
      await hitPage.keyboard.press("Digit1");
      await hitPage.waitForTimeout(Math.min(Math.max(3 * frameMs, 300), 6_000));
      const after = await hitPage.evaluate(() => window.aoLoaded?.activations ?? 0);
      check(
        `${label}: `+"a hotbar key does nothing while the map is open",
        after === before,
        `${before} -> ${after}`
      );

      // Zoom is clamped in both directions, driven by the wheel rather than by arithmetic.
      const fitted = map.scale;
      await hitPage.mouse.move(
        canvasBox.x + worldRect.x + worldRect.w / 2,
        canvasBox.y + worldRect.y + worldRect.h / 2
      );
      for (let i = 0; i < 12; i += 1) {
        await hitPage.mouse.wheel(0, -120);
      }
      const zoomedIn = await settleMap();
      check(
        `${label}: `+"the wheel zooms in and stops at the maximum",
        zoomedIn.scale > fitted && Number.isFinite(zoomedIn.scale) && zoomedIn.scale <= 12.001,
        `${fitted} -> ${zoomedIn.scale}`
      );

      for (let i = 0; i < 30; i += 1) {
        await hitPage.mouse.wheel(0, 120);
      }
      const zoomedOut = await settleMap();
      check(
        `${label}: `+"the wheel cannot zoom out past the whole world",
        Math.abs(zoomedOut.scale - fitted) <= 0.01,
        `${fitted} against ${zoomedOut.scale}`
      );

      // Filtering removes markers and nothing else.
      const filter = await rectSoon("worldmap.filter.merchant");
      check(`${label}: `+"the legend publishes a filter to click", filter !== null);
      if (filter) {
        const drawn = (await mapState()).markers;
        await clickAt(
          filter.x + filter.w / 2,
          filter.y + filter.h / 2,
          CLICK_BUDGET_MS,
          "worldmap.filter.merchant"
        );
        const filtered = await settleMap();
        check(
          "switching a map category off removes exactly its markers",
          filtered.markers === drawn - 1,
          `${drawn} -> ${filtered.markers}`
        );
      }

      // The rail is still there and still works.
      const railTab = await rectSoon("rail.tab.inventory");
      check(`${label}: `+"the rail is still reachable with the map open", railTab !== null);
      if (railTab) {
        const activated = await clickAt(
          railTab.x + railTab.w / 2,
          railTab.y + railTab.h / 2,
          CLICK_BUDGET_MS,
          "rail.tab.inventory"
        );
        check(
          "a rail control still activates with the map open",
          activated.key === "rail.tab.inventory",
          shown([railTab.x + railTab.w / 2, railTab.y + railTab.h / 2], activated)
        );
        check(
          `${label}: `+"clicking the rail did not close the map",
          (await mapState()).open
        );
      }

      await hitPage.keyboard.press("Escape");
      const closed = await settleMap();
      check(`${label}: `+"Escape closes the world map", !closed.open, JSON.stringify(closed));
    }



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
    if (runs("layout")) {
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
    // rasterization sharpness. What it CAN check, and what the paragraph below
    // used to deny, is whether the client observes the ratio at all: it reads
    // window.devicePixelRatio, which the emulation does change. A DPR-only
    // change must leave the logical layout alone and grow the backing store.
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

      // A retina display is more physical pixels for the same CSS box, so the
      // backing store must be the CSS size times the ratio. Equal to the CSS size
      // means the client renders at a fraction of the resolution it has and the
      // browser upscales pixel art to fill the gap.
      //
      // This asserted the opposite until now, which was right while the client
      // pinned its scale factor to 1 — an interim measure that held the layout
      // steady and gave up the resolution. It also left the cursor and Bevy's
      // picking in device pixels while the layout was in CSS pixels, so clicks
      // drifted further off the further they were from the origin on any scaled
      // display. `track_host_canvas` owns the backing store now, and the three
      // agree.
      check(
        `the backing store is ${ratio}x the css size`,
        Math.abs(measured.backingWidth - measured.cssWidth * ratio) <= 2 &&
          Math.abs(measured.backingHeight - measured.cssHeight * ratio) <= 2,
        `css ${measured.cssWidth}x${measured.cssHeight}, backing ${measured.backingWidth}x${measured.backingHeight}, ratio ${measured.ratio}`
      );


      await dprContext.close();
    }

    // Layout invariance across ratios is asserted in Bevy, by
    // a_device_pixel_ratio_change_alone_does_not_change_what_is_framed, which
    // can read the framing directly. A first attempt to check it here sampled
    // the rendered pixels for the rail's edge and reported one value at every
    // ratio while the captures plainly showed the rail collapsing at 2x — a
    // check that passes for the wrong reason is worse than no check.
    //
    // Once the backing store is right the logical size is the CSS size by
    // construction, which is what the assertion above pins.

    // "Update the backing store exactly once per event." A resize that settles
    // through two or three intermediate sizes is a visible flicker, and a
    // resize that lands on the right size after oscillating looks identical to
    // one that did it cleanly in any screenshot taken afterwards.
    console.log("  backing store settles once per resize");
    const settleContext = await browser.newContext({
      viewport: { width: 1280, height: 800 },
      deviceScaleFactor: 1,
    });
    const settlePage = await settleContext.newPage();
    await settlePage.goto(url, { waitUntil: "load" });
    await waitForClient(settlePage);

    // Record every distinct backing-store size from now on, one sample per
    // frame. Started after the client has settled so boot is not counted.
    await settlePage.evaluate(() => {
      const canvas = document.getElementById("ao-canvas");
      window.__sizes = [`${canvas.width}x${canvas.height}`];
      const sample = () => {
        const now = `${canvas.width}x${canvas.height}`;
        if (now !== window.__sizes[window.__sizes.length - 1]) window.__sizes.push(now);
        requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    });

    await settlePage.setViewportSize({ width: 1000, height: 700 });
    await settlePage.waitForTimeout(2_000);

    const sizes = await settlePage.evaluate(() => window.__sizes);
    check(
      "one resize moves the backing store to one new size",
      sizes.length === 2,
      `backing store went through ${JSON.stringify(sizes)}`
    );
    await settleContext.close();
    }

    if (runs("hits")) {
    // Hit testing, in a real browser, because that is the only place the question
    // can be asked. Headless Bevy's UI picking has no render target to map a
    // pointer through and reports a hit on the root node whatever the position.
    //
    // The client publishes each keyed control's rectangle, the world's rectangle,
    // the pointer's own position and an activation counter, so a click can be aimed
    // at a control's actual position and checked against the control that fired —
    // rather than at a position a test guessed from the layout it is verifying.
    //
    // Run across the device pixel ratio matrix and both reachable host modes.
    // Fullscreen is not among them: it needs a user gesture the automation cannot
    // supply, and the refusal path is covered above.
    const hitConfigurations = [
      { label: "windowed 1x", ratio: 1, mode: "windowed" },
      { label: "windowed 1.25x", ratio: 1.25, mode: "windowed" },
      { label: "windowed 1.5x", ratio: 1.5, mode: "windowed" },
      { label: "windowed 1.75x", ratio: 1.75, mode: "windowed" },
      { label: "windowed 2x", ratio: 2, mode: "windowed" },
      { label: "maximized 1x", ratio: 1, mode: "maximized" },
      { label: "maximized 2x", ratio: 2, mode: "maximized" },
    ];

    for (const configuration of hitConfigurations) {
      console.log(`  pointer hit testing — ${configuration.label}`);
      const hitContext = await browser.newContext({
        viewport: { width: 1280, height: 800 },
        deviceScaleFactor: configuration.ratio,
      });
      const hitPage = await hitContext.newPage();
      await hitPage.goto(url, { waitUntil: "load" });
      await waitForClient(hitPage);
      if (configuration.mode === "maximized") {
        await hitPage.evaluate(() => window.aoWindow?.setMode("maximized"));
        await hitPage.waitForTimeout(1_500);
      }
      await runHitTests(hitPage, configuration.label, configuration.ratio);
      await hitContext.close();
    }

    // The same battery again after the display changes under a *running* client,
    // which is a different question from starting at that ratio: every cached
    // rectangle, viewport and scale domain has to be rebuilt rather than merely
    // computed once. This is also what browser zoom is, seen from inside the page —
    // Chrome delivers a zoom as a device pixel ratio change — so it is not claimed
    // separately below.
    console.log("  pointer hit testing — after a resize and a DPR change mid-session");
    const changedContext = await browser.newContext({
      viewport: { width: 1280, height: 800 },
      deviceScaleFactor: 1,
    });
    const changedPage = await changedContext.newPage();
    await changedPage.goto(url, { waitUntil: "load" });
    await waitForClient(changedPage);

    await changedPage.setViewportSize({ width: 1100, height: 740 });
    await changedPage.waitForTimeout(2_000);
    await runHitTests(changedPage, "after a resize", 1);

    // A control's size in CSS pixels does not depend on the device pixel ratio: at a
    // higher ratio the same control is drawn with more device pixels, not made smaller.
    // Worth stating because the failure it catches passes every other check in this
    // battery — a whole interface laid out at half scale is self-consistent, so clicks
    // still land on the controls they hit, and only the drag between two slots that are
    // now half as far apart gave it away.
    const sizeBefore = await changedPage.evaluate(
      () => (window.aoLoaded?.controls ?? []).find((c) => c.key === "inventory.slot.0")
    );

    const cdp = await changedContext.newCDPSession(changedPage);
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 1100,
      height: 740,
      deviceScaleFactor: 2,
      mobile: false,
    });
    await changedPage.waitForTimeout(3_000);
    const changedRatio = await changedPage.evaluate(() => window.devicePixelRatio);
    check(
      "a mid-session DPR change reaches the page",
      changedRatio === 2,
      `devicePixelRatio is ${changedRatio}`
    );
    const sizeAfter = await changedPage.evaluate(
      () => (window.aoLoaded?.controls ?? []).find((c) => c.key === "inventory.slot.0")
    );
    check(
      "a control keeps its size in css pixels across a DPR change",
      sizeBefore &&
        sizeAfter &&
        Math.abs(sizeBefore.w - sizeAfter.w) <= 1 &&
        Math.abs(sizeBefore.h - sizeAfter.h) <= 1,
      `${sizeBefore?.w}x${sizeBefore?.h} became ${sizeAfter?.w}x${sizeAfter?.h}`
    );

    await runHitTests(changedPage, "after a DPR change to 2x", 2);
    await cdp.detach();
    await changedContext.close();

    // Keyboard focus must not leave the canvas. Tab moving browser focus off it
    // ends the session's keyboard: the player tabs through page furniture with no
    // way back except clicking, and every gameplay key stops working.
    console.log("  keyboard focus stays on the canvas");
    const focusContext = await browser.newContext({
      viewport: { width: 1280, height: 800 },
      deviceScaleFactor: 1,
    });
    const focusPage = await focusContext.newPage();
    await focusPage.goto(url, { waitUntil: "load" });
    await waitForClient(focusPage);

    await focusPage.evaluate(() => document.getElementById("ao-canvas").focus());
    check(
      "the canvas can hold focus",
      await focusPage.evaluate(() => document.activeElement?.id === "ao-canvas")
    );

    for (const key of ["Tab", "F6"]) {
      await focusPage.keyboard.press(key);
      const still = await focusPage.evaluate(() => document.activeElement?.id);
      check(`${key} leaves focus on the canvas`, still === "ao-canvas", `focus moved to ${still}`);
    }

    // Shift+Tab too: it is the same escape in the other direction.
    await focusPage.keyboard.press("Shift+Tab");
    check(
      "Shift+Tab leaves focus on the canvas",
      (await focusPage.evaluate(() => document.activeElement?.id)) === "ao-canvas"
    );
    await focusContext.close();

    // The stepped windowed size, at the sizes where it changes answer. 1440p is
    // included because it is the case most likely to be assumed: a large
    // display that still only fits one step, because two need 1520 pixels of
    // height and it has 1440.
    console.log("  windowed step-up");
    const stepContext = await browser.newContext({
      viewport: { width: 1280, height: 800 },
      deviceScaleFactor: 1,
    });
    const stepPage = await stepContext.newPage();
    await stepPage.goto(url, { waitUntil: "load" });
    await waitForClient(stepPage);

    // The page's own rule, not a copy of it, evaluated for viewports this
    // browser cannot actually be given.
    const hostSteps = await stepPage.evaluate(
      (cases) => cases.map(([w, h]) => window.aoWindow.shellSteps(w, h)),
      [
        [1280, 800],
        [1920, 1080],
        [2560, 1440],
        [2560, 1600],
        [3840, 2160],
        [5120, 2880],
      ]
    );
    const ourSteps = [
      [1280, 800],
      [1920, 1080],
      [2560, 1440],
      [2560, 1600],
      [3840, 2160],
      [5120, 2880],
    ].map(([w, h]) => steps(w, h));
    check(
      "the host page steps the window the way this harness expects",
      JSON.stringify(hostSteps) === JSON.stringify(ourSteps),
      `page ${JSON.stringify(hostSteps)} vs harness ${JSON.stringify(ourSteps)}`
    );
    check(
      "a 1440p display fits one step, not two",
      hostSteps[2] === 1,
      `got ${hostSteps[2]} steps at 2560x1440`
    );
    check(
      "4K fits two steps",
      hostSteps[4] === 2,
      `got ${hostSteps[4]} steps at 3840x2160`
    );
    check(
      "a step is never zero, however small the viewport",
      (await stepPage.evaluate(() => window.aoWindow.shellSteps(320, 200))) === 1
    );
    await stepContext.close();

    // And that the rule is actually applied, at a viewport large enough to
    // step. Real, not evaluated: this is the one that catches the CSS variable
    // being set and never read.
    const bigContext = await browser.newContext({
      viewport: { width: 3840, height: 2160 },
      deviceScaleFactor: 1,
    });
    const bigPage = await bigContext.newPage();
    await bigPage.goto(url, { waitUntil: "load" });
    await waitForClient(bigPage);
    const big = await measure(bigPage);
    check(
      "a 4K viewport gets a two-step window",
      Math.abs(big.shellWidth - DESIGN.width * 2) <= 1 &&
        Math.abs(big.shellHeight - DESIGN.height * 2) <= 1,
      `shell ${big.shellWidth}x${big.shellHeight}, expected ${DESIGN.width * 2}x${DESIGN.height * 2}`
    );
    check(
      "a stepped window still leaves room around itself",
      big.shellWidth < big.innerWidth && big.shellHeight < big.innerHeight,
      `shell ${big.shellWidth}x${big.shellHeight} in ${big.innerWidth}x${big.innerHeight}`
    );
    check("no scrollbars at 4K", !big.scrollsHorizontally && !big.scrollsVertically);
    await bigContext.close();
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
