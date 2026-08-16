# Rust/Bevy Client Roadmap

Tracks remaining work for `client-rs`, the Bevy client targeting the browser
(wasm/WebGL2) and native desktop from one codebase. It is an alternative to the
TypeScript/Pixi client in `client/`, not a replacement — both speak to the same
Elixir server.

Phases can overlap, but they are ordered by what unblocks what. Browser tests,
protocol fixtures and performance measurements start with the feature they
protect; they are not deferred to a final QA pass.

Items are tagged **[server]**, **[client]** or **[client/design]**. Some of this
work lives in `server/`, not here—it is tracked here because it exists to serve
this client, and splitting it across two roadmaps would hide the dependency.
Anything tagged **[server]** should also be reflected in the main `ROADMAP.md`
when scheduled.

A claim in "Current state" is a claim about verified behaviour. Compiling,
opening a socket or sending bytes is not evidence that a flow works; the
evidence is a test that fails when the behaviour is removed.

## Why this client exists

Gameplay rules the server enforces were re-implemented independently in the web
client. Two implementations of one rule in two languages must agree exactly, or
the player is snapped backwards mid-step — a bug that proved very hard to
diagnose from either side alone.

`crates/ao-core` holds those rules once, as pure code with no platform or
framework coupling, so the same logic can compile into the wasm client and into
the Rustler NIF the server already loads. Today it carries tile walkability, the
server's speed-hack accumulator, the map pack decoder and the wire protocol —
31 tests, all runnable natively without a browser.

## Current state

Working: real map data from the server's `AOMP` pack, all four map layers drawn
with real artwork, static NPCs and ground objects, a character with body/head
composition, held-key movement gated by the server's walk formula, a WebSocket
transport, a walk encoder and a `pos_update` decoder.

Round-trip latency is measured on the game socket itself (ping 900 / pong 204)
and shown in the status row beside FPS and the online count. Verified against a
real listener over `:gen_tcp`, including before login completes.

The session still does **not** log in end to end, but no longer for the reason
recorded here previously. The packet names were wrong — the client called 74
`LOGIN_EXISTING_CHAR` when the server defines 73 as `login_existing_char` and
74 as `login_new_char` — and the creation fields at the tail of 74 were
described as padding the server ignores, when in fact they decide the
character it creates. Both are fixed, both encoders now exist, and their exact
bytes are asserted against the server's own decoder by a shared fixture
(`apps/ao_protocol/test/client_login_layout_test.exs`).

What blocks login now is the response, not the request. After a successful WS
login the server sends `world_pack_signature` (203) and `session_token` (200);
the client's decoder recognises only `pos_update` (31) and `pong` (204). An
unknown id cannot be skipped, because packet lengths are not on the wire, so
the connection is failed rather than desynchronised. Handling those two frames
is Phase 1 work.

"Socket opened and bytes were sent" is not a successful session and must not be
reported as one again.

The trimmed build measures **19.2 MB raw and 5.5 MB gzip**. Transfer-size gates
must use the compressed artifact players actually download; raw size remains a
secondary diagnostic.

## Phase 0: Platform foundation

Make the prototype honest and establish boundaries while the platform-specific
surface is still small.

1. ~~**[client]** Correct the packet-74 name and current-state reporting. Keep distinct
   encoders for new-character login (74) and token-based existing-character
   login (73).~~ **Done.** Both encoders exist and carry the creation fields the
   server actually reads; a shared byte fixture asserts them against the
   server's decoder in both languages.
2. ~~**[client]** Replace hard-coded asset origin, gateway URL, character name, password and
   client hash with runtime configuration. Production derives HTTPS/WSS
   endpoints from the page origin; development overrides them explicitly.~~
   **Done.** Layered as query string > page meta tags > page origin, with
   `AO_*` environment variables natively. With nothing configured the client
   reports what is missing instead of connecting; with no credentials it does
   not log in, rather than creating a character for whoever opened the page.
   `./build.sh` fails if any value configured in `web/index.html` is found
   inside the built artifact.
3. **[client]** Introduce Bevy application states:
   `Boot -> Authenticate -> SelectCharacter -> LoadWorld -> Playing -> Handoff
   -> Reconnecting`. Replace boolean lifecycle controls such as
   `MapLoadReported`, `CharacterDrawn`, `SceneDirty`, `ScenePainted`,
   `DrawnTiles` and `DrawnEntities` with scoped state, resources and events.

   **Partly done, and the list of booleans needs correcting.** `AppState`
   exists with `Boot -> LoadingWorld -> Playing`, and gameplay systems are
   scoped to `Playing`. `MapLoadReported` is gone: it was doing two jobs at
   once — apply-once and log-once — and running the system only while a load
   is outstanding replaces both.

   The remaining four are not lifecycle booleans and should not become states.
   `DrawnTiles` and `DrawnEntities` are memos of what has already been spawned,
   which is what makes painting incremental as texture sheets stream in;
   `SceneDirty` and `CharacterDrawn` are redraw triggers. Turning any of them
   into application states would conflate "where the client is" with "what has
   been drawn" and would break incremental painting. They should become change
   detection or events, which is a different task from this one.

   `Authenticate`, `SelectCharacter`, `Handoff` and `Reconnecting` are also not
   added yet, deliberately: none has a transition to make until real login
   exists (Phase 1), and a state nothing ever enters is a comment that goes
   stale rather than a state machine.

   Note the split this establishes: `AppState` tracks the client's own
   startup, and `Session` tracks the connection. The world is playable without
   a session — map data arrives over HTTP and a client that failed to log in
   still renders and walks. Gating gameplay on the socket would make a login
   failure look like a dead renderer.
