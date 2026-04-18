# Argentum Roadmap

## Phase 1. Maintenance — keep the branch and roadmap trustworthy

1. Finish or isolate any active gameplay patch.
2. Keep the branch and roadmap clean after every large merge.

## Phase 2. Parity-Required Rules And Backend Behavior — close the remaining backend drift

3. Restore commerce open on merchant double-click.
4. Close bank and commerce sessions when the player walks away from the NPC.
5. Implement the remaining bank-open guards from VB6.
6. Match timbero account-state counters and values to VB6 (message format done).
7. Finish remaining NPC AI edge-case parity.
8. Finish remaining spell-selection edge-case parity.
9. Implement the /REWARD NPC request flow (rank-up rewards already work in faction.ex).
10. Match banker, timbero, priest, and enlistador response text and values to VB6.
11. Fix remaining guild relation stubs.
12. Decide the GM/admin packet target.
13. Implement the remaining GM/admin commands for the chosen target.
14. Remove the remaining GM/admin stubs for the chosen target.
15. Implement capture and control-point events.
16. Implement siege and castle events.
17. Implement event participant tracking and rewards.
18. Implement event scheduling and duration flows.
19. Decide whether AO20-era account, lobby, and control packet surfaces remain in scope.
20. Implement AO20-era account, lobby, and control packet surfaces if they remain in scope.
21. Implement remaining decoded-but-stubbed parity packet handlers that stay in scope.
22. Add a failing parity test for each newly discovered backend drift before fixing it.

## Phase 3. Parity Proof — prove behavior against the VB6 baseline

30. Expand formula golden coverage to the remaining VB6 formulas and edge cases.
31. Add `ao_session` unit tests for session-state transitions and protocol invariants.
32. Add spell-effect golden tests for legacy spells and their edge cases.
33. Add pet and taming parity tests.
34. Add concurrent combat integration tests with multiple live clients.
35. Expand lifecycle tests for autosave timing, multi-map transfer chains, cleanup DB failure, flush timeout, worker crash and start failure, stale autosave ordering, and graceful-disconnect final-save failure.
36. Expand guild, faction, ban, and mute persistence coverage.
37. Add a high-load bot benchmark.
38. Add a load and soak gate.
39. Define the exact parity-gate required suites.
40. Build and version a real VB6 packet-capture corpus. `BLOCKED on Windows/VB6 environment.`
41. Add packet replay coverage for login, character creation, and session bootstrap. `BLOCKED on #40.`
42. Add packet replay coverage for movement, map transfer, chat, and info/service requests. `BLOCKED on #40.`
43. Add packet replay coverage for inventory, equip/use, combat, spells, and death. `BLOCKED on #40.`
44. Add packet replay coverage for bank, trade, party, guild, faction, reconnect, and logout. `BLOCKED on #40.`

## Phase 4. Security And Hardening — harden the server after parity is closed

45. Keep the exploit and parity audit executable.
46. Add anti-cheat hardening.

## Phase 5. Observability And Ops — make the runtime visible and operable

47. Finish telemetry wiring.
48. Add metrics and dashboards.
49. Add alerts.
50. Add runtime admin tools for map and process inspection and control.
51. Add admin lookup for accounts, characters, and online players.
52. Add admin moderation actions.
53. Add admin world actions.
54. Add admin logs and health views.

## Phase 6. Backend Architecture — reduce long-term coupling and hot-path cost

55. Replace NPC aggro full scans with spatial-grid queries.
56. Replace pet target full scans with bounded or indexed lookup.
57. Introduce handler effects only where they remove real coupling.
58. Split `guild_server.ex` into focused modules.
59. Pre-resolve `.dat` references at load time where hot-path lookups still repeat.
60. Unify interest management for players, NPCs, and ground items.
61. Add runtime-tunable settings for intervals, rates, and formula constants.

## Phase 7. Deployment And Release — make releases recoverable and repeatable

62. Add release artifacts, deployment pipeline, and backup/restore runbook.
63. Add TLS for HTTPS and WSS.
64. Add asset CDN and static-delivery strategy.
65. Add automated backups and database connection-pool tuning.
66. Define the live database migration strategy.
67. Add pre-public scripted load and soak runs.

## Phase 8. Legacy Features Disabled In The Inspected VB6 Baseline — add optional legacy systems only if a shard re-enables them

68. If clan relations are re-enabled, implement live guild alliance and peace proposal, detail, and mailbox flows.
69. If guild elections are re-enabled, implement the live election and democratic succession system.

## Phase 9. Browser Proof — prove browser protocol and state correctness

