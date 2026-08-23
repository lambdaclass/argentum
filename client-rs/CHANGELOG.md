# Historical Rust/Bevy Client Changelog

This is the append-only archive for roadmap tasks closed before the repository
roadmaps were consolidated. The single active execution plan is now
[`../ROADMAP.md`](../ROADMAP.md), and new closures go to
[`../CHANGELOG.md`](../CHANGELOG.md). Do not add new entries here.

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

### Completed Task W-0105 — Validated exit destinations

Closed: 2026-08-22 (`5a24d737`, plus the configuration-pin correction committed
immediately after: the closure was pushed before that hole was reported, and does not stand
without it)

`Arena.Map.Movement.check_tile_exit/5` transferred a character to whatever tile an exit
named, consulting neither the arrival tile, nor the character's locomotion, nor whether the
destination was part of a map at all. Measured across the corpus: **2,877 exits point at
solid ground, 48 at a tile the destination does not draw, 4 put a walker on water** —
reachable today, **168 / 24 / 4**, with one arrival both solid and undrawn counted once as
void. Plus 2,444 void tiles across 47 maps reading as walkable floor, because the blocked
layer says nothing about whether a tile exists.

**The rule.** `Arena.World.Arrival`: solid refused for everyone, undrawn refused for
everyone, water refused to a walker and carried for a navigator, walkable accepted for
either — which preserves boat beaching, since whether a ship may run aground is a content
decision and must not ride along inside a defect fix. Beaching has two units and both are
pinned: **865 boundary pairs, 856 of which carry an exit.**

**How the source knows.** Fixed exits do not change, so the topology compiler resolves every
destination once and writes it per map — `ao-topology <pack> --exit-annotations <dir>`, 842
files, 157,353 exits annotated with their destination's class and whether it is drawn. Each
MapServer merges its own file into its own exits at load, so validation is a field read on a
record the source already holds: no cross-process call, no shared table. An earlier attempt
used an ETS table owned by whichever MapServer created it first, which would have vanished
with that process.

**Failing closed.** An exit with no annotation, one from a different world, or one naming a
destination the map disagrees with is refused as `arrival_unknown`. An unrecognised class
reads as solid. The 1,196 exits naming a map that does not exist are unannotated on purpose.
The first wiring allowed a transfer whenever the destination could not be judged, which made
the promise — the source validates before releasing authority — false exactly where it
mattered.

**One world identity, and one source of truth for it.** Annotations are versioned by the map
pack's content hash,
`sha256(pack)[0..16]`, the same identity already in every `maps.<hash>.pack` filename. A
first attempt hashed the same bytes with FNV-1a and gave the pack a second name. SHA-256 is
hand-written here because the tree builds offline, and its correctness is confirmed
independently: over the real pack it produces `17afc00c9c7e0b4c`, which is the filename it
was never told. The server compares the annotations' claim against the pack it actually
built — an artefact agreeing with itself proves nothing — and boots in that order: build the
pack, check the annotations, then start the MapServers that will trust them.

`:map_pack_hash` in configuration is an *assertion* about that hash and never a substitute
for it. An intermediate version let configuration answer "which world is this", which would
have allowed a stale pin and stale annotations to validate each other while both described a
world nobody was serving. A pin that disagrees with the built pack now fails the boot,
naming both values.

**Ownership.** Refusal happens before the step onto the transition band, so a rejection
begins no handoff at all. Counted rather than assumed: solid, void and water-on-foot each
leave exactly one owner and zero transfer effects, with position untouched; valid walking,
sailing and beaching each produce exactly one. The client is corrected immediately with an
authoritative `pos_update` for the position it never left, asserted at handler level —
exactly one, carrying the unchanged tile, with no transfer.

Evidence: `mix test` 823 tests, 0 failures, including 17 in `arrival_ownership_test.exs`
(rule, fail-closed, world identity, ownership counts), 10 in `world_arrival_test.exs`
(the corpus gate over 3,049 generated cases), and the handler-level correction test in
`movement_collision_drift_test.exs`; `./build.sh check` 0, including a new gate that
regenerates all 842 annotation files and compares them byte for byte — verified to fail by
tampering with one line of `map-330.txt`.

Deliberately out of scope, and W-0096's: the typed `arrival_blocked` receipt, destination
preparation for dynamic conditions such as capacity, and deduplication of a repeated
transfer. The repeated-call test here proves classification is deterministic and is named
for that; nothing in this task would stop a duplicated message from starting two handoffs.

### Completed Task W-0097 — Versioned world-topology compiler

Closed: 2026-08-22 (`5633b9ae`)

Compiles the 842 CSM maps into a deterministic, content-hashed `WorldTopology`
(`3e6df36b27c82aab`, 3,903 lines) and refuses to decide anything the data cannot
support. Four statuses separate what was measured from what was permitted:
`unresolved`, `candidate`, `reviewed`, `active`. Active requires *both* a
hand-recorded `geographic` disposition in `assets/world-topology/reviews.txt` and
agreement from the evidence, so 0 seams are active and 164 are candidates awaiting
review. A test proves a review cannot activate a seam the measurements reject, and
another proves 100% ground-art continuity activates nothing.

