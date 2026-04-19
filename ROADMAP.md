# Argentum Roadmap

## Phase 1. Maintenance — keep the branch and roadmap trustworthy

1. Finish or isolate any active gameplay patch.
2. Keep the branch and roadmap clean after every large merge.

## Phase 2. Parity-Required Rules And Backend Behavior — close the remaining backend drift

3. ~~Restore commerce open on merchant double-click.~~ Done.
4. ~~Close bank and commerce sessions when the player walks away from the NPC.~~ Done.
5. ~~Implement the remaining bank-open guards from VB6.~~ Done.
6. ~~Match timbero account-state counters and values to VB6 (message format done).~~ Done.
7. ~~Finish remaining NPC AI edge-case parity.~~ Done.
8. ~~Finish remaining spell-selection edge-case parity.~~ Done.
9. ~~Implement the /REWARD NPC request flow (rank-up rewards already work in faction.ex).~~ Done.
10. ~~Match banker, timbero, priest, and enlistador response text and values to VB6.~~ Done.
11. ~~Fix remaining guild relation stubs.~~ Done.
12. ~~Decide the GM/admin packet target.~~ Done — VB6 parity, tiered text commands over both TCP and WS.
13. ~~Implement the remaining GM/admin commands for the chosen target.~~ Done — 14 new commands added.
14. ~~Remove the remaining GM/admin stubs for the chosen target.~~ Done — no dead stubs found.
15. ~~Implement capture and control-point events.~~ Done — CaptureServer GenServer with team-based flag capture, registration validation, round progression, death timers, hold-to-capture mechanic.
16. ~~Implement siege and castle events.~~ Done — SiegeServer GenServer with wall HP, wave spawning, top-10 scoreboard, defender/attacker win conditions, rewards.
17. ~~Implement event participant tracking and rewards.~~ Done — Rewards pure module (capture/siege/tournament) + ParticipantValidation with 11-point registration checks.
18. ~~Implement event scheduling and duration flows.~~ Done — EventScheduler GenServer with hourly triggers, duration tracking, manual override, injectable clock for testing.
19. ~~Decide whether AO20-era account, lobby, and control packet surfaces remain in scope.~~ Done — no AO20-only binary surfaces exist; account/lobby is REST, already implemented.
20. ~~Implement AO20-era account, lobby, and control packet surfaces if they remain in scope.~~ Done — N/A (no binary surfaces to implement; REST API already exists).
21. ~~Implement remaining decoded-but-stubbed parity packet handlers that stay in scope.~~ Done — `server_open_toggle` and `warp_me_to_target` fixed; remaining stubs documented as intentional.
22. Add a failing parity test for each newly discovered backend drift before fixing it.

## Phase 3. Parity Proof — prove behavior against the VB6 baseline

23. Expand formula golden coverage to the remaining VB6 formulas and edge cases.
24. Add `ao_session` unit tests for session-state transitions and protocol invariants.
25. Add spell-effect golden tests for legacy spells and their edge cases.
26. Add pet and taming parity tests.
27. Add concurrent combat integration tests with multiple live clients.
28. Expand lifecycle tests for autosave timing, multi-map transfer chains, cleanup DB failure, flush timeout, worker crash and start failure, stale autosave ordering, and graceful-disconnect final-save failure.
29. Expand guild, faction, ban, and mute persistence coverage.
30. Add a high-load bot benchmark.
31. Add a load and soak gate.
32. Define the exact parity-gate required suites.
33. Build and version a real VB6 packet-capture corpus. `BLOCKED on Windows/VB6 environment.`
34. Add packet replay coverage for login, character creation, and session bootstrap. `BLOCKED on #33.`
35. Add packet replay coverage for movement, map transfer, chat, and info/service requests. `BLOCKED on #33.`
36. Add packet replay coverage for inventory, equip/use, combat, spells, and death. `BLOCKED on #33.`
37. Add packet replay coverage for bank, trade, party, guild, faction, reconnect, and logout. `BLOCKED on #33.`

## Phase 4. Security And Hardening — harden the server after parity is closed

38. Keep the exploit and parity audit executable.
39. Add anti-cheat hardening.

## Phase 5. Observability And Ops — make the runtime visible and operable

40. Finish telemetry wiring.
41. Add metrics and dashboards.
42. Add alerts.
43. Add runtime admin tools for map and process inspection and control.
44. Add admin lookup for accounts, characters, and online players.
45. Add admin moderation actions.
46. Add admin world actions.
47. Add admin logs and health views.

## Phase 6. Backend Architecture — reduce long-term coupling and hot-path cost

48. Replace NPC aggro full scans with spatial-grid queries.
49. Replace pet target full scans with bounded or indexed lookup.
50. Introduce handler effects only where they remove real coupling.
51. Split `guild_server.ex` into focused modules.
52. Pre-resolve `.dat` references at load time where hot-path lookups still repeat.
53. Unify interest management for players, NPCs, and ground items.
54. Add runtime-tunable settings for intervals, rates, and formula constants.

## Phase 7. Deployment And Release — make releases recoverable and repeatable