70. Run `npm run typecheck` from a clean checkout.
71. Run `npm run build` from a clean checkout.
72. Keep client packet decode and encode locked to the current server protocol.
73. Add browser-side packet fixture tests using the shared VB6 fixtures.
74. Add browser-side decoder fuzz tests.
75. Add browser-side reducer and state tests for inventory.
76. Add browser-side reducer and state tests for bank.
77. Add browser-side reducer and state tests for trade.
78. Add browser-side reducer and state tests for party and clan.
79. Add browser-side reducer and state tests for weather and death.
80. Add browser visual fixture tests for player bodies and equipment overlays.
81. Add browser visual fixture tests for common NPC sprites.
82. Keep WebSocket and session bootstrap isolated from gameplay bytes.
83. Keep NPC sprite and body mappings checked by fixture or screenshot tests.
84. Add web E2E smoke coverage for browser login and lobby flows.
85. Add web E2E smoke coverage for connect, map load, and inventory.
86. Add web E2E smoke coverage for combat, spells, death, and revive.
87. Add web E2E smoke coverage for bank, trade, social UI, weather, and reconnect.

## Phase 10. Frontend Product And UX — make the browser UI reflect authoritative state

88. Make party panels use authoritative state instead of console-text inference.
89. Make clan panels use authoritative state instead of console-text inference.
90. Show party member online state, leader and permissions, and party safe state.
91. Show clan member online state, rank and role, and faction or guild alignment.
92. Keep faction chat visible as a distinct chat stream.
93. Keep guild chat visible as a distinct chat stream.
94. Keep party chat visible as a distinct chat stream.
95. Do not add a browser graphics-quality menu by default unless profiling proves a real need.
96. Add map markers if they remain part of the web UX target.
97. Add combat and spell sound effects.
98. Add inventory and UI sound effects.
99. Add door, teleport, and weather sound effects.
100. Add a responsive layout pass for desktop.
101. Add a responsive layout pass for laptop and common browser zoom levels.

## Phase 11. Browser Account And Lobby — complete the browser account surface

102. Add `POST /api/auth/google`.
103. Support Google-only accounts.
104. Support linked password and Google accounts.
105. Build the browser Google login flow.
106. Build the browser Google account-link flow.
107. Add browser stat choices to the character-create flow.

## Phase 12. Localization — make supported languages first-class

108. Define supported locales and fallback behavior.
109. Extract browser gameplay UI strings into translation keys.
110. Extract account, auth, and lobby UI strings into translation keys.
111. Separate player-facing server and browser messages from hardcoded shard-language text where localization is required.
112. Keep protocol payloads language-neutral where possible.
113. Add locale preference at the account or session level.
114. Add browser language selection and persistence.
115. Add locale-aware number, date, and time formatting.
116. Verify fonts and glyph coverage for the supported languages.
117. Audit chat and input handling for accents, IME, and Unicode edge cases.
118. Add browser i18n test coverage.
119. Decide which surfaces remain intentionally non-localized.

## Phase 13. Multi-Realm — add explicit regional realm support

120. Define the multi-realm architecture.
121. Add realm metadata and realm selection to the account and lobby backend.
122. Add realm selection to the browser lobby.
123. Show per-realm character availability and state in the browser lobby.
124. Route character session issuance through the selected realm.
125. Add deployment and runbook support for multiple regional realms.
126. Add realm-aware monitoring and admin surfaces.
127. Define the controlled character-transfer policy between realms.
128. Implement controlled character transfer between realms if it remains in scope.

## Phase 14. Browser Hardening And Release — make the browser client releasable

129. Define the supported browser matrix and minimum versions.
130. Add shared client-vs-`ao_protocol` contract tests for browser packet shapes.
131. Add deterministic harness, demo routes, or fixtures for critical browser UI states.
132. Add asset, map-pack, and cache failure handling with explicit fallback UI.
133. Expand reconnect and partial-bootstrap recovery behavior and browser tests.
134. Add an explicit Playwright snapshot and release-check discipline for visual baselines.
135. Add client-side telemetry for decode, render, bootstrap, and asset-load failures.
136. Define frontend performance budgets for boot, first map render, reconnect, and map transfer.
137. Add long-session browser memory-growth checks.
138. Define the fast frontend unit-test lane.
139. Add accessibility and keyboard coverage for the core browser panels.
140. Define asset, map-pack, and browser-cache versioning and invalidation rules.
141. Split frontend CI into a fast unit and protocol lane and a slower browser and visual-regression lane.
142. Make the authoritative-vs-inferred browser UI rule explicit and test it.
