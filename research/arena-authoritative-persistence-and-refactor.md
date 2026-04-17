# Arena Authoritative Persistence And Refactor Research

Goal: keep the current runtime model that works, while making the backend safer
to operate and easier to change.

The arena server has a good foundation: one GenServer owns one map, gameplay
state is serialized through that mailbox, and domain modules now handle much of
the logic that used to live in large god modules. The next refactors should
preserve that model. The main objective is not to make everything async. The
objective is to keep the game loop responsive while preserving authoritative,
durable player state.

## Current Decision

The current direction is intentionally conservative:

- While a player is online, live in-memory state is authoritative.
- The database is authoritative when a player is offline, and at explicit
  durable commit boundaries while they are online.
- Autosave is a best-effort snapshot path, not the commit point for economy or
  permission changes.
- Graceful cleanup/logout is the strongest save boundary.
- Bank, trade, inventory/equipment durability, guild membership/invites/
  leadership/relations, and other economy-sensitive or permission-sensitive
  writes stay sync-first by default.
- Do not introduce write-behind caches for money, items, or permissions.
- Ordered async writers, ledgers, or stronger queueing are later options only
  if telemetry proves the sync-first design is too slow.

## VB6 Reference

The original VB6 server is useful as a reference for authority boundaries, but
not as a template for durability guarantees:

- `modUserAutoSave.MaybeRunUserAutoSave` periodically scanned logged users and
  attempted saves within a time budget.
- `SaveUser` and `SaveCharacterDB` persisted main character state, spells,
  inventory, bank, skills, pets, quests, and related durable fields on save and
  logout.
- `modDatabase.Execute` and `ExecutePreparedBankSave` used
  `Command.Execute(..., adAsyncExecute)`, which reduced blocking but did not
  guarantee DB completion when the call returned.

So the part worth preserving is: online gameplay authority lived in memory. The
part we do not need to copy is: important DB writes being dispatched
asynchronously without strong completion semantics.

## Current Baseline

What is already good:

- MapServer is the live authority for a single map.
- Mailbox ordering gives deterministic gameplay state transitions.
- Protocol, arena, gateway, and persistence apps have useful app-level
  boundaries.
- Arena map logic has started moving into focused modules.
- `Arena.Map.State` now makes map state fields explicit.
- Arena tests now have a shared `%Arena.Map.State{}` factory path.

What still creates risk:

- Economy-sensitive DB writes can block gameplay if they run inside MapServer.
- Fire-and-forget saves can lose data or fail without enough visibility.
- Gateway command handling is still too large and mixes unrelated domains.
- Persistence failures, queue depth, map tick latency, and session lifecycle are
  not observable enough.

## Design Principles

1. Keep server authority.
- The client must never be trusted for economy, movement, combat, or inventory
  state.

2. Keep MapServer authoritative for live online gameplay.
- MapServer decides whether an action is legal and applies the in-memory state
  transition in mailbox order.

3. Avoid blocking the map loop on infrastructure where the semantics allow it.
- DB latency, retries, and transient outages should not freeze combat, movement,
  NPC ticks, or chat for everyone on the map. But explicit synchronous commit
  points are still correct for authoritative economy and permission changes.

4. Keep authoritative writes sync-first.
- Logout/cleanup, bank, trade, inventory/equipment durability, guild
  membership/invites/leadership/relations, and other economy-sensitive writes
  should commit explicitly and synchronously by default.

5. Async is for snapshots and other intentional best-effort paths.
- Autosave can be async and coalesced because it is a snapshot path. It is not
  the authoritative commit boundary for money, items, or permissions.

6. Make failure explicit.
- Failed saves should become logs, telemetry, and operator-visible state, not
  silent task failures.

7. Preserve VB6 parity.
- Refactors should not change legal gameplay behavior unless a deliberate
  parity decision is made.

## Research Questions

1. Which state is live-authoritative only, and which state must be durable before
   crossing a boundary?

2. Which DB writes are true authoritative commit points, and which are only
   snapshots?

3. Which boundaries require a synchronous save or flush barrier?

4. How can handler modules return state transitions plus effects without a large
   rewrite?

5. What test helpers are needed so tests use the same state shapes as
   production?

6. What telemetry proves the refactor improved reliability rather than only code
   shape?

## Persistence Problem

Inline DB writes inside MapServer couple gameplay latency to database latency.
If a bank deposit waits on Postgres for 500ms, the map process cannot process
movement, combat, chat, NPC AI, regen, visibility updates, or other players'
actions during that time.

The opposite extreme, fire-and-forget async writes, is also unsafe. If a bank
deposit succeeds in memory but the DB write disappears, the player can lose an
item. If the write is retried without idempotency, the player can duplicate an
item.