**Geometry.** The world is not one plane. `Geometry` is `Plane | Cylinder | Torus |
Discrete`, measured from each space's own failing loops and admissible only if the
space still fits it — without that test a 2-map wrap "explained" 424 maps in 44
cells. 226 spaces, 199 of them reachable only by transition, 1 torus (148x160, the
Newbie Dungeon, a candidate shape pending review). The 74x80 core pitch and the
band-to-core-edge seam rule are confirmed visually by `--example render`, which lays
the world out from seam evidence alone.

**Evidence per seam.** 2,219 candidate seams, 170,836 tile pairs, judged on what a
character can do rather than on whether artwork matches: 41,560 crossable on foot,
12,176 by boat, and the three-tile path (core edge, transition band, arrival)
classified together because the band gates whether a walker can leave at all.
`Atlas` resolves a global position to exactly one map or reports `Ambiguous`, which
inverting `to_global` with its own origin never could.

**Four defects found, none corrected here.** 169 exits transfer a character into
solid rock, 48 arrive on a tile with no ground, 4 leave a walker standing on water,
and 2,444 void tiles across 47 maps read as walkable floor. All four are the exit
path trusting a destination it never checks —
`Arena.Map.Movement.check_tile_exit/5` consults neither the arrival tile nor
`navigating` — and they are one server change, recorded for `W-0101`. A client that
predicted a refusal the server does not make would desynchronise exactly where a
player is most likely to be lost.

**Cross-language.** `Arena.Map.TileSemantics` owns what a tile value means;
`Arena.Map.Movement` calls it and so does the fixture generator, so a handwritten
table cannot drift from behaviour. `fixtures/tile_semantics.txt` pins 143 positions
across eleven maps covering all three tile classes, checked in unit tests without a
corpus and against the pack in `--check`: 0 disagreements. `mappack::Tile` now
delegates to `tiles::TileKind`, closing a second "same byte, two meanings" gap where
VB6 value 4 was walkable to one reader and solid to the other.

**Ownership boundary.** Per-layer ownership is emitted as unreviewed records with no
field for an owner; `W-0101` supplies the artist rule. Handed over: 365 land, 823
shore and 10,264 sea tiles where two maps draw a layer differently, and 826/375/6
where their collision disagrees.

**Acceptance.** 87 squares have reciprocal seams and no contradiction; only **42
survive all eight directed crossings**, which retired the first candidate
(`199 274 / 573 570` transfers two characters into rock walking north). The artifact
is `330 269 / 274 287`: eight clean crossings, 100% gutter continuity, a corner
closing on four distinct contiguous tiles, and four pinned walking routes in
`fixtures/walking_paths.txt` — all on foot, each advancing exactly one global tile,
each handing authority between MapServers, east/west and north/south exact inverses.
Rendered pixels agree 100% across every sampled crossing, decoded from the real
sheets rather than compared by graphic id.

Evidence: `./build.sh check` from clean HEAD `5633b9ae` — roadmap structure,
formatting, wasm target, native target, 589 + 155 + 3 tests, configuration, world
topology baseline; `ao-topology --check` exit 0 with the manifest hash, the tile
semantics fixture and the walking routes all verified against the corpus;
`mix test apps/arena/test/tile_semantics_test.exs` 9 tests; renders at
`--example render`; `--manifest`, `--dependencies`, `--walks` and `--pixels` outputs.

Deliberately not done, and recorded rather than assumed. Two of these need human
judgment and one does not:

- **Engineering, not judgment:** the destination check. Classified by destination,
  2,877 exits point at solid tiles, 48 at undrawn void and 4 strand a walker on water;
  reachable today, 168 / 24 / 4, with one arrival both solid and undrawn counted as void.
  Plus 2,444 void tiles reading as floor. `Arena.Map.Movement.check_tile_exit/5` validates nothing about where it sends a
  character, and that is a defect needing a server implementation and tests, tracked as
  `W-0105`. Calling it a decision for somebody else was wrong: nobody has to decide
  whether a player should end up inside rock.
- **Product or artist judgment:** per-layer gutter ownership exceptions, the ocean's
  geometry and its 34 contradictory claims, and any genuinely ambiguous geography or
  transition classification (`W-0101`).

### Completed Task W-0090 — Atomic first-scene reveal

Closed: 2026-08-21 (`4dcbc9d`)

The world is not shown until it is worth looking at. Before this, the boot screen was
a page element that lifted two frames after `init()` resolved — when the wasm module
*starts* — so a player watched the world assemble: a placeholder grid, then sheets
arriving one at a time, then item icons replacing their own names. The screenshot that
prompted the task showed flat green tiles and text where artwork belongs, with nothing
on screen admitting it was still loading.

