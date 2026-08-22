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

Findings are reported in four separated stages, and the separation is the point:

1. **Observation** — what was measured, named for exactly what it counts.
2. **Reproducible evidence** — the command that recomputes it, and a pinned baseline so it
   cannot drift silently.
3. **Inference** — what the observation appears to mean, stated as a claim that could be
   wrong, with the check that would falsify it.
4. **Activation decision** — a person choosing to depend on the inference.

A baseline pins stage 1 and 2. It must never promote stage 3, because a confidently wrong
classifier produces perfectly stable numbers: this corpus had `seam_exits_across_medium`
pinned and gated at 897 while the true count was 4, and had 278 maps classified as ocean
while nine of them were dry rock. Neither ever drifted. Cross-checking a reading against the
code that owns the meaning — `fixtures/tile_semantics.txt` against `Arena.Map.CsmParser` and
`Arena.Map.Movement` — is what catches that class of error; a drift gate cannot.

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

### Canonical world identity, local simulation partitions

The modern domain model uses a canonical
`WorldPosition { space_id, x, y }` with signed 32-bit tile coordinates. Stable
regions partition that space for simulation; one already-running `MapServer`
may continue to own one legacy AO map and use bounded local coordinates for its
collision grid, occupancy, spawns and hot-path indexes. Local position is a
topology-derived cache/adapter, not an independent source of truth for new
client, protocol, persistence, marker, quest, party, logging or support work.

`WorldSpaceId`, stable `RegionId`, content version/hash and runtime owner
PID/node are different identities. Moving or restarting a region cannot move
the world or change its durable identity. Runtime dungeon/event copies receive
distinct world-space identities rather than arbitrary coordinates in the
overworld. The legacy protocol may project a region and global position back to
`map_id + u8 x/y`; that compatibility view does not constrain the size of the
composed global world.

The current AO corpus stores 100x100 maps, but its standard geographic seams
describe a provisional 74x80 simulation core (`x=14..87`, `y=11..90`) with
transition bands at `x=13/88` and `y=10/91`. The topology compiler must prove
that interpretation per region before activation. Transition-band coordinates
may exist transiently inside one movement/handoff operation but are never a
durable player location: before commit the source owns the player in its core;
after commit the destination owns the player in its core.

Maps are composed virtually, never flattened into one giant map file or one
global gameplay process. The client places authorized region roots in one
global render space; MapServers retain local parallel authority behind a single
versioned conversion boundary.

### A map boundary is not a loading screen

The world may continue to use one loaded `MapServer` per logical AO map. That
server topology must not be visible as a pause, reconnect, blank frame,
progressively appearing destination or camera reset in ordinary play. The game
socket and session remain continuous across a transfer; idle-timer policy may
change how an empty map spends CPU but may not unload it or add entry latency.

There are two presentation classes:

- a compatible walkable border preloads authorized destination geometry and
  dependencies, keeps both logical maps resident, renders them in one camera
  space and crosses without a visible wait; and
- a door, portal, teleport or geometrically unrelated exit uses one atomic
  scene replacement while retaining the complete source scene until the
  destination snapshot and reveal set are ready.

The normal path must finish preloading before contact with an exit. A cold,
failed or mispredicted path cannot promise zero network time, but it must never
show a black frame, fallback grid, half-built world or mixed-map entities: keep
the source visible, stop unsafe input, explain a sustained delay and either
commit one complete destination frame or recover the source. Static destination
art may be prefetched only from server-authorized topology/resources; live
entities remain authoritative snapshot data.

### Protocol changes are governed

New server/client packets first receive a parity decision in
`session_route_manifest.ex`, byte-level fixtures and an explicit compatibility
story. WS-only extensions without a VB6 ancestor are
`:intentional_divergence`. TypeScript compatibility is not part of that story.
Any retained VB6/unframed protocol behavior must be named explicitly by the
owning task and remains governed until separately retired; historical frontend
behavior never overrides server authority, bounded parsing or a cleaner
negotiated Rust protocol.

### Simulation ordering is not a global game tick

The modern protocol must not introduce a fixed global simulation tick, a shared
25 Hz world loop, or a barrier among MapServers. The server remains event-driven:
each MapServer serializes commands through its own mailbox and independently
runs only its existing gameplay jobs (for example NPC AI, regen or buff expiry).
A movement command, authoritative combat command or handoff message is processed
when its owner receives it; it does not wait for an arbitrary frame boundary or
for another map to advance.

Five different counters have five different meanings:

- `SessionEpoch: u64` identifies one accepted connection lifetime. Reconnect
  creates a new value and makes every queued message from the old session stale.
- `AuthorityEpoch: u64` identifies one generation of the player's authoritative
  owner. Initial bootstrap and each committed ownership handoff install a new
  value; resnapshot without an ownership change preserves it.
- `AuthorityRevision: u64` orders committed mutations to the owning
  authoritative aggregate within one authority epoch. It advances exactly once
  after an accepted transaction has committed; rejection does not advance it.
- `ReplicationEpoch: u64` identifies one atomic client-view baseline. Bootstrap,
  resnapshot and handoff each install a new value.
- `ReplicationRevision: u64` orders deltas emitted to one session after AOI
  filtering and coalescing within a replication epoch. It advances once per
  emitted atomic delta, not once per hidden server mutation.

None of these values is time, a render frame or a simulation step, and none may
wrap silently. Authority and replication revisions are deliberately separate:
an entity outside the player's AOI may mutate without creating a false gap in
the player's replication stream, while several pending visible changes may be
coalesced before the next replication revision is assigned.

The minimum live-world contract is:

```text
MoveIntent {
  command_id, authority_epoch, input_sequence, direction
}

CommandReceipt {
  command_id, authority_epoch, accepted_or_reason,
  authority_revision, authoritative_position_or_delta
}

WorldDelta {
  replication_epoch, base_replication_revision, replication_revision,
  entities_added, entities_changed, entities_removed
}
```

The client applies a delta only when the replication epoch is current and
`base_replication_revision` equals the last applied replication revision. An
exact duplicate is idempotent, a stale replication epoch is discarded and a
gap requests one bounded full snapshot; the client never guesses missing
authority. On resnapshot, only the replication epoch must change. On handoff,
the complete destination snapshot installs new authority and replication epochs
plus their baselines together. Source authority revisions are not translated
into the destination.

Network batching is a separate optimization. The session egress may hold and
coalesce already-committed position/heading/animation/vital projections for a
configurable maximum of 40 ms initially, and only while such data is pending.
Critical commands, receipts, combat outcomes and snapshot/handoff boundaries
bypass that delay. Changing or disabling this flush deadline must not change the
authoritative command/receipt/authority-revision history, wake an empty map or
coordinate two MapServers. It may change how many replication deltas are emitted
because coalescing is its purpose, but every run must converge to the same
authorized view. WebSocket remains one reliable ordered TCP stream: priority
and coalescing classes do not create real unreliable or unordered channels.

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

Map continuity is not implemented yet. Phase 1 first compiles the existing map
graph into a reviewable global topology and establishes the shared coordinate
contract. Phase 3 then proves both the final structured snapshot/epoch handoff
and a real camera-continuous four-region slice with the current validated pack,
before asset repackaging can become a blocker. Phases 7 and 8 replace that pack
source with bounded predictive resources, curate the production topology and
extend the proven slice across the world and its cross-region systems, before
the HUD vertical slice, gameplay parity tail or world-fidelity breadth.

The server can keep every logical map process and its static state loaded, and
does, but that alone cannot prevent a client hitch. W-0097/W-0098 establish the
topology and identity foundation; W-0062–W-0066 and W-0096 prove ordered atomic
authority transfer; W-0099 immediately proves a small composed world with no
camera seam using the monolithic pack. W-0055–W-0060/W-0094 and
W-0101/W-0095/W-0067 then make that behavior bounded and production-wide.

## Capability unlock map

This is an architecture map, not another work list. It explains why the single
execution sequence is ordered as it is; agents do not select work from this
table.

| Phase | Capability unlocked | Depends on |
| ---: | --- | --- |
| 0 | Responsive, fixture-backed Bevy product shell | Current renderer |
| 1 | Compiled global topology, canonical world identity and WASM platform foundation | Phase 0 contracts |
| 2 | Truthful authentication and governed global bootstrap/handoff protocol | Phase 1 |
| 3 | Authoritative live world and a four-region seamless MVP | Phase 2 |
| 4 | Core combat/HUD vertical slice | Phases 0 and 3 |
| 5 | Remaining AO workflow parity | Phase 4 |
| 6 | World/audio fidelity within budgets | Phases 3–5 |
| 7 | Per-region runtime assets and predictive destination readiness | Phases 1 and 3; enables Phase 8 |
| 8 | Production continuous-world rollout and cross-region systems | Phases 3 and 7 |
| 9 | Complete localization/accessibility/UI hardening | Phases 4–6 |
| 10 | Staged, observable production releases | All production phases |
| 11 | Measured experiments and future product ideas | Explicit research gates |

