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

### Completed Task W-0004 — Typed UI models, intents and fixtures

Closed: 2026-08-18 (`4e4090d`)

Transport-independent models for every domain the task lists, in
`ao-core/src/view.rs`: progression, vitals, inventory, equipment, spellbook,
hotbar, target, chat, skills, safety, services, and — added to close this task —
minimap and world-map presentation. Nothing in `view` knows about a socket or a
packet. Rendering of the two map views belongs to W-0088 and W-0089; this is the
state they consume.

Server feedback crosses as `FeedbackKey` plus typed `FeedbackParam`, never
presentation-ready Spanish. Prose the protocol cannot classify is preserved and
explicitly marked not-a-key, so nothing branches on it.

Map availability is four states rather than an `Option` — not requested,
loading, ready, refused — because a player reacts differently to each and only a
failure is worth retrying. Reasons use their own `MapUnavailable` vocabulary
rather than `FeedbackKey`: those are gameplay results a player caused, these are
states of the client, and sharing the enum would have meant a free-form key
variant nothing could safely branch on.

Evidence:

- eight deterministic fixtures, mutually distinguishable —
  `every_scenario_is_distinguishable_from_every_other`.
- snapshot equality is semantic and allocation-bounded: `same_state_as` compares
  fields, NaN-aware so malformed data settles. It formerly compared `Debug`
  output, which allocated two full renderings of the entire interface state on
  every poll.
- the rebuild contract at its stated numbers: the first snapshot rebuilds once
  and twenty identical writes rebuild zero times
  (`an_identical_snapshot_does_not_rebuild_the_interface`), one changed field
  rebuilds exactly once (`one_changed_field_rebuilds_exactly_once`), a NaN
  snapshot settles (`a_malformed_snapshot_settles_rather_than_rebuilding_forever`),
  and a real change is not swallowed (`a_genuine_change_does_rebuild`). Counted
  from inside a system through a real `ResMut<UiState>`, because `is_changed()`
  read from outside compares against a tick `update()` has already advanced and
  answers a different question. `UiState::set` is `#[cfg(test)]`; production
  writes go through `publish`, which bypasses detection and raises the tick
  explicitly — taking a `ResMut` at all marks the resource changed the moment it
  is dereferenced, so guarding inside a setter stops the value changing but not
  the tick.
- intent filtering by explicit ordering, `IntentSet::Filter.before(Consume)`,
  proved at app level rather than by inspecting a buffer:
  `intents_are_filtered_before_anything_consumes_them` runs a real consumer in
  the Consume set and sees nothing; `a_ghost_cannot_emit_an_action_intent` and
  `a_ghost_may_still_talk` cover both halves of the rule, because filtering
  everything would strand a dead player with no way to ask for a resurrection.
- the map models: availability states distinguished
  (`a_map_distinguishes_no_data_from_not_loaded_from_refused`), retry confined to
  failures (`only_a_failure_invites_another_attempt`), distinct localisation keys
  (`every_map_reason_carries_its_own_key`), the radius enforced against the
  malformed fixture's i32-extreme markers
  (`a_minimap_never_reports_a_marker_outside_its_own_radius`), empty
  distinguished from unloaded (`an_empty_minimap_is_ready_rather_than_unloaded`),
  an overlay open while loading (`a_world_map_open_while_loading_is_a_state_a_player_can_reach`),
  a ghost keeping its map (`a_ghost_can_still_read_the_map`), and participation in
  snapshot equality (`the_map_states_take_part_in_snapshot_equality`) — without
  which a map change would never rebuild the interface and the map would freeze
  while nothing else looked wrong.
- `./build.sh check`: 338 client tests, 79 core tests, 0 failures.

One correction found while writing the fixtures: `disabled`, `rejected` and
`disconnected` derive from `populated` and had silently inherited a ready map, so
the three scenarios specifically about being told no would have shown a working
minimap.

### Completed Task W-0002 — Responsive geometry and visibility policy

