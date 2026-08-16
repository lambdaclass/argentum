# Rust/Bevy Client Roadmap

Tracks remaining work for `client-rs`, the Bevy client targeting the browser
(wasm/WebGL2) and native desktop from one codebase. It is an alternative to the
TypeScript/Pixi client in `client/`, not a replacement — both speak to the same
Elixir server.

Phases can overlap, but they are ordered by what unblocks what. Browser tests,
protocol fixtures and performance measurements start with the feature they
protect; they are not deferred to a final QA pass.

Items are tagged **[server]** or **[client]**. Some of this work lives in
`server/`, not here — it is tracked here because it exists to serve this client,
and splitting it across two roadmaps would hide the dependency. Anything tagged
**[server]** should also be reflected in the main `ROADMAP.md` when scheduled.

## Why this client exists

Gameplay rules the server enforces were re-implemented independently in the web
client. Two implementations of one rule in two languages must agree exactly, or
the player is snapped backwards mid-step — a bug that proved very hard to
diagnose from either side alone.

`crates/ao-core` holds those rules once, as pure code with no platform or
framework coupling, so the same logic can compile into the wasm client and into
the Rustler NIF the server already loads. Today it carries tile walkability, the
server's speed-hack accumulator, the map pack decoder and the wire protocol —
25 tests, all runnable natively without a browser.

## Current state

Working: real map data from the server's `AOMP` pack, all four map layers drawn
with real artwork, static NPCs and ground objects, a character with body/head
composition, held-key movement gated by the server's walk formula, a WebSocket
transport, a walk encoder and a `pos_update` decoder.

The session does **not** currently log in end to end. The client labels packet
74 as `LOGIN_EXISTING_CHAR`, but the server defines 73 as `login_existing_char`
and 74 as `login_new_char`. It sends the new-character-shaped packet copied
from BotArmy, then fails on the server's first WS response:
`world_pack_signature` (203), because the decoder only recognises
`pos_update` (31). "Socket opened and bytes were sent" is not a successful
session and must not be reported as one again.

The trimmed build measures **19.2 MB raw and 5.5 MB gzip**. Transfer-size gates
must use the compressed artifact players actually download; raw size remains a
secondary diagnostic.

## Phase 0: Platform foundation

Make the prototype honest and establish boundaries while the platform-specific
surface is still small.

1. **[client]** Correct the packet-74 name and current-state reporting. Keep distinct
   encoders for new-character login (74) and token-based existing-character
   login (73).
2. **[client]** Replace hard-coded asset origin, gateway URL, character name, password and
   client hash with runtime configuration. Production derives HTTPS/WSS
   endpoints from the page origin; development overrides them explicitly.
3. **[client]** Introduce Bevy application states:
   `Boot -> Authenticate -> SelectCharacter -> LoadWorld -> Playing -> Handoff
   -> Reconnecting`. Replace boolean lifecycle controls such as
   `MapLoadReported`, `CharacterDrawn`, `SceneDirty`, `ScenePainted`,
   `DrawnTiles` and `DrawnEntities` with scoped state, resources and events.
4. **[client]** Define platform services for HTTP, WebSocket transport, persistent cache,
   auth/token storage, audio, clipboard and external links. Provide browser and
   native implementations rather than spreading `cfg(wasm32)` through gameplay
   systems.
5. **[client]** Fix the native build and move pure parsers/rules into `ao-core`, so both
   targets compile and their platform-independent tests always run. Native HTTP
   and WebSocket stubs must become real implementations before native can be
   called supported.
6. **[server]** Serve the client and runtime configuration from the game origin. The current
   separate-port/CORS setup remains a development option only.
7. **[client]** Keep the trimmed Bevy feature set. Record 5.5 MB gzip as the initial WASM
   transfer baseline and fail CI on an unexplained regression greater than 5%;
   any intentional budget increase must name the feature that caused it.
