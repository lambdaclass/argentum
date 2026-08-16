# Rust/Bevy Client Roadmap

Tracks remaining work for `client-rs`, the Bevy client targeting the browser
(wasm/WebGL2) and native desktop from one codebase. It is an alternative to the
TypeScript/Pixi client in `client/`, not a replacement — both speak to the same
Elixir server.

Phases can overlap, but they are ordered by what unblocks what.

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
with real artwork, NPCs and ground objects, a character with correct body/head
composition, held-key movement gated by the server's own walk formula, a live
WebSocket session that logs in, sends walk packets and applies position
corrections.

Not working: everything in Phase 1 onward.

## Phase 0: Correctness debt

Small, already-known defects that make later work harder or slower.

1. **[client]** Fix the native build. `wayland-sys` needs system libraries the dev shell does
   not provide, so `cargo test -p ao-client` cannot even compile. Native is half
   the point of choosing Bevy.
2. **[client]** Move pure logic out of `ao-client` into `ao-core`. The `GrhIndex`,
   `parse_directional`, `parse_npcs` and `parse_objects` tests live in a crate
   that cannot build natively, so they never run.
3. **[client]** Trim the wasm payload. Bevy's full default features were enabled to diagnose
   a renderer that cleared the screen but drew nothing; that diagnosis is done
   and the payload has stayed at 24.9 MB since. Re-trim with evidence, adding
   features back one at a time.
4. **[server]** Serve the client from the game server's origin. It currently runs on a
   separate port and needs CORS on every asset route, which is a dev-only
   arrangement that will not survive deployment.

Exit criteria:

- `./build.sh check` passes for both targets, including `ao-client` tests.
- Payload is justified: each enabled Bevy feature is needed by something.

## Phase 1: A real session

The client connects and moves, but nothing else. This is the largest phase.

1. **[client]** Protocol breadth. Only `pos_update` (31) is decoded. Unknown ids currently
   fail the connection deliberately, because packet lengths are not on the wire
   and a skipped packet desynchronises everything after it. Each packet needs
   its decoder plus a byte-level fixture, matching how `apps/ao_protocol` is
   tested.
   - character create / move / remove / change
   - chat, console messages
   - stats: hp, mana, stamina, hunger, thirst, gold, level, experience
   - inventory and spell slots
   - ground object create/remove
   - weather, map change
2. **[client]** Login and character creation. Needs a real UI surface — see Phase 4. The
   server endpoints already exist (`/api/auth/login`, `/api/characters`,
   `/api/meta/character-options`) and the web client exercises them.
3. **[client]** Other players and NPCs as live entities, not static map data: spawned,
   moved and despawned from packets.
4. **[client]** Reconnect handling. A dropped socket currently ends the session with a
   logged error and no recovery.

Exit criteria:

- A player can log in, see other connected players move in real time, chat, and
  survive a brief disconnect.
- Every packet the server sends during normal play is either decoded or
  explicitly and deliberately ignored.

## Phase 2: World fidelity

The world renders but does not yet behave like Argentum.

1. **[client]** Walk animation. Animated grhs resolve to frame 0; bodies carry multi-frame
   walk cycles with a `velocidad` the renderer ignores.
2. **[client]** Equipment layers: weapon, shield, helmet, cart, backpack, composed over the
   body in the correct order.
3. **[client]** Depth sorting. Characters draw in spawn order, so one standing behind another
   can occlude it. Sprites are 27x47 against 32px tiles, so overlap is constant.
   Per-row containers avoid a per-frame sort — the approach `research/argentumunited`
   documents.
4. **[server + client]** Roof hiding. Layer 4 draws unconditionally, so entering a building hides the
   player under its roof. The rule is `trigger == 1` on the player's tile, which
   means the server must also ship triggers in the map pack: `encode_map`
   currently omits them and the web client never decodes them.
5. **[client]** Tile streaming that keeps up with movement over long distances, replacing the
   grow-only painted window.
6. **[client]** Tree fading, name labels, chat bubbles, combat text, FX.

Exit criteria:

- Walking, turning and fighting look like the VB6 client beside it.
- Entering a building reveals its interior.

