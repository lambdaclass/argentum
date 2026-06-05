# Argentum Roadmap

This file tracks remaining work only. Completed work belongs in
`CHANGELOG.md`.

Work inside a phase can happen in parallel, but phases should close in order
because later phases depend on the proof, tooling, or operational surface built
earlier.

## Current Priority

Close Phase 1. The immediate priority is the source-data parity tail, the
last open drift item (#19), and strengthening the parity proof surface with
VB6 source anchors, packet fixtures, and RNG guardrails. Snapshot/diff
tooling, the deterministic harness, all golden gameplay fixtures, and the
map-layer effects migration are already shipped.

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

3. Extend packet byte-level fixtures to the remaining high-risk families.
   - Done: bank (init/end/gold/slot), trade (init/slot/console/end),
     death/resurrect (update_hp/mana), status clears (paralize_ok, rest_ok),
     and inventory-use (potion hp/mana/sta) now assert encoded bytes via the
     `assert_payload/3` helper, not only effect kind.
   - Remaining: movement (pos_update), spell-cast, and equip/unequip packets.

Exit criteria:

- Source-data parity tail has explicit fixtures or drift tickets.
- `drift.md` has zero open items, or each open item is explicitly ticketed.
- Golden fixtures cite the VB6 source they are defending. **(Done — all 8
  scenario golden modules carry a `VB6 anchors` block; see CHANGELOG.)**
- Flow-critical packets have byte-level fixtures or an explicit reason they do
  not need one yet. *(In progress — bank/trade/resurrect/status/inventory-use
  covered; movement/spell-cast/equip remain, item 3 above.)*
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

Exit criteria:

- Fast and slow parity gates are documented and runnable.
- Load/soak has a repeatable command and pass criteria.
- Real VB6 packet captures are versioned or the blocker is explicitly tracked.
- Replay coverage exists for the major protocol surfaces once captures exist.
- Integration and soak suites cover combat, guilds, commerce, and transfers.

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

3. Add alerts.
   - Sustained shedding
   - Forced backpressure disconnects

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

8. Add structured audit log review and export for moderation actions.
   - Search by actor, target, action, and time range
   - Export in an operator-friendly format

Exit criteria:

- Operators can inspect live maps, sessions, and online players.
- Critical failure modes emit telemetry and metrics.
- Dashboards and alerts cover backpressure, disconnects, and autosave failures.
- Incident response and moderation audit flows are documented and usable.

## Phase 4: Security And Abuse Hardening

Goal: keep parity while making abuse cases executable and visible.

Work:

1. Keep the exploit and parity audit executable.
2. Add anti-cheat hardening.
3. Expand adversarial tests for protocol abuse, impossible movement, combat
   abuse, chat abuse, and economic abuse.

Exit criteria:

- Abuse checks are represented by automated tests or executable audit tasks.
- New hardening does not silently break VB6 protocol parity.

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

Exit criteria:

- NPC and pet targeting avoid full-map scans on hot paths.
- Guild code has clear module boundaries.
- Persistence writes have explicit ownership and failure semantics.

## Phase 6: Release And Deployment

Goal: make the project releasable, recoverable, and supportable.

Work:

1. Add release artifacts.
2. Add deployment pipeline.
3. Add backup and restore runbook.
4. Add TLS for HTTPS and WSS.
5. Add asset CDN and static-delivery strategy.
6. Add automated backups.
7. Tune database connection pools.
8. Define the live database migration strategy.
9. Add pre-public scripted load and soak runs.
10. Pin and document the working toolchain.
    - Elixir version
    - Erlang/OTP version
    - Hex version
    - Node/npm version
    - Nix and non-Nix setup paths

11. Add a dev-environment verification command.
    - Check Elixir/Erlang/Hex compatibility
    - Check Node/npm availability
    - Check map-pack build prerequisites
    - Fail with actionable setup output

12. Make client build failure modes explicit.
    - Surface map-pack prebuild failures clearly
    - Distinguish toolchain failures from Vite failures
    - Document the direct Vite fallback for client-only verification

13. Make restore drills a release gate.
    - Restore from backup into a clean environment
    - Verify account, character, guild, and bank data
    - Record drill result before public release

Exit criteria:

- A release can be built and deployed from automation.
- Backups and restores are documented and tested.
- HTTPS/WSS and static asset delivery are production-ready.
- Pre-public soak has a documented pass/fail threshold.
- Toolchain verification catches local setup drift before build/test commands.
- Restore drills pass before a public release is cut.

## Phase 7: Browser Product

Goal: make the browser client releasable as a product, not only playable as a
technical client.

Work:

1. Add live-backend browser E2E for existing account and lobby flows.
   - Register or log in through the real browser API
   - Create a character through the lobby
   - Launch the character and receive session credentials
   - Reach the gameplay/reconnect-ready state from those credentials

2. Prove browser protocol and reducer correctness.
   - Clean `typecheck`
   - Clean `build`
   - Shared packet fixtures and fuzzing
   - Reducer/state tests
   - Visual fixtures
   - Browser E2E smoke coverage

3. Make the browser UI reflect authoritative server state.
   - Authoritative party panel
   - Authoritative clan panel
   - Responsive layout passes
   - Live-backend E2E for party snapshots
   - Live-backend E2E for clan details/news/online state

4. Complete the remaining browser account surface.
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

8. Make the browser client releasable.
   - Supported browser matrix
   - Shared protocol contract tests
   - Deterministic browser harness
   - Reconnect, cache, and asset failure handling
   - Visual baseline discipline
   - Client telemetry and performance budgets

9. Add browser/server packet contract fixtures shared in CI.
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

Exit criteria:

- Browser account, lobby, character creation, and launch flows have live-backend
  E2E coverage.
- Browser state is driven by authoritative server packets where available.
- Browser E2E and visual checks cover the release-critical flows.
- Shared packet fixtures protect browser/server protocol compatibility in CI.
- Asset and cache mismatch recovery is covered by tests.

## Phase 8: Optional Legacy And Multi-Realm

These are real product items, but they are not prerequisites for the next
backend or browser release.

Work:

1. If clan relations are re-enabled, implement live guild alliance and peace
   proposal flows.
2. If guild elections are re-enabled, implement live election and democratic
   succession.
3. Add explicit regional realm support.
   - Realm architecture
   - Backend realm selection
   - Browser realm selection
   - Realm-aware monitoring
   - Controlled transfer policy

Exit criteria:

- Optional legacy systems have explicit product approval.
- Multi-realm design is documented before implementation starts.
