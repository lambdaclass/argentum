# Argentum Roadmap

This file tracks remaining work only. Completed work belongs in
`CHANGELOG.md`.

Work inside a phase can happen in parallel, but phases should close in order
because later phases depend on the proof, tooling, or operational surface built
earlier.

## Related Roadmaps

`client-rs/ROADMAP.md` tracks the Rust/Bevy client (browser wasm plus native
desktop). This root roadmap is the canonical owner of server, protocol,
security, operations, deployment, and cross-boundary integration work. A
cross-boundary server task is scheduled here and cites the Rust/Bevy task IDs
that consume it; the client roadmap may describe that dependency, but does not
own or close the server half.

The old TypeScript client may be consulted as a reference, but preserving it is
not a release requirement. Unless a future product decision explicitly restores
that requirement, compatibility and end-to-end acceptance target the Rust/Bevy
client.

## Current Priority

Start Phase 2 (Automated Proof Gate). Phase 1 is closed except the explicitly
blocked `:stun_start` drift item (#19), which needs VB6 source/formula
confirmation. The deterministic harness, snapshot/diff tooling, all golden
gameplay fixtures, the map-layer effects migration, VB6 source anchors, packet
byte-level fixtures, and RNG guardrails are all shipped; the source-data
parity tail has explicit fixtures.

Within Phase 2, the immediate product milestone is #21-#24: a small canonical
world in which a real Rust/Bevy client walks among four local MapServers without
seeing a map transition. Close the remaining client Phase 0 blockers, then
compile #21's topology/coordinate contract while the protocol contract (#13)
closes. Do not broaden packet or account-flow UI coverage: implement only the
modern launch/transport/bootstrap/reconnect and structured handoff path
(#16-#22) needed by #23. Use the current validated monolithic world pack so
per-region packaging, persistent cache, UI polish and staging cannot delay the
test. Only after the four-region slice is repeatable and failure-safe should
#24 make global position authoritative in persistence and broader gameplay or
production-topology work resume.

## Phase 1: Deterministic Parity Harness

Goal: make gameplay parity failures easy to reproduce, inspect, and fix without
depending on mailbox noise or incidental timing.

Work:

1. Close the backend parity tail from source data.
   - Real per-instance item `elemental_tags`
   - Faction-exclusive item flags and strip rules
   - Recipe data expansion and validation against source `.dat` data

2. Close Drift #19 from `drift.md`: blind/dumb/stun subsystem wiring.
   - Audit current state — blind/dumb expiry already ticks; stun-on-melee
     and the server-prompted work-target packet may still be missing
   - Port the missing pieces and emit `:blind_no_more` / `:dumb_no_more` /
     `:stun_start` / `:work_request_target` at their clear sites
   - Shrink `drift.md` to reflect what's actually closed
   - Only residual: `:stun_start` (melee stun-on-hit buff system), blocked on
     VB6 source/formula confirmation — tracked as the lone open Drift #19 item.

Exit criteria:

- Source-data parity tail has explicit fixtures or drift tickets.
- `drift.md` has zero open items, or each open item is explicitly ticketed.
  *(Only `:stun_start` remains, explicitly ticketed and blocked.)*
- Golden fixtures cite the VB6 source they are defending. **(Done — all 8
  scenario golden modules carry a `VB6 anchors` block; see CHANGELOG.)**
- Flow-critical packets have byte-level fixtures or an explicit reason they do
  not need one yet. **(Done — bank/trade/resurrect/status/inventory-use plus
  equip/use, spell-cast (heal/resurrect/status-clear), and movement
  (pos_update/character_move/heading/transfer); see CHANGELOG.)**
- Random flows are deterministic in the default test lane and parity-sensitive
  modules can't reintroduce raw `:rand` / `Enum.random` calls without an
  allowlist entry. **(Done — `rng_guard_test.exs` + `docs/RNG_AUDIT.md`; see
  CHANGELOG.)**

## Phase 2: Automated Proof Gate

Goal: turn parity from a claim into a repeatable gate.

Work:

1. Add a high-load bot benchmark.
2. Add a load and soak gate.
3. Keep the exact parity-gate suites defined in `server/docs/PARITY_GATE.md`.
4. Build and version a real VB6 packet-capture corpus.
   - Blocked until a Windows/VB6 capture environment exists.
5. Add real packet replay coverage for:
   - Login, character creation, and bootstrap
   - Movement, transfer, chat, and service requests
   - Inventory, equip/use, combat, spells, and death
   - Bank, trade, party, guild, faction, reconnect, and logout

6. Add concurrent combat integration coverage.
   - Multiple TCP clients attacking the same NPC
   - Multiple clients attacking the same player where PvP rules allow it
   - XP, loot, death, and visibility effects stay consistent

7. Add guild persistence integration coverage.
   - Create a guild through the live flow
   - Restart or reload persistence
   - Verify guild state, membership, rank, and chat eligibility survive

8. Add full NPC commerce integration coverage.
   - Buy and sell through TCP-level flow
   - Verify gold and inventory changes
   - Verify persistence after reconnect

9. Add long-duration soak coverage.
   - 10+ minute run
   - Memory growth tracking
   - Process growth tracking
   - Scheduler and queue-depth summary

10. Add combat soak coverage.
    - Bots fight, loot, die, and resurrect
    - Combat remains stable under repeated actions

11. Add map-transition soak coverage.
    - Bots repeatedly change maps
    - No duplicate entities or stale sessions remain

12. Make time-dependent gameplay deterministic in tests.
    - Add an injectable clock for cooldowns, buffs, autosave, combat, and
      transfer timing
    - Add deterministic scheduling helpers for periodic and delayed work
    - Remove parity-gate dependence on `Process.sleep/1` where controlled time
      can prove the same behavior

13. Add a versioned protocol compatibility contract.
    - One canonical manifest or schema for packet IDs, binary layouts,
      direction, maximum length, version, capability, and support status
    - Decide explicitly whether the schema is hand-authored or extracted from
      the Elixir source of truth; either way, add a drift check against the
      actual Elixir encoder/decoder
    - Shared Elixir and Rust fixtures generated from or checked against that
      contract
    - Classify every WebSocket-only extension as an intentional divergence
      before assigning or shipping its packet ID
    - Explicit backward-compatibility and packet-deprecation rules
    - Defined handling for unknown, unsupported, and retired packets
    - CI fails when the manifest, Elixir implementation, Rust implementation,
      or byte fixtures disagree

14. Turn benchmark results into performance regression budgets.
    - Store versioned baselines for representative hardware and scenarios
    - Gate movement RTT p99, the duration p99 of the existing NPC-AI/regen/buff
      jobs, maximum queue depth, memory per connected player, login throughput,
      and autosave latency. These job budgets do not define or authorize one
      global simulation tick
    - Report both the absolute result and change from the accepted baseline

15. Produce a failure-reproduction bundle for integration, replay, load, and
    soak failures.
    - RNG seed and deterministic-clock state
    - Bot scenario and action history
    - Relevant packet trace
    - State snapshots and first meaningful diff
    - Logs, metrics, commit, and runtime configuration

16. Replace the current long-lived per-character launch token with secure game
    launch credentials. *(Rust/Bevy: W-0024, W-0025, W-0027.)*
    - Issue an opaque, short-lived credential through the authenticated account
      API, scoped to the account, selected character, and permitted protocol
    - Store only a hash, consume it atomically once, enforce expiry, and support
      revocation and signing-key rotation without logging the secret
    - Log an existing character through packet 73 after the REST launch flow;
      packet 74 remains new-character creation and must never be used as an
      implicit login shortcut
    - Return explicit authentication success and stable rejection reasons
    - Keep password-over-game-socket or legacy token login behind a separately
      named compatibility boundary; it is not the Rust/Bevy production path
    - Cover issue, successful consume, expiry, replay, revocation, wrong
      character, and concurrent double-consume end to end

17. Add a negotiated, length-framed WebSocket protocol without changing the AO
    gameplay payload bodies unnecessarily. *(Rust/Bevy: W-0021-W-0024, W-0029.)*
    - Negotiate protocol version and capabilities before authentication
    - Negotiate `argentum.v2` and use an explicit little-endian bounded
      envelope—`message_type: u16`, `flags: u16`, `payload_length: u32`, then
      payload—so an unknown optional message can be skipped without losing
      stream alignment. Initially flag bit 0 means `required`; all other bits
      must be zero. Unknown required types and unknown flag bits close with a
      stable protocol reason. The subprotocol, not heuristic parsing, decides
      whether framing is present
    - In modern framing, `message_type` owns the packet ID and `payload` is the
      existing AO packet body without its old signed-i16 ID prefix. The legacy
      adapter alone reconstructs/parses `legacy_id + body`; do not transmit a
      redundant second packet ID inside a modern envelope
    - Define explicit login accepted/rejected, world-pack signature, session,
      bootstrap, ping/pong, and protocol-error messages
    - Bound frame size, payload length, buffered bytes, decoded messages per
      scheduler slice, and ingress/egress queues before allocating or
      enqueueing. "Per scheduler slice" is a work budget, not a game tick
    - Record message delivery class in the schema: atomic/critical,
      transactional, latest-state/coalescible, ephemeral, or static. WebSocket
      remains one reliable ordered TCP stream: a class controls queue priority,
      coalescing and overload behavior, but is selected by trusted message-type
      metadata rather than a client flag and must never be described or tested
      as a real unreliable or unordered transport channel
    - Specify required-versus-optional capability behavior, downgrade policy,
      and clean close reasons for incompatible clients
    - Add hostile-length, truncated-frame, unknown-packet, queue-pressure, and
      Elixir/Rust byte-fixture coverage

18. Send a complete, ordered, authoritative bootstrap snapshot after login.
    *(Rust/Bevy: W-0024, W-0025, W-0030.)*
    - Include snapshot version, session epoch, authority epoch/revision,
      replication epoch/revision baseline, character identity, map and position,
      visible entities, inventory, equipment, spells, hotbar, vitals, cooldowns,
      quests, and relevant party/guild/faction state
    - Use explicit begin/end or an equivalent atomic envelope so the client
      never guesses that bootstrap has finished
    - Route every member through one ordered, non-sheddable session path; no
      producer may send bootstrap packets out of band
    - Define oversize-snapshot chunking, cancellation, timeout, and failure
      semantics without exposing a partially initialized playable world
    - Pin the full sequence with byte fixtures and a live login test

19. Add correlated authoritative receipts and revisioned state replication.
    *(Rust/Bevy: W-0026, W-0030 and the owning UI workflow tasks.)*
    - Carry a request/operation ID, command kind, success or rejection, stable
      reason code/localization key, affected entity or slot, and authoritative
      state version or delta
    - Cover inventory use/equip/drop, hotbar changes, spell casts, commerce,
      bank, trade, crafting, quests, and social mutations before those screens
      claim live completion
    - Define duplicate, retry, timeout, late-reply, and stale-version behavior
      so the client never treats an unrelated state change as its response
    - Preserve server authority: optimistic presentation may be reconciled, but
      it may not invent a successful gameplay mutation
    - Keep simulation event-driven. Do not add a global, world-wide, regional,
      or protocol-driven fixed tick as part of protocol v2. Each MapServer
      continues to serialize its own commands through its mailbox and runs only
      the existing independently scheduled gameplay jobs it actually owns
    - Give an accepted connection a `SessionEpoch`; give initial authority and
      each committed ownership handoff a new `AuthorityEpoch`; and number
      committed mutations monotonically with an `AuthorityRevision` scoped to
      that authority epoch. A same-owner resnapshot does not invent a new owner
    - Separately give each atomic client-view baseline a `ReplicationEpoch` and
      number emitted per-session AOI deltas with `ReplicationRevision`.
      Bootstrap, resnapshot and handoff install a new replication baseline. Use
      distinct, non-wrapping `u64` wire types and reject an exhausted counter
      rather than silently wrapping
    - Increment `AuthorityRevision` exactly once after an accepted authoritative
      transaction has committed. A rejected command returns the current
      authority revision but does not advance it. Assign `ReplicationRevision`
      only after filtering/coalescing one emitted session delta. The two must
      remain separate: hidden mutations cannot create client-visible gaps, and
      coalescing cannot erase an authoritative transaction version
    - Epochs and revisions are ordering/version state, never elapsed time, frame
      numbers, timers, or permission to advance the simulation
    - Define movement as `MoveIntent {command_id, authority_epoch,
      input_sequence, direction}`. The server processes it immediately and
      returns an accepted/rejected receipt containing the same command/input
      identifiers, resulting authority revision and canonical position. The
      client may predict presentation, but never sends an authoritative position
    - Build `WorldDelta {replication_epoch, base_replication_revision,
      replication_revision, added, changed, removed}` per session from
      already-committed changes inside that session's authorized AOI. Assign the
      revision after filtering/coalescing. MapServers never wait for one another
      or for an egress flush, and no central process receives every world mutation
    - Apply a delta only when its replication epoch is current and its base
      replication revision matches the client's applied replication revision.
      Ignore an exact duplicate, reject a stale epoch, and request one bounded
      authoritative resnapshot on a gap; never guess, partially apply, or
      advance across a missing replication revision
    - Send login, snapshot/handoff, inventory, trade and authoritative combat
      outcomes immediately through non-sheddable ordered paths. Egress may
      coalesce unsent position/heading/animation/vital projections by stable
      entity ID and may shed explicitly ephemeral presentation under pressure;
      it may not coalesce transactions, receipts or atomic snapshot members
    - If measurement justifies batching latest-state projections, use a
      configurable **maximum wait**, initially no more than 40 ms, only while a
      connected session already has pending coalescible data. This is an egress
      flush deadline, not simulation time: critical messages bypass it, it
      never wakes an empty map, and changing it must not change gameplay results
    - Prove the contract without wall-clock luck: identical command replay does
      not double-apply; rejected commands do not advance revision; a missing
      delta requests one snapshot; delayed/coalesced projections converge to
      the same state; and changing the flush deadline leaves authoritative
      commands, receipts and authority revisions byte-for-byte equivalent even
      when the number of replication deltas legitimately differs

20. Define and prove reconnect and resnapshot semantics.
    *(Rust/Bevy: W-0027, W-0033.)*
    - Reconnect creates a fresh `SessionEpoch`, then its bootstrap installs fresh
      authority and replication epochs; discard every queued or late event from
      the old session
    - A same-connection, same-owner resnapshot preserves session/authority epoch
      and authority revision, but installs a fresh replication epoch and complete
      replication baseline. Do not claim ownership changed merely to repair a
      client-view gap
    - Reauthenticate with a fresh credential, rebuild from an authoritative
      snapshot, and never replay unsafe mutations implicitly
    - Return stable close/retry reasons for maintenance, server full, ban,
      protocol mismatch, expired credential, replacement login, and overload
    - Bound retry hints and server-side reconnect state
    - Prove reconnect leaves one session, one visible entity, and no duplicated
      inventory, trade, guild, party, or combat effects

21. Compile and govern the canonical virtual world before handoff code invents
    its own geography. *(Rust/Bevy: W-0097-W-0098.)*
   - Compile the 842 CSM maps, exits, `mapsworlddata.dat`, metadata and reviewed
     overrides into one deterministic, content-hashed `WorldTopology`
   - Emit stable world spaces/regions, signed global origins, storage/core/
     transition-band/gutter bounds, valid/simulated-tile masks for void or
     irregular space, per-layer ownership *records*, dependencies and transition
     classes: geographic seam, door, portal, teleport or instance entrance
   - **Ownership boundary, settled 2026-08-22.** The compiler emits per-layer
     ownership as evidence marked unreviewed and never guesses an owner: for
     every layer of every seam it records which map draws the tile, whether the
     neighbour draws the same graphic, and whether their collision agrees. The
     artist-reviewed rule that picks an owner and activates it belongs to the
     production classification task (`W-0101`). Choosing a ground owner decides
     what a player may walk on, and the only signal available to a compiler is
     art -- which measured 100% continuity across a boundary that walks a
     character into the sea. The sizes handed over: 365 land, 823 shore and
     10,264 sea boundary tiles where two maps draw the same layer differently,
     and 826/375/6 where their collision values disagree
   - Transition *content* classes are not measurable and are not guessed: the
     compiler reports the geometric shape of every non-seam exit -- 0 mis-typed
     seams, 0 arrivals into a band, 19 band-to-interior, 1,201 from map
     interiors -- and door/portal/teleport/instance is a recorded human
     disposition
   - Recompute and report the audited baseline: 100x100 storage; provisional
     74x80 core (`x=14..87`, `y=11..90`); bands `x=13/88`, `y=10/91`;
     158,549 exits; 157,304 valid cross-map; 156,084 standard seam records;
     1,220 valid exceptions; 49 same-map; 1,196 missing/sentinel
   - **Corrected 2026-08-21.** The figures above reproduce exactly from the
     corpus. Three others in the original audit are superseded, because their
     names were ambiguous or their values depended on a traversal: 1,091
     reciprocal seam pairs becomes 1,102 reciprocal *placements* and 1,098
     unique *pairs* (four pairs claim two opposite placements: 37-168, 37-264,
     167-168, 167-264), plus 15 one-sided placements; 237 components becomes 226
     weak or 232 reciprocal-only, and the roadmap must say which graph it means;
     58 placement conflicts is withdrawn rather than corrected, because moving
     the traversal root moved it from 48 to 161. Stable replacements: 2
     inconsistent components, 2 conflict clusters, 56 cycle witnesses, 125 maps
     implicated, 428 inside an inconsistent component. 56, not the 50 first
     recorded here: the spanning forest keyed tree edges by map pair, so a
     second contradictory claim between the same two maps was mistaken for the
     tree edge and produced no witness. Reproduce with `ao-topology --check`;
     `client-rs` holds the pinned values
   - Treat existing contradictions as a reviewed baseline and fail on new or
     unexplained drift. No active geographic seam may retain an unresolved
     placement conflict or silently chosen winner
   - Use tile/collision overlap as review evidence: at least 95% is an
     automatic candidate, 85-95% requires review and below 85% requires
     correction or explicit non-geographic classification
   - Define shared Elixir/Rust `WorldPosition`, `WorldSpaceId`, stable
     `RegionId`/`EntityId`, `TopologyVersion`, `AuthorityEpoch`, `TransferId`
     and checked global/local conversions with cross-language fixtures
   - Make global position canonical for modern client/protocol/persistence/
     logs/markers while MapServers keep their local collision/occupancy grids;
     local map coordinates are derived adapters, not a second authority
   - Keep the compiled topology in immutable/local read structures so movement
     conversion never calls one central world-position process
   - Keep stable identity separate from content hash, runtime PID/node and
     dynamic instance identity; never persist a transition-band position

22. Make login bootstrap and handoff one structured, ordered, failure-safe
    authority operation. *(Rust/Bevy: W-0030, W-0062-W-0066, W-0096.)*
   - Classify and byte-pin all new packets before implementation; bootstrap and
     handoff carry topology version/hash, space/region, canonical position,
     stable identity, epoch and transfer ID
   - Refactor map entry so it returns structured snapshot data instead of
     sending nearby NPCs or other members out of band
   - Make the session process the single ordered writer for begin, snapshot
     members, end, and failure
   - The source owns through prepare; destination validates topology, capacity,
     collision and readiness; one commit transfers authority. Abort, timeout,
     duplicate, crash, overload and topology races leave exactly one owner
   - A successful commit installs a new authority epoch/revision and a new
     replication epoch/revision baseline with its complete snapshot atomically.
     Authority revisions from the source cannot be continued or translated;
     delayed source deltas/receipts are rejected by their applicable epoch
   - Keep the same socket/session and stable character identity; reject queued
     envelopes from an old region/epoch and never trust a client transform or
     destination
   - Keep snapshot and handoff messages non-sheddable and forbid egress
     coalescing from reordering or crossing the atomic boundary
   - Define server-authorized static preload dependencies separately from live
     entity authority; never disclose hidden destination state
   - With destination readiness delayed by two seconds, prove the old world
     remains visible on the same session, then one complete destination frame
     commits at the matching boundary; failures restore source or terminate
     explicitly, never expose a half-entered destination

23. Prove a four-region seamless-world MVP before production packaging or
    broad rollout. *(Rust/Bevy: W-0099.)*
   - Select one compiler-confirmed 2x2 geographic group; maps 1/2/11/14 are only
     candidates until the compiler proves their placements and seam quality
   - Use the monolithic pack, four global `RegionSceneRoot`s and one camera;
     retain one already-running local-coordinate MapServer per region
   - Walk north, south, east and west under held input. One step crosses the
     seam; player/camera/world-map/debug coordinates and stable identity remain
     continuous with zero paused movement frames on the prepared path while
     internal owner/epoch changes on the same socket
   - Expose no map number, loading/fade, blank/partial frame, camera reset,
     duplicate character, mixed epoch or durable transition-band coordinate
   - Separately delay preparation two seconds after static art is ready: keep
     the complete composed world visible and the player on the last source tile,
     then cross when ready. Also test rejection, stale topology/epoch,
     overload, crash, disconnect, corners, rapid backtracking and 1,000
     crossings with flat memory
   - Keep cross-border live visibility/combat/AI out of this MVP; static neighbor
     rendering and invisible player handoff are mandatory

24. Migrate character persistence to versioned canonical global position after
    the slice is proven. *(Rust/Bevy: W-0100.)*
   - Persist world space, signed global x/y and topology version; stable region
     is a lookup hint, and legacy map/local fields are a compatibility view
   - Migrate a legacy record on login through its pinned topology version,
     dual-write during a controlled release and audit every rewrite
   - During movement, advance global state first and compare its derived local
     position with the actual MapServer/local owner; do not verify a value by
     re-deriving it from the same legacy source
   - Define offline backfill, rollback, ambiguous/obsolete topology handling and
     the safe flip criteria: zero unexplained shadow mismatches in slice/soak
     evidence

Exit criteria:

- Fast and slow parity gates are documented and runnable.
- Load/soak has a repeatable command and pass criteria.
- Real VB6 packet captures are versioned or the blocker is explicitly tracked.
- Replay coverage exists for the major protocol surfaces once captures exist.
- Integration and soak suites cover combat, guilds, commerce, and transfers.
- Time-dependent parity tests run against a controllable clock without
  timing-sensitive sleeps in the critical path.
- The protocol compatibility manifest is versioned and checked by both server
  and Rust tests.
- Existing-character launch uses expiring, single-use credentials and completes
  a real authenticated Rust/Bevy session without packet 74 or fixture authority.
- The framed WebSocket transport is negotiated, bounded, forward-compatible for
  optional packets, and protected by hostile-input tests.
- Bootstrap is explicit, complete, ordered, and atomic from the player's point
  of view.
- Mutating client commands receive correlated authoritative results, and
  reconnect creates a fresh epoch without duplicate or stale state.
- Server simulation remains event-driven: no global/protocol tick or
  cross-MapServer barrier exists. Session epoch, authority epoch/revision and
  replication epoch/revision—not elapsed time—order state, and changing the
  optional egress coalescing deadline does not change gameplay results.
- A replication-revision gap, stale epoch or queue overflow produces one
  explicit bounded resnapshot/close path; it never guesses missing state, grows
  an unbounded queue or turns a latest-state optimization into lost
  transactional authority.
- The deterministic topology compiler emits a versioned/hash-addressed,
  reviewable world; every activated geographic seam has exact round trips and
  zero unresolved placement contradiction.
- Elixir and Rust share canonical global position and stable identity fixtures;
  local MapServer/VB6 coordinates are checked adapters and transition bands are
  never durable state.
- Login bootstrap and map transfer share a structured, ordered snapshot path;
  no out-of-band map producer can race the completion marker.
- Before per-region packaging work begins, the current world pack proves one real
  two-second-delayed transfer keeps the source visible and atomically commits a
  complete destination on the same socket/session.
- A compiler-confirmed four-region slice crosses every cardinal border on one
  connection with continuous player/camera/global coordinates and no visible
  map transition or prepared-path movement stall; unrelated exits still
  atomically replace one complete scene.
- Delayed and failed transfers preserve one authoritative world and never leave
  duplicate entities or mixed epochs.
- Versioned global-position migration, dual write and shadow comparison have an
  auditable rollback and zero unexplained slice/soak mismatches before the
  authoritative persistence read flips.
- Performance regressions have stored baselines, explicit budgets, and a
  failing gate.
- Failed proof-gate runs preserve enough evidence to reproduce the failure
  locally.

## Phase 3: Observability And Operations

Goal: make the server inspectable and operable before public traffic.

Work:

1. Finish telemetry wiring where coverage still matters.
   - Producer migration beyond `Arena.Map.Visibility`
   - Bank and guild event coverage
   - Autosave-task failure and disconnect coverage

2. Finish metrics and dashboards.
   - Backpressure queue depth
   - Disconnect reasons
   - `send_pend`
   - Autosave task failures
   - Egress shed counters
   - Egress coalesce counters
   - Launch-credential issue, consume, expiry, replay rejection, and revocation
   - Protocol-version and capability mix
   - Authentication-to-bootstrap latency and bootstrap failures
   - Command-receipt rejection, timeout, and stale-version counts

3. Add alerts.
   - Sustained shedding
   - Forced backpressure disconnects
   - Launch-credential replay spikes and authentication abuse
   - Bootstrap failure or latency budget violations

4. Add runtime admin tools.
   - Map inspection
   - Process inspection
   - Map control actions

5. Add admin lookup.
   - Accounts
   - Characters
   - Online players

6. Add admin actions.
   - Moderation
   - World actions
   - Log inspection
   - Health checks

7. Add incident runbooks.
   - Database outage
   - Map crash
   - Gateway overload
   - Deploy rollback

8. Add durable structured audit storage, review, and export for moderation
   actions.
   - Append-only persistence rather than logger output as the system of record
   - Retention and archival policy
   - Tamper-evident records
   - RBAC-protected access
   - Search by actor, target, action, and time range
   - Export in an operator-friendly format

9. Define service-level objectives and error budgets.
   - Availability
   - Login success rate
   - Tick and movement latency
   - Disconnect rate
   - Persistence failure rate
   - Recovery-time objective and acceptable data-loss window
   - Use the objectives to drive alert thresholds and release decisions

Exit criteria:

- Operators can inspect live maps, sessions, and online players.
- Critical failure modes emit telemetry and metrics.
- Dashboards and alerts cover backpressure, disconnects, and autosave failures.
- Incident response and moderation audit flows are documented and usable.
- Service-level objectives are measurable from production telemetry and have
  explicit error budgets.
- Audit records are durable, access-controlled, searchable, exportable, and
  tamper-evident.

## Phase 4: Security And Abuse Hardening

Goal: keep parity while making abuse cases executable and visible.

Work:

1. Keep the exploit and parity audit executable.
2. Add anti-cheat hardening.
3. Expand adversarial tests for protocol abuse, impossible movement, combat
   abuse, chat abuse, and economic abuse.

4. Complete the account-security lifecycle.
   - Password reset and email verification
   - Session listing and revocation
   - Login throttling and account-lockout policy
   - Multi-factor authentication for administrative accounts
   - Secret and signing-key rotation
   - Account recovery and deletion flows

5. Adversarially harden the modern game-launch and WebSocket authentication
   path introduced in Phase 2.
   - Rate-limit credential issuance and socket authentication by account, IP,
     character, and risk signal without creating an enumeration oracle
   - Test stolen, expired, replayed, revoked, cross-character, malformed, and
     concurrently consumed credentials
   - Redact credentials, passwords, session identifiers, and recovery secrets
     from logs, telemetry, traces, crash reports, and audit exports
   - Require HTTPS/WSS in production and reject insecure or unexpected origins
     according to an explicit deployment policy
   - Exercise key rotation and emergency global/session revocation

Exit criteria:

- Abuse checks are represented by automated tests or executable audit tasks.
- New hardening does not silently break VB6 protocol parity.
- Account recovery, session control, administrative MFA, and secret rotation
  are implemented and covered by adversarial tests.
- The modern game-launch path resists replay, theft, enumeration, brute force,
  malformed input, secret leakage, and unsafe transport downgrade.

## Phase 5: Runtime Performance And Architecture

Goal: remove known hot-path limits after the proof gate is stable.

Work:

1. Replace NPC aggro full scans with spatial-grid queries.
2. Replace pet target full scans with bounded or indexed lookup.
3. Split `guild_server.ex` into focused modules.
4. Pre-resolve `.dat` references at load time where hot-path lookups repeat.
5. Unify interest management for players, NPCs, and ground items.
6. Add runtime-tunable settings for intervals, rates, and formula constants.
7. Finish the long-term persistence boundary cleanup.
   - One explicit character write path
   - One explicit guild write path
   - Clear ordering, retry, and failure semantics
   - Keep guild writes synchronous until a separate UX/semantics design is
     approved

8. Disarm high-frequency timers on empty maps and rearm them exactly once on
   first entry.
   - Every MapServer stays loaded and its state stays in memory: no reload, no
     hibernation, and no measurable entry delay
   - Measured after the empty-map fast paths landed: an idle 842-map world still
     burns 21% of a core, and 94.6% of idle reductions are the map processes —
     no longer the tick bodies, which now return immediately, but the wakeups
     themselves at 1 to 3.3 Hz per map
   - Buff, regen and NPC-AI timers stop being rearmed while `players` is empty;
     `do_enter` rearms each of them exactly once, and a second entry while
     somebody is already there must not arm a duplicate
   - Autosave keeps running on every map, because it is what keeps an empty
     map's heap compact and it is the only sweeper left once the fast timers
     are silent
   - Respawn reconciliation on entry already covers the deadlines an unarmed
     NPC timer does not scan
   - Close with tests for timer uniqueness across rapid leave/re-entry, a
     crashed session, and simultaneous entries; and with before/after idle CPU
     and entry-latency measurements

9. Reduce allocation in NPC AI hot loops on crowded maps.
   - `npc_ai.ex` accumulates effects with `effects ++ [effect]` inside
     reductions over every live NPC, which is quadratic in the number of
     effects a tick produces
   - Prepend and reverse once, or thread an accumulator, and reuse static map
     data instead of rebuilding collections
   - Not to be done on the strength of the shape alone: implement only with
     before/after allocation and tick-latency numbers on a crowded map that
     show a meaningful improvement. Measured today at 50 players, a regen tick
     is p95 59us / p99 85us and a buff tick p95 59us / p99 63us, against a
     500 ms NPC tick budget — there is no latency problem yet, only a shape
     that will not scale

10. Curate and atomically activate the production world topology after the
    four-region MVP. *(Rust/Bevy: W-0101, W-0095.)*
   - Give every legacy exception/conflict a reviewed disposition: corrected
     geography, non-geographic transition or unsupported seam
   - Require zero unresolved contradiction in an activated geographic component
   - Compile deterministic ownership for ground, collision, gutters,
     decorations/roofs, corners, occlusion, weather/audio and world-map layout
   - Version topology and content together; pin an existing session or
     resnapshot it explicitly during activation

11. Add bounded cross-region interest and command routing without splitting
    authority. *(Rust/Bevy: W-0102.)*
   - One MapServer owns each entity; adjacent regions receive only read-only,
     delta/batchable projections keyed by stable entity ID, owner and epoch
   - Route attacks/spells/interactions asynchronously to the target owner with
     command IDs/idempotency; validate global range, line of sight, zones,
     cooldowns and cost exactly once at authority
   - Never use a synchronous cross-MapServer call on movement/combat hot paths,
     wait for a neighbor before processing local authority, replicate private/
     full entity state, or send every position update through one central
     process
   - Publish only committed, read-only projections. A border subscription may
     flush/coalesce pending changes at a measured 10-25 Hz ceiling while it has
     observers, but this is an asynchronous replication deadline—not a shared
     simulation tick. No observer means no AOI publication timer or work
   - Critical routed commands bypass projection batching. A slow, crashed or
     partitioned neighbor leaves local simulation running; its projection may
     become stale only up to the explicit age budget, after which it is removed
     and resnapshotted rather than extrapolated as authority
   - Bound AOI radius, update bytes/rate, stale age, queue depth and work per
     publication window/command; record local versus cross-node latency,
     coalescing, shedding and resnapshot behavior
   - Test ownership movement during an in-flight command, slow/crashed
     neighbors, crowded seams, projectiles, visibility and duplicate delivery

12. Add hierarchical cross-region navigation with explicit actor policy.
    *(Rust/Bevy: W-0103.)*
   - Compile a high-level seam/portal graph and keep tile A* inside the owning
     MapServer rather than building one giant hot-path navmesh
   - Keep ordinary NPCs local; only players, pets, escorts, event bosses or
     explicitly migratory actors may transfer authority
   - Bound high-level search and cover topology change, unreachable goals,
     congestion, owner crash and pursuit cancellation

13. Add supervised runtime instance world spaces. *(Rust/Bevy: W-0104.)*
   - Keep immutable instance templates separate from UUID-like runtime
     `WorldSpaceId`s and region owners
   - Allocate/admit idempotently through a registry/supervisor that is not on
     movement/AOI hot paths
   - Define capacity, party admission, reconnect, owner crash, topology/content
     version, TTL/grace cleanup and an auditable safe return anchor

Exit criteria:

- An idle world does not burn a core on maps nobody is standing in, and no map
  needs reloading to achieve it.
- NPC and pet targeting avoid full-map scans on hot paths.
- Guild code has clear module boundaries.
- Persistence writes have explicit ownership and failure semantics.
- Production topology activation is contradiction-free and atomic.
- Cross-region AOI/commands preserve one owner and stay inside explicit
  latency, queue, byte and publication-work budgets without a global tick,
  cross-map barrier or central hot path.
- Hierarchical navigation keeps local work local, and runtime instances have
  supervised ownership, cleanup and safe-return semantics.

## Phase 6: Release And Deployment

Goal: make the project releasable, recoverable, and supportable.

Work:

1. Add release artifacts.
2. Add deployment pipeline.
3. Add backup and restore runbook.
4. Add TLS for HTTPS and WSS.
5. Add asset CDN and static-delivery strategy.
   - Send long-lived immutable cache headers for content-hashed packs, indices,
     sprites, audio, and wasm artifacts
   - Keep manifests and mutable entry points short-lived and revalidated
   - Define cache purge, rollback, integrity, range-request, and cross-origin
     policy
6. Add automated backups.
7. Tune database connection pools.
8. Define the live database migration strategy.
9. Add pre-public scripted load and soak runs.
10. Pin and document the working toolchain.
    - Elixir version
    - Erlang/OTP version
    - Hex version
    - Rust, Cargo, clippy, rustfmt, wasm-bindgen, and browser-harness versions
    - Nix and non-Nix setup paths

11. Add a dev-environment verification command.
    - Check Elixir/Erlang/Hex compatibility
    - Check the pinned Rust/wasm toolchain and browser-harness availability
    - Check map-pack build prerequisites
    - Fail with actionable setup output

12. Make client build failure modes explicit.
    - Surface map-pack prebuild failures clearly
    - Distinguish Nix/Rust, wasm-bindgen, asset, and browser-harness failures
    - Keep the shipped build stamp tied to the exact clean source revision
    - Document a client-only Rust/wasm verification path that does not require
      starting unrelated services

13. Make restore drills a release gate.
    - Restore from backup into a clean environment
    - Verify account, character, guild, and bank data
    - Record drill result before public release

14. Add a production-shaped staging and upgrade-compatibility gate.
    - Previous supported Rust/Bevy client against the candidate server
    - Candidate Rust/Bevy client against the previous server where supported
    - Rolling deployment and graceful session drain
    - Database migration while the previous release is still running
    - Rollback after a failed application release or migration

15. Add a data and content validation pipeline.
    - Broken map exits and unreachable spawn points
    - Invalid or duplicate object, NPC, spell, recipe, and drop references
    - Client/server asset-hash mismatches
    - Missing map trigger data required for roof hiding and other client-side
      map presentation rules
    - World-pack and client-build version compatibility
    - Fail release builds with actionable diagnostics

Exit criteria:

- A release can be built and deployed from automation.
- Backups and restores are documented and tested.
- HTTPS/WSS and static asset delivery are production-ready.
- Pre-public soak has a documented pass/fail threshold.
- Toolchain verification catches local setup drift before build/test commands.
- Restore drills pass before a public release is cut.
- Staging proves supported Rust/Bevy client-server combinations, rolling
  deploy, migration, drain, and rollback behavior.
- Invalid world data or incompatible client/server assets cannot enter a
  release artifact.

## Phase 7: Rust/Bevy Client Product

Goal: make the Rust/Bevy browser-wasm and native client releasable as a product,
not only playable as a technical client. All production game UI and workflow
state live in Bevy; JavaScript remains a narrow browser-capability adapter, and
the old TypeScript client is neither a runtime dependency nor an acceptance
gate.

Work:

1. Add live-backend Rust/Bevy E2E for existing account and lobby flows.
   - Register or log in through the real browser API
   - Create a character through the lobby
   - Launch the character and receive session credentials
   - Reach the gameplay/reconnect-ready state from those credentials

2. Prove Rust protocol, model, and Bevy workflow correctness.
   - Clean formatting, clippy, native tests, wasm tests, and production build
   - Shared packet fixtures and fuzzing
   - Model/state-transition tests
   - Visual fixtures
   - Browser E2E smoke coverage

3. Make the Bevy UI reflect authoritative server state.
   - Authoritative party panel
   - Authoritative clan panel
   - Responsive layout passes
   - Live-backend E2E for party snapshots
   - Live-backend E2E for clan details/news/online state

4. Complete the remaining Rust/Bevy account surface.
   - Google auth endpoint and flows
   - Google-only and linked-account support
   - Manual stat allocation during character creation if product scope
     requires it

5. Add live-backend E2E for social chat streams.
   - Party chat
   - Guild chat
   - Faction chat
   - Service/system channel separation

6. Clarify and implement custom map/quest markers if still in scope.
   - Keep existing minimap/world markers if that is enough
   - Add custom user or quest markers only with explicit product approval

7. Make supported languages first-class.
   - Locale definitions
   - Translation extraction
   - Locale preference and persistence
   - Unicode and IME coverage

8. Make the Rust/Bevy client releasable.
   - Supported browser matrix
   - Shared protocol contract tests
   - Deterministic browser harness
   - Reconnect, cache, and asset failure handling
   - Visual baseline discipline
   - Client telemetry and performance budgets

9. Add Rust/server packet contract fixtures shared in CI.
   - Packet examples shared by server and client tests
   - Contract failures reported before browser E2E runs

10. Add visual regression screenshots for release-critical browser surfaces.
   - World rendering
   - In-world labels
   - NPCs and objects
   - Inventory
   - Bank and trade panels

11. Add asset, cache, and version mismatch recovery tests.
   - Stale world pack
   - Missing asset indices
   - Changed client build hash
   - Reload/retry paths

12. Add client accessibility and performance release gates.
    - Keyboard-only navigation
    - Screen-reader labels and announcements
    - Automated color-contrast checks
    - Reduced-motion support
    - Explicit responsive/mobile support policy
    - Asset-size, startup-time, and frame-time budgets
    - Low-bandwidth and degraded-network coverage

13. Replace presentation-ready server prose with typed semantic events for the
    modern protocol. *(Rust/Bevy: W-0069 and the owning workflow tasks.)*
    - Send a stable event/reason key plus typed parameters for gameplay,
      commerce, inventory, spell, quest, party, guild, faction, moderation, and
      connection outcomes
    - Localize in the client; do not require the server to choose Spanish,
      English, or Portuguese presentation text for the Rust/Bevy path
    - Keep an explicitly tested legacy text adapter only where an old protocol
      contract still requires one
    - Define severity, channel, accessibility announcement behavior, and a
      safe fallback for an unknown key
    - Extract and audit remaining hard-coded player-facing server strings

Exit criteria:

- Rust/Bevy account, lobby, character creation, and launch flows have
  live-backend E2E coverage.
- Rust/Bevy state is driven by authoritative server packets; fixture/gallery
  data cannot act as production authority.
- Browser-wasm E2E and visual checks cover the release-critical flows, while
  native builds share the same Bevy UI and state paths.
- Shared packet fixtures protect Rust/server protocol compatibility in CI.
- Asset and cache mismatch recovery is covered by tests.
- Supported browser surfaces pass the accessibility checks and stay within
  documented asset, startup, and frame-time budgets.
- Player-facing modern-protocol outcomes are semantic and localizable, with no
  dependency on the old TypeScript client.

## Phase 8: Optional Legacy And Multi-Realm

These are real product items, but they are not prerequisites for the next
backend or Rust/Bevy release.

Work:

1. If clan relations are re-enabled, implement live guild alliance and peace
   proposal flows.
2. If guild elections are re-enabled, implement live election and democratic
   succession.
3. Add explicit regional realm support.
   - Realm architecture
   - Backend realm selection
   - Rust/Bevy realm selection
   - Realm-aware monitoring
   - Controlled transfer policy

Exit criteria:

- Optional legacy systems have explicit product approval.
- Multi-realm design is documented before implementation starts.

## Phase 9: Product Research And Future Ideas

Goal: continuously discover, compare, and validate ideas for what the game
should become after the committed roadmap is healthy.

This phase is intentionally exploratory and does not block a release. Research
items are not implementation commitments until they have an explicit product
decision and are promoted into a delivery phase.

Work:

1. Maintain a source-backed inventory of possible game features.
   - Official Argentum Online documentation and source
   - Player feedback, support requests, and community discussions
   - Comparable MMORPGs and online social games
   - Internal ideas, prototypes, and technical opportunities

2. Identify player problems before selecting solutions.
   - New-player confusion and early abandonment
   - Missing short-, medium-, and long-term goals
   - Solo, group, guild, PvE, PvP, economy, and social needs
   - International access, latency, language, and accessibility barriers

3. Write a short research brief for each serious candidate.
   - Player problem and target audience
   - Proposed experience and core gameplay loop
   - Dependencies and systems it can reuse
   - Engineering, content, moderation, and operating costs
   - Economy, balance, abuse, and pay-to-win risks
   - Success metrics and smallest useful experiment

4. Validate promising ideas before full implementation.
   - Paper designs and data-model reviews
   - UI mockups and disposable prototypes
   - Focused technical spikes for the highest-risk assumptions
   - Staging playtests and structured player feedback
   - Telemetry review where production evidence exists

5. Review and rank candidates using consistent criteria.
   - Player value and long-term retention
   - Repeatable goals and social coordination
   - Content leverage per developer hour
   - Fit with the existing world, economy, and technical architecture
   - Accessibility, internationalization, safety, and moderation impact
   - Ongoing infrastructure and support cost

6. Give every reviewed idea an explicit outcome.
   - Promote accepted ideas into a scoped roadmap phase
   - Keep uncertain ideas in research with a named validation question
   - Defer ideas whose prerequisites do not exist yet
   - Record why rejected ideas should not be pursued

7. Revisit supporter and monetization ideas separately from gameplay access.
   - Prefer cosmetics, identity, account organization, and communication tools
   - Keep worlds, quests, destinations, classes, and competitive power free
   - Document recurring service cost and entitlement behavior
   - Review downgrade safety and abuse cases before launch

Initial research inputs:

- `research/post-parity-game-mechanics.md`
- `research/wiki-patreon-feature-audit.md`
- `research/ui-ux/runescape-ui-ux.md`

Exit criteria for promoting an idea:

- The player problem, intended audience, and expected value are documented.
- The smallest useful version and its dependencies are understood.
- Economy, balance, abuse, moderation, accessibility, and operating risks have
  been reviewed where relevant.
- The idea has measurable success criteria and a validation plan.
- A clear accept, defer, or reject decision is recorded.
- Accepted work is moved into a concrete implementation phase before coding
  begins.