## Phase 3: Seamless map transitions

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
7. **[client]** Persistent world-pack cache. The pack is **58.8 MB**; it must be fetched once
   and never re-fetched. Holding it fully resident alongside decoded maps and a
   texture cache is the biggest memory risk in the design — prefer a
   range-indexed pack or per-map files over an LRU across a resident 58.8 MB
   buffer.
8. **[client]** Persistent texture cache keyed by sheet, never uploading the same sheet
   twice, bounded by a **byte budget** rather than an entry count. Map 1 alone
   needed 28 sheets for one visible window. Count decoded RGBA/GPU allocation,
   not compressed PNG bytes, and make the browser budget configurable.
9. **[client]** Exit-based preloading of likely destinations, prioritised by distance to the
   player. Give speculative assets their own megabyte allowance and stop
   preloading before it consumes the headroom reserved for `PendingWorld`; an
   LRU entry count is not a memory bound.

Exit criteria:

- With destination loading deliberately delayed by two seconds, the old world
  stays rendered, input is paused, and the destination appears atomically — no
  black frame, no loading screen, no duplicated character, no stale entity.
  This needs a delay-injection hook to be testable at all.
- Under forced egress backpressure, packet capture proves that no handoff member
  is dropped, coalesced, or delivered outside its `begin`/`end` boundaries.
- Browser telemetry reports pack, decoded-map, speculative-preload, and estimated
  GPU-texture bytes separately and stays within configured ceilings.
- 1,000 repeated transitions leave no leaked entities or textures.
- Destination failure, disconnect mid-transfer, stale source movement after
  handoff, and transitions under backpressure all behave.

## Phase 4: UI

Nothing exists. Bevy has no UI toolkit enabled in this build.

1. **[client]** Decide the approach. An HTML/DOM layer over the canvas is likely right for
   forms, text input and IME — the web client already implements these flows
   against the same endpoints. `bevy_egui` is the alternative and keeps
   everything in one renderer, at the cost of worse text input.
2. **[client]** Login, character selection and creation.
3. **[client]** Inventory, spells, stats, chat, hotbar, minimap.
4. **[client]** Trade, bank, commerce, party, clan panels.

`research/argentumunited/README.md` documents a working AO client's layout and
eight specific ideas worth taking, including numbers rendered inside status bars
and locked inventory slots shown rather than hidden.

## Phase 5: Release

1. **[client]** Native packaging for Linux, macOS and Windows.
2. **[client]** Asset caching: a service worker plus IndexedDB, which neither client has —
   every session currently refetches sprites.
3. **[server]** Content-hashed assets with long-lived immutable cache headers.
4. **[client]** Build identification in-client, as `client/` already does.
5. **[client]** Automated browser tests for the critical flows.

Exit criteria:

- A player can download a desktop build or open the browser build and play the
  same game.
- A repeat visit starts without refetching assets.

## Server work this client needs, in one place

Everything tagged **[server]** above, ordered by when it blocks:

| Phase | Change | Why |
| --- | --- | --- |
| 0 | Serve `client-rs` from the game origin | Removes the dev-only CORS arrangement |
| 2 | Emit `triggers` in `encode_map` | Roof hiding is impossible without them; the web client needs this too |
| 3 | Parity entries for the new handoff packets | `session_route_manifest.ex` classifies 202 packets; unclassified ones fail its test |
| 3 | `map_handoff_begin` / `end` + fixtures | Explicit snapshot boundary |
| 3 | `MapServer.enter/3` returns a snapshot | NPCs currently sent out-of-band, so no end marker is authoritative |
| 3 | Session `world_epoch` | Char indices are map-local and reused |
| 3 | `map_handoff_failed` | Destination refusal must not strand the player |
| 3 | Exempt the snapshot from egress coalescing | Critical prevents shedding, not reordering |
| 5 | Immutable cache headers on hashed assets | Repeat visits should not refetch |

Two of these already benefit the TypeScript client independently: map triggers
(it cannot hide roofs either) and immutable asset headers.

## Deliberately out of scope

- Maps larger than 100x100 or variable-sized maps. Server, NIF and wire
  coordinates are all built on 100x100 with `u8` tile coordinates. Nothing about
  seamless transitions requires changing that, and conflating the two would make
  both harder.
- Replacing the TypeScript client. Two clients against one server is a feature:
  it keeps the protocol honest.