The target is clearer:

- MapServer remains the live authority while a player is online.
- The DB is authoritative when a player is offline, and at explicit durable
  boundaries while they are online.
- Autosave remains a snapshot path.
- Cleanup/logout remains the strongest explicit save boundary.
- Critical economy or permission changes commit explicitly and synchronously.
- Operators can see persistence latency, failures, and shutdown/flush behavior.

## Persistence Options

### Option A: Sync-First Authoritative Boundaries

Pros:

- Clear commit point.
- Easy to reason about when correctness matters.
- Failure can reject or roll back the action immediately.
- Matches the desired boundary for economy and permission changes.

Cons:

- If left inline in hot map handlers, slow DB writes can still stall maps.
- Requires careful extraction of persistence modules so correctness does not rely
  on ad hoc `Repo` calls spread through gameplay code.

This is the recommended near-term model for authoritative writes.

### Option B: Fire-And-Forget Tasks

Pros:

- Easy to add.
- Removes blocking from the map loop.

Cons:

- Not authoritative enough for economy state.
- Failures can be silent.
- No natural operation ordering.
- Retries can duplicate effects unless every write is idempotent.
- Shutdown can drop in-flight writes.

This should not be used for bank, inventory, gold, trade, auction, guild
membership/permission changes, or character ownership changes.

### Option C: Ordered Writers For Snapshot Or Later Optimization

Pros:

- Good fit for coalesced autosave snapshots.
- Can reduce repeated write pressure for non-authoritative save paths.
- Provides a cleaner later upgrade path if sync-first critical writes prove too
  slow under real telemetry.

Cons:

- Adds lifecycle and supervision complexity.
- Can blur authority if introduced too early or used for economy state by
  default.
- Still does not solve cross-character atomicity on its own.

This is acceptable for autosave or other explicitly best-effort paths. It is
not the first answer for economy writes.

### Option D: Idempotent Operation Ledger Later

Pros:

- Every operation has an `op_id`.
- Retrying the same operation cannot duplicate items or gold.
- Crashes can recover from unapplied operations.
- Operators can inspect operation status.

Cons:

- Requires schema and transaction design.
- Requires deciding operation granularity.
- More work than simple snapshot saves.

This is a later option if sync-first boundaries plus telemetry show a real need
for more durable replay/retry infrastructure.

### Option E: Full Event Sourcing

Pros:

- Complete history of state transitions.
- Strong auditability.
- Excellent replay/debug potential.

Cons:

- Large architecture shift.
- Requires projection, compaction, migration, and operational discipline.
- Overkill before the current persistence risks are isolated.

This is not the recommended near-term move.

## Recommended Persistence Architecture

Start with explicit sync-first boundaries and one clearly scoped snapshot path.

Core rules:

- Load durable state from DB at login/reconnect.
- While the player is online, use live in-memory entity state as authority.
- Do not consult the DB on every gameplay action.
- Validate actions in memory first.
- For authoritative economy and permission changes, commit through an explicit
  persistence boundary before finalizing the durable transition.
- Keep autosave separate as a coalesced best-effort snapshot path.
- Keep graceful cleanup/logout as the strongest save boundary.

Recommended module boundaries:

- `AoTcpGateway.SessionPersistence.cleanup/1`
  - authoritative final save on graceful disconnect
- `AoTcpGateway.AutosaveWriter`
  - coalesced snapshot path only
- `Arena.BankPersistence`
  - explicit bank load and commit APIs
- `Arena.TradePersistence`
  - explicit trade commit APIs
- `Arena.GuildPersistence`
  - explicit durable guild membership/leadership/relation writes

Recommended boundary shape:

```elixir
{:ok, result} = BankPersistence.deposit_item(...)
{:ok, result} = TradePersistence.commit(...)
{:ok, result} = GuildPersistence.update_membership(...)
```

Optional later additions, only if telemetry proves the sync-first design is too
slow:

- ordered autosave writers with stronger flush/queue visibility
- idempotent operation ledger for especially sensitive multi-step economy flows
- more advanced recovery/replay infrastructure

## Persistence Invariants

Bank, inventory, gold, trade, auction, and item rewards must satisfy these:

- No item or gold duplication after retry.
- No item or gold loss after worker crash.
- Operations for one character are persisted in order.
- Cross-character operations are atomic or compensating behavior is explicit.
- Logout cannot complete while sensitive writes are unflushed.
- Map transfer cannot lose the source map's final state.
- Server shutdown waits for pending writes or records them for recovery.
- Failed operations are visible to logs, telemetry, and operator tooling.

## Flush Barriers

Use a flush barrier when crossing a boundary where stale durable state can create
loss or duplication.

Recommended barriers:

- logout
- map transfer
- trade completion
- bank close, if a bank session holds dirty in-memory bank state
- auction commit
- guild/faction rank or reward changes
- character deletion
- server shutdown

Do not flush on every movement, chat, or combat tick. Those should be snapshots
or periodic saves, not blocking gameplay operations.

## Persistence Migration Plan

### Phase 1: Classify Writes

Audit all `GameBackend.*` calls from arena and gateway.

Classify each write as:

- snapshot save
- idempotent operation
- synchronous authorization check
- cross-character transaction
- admin/audit event

Expected result: a table of write sites, risks, and target persistence pattern.

### Phase 2: Lock The Hard Sync Boundaries

Start with the operations where ambiguity is unacceptable.

Target:

- graceful cleanup/logout is the strongest save point
- guild membership/invite/leadership/relation writes stop using
  fire-and-forget tasks
- bank persistence moves behind explicit sync APIs
- trade durability gets a single explicit commit boundary
- inventory/equipment durability paths are classified and made explicit

### Phase 3: Extract Persistence Modules

Extract small persistence boundaries before adding more infrastructure:

- `BankPersistence`
- `TradePersistence`
- `GuildPersistence`
- any remaining inventory/equipment durability helpers

### Phase 4: Autosave As Snapshot

Autosave can stay async because it is not the authoritative commit point.

Target:

- one coalesced snapshot writer per character at most
- latest-snapshot-wins semantics
- explicit telemetry for submit/start/ok/error/flush
- cleanup flushes pending snapshots before the final save

### Phase 5: Consider Stronger Async Only If Needed

Only after sync-first boundaries and telemetry are in place:

- decide whether ordered writers are still needed outside autosave
- decide whether any economy path truly needs an idempotent operation ledger
- keep these as explicit upgrades, not the default model

## Full Refactor Roadmap

### Workstream 1: Test State Migration

Status: complete. Arena tests now use a shared map-state factory instead of
partial raw maps.

Shared factory:

```elixir
Arena.Test.MapStateFactory.map_state(opts)
```

It should return `%Arena.Map.State{}` and support:

- players
- sessions
- npcs
- occupancy map
- meta overrides
- ground items
- counters
- visibility mode
- triggers
- GM blocked tiles

Migrate tests away from raw map states.

Priority files:

- `hunger_thirst_test.exs`
- `interval_timer_audit_test.exs`
- `timer_clamp_parity_test.exs`
- `gm_adversarial_test.exs`
- `spell_effect_golden_test.exs`
- `bug_regression_test.exs`
- `economy_security_test.exs`
- `exploit_adversarial_test.exs`
- `invisibility_edge_cases_test.exs`
- `pet_taming_parity_test.exs`
- `npc_ai_test.exs`
- `trainer_weather_test.exs`

Also remove old state fields such as `floor_items` and `next_floor_id` from map
state fixtures.

### Workstream 2: State Helpers

Add focused helpers to `Arena.Map.State` after tests use the struct:

```elixir
State.put_player(state, char_id, entity)
State.update_player(state, char_id, fun)
State.delete_player(state, char_id)
State.put_npc(state, instance_id, npc)
State.update_npc(state, instance_id, fun)
State.put_ground_items(state, ground_items)
State.put_meta(state, key, value)
```

Goal: reduce repeated nested `Map.put` code and centralize state invariants.

### Workstream 3: Map Meta Struct

`state.meta` is still a raw map. It contains map name, terrain, flags, exits,
weather, layers, objects, NPC definitions, and trigger metadata.

Introduce:

```elixir
%Arena.Map.Meta{}
```

This should happen after tests use `%Arena.Map.State{}`. Otherwise the migration
will multiply raw-map fixture failures.

### Workstream 4: Gateway Session State Struct

The gateway session state should get the same treatment as map state.

Introduce:

```elixir
%AoTcpGateway.Session.State{}
```

Benefits:

- compile-time field checks
- safer command refactors
- less accidental root-level map drift
- easier testing of command handlers

### Workstream 5: Gateway Command Split

Split large command handling by domain:

- movement commands
- combat commands
- inventory commands
- bank commands
- trade commands
- social commands
- party/guild/faction commands
- GM commands
- account/session commands

Target shape:

```elixir
CommandRouter.dispatch(command, payload, session_state)
```

Each domain module should own command validation and calls into arena APIs.

### Workstream 6: Handler Effects

Move gradually toward handlers returning state plus effects where it removes real
coupling. An effect is a small data description of work to perform after the
state transition, such as sending a packet, enqueueing persistence, or writing
an audit event.

Example:

```elixir
{:ok, state, effects}
```

Effect examples:

- send packet
- broadcast packet
- request persistence boundary
- enqueue autosave snapshot
- emit audit event
- schedule timer
- notify session state