Closed: 2026-08-16 (`31ddbe2`, `729451e`, `501e6c5`, `75080c8`, `450bf83`,
`a76f270`)

The rail mode is carried across frames rather than recomputed from nothing.
Entering compact needs the world below `WORLD_MIN_WIDTH`; leaving it needs a
further `COMPACT_HYSTERESIS`, so the two crossings sit 48px apart and a window
resting on the boundary settles instead of rebuilding the rail every frame.

Compact mode stopped being a promise: five vital slivers and three focusable
navigation controls, driven from the same view model the full rail uses.

Three faults were found by looking at the captures, not by the tests that
passed alongside them, and each is now held by a test that fails without its
fix:

- Every window between 920px and 968px opened as an icon strip.
  `AppliedGeometry` defaulted to the geometry of a zero-sized window — which is
  compact — and the hysteresis carried that seed forward, so the seed rather
  than the width decided the mode across the whole band. It is now
  `Option<ShellGeometry>`: never laid out is a state, and it maps onto the
  `Option<RailMode>` the layout already took.
- The compact strip drew the full rail's labelled bars on top of its slivers.
  Both carry `RailRegion::Vitals` — the same region shown differently — so the
  panel rebuild filled both. It now queries `With<FullRailOnly>`.
- The inventory grid drew over the panel below it in a short window. The
  regions themselves shrink in order and never overlap, so measuring them found
  nothing; what overflowed was the content inside a shrunken well.

Evidence:

- hysteresis as a property, not a shape: `a_one_pixel_dither_cannot_toggle_the_mode_forever`
  rules out any adjacent pair of widths that alternates, and
  `the_two_thresholds_are_a_hysteresis_band_apart` pins the band, since the
  first still passes with the band collapsed. Both fail at
  `COMPACT_HYSTERESIS = 0.0`.
- `a_window_opened_inside_the_hysteresis_band_gets_the_rail_its_width_asks_for`,
  which fails if the compact seed is reintroduced.
- `ui/testing.rs`, an app that really solves the layout — the smallest plugin
  set that makes `ComputedNode` real, no renderer and no GPU. It includes
  `FontPlugin` deliberately: without a font every string measures zero, and an
  overflow test that cannot measure text cannot fail.
- computed-layout tests over that app:
  `nothing_in_the_full_rail_is_laid_out_past_its_edge` at the narrowest full
  rail there is; `the_compact_strip_is_not_also_filled_with_full_rail_content`;
  `no_rail_region_draws_outside_itself_in_a_short_window`, which reads
  `CalculatedClip` because clipping is a render property and comparing
  rectangles alone would have passed against the bug;
  `the_solved_grid_is_six_columns_wherever_the_rail_ends_up`, counting what the
  engine put on each row at 2x UI scale, where the previous guarantee was
  arithmetic and the arithmetic is what was wrong the last time this broke.
- compact content is queried in the real tree:
  `compact_mode_renders_a_visible_vital_and_a_usable_navigation_control`,
  `a_compact_navigation_control_is_focusable_rather_than_decorative`,
  `the_full_rail_is_hidden_in_compact_mode_and_shown_otherwise`.
- captures at the breakpoint minus and plus one pixel, the minimum supported
  size (792x638, derived from the area of interest beside a compact rail),
  ultrawide and a short window, each asserting the page does not scroll. Sizes
  are expressed as the window the *client* receives and measured from the host
  page: the shell has a 1px border, and the first attempt handed the client
  919px for a capture named `breakpoint-plus-1`, producing two identical
  compact shells labelled as opposite sides of the boundary. The harness now
  fails rather than mislabelling, and refuses sizes the shell's clamps make
  unreachable. `the_capture_harness_targets_the_real_breakpoint_and_minimum`
  checks the script's literals against the client's constants.
- ultrawide: the rail reaches 757 logical pixels at 2x while the grid is capped
  at its design slot size and fills 516, so the grid is centred — left aligned
  the remainder read as a region that failed to fill.