## Execution sequence

Execute the following task bodies from top to bottom. Phase 0 is intentionally
UI-first and fixture-backed; Phase 1 makes the platform boundary real before
protocol breadth.

Phase 0 keeps only the work the seamless-world MVP needs: finish the active
pointer and Tab-map work, then close `W-0090`'s reusable reveal barrier. Fixture
product/account screens move to Phase 0b before their live adapter; they do not
gate world topology or travel.

The shortest path to testing travel is explicit: close the two active Phase 0
tasks and atomic first-scene reveal; compile and review a global topology; lock
the Elixir/Rust coordinate contract; build the minimum platform/protocol/live
world path; then run Phase 3's atomic handoff and four-region seamless slice.
Both proofs use the already validated monolithic world pack so asset
repackaging cannot delay them. Phase 7 then makes destinations predictively
ready from bounded per-region resources, and Phase 8 curates and expands the
proven model across production geography and cross-region systems.

Hardening, staging, account-flow polish, persistent-cache reuse and developer
diagnostics are deliberately sequenced after the first seamless-travel proof.
They remain release work, but they do not make an atomic transfer more correct.
The Phase 0b checklist retains the prototype evidence; Phase 7b owns persistent
cache and coherent application updates.

`W-0062` through `W-0064` sit in Phase 2 because handoff packets, structured map
entry and ordering are protocol foundations, not late presentation features.
`W-0065`, `W-0066` and `W-0096` produce an early, falsifiable atomic handoff;
`W-0099` then proves camera-continuous play across a compiler-confirmed 2x2
region group in the same phase. Phase 7 makes likely destinations ready before
the boundary; Phase 8 rolls the model out safely. This is a production world
invariant, not optional polish: no release can call map travel complete while a
normal geographic transition exposes a loading screen, camera reset or entity
identity break.

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

### Phase 0 exit gate

Phase 1 unlocks when `W-0085`, `W-0089` and `W-0090` close. These checks gate
the shell geometry, pointer integrity, two map views and the reusable
first-scene reveal barrier. Product screens remain required before release in
Phase 0b, but do not hold the seamless-world MVP behind fixture UI breadth.

The hardening and validation checks are not listed here. They belong to the tasks
that own them and are checked in the Phase 0b hardening checklist — nothing was
dropped, and each item is written out there rather than referred to.

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
- [ ] Focus, modal/chat ownership, drag cancellation, tooltips and IME never
      leak unintended world commands.

## Phase 1 — Compiled world topology and WASM platform foundation

Establish the seamless-world coordinate contract before protocol or gameplay
code can invent incompatible local/global conversions. Then make the prototype
honest while the platform-specific surface is still small. Phase 0 may use
deterministic adapters until this phase.

### Task W-0098 — Canonical world-position and stable-identity contract

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0097

Define shared Elixir/Rust fixtures and checked conversion APIs for
`WorldSpaceId`, stable `RegionId`, `WorldPosition<i32>`, bounded
`LocalPosition`, `RegionPlacement`, `RegionGeometry`, `TopologyVersion`,
`TransitionKind`, stable `EntityId`, `AuthorityEpoch` and `TransferId`.

Global coordinates are per-space and exact, because W-0097 found the world is an atlas
of several geometries rather than one plane: most spaces are planes, the Newbie Dungeon
closes as a 148x160 torus, and 199 spaces are reached only by transition.
`WorldSpaceGeometry` is `Plane | Cylinder { axis, period } | Torus { width, height } |
Discrete`, and position arithmetic goes through it — a step in a toroidal space reduces
modulo the period, a step off the edge of a planar space is a transition, and no caller
may add tiles to a `WorldPosition` without saying which space it is in. Two positions in
different spaces are never comparable and never subtractable.

A wrapping space needs one more thing the server does not: the client keeps a **nearest
unwrapped render position**, so crossing the wrap moves the camera one tile rather than
jumping it a whole period. The canonical position stays reduced; only rendering
unwraps, and the two must never be confused in a fixture. New modern-domain code stores,
compares, logs and transmits global positions; a MapServer derives local
coordinates at its boundary for collision, occupancy and legacy content.

Keep content identity, topology version, runtime process ownership and dynamic
instance identity separate. Region IDs remain stable across process restarts
and topology releases; they are never sequential PIDs or array positions.
Transition-band positions are operation-local and cannot be persisted. A
retained legacy adapter projects an eligible global position to
`map_id + u8 x/y` and rejects an unrepresentable region explicitly.

Specify the extension points now without implementing their breadth: one
authoritative owner per entity; read-only cross-region observations; commands
routed to that owner; instance templates separate from runtime space IDs; and a
versioned topology lookup rather than a central per-movement coordinate
service. Property tests cover local/global round trips, negative/global-large
coordinates, boundaries/corners, disconnected spaces, stale versions and
stable IDs across reshard/restart.

### Task W-0015 — Platform-service traits and capabilities

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0004

Define narrow services for HTTP, WebSocket, persistent cache, auth/token
storage, audio, clipboard, IME/text composition, fullscreen/window, browser
history and external links. Define capability results and failures without
spreading `cfg(wasm32)` into gameplay or UI systems.

Partially delivered, and deliberately not closed. `platform` defines `HostClock`,
`HostWindow` and `HostHttp` behind one `Platform` resource, with `Support` for
capability answers — the top bar uses it to withhold a fullscreen button from a
host that has no fullscreen while keeping it on one that merely needs a gesture —
and `FetchError` for the failures a fetch can produce. Four production callers
moved behind the boundary: the ping schedule, the online poll, the frame-rate
readout and the shell's canvas tracker. `hud.rs` went from six `cfg(target_arch)`
sites to none.

The rest of the list — WebSocket, persistent cache, token storage, audio,
clipboard, IME, history and external links — is unbuilt on purpose: every one of
them was written, reported unused by the compiler, and removed. Their adapters and
their first callers both belong to `W-0016` and to the tasks that introduce the
screens using them, and a service whose only caller is its own test is not a
service. Close this task together with `W-0016`, in dependency order, or move the
unbuilt services explicitly to the tasks that will call them. It does not close on
its own.

### Task W-0016 — Browser adapters and host boundary

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0015

Implement browser services, gesture-gated fullscreen/audio, resize/DPR/IME,
storage denial/quota, history and external-link behavior. Source/browser tests
must prove the host contains only canvas, pre-WASM fallback and thin adapters—no
application forms, panels or duplicate state tree.

### Task W-0018 — Honest lifecycle states

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0015

Extend application/session state only when transitions exist:
`Boot -> Authenticate -> SelectCharacter -> LoadWorld -> Playing`, plus
`Reconnecting` in Phase 2 and `Handoff` in Phase 3. Keep render memos and redraw
triggers as render concerns/change detection, not application states. Reset
session-scoped resources explicitly at every transition.

### Task W-0020 — Budgets and capability profiles

- **State:** planned
- **Phase:** 1
- **Depends on:** W-0016

Remeasure optimized raw/gzip WASM and enforce a documented 5% unexplained-
regression threshold. Establish fixed browser/device/network profiles and
numeric ceilings for first interactive world, p95 frame, draw calls, WASM heap,
estimated GPU memory and reconnect/handoff. Probe WebGL2, texture size, DPR,
audio, persistent storage/quota and memory signals; select a tested low-resource
profile or actionable unsupported-device screen.

### Phase 1 exit gate

- [ ] `./build.sh check` passes for WASM, both Rust crates and the roadmap gate.
- [ ] The topology compiler deterministically reproduces the audited corpus,
      emits a version/hash and review report, and permits no active geographic
      seam with an unresolved placement contradiction.
- [ ] Shared Elixir/Rust fixtures prove canonical position, stable identity,
      topology-version and local/global conversion semantics; transition bands
      cannot become durable locations.
- [ ] Standard cardinal seams advance one global tile, while doors, portals,
      teleports, disconnected components and instances never acquire invented
      spatial adjacency.