`reveal` owns the decision as pure data: a named set of members, a monotonic load
generation, and progress counted from completions. Nothing about it touches Bevy,
because the questions that go wrong here are about order and identity — which members
are required, which load an answer belongs to, whether progress can regress, whether a
late answer from an abandoned load can reveal a scene nobody is waiting for — and every
one can be tested exhaustively without a GPU. None can be tested honestly through a
screenshot.

`ui::barrier` draws it: opaque, above every panel, carrying the same `Modal` marker a
dialog does so gameplay suppression is the rule that already exists rather than a
second one. A failure replaces the progress bar instead of sitting beside it, because
86% next to a dead load says "nearly there" about something that will never finish.

**What the first frame requires**, and why each is there: the map's own data; every
sheet the paint window needs; the character *drawn*, not merely describable; the NPCs
and ground items in view, bounded by the server's area of interest because terrain is
public map data and an entity outside the AoI is something the server never disclosed;
the interface font, checked by asking whether it actually replaced the default handle;
the HUD atlases and fallbacks; a snapshot that was published, which the resource
records rather than something to infer from its contents; and a composed frame — every
drawable tile in the window actually spawned, which is the observable form of "the
first frame's uploads are done" since Bevy's main world offers no residency signal and
inventing one would be a claim rather than a check.

**Four defects the barrier found by existing.** Four sheets in `resources/raw/Graficos`
are named `.PNG` while every index asks for `.png`, so on a case-sensitive filesystem
they 404 — and one is ground art at Ullathorpe's spawn point, where every character
starts. Both clients had drawn that hole silently for as long as the server has
existed. The loader never fetched object artwork at all, so barrels, signs and trees
were never part of any first frame. A failed sheet was a `log::warn!` and nothing else,
which is right for an optional sheet and wrong for one the visible scene needs. And a
failed map fetch left the barrier waiting forever while the state machine moved on to
`Playing` behind it.

**Time to a complete first frame**, against the dev server under software rendering:
ninety seconds when the barrier first existed, then seventy-two once the spawn view's
tiles were fetched before every body and head, then thirty with six workers instead of
one await at a time, then **five** once the required set matched what was actually
being fetched. The first frame needs 48 sheets and 2,434 tiles; the rest of the map's
artwork continues afterwards, which is what the contract asks be recorded separately.

Evidence:

- `./build.sh check` from clean HEAD: roadmap structure, formatting, wasm target,
  native target, 589 tests, configuration check.
- 25 `reveal` tests and 9 `ui::barrier` tests: an empty set is never ready, completion
  order is irrelevant, one slow member holds the whole scene, an answer from an
  abandoned generation is refused, an unrequired member is refused rather than added,
  progress cannot regress except to a failure, a failure outranks the bar, a revealed
  scene stays revealed, byte totals stay unknown until every reporter knows its own, a
  fetch failure is retryable and a corrupt file is not, a window that grows mid-load
  starts a new candidate, a reconnect abandons a candidate but not a shown world, and a
  thousand load-and-cancel cycles leave one barrier and no entities behind.
- `scripts/browser-test.mjs --only reveal`, 13 checks: with one required sheet held by
  request interception, the reveal flag is false, the pointer over the middle of the
  world does not resolve to world, arrow keys leave the player where they were, and
  five pixels sampled away from the barrier's text are all exactly rgb(7, 7, 14) —
  `surface::VOID`. A resize and a maximize mid-load keep all four corners covered. Then
  the sheet arrives and the world is drawn and clickable. Separately: a required sheet
  answering 503 stops the scene and says so, the retry control appears in the published
  rectangles, and a real click on it re-fetches and reveals. And a warm second load,
  where every asset is cached, still commits a complete scene.
- Full browser gate at build `4dcbc9d`: **794 checks, 0 failures**.

Not covered, and owned elsewhere rather than quietly dropped:

- The candidate is staged behind an opaque barrier rather than in a hidden scene root.
  For a *first* scene these are observably identical — nothing was on screen before —
  and the pending-root machinery belongs to `W-0065`, which needs two resident worlds
  for handoff.
- The failure screen offers retry but not back or logout, which need the session
  screens in `W-0009`.
- Equipment is not part of the character composition anywhere in the client yet, so it
  cannot be a member of this set; the player's body and head are.
- Real fullscreen needs a user gesture automation cannot supply — `W-0073` — so the
  maximize path is what the mid-load checks use.
- Entity cleanup across a thousand cycles is asserted; texture and listener residency
  have no honest measurement from Bevy's main world, so no claim is made about them.

### Completed Task W-0089 — Tab world-map overlay

Closed: 2026-08-20 (`c377ec9`)

Tab opens a whole-world map inside the world viewport. The top bar and character
rail stay where they were and stay clickable, because a map is something you
consult while playing rather than a screen you leave the game for. Tab or Escape
closes it, once per press.