8. **[client]** Establish a fixed browser/device/network benchmark profile and record
   numeric ceilings for time to first interactive world, p95 frame time, draw
   calls, WASM heap, estimated GPU memory and reconnect/handoff latency before
   the phases that consume those budgets begin.

Exit criteria:

- `./build.sh check` passes for WASM and native, including `ao-client` and
  `ao-core` tests.
- No credentials or production hosts are compiled into the client.
- Lifecycle transitions are represented by the state machine, not inferred
  from unrelated booleans.
- The compressed WASM size is produced and checked by CI.
- Runtime performance budgets have a reproducible measurement command and
  stored baseline, not an informal target.

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
4. **[client]** Add the minimal DOM authentication and character-selection shell now, not in
   the later full-UI phase. Use `/api/auth/login`, `/api/characters`,
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

Exit criteria:

- A real account selects an existing character, decodes packet 203, completes
  bootstrap and reaches `Playing` using packet 73.
- Packet 74 is used only for the deliberate character-creation flow.
- Every normal-play packet is decoded, or safely ignored only inside the
  negotiated framed protocol.
- Elixir and Rust fixtures prove identical packet bytes, including fragmented
  and concatenated delivery.
- Framing and packet decoders survive fuzz/property tests for truncation,
  hostile lengths and arbitrary unknown packet IDs without panic or desync.

## Phase 2: Authoritative live world

Replace the static demonstration with server-owned state before polishing it.

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
   model, presentation and UI layers before adding more packet handlers.

Exit criteria:

- A player can log in, see other players and NPCs move, see objects appear and
  disappear, chat, and survive a brief disconnect without stale entities.
- Local prediction remains responsive under injected latency and converges to
  the server without oscillation.
- Entity churn and reconnect soak tests leave no duplicate or leaked entities.

## Phase 3: World fidelity and audio

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

Exit criteria:

- Walking, turning and fighting look like the VB6 client beside it.
- Entering a building reveals its interior.
- A 30-minute movement/combat capture stays inside the frame-time, entity and
  texture-memory budgets.
- Audio starts only after consent/gesture and respects mute/background state.
- Golden screenshot tests cover representative outdoor, indoor, crowded and
  equipment-layer scenes at supported scale factors.

## Phase 4: Versioned assets and persistent cache

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
   still requires a live server.

Exit criteria:

- Loading one map does not download or retain the full 58.8 MB pack.
- A warm visit does not refetch unchanged maps or sprite sheets.
- Corrupt, partial and mixed-version caches recover automatically.
- CI reports cold/warm transferred bytes, cache hit rate, WASM heap and estimated
  GPU texture memory on a fixed browser profile.

## Phase 5: Seamless map transitions

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
9. **[client]** Use Phase 4's cache and exit dependency index to prepare destination maps and
   textures without re-downloading or re-uploading shared resources.

Exit criteria:

- With destination loading deliberately delayed by two seconds, the old world
  stays rendered, input is paused, and the destination appears atomically — no
  black frame, no loading screen, no duplicated character, no stale entity.
  This needs a delay-injection hook to be testable at all.
- Under forced egress backpressure, packet capture proves that no handoff member
  is dropped, coalesced, or delivered outside its `begin`/`end` boundaries.
- Browser telemetry reports decoded-map, speculative-preload and estimated
  GPU-texture bytes separately and stays within Phase 4's ceilings.
- 1,000 repeated transitions leave no leaked entities or textures.
- Destination failure, disconnect mid-transfer, stale source movement after
  handoff, and transitions under backpressure all behave.

## Phase 6: Complete UI, localization and accessibility

Use the hybrid boundary established in Phase 0: DOM for forms, text input, IME
and accessible controls; Bevy for the world and tightly coupled HUD visuals.

1. **[client]** Inventory, spells, stats, chat, hotbar and minimap.
2. **[client]** Trade, bank, commerce, party and clan panels.
3. **[client]** Build localization around stable message keys from the start. Ship Spanish,
   English and Portuguese with fallback tests; avoid embedding server-authored
   Spanish sentences where a semantic event plus parameters will work.