4. **[client]** Define platform services for HTTP, WebSocket transport, persistent cache,
   auth/token storage, audio, clipboard, IME/text composition, fullscreen and
   external links. Provide browser and native implementations rather than
   spreading `cfg(wasm32)` through gameplay systems.
5. **[client]** Make Bevy the single owner and renderer of every user-facing application
   screen:
   product shell, authentication, character creation/selection, rankings, HUD,
   chat, panels, settings and diagnostics. Thin browser/native adapters may
   expose platform APIs to Bevy, but must not create a second DOM/React UI tree
   or a second source of UI state.
6. **[client]** Fix the native build and move pure parsers/rules into `ao-core`, so both
   targets compile and their platform-independent tests always run. Native HTTP
   and WebSocket stubs must become real implementations before native can be
   called supported.
7. **[server]** Serve the client and runtime configuration from the game origin. The current
   separate-port/CORS setup remains a development option only.
8. **[client]** Keep the trimmed Bevy feature set. Record 5.5 MB gzip as the initial WASM
   transfer baseline and fail CI on an unexplained regression greater than 5%;
   any intentional budget increase must name the feature that caused it.
9. **[client]** Establish a fixed browser/device/network benchmark profile and record
   numeric ceilings for time to first interactive world, p95 frame time, draw
   calls, WASM heap, estimated GPU memory and reconnect/handoff latency before
   the phases that consume those budgets begin.
10. **[client]** Probe capabilities before launching: WebGL2, maximum texture size, device
   pixel ratio, audio support, persistent-storage availability/quota and memory
   pressure indicators where the platform exposes them. Select a documented
   low-resource profile or show an actionable unsupported-device result instead
   of failing inside Bevy startup.

Exit criteria:

- `./build.sh check` passes for WASM and native, including `ao-client` and
  `ao-core` tests.
- No credentials or production hosts are compiled into the client.
- All application UI is Bevy-owned on browser and native; platform adapters expose
  capabilities without creating a parallel application or state tree.
- Lifecycle transitions are represented by the state machine, not inferred
  from unrelated booleans.
- The compressed WASM size is produced and checked by CI.
- Runtime performance budgets have a reproducible measurement command and
  stored baseline, not an informal target.
- Supported and deliberately unsupported capability profiles produce stable,
  testable startup outcomes; the diagnostic report contains no identifying data.

## Phase 1: Protocol and real authentication

The first goal is one truthful, testable session—not broad gameplay.

### Step zero: protocol governance

`session_route_manifest.ex` classifies 202 packets with `vb6_ref` and
`parity_status`. Decide and document the parity story before introducing a
modern wire envelope. A length-framed WS protocol is an
`:intentional_divergence`, requires manifest entries and byte-level fixtures,
and must leave the legacy TCP/WS path working.

1. **[server + client]** Negotiate a versioned, length-framed WebSocket protocol before
   login, preferably through a WebSocket subprotocol/capability. Preserve the
   existing AO packet bytes inside the frame. Modern clients can then skip an
   unknown packet safely; legacy clients continue using the unframed stream.
2. **[server + client]** Price the schema prerequisite honestly. There is no canonical
   protocol schema today: the Elixir encoder/decoder is the source of truth.
   Choose one governed path:
   - author a machine-readable schema and prove it against Elixir golden bytes;
   - build an Elixir-source extractor and still verify every result; or
   - keep manual Rust codecs with paired byte fixtures.
   Code generation begins only after one of those sources is trustworthy.
3. **[client]** Decode packet 203 and validate the advertised map-pack
   version/hash before entering the world. Then cover the complete login
   bootstrap, explicit login success, and every login/error outcome.
4. **[client]** Build the Bevy product shell now, not in the later polish phase. Preserve
   the existing web client's registration, login/logout, character creation with
   server-provided options and sprite preview, character selection, launch and
   rankings flows. Use `/api/auth/login`, `/api/characters`,
   `/api/meta/character-options` and the browser launch endpoint; enter the game
   with packet 73's character ID and session token. Never send the account
   password over the game protocol.
5. **[client]** Add protocol breadth, with a byte fixture per packet:
   - character create / move / remove / change
   - chat and structured console messages
   - stats, inventory and spells
   - ground object create/remove
   - weather and map change
   - session token, intervals, build/version and errors
6. **[client]** Implement connection lifecycle: heartbeat/RTT, meaningful close reasons,
   exponential reconnect backoff and an explicit transition to `Playing` only
   after the authoritative bootstrap completes.
7. **[client]** Add a redacted packet-trace recorder and deterministic replay harness. A
   trace contains inbound frames, outbound commands, timestamps, application
   state transitions and build/world versions, but never passwords, launch
   tokens or account cookies. Replays run without a live socket and can inject
   fragmentation, delay and disconnect boundaries.
8. **[client]** Bound network work and memory in both directions. Limit queued inbound
   frames/decoded packets by bytes and count, process them with a per-frame time
   or packet budget, observe WebSocket `bufferedAmount`, and cap pending outbound
   commands. Overflow must disconnect/resynchronise explicitly—never grow an
   unbounded `Vec`, silently discard authoritative state or freeze one render
   frame while draining a burst.