While it is open the world does not act. It is a modal — the same rule a dialog
uses, stated once instead of in every gameplay system: no movement, no casting, no
targeting, and a click over the map is not also a click on the ground behind it. An
armed spell and a drag in progress are released under their own cancellation rules
rather than left pointing at something the player can no longer see. What the map
suppresses is what the *player* can send: a snapshot arriving while the map is up
still reaches it, because a client that stopped applying server state would look
frozen and would show a stale world the moment the map closed.

The view fits the whole world and letterboxes the spare axis. The wheel and `=`/`-`
zoom, the arrow keys and a drag pan, `whole world` refits, `centre on me`
recentres. Every path is clamped: a malformed view, a zero-sized world or a
zero-sized viewport falls back to the last view that worked rather than producing a
NaN transform, and zooming out cannot take the world out of its own frame. Clamping
outranks anchored zoom at a letterboxed axis — keeping the world in frame matters
more than keeping the tile under the cursor still — and that precedence is asserted
rather than left to whichever branch ran last.

It draws the region name, the player's coordinates, the player's own position as a
gold ring, and one marker per category with hover, focus, a tooltip and a distinct
*shape*, so no category depends on colour. The legend is also the filter, and each
entry carries the same glyph the map draws, from the same builder, so the two
cannot drift apart. Filtering changes only what is drawn.

What it draws is what the server sent. The snapshot carries five presences, two of
them hostile creatures, and clearing the marker list empties the map completely — a
map that drew a dot per presence would look richer and would be telling the player
where the monsters are.

The overview art does not exist yet, so `assets/world-map/MANIFEST.md` is its
entry: id, path, source, licence, 2048 maximum and 1024 reduced dimensions, a 2 MiB
compressed ceiling, 16 MiB decoded, and the outline for anything below the reduced
profile. The client embeds it and fails a test if the numbers disagree with the
constants it compiles in, and publishes the profile the running device would
actually get, so the fallback can be observed rather than asserted. Which profile a
device gets is decided from its own reported texture limit, never from the user
agent — guessing from the user agent is how a client asks a phone for sixteen
megabytes.

The first capture of this overlay was a black rectangle with six dots in it: exactly
the state this task forbids by name, drawn by the code meant to prevent one. My own
documentation had promised a vector outline and never drawn it. Finding it needed
someone to look at the picture — the byte sizes were entirely consistent with a
working overlay. The world's rectangle and a ten-tile grid are drawn now, through
the same camera as the markers so they pan and zoom together, and an unavailable map
draws no outline at all, because an outline around nothing is a claim that the world
is that size.

Evidence:

- `./build.sh check` from clean HEAD: roadmap structure, formatting, wasm target,
  native target, 552 tests, configuration check.
- 37 `ui::worldmap` tests, including the outline and grid moving with the camera,
  no outline for an unavailable map, the manifest agreeing with the compiled budget,
  markers coming only from the snapshot, the legend sampling every category, and the
  session continuing to apply snapshots behind the open map.
- `scripts/browser-test.mjs` at build `c377ec9`: **780 checks, 0 failures**. Tab
  opens and Escape closes; three presses read open, shut, open; the world is not
  clickable through the map; a hotbar key does nothing; arrow keys are refused at
  the fitted view and pan a zoomed one while the player does not move; the wheel
  clamps in both directions; a legend filter changes exactly its own markers and
  restores them; the rail is still reachable and still activates; the device is
  offered the largest overview it can hold within its memory budget and its wire
  ceiling matches the manifest; and the map survives windowed, maximized and
  fullscreen mode changes and still closes.
- `scripts/capture.mjs`: 30 map captures — whole-world, zoomed, panned, filtered and
  closed at every ratio in the matrix, the unavailable view from a separate boot at
  `?scenario=disconnected`, and the map open across maximize and restore. Looked at,
  not merely counted.

Three harness defects were found and fixed rather than retried: a fixed frame wait
read a half-rebuilt overlay after a ratio change; the replacement accepted "has not
started yet" as "has settled" and reported five map checks as client failures; and
the filter check assumed which way a toggle pointed, so a pass that inherited a
filtered map read filtering as *adding* a marker. `--only map` now runs the same map
assertions in 348 checks instead of 780, because paying hours to validate one
overlay change is how a harness bug survives to the third run.

Not covered: real fullscreen needs a user gesture automation cannot supply, so the
adapter is tested for reporting the mode it actually reached and the map is captured
across maximize instead. HiDPI rasterisation sharpness is W-0092's. The wording of
the unavailable states is a label rather than an instruction, which W-0093 owns
along with the rest of the client's placeholder honesty.

### Completed Task W-0085 — Pointer and hit-test coordinate integrity

Closed: 2026-08-20 (`d0e5af2`, verified again at `c377ec9`)

