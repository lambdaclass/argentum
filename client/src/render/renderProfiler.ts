/**
 * Opt-in profiler for the world render path.
 *
 * Exists to attribute perceived movement lag. The Pixi ticker owns the cheap
 * per-frame work (motion interpolation, camera, HUD, weather); the expensive
 * pass — syncCharacters, chat bubbles, effects, and a full app.render() — is
 * driven by React whenever the `world` object identity changes. This measures
 * how often that pass runs and what each phase costs, so "movement feels slow"
 * can be answered with numbers rather than inspection.
 *
 * Disabled by default and costs nothing when off: every hook is a boolean check.
 *
 * Usage from the browser console:
 *
 *     __argentumPerf.start()     // begin sampling
 *     ...move around for a while...
 *     __argentumPerf.report()    // print a table, keep sampling
 *     __argentumPerf.stop()      // stop and reset
 */

type PhaseName = string;

interface PhaseStats {
  calls: number;
  totalMs: number;
  maxMs: number;
}

const stats = new Map<PhaseName, PhaseStats>();
let enabled = false;
let startedAt = 0;
let renderPasses = 0;

function record(phase: PhaseName, ms: number) {
  let entry = stats.get(phase);
  if (!entry) {
    entry = { calls: 0, totalMs: 0, maxMs: 0 };
    stats.set(phase, entry);
  }
  entry.calls += 1;
  entry.totalMs += ms;
  if (ms > entry.maxMs) {
    entry.maxMs = ms;
  }
}

export const renderProfiler = {
  get enabled() {
    return enabled;
  },

  start() {
    stats.clear();
    renderPasses = 0;
    startedAt = performance.now();
    enabled = true;
    // eslint-disable-next-line no-console
    console.log("[argentumPerf] sampling started — move around, then __argentumPerf.report()");
  },

  stop() {
    enabled = false;
    stats.clear();
    renderPasses = 0;
    // eslint-disable-next-line no-console
    console.log("[argentumPerf] stopped");
  },

  /** Count one full React-driven render pass. */
  countPass() {
    if (enabled) {
      renderPasses += 1;
    }
  },

  /** Time a single phase within a render pass. */
  measure<T>(phase: PhaseName, fn: () => T): T {
    if (!enabled) {
      return fn();
    }
    const t0 = performance.now();
    try {
      return fn();
    } finally {
      record(phase, performance.now() - t0);
    }
  },

  report() {
    const elapsedS = (performance.now() - startedAt) / 1000;
    if (!enabled) {
      // eslint-disable-next-line no-console
      console.log("[argentumPerf] not running — call __argentumPerf.start() first");
      return;
    }

    const rows = [...stats.entries()]
      .map(([phase, s]) => ({
        phase,
        calls: s.calls,
        "calls/s": +(s.calls / elapsedS).toFixed(1),
        "avg ms": +(s.totalMs / s.calls).toFixed(3),
        "max ms": +s.maxMs.toFixed(3),
        "total ms": +s.totalMs.toFixed(1),
        "% of wall": +((s.totalMs / (elapsedS * 1000)) * 100).toFixed(1)
      }))
      .sort((a, b) => b["total ms"] - a["total ms"]);

    /* eslint-disable no-console */
    console.log(
      `[argentumPerf] ${elapsedS.toFixed(1)}s — ${renderPasses} React-driven render passes ` +
        `(${(renderPasses / elapsedS).toFixed(1)}/s)`
    );
    console.table(rows);
    /* eslint-enable no-console */
  }
};

if (typeof window !== "undefined") {
  (window as unknown as Record<string, unknown>).__argentumPerf = renderProfiler;
}
