# Arena Authoritative Persistence And Refactor Research

Goal: keep the current runtime model that works, while making the backend safer
to operate and easier to change.

The arena server has a good foundation: one GenServer owns one map, gameplay
state is serialized through that mailbox, and domain modules now handle much of
the logic that used to live in large god modules. The next refactors should
preserve that model. The main objective is not to make everything async. The
objective is to keep the game loop responsive while preserving authoritative,
durable player state.

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

3. Do not block the map loop on infrastructure when avoidable.
- DB latency, retries, and transient outages should not freeze combat, movement,
  NPC ticks, or chat for everyone on the map.

4. Do not use naive async write-behind for economy state.
- Bank, inventory, gold, trade, auction, and guild/faction rewards need ordered,
  idempotent, observable persistence.

5. Make failure explicit.
- Failed saves should become retry state, metrics, logs, and operator-visible
  alerts, not silent task failures.

6. Preserve VB6 parity.
- Refactors should not change legal gameplay behavior unless a deliberate
  parity decision is made.

## Research Questions

1. Which state is live-authoritative only, and which state must be durable before
   crossing a boundary?

2. Which DB writes are safe as snapshots, and which must be persisted as
   idempotent operations?

3. What boundaries require a flush barrier?

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

The target is stronger:

- MapServer remains the live authority.
- Persistence is ordered per character or account.
- Every sensitive operation has an idempotency key.
- Failed writes retry with backoff.
- Logout, transfer, trade completion, and shutdown can wait for pending writes.
- Operators can see pending, failed, and retrying persistence work.

## Persistence Options

### Option A: Keep Inline DB Writes

Pros:

- Simple control flow.
- DB confirmation happens before the handler returns.
- Easy to reason about in small cases.

Cons:

- Slow DB writes freeze the entire map.
- DB outages turn gameplay handlers into backpressure points.
- Retries and failure tracking are usually ad hoc.
- Testing handlers requires DB setup or mocks.

Use only for operations that truly must synchronously consult durable state
before the live state can proceed.

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

This should not be used for bank, inventory, gold, trade, auction, or character
ownership changes.

### Option C: Ordered Character Writer

Pros:

- One writer process per character gives per-character ordering.
- MapServer enqueue stays fast.
- Flush barriers are possible.
- Retries and queue depth are observable.

Cons:

- Requires supervision, registry, retry logic, and lifecycle management.
- Cross-character operations still need explicit transaction design.

This is a good first production target.

### Option D: Idempotent Operation Ledger

Pros:

- Every operation has an `op_id`.
- Retrying the same operation cannot duplicate items or gold.
- Crashes can recover from unapplied operations.
- Operators can inspect operation status.

Cons:

- Requires schema and transaction design.
- Requires deciding operation granularity.
- More work than simple snapshot saves.

This should be combined with ordered character writers for economy-sensitive
state.

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

Use ordered per-character writers plus an idempotent operation ledger.

Core components:

- `Arena.Persistence.CharacterWriterSupervisor`
- `Arena.Persistence.CharacterWriterRegistry`
- `Arena.Persistence.CharacterWriter`
- `GameBackend.CharacterOps`
- `character_persistence_ops` table

Recommended API:

```elixir
CharacterWriter.enqueue(character_id, op)
CharacterWriter.flush(character_id, timeout)
CharacterWriter.status(character_id)
```

Operation shape:

```elixir
%{
  id: op_id,
  character_id: character_id,
  type: :bank_deposit,
  payload: %{
    inventory_slot: slot,
    bank_slot: bank_slot,
    item_id: item_id,
    amount: amount
  },
  map_id: map_id,
  inserted_at: now
}
```

Ledger table shape:

```text
character_persistence_ops
- op_id uuid primary key
- character_id bigint not null
- type text not null
- payload jsonb not null
- status text not null
- attempts integer not null default 0
- inserted_at timestamp not null
- applied_at timestamp
- last_error text
```

Persistence transaction:

```elixir
Repo.transaction(fn ->
  insert_operation_if_absent!(op)

  unless operation_applied?(op.id) do
    apply_operation!(op)
    mark_operation_applied!(op.id)
  end
end)
```

MapServer state extension:

```elixir
%Arena.Map.State{
  pending_persistence: %{
    character_id => MapSet.new([op_id])
  }
}
```

Writer notifications:

```elixir
{:persistence_committed, character_id, op_id}
{:persistence_failed, character_id, op_id, reason}
```

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
- bank close, if bank state is persisted operation-by-operation
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

### Phase 2: Bank First

Bank is the best starting point because it is economy-sensitive and currently
easy to reason about.

Target:

- deposit emits a `:bank_deposit` operation
- withdraw emits a `:bank_withdraw` operation
- gold deposit emits a `:bank_gold_deposit` operation
- gold withdraw emits a `:bank_gold_withdraw` operation
- operations are idempotent
- logout flushes pending bank ops

### Phase 3: Inventory And Ground Items

Migrate pickup, drop, equip, unequip, consume, loot, and stack split/merge.

Important rule: persistence should represent the operation that happened, not
only the final bag snapshot, for economy-sensitive paths.

### Phase 4: Trade And Auction

Trade and auction require cross-character or global ordering.

Trade target:

- trade commit emits one atomic operation containing both sides
- either both players receive the exchange or neither does
- retrying the trade op does not duplicate either side

Auction target:

- bids and settlement use idempotent operations
- item ownership changes exactly once
- failed settlement is visible and recoverable

### Phase 5: Autosave And Character Snapshots

Autosave can be snapshot-based.

Target:

- supervised save worker
- retry with backoff
- dirty character tracking
- telemetry for save latency and failure
- graceful shutdown drain

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
- enqueue persistence operation
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

This work depends on explicit dirty state and persistence queues.

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
5. Add telemetry around current DB write latency and map tick duration.
6. Implement ordered character writer infrastructure.
7. Add idempotent operation ledger.
8. Migrate bank persistence first.
9. Add logout and shutdown flush barriers.
10. Migrate inventory, trade, and auction persistence.
11. Introduce gateway session state struct.
12. Split gateway command handling.
13. Add handler effects only for low-frequency control-plane paths where they
    remove persistence, audit, or packet-send coupling.
14. Introduce `Arena.Map.Meta`.
15. Harden supervision and recovery.

## Verification Strategy

Required test categories:

- unit tests for state helpers
- unit tests for character writer ordering
- idempotency tests for duplicate operation replay
- crash/restart tests for pending operations
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
- retrying a persistence operation cannot duplicate effects
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

1. Make tests use the same map state shape as production.
2. Keep MapServer as the live gameplay authority.
3. Move sensitive persistence behind ordered, idempotent writers.
4. Use flush barriers at boundaries where durable state must catch up.
5. Add telemetry and graceful shutdown so failures are visible and recoverable.

This gives the backend stronger correctness and better operational behavior
without changing the core arena runtime model.