9. **[client]** Preserve browser product navigation semantics while Bevy owns the screens:
   stable routes for lobby, rankings, character creation and play; reloadable
   deep links; browser back/forward integration; and deterministic logout or
   invalid-session recovery. Native builds expose the same flows through Bevy
   navigation without pretending to have browser history.
10. **[client]** Classify bootstrap and access failures into actionable Bevy states:
    credentials rejected, banned, muted, server full, maintenance, token expired,
    stale/incompatible world data, asset-index failure and scene-preload failure.
    Retry assets, retry world data, reconnect and forget-session are independent
    actions and never require a page reload as the only recovery path.

Exit criteria:

- A real account selects an existing character, decodes packet 203, completes
  bootstrap and reaches `Playing` using packet 73.
- Registration, character creation/preview, selection, launch, rankings,
  logout, deep links and browser history work through Bevy-owned screens.
- Packet 74 is used only for the deliberate character-creation flow.
- Every normal-play packet is decoded, or safely ignored only inside the
  negotiated framed protocol.
- Elixir and Rust fixtures prove identical packet bytes, including fragmented
  and concatenated delivery.
- Framing and packet decoders survive fuzz/property tests for truncation,
  hostile lengths and arbitrary unknown packet IDs without panic or desync.
- A recorded login/bootstrap/gameplay trace replays to the same client-world
  state deterministically, with secrets demonstrably redacted.
- Sustained packet bursts and a deliberately stalled render loop stay within the
  queue budgets, preserve critical ordering and recover through a fresh snapshot
  after overflow.
- Each classified bootstrap/access failure exposes the correct recovery action
  without leaking credentials or leaving an invisible session alive.

## Phase 2: Bevy UI system and interaction prototype

Define how Argentum looks, behaves and exchanges typed state before wiring
dozens of packet handlers directly to widgets. The direction is recognisably
classic AO—dense, tactile and readable—modernised without becoming a generic
dashboard. This phase can proceed beside Phase 1 once Phase 0's Bevy/platform
boundary exists.

1. **[client]** Define transport-independent view models and command intents for at least
   `PlayerVitals`, `InventoryState`, `EquipmentState`, `SpellbookState`,
   `HotbarState`, `TargetState`, `ChatState`, `SkillsState`, `ProgressionState`,
   `SafetyState` and `ServiceState`. Bevy presentation reads these models and
   emits intents; it never parses packets or calls a socket. Server feedback
   crosses this boundary as stable semantic keys plus typed parameters, not
   presentation-ready Spanish strings where the protocol can avoid them.
2. **[client]** Supply deterministic fixture adapters first and an authoritative-session
   adapter in Phase 3. Fixtures cover populated, empty, loading, disabled,
   rejected, disconnected, dead/ghost and malformed-data states without
   pretending that mock interactions are live gameplay.
3. **[client/design]** Define the information architecture and persistent HUD regions: world
   viewport, vitals, character/progression state, inventory/equipment, hotbar,
   chat, minimap, notifications and contextual actions. Specify what is always
   visible and what belongs in a window, tooltip or temporary overlay.
4. **[client/design]** Publish design tokens for typography, licensed fonts, colors, borders,
   spacing, icon sizes, focus states, disabled/locked states, rarity/status
   semantics and pixel-art scaling. Every token remains legible over bright and
   dark maps and in supported color-sensitive modes.
5. **[client/design]** Build a reusable Bevy component catalogue covering buttons, tabs,
   slots, numeric status bars, lists, text/password fields, tooltips, context
   menus, dialogs, notifications, drag ghosts, progress/cooldown indicators and
   hotkey prompts. Components have one event, focus and state model across WASM
   and native.
6. **[client/design]** Implement the Bevy window manager: open/close/focus, z-order, modal
   behavior, moving, snapping/docking, optional resizing, remembered positions,
   Escape handling and restoration when the available viewport changes.
7. **[client/design]** Specify interaction rules once: drag/drop and cancellation, quantity
   splitting, click/double-click/right-click, tooltip timing, target modes,
   cooldown/rejection feedback, keyboard shortcuts and suppression of world
   commands while chat, text/password fields or modals own input.
8. **[client/design]** Prototype distinct peaceful/exploration and combat layouts, plus
   responsive breakpoints for 720p, 1080p, ultrawide and small-laptop windows.
   Include UI scaling, integer-scaled world presentation and a constrained
   layout for insufficient space.
9. **[client/design]** Cover the playable HUD explicitly: HP, mana, stamina, hunger, thirst,
   XP/level and skills; inventory/equipment; spellbook, requirements, hotbar and
   cooldowns; current target; personal/party safe mode; chat channels; and
   navigation/dead-state restrictions.
10. **[client/design]** Design onboarding and contextual guidance for movement, interaction,
    combat, inventory, spells, death and recovery. Include empty, loading,
    disabled, rejected, disconnected and maintenance states—not only populated
    happy-path screens.
11. **[client/design]** Produce an interactive Bevy prototype/component gallery using
    representative real game data and long ES/EN/PT strings. Core workflows are
    testable from typed fixtures without a finished server implementation.
12. **[client/design]** Run task-based usability sessions with veteran AO players and
    newcomers. Measure whether they can find health/mana, use/equip an item,
    cast a spell, trade, bank, change chat channel and recover from a rejected
    action; record findings and revise the prototype.
13. **[client/design]** Keep reference screenshots, fixture states and interaction
    specifications versioned beside the client so implementation, component
    gallery and golden tests share the same source of truth.