One coordinate pipeline from the pointer to the world, applied exactly once each:
CSS presentation size, backing-store size, device pixel ratio, UI scale, camera
viewport offset and world projection. The control visibly under the pointer is the
control that receives the event, and a click on the interface does not also reach
the ground behind it.

Proved where the question lives — in a browser, with a real pointer. 548 checks at
ratios 1.0, 1.25, 1.5, 1.75 and 2.0, windowed and maximized, and again after a
mid-session resize and a mid-session ratio change: centre and per-edge probes one
pixel inside and one pixel outside an inventory slot, a hotbar slot, a rail tab
and a top-bar icon; exactly-once activation; the world's centre and four edges
against the tile actually drawn; the world/rail seam; a control floating over the
world intercepting its own click; a pointer-driven inventory drag; and a control
keeping its CSS size across a ratio change. Screenshots and coordinate arithmetic
alone would not have found any of the three defects below.

Three defects were found by that evidence and fixed rather than accommodated:

- A click on the hotbar also selected the tile beneath it. The hotbar floats
  inside the world viewport, so a player meaning to drink a potion walked two
  tiles instead. Fixed with an explicit interception rule rather than by moving
  the hotbar out of the way.
- One click activated a control twice whenever the picking event and the first
  observed press landed in the same frame. The first guard cleared its flag on the
  rising edge, wiping what the observer had just set; the guard now ends with the
  press.
- A mid-session device pixel ratio change laid the whole interface out at half
  scale. `camera_system` refreshes a camera's cached scale factor only for windows
  named in a window message, and the client had changed its own window silently.
  It announces the change now.

Two probes named in the contract are owned by the tasks that create the surface
they need, and were reassigned rather than left to hold this foundation open:
W-0009 runs the same dialog-boundary probes when it creates a production dialog,
and W-0073 owns physical fullscreen hit testing, which needs a real user gesture
automation cannot supply — the automated refusal path is covered here. The spell
control the contract also named arrived with W-0007 and is covered: the battery
switches to the Spells tab, checks a row activates exactly once and that a click
just outside it does not, and puts the inventory back.

### Completed Task W-0088 — Fixture-backed minimap presentation

Closed: 2026-08-19 (`e94832e`)

The well in the world's upper right said "minimap unavailable" from W-0002
onwards. That was honest while nothing read the map data and a lie the moment
something did: the snapshot has carried an availability, a map number, a centre,
a radius and four markers all along.

It draws them now — player, party, hostile and landmark — each with its own
*shape* as well as its own colour, because a player who cannot distinguish two of
the colours still has to be able to tell a party member from a wolf. North is
marked and the coordinates are written out, since a map you cannot read your
position off is one you cannot use to tell anyone where you are.

What it draws is what the server disclosed and nothing else. No map asset is read
to find entities the server did not mention; a minimap showing withheld hostiles
would be a wall-hack built out of presentation code.

Idle, loading and the four reasons a map can be unavailable each say which one
they are, because "nothing yet" and "nothing here" send a player to different
places. A marker beyond the radius is dropped rather than clamped to the edge,
which would read as a crowd gathering at the border. A radius of zero covers one
tile instead of dividing by nothing — the malformed fixture sends one, and
dividing produced infinities.

Evidence: 499 tests in `ao-client`, including placement, orientation, the
malformed radius, every fixture's markers, per-kind shape and colour
distinctness, and app tests for the drawn map, the unavailable state and a map
change leaving nothing behind; 584 browser checks against build `e94832e`, all
green. The well is square and clipped at every supported window size including
the compact rail.

W-0039 owns the later authoritative live-world connection.

### Completed Task W-0008 — Chat, target, safety and feedback prototype

Closed: 2026-08-19 (`bf74d6e`, `afab30c`, `b5ae76b`, `ada0f73`, `c0fb8ff`,
`778d4cd`, `7a379b0`)

The HUD over the world, judged against a map with people on it. The populated
fixture now carries five presences — two citizens, a merchant and two hostiles,
one speaking and two taking hits — and six channels' worth of chat, because a
HUD tested on an empty map is tested against the wrong thing: the parts that
fail first fail because of each other.

The message overlay is bounded and wrapped so a long announcement cannot reach
under the minimap, five lines collapsed and fourteen expanded, oldest faintest,
with a filter per channel that marks itself off in two ways at once. A line with
no body is dropped rather than drawn as an invisible row that still takes a place
in the bound. The composer is where focus ownership becomes visible: Enter gives
it the keyboard, Enter again sends on the active channel, Escape hands the
keyboard back and keeps the sentence.

Names, bubbles and combat text are placed over the world by three stated rules —
priority by distance, overlap resolved by dropping rather than nudging, fade by
distance — with ties broken on identity so a crowd resolves the same way every
frame. `screen_of_world` and `tile_centre` joined the coordinate pipeline rather
than being computed in the panel that wanted them.