- [ ] Browser platform services use narrow contracts and no platform
      conditionals leak into gameplay/UI; the same contracts retain native
      adapter seams for W-0017.
- [ ] No credential/production host is compiled in; the browser host contains
      only canvas, fallback and thin adapters.
- [ ] Lifecycle state is explicit and draw memos/redraw triggers remain render
      concerns.
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

### Task W-0062 — Handoff parity and compatibility contract

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0021, W-0098

Classify `map_handoff_begin/end/failed` as intentional divergences, assign
fixtures and capability negotiation, and state the behavior of retained
VB6/unframed sessions explicitly. Do not build or preserve a TypeScript-specific
handoff path.

Consume W-0097's signed topology rather than carrying an ad-hoc client
transform. Bootstrap/handoff names the topology version/hash, world space,
stable source/destination regions, canonical position, transfer ID and authority
epoch. Define `prepare`, `commit`, `abort` and idempotent retry semantics. Only
a compiler-authorized `geographic_seam` can place both region roots in one
camera space; doors, portals, teleports and instance entrances change spaces or
replace a scene without fabricated adjacency. The server never trusts a
client-supplied placement or destination.

Define an authorized preload hint separately from the authoritative handoff: it
may disclose static region/resource dependencies the player is permitted to
cache, never destination players, NPCs, drops or hidden objectives. Pin
malformed, stale-version, unauthorized and geometrically inconsistent topology
fixtures. Length framing leaves room for future neighbor-subscription fields;
do not reserve a speculative AOI packet before W-0102 proves its contract.

Decided here rather than in Phase 8 because handoff is a constraint on design,
not a feature bolted on at the end. It dictates world and entity lifecycle: two
live worlds, epochs, ordered batches, identity across a boundary and a cache that
spans two maps. Settled after the protocol decision and before the tasks it
constrains so those are built to it rather than rebuilt for it. The structured
server path and ordering land in this phase; the first atomic client proof lands
in Phase 3; predictive asset readiness and continuous border composition follow
in Phases 7 and 8.

### Task W-0022 — Negotiated length-framed WebSocket transport

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0021

Negotiate a versioned WS subprotocol/capability before authentication; never
guess the format from the first payload. The initial modern subprotocol is
`argentum.v2`. Carry existing AO packet bodies at first inside this
little-endian bounded envelope: `message_type: u16`, `flags: u16`,
`payload_length: u32`, then exactly that many payload bytes. In the initial
version, flag bit 0 means `required` and every other bit must be zero. A modern
client skips an unknown optional type, closes with a stable
`unsupported_required_message` reason for an unknown required type, and rejects
unknown flag bits. Legacy TCP/WS remains unframed behind its adapter.

`message_type` is the packet ID in modern framing; its payload omits the legacy
signed-i16 packet-ID prefix. The legacy adapter alone translates between
`legacy_id + body` and the schema's `message_type + body`. A modern envelope
must not carry the ID twice.

WebSocket is one reliable ordered TCP byte stream. Atomic/critical,
transactional, latest-state/coalescible, ephemeral or static delivery class is
trusted schema metadata selected by `message_type`, never a client-controlled
flag, and cannot promise unreliable or unordered transport. Parsing must not
depend on one AO envelope equalling one WebSocket callback. Test split headers/
payloads, several envelopes in one callback, empty payloads, every flag case,
unknown IDs, hostile/truncated lengths, downgrade refusal and a valid message
following a skipped optional message.

### Task W-0023 — Canonical protocol schema decision

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0021

Choose and prove one source: machine-readable schema checked against Elixir
goldens, an Elixir-source extractor with verification, or manual Rust codecs
with paired fixtures. For every message, record direction, numeric ID, required
capability/version, delivery class, binary layout, endianness, signedness,
coordinate space/unit, maximum encoded length and stable error semantics. Hot
movement/projection messages may use compact fixed layouts; control/bootstrap/
handoff evolution must have an explicit message version or tagged optional
fields. Code generation begins only after its source is trusted.

Define `SessionEpoch`, `AuthorityEpoch`, `AuthorityRevision`,
`ReplicationEpoch`, `ReplicationRevision`, `CommandId` and `InputSequence` as
distinct non-wrapping `u64` types in Rust and Elixir; paired fixtures must fail
if fields are swapped despite having the same wire width.

### Task W-0029 — Bounded network queues

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0022

Bound incoming frames/decoded packets and pending commands by bytes/count;
budget processing per frame and observe WebSocket buffered amount. Overflow
must disconnect/resnapshot explicitly, never grow forever, silently drop
authoritative state or freeze one render frame.

Give outbound schema classes concrete queue policy. Atomic/critical and
transactional messages are ordered, non-sheddable and bounded; reaching their
limit closes/resnapshots explicitly. Latest-state projections may replace only
an older **unsent** projection for the same stable entity and field group.
Ephemeral presentation may be shed with a counter. No policy may drop a command
receipt, combat outcome, inventory/trade mutation or snapshot/handoff member.

If live measurement warrants batching, add one session-egress flush deadline:
at most 40 ms initially, armed only while a connected session has pending
coalescible projections. Critical traffic flushes immediately. Tests run the
same command script with batching disabled and at the maximum delay and require
an identical authoritative receipt/authority-revision history and equivalent
final replicated state. Replication-delta count may differ. No MapServer waits
on the flush and no empty map wakes because of it.

### Task W-0063 — Structured MapServer snapshot adapter

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0062

Refactor `MapServer.enter/3` to return a structured snapshot rather than send
NPC bytes out of band. The snapshot carries canonical position, stable entity
identity, owning region, topology version and authority epoch in addition to
the local simulation view. Make login, reconnect and map entry consume the same
internal snapshot shape. If a retained unframed protocol still requires the
traditional packet sequence, isolate that encoding and global-to-local
projection behind a protocol adapter; exact TypeScript behavior is not an
acceptance criterion.

Close with server tests proving no map producer calls a client/session process
to emit a snapshot member and no NPC or object packet can arrive after an end
marker through an out-of-band path.

### Task W-0064 — Epoch, failure and ordered batch

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0022, W-0023, W-0029, W-0063

Own a connection `SessionEpoch`; an `AuthorityEpoch` plus
`AuthorityRevision` for the installed region authority; and a
`ReplicationEpoch` plus `ReplicationRevision` for the session's atomic client
view. Reconnect replaces the session epoch. Bootstrap and each successful
transfer install new authority and replication epochs with complete baselines.
A same-owner resnapshot replaces only the replication epoch/baseline. Key any
remaining map-local IDs by authority epoch while preserving stable entity
identity. A source authority revision never continues into or gets translated
to a destination epoch. The source owns
the player through prepare; the destination validates capacity, topology
version, entry collision and snapshot readiness without publishing authority.
Commit once, or abort idempotently and retain/correct the complete source world.
A timeout, destination crash/overload, source crash, duplicated message or
topology release race may never create zero or two owners.

Guarantee `begin < every snapshot member < end` through one ordered,
non-sheddable batch or critical FIFO; normal coalescing may not reorder, merge
across or escape the boundary.

Pin the sequence byte-for-byte in Elixir and Rust and force egress pressure in
the test. Prove login, reconnect and handoff all use the same writer and that a
late source-epoch envelope is rejected rather than applied to the destination.
Duplicate prepare/commit/abort is idempotent; revision exhaustion fails closed
in a deterministic test rather than wrapping.

### Task W-0024 — Login bootstrap decoding

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0022, W-0023, W-0064

Decode session token 200, world-pack signature 203, explicit login success and
all bootstrap/error responses. Validate content and topology version/hash, then
accept the snapshot's world space, stable region and canonical position before
entering the world. Prove a real existing character reaches the authoritative
bootstrap with packet 73. This first vertical slice may use explicitly supplied
development credentials from runtime configuration; polished account and
character navigation is W-0025 and does not block handoff testing.

### Task W-0026 — Authoritative live-world packet coverage

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0023, W-0024

Add paired fixtures and Rust handlers for the minimum authoritative world
surface needed by W-0030, W-0096 and W-0099: snapshot begin/end, entity
create/move/change/remove, region/global-position/heading change, character
composition, visible objects, build/content/topology version and transition
errors. Local map position exists only inside the legacy adapter and MapServer
boundary. Unknown framed packets are counted and skipped; unknown legacy
packets fail without desync.

Implement movement as an intent, not a client position:
`MoveIntent {command_id, authority_epoch, input_sequence, direction}`. An
accepted or rejected `CommandReceipt` echoes both identifiers and carries the
current authority epoch, resulting authority revision, stable reason when
rejected, and authoritative canonical position/delta. Duplicate command IDs are
idempotent; stale authority epochs reject; prediction is presentation only.

