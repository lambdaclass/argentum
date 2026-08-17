# Rust/Bevy Client Changelog

This is the append-only home for closed roadmap tasks and dated, verified
milestones. Active execution order and phase completion gates live together in
`ROADMAP.md`.

Stable `W-NNNN` identities were introduced on 2026-08-16. Earlier work is
recorded as pre-ID foundation rather than assigned invented task identities
after the fact. Future closures use this form:

```markdown
### Completed Task W-NNNN — Title

Closed: YYYY-MM-DD (`commit`)
Evidence: commands, tests, captures and measurements
```

Never reuse a completed ID in the active roadmap.

## Closed tasks

### Completed Task W-0001 — Fixed Bevy application shell

Closed: 2026-08-16 (`9c41009`, `b078ac0`, `eebfe80`, `d206294`, `2b80041`, `83dc05e`)

The top bar, world region, character rail and numbered hotbar form one
application shell in the rendered browser window, derived from the current host
rectangle rather than from layout helpers alone.

**Host modes.** The canvas follows the host. Windowed is a bounded, centred
1280x760 game window — the reference client's measured height, the same 22%
rail — which shrinks to fit smaller viewports so a laptop is never broken by the
bound. Maximize expands the host to the browser content area with tabs and
address bar visible; fullscreen goes through the platform capability, needs a
user gesture and can be refused, in which case the adapter reports the mode
actually reached instead of claiming success. Escape leaves fullscreen without
notifying the client, so the mode is re-read twice a second rather than
remembered.

**Top bar.** `LN`, `PIC`, `AUD`, `CBT` and `CFG` are gone. Actions use icons
composed from primitives — no font or sheet to license — each carrying a
localisation key used as both hover tooltip and accessible name. One tooltip
node is reused and ignores picking, since a tooltip that can be hovered steals
the pointer from the control it describes. FPS, ping and population stay
textual.

**Focus across rebuilds.** Panels rebuild on every snapshot and every geometry
change, which despawns their controls, so focus held as an entity was lost by a
resize. Controls carry stable keys and focus remembers both entity and key,
survives a panel being briefly absent mid-rebuild, and declines to re-attach to
a control that came back disabled.

Evidence:

- `node scripts/browser-test.mjs` — canvas is the smaller of the playing size
  and the viewport within one pixel with no page scrollbars, at 720p, 1080p,
  1440p, small-laptop and narrow; across three live resizes; at emulated device
  pixel ratios 1.25, 1.5 and 2. Host modes: windowed is bounded and smaller than
  its viewport, maximize fills the content area with the canvas following it,
  restore returns to exactly the starting size and the host reports itself
  windowed again.
- `cargo test --workspace` — 298 client, 70 core. Region partition tests assert
  non-negative, non-overlapping bounds inside the window at nine sizes including
  1x1 and zero; the bar spans full width with the rail full-height beneath it;
  world and rail leave no gap; the hotbar stays inside and centred on the world
  rather than the window.
- `node scripts/capture.mjs` — 13 captures at build `83dc05e`. 1280x720 and
  1920x1080 show the full top bar, rail and hotbar with no clipping.
- Artifact: 24.2 MB raw, 20.0 MB optimized, 5.78 MB gzip.

Roadmap correction: the task originally required the canvas to track the browser
content area without qualification. Implementation showed that is wrong above a
certain size — the world holds its designed view and scales up rather than
revealing more map, so filling a 2000-pixel browser made every element enormous
while showing nothing more. The requirement now carries its bound and still
forbids what it was written to forbid: a fixed rectangle that ignores a smaller
window.

Known limitation carried forward to W-0003: Playwright's `deviceScaleFactor` is
an emulation headless Chromium does not rasterize at, so the canvas backing
store measures identically at 1x and 2x. Verifying that it follows a real device
pixel ratio needs a physical high-DPI display.

## Pre-stable-ID foundation

### 2026-08-16 — Honest login request encoders

Existing-character login is packet 73 and new-character login is packet 74;
the latter's creation fields are no longer mislabeled as ignored padding.
Shared fixtures assert Rust bytes against the Elixir decoder.

### 2026-08-16 — Runtime configuration boundary

Hard-coded asset/gateway/character values were replaced by query string, page
metadata and page-origin resolution on web and `AO_*` variables on native.
Missing credentials no longer cause implicit character creation, and the build
checks that page configuration does not appear in the WASM artifact.

### 2026-08-16 — Initial lifecycle state machine

`AppState` covers `Boot -> LoadingWorld -> Playing` and scopes gameplay systems
to `Playing`. `MapLoadReported` was removed. Render memos and redraw triggers
were deliberately not mislabeled as application lifecycle states.

### 2026-08-16 — Game-socket latency probe

Client ping 900/server pong 204 uses one in-flight opaque token and a bounded
moving median. A real Ranch listener test covers the echo before login and
fails when the token is not returned unchanged.

### 2026-08-16 — Renderer and movement foundation

The client renders real map layers and artwork, composed characters, static
NPC/object records and real walk/position packets. Newest-key direction,
server-formula walk gating, under/over-character layer placement, tall-art
prefetch and a 35%/0.12s occluder fade are present. These are foundations for
later authoritative entities, depth sorting, trigger-driven roofs and bounded
streaming—not evidence that those phases are closed.

### 2026-08-16 — Recorded artifact baseline

The last recorded optimized client was 19.2 MB raw and 5.5 MB gzip. The gzip
measurement is the transfer baseline to defend; every budget gate must remeasure
the actual artifact rather than repeating this historical number as current.