Performance guardrail: do not introduce effects in tight gameplay loops by
default. Keep movement, heading updates, visibility fanout, NPC AI inner loops,
regen/buff ticks, and hot combat loops direct unless profiling proves the
change is safe and useful. Small effect lists are cheap for low-frequency
control-plane actions, but per-recipient or per-tick effect expansion can create
unnecessary allocation and dispatch overhead.

Use effects first where correctness, observability, or test isolation matter
more than micro-overhead:

- persistence operations
- GM audit events
- bank and trade commit boundaries
- autosave and logout
- auction and guild/faction durable changes
- account/session lifecycle

Do this incrementally. The first target is not a global handler rewrite; it is
removing inline persistence/audit coupling from sensitive low-frequency paths.

### Workstream 7: Observability

Add telemetry before and during the persistence migration.

Events:

- packet received
- command handled
- map handler duration
- map mailbox length
- regen tick duration
- NPC AI tick duration
- DB write latency
- persistence queue depth
- persistence retry count
- persistence failure
- flush barrier latency
- autosave latency
- session connect/disconnect

This turns refactoring into measurable reliability work.

### Workstream 8: Graceful Shutdown

Shutdown should:

- stop accepting new sessions
- notify sessions
- stop new sensitive operations
- flush dirty characters
- drain persistence queues
- record unflushed work if the deadline expires
- stop maps cleanly

This work depends on explicit persistence boundaries and snapshot flush points.

### Workstream 9: Supervision And Recovery

Review restart policy for map processes and persistence workers.

Questions:

- Should crashed maps restart automatically?
- How do players reconnect after a map crash?
- What durable state is needed to rebuild a map?
- What happens to pending persistence on crash?

Target: no silent dead map, no stranded sessions, no lost pending writes.

### Workstream 10: Runtime Configuration

Move tunable values to config where appropriate:

- autosave interval
- regen tick interval
- NPC AI tick interval
- flood thresholds
- visibility mode
- persistence retry intervals
- flush timeouts
- queue thresholds

Do not move formula constants blindly if they are VB6 parity constants. Those
should remain explicit and tested.

## Suggested Execution Order

1. Migrate arena tests to use `%Arena.Map.State{}`. DONE.
2. Remove old map-state fixture fields and root-level meta assertions. DONE.
3. Add `Arena.Map.State` helper functions.
4. Audit all DB write sites.
5. Classify each write as authoritative commit, snapshot, or audit/event.
6. Add telemetry around current DB write latency, failure, and map tick
   duration.
7. Replace fire-and-forget guild writes with explicit sync persistence.
8. Define bank persistence boundary.
9. Define trade persistence boundary.
10. Verify logout, cleanup, transfer, and shutdown boundaries.
11. Keep autosave as a coalesced snapshot path.
12. Introduce gateway session state struct.
13. Split gateway command handling.
14. Add handler effects only for low-frequency control-plane paths where they
    remove persistence, audit, or packet-send coupling.
15. Introduce `Arena.Map.Meta`.
16. Harden supervision and recovery.
17. Only then reconsider ordered writers or an operation ledger if telemetry
    proves they are needed.

## Verification Strategy

Required test categories:

- unit tests for state helpers
- explicit persistence-boundary tests for bank, trade, and guild critical paths
- bank deposit/withdraw conservation tests
- trade atomicity tests
- logout flush barrier tests
- map transfer flush barrier tests
- shutdown drain tests
- telemetry smoke tests

Required invariants:

- total gold is conserved except legal mint/burn paths
- item stacks are conserved across inventory, bank, ground, trade, and auction
- a character is present in exactly one map after transfer
- failed persistence cannot silently disappear
- map tick latency remains bounded when DB writes are slow

## Non-Goals

- Do not replace the one-GenServer-per-map model.
- Do not introduce full event sourcing as the first persistence refactor.
- Do not trust the client for any economy or movement authority.
- Do not make economy writes fire-and-forget.
- Do not convert hot movement, visibility, NPC AI, regen, or combat inner loops
  to effect lists by default.
- Do not change VB6 gameplay behavior as part of infrastructure cleanup.
- Do not hide persistence failures to preserve a smooth UX.

## Decision Summary

The recommended path is conservative:

1. Keep online gameplay authority in memory.
2. Treat autosave as a snapshot path, not the economy commit path.
3. Make logout/cleanup, bank, trade, inventory/equipment durability, and guild
   permission changes explicit sync-first boundaries.
4. Add telemetry and graceful shutdown so failures are visible and recoverable.
5. Consider stronger async or ledger machinery only after the sync-first model
   is correct and measurable.

This gives the backend stronger correctness and better operational behavior
without changing the core arena runtime model.