Apply replication as
`WorldDelta {replication_epoch, base_replication_revision,
replication_revision, added, changed, removed}` built per authorized session/AOI
from committed changes. Assign the next replication revision only after
filtering/coalescing the next atomic delta. Accept only the current replication
epoch with `base_replication_revision == applied_replication_revision`; ignore
an exact duplicate, discard a stale epoch and request one bounded resnapshot on
a gap. Applying a delta is atomic from the typed model's point of view. The
server may coalesce unsent latest-state fields, but it may not create a global
tick, synchronize MapServers or mix transactional outcomes into a lossy/
coalescible delta.

Incremental chat, detailed inventory/spell/stat updates, weather and other
gameplay breadth belong to their Phase 4–6 owning tasks and do not gate the
first real map transition. The bootstrap may still carry their typed initial
state without requiring every later mutation packet here.

### Task W-0028 — Redacted trace and deterministic replay

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0022, W-0026

Record bounded inbound/outbound frames, timestamps, state transitions and
build/world versions without passwords, tokens, cookies or private account
data. Replay without a socket and inject fragmentation, latency, reordering
where legal and disconnect boundaries.

Record session/authority/replication epochs, authority revision, base/current
replication revision, command/input IDs, schema delivery class, encoded length,
coalesced/shed reason and resnapshot trigger.
Timestamps are diagnostic only: replay ordering and acceptance come from the
protocol identifiers, never from wall-clock arrival time.

### Task W-0027 — Connection lifecycle and recovery

- **State:** planned
- **Phase:** 2
- **Depends on:** W-0018, W-0024

Implement meaningful close reasons, bounded heartbeat/RTT, exponential backoff,
token expiry and explicit `Playing` only after bootstrap. Classify credentials,
ban/mute, full, maintenance, stale world/assets and preload failures into Bevy
states with independent retry/reconnect/forget-session actions.

Reconnect discards the old session epoch and accepts new authority/replication
epochs only through bootstrap. A same-connection, same-owner resnapshot keeps
the authority epoch/revision, atomically replaces only the replication epoch/
baseline and suppresses duplicate resnapshot requests until that attempt ends.

### Phase 2 exit gate

- [ ] Protocol v2/new packets are classified and byte-pinned before use; legacy
      streams remain compatible and framed streams skip unknown IDs safely.
- [ ] Handoff topology classifies geographic seams separately from
      doors/portals/teleports/instances, pins valid and malformed compiler
      placements and exposes only authorized static preload dependencies.
- [ ] Bootstrap and handoff agree on topology signature, world space, stable
      region/entity identity, canonical position, epoch and transfer ID; a
      client-provided transform or destination is never authoritative.
- [ ] Framing/codec fuzz tests survive truncation, concatenation, fragmentation,
      hostile lengths and arbitrary unknown IDs without panic or desync.
- [ ] A real existing character uses packet 73, validates packet 203, accepts
      token 200 and completes authoritative bootstrap; packet 74 is creation-only.
- [ ] `MapServer.enter/3` returns structured data; login, reconnect and handoff
      share one ordered writer and no snapshot member is emitted out of band.
- [ ] Forced backpressure proves `begin < every member < end`, and a stale world
      authority epoch cannot mutate the current world; prepare/commit/abort remains
      single-owner under timeout, duplicate, crash, overload and topology race.
- [ ] No global/protocol tick or cross-MapServer barrier exists. Session epoch,
      authority epoch/revision and replication epoch/revision have distinct
      paired fixtures; accepted transactions advance authority once, rejections
      do not, duplicates are idempotent and a replication gap requests exactly
      one bounded resnapshot.
- [ ] Running the same authoritative script with projection batching disabled
      and at its 40 ms maximum produces identical receipts/authority revisions
      and equivalent final replicated state; critical traffic bypasses batching
      and empty maps receive no flush wakeup.
- [ ] Redacted traces replay deterministically and contain no password, token,
      cookie or account secret.
- [ ] Network bursts stay bounded and every auth/bootstrap failure offers the
      correct recovery without an invisible live session.

## Phase 3 — Authoritative live world and seamless-world MVP

This phase is the first playable travel milestone. It proves the final authority,
epoch, canonical-position, scene-root and input contracts with the current
validated world pack, before per-region packaging or broad production topology
exists. First prove atomic replacement on one transition; then prove a
compiler-confirmed 2x2 geographic slice in which the player and camera cross all
four borders without noticing the internal MapServer handoff.

### Task W-0030 — Bootstrap-owned world

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0024, W-0026, W-0090

Take world space, stable region, canonical position and identity from the login
snapshot; remove demo coordinates and `INITIAL_MAP`. Derive the local MapServer
view only through W-0098. Feed the authoritative snapshot and region dependency
set into the W-0090 reveal barrier; a pack record may preload art but never prove
that an entity currently exists or that the first scene is ready.

### Task W-0031 — Authoritative ECS identity

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0030, W-0062

Represent players, NPCs and objects as live ECS entities keyed by stable
authoritative identity and positioned canonically in their world space. Region
owner and epoch are routing/lifetime data, not identity. Apply
create/move/change/remove idempotently and test duplicates, unknown removes,
late packets, owner changes and churn without leaks.

Identity has to satisfy `W-0062`: an entity that crosses a map boundary is the same entity, and a scheme that cannot say so is a scheme handoff has to replace.

### Task W-0032 — Prediction, interpolation and reconciliation

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0031

Separate fixed-step intent, global-space prediction, authoritative correction
and remote interpolation. Derive a local collision command at the MapServer
boundary; do not reset camera space at a region seam. Reset `WalkGate` on
login/reconnect/handoff. Measure step interval distribution so camera or cadence
pauses are diagnosed from data.

### Task W-0033 — Reconnect/resnapshot contract

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0027, W-0031, W-0062

Define server/client resynchronization: a fresh epoch/snapshot replaces stale
entities and inputs, and movement accumulated while disconnected or asleep is
not blindly replayed. A reconnect pins a supported topology version or performs
the explicit W-0100 migration; it never guesses a placement for obsolete saved
state.

Resnapshot and handoff are the same operation seen from two sides, so this has to satisfy `W-0062` rather than be widened for it later.

### Task W-0034 — Client architecture split

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0030

Separate transport/session, authoritative model, presentation and Bevy UI before
packet breadth causes another monolith. Raw packet structures never become
widget resources.

### Task W-0065 — Active/pending Bevy worlds

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0034, W-0064, W-0090

Maintain a keyed `ResidentRegions` collection with one `ActiveAuthority`, at
most one `PreparedTransfer`, and explicit visible-neighbor/rollback pins. Every
`RegionSceneRoot` sits at its compiler-authorized global origin. Keep the source
and all visible static roots fully rendered while destination region data,
assets and the complete snapshot become ready. Commit authority once on a frame
boundary; reject queued envelopes from a stale region or epoch and destroy a
cancelled prepared root without touching active or still-visible roots.

Reuse W-0090's reveal-set/readiness contract so initial login and later handoff
cannot develop different definitions of a complete first destination frame.
For this early slice, the validated monolithic world pack is an allowed asset
source: the scene/authority API must already accept a region-scoped dependency set
so Phase 7 can replace the source without rewriting handoff.

### Task W-0066 — Input and lifecycle handoff behavior

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0018, W-0032, W-0033, W-0065

Enter real `Handoff`, pause unsafe gameplay intents and reset `WalkGate` without
replaying source-epoch steps. Keep the network/session processing. Commit only
the matching ordered snapshot when the destination scene is complete, then
resume input against the new epoch. Door, portal and teleport clear held
movement; geographic-seam held-input and camera continuity are proved by W-0099.

On timeout, rejection, disconnect, corrupt/missing assets or memory-budget
failure, retain or restore the complete source scene with an actionable reason.
Do not infer completion from packet timing: transfer intentionally suppresses
`pos_update` today.

### Task W-0096 — Atomic handoff vertical slice

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0028, W-0066

Wire one real server map exit through the governed begin/snapshot/end path into
`PendingWorld`, using the existing world pack, same WebSocket, session process
and character authority. Add an explicit delay-injection hook and make this the
first handoff acceptance test:

1. start fully playable on the source map;
2. delay destination readiness by two seconds;
3. cross the exit and verify the source world remains completely rendered while
   unsafe input is paused and the socket/session stay unchanged; record the
   already-running destination `MapServer` identity and prove no process startup
   or map parsing occurs on this path;
