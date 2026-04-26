# Argentum Roadmap

## Current State

- Backend parity is effectively closed except for one scoped partial item:
  - remaining outbound packet wiring for `blind_no_more`,
    `dumb_no_more`, `work_request_target`, and `stun_start`
- Effects refactor: `Arena.Map.Healing` is fully on the contract.
  - All four handlers (`rest`, `meditate`, `heal`, `resucitate`) return
    `{:ok, state, effects}` and never see a session pid
  - `MapServer` adapter extracted as `Effects.run_handler/2`; the four
    healing casts collapse to one-liners
  - `Helpers.broadcast_character_change/2` now routes through
    `AoSession.Egress.enqueue/2`; the legacy `{:send_raw, _}` shim is no
    longer in the healing path
  - Adversarial test suite landed (constructor robustness, runner
    failure modes, end-to-end MapServer casts proving no `{:send_raw, _}`
    reception)
  - `NpcInteraction` is the next active target
- Backpressure foundation, Prometheus `/metrics`, slow-client soak profile,
  monitoring runbook, and autosave supervision are landed
- Constraint for the effects lane:
  - effects are data
  - the runner is a plain module
  - execution stays inside existing `MapServer` processes
  - do **not** add a new coordinator GenServer

## Linear Execution Plan

### Immediate Backend Work

1. ~~Finish the `Arena.Map.Healing` effects rollout.~~ Done.
   - All four handlers migrated; runner routes through `AoSession.Egress`;
     no raw effect tuples at call sites

2. ~~Stabilize the effects pattern after `Healing`.~~ Done.
   - `Effects.run_handler/2` adapter extracted; convention documented in
     `Arena.Map.Effects` moduledoc; `Healing` is the reference implementation

3. `ACTIVE` Migrate `Arena.Map.NpcInteraction` to the effects contract.
   - Only migrate behavior that benefits from explicit effects
   - Do not mix unrelated cleanup into the same commits
   - Follow the `Healing` reference: handlers return `{:ok, state, effects}`,
     casts use `Effects.run_handler/2`, no session pid in handlers
   - Finish it in this order:
     - pure text and info paths
     - gamble and forgive
     - arena entry via `:transfer`
     - fish delivery, quest NPC click, and subastador click
   - Defer the main `handle_npc_double_click` dispatcher flip until the
     sibling modules it delegates to are also on the effects contract

4. Build a deterministic scenario harness.
   - Synthetic maps
   - Frozen clock
   - Background ticks disabled unless explicitly enabled
   - Scripted packet or handler drivers
   - Exact state and effect assertions

5. Add a parity test DSL and real gameplay fixture factories.
   - High-level helpers like `click_npc`, `use_item`, `cast_spell`,
     `expect_effect`, and `expect_entity`
   - Factories for NPCs, entities, inventory, buffs, and selected-target state
   - Keep parity tests readable and gameplay-shaped instead of mailbox-shaped

6. Add structured state and effect snapshots plus failure diff tooling.
   - Stable serializers for entity, inventory, buffs, and visible state
   - Failure output should show the first meaningful divergence, not raw mailbox noise

7. Standardize RNG control for parity-sensitive tests.
   - Seed or inject RNG for gamble, taming, loot-like, and other random flows
   - Remove seed-sensitive parity noise from the default test lane

8. Add per-flow golden fixtures for core gameplay and service flows.
   - Heal, forgive, gamble, trade, bank, faction enlistment, criminal conversion,
     potions, and other high-drift flows
   - Expected outcomes should live in data, not only handwritten assertions

9. Migrate `Arena.Map.Social` or `Arena.Map.InventoryHandlers` to the effects contract.
   - Pick the module with the cleaner blast radius first

10. Flip `NpcInteraction` dispatcher paths onto the effects contract once its sibling modules are ready.
   - Do not force mixed `{:noreply, state}` and `{:ok, state, effects}`
     returns through the same dispatcher during the transition

11. Leave `Arena.Map.CombatHandlers` for last.
   - Only start after the pattern is proven on simpler modules

12. Close the last partial parity item.
   - Wire `blind_no_more`
   - Wire `dumb_no_more`
   - Wire `work_request_target`
   - Wire `stun_start`
   - Do not mark this done until call sites exist, not just encoder clauses

### Proof And Repeatability

13. Add a high-load bot benchmark.

