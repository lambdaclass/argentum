# Argentum Roadmap

## Phase 1. Maintenance - keep the branch and roadmap trustworthy

1. Finish or isolate any active gameplay patch.
2. Keep the branch, roadmap, and changelog clean after every large merge.

## Phase 2. Parity-Required Rules And Backend Behavior - close the currently confirmed backend drift

3. ~~Restore commerce open on merchant double-click.~~ Done.
4. ~~Close bank and commerce sessions when the player walks away from the NPC.~~ Done.
5. ~~Implement the remaining bank-open guards from VB6.~~ Done.
6. ~~Match timbero account-state counters and values to VB6.~~ Done.
7. ~~Finish remaining NPC AI edge-case parity.~~ Done.
8. ~~Finish remaining spell-selection edge-case parity.~~ Done.
9. ~~Implement the /REWARD NPC request flow.~~ Done.
10. ~~Match banker, timbero, priest, and enlistador response text and values to VB6.~~ Done.
11. ~~Fix remaining guild relation stubs.~~ Done.
12. ~~Decide the GM/admin packet target.~~ Done.
13. ~~Implement the remaining GM/admin commands for the chosen target.~~ Done.
14. ~~Remove the remaining GM/admin stubs for the chosen target.~~ Done.
15. ~~Implement capture and control-point events.~~ Done.
16. ~~Implement siege and castle events.~~ Done.
17. ~~Implement event participant tracking and rewards.~~ Done.
18. ~~Implement event scheduling and duration flows.~~ Done.
19. ~~Decide whether AO20-era account, lobby, and control packet surfaces remain in scope.~~ Done.
20. ~~Implement AO20-era account, lobby, and control packet surfaces if they remain in scope.~~ Done.
21. ~~Implement remaining decoded-but-stubbed parity packet handlers that stay in scope.~~ Done.
22. Add a failing parity test for each newly discovered backend drift before fixing it.
23. ~~Add the missing `eGMPanel` decode, route, and handler, and send `show_gm_panel_form`.~~ Done.
24. ~~Apply the VB6 30 percent NPC melee poison roll instead of poisoning on every landed hit.~~ Done.
25. ~~Add binary duel packet support for `eDuel`, `eAcceptDuel`, `eCancelDuel`, and `eQuitDuel`.~~ Done.
26. ~~Allow faction council members to use `royal_army_message` and `chaos_legion_message` like VB6.~~ Done.
27. ~~Expand inventory size by patron tier and remove hardcoded 24-slot assumptions.~~ Done.
28. ~~Restore the VB6 max active quest cap of 5.~~ Done.
29. ~~Block merchant sell for items flagged `destruye`.~~ Done.
30. ~~Apply the Trabajador merchant sell-price discount from VB6.~~ Done.
31. ~~Block merchant sell for `Consejero` and `SemiDios`.~~ Done.
32. ~~Add `eChatColor` decode, state, handler, and outbound chat color support.~~ Done.
33. ~~Port the VB6 `SubirSkill` practice formula, hunger/thirst gate, expert cutoff, and XP reward.~~ Done.
34. ~~Narrow Royal Army enlistment class rejection to `:thief` only.~~ Done.
35. ~~Reject Ciudadano, Armada, and consejo on Chaos Legion enlistment.~~ Done.
36. ~~Enforce `MAX_FACTION_ENLISTMENTS` on both faction enlist paths.~~ Done.
37. ~~Port the full VB6 `VolverCriminal` flow instead of only setting `criminal: true`.~~ Done.
38. ~~Apply HP potion `SelfHealingBonus` and the `DivineBlood` consumption block.~~ Done.
39. ~~Apply the VB6 mana potion restore formula based on `porcentaje`.~~ Done.
40. ~~Add duration timers and `backup * 2` caps for strength and agility potions.~~ Done.
41. Add the missing outbound packets `paralize_ok`, `blind_no_more`, `dumb_no_more`, `rest_ok`, `work_request_target`, and `stun_start`. _Partial: all six encoders shipped; `paralize_ok` and `rest_ok` wired; remaining four pending flag-subsystem ports (blind/dumb/stun buffs, server-prompted work-target flow)._

