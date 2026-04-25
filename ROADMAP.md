# Argentum Roadmap

## Current State

- Backend parity is effectively closed except for one scoped partial item:
  - `[41]` remaining outbound packet wiring for `blind_no_more`,
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

1. ~~Finish the `Arena.Map.Healing` effects rollout.~~ Done. `[69-71]`
   - All four handlers migrated; runner routes through `AoSession.Egress`;
     no raw effect tuples at call sites

2. ~~Stabilize the effects pattern after `Healing`.~~ Done. `[69-71]`
   - `Effects.run_handler/2` adapter extracted; convention documented in
     `Arena.Map.Effects` moduledoc; `Healing` is the reference implementation

3. `ACTIVE` Migrate `Arena.Map.NpcInteraction` to the effects contract. `[71]`
   - Only migrate behavior that benefits from explicit effects
   - Do not mix unrelated cleanup into the same commits
   - Follow the `Healing` reference: handlers return `{:ok, state, effects}`,
     casts use `Effects.run_handler/2`, no session pid in handlers

4. Migrate `Arena.Map.Social` or `Arena.Map.InventoryHandlers` to the effects contract. `[71]`
   - Pick the module with the cleaner blast radius first

5. Leave `Arena.Map.CombatHandlers` for last. `[71]`
   - Only start after the pattern is proven on simpler modules

6. Close the last partial parity item. `[41]`
   - Wire `blind_no_more`
   - Wire `dumb_no_more`
   - Wire `work_request_target`
   - Wire `stun_start`
   - Do not mark `[41]` done until call sites exist, not just encoder clauses

### Proof And Repeatability

7. Build a deterministic scenario harness. `[51 prerequisite]`
   - Synthetic maps
   - Frozen clock
   - Background ticks disabled unless explicitly enabled
   - Scripted packet or handler drivers
   - Exact state and effect assertions

8. Add a high-load bot benchmark. `[49]`

9. Add a load and soak gate. `[50]`

10. Define the exact parity-gate required suites. `[51]`

11. Build and version a real VB6 packet-capture corpus. `[52]`
    - `BLOCKED` on Windows/VB6 environment

12. Add packet replay coverage for login, character creation, and bootstrap. `[53]`
    - `BLOCKED` on `[52]`

13. Add packet replay coverage for movement, transfer, chat, and service requests. `[54]`
    - `BLOCKED` on `[52]`

14. Add packet replay coverage for inventory, equip/use, combat, spells, and death. `[55]`
    - `BLOCKED` on `[52]`

15. Add packet replay coverage for bank, trade, party, guild, faction, reconnect, and logout. `[56]`
    - `BLOCKED` on `[52]`

### Observability And Operations

16. Finish telemetry wiring where coverage still matters. `[59]`
    - Remaining producer migration beyond `Arena.Map.Visibility`
    - Any missing bank or guild event coverage
    - Any missing autosave-task failure or disconnect coverage

17. Finish metrics and dashboards. `[60]`
    - Backpressure queue depth
    - Disconnect reasons
    - `send_pend`
    - Autosave task failures
    - Egress shed and coalesce counters

18. Add alerts. `[61]`
    - Sustained shedding
    - Forced backpressure disconnects

19. Add runtime admin tools for map and process inspection and control. `[62]`

20. Add admin lookup for accounts, characters, and online players. `[63]`

21. Add admin moderation, world, log, and health actions. `[64-66]`

### Security And Hardening

22. Keep the exploit and parity audit executable. `[57]`

23. Add anti-cheat hardening. `[58]`

### Performance And Backend Architecture

24. Replace NPC aggro full scans with spatial-grid queries. `[67]`
    - This is the next major runtime win after the effects pattern is proven

25. Replace pet target full scans with bounded or indexed lookup. `[68]`

26. Split `guild_server.ex` into focused modules. `[72]`

27. Pre-resolve `.dat` references at load time where hot-path lookups still repeat. `[73]`

28. Unify interest management for players, NPCs, and ground items. `[74]`

29. Add runtime-tunable settings for intervals, rates, and formula constants. `[75]`

30. Finish the long-term persistence boundary cleanup. `[70 follow-up]`
    - One explicit character write path
    - One explicit guild write path
    - Clear ordering, retry, and failure semantics
    - Keep guild writes synchronous until a separate UX/semantics design is approved

### Release And Deployment

31. Add release artifacts, deployment pipeline, and backup/restore runbook. `[76]`

32. Add TLS for HTTPS and WSS. `[77]`

33. Add asset CDN and static-delivery strategy. `[78]`

34. Add automated backups and database connection-pool tuning. `[79]`

35. Define the live database migration strategy. `[80]`

36. Add pre-public scripted load and soak runs. `[81]`

## Completed Or Mostly Closed Work

1. Maintenance discipline remains ongoing. `[1-2]`
2. Backend parity work is done except for `[41]`. `[3-40]`
3. Proof foundations before the current gate are done. `[42-48]`
4. Backpressure foundation, Prometheus `/metrics`, slow-client soak profile,
   monitoring runbook, and autosave supervision are landed.

## Future Product Work

These are real roadmap items, but they are not the next backend priorities.

### Optional Legacy Systems

37. If clan relations are re-enabled, implement live guild alliance and peace proposal flows. `[82]`

38. If guild elections are re-enabled, implement the live election and democratic succession system. `[83]`

### Browser Proof

39. Prove browser protocol and reducer correctness. `[84-101]`
    - Clean `typecheck` and `build`
    - Shared packet fixtures and fuzzing
    - Reducer/state tests
    - Visual fixtures
    - Browser E2E smoke coverage

### Frontend Product And UX

40. Make the browser UI reflect authoritative server state. `[102-115]`
    - Authoritative party and clan panels
    - Distinct faction, guild, and party chat streams
    - Responsive layout passes
    - Markers and sound effects if they remain in scope

### Browser Account And Lobby

41. Complete the browser account surface. `[116-121]`
    - Google auth endpoint and flows
    - Google-only and linked-account support
    - Browser stat choices during character creation

### Localization

42. Make supported languages first-class. `[122-133]`
    - Locale definitions
    - Translation extraction
    - Locale preference and persistence
    - Unicode and IME coverage

### Multi-Realm

43. Add explicit regional realm support. `[134-142]`
    - Realm architecture
    - Backend and browser realm selection
    - Realm-aware monitoring
    - Controlled transfer policy

### Browser Hardening And Release

44. Make the browser client releasable. `[143-156]`
    - Supported browser matrix
    - Shared protocol contract tests
    - Deterministic browser harness
    - Reconnect, cache, and asset failure handling
    - Visual baseline discipline
    - Client telemetry and performance budgets