`research/argentumunited/README.md` documents a working AO client's layout and
eight specific ideas worth taking, including numbers rendered inside status bars
and locked inventory slots shown rather than hidden.

Exit criteria:

- Tokens, component states, window behavior and platform-service boundaries are
  explicit enough that two implementers produce compatible Bevy controls.
- The fixture-backed Bevy prototype completes representative gameplay tasks at
  all target resolutions without clipped critical information or fractional
  world scaling.
- Keyboard/focus traversal, text composition and modal/chat ownership work in
  browser and native builds; UI interaction never leaks an unintended world
  command.
- Every prototype state is driven through the same typed models and intents the
  live adapter will use; no fixture-only widget API enters production.
- Veteran/newcomer findings, resulting changes and remaining tradeoffs are
  recorded with the approved reference screens.

## Phase 3: Authoritative client state and live world

Replace the static demonstration with server-owned state and adapt protocol
events into Phase 2's typed UI models before polishing the presentation.

1. **[client]** Take the initial map and position from the login bootstrap. Remove
   `INITIAL_MAP` and the demo player's independent coordinates.
2. **[client]** Represent players, NPCs and ground objects as live ECS entities keyed by
   authoritative identity. Map-pack NPC/object records may guide asset preloads,
   but must never be rendered as proof that the entity currently exists.
3. **[client]** Apply character/object create, move, change and remove messages idempotently.
   Unknown removes, duplicate creates and late packets must not leak or duplicate
   entities.
4. **[client]** Separate fixed-timestep movement intent, local prediction, authoritative
   reconciliation and remote-entity interpolation. Reset `WalkGate` on login,
   reconnect and map handoff; never treat shared client code as an anti-cheat
   boundary—the server remains authoritative because WASM is user-controlled.
5. **[server + client]** Define reconnect/resynchronisation semantics. A reconnect receives a
   fresh snapshot/epoch, discards stale entities and inputs, and does not blindly
   replay movement accumulated while disconnected or while the tab was asleep.
6. **[client]** Split the current monolithic world systems into transport/session, world
   model, presentation and UI layers before adding more packet handlers. Raw
   packet types never become Bevy widget state.
7. **[client]** Add a feature/build-gated Bevy developer overlay with redacted packet events,
   authoritative versus predicted position, correction and movement-cadence
   counters, tile inspection, renderer budgets and build/world identifiers.
   Release builds keep the underlying bounded metrics without exposing private
   operator tools to players.

Exit criteria:

- A player can log in, see other players and NPCs move, see objects appear and
  disappear, chat, and survive a brief disconnect without stale entities.
- Local prediction remains responsive under injected latency and converges to
  the server without oscillation.
- Entity churn and reconnect soak tests leave no duplicate or leaked entities.
- The fixture and live adapters produce equivalent typed view-model snapshots
  for the same recorded trace.

## Phase 4: Core playable HUD vertical slice

Decoding packets and drawing fixture-backed widgets is not gameplay. Connect the
first complete set of Bevy workflows to authoritative server state before
expanding breadth.

1. **[client]** Wire Phase 3's authoritative adapters into Phase 2's HUD and command
   intents. Vitals, XP/level, skills, selected target, safety state, inventory,
   equipment, spellbook, hotbar and chat update without widgets reading packets.
2. **[client]** Implement inventory/equipment end to end: select, move, use, drop and equip
   every supported layer; quantities, locked slots, disabled/dead states and
   authoritative rollback on rejection.
3. **[client]** Implement magic end to end: spell selection and persistent hotbar, target
   modes, cast/cancel, cooldown and interval feedback, mana/stamina/skill
   requirements, staff/equipment masks, land/water restrictions, area radius,
   maximum target level and whether the spell works on dead targets.
4. **[client]** Implement targeting and world interaction: select characters, NPCs, objects
   or tiles; face targets; use the world; pick up/drop items; and preserve server
   range, visibility and navigation rules.
5. **[client]** Implement combat: attack/weapon use, damage/block/status feedback, personal
   safe mode, party safe mode, safe-zone restrictions, death/ghost command
   gating and server rejection/correction. Full resurrection/recovery workflows
   remain in Phase 5.
6. **[client]** Implement public, private, party, clan and faction chat with channel filters,
   bubbles and explicit server mute/moderation feedback. Input focus suppresses
   movement, combat and hotkeys, and Unicode limits are applied consistently.
7. **[client]** Keep typed fixtures for component and failure-state tests, but make every
   exit criterion below exercise the real session/server path as well.

Exit criteria:

- One player can log in, fight, loot, move/equip/use/drop items, select and cast
  constrained spells, assign/use hotkeys, change chat channels and toggle the
  applicable safety modes through Bevy UI.
- Inventory, combat, spell and chat flows each cover success, rejection,
  interruption, death restrictions and reconnect where applicable.
- The same recorded flow drives equivalent typed state in replay and live modes;
  no Bevy UI system reads raw packet bytes or owns authoritative gameplay rules.
- Existing web-client session/spellbook, status-overlay and relevant UI-parity
  browser tests have Rust-client equivalents or an explicit retirement record.

## Phase 5: Remaining gameplay parity

Complete the AO workflows outside the core combat loop and prove feature
migration rather than equating packet coverage with a finished client.

1. **[client]** NPC dialogue and services: conversation, quests where supported, training,
   healing, resurrection and other contextual service interactions.