The target strip names the target, says what kind it is in words, and draws
health only when the server disclosed it. It stops showing a target once the
answer cannot still be true: death, a map change, a disconnect, or the character
no longer being among the presences the server sends — which is how range and
visibility loss reach the client.

Notices stack above the hotbar with a marker glyph as well as a colour, bounded
to the newest four, and the connection's own state joins them last, because from
the player's side both answer "why did nothing happen". `FeedbackKey::Muted` and
`FeedbackKey::is_refusal` are new: being silenced leads somewhere different from
being blocked, and a client that treats every notice as a refusal disarms an
armed spell the moment a level-up arrives.

The safety toggles replaced the words "not yet wired" in the rail's navigation
region. They say "on" or "off" as well as carrying a border, and they ask the
server rather than flipping the client's own copy.

Focus ownership is now complete: a text field, an IME composition and a modal all
take the keyboard from the world. The modal rule is a run condition on the whole
gameplay set rather than a check inside each system, and movement is tested
through it — a player answering a dialog must not walk out from under it.

Evidence: 488 tests in `ao-client` and 82 in `ao-core`, and 584 browser checks
against build `7a379b0`, all green. Two defects the evidence found: a target that
contradicted the fixture's own crowd, and "any feedback" standing in for "a
refusal".

### Completed Task W-0007 — Spellbook and hotbar prototype

Closed: 2026-08-19 (`1ca1735`, `5b2c763`, `83be5bd`, `d646fa5`, `200c769`,
`079a221`, `62930c3`, `0f5dcc4`)

The spellbook and the numbered hotbar, both operable. `spell_row` and
`activate_spell` had existed for some time with no production caller, so the
book could be rendered and not used and the decision the module exists to make
— cast now, or arm and wait for a target — was never made.

Rows are controls with stable keys, drawn with the graphic their spell names,
the mana cost, and the reason a blocked spell cannot be cast in words rather
than as `spell.blocked.mana`. Clicking a ready self-cast or area spell sends
exactly one cast; a ground or entity spell with nothing selected arms, and a
world click spends it — target first, then cast, which is the order a server can
refuse in halves. An armed spell disarms on the cast, on Escape, on death, on a
disconnect and on an authoritative refusal.

Hotbar slots draw their binding's graphic, how many of a bound consumable the
player is carrying, and a veil in proportion to the cooldown left. Pointer and
keyboard share one activation function, so a key that refuses a cooling slot
cannot disagree with a click that sends it; the number keys stay suppressed
while text owns the keyboard. Dropping an inventory item or a spellbook row onto
a slot binds it, Shift-click empties it, and the page control turns the page.
The stand-in authority keeps the pages, because an assignment that vanished on
the way to page two and back would read as the server refusing something it had
already accepted.

The rail's tab strip became real in the process: three equal-width controls that
switch the panel by pointer or keyboard, keep their selection across the
snapshots that rebuild the rail, and do not move the regions below the grid.
`Intent::ClearHotbarSlot` is new and deliberately separate from binding.

Evidence: 442 tests in `ao-client`, including tests that activate and drop onto
the production spell and hotbar entities and observe the intents, the armed
state and the rendered blockers; and 586 browser checks against build `0f5dcc4`,
which now include the spell control W-0085 was waiting for.

Three defects the evidence found: tabs that were not equal width because
`flex_grow` shares only spare space; a panel rebuilt after the controls were
presented, which flickered resting colours for a frame; and a refused inventory
slot whose danger border was repainted away, fixed by giving
`present_controls` a `Danger` component to read.

### Completed Task W-0006 — Character, vitals, inventory and equipment prototype

Closed: 2026-08-19 (`c850253`, `6308dcb`, `55229e2`, `973c4a0`, `c9f03ca`,
`41ddf0e`, `b2fda64`, `a6a7ee0`, `e1bc28b`, `fe356a1`, `f60787d`)

The character rail, fixture-backed and operable: name, class and level, XP,
world time and area status, currency, the inventory grid with real item artwork
resolved through the game's own object table, quantities in corners, equipped
markers, visible locked slots, an equipment summary of icons rather than a list
of names, selected item detail, vitals, and the character's skills behind a
real tab strip.

Interaction goes through the shared controls from W-0005. A single click
selects; a double click emits exactly one use or equip intent, decided by the
item's action metadata rather than inferred from its stack size; Shift-click
applies the drop-one rule; a drag emits a move only for a valid distinct
destination, and Escape, the pointer leaving the window, focus loss, a closed
panel or a rebuilt grid all cancel it. While an intent is unanswered its slot
is guarded against a duplicate and says so with an ellipsis; a refusal marks
the slot with an exclamation and a danger border rather than only a line of
text elsewhere.

The snapshot changes only after the simulated authority accepts. A refusal
leaves the item exactly where it was and answers with a semantic feedback key,
which is the order that keeps items from appearing to duplicate and vanish when
the real server says no.