## Phase 3. Parity Proof - prove behavior against the VB6 baseline

42. ~~Expand formula golden coverage to the remaining VB6 formulas and edge cases.~~ Done.
43. ~~Add `ao_session` unit tests for session-state transitions and protocol invariants.~~ Done.
44. ~~Add spell-effect golden tests for legacy spells and their edge cases.~~ Done.
45. ~~Add pet and taming parity tests.~~ Done.
46. ~~Add concurrent combat integration tests with multiple live clients.~~ Done.
47. ~~Expand lifecycle tests for autosave timing, multi-map transfer chains, cleanup DB failure, flush timeout, worker crash and start failure, stale autosave ordering, and graceful-disconnect final-save failure.~~ Done.
48. ~~Expand guild, faction, ban, and mute persistence coverage.~~ Done.
49. Add a high-load bot benchmark.
50. Add a load and soak gate.
51. Define the exact parity-gate required suites.
52. Build and version a real VB6 packet-capture corpus. `BLOCKED on Windows/VB6 environment.`
53. Add packet replay coverage for login, character creation, and session bootstrap. `BLOCKED on #52.`
54. Add packet replay coverage for movement, map transfer, chat, and info/service requests. `BLOCKED on #52.`
55. Add packet replay coverage for inventory, equip/use, combat, spells, and death. `BLOCKED on #52.`
56. Add packet replay coverage for bank, trade, party, guild, faction, reconnect, and logout. `BLOCKED on #52.`

## Phase 4. Security And Hardening - harden the server after parity is closed

57. Keep the exploit and parity audit executable.
58. Add anti-cheat hardening.

## Phase 5. Observability And Ops - make the runtime visible and operable

59. Finish telemetry wiring. _Partial: session backpressure foundation
    (`AoSession.Outbound`, `AoSession.Egress`, `AoSession.PressureRegistry`,
    `AoProtocol.Classify`) emits `[:arena, :session, :backpressure]`.
    Remaining: PromEx/Prometheus reporter, bank/guild events, producer
    migration beyond `Arena.Map.Visibility`._
60. Add metrics and dashboards.
61. Add alerts.
62. Add runtime admin tools for map and process inspection and control.
63. Add admin lookup for accounts, characters, and online players.
64. Add admin moderation actions.
65. Add admin world actions.
66. Add admin logs and health views.

## Phase 6. Backend Architecture - reduce long-term coupling and hot-path cost

67. Replace NPC aggro full scans with spatial-grid queries.
68. Replace pet target full scans with bounded or indexed lookup.
69. Define a shared map-effect return contract and effect shapes.
70. Add effect helper constructors and explicit persistence-boundary wrappers.
71. Introduce handler effects only where they remove real coupling.
72. Split `guild_server.ex` into focused modules.
73. Pre-resolve `.dat` references at load time where hot-path lookups still repeat.
74. Unify interest management for players, NPCs, and ground items.
75. Add runtime-tunable settings for intervals, rates, and formula constants.

## Phase 7. Deployment And Release - make releases recoverable and repeatable

76. Add release artifacts, deployment pipeline, and backup/restore runbook.
77. Add TLS for HTTPS and WSS.
78. Add asset CDN and static-delivery strategy.
79. Add automated backups and database connection-pool tuning.
80. Define the live database migration strategy.
81. Add pre-public scripted load and soak runs.

## Phase 8. Legacy Features Disabled In The Inspected VB6 Baseline - add optional legacy systems only if a shard re-enables them

82. If clan relations are re-enabled, implement live guild alliance and peace proposal, detail, and mailbox flows.
83. If guild elections are re-enabled, implement the live election and democratic succession system.

## Phase 9. Browser Proof - prove browser protocol and state correctness

