# Rust/Bevy Client Roadmap

This is the active execution plan for `client-rs`, the Bevy client targeting
browser/WASM and native desktop from one Rust codebase. It answers two different
questions without confusing them:

- the phase map says **what capabilities unlock the finished client**; and
- the execution sequence says **what should be implemented next, in order**.

The Rust/Bevy client is the sole actively developed game client and the intended
production successor. The TypeScript/Pixi client in `client/` is frozen,
non-gating reference material: do not spend roadmap time preserving, testing or
repairing its compatibility, and allow cleaner server/protocol architecture to
break it. Retain useful traces, fixtures and behavioral references only until
their Rust/server replacements exist; removal of the obsolete tree and its
deploy surface is the bounded cleanup task W-0091, not incidental work inside
an unrelated task.

Canonical supporting documents:

- [Client changelog](CHANGELOG.md) owns completed work and dated evidence.
- This roadmap owns active tasks, execution order and phase exit gates.
- `scripts/check_roadmap.sh` enforces stable task identities, one sequence and
  one exit gate per phase.

## How to execute this roadmap

Execution starts at the first active task in
[Execution sequence](#execution-sequence) and continues in file order. The
detailed task bodies are the only priority list; there is no summary queue to
keep synchronized with them.

Each active task has an immutable `W-NNNN` identity. IDs are never renumbered,
reused or made to encode priority. New urgent work receives the next unused ID
and is inserted explicitly at the correct point in the sequence. A commit,
review or blocker should refer to the ID, not to “task 3” or a line number. A
task ID in a commit title records work toward that task; it does not close the
task. Closure happens only when the task contract and applicable phase gate
pass, the active body is removed from this file and a dated `Completed Task`
entry is added to `CHANGELOG.md` in the same change.

Do not create a summary queue, phase-local queue, hidden priority list or second
“urgent” sequence. If a task is blocked only on external or human input, record
the blocker and continue with the next dependency-ready task in file order; do
not invent an answer on the user’s behalf.

Closed task bodies move to `CHANGELOG.md`. Keep only durable constraints
and current work here. Replace a task’s status/evidence note rather than
appending contradictory present-tense histories.

### State vocabulary

- `ready`: dependencies are satisfied and this is the next executable work.
- `planned`: specified but waiting for earlier work in the sequence.
- `active`: implementation is in progress on a named worktree/branch.
- `blocked`: a concrete dependency or external decision prevents progress.
- `research-gated`: a falsification probe or product decision is required
  before implementation is authorized.
- `closed`: all task and applicable phase gates passed; closed tasks live only
  in the client changelog.

“Implemented”, “compiles”, “green” and “packet sent” are observations, not
closure states. A flow closes only with evidence that fails when its behavior is
removed.

### Task contract

Every task must leave:

- one bounded behavior or decision, small enough for an independently useful
  commit;
- its positive path plus relevant empty, rejection, interruption and cleanup
  paths;
- deterministic tests or fixtures at the lowest useful layer;
- browser/native evidence where platform behavior is involved;
- updated size, frame, memory or network measurements when it can move a
  budget; and
- current documentation with obsolete claims removed in the same change.

Tests must exercise the layer that owns the claim. Pure geometry, focus-order or
intent-mapping tests are necessary but cannot prove that the browser resized the
canvas, Bevy applied the intended layout, a pointer activated a control, a
resource avoided a change tick or a rendered panel stayed visible. Those claims
need Bevy app/ECS, browser or capture evidence. Production UI types that are
reachable only from tests are scaffolding, not an implemented interaction.

Work estimated in weeks begins with a cheap falsification spike and explicit
kill criteria. A killed experiment is useful evidence and belongs in the
changelog, not a half-built production path.

## Non-negotiable architecture

### Bevy owns the application UI

Every user-facing screen and interactive component inside `client-rs` is built,
laid out, rendered and state-managed in Bevy on WASM and native. This includes
boot and recovery, authentication, registration, character creation/selection,
rankings, HUD, chat, inventory, spells, minimap, commerce, settings,
accessibility semantics and developer diagnostics.

JavaScript and CSS are limited to the canvas host, an unavoidable pre-WASM
fallback and thin adapters for browser capabilities such as history, storage,
clipboard, IME, fullscreen and external links. They do not implement panels,
forms, navigation, overlays or gameplay state, and there is no parallel
DOM/React version to synchronize. The public marketing site is outside this
invariant.

### The server remains authoritative

WASM is controlled by the player. The client may predict, interpolate and hide
invalid actions for responsiveness, but it grants no authority over movement,
combat, inventory, spells, economy, visibility or identity. Shared `ao-core`
code prevents accidental rule drift; it is not an anti-cheat boundary.

### Protocol changes are governed

New server/client packets first receive a parity decision in
`session_route_manifest.ex`, byte-level fixtures and an explicit compatibility
story. WS-only extensions without a VB6 ancestor are
`:intentional_divergence`. TypeScript compatibility is not part of that story.
Any retained VB6/unframed protocol behavior must be named explicitly by the
owning task and remains governed until separately retired; historical frontend
behavior never overrides server authority, bounded parsing or a cleaner
negotiated Rust protocol.

### UI and transport remain separate

Bevy presentation reads typed view models and emits command intents. Widgets do
not parse packets, call sockets or own authoritative rules. Fixture, replay and
live adapters all cross the same boundary.

## Current verified state

The client renders real `AOMP` map data and artwork on all four layers, static
NPC/object records and a composed player body/head. Held-key movement uses the
server’s walk formula and emits real walk packets; `pos_update` applies server
corrections. Direction follows the newest held key. Layers 0–1 render below the
character and layers 2–3 above it; tall overlay art is prefetched beyond the
visible rows and covering overlays fade to 35% over 0.12 seconds. This is a
foundation for, not completion of, depth sorting and trigger-driven roofs.

The game WebSocket measures RTT with client ping 900/server pong 204 once every
five seconds. The client keeps one probe in flight and displays a bounded moving
median beside FPS and population. The echo is verified against a real Ranch
listener before login.

Login requests are now honest: packet 73 is existing-character login and packet
74 is new-character login, including the creation fields the server consumes.
Shared Elixir/Rust fixtures pin their bytes. Runtime configuration resolves from
query string, page metadata and page origin (or `AO_*` native variables), and a
missing credential does not create a character.

The session still does **not** log in end to end. After WS login the server sends
`world_pack_signature` 203 and `session_token` 200, while the Rust decoder only
handles `pos_update` 31 and `pong` 204. The unframed stream cannot skip an
unknown ID safely, so the client correctly fails rather than desynchronizing.

`AppState` currently covers `Boot -> LoadingWorld -> Playing`, with gameplay
systems scoped to `Playing`. Draw memos such as `DrawnTiles`/`DrawnEntities` and
redraw triggers such as `SceneDirty`/`CharacterDrawn` are not lifecycle states;
they remain render bookkeeping until replaced by change detection/events.

The last recorded transfer baseline is **19.2 MB raw / 5.5 MB gzip**. Compressed
bytes are the player-facing budget; raw bytes remain a diagnostic. The next
budget task must remeasure rather than silently treating this snapshot as
current forever.

## Capability unlock map

This is an architecture map, not another work list. It explains why the single
execution sequence is ordered as it is; agents do not select work from this
table.

| Phase | Capability unlocked | Depends on |
| ---: | --- | --- |
| 0 | Responsive, fixture-backed Bevy product shell | Current renderer |
| 1 | Browser/native platform foundation with measured budgets | Phase 0 contracts |
| 2 | Truthful authentication and governed protocol | Phase 1 |
| 3 | Authoritative live world and reconciliation | Phase 2 |
| 4 | Core combat/HUD vertical slice | Phases 0 and 3 |
| 5 | Remaining AO workflow parity | Phase 4 |
| 6 | World/audio fidelity within budgets | Phases 3–5 |
| 7 | Versioned assets and bounded persistent cache | Phase 1; informs Phase 8 |
| 8 | Seamless authoritative map handoff | Phases 3 and 7 |
| 9 | Complete localization/accessibility/UI hardening | Phases 4–6 |
| 10 | Staged, observable production releases | All production phases |
| 11 | Measured experiments and future product ideas | Explicit research gates |

## Execution sequence

Execute the following task bodies from top to bottom. Phase 0 is intentionally
UI-first and fixture-backed; Phase 1 makes the platform boundary real before
protocol breadth. `W-0013` unlocks technical Phase 1 work. `W-0014` is required
before Phase 0 is product-approved, but waiting for participant sessions does
not stop dependency-ready platform work.

## Phase 0 — Responsive Bevy game shell and UI/UX prototype

Build the interface players inhabit before protocol breadth. It uses typed
fixtures now and the same models with a live adapter later. The composition may
learn from `research/argentumunited/README.md`—thin status bar, expanding world,
full-height character rail and a world-centered hotbar—but must not copy its
artwork.

The reference layout contract is:

```text
┌──────────────────────────── global status bar ────────────────────────────┐
│ ┌──────────────── world viewport ────────────────┐ ┌─ character rail ──┐ │
│ │ world messages                                 │ │ identity + XP      │ │
│ │                                                │ │ inventory/spells   │ │
│ │      authoritative world and character        │ │ selected details   │ │
│ │                                                │ │ equipment/currency │ │
│ │              viewport-centered hotbar          │ │ vitals/navigation  │ │
│ └────────────────────────────────────────────────┘ └────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────┘
```

The world viewport grows when the window is maximized. The right rail remains
readable rather than scaling every control proportionally, and the hotbar is
centered within the world area—not beneath the rail. The layout borrows this
information hierarchy from the reference screenshot, not its branded art,
icons, fonts or exact decoration. Reference comparison is performed at the
same browser viewport: the target is comparable information clarity and
interaction quality, not pixel-for-pixel reproduction. Every shipped icon and
decorative asset is project-owned or licensed for this client.

### Task W-0085 — Pointer and hit-test coordinate integrity

- **State:** active
- **Phase:** 0
- **Depends on:** W-0003, W-0005

Define one coordinate pipeline from browser/native pointer position through the
canvas, Bevy UI and world camera. Apply CSS presentation size, backing-store
size, DPR, UI scale, camera viewport offset and world projection exactly once.
The control that is visibly under the pointer must be the control that receives
the event, and UI interception must prevent the same click from reaching the
world.

Exercise DPR 1.0, 1.25, 1.5, 1.75 and 2.0 at windowed, maximized and fullscreen
sizes. For representative inventory, spell, hotbar, tab and dialog controls,
click the center, every edge one pixel inside and one pixel outside; assert the
expected entity activates exactly once. Click the center and four edges of the
world viewport and prove the selected tile matches the rendered tile without an
off-by-one error. Repeat after resize, browser zoom and DPR change.

Pointer capture must survive an in-progress drag while the pointer remains in
the window and cancel cleanly on focus loss, pointer exit, panel removal or an
invalidating resize. Close with browser-driven input tests plus Bevy app tests;
screenshots and pure coordinate arithmetic alone are insufficient.

### Task W-0006 — Character, vitals, inventory and equipment prototype

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0004, W-0005

Implement fixture-backed character/XP, HP, mana, stamina, hunger, thirst,
skills, currency, inventory, equipment, selected item detail, quantities and
visible locked slots. Exercise selection, equip/use/drop intent, splitting,
drag cancellation, insufficient state and authoritative rejection/rollback
presentation without claiming mock actions are live gameplay.

The rail uses a deliberate information hierarchy: prominent character name;
secondary class and level; XP bar; world time/status; compact currency and
equipment summaries; then vitals and navigation. Gold does not consume the
identity header when it can be scanned in the currency row. Equipment state is
shown with recognizable slot/item icons and concise counters, not a permanent
list of raw item names; full names, statistics and durability live in selection
details or tooltips.

Connect rendered slots to the W-0005 interaction system. Single click selects,
double click emits exactly one use/equip intent, Shift-click opens or applies an
explicit split/drop quantity rule, and drag/drop emits a move only for a valid
distinct destination. Escape, pointer leaving the window, focus loss, panel
close and grid rebuild all cancel a drag and remove its ghost.

Do not infer item behavior from stack quantity. Item action/category metadata
in the view model decides whether activation equips, uses or opens an item;
tests cover a single-use consumable and a non-stackable piece of equipment.
Render item GRH icons, corner quantity overlays, equipped markers, visible
locked slots and distinct hover/focus/selection/pending/rejected states in the
actual rail. Unknown GRHs use a stable visible fallback. Selection is keyed by
stable item/slot identity and survives an unrelated snapshot update; removal,
replacement or panel close clears it deterministically. While an action is
pending, accidental double activation cannot emit a duplicate command. The
fixture snapshot changes only after simulated authority accepts an intent;
rejection leaves the authoritative item in place and shows semantic feedback.

Close with Bevy interaction tests that click and drag spawned slot entities and
assert `IntentMessage` output and cleanup. Testing an intent-mapping helper or
`DragState` alone does not prove that the interface is operable.

### Task W-0007 — Spellbook and hotbar prototype

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0004, W-0005

Implement spells, requirements, target modes, cooldowns and persistent numbered
hotbar assignment/use with fixtures. Cover insufficient mana/stamina/skill,
equipment masks, land/water, target-level, area and dead-target restrictions as
typed presentation states whose final authority remains server-side.

Complete the rendered flow:

- inventory/spell tabs are equal-width controls with distinct hover, focus,
  pressed and selected states, preserve the selected tab across harmless
  snapshots and switch visible content with keyboard and pointer input without
  moving the surrounding rail;
- clicking a ready self/area spell emits one cast intent; an entity/ground spell
  arms visibly, consumes the next valid world target and disarms on cast,
  Escape, death, disconnect or authoritative rejection;
- spell rows and hotbar slots display GRH icon, cost, disabled reason, cooldown
  and quantity overlays, key labels, disabled reason, cooldown overlay and
  focus/selection/activation state; semantic keys are localized by the UI
  boundary rather than shown raw to players;
- number keys and pointer clicks share one hotbar activation path, are suppressed
  while text owns focus and never fire a cooling or empty slot; and
- assignment, replacement, removal and page controls are usable and persist in
  the fixture adapter without pretending the server accepted them.

Close with Bevy app tests that interact with spawned spell/hotbar entities and
observe intents, armed state and rendered blockers. Pure spell-activation and
hotbar-intent tests do not prove that the interface is operable.

### Task W-0008 — Chat, target, safety and feedback prototype

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0004, W-0005

Implement world messages, chat channels, bubbles, current target, personal and
party safety, navigation/dead restrictions, notifications and contextual
actions. Define focus ownership so chat, IME, password fields and modals suppress
movement/combat/hotkeys. Cover cooldown, mute, rejection and disconnect feedback.

World chat is a bounded upper-left overlay with wrapping, fading, expansion and
channel filters; long announcements cannot run beneath or obscure the minimap.
Fixtures include the local name, several player/NPC names, bubbles, combat text,
a selected target and success/failure feedback so the HUD is judged under real
Argentum visual density rather than an empty map. Labels apply deterministic
priority, overlap and distance/fade rules instead of becoming an unreadable
stack.

The selected-target presentation distinguishes player, NPC, object and ground
targets, exposes only server-authorized information, and clears immediately on
despawn, death, map change, range/visibility loss or disconnect. Feedback is
visible without relying only on chat color.

### Task W-0088 — Fixture-backed minimap presentation

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0004, W-0005, W-0008

Replace the unexplained black minimap well with a fixture-backed Bevy minimap
contract while keeping unavailable/loading/error states honest. Render the
current map outline or tile abstraction, player marker, permitted party/NPC or
objective markers, orientation and coordinates from typed presentation data;
do not derive hidden authoritative entities from downloaded map assets.

Markers use stable icon/shape distinctions in addition to color, stay clipped
to the minimap, and expose localized tooltips where interaction is supported.
Resize, compact mode, UI scale, map change and malformed/missing map data cannot
stretch the map, leak state from the previous map or leave an unlabeled black
rectangle. Phase 0 closes the presentation and fixture behavior; W-0039 owns
the later authoritative live-world connection.

### Task W-0089 — Tab world-map overlay

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0003, W-0004, W-0005, W-0008, W-0085, W-0088

Implement the full world map as a Bevy-owned overlay within the world viewport,
leaving the global top bar and character rail visible and interactive as in the
reference workflow. In gameplay/world input context, Tab opens the map and Tab
or Escape closes it. Opening the map hides or disables the world hotbar and
world targeting, releases any armed spell/drag/pointer capture under their
documented cancellation rules, and pauses movement/combat command emission
without pausing the authoritative session.

The initial view fits the whole known world while preserving aspect ratio with
intentional crop/letterbox treatment. Support bounded pointer-wheel and
keyboard zoom, pointer drag and keyboard pan, reset-to-fit, recenter-on-player
and stable zoom-around-cursor behavior. Clamp every path to finite map bounds;
malformed coordinates, a zero-sized viewport or repeated open/close cannot
produce NaN transforms, reveal uninitialized texture memory or lose the last
valid camera state. Persist the last valid pan/zoom for the session while a
separate reset action always restores the whole-world view.

Render the player marker, current region name and world coordinates plus typed,
toggleable categories for merchants, quests, dungeons and points of interest.
Markers are project-owned icons with localized labels, hover/focus states and
non-color distinctions. The client renders only discovered or server-authorized
markers; map resources cannot reveal hidden NPCs, players, objectives or
resources. Filtering changes presentation only and never authoritative world
state. Empty, unavailable, loading, stale-version and missing-icon states remain
actionable and cannot silently degrade into a black rectangle.

Use a dedicated bounded world-map asset/manifest entry rather than decoding or
retaining the complete gameplay world pack to draw the overview. Specify source
license, compressed/decoded/GPU byte cost, maximum texture dimensions and a
fallback for devices below that limit; Phase 7 later content-hashes and caches
the production asset.

Close with Bevy app and browser tests proving input-context priority, one toggle
per keypress, no movement/cast/target command while open, correct rail
interaction, pan/zoom clamping and marker filtering. Capture whole-world,
zoomed, panned, filtered and unavailable views at the Phase 0 size/DPR matrix,
including close/restore after resize, maximize and fullscreen.

### Task W-0009 — Bevy product screens

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0004, W-0005

Build fixture-driven boot/loading, login, registration, character selection,
character creation with sprite preview, rankings, maintenance, reconnect,
invalid-session and recovery screens. These are real Bevy navigation states,
not DOM placeholders, and include empty/error/slow outcomes before Phase 2
connects services.

The rail's bottom navigation is a real, compact icon-button row using the
shared control path, localized tooltips and accessible names. It provides the
supported routes for character/statistics, journal/quests, achievements,
party/social, clan/faction, map and settings plus an explicit session/logout
action. Unimplemented destinations are visibly disabled with a reason; the
production UI never ships a `navigation — not yet wired` text panel.

### Task W-0090 — Atomic first-scene reveal

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0001, W-0003, W-0004, W-0009

Keep the Bevy loading/recovery screen fully visible until the first playable
scene can be presented as one complete frame. Do not expose the world camera,
partially populated rail, checkerboard, missing sprites or progressively
appearing map layers while required first-scene work is still downloading,
decoding, spawning or uploading to the GPU.

Define a versioned `FirstSceneRevealSet` rather than interpreting “everything”
as the entire game archive. At minimum it contains validated current-map data;
every texture sheet and tall-overlay dependency intersecting the initial
viewport plus its bounded prefetch margin; local-player body/head/equipment;
required fallback sprites; primary font and HUD/icon atlases; initial typed HUD
snapshot; shader/pipeline readiness where observable; and completion of the
GPU uploads needed by the first frame. Unrelated maps, optional music and assets
outside the reveal set may continue through bounded background loading after
reveal, but an asset already required by the visible scene may not pop in later.

Stage the candidate under a monotonically increasing load generation in a
hidden/pending scene root. Commit visibility on one frame boundary only after
all reveal-set members are ready and one complete candidate frame passes its
readiness check. A retry, character switch, reconnect, resize or newer map/load
generation cancels the stale candidate and its work; late completions cannot
reveal an obsolete scene. Gameplay input and world intents remain disabled
until commit, while the network/session continues processing within its normal
bounds.

Progress is truthful and monotonic within one generation: report named map,
asset, decode/GPU and snapshot stages plus known bytes/items, never infer 100%
from request dispatch or asset-handle creation. Required failure, timeout,
corruption, unsupported texture size and memory-budget rejection stay on an
actionable loading/error screen with retry/back/logout choices. An explicitly
approved visible fallback may satisfy a missing optional visual; silently
revealing a partial world may not.

Close with deterministic loader tests that shuffle completion order and delay
one required texture by two seconds: every frame before readiness contains the
loading screen and no world pixel, and the next visible world frame contains
all reveal-set layers, character composition and HUD. Repeat with warm cache,
one failed asset, stale-generation completion, resize/maximize/fullscreen and
1,000 load/cancel/retry cycles while checking entity, texture, listener and
memory cleanup. Record time-to-complete-first-frame separately from time to
download the full optional asset set.

### Task W-0010 — Secondary windows and interaction ownership

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0005

Implement open/close/focus, z-order, modal behavior, movement,
snapping/docking, optional resize, remembered positions, Escape semantics and
restoration after viewport changes. Specify click/double-click/right-click,
drag/drop, quantity and tooltip timing once rather than per panel.

### Task W-0011 — Settings, guidance and accessibility fixtures

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0006, W-0007, W-0008, W-0009, W-0010

Prototype remappable input, UI/chat scale, audio, reduced motion and
color-sensitive settings; keyboard focus/semantics; and contextual guidance for
movement, interaction, combat, inventory, spells, death and recovery. Exercise
long ES/EN/PT strings, Unicode composition, missing localization and unavailable
capabilities.

Offer persistent named UI-scale choices covering at least 90%, 100%, 110% and
125% (or measured equivalents), independent of logical world framing and DPR.
Text keeps a documented readable minimum, pixel-art icons use the intended
nearest-neighbor sampling, tooltips remain on-screen and changing UI scale
preserves focus, selection, composing text and camera center. Every
color-sensitive state has a non-color cue.

### Task W-0087 — Worst-case UI data and fallback fixtures

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0004, W-0006, W-0007, W-0008, W-0009, W-0011

Add one deterministic stress fixture using the server/protocol maximum for every
bounded collection: all inventory and equipment slots occupied, the maximum
spellbook and hotbar pages, the retained chat-message limit, the longest valid
character/item/spell labels and the largest supported numeric values. If a
maximum is not currently defined, define and document a named client display or
retention cap before constructing the fixture; do not choose a silent arbitrary
number.

Add a separate realistic busy-HUD fixture: several nearby players and NPCs with
names, chat and system messages, a selected target, damaged vitals, equipment,
a full first inventory page, assigned item/spell hotbar slots, active cooldowns,
quantities and one rejected/pending action. It must exercise the actual world,
rail, minimap and hotbar together; an empty scene with placeholder labels is
not sufficient visual evidence.

Add independent failure variants for an unknown/missing GRH icon, unavailable
primary font, missing localization key, oversized translated label and malformed
numeric value. Each produces a stable visible fallback, preserves layout and
remains actionable where safe. Player-facing screens must not expose a raw
semantic key, collapse a slot to zero size or replace a whole panel with an
empty black rectangle.

Record spawned UI entity count, rebuild count and p95 frame time while the
fixture is visible for ten seconds. Reapplying an identical fixture performs no
rebuild; switching away and back returns to the same bounded entity count. W-0020
sets production budgets later, but this task records the Phase 0 baseline and
fails monotonic entity or memory growth.

### Task W-0012 — Component gallery and deterministic visual harness

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0002, W-0003, W-0004, W-0005, W-0006, W-0007, W-0008, W-0009, W-0010, W-0011, W-0085, W-0087, W-0088, W-0089, W-0090

Create a Bevy component gallery and scripted capture harness sharing the same
fixtures as production UI. Pin fonts, seed, animation time, map/camera, locale,
logical resolution, DPR and GPU tolerance. Store approved goldens for 720p,
1080p, 1440p, ultrawide, small laptop, compact rail, maximized and fullscreen;
include peaceful, realistic busy-HUD, combat, loading, empty and rejected
states plus whole-world and zoomed/filtered Tab-map states. Reference-layout
comparisons use the same browser viewport and record shell bounds, world/rail
ratio and UI scale so conclusions are not drawn from differently sized
captures.

### Task W-0086 — Resize and UI lifecycle stress

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0002, W-0003, W-0005, W-0006, W-0007, W-0008, W-0009, W-0010, W-0012, W-0085, W-0087, W-0088, W-0089, W-0090

Run the production Bevy tree through repeated lifecycle changes rather than
testing each layout once. A scripted test performs 250 alternating resizes
across minimum, 720p, 1080p and ultrawide bounds; 1,000 panel open/close cycles;
1,000 inventory/spell tab switches; 1,000 Tab-map open/close cycles with bounded
pan/zoom/filter changes; repeated first-scene load/cancel/retry cycles; repeated
maximize/fullscreen restoration; and a zero-sized/minimized canvas followed by
restoration.

After every settled transition there is exactly one shell root, top bar, world
camera, rail and hotbar. Hidden or removed controls cannot retain focus; no drag,
tooltip, modal, armed spell or captured pointer survives the transition that
invalidates it. A zero-sized surface produces no panic, NaN, enormous viewport
or world command, and restoration produces a correctly laid-out frame within
two rendered frames.

Record entity count, active browser listeners/observers and WASM/native memory
before and after the run. Counts return to the documented baseline except for
explicit bounded caches; they cannot grow once per cycle. Run the stress path in
native and a real browser, not only against pure layout functions.

### Task W-0013 — Phase 0 technical evidence

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0001, W-0002, W-0003, W-0004, W-0005, W-0006, W-0007, W-0008, W-0009, W-0010, W-0011, W-0012, W-0085, W-0086, W-0087, W-0088, W-0089, W-0090

Run the Phase 0 technical checklist, archive capture artifacts and correct every
failed contract. This closes the engineering gate and unlocks Phase 1; it does
not fabricate the human usability evidence owned by W-0014.

Run formatting, clippy, WASM/native checks and tests from the pinned Nix
toolchain. Phase 0 UI code has no unused imports; production interaction types
must not be dead code. Record client/core test counts, optimized raw+gzip size,
browser engine/version, GPU/backend and the full capture matrix. Before moving
any body to the changelog, verify its closure evidence exercises the claimed
layer and add the dated commit plus evidence to `CHANGELOG.md`; a green
structural roadmap count is not task-completion evidence.

### Task W-0014 — Veteran and newcomer usability validation

- **State:** planned
- **Phase:** 0
- **Depends on:** W-0013 and recruited participants

Run task-based sessions measuring whether veterans and newcomers can find
health/mana, use/equip an item, cast a spell, trade, bank, change chat channel
and recover from rejection. Record protocol, findings, resulting revisions and
remaining tradeoffs. This is the Phase 0 product-approval gate but does not hold
idle dependency-ready Phase 1 engineering.

### Phase 0 exit gate

`W-0013` owns the technical checks below and unlocks Phase 1. Participant checks
close through `W-0014`; scheduling people does not idle ready technical work.

- [ ] At 720p, 1080p, 1440p, ultrawide and small-laptop sizes, the world expands,
      the rail remains usable, compact mode is deliberate and the hotbar stays
      centered on the world viewport.
- [ ] The browser canvas follows the content viewport on load, resize and
      maximize within one pixel, creates no page scrollbar and leaves no
      accidental host-page perimeter; the host contains no persistent gameplay
      hint or application panel.
- [ ] Windowed, maximized and fullscreen captures stay pixel-aligned across the
      DPR 1.0/1.25/1.5/1.75/2.0 and supported OS-scale matrix; world, UI and
      physical scale remain separate.
- [ ] At UI scale 1.0 and greater than 1.0, Bevy `ComputedNode` bounds for the
      top bar, world and rail agree with the world-camera viewport. A DPR-only
      change preserves logical camera framing and visible tile count.
- [ ] Resize, zoom, DPI and fullscreen do not move the player, alter visibility,
      stretch sprites, shimmer the camera or lose composing text.
- [ ] FPS refreshes at most once per second; background throttling is labelled
      background/paused and cannot overwrite the foreground sample as “10 FPS”.
- [ ] Ping runs once per five seconds with one probe in flight, no per-frame
      sends and no catch-up burst after suspension, focus or reconnect.
- [ ] Product screens and HUD workflows are Bevy-owned and cover populated,
      empty, loading, disabled, rejected, disconnected, dead/ghost and malformed
      fixture states.
- [ ] Initial load keeps the complete loading screen visible until the named
      first-scene reveal set, authoritative snapshot and required GPU uploads
      are ready; one frame-boundary commit reveals a complete map, character
      and HUD with no partial layers or progressive visible pop-in.
- [ ] A two-second delayed required texture, shuffled completion, stale load,
      warm cache, failure and cancellation keep progress truthful and cleanup
      bounded. Background loading after reveal contains only assets not required
      by the already visible scene.
- [ ] In gameplay context, one Tab press opens a whole-world map inside the
      world viewport while preserving the rail; Tab/Escape closes it. Fit,
      pan, zoom, reset, player recenter and merchant/quest/dungeon/POI filters
      work by pointer and keyboard without leaking movement, combat, targeting
      or hidden authoritative information.
- [ ] The minimap and Tab map have labelled unavailable/loading/error states,
      project-owned marker icons, bounded resources and deterministic captures;
      neither can become an unexplained black well.
- [ ] Full and compact rail trees contain visible, usable content; compact mode
      includes at least one vital indicator and one navigation control, and no
      rail mode degrades to an unexplained empty black rectangle.
- [ ] The rendered rail uses real/fallback GRH icons, quantity and cooldown
      overlays, stable selected/equipped/pending/rejected states, compact
      currency/equipment summaries and equal-width Inventory/Spells tabs; no
      raw fixture label or permanent textual equipment/navigation placeholder
      substitutes for the intended control.
- [ ] Top-bar and bottom-navigation actions use project-owned icons with
      localized tooltips and accessible names, while FPS, ping and population
      remain readable textual status. Disabled destinations explain why they
      are unavailable.
- [ ] Persistent 90/100/110/125% UI-scale choices (or measured equivalents)
      preserve world framing, focus, selection and camera center; text remains
      legible, pixel icons remain crisp and tooltips stay inside the viewport.
- [ ] Pointer and keyboard input traverse, focus and activate real spawned Bevy
      controls. Inventory/spell/hotbar interactions emit typed intents through
      the shared control path; no production control model exists only in tests.
- [ ] At every supported DPR and after resize/zoom/fullscreen changes, clicks at
      control centers and boundaries activate exactly the rendered control;
      world clicks resolve to the rendered tile and intercepted UI clicks emit
      no world command.
- [ ] Twenty identical snapshot writes produce no Bevy change tick or UI
      rebuild; one semantic change produces exactly one rebuild; malformed NaN
      data settles without whole-snapshot debug formatting.
- [ ] The named worst-case fixture renders bounded maximum inventory, equipment,
      spells, hotbar and chat data plus longest labels. Missing GRH/font/key and
      malformed-value variants remain stable, legible and free of raw semantic
      keys; entity/rebuild/frame baselines are recorded.
- [ ] A realistic busy-HUD capture contains nearby named players/NPCs, bounded
      chat, a selected target, damaged vitals, a populated inventory/equipment
      state, assigned hotbar items/spells, active cooldowns and pending/rejected
      feedback without overlap or loss of actionability.
- [ ] Focus, modal/chat ownership, drag cancellation, tooltips and IME never
      leak unintended world commands.
- [ ] The native/browser lifecycle stress run completes 250 resizes, 1,000 panel
      cycles and 1,000 tab switches. Shell/camera roots remain unique, invalid
      transient state is cleared and entity/listener/memory counts do not grow
      once per cycle.
- [ ] Component gallery and production UI share models, intents, fixtures,
      tokens and components; the deterministic golden matrix passes.
- [ ] Source/browser checks find no DOM/CSS application panel, form, navigation
      state or alternate HUD.
- [ ] Pinned-toolchain format, clippy, WASM/native and test gates pass with no
      unused imports and no unexplained dead production UI path. Recorded
      evidence includes test counts, browser/GPU details and raw+gzip size.
- [ ] Every closed Phase 0 task has exactly one dated `Completed Task W-NNNN`
      changelog entry with commit and evidence, and no closed body remains in
      the active execution sequence.
- [ ] Veterans and newcomers complete the recorded usability protocol; findings,
      revisions and deliberately rejected suggestions are documented.

## Phase 1 — Platform foundation

Make the prototype honest while the platform-specific surface is still small.
Minimal platform interfaces are scheduled immediately after the Phase 0
technical gate; Phase 0 may use deterministic adapters until then.

### Task W-0015 — Platform-service traits and capabilities

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0004

Define narrow services for HTTP, WebSocket, persistent cache, auth/token
storage, audio, clipboard, IME/text composition, fullscreen/window, browser
history and external links. Define capability results and failures without
spreading `cfg(wasm32)` into gameplay or UI systems.

### Task W-0016 — Browser adapters and host boundary

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0015

Implement browser services, gesture-gated fullscreen/audio, resize/DPR/IME,
storage denial/quota, history and external-link behavior. Source/browser tests
must prove the host contains only canvas, pre-WASM fallback and thin adapters—no
application forms, panels or duplicate state tree.

### Task W-0017 — Native adapters and build parity

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0015

Replace native HTTP/WebSocket and platform stubs with real implementations and
provide cache, clipboard, text composition, window/fullscreen, audio and link
services. Move pure parsers/rules into `ao-core`; both targets and all
platform-independent tests remain green.

### Task W-0018 — Honest lifecycle states

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0015

Extend application/session state only when transitions exist:
`Boot -> Authenticate -> SelectCharacter -> LoadWorld -> Playing`, plus
`Reconnecting` in Phase 2 and `Handoff` in Phase 8. Keep render memos and redraw
triggers as render concerns/change detection, not application states. Reset
session-scoped resources explicitly at every transition.

### Task W-0019 — Same-origin staging deployment

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0016

Serve the WASM client and runtime configuration from the game origin while
retaining explicit development overrides. Define a reproducible staging deploy,
health check, cache headers, rollback and browser smoke path; no production host
or credential is compiled into the artifact.

### Task W-0020 — Budgets and capability profiles

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0016, W-0017

Remeasure optimized raw/gzip WASM and enforce a documented 5% unexplained-
regression threshold. Establish fixed browser/device/network profiles and
numeric ceilings for first interactive world, p95 frame, draw calls, WASM heap,
estimated GPU memory and reconnect/handoff. Probe WebGL2, texture size, DPR,
audio, persistent storage/quota and memory signals; select a tested low-resource
profile or actionable unsupported-device screen.

### Phase 1 exit gate

- [ ] `./build.sh check` passes for WASM and native, including both crates and
      the roadmap gate.
- [ ] Browser/native platform services share narrow contracts and no platform
      conditionals leak into gameplay/UI.
- [ ] No credential/production host is compiled in; the browser host contains
      only canvas, fallback and thin adapters.
- [ ] Lifecycle state is explicit and draw memos/redraw triggers remain render
      concerns.
- [ ] Same-origin staging deploy, health check, smoke test and rollback repeat.
- [ ] CI publishes raw/gzip size and fixed startup/frame/draw/heap/GPU/network
      budgets, failing unexplained regressions.
- [ ] Supported, low-resource and unsupported capability profiles reach stable,
      actionable outcomes without identifying diagnostics.

## Phase 2 — Governed protocol and real authentication

The first goal is one truthful session, not broad packet count.

### Task W-0021 — Protocol-v2 parity decision

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0020

Classify version/framing extensions in `session_route_manifest.ex`, reserve IDs,
define legacy compatibility and add byte fixtures before implementation. Record
why the divergence is necessary and how it is disabled or rolled back.

### Task W-0022 — Negotiated length-framed WebSocket transport

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0021

Negotiate a versioned WS subprotocol/capability that carries unchanged AO packet
bytes inside a bounded length envelope. Modern clients safely skip unknown
packets; legacy TCP/WS remains unframed. Test fragmentation, concatenation,
unknown IDs, hostile lengths and downgrade behavior.

### Task W-0023 — Canonical protocol schema decision

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0021

Choose and prove one source: machine-readable schema checked against Elixir
goldens, an Elixir-source extractor with verification, or manual Rust codecs
with paired fixtures. Code generation begins only after its source is trusted.

### Task W-0024 — Login bootstrap decoding

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0022, W-0023

Decode session token 200, world-pack signature 203, explicit login success and
all bootstrap/error responses. Validate content version/hash before entering
the world and prove a real existing character reaches the authoritative
bootstrap with packet 73.

### Task W-0025 — Live Bevy account and character flows

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0009, W-0016, W-0024

Connect Bevy registration, login/logout, server-provided character options,
creation/preview, selection, launch and rankings to REST and the game socket.
Use launch token plus character ID; never send account passwords over the game
protocol. Preserve reloadable routes/history on web and equivalent navigation
on native.

### Task W-0026 — Normal-play packet coverage

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0023, W-0024

Add paired fixtures and Rust handlers for entity create/move/change/remove,
chat/structured console events, stats, inventory, spells, objects, weather, map
change, intervals, build/version and errors. Unknown framed packets are counted
and skipped; unknown legacy packets fail without desync.

### Task W-0027 — Connection lifecycle and recovery

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0018, W-0024

Implement meaningful close reasons, bounded heartbeat/RTT, exponential backoff,
token expiry and explicit `Playing` only after bootstrap. Classify credentials,
ban/mute, full, maintenance, stale world/assets and preload failures into Bevy
states with independent retry/reconnect/forget-session actions.

### Task W-0028 — Redacted trace and deterministic replay

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0022, W-0026

Record bounded inbound/outbound frames, timestamps, state transitions and
build/world versions without passwords, tokens, cookies or private account
data. Replay without a socket and inject fragmentation, latency, reordering
where legal and disconnect boundaries.

### Task W-0029 — Bounded network queues

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0022

Bound incoming frames/decoded packets and pending commands by bytes/count;
budget processing per frame and observe WebSocket buffered amount. Overflow
must disconnect/resnapshot explicitly, never grow forever, silently drop
authoritative state or freeze one render frame.

### Phase 2 exit gate

- [ ] Protocol v2/new packets are classified and byte-pinned before use; legacy
      streams remain compatible and framed streams skip unknown IDs safely.
- [ ] Framing/codec fuzz tests survive truncation, concatenation, fragmentation,
      hostile lengths and arbitrary unknown IDs without panic or desync.
- [ ] A real existing character uses packet 73, validates packet 203, accepts
      token 200 and completes authoritative bootstrap; packet 74 is creation-only.
- [ ] Registration, preview/creation, selection, launch, rankings, logout, deep
      links and history work through Bevy.
- [ ] Redacted traces replay deterministically and contain no password, token,
      cookie or account secret.
- [ ] Network bursts stay bounded and every auth/bootstrap failure offers the
      correct recovery without an invisible live session.

## Phase 3 — Authoritative client state and live world

### Task W-0030 — Bootstrap-owned world

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0024, W-0026, W-0090

Take map, position and identity from the login snapshot; remove demo coordinates
and `INITIAL_MAP`. Feed the authoritative snapshot and map dependency set into
the W-0090 reveal barrier; a pack record may preload art but never prove that an
entity currently exists or that the first scene is ready.

### Task W-0031 — Authoritative ECS identity

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0030

Represent players, NPCs and objects as live ECS entities keyed by authoritative
identity. Apply create/move/change/remove idempotently and test duplicates,
unknown removes, late packets and churn without leaks.

### Task W-0032 — Prediction, interpolation and reconciliation

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0031

Separate fixed-step intent, local prediction, authoritative correction and
remote interpolation. Reset `WalkGate` on login/reconnect/handoff. Measure step
interval distribution so camera or cadence pauses are diagnosed from data.

### Task W-0033 — Reconnect/resnapshot contract

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0027, W-0031

Define server/client resynchronization: a fresh epoch/snapshot replaces stale
entities and inputs, and movement accumulated while disconnected or asleep is
not blindly replayed.

### Task W-0034 — Client architecture split

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0030

Separate transport/session, authoritative model, presentation and Bevy UI before
packet breadth causes another monolith. Raw packet structures never become
widget resources.

### Task W-0035 — Bounded developer diagnostics

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0032, W-0034

Add feature/build-gated Bevy diagnostics for redacted packets, authoritative vs
predicted position, corrections, cadence, tile inspection, budgets and
build/world IDs. Release builds keep bounded metrics without private operator
tools.

### Phase 3 exit gate

- [ ] Bootstrap is the only source of initial map, position and identity.
- [ ] Entity create/change/move/remove is idempotent; duplicate, unknown, stale
      and churn cases leak nothing.
- [ ] Prediction stays responsive under injected latency and converges without
      oscillation; interpolation never rewrites authority.
- [ ] Login/reconnect/handoff reset `WalkGate`, held input and stale epoch state.
- [ ] Reconnect obtains a fresh snapshot and never replays asleep/offline input.
- [ ] Fixture, replay and live adapters produce equivalent typed snapshots; no
      widget reads packets and release builds omit private diagnostics.

## Phase 4 — Core playable HUD vertical slice

### Task W-0036 — Live UI adapter

- **State:** planned
- **Phase:** 4
- **Depends on:** W-0004, W-0034

Drive the Phase 0 models/intents from authoritative state. Fixture, replay and
live snapshots for the same trace must agree; widgets remain packet-blind.

### Task W-0037 — Inventory and equipment end to end

- **State:** planned
- **Phase:** 4
- **Depends on:** W-0036

Select, move, use, split, drop and equip supported layers with quantities,
locked/disabled/dead states and authoritative rollback after rejection,
interruption or reconnect.

### Task W-0038 — Magic and hotbar end to end

- **State:** planned
- **Phase:** 4
- **Depends on:** W-0036

Implement spell selection/assignment, target/cancel, cast, cooldown/interval,
resource/skill/equipment/terrain/level/area/dead constraints and server
correction through the live path.

### Task W-0039 — Targeting and world interaction

- **State:** planned
- **Phase:** 4
- **Depends on:** W-0036

Select characters/NPCs/objects/tiles, face/use/pick up/drop and preserve server
range, navigation and visibility. Cover target disappearance and map change.
Connect the W-0088 minimap and W-0089 Tab map to the authoritative current map,
player position and explicitly authorized/discovered marker feed. Map opening,
filtering and panning remain client presentation; any travel, targeting or
context action returns through an ordinary validated intent and cannot infer
entities outside server visibility.

### Task W-0040 — Combat and safety end to end

- **State:** planned
- **Phase:** 4
- **Depends on:** W-0038, W-0039

Implement attack/weapon use, damage/block/status, personal/party safe modes,
safe zones and death/ghost gating with rejection/correction evidence.

### Task W-0041 — Chat end to end

- **State:** planned
- **Phase:** 4
- **Depends on:** W-0036

Implement public/private/party/clan/faction channels, filters, bubbles and
mute/moderation feedback. Unicode limits are consistent and input focus cannot
leak gameplay commands.

### Phase 4 exit gate

- [ ] A real character fights, loots, moves/equips/uses/drops items, casts
      constrained spells, uses hotkeys, chats and toggles safety through Bevy.
- [ ] The live minimap and Tab map follow authoritative map/player state, clear
      stale markers on map change/reconnect and reveal no entity or objective
      outside the server-authorized marker feed.
- [ ] Inventory, magic, targeting, combat and chat cover success, rejection,
      interruption, death, map change and reconnect where applicable.
- [ ] Server correction rolls back without duplicate items, cooldowns, targets
      or commands.
- [ ] Fixture/replay/live model states agree and UI owns no authoritative rule.
- [ ] Every supported workflow has Rust-owned app/browser evidence. Historical
      TypeScript tests or traces may inform cases but are not compatibility,
      coverage or release gates.

## Phase 5 — Remaining gameplay parity

### Task W-0042 — NPC dialogue and services

- **State:** planned
- **Phase:** 5
- **Depends on:** W-0040

Complete dialogue, training, healing, resurrection, quests where supported and
other contextual services with success, rejection, cancel and reconnect.

### Task W-0043 — Economy workflows

- **State:** planned
- **Phase:** 5
- **Depends on:** W-0037

Complete NPC commerce, bank item/gold and player trade, including quantities,
confirmation, insufficient funds/capacity, cancellation and disconnect.

### Task W-0044 — Social, clan and faction workflows

- **State:** planned
- **Phase:** 5
- **Depends on:** W-0041

Implement party/clan membership and leadership, invites, rosters, clan creation,
block/mute/report and permission-aware faction/moderation feedback.

### Task W-0045 — Death and recovery

- **State:** planned
- **Phase:** 5
- **Depends on:** W-0040, W-0042

Complete ghost presentation, allowed commands, lost/retained state,
resurrection and authoritative return to play.

### Task W-0046 — Travel, survival and service commands

- **State:** planned
- **Phase:** 5
- **Depends on:** W-0042

Cover travel restrictions, hunger/thirst, rest, meditation and navigation plus
help, MOTD, uptime, rewards, account/position/stats/skills resync and punishment
lookup where supported. Client gating improves feedback but grants no trust.

### Task W-0047 — Versioned gameplay metadata

- **State:** planned
- **Phase:** 5
- **Depends on:** W-0023

Govern spell requirements, XP thresholds, object/NPC definitions and faction
labels so incompatible/stale presentation data is rejected before `Playing`.

### Task W-0048 — Workflow parity matrix

- **State:** planned
- **Phase:** 5
- **Depends on:** W-0042, W-0043, W-0044, W-0045, W-0046, W-0047

Map each supported workflow to commands, packets, Rust handlers, Bevy UI,
VB6/server behavior where still governed, and Rust end-to-end tests. “Packet
decoded” is not a completed row. Consult old TypeScript E2E tests only when they
provide useful behavioral evidence; do not reproduce obsolete frontend
behavior or require one-for-one test migration.

### Phase 5 exit gate

- [ ] Scripted characters complete NPC services, commerce/bank, player trade,
      party/clan, death/recovery, travel/survival and service commands end to end.
- [ ] Every workflow covers success, rejection, cancellation/interruption and
      reconnect.
- [ ] Incompatible spell, XP, object/NPC or faction metadata is rejected before
      `Playing`.
- [ ] The workflow parity matrix has no unexplained Bevy-exposed row.
- [ ] Trace replay reproduces a regression from every major workflow and the
      supported Rust workflows have independent end-to-end coverage.

## Phase 6 — World fidelity and audio

### Task W-0049 — Character animation and equipment composition

- **State:** planned
- **Phase:** 6
- **Depends on:** W-0031

Resolve animated GRHs, body walk speeds/cycles and weapon, shield, helmet, cart
and backpack layers in VB6-compatible order.

### Task W-0050 — Depth sorting and trigger-driven roofs

- **State:** planned
- **Phase:** 6
- **Depends on:** W-0031

Replace spawn-order overlap with measured row/depth ownership and ship map
triggers through server encoding. Implement trigger 1 building/roof visibility
for the Rust client. Existing over-character layers and fade are supporting
evidence, not closure; the TypeScript renderer is not a compatibility target.

### Task W-0051 — Bounded tile and texture streaming

- **State:** planned
- **Phase:** 6
- **Depends on:** W-0020, W-0030

Request missing sheets ahead of movement, retain tall art and despawn material
outside byte-budgeted windows without visible holes or unbounded GPU growth.
Every dependency in the initial visible window belongs to W-0090's reveal set;
post-reveal streaming may not use ordinary movement into an unloaded visible
tile as an excuse for pop-in.

### Task W-0052 — Labels, fades, weather and visual FX

- **State:** planned
- **Phase:** 6
- **Depends on:** W-0050

Complete tree/occluder fading, names, chat bubbles, combat text, weather,
day/night and shaders with reduced-motion/color-sensitive alternatives. Preserve
the existing overlay-fade behavior with deterministic coverage tests.

### Task W-0053 — Music and positional audio

- **State:** planned
- **Phase:** 6
- **Depends on:** W-0015

Implement map music and positional effects with separate controls. Browser
audio unlocks on gesture, suspends in background and resumes without overlap.

### Task W-0054 — Renderer profiling and optimization

- **State:** planned
- **Phase:** 6
- **Depends on:** W-0051, W-0052

Measure against Phase 1 frame/draw/memory ceilings. Add chunk meshes, batching
or instancing only when measurements demand them; keep culling, entity and
texture cleanup observable.

### Phase 6 exit gate

- [ ] Walking, turning, equipment and fighting match the intended reference in
      deterministic captures; overlap follows world depth, not spawn order.
- [ ] Server triggers reveal building interiors in the Rust client without
      hiding unrelated upper-layer art.
- [ ] Long movement streams tiles/tall art without holes and releases old
      entities/textures inside byte budgets.
- [ ] A 30-minute movement/combat capture stays inside frame, draw, entity, heap
      and GPU ceilings.
- [ ] Audio obeys gesture, controls and background/resume behavior without
      overlap; goldens cover indoor/outdoor/crowded/weather/equipment scenes.

## Phase 7 — Versioned assets and persistent cache

This precedes seamless handoff. A transition cannot be hitch-free if it first
downloads or materializes the full 58.8 MB pack.

### Task W-0055 — Indexed or per-map world format

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0020, W-0024

Replace the monolithic sequential pack with per-map resources or a range-indexed
format and small index. Define compressed transfer, decoded map and maximum
hostile-size bounds before implementation.

### Task W-0056 — Content-hashed resource manifest

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0055

Version maps, indices, sprite sheets and audio; validate packet 203 and prevent
mixed world builds through atomic activation/invalidation.

### Task W-0057 — Persistent cache service

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0015, W-0056

Implement Cache Storage/IndexedDB on web and application cache directories on
native. Denial, quota exhaustion, eviction, corruption and partial versions
fall back safely.

### Task W-0058 — Immutable/range resource serving

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0055, W-0056

Serve content-addressed assets with immutable headers and range support where
the format requires it; prove warm visits do not refetch unchanged resources.

### Task W-0059 — Byte-budgeted cache and preloading

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0057

Track compressed, decoded-map, WASM-heap and estimated RGBA/GPU bytes
separately. Evict by bytes, not entry count. Build a map-to-assets dependency
index and give speculative exits a separate allowance below authoritative-world
headroom.

### Task W-0060 — Bounded decode and GPU upload

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0059

Decode off the gameplay loop where possible, spread uploads across frames,
cancel obsolete speculation and cap work/bytes per frame. Fuzz map/index/image
metadata and reject hostile dimensions/counts even when hashes match.

### Task W-0061 — Coherent app-shell updates

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0056, W-0057

Cache the shell/service worker while remaining honest that play needs a server.
Install/activate atomically so no tab combines old WASM with a partially updated
manifest, including rollback.

### Phase 7 exit gate

- [ ] Loading one map neither downloads nor retains the complete 58.8 MB pack;
      a small manifest activates atomically and prevents mixed builds.
- [ ] Warm visits do not refetch unchanged maps, sheets or audio.
- [ ] Storage denial/quota/eviction, corruption, partial downloads and rollback
      recover automatically.
- [ ] CI separates cold/warm transfer, cache hit, compressed/decoded/heap/GPU
      bytes; eviction and speculation are megabyte-bounded.
- [ ] Cached decode/upload stays under per-frame work/byte ceilings.
- [ ] Resource fuzzing enforces size/dimension/count limits and service-worker
      activation/rollback keeps one coherent shell/WASM/manifest set.

## Phase 8 — Seamless authoritative map handoff

Treat this as approximately 40% server/60% client. The server API and ordering
changes are core work, not two free packets.

### Task W-0062 — Handoff parity and compatibility contract

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0021, W-0033, W-0059

Classify `map_handoff_begin/end/failed` as intentional divergences, assign
fixtures and capability negotiation, and state the behavior of retained
VB6/unframed sessions explicitly. Do not build or preserve a TypeScript-specific
handoff path.

### Task W-0063 — Structured MapServer snapshot adapter

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0062

Refactor `MapServer.enter/3` to return a structured snapshot rather than send
NPC bytes out of band. If the governed unframed protocol still requires the
traditional packet sequence, isolate it behind a protocol adapter; exact
TypeScript behavior is not an acceptance criterion.

### Task W-0064 — Epoch, failure and ordered batch

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0063

Own a session `world_epoch`, increment per transfer and key map-local IDs by
epoch. Keep the source world on failure, correct position and resume input.
Guarantee `begin < every snapshot member < end` through one ordered batch or
critical FIFO; normal coalescing may not escape the boundary.

### Task W-0065 — Active/pending Bevy worlds

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0064, W-0060

Maintain `ActiveWorld` and `PendingWorld` under separate `MapSceneRoot`s. Commit
once, only when assets and complete snapshot are ready; reject queued envelopes
from stale map/epoch. Reuse the W-0090 reveal-set/readiness contract so initial
login and later handoff cannot develop different definitions of a complete
first destination frame.

### Task W-0066 — Input and lifecycle handoff behavior

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0018, W-0065

Enter real `Handoff`, pause gameplay, clear held inputs/`WalkGate`, retain the
old rendered world and resume only after atomic commit. Do not infer completion
from packet timing: transfer intentionally suppresses `pos_update` today.

### Task W-0067 — Adversarial transition harness

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0065, W-0066

Add delay injection and forced egress backpressure. Prove a two-second delayed
destination leaves the old world visible and commits atomically; cover failure,
mid-transfer disconnect, stale movement, packet ordering and 1,000-transition
entity/texture cleanup.

### Phase 8 exit gate

- [ ] Handoff packets have parity entries, exact fixtures and explicit
      capability behavior for any retained unframed protocol.
- [ ] `MapServer.enter/3` returns a structured snapshot and no NPC packet
      remains out of band; no TypeScript-specific adapter is required.
- [ ] Backpressure capture proves `begin < every member < end` with no escaped,
      coalesced or dropped member.
- [ ] Epoch filtering prevents stale source entities/input from mutating the
      destination.
- [ ] A two-second delayed destination leaves the source visible, pauses input
      and commits in one frame without black/loading/duplicate artifacts.
- [ ] Failure and mid-transfer disconnect recover explicitly; 1,000 transitions
      leak no scene root, entity, decoded map or texture.

## Phase 9 — Complete localization, accessibility and UI hardening

### Task W-0068 — Authoritative workflow polish

- **State:** planned
- **Phase:** 9
- **Depends on:** W-0048

Polish every Phase 4/5 HUD, service, commerce, social and recovery surface with
the Phase 0 component system. Do not create a late second UI implementation.

### Task W-0069 — Stable-key localization

- **State:** planned
- **Phase:** 9
- **Depends on:** W-0047, W-0068

Ship Spanish, English and Portuguese with fallback/missing-key tests and typed
parameters. Avoid server-authored Spanish when a semantic event suffices.

### Task W-0070 — Persisted settings and migrations

- **State:** planned
- **Phase:** 9
- **Depends on:** W-0015, W-0069

Persist per-device/account key, scale, chat, audio, motion and color settings.
Version schemas; migrate old fixtures and recover safely from corrupt/newer
data without passwords or startup failure.

### Task W-0071 — Keyboard, semantics, gamepad and text correctness

- **State:** planned
- **Phase:** 9
- **Depends on:** W-0011, W-0069

Complete keyboard-only navigation and expose Bevy semantics to supported
platform APIs. Add gamepad only after keyboard parity. Treat text as grapheme
clusters, ship licensed ES/EN/PT fonts, define emoji policy and neutralize
malicious bidi/control characters without corrupting accents or copy/paste.

### Task W-0072 — Truthful boot and recovery progress

- **State:** planned
- **Phase:** 9
- **Depends on:** W-0027, W-0057, W-0090

Expose client, manifest, authentication, map, assets and snapshot progress with
independent recovery actions. Report known bytes/items plus decode/GPU work,
never 100% at request dispatch or Bevy handle creation. Remove host fallback
only after an explicit Rust readiness signal, not module instantiation, and
keep the Bevy loading screen until the atomic first-scene reveal commits.

### Task W-0073 — Complete responsive/fullscreen hardening

- **State:** planned
- **Phase:** 9
- **Depends on:** W-0003, W-0068

Re-run small-window, ultrawide, zoom, DPR, orientation, OS scaling, fullscreen
permission failure, long-session and context-loss matrices against complete UI.
Events still cannot move the player, change visibility or lose composition.

### Phase 9 exit gate

- [ ] Every supported flow works in ES/EN/PT with fallback keys, licensed glyphs
      and no clipped critical text.
- [ ] Authentication, selection and chat work with keyboard/IME and expose Bevy
      semantics without duplicate invisible controls.
- [ ] Grapheme/emoji/bidi rules round-trip valid names/chat without corrupting
      accents.
- [ ] Settings preserve no password, migrate old schemas and recover from
      corrupt/newer data.
- [ ] Complete-UI resize/fullscreen/zoom/DPR/orientation/context-loss matrices
      preserve pixel alignment, gameplay and input.
- [ ] Boot progress distinguishes client, manifest, auth, map, assets and
      snapshot, with an actionable recovery for each failure.

## Phase 10 — Production hardening and release

### Task W-0074 — Browser lifecycle and context recovery

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0033, W-0060

Clear held input on focus loss, suspend expensive hidden-tab work, resnapshot
after long sleeps, ignore stale socket callbacks and recover WebGL resources or
show actionable failure.

### Task W-0075 — Production transport and content security

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0019, W-0027

Require HTTPS/WSS, short-lived launch tokens, CSP/origin and REST CSRF/session
controls, bounded frames/resources and explicit logout. Render player content
as text. Do not promise WASM certificate pinning or treat hashes/encryption as
anti-cheat.

### Task W-0076 — Privacy-conscious observability and support bundles

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0035, W-0075

Report build/world, boot, frame, RTT, reconnect, handoff, cache and memory
metrics without credentials/tokens/chat. Retain private symbols by build ID and
let players export a redacted capability/state/error/version bundle.

### Task W-0077 — Cross-browser and fault-injection release suite

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0067, W-0073, W-0074

Run Chromium, Firefox and WebKit end to end with cold/throttled boot,
fragmentation, disconnect, cache eviction, context loss and delayed handoff.

### Task W-0078 — Native packaging and content-addressed updates

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0017, W-0061

Produce signed/versioned Linux, macOS and Windows builds using the already-real
native services. Implement partial/content-addressed updates without duplicating
platform work from Phase 1.

### Task W-0079 — Reproducible release, rollout and rollback

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0019, W-0076, W-0077, W-0078

Show build identity, reproduce artifacts, stage/canary rollout and test rollback
with one coherent client/manifest pair. Dashboard size, boot, frame, network and
memory regressions before promotion.

### Task W-0080 — Version and duplicate-session compatibility

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0022, W-0079

Negotiate supported protocol/content ranges and test old/new client/server
combinations. Define same-character multi-tab/device handoff or rejection so
there are never two authorities or unexplained disconnects.

### Task W-0081 — Feature flags and operational states

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0079

Version flags with safe cached defaults for protocol v2, handoff, preloading,
FX/audio and optional telemetry. Model restart countdown, draining, maintenance,
server-full/queue and retry eligibility; flags may reduce optional behavior but
never weaken authority/authentication/validation.

### Task W-0082 — Supply-chain and release obligations

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0079

Gate dependencies on vulnerability/license audit, SBOM, reproducible locks,
third-party notices, asset/font/music provenance and AGPL distribution duties.
Unlicensed resources do not ship.

### Task W-0091 — Retire the TypeScript client surface

- **State:** planned
- **Phase:** 10
- **Depends on:** W-0079

After the Rust/Bevy production route and rollback are proven, inventory every
remaining build, deploy, route, CI, documentation, fixture and operational
dependency on `client/`. Extract only historical traces, protocol examples or
behavioral fixtures that still provide unique value into maintained Rust/server
ownership with provenance; old TypeScript tests themselves are not gates.

Remove the TypeScript client from production routing, CI/release matrices,
deployment artifacts and active documentation, then archive or delete its
source and dependencies in one reviewable cleanup. Remove TypeScript-specific
server adapters that have no VB6/unframed or Rust consumer. Do not use this task
to weaken server authority, packet classification, byte fixtures, rollback or
the separately governed legacy protocol.

Close with repository/deployment searches proving no production or CI path
builds or serves the obsolete frontend, a Rust staging/rollback smoke test, and
dependency/license scans proving its package ecosystem no longer ships. Record
which reference artifacts were retained and why.

### Task W-0092 — Render the world and interface at physical device resolution

- **State:** planned
- **Phase:** 11
- **Depends on:** W-0003

Deferred from W-0003 by decision on 2026-08-18, then largely delivered during
W-0085 — because it turned out not to be a quality question.

The interim path pinned the web build's scale factor to 1. That held the layout
steady and gave up the extra resolution, which read as a cosmetic trade. It also
left Bevy's *input* paths in device pixels while the layout was in CSS pixels, and
the two agree only at ratio 1: on a 125% display, an ordinary Windows setting, a
click 400 pixels from the left edge was treated as 800 and landed in the character
rail instead of the world. Correctness, not sharpness, and found by driving real
clicks in a browser at 1.25x rather than by reasoning about it.

`ui::shell::track_host_canvas` now owns the relationship: logical size is the host
element's CSS box, physical size is that times the device pixel ratio, the scale
factor is the ratio, and every consumer — layout, cursor, picking — works in units
that agree. Measured at 1.0, 1.25 and 2.0: the backing store is exactly `css ×
ratio`, the layout is unchanged, and the pointer lands where it was put.

What remains:

- **The world's grid at fractional ratios.** One world pixel now covers 1.25 or 1.5
  physical pixels at those settings, so nearest sampling duplicates some source
  pixels and not others and the pattern shifts as the camera pans.
  `scale::world_render` decides the integer-zoom target that fixes it and is
  tested; the wiring is what is missing, and `examples/render_target_probe.rs`
  records that all four of its stages pass natively so the mechanism is sound.
- **Hardware validation.** Text sharpness and compositor behaviour cannot be judged
  where every ratio is emulated and headless Chromium composites at 1x.

Still to prove, for the parts above:

- Interface text and controls render at physical resolution.
- The world keeps a whole number of physical pixels per world pixel, so a
  fractional ratio cannot make the sampling grid shift while the camera pans.
  `scale::world_render` already decides that target and is tested; the wiring is
  what remains.
- Pointer mapping follows CSS → composite rectangle → world exactly once, with no
  second derivation of the same rectangle.
- Render-target dimensions and memory stay inside `scale::TargetLimits`, which
  reads the device's own maximum.
- A tested fallback for devices that cannot support the above. The pinned
  scale-factor-1 path is *not* it: it breaks pointer accuracy on scaled displays,
  which is why it was replaced rather than kept.

Known before starting, from `examples/render_target_probe.rs`: clearing an image
target, drawing a colour-only quad into it, drawing a textured sprite into it,
and two cameras with two targets in one frame all **pass natively**. The
production attempt failed in the browser after those same mechanisms were ruled
out, so WebGL2 is the remaining suspect and the probe should be run under WASM
first. Do not re-diagnose culling, asset usages or MSAA; those are settled.

Close with the DPR matrix showing a backing store of `css × ratio` at each ratio,
an unchanged logical layout and tile count across ratios, a pointer round-trip
that holds at every ratio, and a measurement of text sharpness on physical
high-DPI hardware — which is the one part that needs a real display.

### Phase 10 exit gate

- [ ] Chromium, Firefox and WebKit pass login/gameplay/reconnect/cache/handoff
      under throttling, fragmentation, disconnect and context loss.
- [ ] HTTPS/WSS, token expiry, CSP/origin, CSRF/session, size limits and logout
      are exercised in staging.
- [ ] Focus/hidden/sleep/stale-callback/context-loss paths are bounded and
      recoverable.
- [ ] Linux, macOS and Windows artifacts are signed/versioned as appropriate,
      reproducible, self-identifying and retain symbols by build ID.
- [ ] Canary promotion/rollback, old/new compatibility and duplicate-character
      ownership are deterministic and corruption-free.
- [ ] Flag outage, maintenance/drain/restart, capacity and packet floods reach
      truthful Bevy recovery states.
- [ ] Dashboards catch size/boot/frame/network/cache/memory regressions; support
      bundles contain no secrets/chat; SBOM, notices, provenance and AGPL gates pass.
- [ ] Rust/Bevy is the only production game frontend; TypeScript build, deploy,
      routing and CI surfaces are removed, with any retained reference artifact
      owned by a maintained Rust/server test or document.

## Phase 11 — Research and experiments

### Task W-0083 — Governed research registry

- **State:** research-gated
- **Phase:** 11
- **Depends on:** production evidence relevant to each proposal

For every proposal, record player value, hypothesis, smallest falsification
probe, kill criteria, protocol/server impact, abuse/privacy, compatibility and
measured memory/network/operating cost. Accepted work graduates into new stable
tasks with budgets and tests; rejected evidence stays in history.

Candidate investigations:

- optional automatic chat translation, consent, moderation, latency, provider
  cost and whether a subscription is ethical/useful;
- agent-rich gameplay when players can run uncontrolled LLMs: server authority,
  bot-resistant social value, rate limits, provenance and player-created goals;
- touch/mobile controls and a genuinely small-screen HUD;
- WebGPU, WASM threads and shaders only where profiling supports them;
- explicit continent travel or multi-region worlds with one character/market
  authority;
- dynamic zone instancing and population-aware placement;
- variable-sized maps, coordinates wider than `u8`, chunks and continuous
  geometry beyond seamless logical-map handoff;
- quests, events, subscriptions and community benefits that avoid pay-to-win;
- positional audio and map-specific music; and
- further ideas from AO/Argentum United research, the wiki, community feedback
  and privacy-conscious live telemetry.

### Phase 11 exit gate

- [ ] The proposal states player value and a falsifiable hypothesis.
- [ ] A cheap spike and kill criteria precede work measured in weeks.
- [ ] Protocol/server, compatibility, authority, abuse, privacy, moderation,
      memory, network and operating cost are measured.
- [ ] Acceptance or rejection evidence remains in the changelog so the decision
      is not reopened without new information.
- [ ] Accepted experiments become estimated stable tasks with dependencies,
      budgets and tests before production implementation.

## Server dependency view

Server-tagged work is filed here because it blocks this client. Reflect it in
the root roadmap when it enters active execution.

| Client task | Server change |
| --- | --- |
| W-0019 | Serve the Rust client/runtime config from the game origin |
| W-0021–W-0023 | Governed protocol-v2 negotiation and schema/fixture source |
| W-0024–W-0029 | Bootstrap packets, failure semantics and bounded transport |
| W-0033 | Fresh reconnect/resynchronization snapshot |
| W-0042–W-0048 | Gameplay workflow fixtures and versioned metadata |
| W-0050 | Emit map triggers consumed by the Rust world renderer |
| W-0055–W-0058 | Indexed assets, hashes, range/immutable serving |
| W-0062–W-0064 | Handoff parity, structured snapshot, epoch and FIFO batch |
| W-0075, W-0080–W-0081 | Security, rollout compatibility, session ownership and operations |

## Global definition of done

- Every task assigned to the phase is closed or explicitly moved with a
  documented dependency; no phase is called complete around an open task.
- The task contract and applicable canonical phase checklist pass.
- Pure logic has native tests; browser behavior has browser tests; flow-critical
  packets have cross-language bytes and governed parity classification.
- Every application screen/control is Bevy-owned; JavaScript/CSS cannot satisfy
  an application-UI acceptance criterion.
- Happy path, rejection, interruption and cleanup are exercised in proportion
  to risk.
- Every supported workflow has Rust-owned tests. Historical
  `client/tests/e2e` cases may inform coverage but never block or define it.
- Compressed transfer, boot, frame, network and memory deltas are recorded where
  affected; unexplained regressions fail their gates.
- TypeScript compatibility is not a gate. Any retained VB6/unframed protocol
  behavior is explicit, fixture-pinned and independently governed.
- `bash client-rs/scripts/check_roadmap.sh` passes, and completed task bodies and
  dated evidence move to `client-rs/CHANGELOG.md`.

## Deliberately out of scope

- Variable or larger-than-100x100 maps during seamless handoff. Server, NIF and
  current wire coordinates use `u8` tiles; that is W-0083 research.
- Preserving or extending the TypeScript client. Incidental deletion during
  unrelated work is also excluded; W-0091 owns its bounded retirement after
  Rust production rollout and reference extraction.
- Client hashes, encrypted assets or WASM checks as an anti-cheat boundary.
- DOM/React implementation of a Bevy application screen.