4. **[client]** Add settings for remappable keys, UI scale, chat size, master/music/effects
   volume, reduced motion and color-sensitive effects. Persist them per account
   or device as appropriate.
5. **[client]** Support keyboard-only navigation and accessible DOM labels for authentication,
   chat and forms. Add gamepad support after keyboard parity; touch/mobile remains
   research until the desktop/browser interaction model is solid.
6. **[client]** Show truthful staged boot progress—client, manifest, authentication, map,
   assets and snapshot—and actionable retry/error states. The JavaScript boot
   screen must wait for a Rust readiness signal rather than disappear merely
   because the WASM module instantiated.

`research/argentumunited/README.md` documents a working AO client's layout and
eight specific ideas worth taking, including numbers rendered inside status bars
and locked inventory slots shown rather than hidden.

Exit criteria:

- Every supported flow is usable in ES/EN/PT without clipped text or missing
  fallback keys.
- Authentication, character selection and chat work with keyboard navigation
  and IME input.
- Reloading preserves user settings without preserving passwords.

## Phase 7: Production hardening and release

1. **[client]** Handle browser lifecycle deliberately: focus loss clears held input, hidden
   tabs suspend expensive presentation, long sleeps trigger resynchronisation,
   stale callbacks from replaced sockets are ignored, and WebGL context loss
   restores resources or shows a recoverable error.
2. **[client + server]** Require HTTPS/WSS in production, short-lived launch tokens and
   appropriate CSP/origin controls. The client is untrusted: asset encryption,
   a client hash and browser-side checks are not security boundaries. Browser
   TLS uses the browser trust store; do not promise application certificate
   pinning for WASM.
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

Exit criteria:

- A player can download a desktop build or open the browser build and play the
  same game.
- A repeat visit starts without refetching unchanged assets.
- Supported browsers pass the same login, gameplay, reconnect and handoff suite.
- Release dashboards expose size, boot, frame, network and memory regressions
  before rollout.

## Phase 8: Research and experiments

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
| 3 | Emit `triggers` in `encode_map` | Roof hiding is impossible without them; the TypeScript client needs this too |
| 4 | Indexed/per-map asset format, hashes, range support and immutable headers | Avoids downloading/retaining 58.8 MB and enables safe persistent caching |
| 5 | Parity entries for the new handoff packets | Unclassified intentional divergences fail the protocol gate |
| 5 | `map_handoff_begin` / `end` + fixtures | Explicit snapshot boundary |
| 5 | `MapServer.enter/3` returns a snapshot | NPCs currently sent out-of-band, so no end marker is authoritative |
| 5 | Session `world_epoch` | Char indices are map-local and reused |
| 5 | `map_handoff_failed` | Destination refusal must not strand the player |
| 5 | Ordered critical snapshot batch | Boundary packets alone cannot contain normally coalesced members |

Map triggers, the asset format and immutable cache headers benefit the
TypeScript client independently. Protocol v2 and handoff framing remain
capability-gated until that client deliberately opts in.

## Definition of done for every phase

- Update this roadmap's current-state and measurements in the same change; a
  compile or packet send is not evidence of a working end-to-end flow.
- Add native unit tests for pure code, WASM/browser integration tests for browser
  behavior and cross-language fixtures for every flow-critical packet.
- Exercise the failure path and cleanup, not only the happy path.
- Record changes to compressed transfer size, startup, frame time, network and
  memory budgets; unexplained regressions fail the gate.
- Keep the TypeScript client and legacy protocol operational unless a separate
  migration explicitly retires them.

## Deliberately out of scope

- Maps larger than 100x100 or variable-sized maps during the seamless-handoff
  implementation. Server, NIF and wire coordinates use 100x100 maps with `u8`
  tile coordinates; changing that is a separate Phase 8 research candidate.
- Replacing the TypeScript client. Two clients against one server is a feature:
  it keeps the protocol honest.
- Treating client-side asset encryption, client hashes or WASM validation as
  anti-cheat. The server owns all authoritative validation.