2. **[client]** Economy: NPC commerce, bank items/gold, player trade and every confirmation,
   quantity, cancellation, insufficient-funds and disconnect path.
3. **[client]** Social and faction workflows: party and clan membership/leadership, invites,
   rosters, clan creation, block/mute/report and moderation feedback.
4. **[client]** Finish death/resurrection and recovery flows, including ghost presentation,
   allowed commands, lost/retained state and authoritative return to play.
5. **[client]** Cover travel restrictions, hunger/thirst, rest, meditation, navigation and
   other state that changes which commands the client may offer. Client gating
   improves feedback but grants no trust; the server remains authoritative.
6. **[client]** Preserve the old client's service/status command surface where the server
   supports it: help, MOTD, uptime, information, rewards, account state,
   position/stats/skills resynchronisation and punishment lookup with
   permission-aware feedback.
7. **[server + client]** Govern versioned gameplay metadata used for presentation—spell
   definitions and requirements, XP thresholds, object/NPC definitions and
   faction labels—so the Bevy client detects incompatible/stale data rather than
   silently disagreeing with server rules.
8. **[client + server]** Maintain a parity matrix mapping each supported workflow to client
   commands, server packets, Rust handlers, Bevy UI surface, VB6/TypeScript
   reference and an end-to-end test. "Packet decoded" alone is not a completed
   row.

Exit criteria:

- A scripted character completes NPC service, commerce/bank, player trade,
  party/clan, death/resurrection and progression/service-command flows end to
  end.
- Each workflow tests success, server rejection, interruption and reconnect.
- The parity matrix has no unexplained gap for features exposed by Bevy UI and
  detects incompatible gameplay metadata before entering `Playing`.
- Packet-trace replay reproduces at least one regression from every major
  workflow without a live server.
- Every existing TypeScript/Pixi product/gameplay E2E test passes against the
  Rust client, has an equivalent stronger test, or is intentionally retired with
  its reason and replacement coverage recorded.

## Phase 6: World fidelity and audio

The authoritative world should now look and sound like Argentum.

1. **[client]** Walk animation. Animated grhs resolve to frame 0; bodies carry multi-frame
   walk cycles with a `velocidad` the renderer currently ignores.
2. **[client]** Equipment layers: weapon, shield, helmet, cart and backpack, composed over
   the body in the correct order.
3. **[client]** Depth sorting. Characters draw in spawn order, so one standing behind another
   can occlude it. Per-row containers avoid a full per-frame sort—the approach
   `research/argentumunited` documents.
4. **[server + client]** Roof hiding. Layer 4 draws unconditionally. Ship triggers in the map
   format and implement the `trigger == 1` rule for the player and both clients.
5. **[client]** Tile streaming that keeps up with long-distance movement, requests missing
   sheets on demand and despawns material outside the retained window.
6. **[client]** Tree fading, name labels, chat bubbles, combat text, weather, day/night and FX.
7. **[client]** Music and positional sound with separate volume controls. Browser audio must
   unlock from a user gesture, suspend cleanly in a background tab and resume
   without overlapping tracks.
8. **[client]** Profile the tile/entity renderer against the Phase 0 draw-call and frame-time
   ceilings. Introduce chunked tile meshes, sprite batching or instancing only
   where measurements require them; keep culling and entity cleanup observable.

Exit criteria:

- Walking, turning and fighting look like the VB6 client beside it.
- Entering a building reveals its interior.
- A 30-minute movement/combat capture stays inside the frame-time, entity and
  texture-memory budgets.
- Audio starts only after consent/gesture and respects mute/background state.
- Golden screenshot tests cover representative outdoor, indoor, crowded and
  equipment-layer scenes at supported scale factors.

## Phase 7: Versioned assets and persistent cache

This precedes seamless transitions: a transition cannot be hitch-free if the
client first downloads or retains an unbounded 58.8 MB world pack.

1. **[server + client]** Replace the monolithic sequential pack with per-map files or a
   range-indexed format. Publish a small index first so one map can be fetched
   without materialising the whole pack.
2. **[server + client]** Publish a content-hashed manifest covering maps, indices, sprite
   sheets and audio. Validate packet 203 against it and invalidate cache entries
   atomically when versions change; never mix resources from two world builds.
3. **[client]** Implement the persistent-cache platform service: Cache Storage/IndexedDB in
   the browser and an application cache directory on native. Storage denial,
   quota exhaustion and browser eviction fall back safely to network/memory.
4. **[server]** Serve content-addressed resources with immutable cache headers and range
   support where the chosen pack format requires it.
5. **[client]** Track compressed cache bytes, decoded-map bytes and estimated RGBA/GPU bytes
   separately. Texture eviction uses bytes, not entry count; compressed PNG size
   is not a proxy for GPU allocation.
6. **[client]** Build a map-to-assets dependency index and preload likely exits within a
   separate megabyte allowance. Speculation stops before consuming the headroom
   reserved for the next authoritative world.
7. **[client]** Cache the app shell/service worker, while remaining honest that gameplay
   still requires a live server. Install/activate a new worker atomically so an
   open tab cannot combine an old WASM client with a partially updated shell.
8. **[client]** Prepare assets within the frame budget. Decode off the main gameplay loop
   where the platform permits, spread GPU texture uploads across frames, cancel
   obsolete speculative work and cap uploads/decoded bytes per frame. A cache
   hit is not allowed to become a visible decode/upload hitch.