4. deliver the matching end boundary and verify the very next committed world
   frame is a complete destination—never a loading screen, blank, generated
   fallback, partial layer, duplicate character or mixed epoch;
5. repeat with rejection, missing/corrupt pack data, stale snapshot members,
   mid-transfer disconnect and source recovery.

Capture the frames and network/session identity as test artifacts. Run 1,000
back-and-forth transitions while asserting one active authority, at most one
prepared transfer, one authoritative local character, bounded resident roots/
entities/textures/listeners and no monotonic WASM-heap growth. This closes
atomic no-blank replacement before W-0099 proves camera-continuous geography.

### Task W-0099 — Four-region seamless-world MVP

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0096, W-0098

Select one compiler-confirmed 2x2 geographic group with clean cardinal seams;
maps 1/2/11/14 are candidates only if W-0097's generated evidence confirms
them. Use the current monolithic pack so packaging work cannot delay the proof.
Load four `RegionSceneRoot`s at their canonical origins and compose their static
ground, decoration and roof layers in one Bevy world camera. The server keeps
one already-running local-coordinate MapServer per region.

Start from a real login and walk north, south, east and west through every seam
under held input. Player, camera, visible static world, minimap/world-map marker,
debug/support coordinates and stable character identity remain in one global
space. Crossing advances one tile, changes internal region owner and epoch
atomically on the same socket/session, and never exposes a map number, loading
screen, fade, blank/partial frame, camera recenter, duplicated character or
transition-band location. Local `u8` coordinates are observable only in
server/adapter diagnostics.

On the normal path, prepare the destination snapshot before contact and prove
the crossing has zero paused movement frames. Separately delay preparation by
two seconds after static art is ready: hold the character at the last
source-owned tile while the composed world remains fully rendered, then cross
when ready without a loading/fade/camera reset. Do not predict confirmed
gameplay into authority the destination has not accepted. Rejection, overload,
destination crash, stale topology, stale epoch, disconnect and corrupt resource
data retain the last source-owned global position or terminate
explicitly—never limbo or double ownership. Repeat all four directions,
corners, rapid backtracking and 1,000 crossings while checking continuous
camera displacement on successful crossings, one character, one owner, bounded
roots/entities/textures/listeners/queues and flat memory.

The crossing is command/event-driven: neither source nor destination waits for
a global tick, a shared MapServer barrier or the optional projection flush.
Acceptance records intent receipt time, prepare-ready time and commit time
separately and proves changing the projection coalescing deadline does not move
the authoritative crossing tile, alter the accepted command sequence or add a
prepared-path movement frame.

This MVP intentionally does not claim live cross-border NPC/player visibility,
targeting, combat or long-range AI; W-0102/W-0103 own those features. Static
neighbor visibility and invisible player authority handoff are required now.
Keep a deterministic replay plus frame-by-frame capture as the release artifact.

### Task W-0100 — Versioned global-position persistence migration

- **State:** planned
- **Phase:** 3
- **Depends on:** W-0099

Add authoritative `world_space_id`, signed global x/y and `topology_version` to
character position persistence, with stable region only as a lookup hint. On
first login from a legacy record, derive global state from the versioned legacy
map/local position, record an auditable migration and dual-write the old
compatibility view during a controlled release.

During movement, advance the canonical position first and compare the
topology-derived local result with the actual owning MapServer/local position;
do not "verify" canonical state by merely deriving it again from local. Expose
mismatch counters and sampled redacted diagnostics. Backfill/offline migration,
rollback and login against an unsupported/ambiguous topology version have
explicit operator outcomes. Flip authoritative reads only after the four-region
slice and a representative soak report zero unexplained mismatches; every
rewrite remains versioned and auditable.

### Phase 3 exit gate

- [ ] Bootstrap is the only source of initial map, position and identity.
- [ ] Bootstrap's durable position is canonical world space; local map
      coordinates are topology-derived simulation/legacy views.
- [ ] Entity create/change/move/remove is idempotent; duplicate, unknown, stale
      and churn cases leak nothing.
- [ ] Prediction stays responsive under injected latency and converges without
      oscillation; interpolation never rewrites authority.
- [ ] Login/reconnect/handoff reset `WalkGate`, held input and stale epoch state.
- [ ] Reconnect obtains a fresh snapshot and never replays asleep/offline input.
- [ ] Fixture, replay and live adapters produce equivalent typed snapshots and
      no widget reads packets.
- [ ] A real exit uses one socket/session and one ordered snapshot boundary;
      while destination work is delayed two seconds the complete source remains
      visible, then one frame atomically commits the complete destination.
- [ ] Failure, stale epoch, missing/corrupt resources and disconnect recover to
      one explicit authoritative state; 1,000 transitions leak no world root,
      entity, texture, listener or memory.
- [ ] A compiler-confirmed 2x2 slice crosses all four cardinal seams under held
      input with continuous player/camera/global coordinates, one socket,
      stable identity, zero prepared-path movement stalls and no player-visible
      map transition.
- [ ] The four-region crossing remains event-driven and produces the same
      authoritative command/receipt/authority-revision history and final view
      with projection batching disabled and at its maximum; no global tick, map
      barrier or egress deadline gates authority transfer.
- [ ] Delayed/rejected/crashed handoffs preserve exactly one authority owner and
      either roll back to the source-owned global position or terminate
      explicitly; no transition-band coordinate is persisted.
- [ ] Versioned persistence migration and dual-write shadow checks report zero
      unexplained canonical/local mismatches before global position becomes the
      authoritative read path.

## Phase 7 — Per-region runtime assets and destination readiness

The Phase 3 atomic transition is already correct with the current world pack.
This phase makes the normal path ready before contact: a transition cannot be
hitch-free if it first downloads or materializes the full 58.8 MB pack. Browser
persistence is useful but does not gate this in-session readiness proof.

### Task W-0055 — Indexed or per-region world format

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0020, W-0024, W-0062, W-0098

Replace the monolithic sequential pack with per-region resources or a
range-indexed format and small index keyed by W-0097's stable topology IDs.
Legacy map records remain valid content units; they are not durable world
identity. Define compressed transfer, decoded region and maximum hostile-size
bounds before implementation.

The format has to satisfy `W-0062`, which is what makes a region request cheap
enough to prefetch the world a player is walking towards.

### Task W-0056 — Content-hashed resource manifest

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0055

Version topology, regions, indices, sprite sheets and audio; validate packet
203 and prevent mixed topology/content builds through atomic
activation/invalidation.

### Task W-0058 — Immutable/range resource serving

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0055, W-0056

Serve content-addressed assets with immutable headers and range support where
the format requires it. Prove one region request cannot force transfer of
unrelated regions and a cancelled range/request cannot activate a partial
resource.

### Task W-0059 — Byte-budgeted residency and preloading

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0056, W-0062

Track compressed, decoded-region, WASM-heap and estimated RGBA/GPU bytes
separately. Evict by bytes, not entry count. Build a region-to-assets dependency
index and give speculative exits a separate allowance below authoritative-world
headroom.

The budget has to satisfy `W-0062` and W-0099's composition model: residency
pins the active region, every visible adjacent static region, the prepared
destination and any source needed for rollback. Eviction that assumes exactly
two maps can drop visible geography or the only safe recovery world. Persistent
reuse across browser sessions is a separate Phase 7b concern.

### Task W-0060 — Bounded decode and GPU upload

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0059

Decode off the gameplay loop where possible, spread uploads across frames,
cancel obsolete speculation and cap work/bytes per frame. Fuzz map/index/image
metadata and reject hostile dimensions/counts even when hashes match.

### Task W-0094 — Predictive destination readiness

- **State:** planned
- **Phase:** 7
- **Depends on:** W-0058, W-0060, W-0062

Turn the current region's compiler-generated, server-authorized topology into a bounded preload
plan before the player reaches a transition. Rank candidates from position,
heading, movement history and explicit portal/door interaction without treating
prediction as authority. Fetch and validate the destination region record and
content version, decode its visible dependency set, upload required sheets and
publish a typed `DestinationReadiness` only when the destination can produce a
complete first frame under the same reveal contract as W-0090.

Keep the current region pinned and give candidate destinations a separate
compressed/decoded/GPU byte allowance. Bound simultaneous candidates, request
concurrency, decode/upload work per frame and distance/time lookahead; cancel
obsolete speculation without evicting the active world or a handoff already in
progress. A malicious region cannot make exits recursively preload the world, and
preloading static art cannot create destination entities or reveal
server-withheld markers.