84. Run `npm run typecheck` from a clean checkout.
85. Run `npm run build` from a clean checkout.
86. Keep client packet decode and encode locked to the current server protocol.
87. Add browser-side packet fixture tests using the shared VB6 fixtures.
88. Add browser-side decoder fuzz tests.
89. Add browser-side reducer and state tests for inventory.
90. Add browser-side reducer and state tests for bank.
91. Add browser-side reducer and state tests for trade.
92. Add browser-side reducer and state tests for party and clan.
93. Add browser-side reducer and state tests for weather and death.
94. Add browser visual fixture tests for player bodies and equipment overlays.
95. Add browser visual fixture tests for common NPC sprites.
96. Keep WebSocket and session bootstrap isolated from gameplay bytes.
97. Keep NPC sprite and body mappings checked by fixture or screenshot tests.
98. Add web E2E smoke coverage for browser login and lobby flows.
99. Add web E2E smoke coverage for connect, map load, and inventory.
100. Add web E2E smoke coverage for combat, spells, death, and revive.
101. Add web E2E smoke coverage for bank, trade, social UI, weather, and reconnect.

## Phase 10. Frontend Product And UX - make the browser UI reflect authoritative state

102. Make party panels use authoritative state instead of console-text inference.
103. Make clan panels use authoritative state instead of console-text inference.
104. Show party member online state, leader and permissions, and party safe state.
105. Show clan member online state, rank and role, and faction or guild alignment.
106. Keep faction chat visible as a distinct chat stream.
107. Keep guild chat visible as a distinct chat stream.
108. Keep party chat visible as a distinct chat stream.
109. Do not add a browser graphics-quality menu by default unless profiling proves a real need.
110. Add map markers if they remain part of the web UX target.
111. Add combat and spell sound effects.
112. Add inventory and UI sound effects.
113. Add door, teleport, and weather sound effects.
114. Add a responsive layout pass for desktop.
115. Add a responsive layout pass for laptop and common browser zoom levels.

## Phase 11. Browser Account And Lobby - complete the browser account surface

116. Add `POST /api/auth/google`.
117. Support Google-only accounts.
118. Support linked password and Google accounts.
119. Build the browser Google login flow.
120. Build the browser Google account-link flow.
121. Add browser stat choices to the character-create flow.

## Phase 12. Localization - make supported languages first-class

122. Define supported locales and fallback behavior.
123. Extract browser gameplay UI strings into translation keys.
124. Extract account, auth, and lobby UI strings into translation keys.
125. Separate player-facing server and browser messages from hardcoded shard-language text where localization is required.
126. Keep protocol payloads language-neutral where possible.
127. Add locale preference at the account or session level.
128. Add browser language selection and persistence.
129. Add locale-aware number, date, and time formatting.
130. Verify fonts and glyph coverage for the supported languages.
131. Audit chat and input handling for accents, IME, and Unicode edge cases.
132. Add browser i18n test coverage.
133. Decide which surfaces remain intentionally non-localized.

## Phase 13. Multi-Realm - add explicit regional realm support

134. Define the multi-realm architecture.
135. Add realm metadata and realm selection to the account and lobby backend.
136. Add realm selection to the browser lobby.
137. Show per-realm character availability and state in the browser lobby.
138. Route character session issuance through the selected realm.
139. Add deployment and runbook support for multiple regional realms.
140. Add realm-aware monitoring and admin surfaces.
141. Define the controlled character-transfer policy between realms.
142. Implement controlled character transfer between realms if it remains in scope.

## Phase 14. Browser Hardening And Release - make the browser client releasable

143. Define the supported browser matrix and minimum versions.
144. Add shared client-vs-`ao_protocol` contract tests for browser packet shapes.
145. Add deterministic harness, demo routes, or fixtures for critical browser UI states.
146. Add asset, map-pack, and cache failure handling with explicit fallback UI.
147. Expand reconnect and partial-bootstrap recovery behavior and browser tests.
148. Add an explicit Playwright snapshot and release-check discipline for visual baselines.
149. Add client-side telemetry for decode, render, bootstrap, and asset-load failures.
150. Define frontend performance budgets for boot, first map render, reconnect, and map transfer.
151. Add long-session browser memory-growth checks.
152. Define the fast frontend unit-test lane.
153. Add accessibility and keyboard coverage for the core browser panels.
154. Define asset, map-pack, and browser-cache versioning and invalidation rules.
155. Split frontend CI into a fast unit and protocol lane and a slower browser and visual-regression lane.
156. Make the authoritative-vs-inferred browser UI rule explicit and test it.