9. **[client]** Reject malformed or hostile resources with explicit size/dimension/count
   limits. Fuzz the map pack, index and image-metadata parsers; integrity hashes
   do not replace defensive parsing.

Exit criteria:

- Loading one map does not download or retain the full 58.8 MB pack.
- A warm visit does not refetch unchanged maps or sprite sheets.
- Corrupt, partial and mixed-version caches recover automatically.
- CI reports cold/warm transferred bytes, cache hit rate, WASM heap and estimated
  GPU texture memory on a fixed browser profile.
- A fully cached destination can be decoded and uploaded without exceeding the
  configured per-frame budget or producing a long task.

## Phase 8: Seamless map transitions

The player never sees a loading screen when changing maps. Requires coordinated
server and client work; see the design discussion for full detail. Treat the
remaining effort as roughly **40% server / 60% client**: the server work changes
a core map/session API and the compatibility path, rather than merely adding two
wire packets.

Server:

1. **[server]** `map_handoff_begin` / `map_handoff_end` framing a complete, ordered
   destination snapshot.
2. **[server]** `MapServer.enter/3` returns a structured snapshot instead of sending NPC
   packets out-of-band. It currently does `send(caller_pid, {:send_raw, raw})`
   (`arena/map/map_server.ex:1219`), which is exactly why an authoritative end
   marker is not possible today.
3. **[server]** A session-owned `world_epoch`, incremented per transfer. Char indices are
   map-local and reused, so entities must be keyed `(epoch, char_index)` and
   anything from an earlier epoch discarded.
4. **[server]** Failure path: keep the player on the source map, send `map_handoff_failed`,
   correct their position, resume input.

**Before any of that**, decide the parity story. `session_route_manifest.ex`
classifies 202 packets with a `vb6_ref` and a `parity_status`. These new packets
have no VB6 ancestor and need `:intentional_divergence` entries plus fixtures,
or the manifest test will reject them. This is step zero, not an afterthought.

Also choose the compatibility migration before changing `MapServer.enter/3`:
first make it return the structured snapshot through a session adapter that can
still emit the existing TypeScript sequence. Only emit the framed sequence to a
client that declares the capability, or teach the TypeScript decoder the new
fixed-size frames first. `change_map` compatibility by itself does not protect
the shared session path from the `enter/3` API change.

Two further constraints the design must state explicitly:

- The critical queue is FIFO, but normal snapshot members such as position and
  stats are ordinarily coalesced and therefore flush after critical packets.
  The handoff must be one ordered batch, or every packet from `begin` through
  `end` must be forced through the critical FIFO by the session process. Add a
  backpressure test that proves `begin < every snapshot packet < end`; merely
  marking the boundary packets critical is insufficient.
- The TypeScript client keeps running throughout. Legacy `change_map` covers the
  wire, but the `enter/3` shape change touches the session path both clients use.
- `Movement.do_move/8` deliberately emits no `pos_update` when
  `transferring?` is true. The client therefore receives no authoritative
  position confirmation during the current transfer window, another reason
  bootstrap completion cannot be inferred from packet timing.

Client:

5. **[client]** `ActiveWorld` / `PendingWorld`, committing the swap in one ordered system
   only when assets and snapshot are both ready.
6. **[client]** `MapSceneRoot` per map so a scene is switched by toggling one root rather
   than replacing thousands of entities.
7. **[client]** Key every map-scoped entity by `(world_epoch, authoritative_id)` and reject
   queued envelopes whose source map/epoch is no longer active.
8. **[client]** Pause gameplay input at `begin`, clear held keys and `WalkGate`, retain the
   old rendered world, then resume only after the atomic destination commit.
9. **[client]** Use Phase 7's cache and exit dependency index to prepare destination maps and
   textures without re-downloading or re-uploading shared resources.

Exit criteria:

- With destination loading deliberately delayed by two seconds, the old world
  stays rendered, input is paused, and the destination appears atomically — no
  black frame, no loading screen, no duplicated character, no stale entity.
  This needs a delay-injection hook to be testable at all.
- Under forced egress backpressure, packet capture proves that no handoff member
  is dropped, coalesced, or delivered outside its `begin`/`end` boundaries.
- Browser telemetry reports decoded-map, speculative-preload and estimated
  GPU-texture bytes separately and stays within Phase 7's ceilings.
- 1,000 repeated transitions leave no leaked entities or textures.
- Destination failure, disconnect mid-transfer, stale source movement after
  handoff, and transitions under backpressure all behave.

## Phase 9: Complete Bevy UI, localization and accessibility

Polish and complete Phase 2's Bevy design system after the Phase 4 and 5
workflows are authoritative. There is one Bevy UI on WASM and native; platform
services provide text composition, clipboard, storage and window capabilities
without creating parallel DOM panels.

1. **[client]** Complete and polish the core HUD, inventory/equipment, spellbook/hotbar,
   skills/progression, target, chat and minimap surfaces delivered in Phase 4.
2. **[client]** Complete NPC services, trade, bank, commerce, party, clan, faction,
   death/recovery and service/status panels delivered in Phase 5.
3. **[client]** Complete the stable-key localization system introduced with the Phase 2
   models. Ship Spanish, English and Portuguese with fallback tests; avoid
   embedding server-authored Spanish sentences where a semantic event plus
   parameters will work.
4. **[client]** Add settings for remappable keys, UI scale, chat size, master/music/effects
   volume, reduced motion and color-sensitive effects. Persist them per account
   or device as appropriate.