Evidence: 415 tests in `ao-client`, including interaction tests that activate
and drag the production slot entities and assert the resulting `IntentMessage`
and cleanup, and 548 browser checks against build `d0e5af2` — among them a
pointer-driven drag between two slots that exchanges their contents, run at
device pixel ratios 1.0 through 2.0, windowed and maximized, and again after a
mid-session resize and ratio change.

Two defects found by that evidence and fixed rather than accommodated: one
click activating a control twice whenever the press and the `Interaction`
transition fell in different frames, and a mid-session device pixel ratio
change leaving the whole interface laid out at half scale.

### Completed Task W-0005 — Design tokens and Bevy primitives

Closed: 2026-08-18 (`401cfca`, `f13fdb1`, `8427db0`, `89d3c66`, `9436dea`,
`c54a079`, `646162f`, `71f72ed`, `21e0c0d`)

Versioned tokens for typography, colour, borders, spacing, icon and slot sizes,
focus, disabled, rarity and status, and the shared Bevy controls that use them:
button, tab, slot, status bar, list and list row, text and password field,
tooltip, menu, dialog, notification, drag ghost, progress/cooldown and hotkey
prompt. One focus, activation and state model, the same systems on WASM and
native with no `cfg` between them.

Three faults found while building it, each of which made a control look finished
and behave as decoration:

- `button`, `tab` and `slot` attached `Control` but not `Button` — and `Button` is
  what requires the `Interaction` that `track_pointer` queries. Everything they
  produced was invisible to the pointer: hover never registered, a click did
  nothing. The panels that worked did so by adding `Button` themselves, which is
  the duplication this task exists to remove.
- The inventory slot had the same gap, so clicking an inventory slot did nothing.
  The hotbar slots had neither component: the number keys worked while the slots
  themselves were decoration that Tab passed over. `controls::interactive` now
  names the contract and all three use it.
- `TextInputActive` was described as the single definition of who owns the
  keyboard while movement had no rule at all — typing "w" walked the player — and
  the hotbar consulted the snapshot directly. It is now computed from both sources
  that can make it true and read by movement, hotbar keys and spell disarm in a
  `GameplayInput` set ordered after the interaction pipeline, so a keystroke
  cannot be taken as movement in the frame a field gains focus.

Behaviour, with the reasoning in the code:

- F6 enters and leaves focus navigation. Tab traversal was unconditional, which
  took a gameplay key — the whole-world map opens on Tab (W-0089) — and a focus
  ring walking the interface mid-fight is not what a player pressing it wanted.
  Leaving navigation drops the ring, unless a text field holds it, since dropping
  focus mid-sentence would discard what was being written. The host suppresses Tab
  and F6 only while the canvas has focus: with default handling left on, Tab moved
  browser focus off the canvas and ended the session's keyboard entirely.
- `Modal` confines traversal to the topmost dialog or menu. Tab walking out of a
  dialog into the panel it covers is the difference between a modal and a floating
  box.
- The text field is complete rather than present: a typed `TextEdit` boundary for
  the adapters in W-0015..W-0017, editing applied only to the focused field, an IME
  preview held apart from the value so cancellation can withdraw it, masking that
  never alters the value, and the caret drawn *at* `caret()` — it was appended to
  the end, so pressing left moved the model and nothing on screen. Character
  indices throughout, because a byte index lands inside "año".
- Tooltips are placed below by preference and above when below would leave the
  viewport, using the tooltip's measured size once it has one. They were always
  below with no check, which put them off-screen exactly where they are needed:
  the bottom of the compact rail and the right of the top bar.
- Status is never colour alone. Focus adds border *width* — it was a colour change
  and nothing else, and focus is the one state a player cannot play without
  knowing. Selection marks a leading-edge bar via the `Selected` state, notice
  levels carry a text marker, and locked slots draw a mark.

Evidence: 372 client tests, 79 core tests, 0 failures. The interaction tests spawn
the exact production builder and add nothing by hand — their pointer helper reads
the `Interaction` the builder should have supplied, so an omission fails with "the
builder produced a control with no Interaction to drive". Browser checks confirm
Tab, Shift+Tab and F6 leave focus on the canvas. Every behavioural claim above was
verified by mutation: removing the fix makes the test fail.

**Builders with no production consumer yet, and who owns each.** This task's
"no unused builder" rule cannot be satisfied here, because the consumers belong
to tasks that depend on this one: `spell_row` and `cooldown_overlay` to W-0007
and W-0010, `dialog`, `menu`, `notification` and the chat/password fields to
W-0008, `list` and `list_row` to W-0007 and W-0008, `drag_ghost` to W-0009, and
`button`, `tab`, `slot` and `progress` to those panels and to the gallery in
W-0012. What this task owns — each control complete, carrying the components the
pipeline queries, activated in tests through the real plugin, and no builder
duplicating something the plugin already does — is met. Adoption is each owning
task's evidence. `shell::focus_ring` was deleted rather than adopted, since
`present_controls` already renders focus; `hotbar::selection_ring` and a second
`slot_key_code` were byte-identical copies, and the `Tooltip` marker was never
constructed.