55. Add release artifacts, deployment pipeline, and backup/restore runbook.
56. Add TLS for HTTPS and WSS.
57. Add asset CDN and static-delivery strategy.
58. Add automated backups and database connection-pool tuning.
59. Define the live database migration strategy.
60. Add pre-public scripted load and soak runs.

## Phase 8. Legacy Features Disabled In The Inspected VB6 Baseline — add optional legacy systems only if a shard re-enables them

61. If clan relations are re-enabled, implement live guild alliance and peace proposal, detail, and mailbox flows.
62. If guild elections are re-enabled, implement the live election and democratic succession system.

## Phase 9. Browser Proof — prove browser protocol and state correctness

63. Run `npm run typecheck` from a clean checkout.
64. Run `npm run build` from a clean checkout.
65. Keep client packet decode and encode locked to the current server protocol.
66. Add browser-side packet fixture tests using the shared VB6 fixtures.
67. Add browser-side decoder fuzz tests.
68. Add browser-side reducer and state tests for inventory.
69. Add browser-side reducer and state tests for bank.
70. Add browser-side reducer and state tests for trade.
71. Add browser-side reducer and state tests for party and clan.
72. Add browser-side reducer and state tests for weather and death.
73. Add browser visual fixture tests for player bodies and equipment overlays.
74. Add browser visual fixture tests for common NPC sprites.
75. Keep WebSocket and session bootstrap isolated from gameplay bytes.
76. Keep NPC sprite and body mappings checked by fixture or screenshot tests.
77. Add web E2E smoke coverage for browser login and lobby flows.
78. Add web E2E smoke coverage for connect, map load, and inventory.
79. Add web E2E smoke coverage for combat, spells, death, and revive.
80. Add web E2E smoke coverage for bank, trade, social UI, weather, and reconnect.

## Phase 10. Frontend Product And UX — make the browser UI reflect authoritative state

81. Make party panels use authoritative state instead of console-text inference.
82. Make clan panels use authoritative state instead of console-text inference.
83. Show party member online state, leader and permissions, and party safe state.
84. Show clan member online state, rank and role, and faction or guild alignment.
85. Keep faction chat visible as a distinct chat stream.
86. Keep guild chat visible as a distinct chat stream.
87. Keep party chat visible as a distinct chat stream.
88. Do not add a browser graphics-quality menu by default unless profiling proves a real need.
89. Add map markers if they remain part of the web UX target.
90. Add combat and spell sound effects.
91. Add inventory and UI sound effects.
92. Add door, teleport, and weather sound effects.
93. Add a responsive layout pass for desktop.
94. Add a responsive layout pass for laptop and common browser zoom levels.

## Phase 11. Browser Account And Lobby — complete the browser account surface

95. Add `POST /api/auth/google`.
96. Support Google-only accounts.
97. Support linked password and Google accounts.
98. Build the browser Google login flow.
99. Build the browser Google account-link flow.
100. Add browser stat choices to the character-create flow.

## Phase 12. Localization — make supported languages first-class

101. Define supported locales and fallback behavior.
102. Extract browser gameplay UI strings into translation keys.
103. Extract account, auth, and lobby UI strings into translation keys.
104. Separate player-facing server and browser messages from hardcoded shard-language text where localization is required.
105. Keep protocol payloads language-neutral where possible.
106. Add locale preference at the account or session level.
107. Add browser language selection and persistence.
108. Add locale-aware number, date, and time formatting.
109. Verify fonts and glyph coverage for the supported languages.
110. Audit chat and input handling for accents, IME, and Unicode edge cases.
111. Add browser i18n test coverage.
112. Decide which surfaces remain intentionally non-localized.

## Phase 13. Multi-Realm — add explicit regional realm support

113. Define the multi-realm architecture.
114. Add realm metadata and realm selection to the account and lobby backend.
115. Add realm selection to the browser lobby.
116. Show per-realm character availability and state in the browser lobby.
117. Route character session issuance through the selected realm.
118. Add deployment and runbook support for multiple regional realms.
119. Add realm-aware monitoring and admin surfaces.
120. Define the controlled character-transfer policy between realms.
121. Implement controlled character transfer between realms if it remains in scope.

## Phase 14. Browser Hardening And Release — make the browser client releasable

122. Define the supported browser matrix and minimum versions.
123. Add shared client-vs-`ao_protocol` contract tests for browser packet shapes.
124. Add deterministic harness, demo routes, or fixtures for critical browser UI states.
125. Add asset, map-pack, and cache failure handling with explicit fallback UI.
126. Expand reconnect and partial-bootstrap recovery behavior and browser tests.
127. Add an explicit Playwright snapshot and release-check discipline for visual baselines.
128. Add client-side telemetry for decode, render, bootstrap, and asset-load failures.
129. Define frontend performance budgets for boot, first map render, reconnect, and map transfer.
130. Add long-session browser memory-growth checks.
131. Define the fast frontend unit-test lane.
132. Add accessibility and keyboard coverage for the core browser panels.
133. Define asset, map-pack, and browser-cache versioning and invalidation rules.
134. Split frontend CI into a fast unit and protocol lane and a slower browser and visual-regression lane.
135. Make the authoritative-vs-inferred browser UI rule explicit and test it.