5. **[client]** Support keyboard-only navigation and expose the Bevy focus/semantics tree to
   platform accessibility APIs for authentication, chat, forms and gameplay
   controls. Add gamepad support after keyboard parity; touch/mobile remains
   research until the desktop/browser interaction model is solid.
6. **[client]** Show truthful Bevy-owned staged boot progress—client, manifest,
   authentication, map, assets and snapshot—with actionable retry/error states.
   The host page may show only a minimal pre-WASM fallback and replaces it after
   a Rust readiness signal, not merely because the module instantiated.
7. **[client]** Implement responsive integer scaling for the pixel-art viewport. Define
   behavior for small windows, ultrawide displays, browser zoom, device-pixel
   ratios, orientation changes and OS scaling without fractional camera shimmer
   or distorted aspect ratio.
8. **[client]** Support windowed, maximized and fullscreen modes with a reliable return path,
   persisted preference and browser-permission failure handling. Recompute the
   viewport on every resize/fullscreen/DPI event without moving the player,
   changing world visibility rules or losing focused text input.
9. **[client]** Ship licensed fonts with explicit ES/EN/PT and game-symbol coverage. Treat
   user text as Unicode grapheme clusters for cursor movement, selection,
   truncation and length limits; define an emoji policy and neutralise malicious
   bidirectional/control characters without corrupting legitimate accents or
   copy/paste.
10. **[client]** Version persistent settings and UI/cache metadata. Each release supplies a
    tested forward migration; unknown, corrupt or newer schemas fall back safely
    without retaining passwords or preventing startup. Downgrade behavior is
    explicit rather than accidental.

Exit criteria:

- Every supported flow is usable in ES/EN/PT without clipped text or missing
  fallback keys.
- Authentication, character selection and chat work with keyboard navigation
  and IME input, and their Bevy semantics are exposed to supported screen-reader
  APIs without invisible duplicate controls.
- Reloading preserves user settings without preserving passwords.
- Automated resize tests cover supported aspect ratios and device-pixel ratios;
  screenshots remain pixel-aligned in windowed and fullscreen modes.
- Names and chat round-trip correctly through grapheme, font and bidi tests in
  all supported languages.
- Settings fixtures from every supported prior schema migrate deterministically;
  corrupt/newer fixtures recover with documented defaults.

## Phase 10: Production hardening and release

1. **[client]** Handle browser lifecycle deliberately: focus loss clears held input, hidden
   tabs suspend expensive presentation, long sleeps trigger resynchronisation,
   stale callbacks from replaced sockets are ignored, and WebGL context loss
   restores resources or shows a recoverable error.
2. **[client + server]** Require HTTPS/WSS in production, short-lived launch tokens and
   appropriate CSP/origin controls. The client is untrusted: asset encryption,
   a client hash and browser-side checks are not security boundaries. Browser
   TLS uses the browser trust store; do not promise application certificate
   pinning for WASM.
   Render player/chat content as text, never trusted HTML; define CSRF/session
   handling for REST calls, maximum frame/decompressed-resource sizes, token
   expiry, explicit logout and credential-free diagnostics.
3. **[client]** Add structured, privacy-conscious diagnostics: build/world version, time to
   first interactive world, FPS/frame time, RTT, reconnects, handoff latency,
   cache hit rate and memory budgets. Never log credentials or launch tokens.
4. **[client]** Run Playwright browser/server integration tests from earlier phases in
   Chromium, Firefox and Safari/WebKit. Include throttled cold boot, fragmented
   frames, disconnects, cache eviction, context loss and the two-second handoff
   delay.
5. **[client]** Implement native platform services and package signed/versioned builds for
   Linux, macOS and Windows, with partial/content-addressed updates.
6. **[client]** Display build identification in-client, automate reproducible release
   artifacts and retain a tested rollback path.
7. **[server + client]** Define rolling-upgrade compatibility. Negotiate minimum/maximum
   supported protocol and content builds, show a recoverable upgrade-required
   screen, and test old-client/new-server plus new-client/old-server during every
   rollout. Service-worker activation and rollback must preserve one coherent
   client/manifest pair.
8. **[server + client]** Define multi-tab/session ownership. Launching the same character in
   another tab or device must produce a deterministic handoff or rejection,
   never two active authorities, token leakage or an unexplained disconnect.
9. **[server + client]** Add versioned runtime feature flags with safe defaults and cached
   fallback behavior. Roll out or disable protocol v2, seamless handoff,
   speculative preloading, shaders/audio and optional telemetry independently.
   A flag may reduce optional functionality but must never weaken server
   authority, authentication or protocol validation.
10. **[client]** Retain private debug/symbol artifacts for every stripped WASM/native build
    and make crash reports resolvable by build ID. Let players copy a redacted
    support bundle containing capabilities, recent state transitions, error
    codes and resource/protocol versions—never tokens, account data or chat.
11. **[server + client]** Model maintenance and capacity as explicit states: scheduled-restart
    warning/countdown, draining, maintenance, server-full/queue position and
    retry eligibility. Preserve or close sessions deliberately so operational
    work appears as a useful message rather than a generic socket failure.
12. **[client]** Gate releases on dependency vulnerability/license auditing, an SBOM,
    reproducible dependency locks, third-party notices, asset/font/music
    provenance and AGPL distribution obligations. A resource without confirmed
    redistribution rights does not enter a release artifact.

Exit criteria:

- A player can download a desktop build or open the browser build and play the
  same game.