Record prediction hit/miss/cancel, bytes fetched, cache reuse, time from hint to
ready and whether contact beat readiness. Close with deterministic route walks,
rapid direction changes, two competing exits, slow and failed requests, stale
content versions, quota pressure and warm-cache replay. For the supported
movement-speed/network profile, a normal traversable exit must be ready before
contact; a miss enters the explicit retained-source fallback owned by W-0066,
never progressive destination rendering.

### Phase 7 exit gate

- [ ] Loading one region neither downloads nor retains the complete 58.8 MB pack;
      a small manifest activates atomically and prevents mixed builds.
- [ ] A region/range request transfers only its bounded resource set; cancellation,
      corruption or partial data never activates an incomplete destination.
- [ ] CI reports compressed transfer, decoded region, WASM heap and GPU bytes;
      residency, eviction and speculation are megabyte-bounded.
- [ ] Decode/upload stays under per-frame work/byte ceilings.
- [ ] Authorized exits produce a bounded destination-readiness plan; normal
      traversable-route tests reach the boundary with the complete destination
      resident, decoded and GPU-ready, while misses retain the source scene.
- [ ] Prediction cannot recursively fetch the world, disclose live destination
      state, evict the active map or exceed its compressed/decoded/GPU allowance.
- [ ] Resource fuzzing enforces size, dimension and count limits.

## Phase 8 — Production continuous-world rollout and cross-region systems

Phase 3 already proves the experience and authority model on a four-region
slice; Phase 7 makes likely regions ready within byte/time budgets. This phase
curates the full production topology, expands the proven composition path and
adds gameplay that genuinely spans invisible simulation partitions. It does not
replace one loaded MapServer per legacy map with a global bottleneck.

### Task W-0105 — Validated exit destinations

- **State:** planned
- **Phase:** 3
- **Depends on:** none

`Arena.Map.Movement.check_tile_exit/5` transfers a character to whatever tile an exit
names, without consulting the arrival tile, the character's locomotion or whether the
destination is part of the map at all. `W-0097` measured what that admits, and the count
depends on which question is asked — both are recorded because both matter:

- **classified by destination**, every exit in the corpus: **2,877 point at solid ground,
  48 at a tile the destination does not draw, 4 put a walker on water**;
- **reachable today**, the subset a character can actually get to because the way out is
  open: **168 solid, 24 void, 4 water**. The 169th reachable solid arrival is also undrawn,
  so it is counted once, as void.

The rule refuses all of them: an arrival is not valid for being unreachable, and a rule
scoped to the reachable ones would pass its gate and admit the rest the moment a wall
moved. 2,444 void tiles across 47 maps read as walkable floor, because the blocked layer
says nothing about whether a tile exists.

Boat beaching has two units and they are not the same number: **865 boundary *pairs* where
a sailor's path arrives on dry land, of which 856 carry an exit**. The first counts
opportunities in the tile geometry, the second counts exits that actually do it, and both
are pinned so a change to either is visible.

This is a defect, not a decision. Nobody has to judge whether a player should end up
inside rock, so it is engineering work: validate the destination on the server, decide
explicitly what happens when it fails — refuse the transfer, or relocate to the nearest
valid tile, with the choice tested either way — and cover every one of the four classes
with a test that names a real map and tile from the measured list.

The client must not anticipate the fix. `mappack::Tile::enterable` and
`ao_core::mask` deliberately reproduce today's server behaviour, including its
asymmetry (water needs a boat; nothing stops a boat on dry land), because a client that
predicts a refusal the server does not make desynchronises exactly where a player is
most likely to be lost. When the server changes, `Arena.Map.TileSemantics`,
`fixtures/tile_semantics.txt` and the client's reading move in the same commit.

Re-run `ao-topology --check` afterwards: the four counts are pinned in `BASELINE`, so
the fix shows up as drift with the numbers that moved.

### Task W-0101 — Production topology classification and activation

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0097, W-0099

Classify every non-standard exit and low-quality seam as corrected geographic data,
a door/portal/teleport/instance transition, or unsupported geography. An active
region may contain no unresolved contradiction. Not all 842 maps must become one
continent: disconnected regions and explicit portals are valid, but approximate
transforms and silent compiler winners are not.

**Reframed 2026-08-21, and it is still required.** The old opening line — "resolve
every one of W-0097's baseline placement conflicts" — read as repairing broken data.
The corpus is not broken: the legacy world deliberately contains several spatial
geometries, and the work is to classify and activate them. An earlier draft of this
note claimed no curation was needed at all, which was wrong twice over — it rested on
a water classifier that counted solid rock as ocean, and it ignored that the ocean
itself still holds 34 unresolved sea-to-sea claims.

So this task owns, concretely:

- The **ocean's geometry** — plane, cylinder, torus or a reused transition network —
  and the 34 sea-to-sea contradictions, which are the only remaining contradictions in
  the corpus. Sailing must not lose seamless continuity because the sea was easier to
  treat as scenery.
- Confirming the Newbie Dungeon torus against seam and collision evidence before it is
  activated as a wrapping space.
- The **199 Discrete spaces**, each reached only by door, portal or teleport, and the
  one shore claim that does not close.
- Every non-standard exit and low-quality seam classified: corrected geographic data,
  a door/portal/teleport/instance transition, or unsupported geography.

The land-based four-map MVP is not blocked by any of it — 931 land-land claims are
consistent today — but W-0095 and the full world are.

**Review must be grouped, not per-seam or per-tile.** The manifest's review file takes
one line per directed seam, which would mean approving roughly 1,630 clean seams by
hand. That is a conservative default, not a requirement, and it must be replaced before
production rollout by a policy applied to a whole space:

```
activate-space 199 using safe-geography-v1
```

The compiler expands such a decision only for seams that satisfy every mandatory check —
consistent placement, unique destination, one-tile movement, valid arrival collision,
compatible locomotion, reciprocity where required, no ambiguous overlapping map,
deterministic layer policy, and a passing visual capture — and it still records
per-seam evidence for all of them. The approval is of the rule, once.

**A human-workload report is a prerequisite for full-world curation**, and it must first
group three things the compiler currently reports as raw counts:

1. the 1,220 non-standard exit records into distinct transitions, by source interaction
   and destination, because those records are very likely far fewer actual doors,
   portals and teleports;
2. contested layer tiles into seam-level and root-cause clusters — never reviewed tile
   by tile;
3. the 26 multi-map cells into intentional aliases versus incorrect placements.

The target the report has to hit: **no per-map or per-tile manual review, fewer than 100
grouped review units, and fewer than 20 questions needing a product decision.** The
expected product questions are the ocean's geometry, whether the Newbie Dungeon wraps, a
handful of genuinely ambiguous overlap groups, how unusual portal and instance
relationships should feel, visual exceptions where two valid layer choices differ, and
approval of the activation policy itself. Everything else is evidence-backed curation
that can be proposed, tested and committed without asking.

Decide per-layer seam ownership from the records `W-0097` emits, which arrive
marked `unreviewed` and are never resolved by the compiler. Ground and collision
come from the region that owns a global tile; gutter decorations and roofs may
cross a core boundary only by an explicit priority/artist rule that cannot
duplicate or erase interactive collision. `W-0097` measures and reports; this
task chooses and activates. Review corner junctions, occlusion/depth ordering, weather/audio
zones and world-map alignment. Activate topology/content versions atomically;
existing sessions pin a compatible version or receive an explicit resnapshot,
never a half-updated geography.

### Task W-0095 — Production geographic composition

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0065, W-0066, W-0094, W-0099, W-0101

Expand W-0099's four-region implementation to every topology-authorized
geographic component. Place active and ready region roots at their canonical
origins, draw required static neighbors through one world camera, and retain
roots by the W-0059 visibility/rollback budget. Camera, player, markers and
coordinates remain global; owner-region/epoch changes stay invisible.

Commit destination authority at the ordered handoff boundary and release a
source root only after it leaves the retention margin and no rollback or visible
gutter can reference it. Do not show destination players, NPCs, drops,
resources or objectives until authoritative interest data discloses them. A
seam that fails compiler geometry, collision, layer or depth rules is downgraded
to atomic non-geographic presentation rather than approximately stitched.

Cover every cardinal edge, corners, repeated backtracking, held movement,
server correction/rejection, competing exits and topology-version activation.
Doors, portals, teleports and instance entrances commit one complete scene
without pretending unrelated spaces are adjacent.