- the area of interest is unchanged and still checked against the server:
  `aoi_client_contract_test.exs`, 2 tests, 0 failures.
- `./build.sh check`: 312 client tests, 70 core tests, 0 failures. Captures
  taken from a clean build of the closing commit.

Known limitation, not fixed here: below roughly 700px of window height the
inventory grid loses its lower rows to the clip. That is better than drawing
them over the next panel, but making them reachable is a scrolling rail.

### Completed Task W-0084 — Honest FPS, focus and ping status

Closed: 2026-08-16 (`0aa683b`, `4008cd0`, `f0f2e5a`)

The frame rate is counted over a full second of *visible* frames and rewritten
at most once per second. Latency is probed on its own five-second schedule, not
from the readout update, so a struggling client does not probe least exactly
when latency matters most.

Visibility, not focus, decides whether a sample is real. A visible but unfocused
window is still being rendered, and its rate is the truth; only a hidden or
throttled one stands down, because a tab running at a few frames a second
reported as performance says the machine is failing when it is idle. A held
reading is labelled `144 bg` rather than shown bare — an unmarked stale number
is indistinguishable from a current one.

The probe schedule resets rather than decrements. A decrementing timer preserves
average rate but, after a suspension, owes several probes and fires them the
instant the tab wakes — from every client waking together.

Evidence — each boundary the task names, proved against a fake clock:

- no second rewrite before a full foreground second —
  `no_second_rewrite_before_a_full_foreground_second`
- a background interval never becomes a foreground sample —
  `a_background_interval_never_becomes_a_foreground_sample`
- restoration starts a fresh sample — `restoration_starts_a_fresh_sample`,
  `a_long_frame_on_resume_is_not_averaged_into_the_rate`
- no probe before five seconds, exactly one at five —
  `no_probe_before_the_interval_and_exactly_one_at_it`
- a thirty-second suspension produces one probe, not six —
  `a_thirty_second_suspension_produces_one_probe_and_not_six`, with
  `the_schedule_holds_its_rate_over_a_long_run` confirming resetting has not
  quietly changed the rate
- reconnect resets timer and pending sample — `reconnecting_resets_the_schedule`,
  `reconnecting_resets_the_probe_schedule`, and
  `staying_connected_does_not_keep_resetting_the_schedule` so the probe still
  becomes due
- visible-but-unfocused keeps measuring —
  `a_visible_but_unfocused_window_still_reports_its_real_frame_rate`,
  `a_window_that_is_not_visible_does_not_report_a_frame_rate`, and
  `an_unfocused_window_is_not_dropped_to_an_event_driven_loop` pinning the winit
  update mode so the client cannot fall back to a 10Hz event-driven loop

`cargo test --workspace` — 297 client, 70 core.

Two faults found and fixed while closing. Splitting the status row into three
labelled fields had left the update writing to a `Text` component that no longer
existed on that entity, so the bar read `FPS -- PING -- ON --` permanently while
the counter beneath it worked perfectly; there is now a test that runs the
system and asserts the values change. And the probe schedule was never reset on
reconnect, so a new connection inherited the old one's elapsed time.

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

Correction, 2026-08-18 (`c99ed51`): the paragraph above is wrong in its
reasoning, and left in place because this file records what was believed at the
time. The claim that the emulated ratio is not observed is false — the client
reads `window.devicePixelRatio`, and that reading was the bug: Bevy's
`fit_canvas_to_parent` installs the parent's CSS box as the window's *physical*
size, so at ratio 2 a 1278px shell became a 639px logical window, the character
rail collapsed to its icon strip and the world drew at double zoom. The backing
store measuring the same at 1x and 2x was the symptom, not an artefact of the
harness. It was found by taking the W-0003 DPR captures and looking at them,
which the note above would have discouraged.

What is genuinely unverifiable here is rasterisation *sharpness*, since headless
Chromium composites at 1x. That, and the HiDPI render path itself, remain open
on W-0003.

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