- A repeat visit starts without refetching unchanged assets.
- Supported browsers pass the same login, gameplay, reconnect and handoff suite.
- Release dashboards expose size, boot, frame, network and memory regressions
  before rollout.
- Rolling upgrade/rollback and duplicate-session tests pass without corrupting
  character state or mixing client/resource versions.
- Packet floods, unavailable flag configuration, simulated crashes, maintenance
  drain and server-full responses all reach their bounded/recoverable UI states.
- A release publishes its SBOM/notices and archives symbol artifacts keyed by
  the exact build ID shown in the client.

## Phase 11: Research and experiments

Research produces measured proposals, not promises slipped into an active
phase. Promote an idea into the roadmap only after documenting player value,
protocol/server impact, memory/network cost, abuse cases and a falsifiable test.

Candidates:

- optional automatic chat translation, including consent, privacy, moderation,
  latency, provider cost and whether it belongs in a subscription;
- touch/mobile controls and small-screen HUDs;
- WebGPU, WASM threads and advanced shaders, justified by profiling rather than
  novelty;
- multi-region worlds or explicit continent travel while preserving character
  authority and market consistency;
- dynamic zone instancing and population-aware placement;
- variable-sized maps, coordinates wider than `u8`, chunks and truly continuous
  geometry beyond seamless logical-map transitions;
- deeper positional audio and map-specific music;
- further ideas from Argentum United, the AO wiki, Patreon/community feedback
  and live player telemetry.

Exit criteria:

- Each accepted experiment graduates into a separately estimated phase with an
  owner, compatibility plan, budgets and acceptance tests.
- Rejected experiments retain their evidence so the same question is not
  repeatedly reopened without new information.

## Server work this client needs, in one place

Everything tagged **[server]** above, ordered by when it blocks:

| Phase | Change | Why |
| --- | --- | --- |
| 0 | Serve `client-rs` from the game origin | Removes the dev-only CORS arrangement |
| 1 | Parity decision and negotiated length-framed WS protocol | Lets modern clients skip unknown packets without changing legacy TCP/WS |
| 1 | Canonical schema/extractor decision plus cross-language fixtures | Code generation is unsafe until a source is proven against Elixir bytes |
| 3 | Reconnect/resynchronisation snapshot contract | Prevents stale entities and replayed inputs after transport loss or tab sleep |
| 4 | Core gameplay workflow end-to-end fixtures | Proves inventory, spell, combat, safety and chat success/rejection paths |
| 5 | Remaining-workflow parity matrix and fixtures | Proves services, economy, social, recovery and progression—not only individual packets |
| 5 | Versioned gameplay-metadata contract | Prevents spell, XP, object/NPC and faction presentation from drifting from the server |
| 6 | Emit `triggers` in `encode_map` | Roof hiding is impossible without them; the TypeScript client needs this too |
| 7 | Indexed/per-map asset format, hashes, range support and immutable headers | Avoids downloading/retaining 58.8 MB and enables safe persistent caching |
| 8 | Parity entries for the new handoff packets | Unclassified intentional divergences fail the protocol gate |
| 8 | `map_handoff_begin` / `end` + fixtures | Explicit snapshot boundary |
| 8 | `MapServer.enter/3` returns a snapshot | NPCs currently sent out-of-band, so no end marker is authoritative |
| 8 | Session `world_epoch` | Char indices are map-local and reused |
| 8 | `map_handoff_failed` | Destination refusal must not strand the player |
| 8 | Ordered critical snapshot batch | Boundary packets alone cannot contain normally coalesced members |
| 10 | HTTPS/WSS, launch-token and origin policy | Makes the browser deployment boundary explicit and testable |
| 10 | Protocol/build compatibility and upgrade-required response | Keeps cached old clients safe during rolling deploys and rollback |
| 10 | Multi-tab/session ownership contract | Prevents two active authorities for one character |
| 10 | Versioned feature-flag delivery with safe defaults | Supports staged rollout and emergency disablement without weakening authority |
| 10 | Maintenance/drain/capacity state contract | Gives clients deterministic warnings, queues and retry behavior |

Map triggers, the asset format and immutable cache headers benefit the
TypeScript client independently. Protocol v2 and handoff framing remain
capability-gated until that client deliberately opts in.

## Definition of done for every phase

- Update this roadmap's current-state and measurements in the same change; a
  compile or packet send is not evidence of a working end-to-end flow.
- Add native unit tests for pure code, WASM/browser integration tests for browser
  behavior and cross-language fixtures for every flow-critical packet.
- For every relevant test in `client/tests/e2e`, add Rust-client coverage or a
  reviewed retirement record naming the replacement behavior and test. A panel
  existing in Bevy is not evidence that the old workflow survived migration.
- Exercise the failure path and cleanup, not only the happy path.
- Record changes to compressed transfer size, startup, frame time, network and
  memory budgets; unexplained regressions fail the gate.
- Keep the TypeScript client and legacy protocol operational unless a separate
  migration explicitly retires them.

## Deliberately out of scope

- Maps larger than 100x100 or variable-sized maps during the seamless-handoff
  implementation. Server, NIF and wire coordinates use 100x100 maps with `u8`
  tile coordinates; changing that is a separate Phase 11 research candidate.
- Replacing the TypeScript client. Two clients against one server is a feature:
  it keeps the protocol honest.
- Treating client-side asset encryption, client hashes or WASM validation as
  anti-cheat. The server owns all authoritative validation.