### Completed Task W-0003 — Scaling, fullscreen, resize and DPI

Closed: 2026-08-18 (`c99ed51`, `df4a563`, `ec7fa8f`, `6d0db91`, `87441d5`,
`f9df406`, `3b9c597`, `188314a`, `2bb6532`, `d92149f`)

Three scale domains kept separate and proved in Bevy rather than in arithmetic:
device pixel ratio, integer world zoom, continuous UI scale.

The fault this task existed to prevent turned out to be live, and was found by
taking the DPR captures and looking at them. At an emulated ratio of 2 the
character rail had collapsed to its icon strip and the world drew at double zoom
— a display setting silently changing how much of the game a player could see.
Bevy's `fit_canvas_to_parent` installs the parent's *CSS* box as the window's
*physical* size, so with a scale factor from the display the client computed its
logical size as css/ratio and a 1278px shell became a 639px window. The web build
now pins its scale factor to 1: one CSS pixel is one logical pixel, whatever the
display reports.

Evidence:

- `the_camera_viewport_is_the_world_node_at_every_ui_scale` compares the solved
  `ComputedNode` bounds of the world region against the camera's actual viewport
  at UI scale 1.0 and above it, and asserts the two cases really are different
  scales so it is not one case written twice. Removing the `node_px`
  compensation makes it report a 3994x2920 node against a 1997x1460 viewport.
- `a_device_pixel_ratio_change_alone_does_not_change_what_is_framed` runs the
  1.0/1.25/1.5/1.75/2.0 matrix natively — `shell_app_at` keeps the logical size
  and grows the backing store, which is what a higher-DPI display is. Deriving
  the geometry from physical size instead makes 1.25x frame 1248x920 where 1x
  frames 998x760. Paired with
  `a_higher_ratio_buys_more_physical_pixels_for_the_same_world`, so "nothing
  changed" cannot pass by the ratio being ignored entirely.
- restore preserves what the player was doing:
  `a_host_mode_change_and_back_preserves_what_the_player_was_doing` (selected
  item, focused control by key, half-typed text, camera centre) and
  `the_pointer_is_recomputed_for_the_geometry_the_window_now_has`, which fails
  when `resolve_pointer` is made to cache its geometry — otherwise the first
  click after a restore lands on the tile the *previous* window had under the
  cursor.
- browser checks: one CSS pixel is one logical pixel at every emulated ratio; one
  resize moves the backing store to exactly one new size; three host modes with
  truthful fallback when fullscreen is refused; the windowed step-up.
- the windowed shell now takes the largest whole multiple of 1280x760 the
  viewport has room for, and `a_stepped_host_window_actually_steps_the_world_zoom`
  proves a 1, 2 and 3-step window resolves to world zoom 1, 2 and 3 — without
  which a larger window would have been a wider view rather than a larger scene.
- captures: the DPR matrix at 1.0/1.25/1.5/1.75/2.0, plus windowed, maximized,
  restored, ultrawide, minimum supported, short window and a stepped 4K shell.

Two claims of mine were wrong and are corrected in place. The harness said
Playwright's `deviceScaleFactor` "is not observed by winit"; it is, and that
reading was the bug — a note explaining the evidence away. And a first attempt to
assert layout invariance in the browser sampled rendered pixels for the rail's
edge, reported the same value at every ratio while the captures plainly showed
the rail collapsing, and was deleted: a check that passes for the wrong reason is
worse than none.

Also fixed here because it made every capture untrustworthy: `build.rs` only
re-ran when `.git/HEAD` moved, so editing a source file left the previous stamp
baked in — precisely when `-dirty` should appear. And the capture harness waited
four seconds and assumed the world had loaded, which is how twenty-four
screenshots of a bare placeholder grid were filed as evidence; it now preflights
the asset origin and waits for the client's own report of decoded sheets and
painted tiles.

**Deferred to W-0092:** rendering at physical device resolution. The pinned path
meets every scaling requirement in the Phase 0 exit gate — pixel alignment across
the DPR matrix, the three scales kept separate, a DPR-only change preserving
framing and tile count, no shimmer — and it forgoes the extra resolution a HiDPI
display offers, so interface text is upscaled there. That is real debt, deferred
by decision on 2026-08-18 and recorded as its own task rather than left implicit.

`examples/render_target_probe.rs` remains as the diagnostic for it: clearing an
image target, a colour-only quad, a textured sprite, and two cameras with two
targets in one frame all pass natively, so the mechanism is sound and the
production failure was none of culling, asset usages or MSAA — every one of the
things changed while guessing. WebGL2 is the remaining suspect. The probe's first
version reported a false failure, because readback fires every frame and the
earliest completion describes the texture before anything has rendered into it.

`./build.sh check`: 351 client tests, 79 core tests, 0 failures.

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