14. Add a load and soak gate.

15. Define the exact parity-gate required suites.

16. Build and version a real VB6 packet-capture corpus.
    - `BLOCKED` on Windows/VB6 environment

17. Add packet replay coverage for login, character creation, and bootstrap.
    - `BLOCKED` on the VB6 packet-capture corpus task above

18. Add packet replay coverage for movement, transfer, chat, and service requests.
    - `BLOCKED` on the VB6 packet-capture corpus task above

19. Add packet replay coverage for inventory, equip/use, combat, spells, and death.
    - `BLOCKED` on the VB6 packet-capture corpus task above

20. Add packet replay coverage for bank, trade, party, guild, faction, reconnect, and logout.
    - `BLOCKED` on the VB6 packet-capture corpus task above

### Observability And Operations

21. Finish telemetry wiring where coverage still matters.
    - Remaining producer migration beyond `Arena.Map.Visibility`
    - Any missing bank or guild event coverage
    - Any missing autosave-task failure or disconnect coverage

22. Finish metrics and dashboards.
    - Backpressure queue depth
    - Disconnect reasons
    - `send_pend`
    - Autosave task failures
    - Egress shed and coalesce counters

23. Add alerts.
    - Sustained shedding
    - Forced backpressure disconnects

24. Add runtime admin tools for map and process inspection and control.

25. Add admin lookup for accounts, characters, and online players.

26. Add admin moderation, world, log, and health actions.

### Security And Hardening

27. Keep the exploit and parity audit executable.

28. Add anti-cheat hardening.

### Performance And Backend Architecture

29. Replace NPC aggro full scans with spatial-grid queries.
    - This is the next major runtime win after the effects pattern is proven

30. Replace pet target full scans with bounded or indexed lookup.

31. Split `guild_server.ex` into focused modules.

32. Pre-resolve `.dat` references at load time where hot-path lookups still repeat.

33. Unify interest management for players, NPCs, and ground items.

34. Add runtime-tunable settings for intervals, rates, and formula constants.

35. Finish the long-term persistence boundary cleanup.
    - One explicit character write path
    - One explicit guild write path
    - Clear ordering, retry, and failure semantics
    - Keep guild writes synchronous until a separate UX/semantics design is approved

### Release And Deployment

36. Add release artifacts, deployment pipeline, and backup/restore runbook.

37. Add TLS for HTTPS and WSS.

38. Add asset CDN and static-delivery strategy.

39. Add automated backups and database connection-pool tuning.

40. Define the live database migration strategy.

41. Add pre-public scripted load and soak runs.

## Completed Or Mostly Closed Work

- Maintenance discipline remains ongoing.
- Backend parity work is done except for the last partial parity item.
- Proof foundations before the current gate are done.
- Backpressure foundation, Prometheus `/metrics`, slow-client soak profile,
   monitoring runbook, and autosave supervision are landed.

## Future Product Work

These are real roadmap items, but they are not the next backend priorities.

### Optional Legacy Systems

42. If clan relations are re-enabled, implement live guild alliance and peace proposal flows.

43. If guild elections are re-enabled, implement the live election and democratic succession system.

### Browser Proof

44. Prove browser protocol and reducer correctness.
    - Clean `typecheck` and `build`
    - Shared packet fixtures and fuzzing
    - Reducer/state tests
    - Visual fixtures
    - Browser E2E smoke coverage

### Frontend Product And UX

45. Make the browser UI reflect authoritative server state.
    - Authoritative party and clan panels
    - Distinct faction, guild, and party chat streams
    - Responsive layout passes
    - Markers and sound effects if they remain in scope

### Browser Account And Lobby

46. Complete the browser account surface.
    - Google auth endpoint and flows
    - Google-only and linked-account support
    - Browser stat choices during character creation

### Localization

47. Make supported languages first-class.
    - Locale definitions
    - Translation extraction
    - Locale preference and persistence
    - Unicode and IME coverage

### Multi-Realm

48. Add explicit regional realm support.
    - Realm architecture
    - Backend and browser realm selection
    - Realm-aware monitoring
    - Controlled transfer policy

### Browser Hardening And Release

49. Make the browser client releasable.
    - Supported browser matrix
    - Shared protocol contract tests
    - Deterministic browser harness
    - Reconnect, cache, and asset failure handling
    - Visual baseline discipline
    - Client telemetry and performance budgets