### Task W-0067 — Adversarial transition harness

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0095, W-0096

Extend W-0096's delay/backpressure harness with preloaded geographic-seam
captures. Fail frame by frame on a loading overlay, camera jump, incomplete
destination layer, mixed epoch or second socket/session. Cover every edge,
backtracking, rejection and two nearby exits; record preload hit rate,
boundary-to-commit latency and cold-fallback duration separately so a correct
fallback cannot hide a consistently late preload path.

### Task W-0102 — Cross-region interest and authoritative command routing

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0031, W-0095

Give every entity exactly one authoritative MapServer owner and publish bounded,
read-only observations into neighboring region interest sets keyed by stable
entity ID, owner region and epoch. Subscription changes are derived from global
AOI and topology; stale projections disappear idempotently and can never mutate
gameplay state.

Publish only committed projection deltas. A border subscription may coalesce
pending position/heading/animation/vital changes at a measured configurable
ceiling between 10 and 25 Hz while it has observers. This is a maximum network
publication cadence, not a simulation tick: no observers means no AOI timer or
publication work; local commands never wait for a publication window; and a
slow/missing neighbor never blocks its owner. A projection older than the
explicit stale-age budget is removed and resnapshotted rather than extrapolated
as authority.

Route a command aimed across a seam to the current owner, then perform range,
line-of-sight, safe-zone, cooldown and resource checks in canonical global
coordinates at authority. Handle migration races with epoch/version rejection
and bounded retry rather than double execution. Test players, NPCs,
projectiles/spells, drops and chat visibility at borders, including an entity
moving owners during a command. Use direct region routing/distributed lookup
and spatial subscriptions; no central process receives every position update.
Critical cross-region commands bypass AOI batching and must not use a
synchronous call that can stall the source MapServer. Bound projection bytes,
entities, subscribers, queue depth, coalescing work, stale age and routed
commands per publication window. Test a stopped, slow and overloaded neighbor
while unrelated local movement/combat continues within its latency budget.

### Task W-0103 — Hierarchical cross-region navigation and actor policy

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0095, W-0102

Compile a high-level connectivity graph over region portals/seams and retain
local grid pathfinding inside each MapServer. Only actors with an explicit
cross-region policy—players, pets, escorts, event bosses or migrating ecology—
may request an authority handoff; ordinary local NPCs remain local and incur no
global routing work. Cover unreachable/changed topology, seam congestion,
owner crash, pursuit cancellation and bounded path-search budgets.

### Task W-0104 — Runtime instance world spaces

- **State:** planned
- **Phase:** 8
- **Depends on:** W-0064, W-0095, W-0098

Define immutable instance templates separately from runtime UUID-like
`WorldSpaceId`s. A supervised registry allocates a space, starts/claims its
region owners idempotently and returns a signed portal destination; it is not on
movement or AOI hot paths. Specify party membership/admission, reconnect,
return anchors, persistence boundaries, topology/template version, bounded
capacity, owner crash recovery and TTL/grace cleanup. A player can never be
persisted into a destroyed instance without an auditable safe return location.

### Phase 8 exit gate

- [ ] Handoff packets have parity entries, exact fixtures and explicit
      capability behavior for any retained unframed protocol.
- [ ] `MapServer.enter/3` returns a structured snapshot and no NPC packet
      remains out of band; no TypeScript-specific adapter is required.
- [ ] Backpressure capture proves `begin < every member < end` with no escaped,
      coalesced or dropped member.
- [ ] Epoch filtering prevents stale source entities/input from mutating the
      destination.
- [ ] The same socket/session survives every transfer; each destination
      MapServer was already loaded and no map-process startup lies on the
      transition path.
- [ ] A preloaded geographic seam renders both authorized static worlds in
      one camera space, crosses with continuous camera motion and produces zero
      blank, partial or loading frames; live destination entities appear only
      from its authoritative snapshot.
- [ ] Preloaded doors, portals and teleports atomically replace one complete
      scene with another without fabricating spatial adjacency.
- [ ] The Phase 3 two-second delayed-destination proof remains green against the
      final per-region resource and composition path.
- [ ] Failure and mid-transfer disconnect recover explicitly; 1,000 transitions
      leak no scene root, entity, decoded region or texture.
- [ ] Every activated geographic seam has a reviewed compiler disposition and
      deterministic ground/collision/gutter ownership; topology/content
      versions activate atomically.
- [ ] Cross-region visibility and commands retain one entity owner, reject
      stale epochs and evaluate gameplay rules globally without a central
      per-position bottleneck.
- [ ] Hierarchical pathfinding keeps local work local and transfers only actor
      classes explicitly allowed to cross a region boundary.
- [ ] Runtime instance IDs, ownership, admission, reconnect and cleanup are
      supervised/idempotent and always retain an auditable safe return path.

## Phase 7b — Persistent cache and coherent updates

This hardening follows the first correct transition and the first continuous
border. It improves repeat visits and deployment safety without delaying the
runtime residency and preload path those milestones need.

### Task W-0057 — Persistent cache service

- **State:** planned
- **Phase:** 7b
- **Depends on:** W-0015, W-0056

Implement Cache Storage/IndexedDB on web and application cache directories on
native. Denial, quota exhaustion, eviction, corruption and partial versions
fall back safely. Persistent entries feed the same bounded residency API proven
in Phase 7; they do not create a second asset-loading path.

### Task W-0061 — Coherent app-shell updates

- **State:** planned
- **Phase:** 7b
- **Depends on:** W-0056, W-0057

Cache the shell/service worker while remaining honest that play needs a server.
Install/activate atomically so no tab combines old WASM with a partially updated
manifest, including rollback.

### Phase 7b hardening checklist

- [ ] Warm visits do not refetch unchanged maps, sheets or audio.
- [ ] Storage denial, quota exhaustion, eviction, corruption and partial
      downloads fall back to a correct cold/runtime path.
- [ ] Service-worker activation and rollback keep one coherent
      shell/WASM/manifest set across multiple tabs.

## Phase 0b — Prototype hardening and validation

Deferred out of the critical travel path deliberately. These remain required
before release, but none is needed to prove atomic or continuous map travel.
They are worth more once real data and the final transition lifecycle exist: a
defect sweep, staging, polished account flows, private diagnostics, a component
gallery, a worst-case fixture set, a lifecycle stress run and recorded usability
sessions all test more against a live adapter than against fixtures.

### Task W-0009 — Core Bevy session screens

- **State:** planned
- **Phase:** 0b
- **Depends on:** W-0004, W-0005

Build the fixture-driven boot/loading, login, character selection, maintenance,
reconnect, invalid-session and recovery screens required to enter, retain and
recover a playable world. These are real Bevy navigation states, not DOM
placeholders, and include empty/error/slow outcomes. Registration, character
creation/preview and rankings remain in the same Bevy navigation model but are
completed with the live account flows in W-0025.

The rail's bottom navigation is a real compact icon-button row using the shared
control path, localized tooltips and accessible names. It provides supported
routes for character/statistics, journal/quests, achievements, party/social,
clan/faction, map and settings plus explicit session/logout. Unimplemented
destinations are visibly disabled with a reason; production never ships a
`navigation — not yet wired` text panel. Run W-0085's coordinate probes at all
dialog corners/edges after resize, DPR, maximize, restore and UI-scale changes.

### Task W-0093 — Prototype defect sweep

- **State:** planned
- **Phase:** 0b
- **Depends on:** W-0006, W-0007, W-0008, W-0088

Fix the concrete defects already found by running the built client:

- map inventory rejection reasons to distinct actionable feedback and emit an
  acknowledgement for accepted actions;
- rebuild a bound consumable's hotbar quantity when inventory changes;
- carry a whisper addressee through the intent and composer;
- carry the authoritative equipment slot instead of guessing from a name key;
- identify targets by presence ID rather than display name and kind;
- draw no world label without a corresponding body/stand-in;
- remove the fixture's duplicate `Provisiones` identity;
- expire combat text and level-up/system notices under explicit timing rules;
  and
- show an actionable failed-load state when the world pack is missing instead
  of silently drawing the generated green-grid fallback; and
- make the six inert top-bar actions honest. `Support`, `Language`, `Screenshot`,
  `MuteAudio`, `MuteCombat` and `Settings` are spawned as enabled, focusable
  buttons with hover states, and `handle_bar_clicks` matches only maximise and
  fullscreen — every other press falls through its catch-all. A control that looks
  live and does nothing teaches a player the client is broken, so either implement
  them or draw them as unavailable with a stated reason, and include one of them in
  the browser hit battery's sample either way.

W-0090 and W-0096 independently own truthful failure during first reveal and
handoff, so deferring this broader sweep cannot permit a placeholder transition.
Close with layer-owned tests and a busy-HUD capture showing no name without a
body, duplicated name or feedback that outlives its cause.

### Task W-0017 — Native adapters and build parity

- **State:** planned
- **Phase:** 0b
- **Depends on:** W-0015

Replace native HTTP/WebSocket and platform stubs with real implementations and
provide cache, clipboard, text composition, window/fullscreen, audio and link
services. Move pure parsers/rules into `ao-core`; both targets and all
platform-independent tests remain green. This reuses the interfaces proven by
the WASM vertical slice and cannot fork gameplay, authority or UI behavior.

### Task W-0019 — Same-origin staging deployment

- **State:** planned
- **Phase:** 0b
- **Depends on:** W-0016

Serve the WASM client and runtime configuration from the game origin while
retaining explicit development overrides. Define a reproducible staging deploy,
health check, cache headers, rollback and browser smoke path; no production host
or credential is compiled into the artifact.

### Task W-0025 — Live Bevy account and character flows

- **State:** planned
- **Phase:** 0b
- **Depends on:** W-0009, W-0016, W-0024

Connect Bevy registration, login/logout, server-provided character options,
creation/preview, selection, launch and rankings to REST and the game socket.
Use launch token plus character ID; never send account passwords over the game
protocol. Preserve reloadable routes/history on web and equivalent navigation
on native.

### Task W-0035 — Bounded developer diagnostics

- **State:** planned
- **Phase:** 0b
- **Depends on:** W-0032, W-0034

Add feature/build-gated Bevy diagnostics for redacted packets, authoritative vs
predicted position, corrections, cadence, tile inspection, transition readiness,
budgets and build/world IDs. Release builds keep bounded metrics without private
operator tools.

### Phase 0b hardening checklist

Deliberately not called an exit gate: Phase 0 is gated by its own list above, and
these items answer a different question — whether the prototype holds up once it
is pushed. `W-0013` owns the technical sweep and `W-0014` the participant
sessions.

- [ ] Persistent 90/100/110/125% UI-scale choices (or measured equivalents)
      preserve world framing, focus, selection and camera center; text remains
      legible, pixel icons remain crisp and tooltips stay inside the viewport.
- [ ] The named worst-case fixture renders bounded maximum inventory, equipment,
      spells, hotbar and chat data plus longest labels. Missing GRH/font/key and
      malformed-value variants remain stable, legible and free of raw semantic
      keys; entity/rebuild/frame baselines are recorded.
- [ ] A realistic busy-HUD capture contains nearby named players/NPCs, bounded
      chat, a selected target, damaged vitals, a populated inventory/equipment
      state, assigned hotbar items/spells, active cooldowns and pending/rejected
      feedback without overlap or loss of actionability.
- [ ] Product screens and HUD workflows are Bevy-owned and cover populated,
      empty, loading, disabled, rejected, disconnected, dead/ghost and malformed
      fixture states; dialog-boundary pointer probes match rendered controls.
- [ ] Top-bar and bottom-navigation actions use project-owned icons with
      localized tooltips and accessible names, while FPS, ping and population
      remain readable textual status. Disabled destinations explain why they
      are unavailable.
- [ ] The native/browser lifecycle stress run completes 250 resizes, 1,000 panel
      cycles and 1,000 tab switches. Shell/camera roots remain unique, invalid
      transient state is cleared and entity/listener/memory counts do not grow
      once per cycle.
- [ ] Component gallery and production UI share models, intents, fixtures,
      tokens and components; the deterministic golden matrix passes.
- [ ] Registration, preview/creation, selection, launch, rankings, logout, deep
      links and history work through Bevy.
- [ ] Same-origin staging deploy, health check, smoke test and rollback repeat;
      diagnostics remain feature/build-gated and redact private data.
- [ ] Native and WASM use the same platform contracts, authoritative models and
      Bevy UI; both builds and all platform-independent tests remain green.
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

### Task W-0010 — Secondary windows and interaction ownership

- **State:** planned
- **Phase:** 0b
- **Depends on:** W-0005

Implement open/close/focus, z-order, modal behavior, movement,
snapping/docking, optional resize, remembered positions, Escape semantics and
restoration after viewport changes. Specify click/double-click/right-click,
drag/drop, quantity and tooltip timing once rather than per panel.

### Task W-0011 — Settings, guidance and accessibility fixtures

- **State:** planned
- **Phase:** 0b
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
- **Phase:** 0b
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
- **Phase:** 0b
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
- **Phase:** 0b
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
- **Phase:** 0b
- **Depends on:** W-0001, W-0002, W-0003, W-0004, W-0005, W-0006, W-0007, W-0008, W-0009, W-0010, W-0011, W-0012, W-0085, W-0086, W-0087, W-0088, W-0089, W-0090

Run the prototype's technical checklist, archive capture artifacts and correct
every failed contract. Phase 1 is no longer gated on this: it unlocks when the
Phase 0 tasks named in the execution sequence close. This is the full-prototype
evidence sweep, and it does not fabricate the human usability evidence owned by
W-0014.

Run formatting, clippy, WASM/native checks and tests from the pinned Nix
toolchain. Phase 0 UI code has no unused imports; production interaction types
must not be dead code. Record client/core test counts, optimized raw+gzip size,
browser engine/version, GPU/backend and the full capture matrix. Before moving
any body to the changelog, verify its closure evidence exercises the claimed
layer and add the dated commit plus evidence to `CHANGELOG.md`; a green
structural roadmap count is not task-completion evidence.

### Task W-0014 — Veteran and newcomer usability validation

- **State:** planned
- **Phase:** 0b
- **Depends on:** W-0013 and recruited participants

Run task-based sessions measuring whether veterans and newcomers can find
health/mana, use/equip an item, cast a spell, trade, bank, change chat channel
and recover from rejection. Record protocol, findings, resulting revisions and
remaining tradeoffs. This is the Phase 0 product-approval gate but does not hold
idle dependency-ready Phase 1 engineering.

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
- **Depends on:** W-0020, W-0030, W-0062, W-0099

Request missing sheets ahead of movement, retain tall art and despawn material
outside byte-budgeted windows without visible holes or unbounded GPU growth.
Every dependency in the initial visible window belongs to W-0090's reveal set;
post-reveal streaming may not use ordinary movement into an unloaded visible
tile as an excuse for pop-in.

Streaming has to satisfy W-0099: the active region, visible static neighbors,
prepared destination and rollback source may all be resident. A budget that
assumes one or exactly two maps will break at a composed boundary.

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
- population-aware region placement/co-location policies after W-0102 provides
  measurements; logical ownership must remain stable while physical placement
  changes;
- larger local region storage, non-100x100 content and alternative chunk sizes;
  the canonical composed world and runtime instance spaces are production work,
  not research;
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
| W-0097–W-0098 | Compile/version topology; define canonical positions, stable region/entity IDs and checked local adapters |
| W-0021–W-0023 | Governed protocol-v2 negotiation and schema/fixture source |
| W-0024–W-0029 | Bootstrap packets, failure semantics and bounded transport |
| W-0033 | Fresh reconnect/resynchronization snapshot |
| W-0099–W-0100 | Four-region same-session seamless MVP and versioned global-position persistence migration |
| W-0042–W-0048 | Gameplay workflow fixtures and versioned metadata |
| W-0050 | Emit map triggers consumed by the Rust world renderer |
| W-0055–W-0058 | Indexed assets, hashes, range/immutable serving |
| W-0062–W-0064 | Handoff parity, structured snapshot, epoch and FIFO batch |
| W-0094–W-0096 | Atomic-transition evidence, authorized preload dependencies and exact compiler-authorized placements |
| W-0101–W-0104 | Production topology activation, cross-region AOI/commands, hierarchical navigation and runtime instances |
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

- Variable or larger-than-100x100 *local region files* during the MVP. Server,
  NIF and legacy wire coordinates use `u8` tiles; larger local storage is W-0083
  research. This does not limit the signed canonical global world composed from
  existing regions.
- Preserving or extending the TypeScript client. Incidental deletion during
  unrelated work is also excluded; W-0091 owns its bounded retirement after
  Rust production rollout and reference extraction.
- Client hashes, encrypted assets or WASM checks as an anti-cheat boundary.
- DOM/React implementation of a Bevy application screen.
