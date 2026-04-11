# Argentum Unified Roadmap

This is the only roadmap. `CHANGELOG.md` tracks completed work.

## Current Status

- **Backend gameplay:** close for the modern web path, but not full VB6 parity.
  Do not call the backend compatible until the backend tasks below are closed
  or deliberately removed from scope.
- **Parity gate:** the harness foundation is in place. The main remaining proof
  gap is a real VB6 traffic corpus and replay coverage built from captured
  sessions instead of synthetic fixtures alone.
- **Backend environment:** the supported `server/` Nix/dev shell compiles and
  tests cleanly, and recent migrations were verified on clean Postgres.
- **Web client:** playable development client. Remaining work is weather/social
  polish, authoritative party/clan state, trade metadata display, browser-side
  parity tests, and session/auth UX polish.
- **Post-compat account flow:** not built. Target is username/password or Google
  account login over HTTP, character selection in the browser, then unchanged
  AO socket login with `login_existing_char(char_id, session_token)`.
- **Code size now:** backend runtime code is ~21k Elixir LOC, backend tests are
  ~17k Elixir LOC, and the web client source is ~15k TypeScript/React/CSS LOC.

## Linear Task List

Tasks `1-49` are the backend parity path. Tasks `50-145` are post-parity
browser/product work. Tasks `146-167` are backend modernization and
operations that should not block parity signoff unless explicitly pulled into
scope. Tasks `168-169` are optional legacy features that the inspected VB6
baseline kept disabled and should only be revisited after backend
modernization unless a target shard explicitly re-enables them.

## Scope Rules

- If a task changes **player-visible gameplay**, **old-client protocol
  behavior**, or **persistent game rules**, match the VB6 baseline.
- If the VB6 baseline intentionally disables a feature, keep the disabled
  behavior unless the selected target shard explicitly re-enables it.
- If the inspected VB6 baseline disables a feature, parity only requires
  preserving the disabled semantics in the backend parity path. Re-enabling
  that feature belongs after the frontend/product and backend-modernization
  tracks unless the selected shard explicitly requires it earlier.
- If a task only changes **implementation**, **testing**, **performance**,
  **ops**, or **admin tooling**, improve it in the modern way.
- Items explicitly marked **if target baseline uses them** are parity blockers
  only when the chosen VB6 shard/data set actually depends on them.

## Backend Parity Finish Line

Call backend parity done only when:

- real VB6 packet captures exist from `mix capture.packets`
- replay suites are green against those captures
- formula/lifecycle/persistence parity suites are green
- the manual VB6 smoke checklist is green with an unmodified VB6 client
- all in-scope parity-required backend tasks below are done
- any out-of-scope legacy systems are explicitly listed as excluded

## Execution Rules

Keep the roadmap linear, but execute it with these constraints:

- **Tasks 1-3:** do serially. They are repo hygiene and status control.
- **Tasks 4-13:** strongest current parallel batch. These are mostly proof and
  test work with low write-set overlap.
- **Tasks 14-18:** keep at the end of parity proof. They are blocked on having
  a Windows/VB6 environment and a real capture corpus.
- **Tasks 19-29:** mostly shared protocol/session behavior. Prefer one owner at
  a time unless the write sets are proven disjoint.
- **Tasks 30-34:** good parallel batch. These are isolated old packet/UI
  families if each family has a single owner.
- **Tasks 35-36:** do serially. GM/admin packet targeting and implementation
  tend to touch shared routing and decoder surfaces.
- **Tasks 37-46:** parallelize by subsystem only. One owner per legacy system:
  quests, duels, events, auction, mounts, gambling, treasure, forum,
  marriage.
- **Tasks 47-49:** do serially. These are scope decisions and final drift
  cleanup.
- **Tasks 50-145:** highly parallelizable once started. Split by browser
  surface: protocol tests, reducer/state tests, UI polish, account/lobby,
  i18n, multi-realm.
- **Tasks 146-167:** parallelize by subsystem. These are modernization tasks
  and should not block parity signoff unless explicitly promoted.
- **Tasks 168-169:** do only after backend modernization unless the target
  shard explicitly promotes them back into the parity path.

When in doubt:

- Parallelize test-only, doc-only, data-only, and clearly isolated subsystem
  work.
- Serialize anything that touches shared session logic, protocol decoding,
  command routing, or cross-cutting persistence semantics.
- Merge proof/test work before shared behavior changes.

### Maintenance

1. Keep the branch clean.
   Outcome: no stray generated files, half-finished migrations, or untracked
   parity tests remain in normal working branches.
2. Finish or isolate any active gameplay patch before unrelated work starts.
   Outcome: parity work does not overlap with half-integrated gameplay edits.
3. Update the top-level roadmap status after every large merge.
   Outcome: the roadmap remains accurate instead of becoming historical fiction.

### Parity Proof

4. Expand the current formula golden coverage to the remaining VB6 formulas and
   edge cases.
   Outcome: combat, XP, regen, prices, training, and remaining formula edge
   cases are checked against VB6 outputs.
5. Add `ao_session` unit tests for session-state transitions and protocol
   invariants.
   Outcome: session-level packet handling and state transitions are covered
   below the TCP smoke layer.
6. Add spell-effect golden tests for legacy spells and their edge cases.
   Outcome: individual spell outputs and side effects are checked against the
   VB6 baseline instead of only broad combat formulas.
7. Add pet/taming parity tests.
   Outcome: pet follow/attack/taming behavior is proven under the same parity
   gate as player combat and movement.
8. Add concurrent combat integration tests with multiple live clients.
   Outcome: two-client and multi-actor combat ordering is verified instead of
   assuming single-session happy paths.
9. Expand lifecycle tests for login/autosave/logout/crash cleanup/transfer.
   Outcome: persistence and ownership transitions stay correct under failure.
10. Expand guild/faction/ban/mute persistence coverage.
    Outcome: shared cross-map state survives restart and migration.
11. Add a high-load bot benchmark as part of the load/soak gate.
    Outcome: the parity gate includes an explicit many-session benchmark, not
    just ad hoc long-running tests.
12. Add a load/soak gate.
    Outcome: long-running many-session behavior is tested before public use.
13. Define the exact parity-gate required suites.
    Outcome: "parity gate green" means a concrete, documented set of passing
    suites instead of a vague status label.
14. Once a Windows/VB6 environment is available, build and version a real VB6
    packet-capture corpus using `mix capture.packets` against an unmodified
    VB6 client.
    Outcome: replay tests have captured byte fixtures from the real old client
    instead of ad hoc locally built packet sequences, and the capture workflow
    is part of the normal parity toolchain.
15. Once the real corpus exists, add packet replay coverage for login,
    character creation, and session bootstrap.
    Outcome: authentication and initial game-state delivery are proven against
    captured traffic.
16. Once the real corpus exists, add packet replay coverage for movement, map
    transfer, chat, and info/service requests.
    Outcome: common non-combat session flows are proven against captured
    traffic.
17. Once the real corpus exists, add packet replay coverage for inventory,
    equip/use, combat, spells, and death.
    Outcome: the core gameplay packet loops are proven against captured
    traffic.
18. Once the real corpus exists, add packet replay coverage for bank, trade,
    party, guild, faction, reconnect, and logout.
    Outcome: the remaining social/economy/session packet flows are proven
    against captured traffic.

### Parity-Required Backend Behavior

19. Finish `/HOGAR` exact VB6 behavior.
    Outcome: `/HOGAR` matches the inspected VB6 baseline end-to-end: dead-only
    immediate return with gold cost, alive-use rejection, jail/NEWBIE/CARCEL
    and reto restrictions, and no invented delayed-travel flow.
20. Preserve the disabled guild relation semantics from the inspected VB6
    baseline.
    Outcome: alliance/peace proposal lists, details, and related clan-relation
    packets return the VB6 disabled responses instead of modern placeholder
    mailbox behavior. Live alliance/peace systems, if later desired, are
    deferred until after the frontend work.
21. Fix `gm_message` to match VB6 GM/admin broadcast semantics.
    Outcome: `gm_message` is limited to the intended GM/admin audience, uses
    the right prefix/font semantics, and is audited like the old server rather
    than behaving like a global plain-chat broadcast.
22. Fix `rain_toggle` to match VB6 global weather semantics.
    Outcome: GM weather toggling drives the same global rain/snow/thunder/flash
    side effects the VB6 server produced instead of only flipping map-local
    rain state.
23. Implement the remaining player-to-staff request packet behavior.
    Outcome: `role_master_request` and the old support-request surfaces such as
    `question_gm` have real VB6-compatible routing instead of being absent.
24. Keep elemental/rune combat effects data-driven.
    Outcome: elemental tags remain inert unless target data enables them; if it
    does, the combat matrix/effects are implemented without inventing new
    rules.
25. Audit remaining interval/timer clamps against VB6.
    Outcome: regen, hunger/thirst, buff timing, and other periodic behavior do
    not drift on edge intervals.
26. Audit remaining invisibility, NPC AI, and spell-selection edge cases
    against VB6.
    Outcome: the remaining known semantic edge cases are either matched or
    explicitly documented as out of scope.
26a. Fix: spell invisibility must NOT break on walking (VB6 parity). DONE.
    VB6: only Oculto (stealth) breaks on walk for non-Thief/Bandit classes.
    Spell invisibility (`invisible` flag) is never cleared by movement.
    Removed incorrect break_invisibility call in movement.ex do_move/8.
26b. Implement Oculto (stealth/hide skill) as a separate flag from spell invisibility.
    VB6 has two distinct systems: `invisible` (spell-based, timed buff) and
    `Oculto` (hide skill, breaks on walk for non-Thief/Bandit, breaks on
    shout, has its own timer). Currently only spell invisibility exists.
    Outcome: entity gains `oculto` boolean; walk breaks it for non-stealth
    classes; shout breaks it; timer expiry breaks it; Thief/Bandit exempt
    from walk break.
26c. Fix: offensive spell casting should break both invisible and oculto.
    VB6: casting a negative spell calls RemoveUserInvisibility on the caster
    (behind "remove-inv-on-attack" feature flag). Currently not implemented.
26d. Fix: add NPC leash distance (~15 tiles) so chasing NPCs return to spawn.
    Outcome: hostile NPCs stop chasing beyond leash range, matching VB6.
26e. Fix: melee hits should transfer NPC aggro (currently only spells do).
    Outcome: both melee and spell damage set npc.target_id to the attacker.
26f. Fix: NPC spell damage should use actual NPC level instead of hardcoded 20.
    Outcome: npc_def_level/1 returns the NPC definition's level field.
26g. Implement NoDetectable flag for immunity to RemoveInvisibility spells.
    VB6: players with NoDetectable=1 are immune to the RemoveInvisibility
    spell effect. Currently not implemented.
26h. Fix: entering no-invi maps (SinInviOcul) should clear both flags.
    VB6: maps flagged SinInviOcul strip invisible+oculto on entry.
26i. Fix: equipping mount should break both invisible and oculto.
    VB6: mounting clears both flags unconditionally.
27. Add authoritative party/clan snapshot packets or a documented backend
    snapshot API for the browser.
    Outcome: frontend party/clan UI can consume backend truth instead of chat
    log inference.
28. Finish pet/trainer command parity for the selected VB6 baseline.
    Outcome: `pet_follow_all`, trainer creature lists, trainer summon/train
    flows, and any real trainer gating used by the target shard are implemented
    instead of left as stubs or reduced to unrelated skill-point shortcuts.
29. Add out-of-sequence packet validation.
    Outcome: trade/commercial/admin packet families reject invalid state
    transitions instead of relying on happy-path ordering.
30. Expand remaining production recipe coverage to the target data set.
    Outcome: tailoring and any still-missing production recipes are covered if
    the target shard expects them.
31. Finish the remaining old crafting UI packet surface.
    Outcome: old carpenter/blacksmith/alchemy/tailor windows can drive the
    existing crafting backend through open/add/remove/move/craft/close flows.
32. Finish the remaining training/spell window response semantics.
    Outcome: the VB6 client gets the exact remaining responses it still expects
    for spell info, spell movement, trainer lists, trainer summon responses,
    and the missing `UpdateRM`/`UpdateDM` style spell-stat updates.
33. Finish the remaining info/service/NPC-request window semantics.
    Outcome: help, MOTD, uptime, punishments, reward, account-state, banker,
    timbero, priest, enlistador, and related old request/response windows stop
    using placeholder text and match VB6 behavior.
34. Finish the remaining faction/council old response behavior.
    Outcome: the old faction/council UI and command surface, including
    `online_royal_army`, `online_chaos_legion`, and council-management flows,
    do not depend on slash-command-only replacements.
35. Decide the old GM/admin binary packet target.
    Outcome: the exact packet compatibility target is explicit instead of
    implicit.
36. Implement the remaining GM/admin binary packet behavior for that target.
    Outcome: the supported old GM/admin packet family works end-to-end.
37. Implement quests and quest-NPC protocol.
    Outcome: quest state and quest NPC interactions exist on the backend.
38. Implement duels / reto exact flow.
    Outcome: the reto/duel lifecycle matches old server behavior instead of a
    simplified approximation.
39. Implement events / tournaments / lobby events / capture events /
    invasions / global world-event announcements.
    Outcome: server-side event systems match the selected old-server feature
    set, including the old event-lobby protocol where that baseline depends on
    it.
40. Implement auction / subasta.
    Outcome: the old auction backend exists and is reachable through the
    compatible protocol/UI path.
41. Implement mounts if the target data expects mounts separate from
    boats/navigation.
    Outcome: mount behavior is present where the target shard/data requires it.
42. Implement gambling / priest-forgiveness / arena-payment side systems.
    Outcome: gambler flows, priest donation-forgiveness semantics, priced-entry
    travel/arena flows, and the related old economy side systems exist with VB6
    behavior instead of modern substitutes.
43. Implement treasure search.
    Outcome: treasure-search gameplay exists on the backend.
44. Implement forum / in-game message board.
    Outcome: the old in-game board/forum backend exists and persists correctly.
45. Implement marriage.
    Outcome: marriage-related backend state and actions exist.
46. Preserve the disabled guild election semantics from the inspected VB6
    baseline.
    Outcome: guild election packets return the VB6 disabled responses instead
    of assuming elections are live. Live election implementation, if later
    desired, is deferred until after the frontend work.
47. Decide whether the old AO20-era account/lobby/control packet surfaces are
    still in scope.
    Outcome: the old lobby, anti-cheat session packets, feature toggles,
    hotkeys, skin/reset/delete-item flows, and premium/shop or publication
    control surfaces are either explicitly required for parity or explicitly
    cut from scope.
48. If those old AO20-era packet surfaces remain in scope, implement them.
    Outcome: the selected old account/lobby/control packet families exist as
    parity features instead of staying as decoder-only or completely absent
    protocol surfaces.
49. Close any remaining backend drift only by adding a failing parity test
    first.
    Outcome: no undocumented "close enough" backend differences remain.

### Post-Parity Browser And Product Work

50. Run `npm run typecheck` from a clean checkout.
    Outcome: the current browser code passes the static TypeScript gate.
51. Run `npm run build` from a clean checkout.
    Outcome: the production browser bundle builds successfully.
52. Keep client packet decode/encode locked to current server protocol.
    Outcome: browser packet handling does not drift from `ao_protocol`.
53. Add browser-side packet fixture tests using the shared VB6 fixtures.
    Outcome: client protocol compatibility is checked against the same captured
    bytes as the server.
54. Add browser-side decoder fuzz tests.
    Outcome: malformed packet payloads do not crash or corrupt client state.
55. Add browser-side reducer/state tests for inventory.
    Outcome: inventory state stays deterministic under packet sequences.
56. Add browser-side reducer/state tests for bank.
    Outcome: bank state stays deterministic under packet sequences.
57. Add browser-side reducer/state tests for trade.
    Outcome: trade state stays deterministic under packet sequences.
58. Add browser-side reducer/state tests for party and clan.
    Outcome: social state stays deterministic under packet sequences.
59. Add browser-side reducer/state tests for weather and death.
    Outcome: weather/death state stays deterministic under packet sequences.
60. Add browser visual fixture tests for player bodies and equipment overlays.
    Outcome: body/head/equipment composition does not drift visually.
61. Add browser visual fixture tests for common NPC sprites.
    Outcome: skeleton/boar/wolf/ant style mapping regressions are caught early.
62. Keep WebSocket/session bootstrap isolated from gameplay bytes.
    Outcome: browser auth/lobby flow never contaminates AO gameplay packet
    semantics.
63. Decode and dispatch `snow_toggle`.
    Outcome: snow state reaches the browser renderer correctly.
64. Render snow when `snow_toggle` is active.
    Outcome: weather parity is visually complete in the browser.
65. Show trade item name in the trade panel.
    Outcome: the player sees the real item label from packet 100.
66. Show trade item `GRH`/sprite metadata in the trade panel.
    Outcome: trade visuals use the metadata already sent by the server.
67. Show trade item elemental tags in the trade panel.
    Outcome: non-zero item tags are visible instead of hidden protocol data.
68. Show spell cooldown hints.
    Outcome: spell timing constraints are visible before the server rejects the
    cast.
69. Show spell requirement hints.
    Outcome: land/water/staff/dead targeting rules are visible in the browser.
70. Show spell AoE/radius hints.
    Outcome: spell area semantics are visible before cast.
71. Keep NPC sprite/body mappings checked by fixture or screenshot tests.
    Outcome: visual regressions in body-to-sprite mapping are caught early.
72. Make party panels use authoritative state instead of console-text
    inference.
    Outcome: party UI reflects backend truth.
73. Make clan panels use authoritative state instead of console-text inference.
    Outcome: clan UI reflects backend truth.
74. Show party member online state, leader/permissions, and party safe state.
    Outcome: party UI surfaces the real backend state instead of a flat member
    list.
75. Show clan member online state, rank/role, and faction/guild alignment.
    Outcome: clan UI surfaces the real backend state instead of a flat member
    list.
76. Keep faction chat visible as a distinct chat stream.
    Outcome: faction communication is not collapsed into generic log lines.
77. Keep guild chat visible as a distinct chat stream.
    Outcome: guild communication is not collapsed into generic log lines.
78. Keep party chat visible as a distinct chat stream.
    Outcome: party communication is not collapsed into generic log lines.
79. Add clear ghost/dead HUD cues.
    Outcome: dead state is visually obvious in the browser.
80. Disable actions that the dead state will reject anyway.
    Outcome: obvious dead-state rejections are prevented client-side.
81. Add a loading overlay.
    Outcome: map/session transitions are visible instead of abrupt.
82. Add a reconnect overlay.
    Outcome: connection recovery is visible and less confusing.
83. Add a banned error state.
    Outcome: banned users get an explicit browser state instead of a generic
    failure.
84. Add a muted error/state message.
    Outcome: muted users see a clear chat restriction state.
85. Add a server-full error state.
    Outcome: capacity failures are explicit in the browser.
86. Add a maintenance error state.
     Outcome: maintenance mode is explicit in the browser.
87. Add a token-expired error state.
     Outcome: auth/session expiry is explicit in the browser.
88. Add browser music settings.
     Outcome: music can be enabled, disabled, and persisted intentionally.
89. Add browser SFX settings.
     Outcome: sound effects can be enabled, disabled, and persisted
     intentionally.
90. Add browser renderer-quality settings.
     Outcome: users can trade fidelity for performance explicitly.
91. Add browser keybind settings.
     Outcome: controls can be configured instead of hardcoded.
92. Add a minimap if it remains part of the web UX target.
     Outcome: navigation support is explicit instead of ad hoc.
93. Add map markers if they remain part of the web UX target.
     Outcome: navigation targets are explicit instead of ad hoc.
94. Add combat and spell sound effects.
     Outcome: combat feedback is not visually silent.
95. Add inventory and UI sound effects.
     Outcome: inventory and menu interactions have immediate feedback.
96. Add door, teleport, and weather sound effects.
     Outcome: world transitions and ambience have immediate feedback.
97. Add a responsive layout pass for desktop.
     Outcome: the client remains usable on normal desktop browser sizes.
98. Add a responsive layout pass for laptop and common browser zoom levels.
     Outcome: the client remains usable on tighter browser layouts and zoomed
     views.
99. Add web E2E smoke coverage for browser login/lobby flows once they exist.
     Outcome: the account/lobby browser path is tested end-to-end.
100. Add web E2E smoke coverage for connect, map load, and inventory.
     Outcome: the basic gameplay browser path is tested end-to-end.
101. Add web E2E smoke coverage for combat, spells, death, and revive.
     Outcome: the core gameplay browser path is tested end-to-end.
102. Add web E2E smoke coverage for bank, trade, social UI, weather, and
     reconnect.
     Outcome: advanced browser gameplay flows are tested end-to-end.
103. Add `POST /api/auth/login`.
     Outcome: account-level username/password login exists over HTTP.
104. Add `POST /api/auth/google`.
     Outcome: account-level Google login exists over HTTP.
105. Add `GET /api/auth/session`.
     Outcome: browser session restore works without touching the AO socket.
106. Add `POST /api/auth/logout`.
     Outcome: account logout is explicit and clean.
107. Add `GET /api/characters`.
     Outcome: the browser can list account-owned characters.
108. Add `POST /api/characters`.
     Outcome: character creation exists in the account lobby flow.
109. Add `POST /api/characters/:id/session`.
     Outcome: selecting a character yields the token needed for unchanged AO
     socket entry.
110. Support password-only accounts.
     Outcome: the account model works without Google linkage.
111. Support Google-only accounts.
     Outcome: the account model works without a local password.
112. Support linked password+Google accounts.
     Outcome: one account can support both auth methods cleanly.
113. Build the browser username/password login flow.
     Outcome: users can sign in with credentials before the AO session starts.
114. Build the browser session-restore flow.
     Outcome: users can resume account sessions cleanly.
115. Build the browser Google login flow.
     Outcome: Google auth is first-class in the browser, not a token paste
     path.
116. Build the browser Google account-link flow.
     Outcome: existing accounts can attach Google auth cleanly.
117. Build the browser character list flow.
     Outcome: the browser shows owned characters before opening the AO session.
118. Build the browser character creation flow.
     Outcome: the browser can create a new character before opening the AO
     session.
119. Build the browser character selection flow.
     Outcome: the browser chooses a character before opening the AO session.
120. Include race/class choices in the browser character create flow.
     Outcome: browser-side character creation exposes core class/race setup.
121. Include head/home/stat choices in the browser character create flow.
     Outcome: browser-side character creation exposes the remaining setup
     choices the backend expects.
122. Stop using socket `login_new_char` as the primary browser account flow.
     Outcome: account auth and gameplay auth are clearly separated.
123. Launch the AO socket with `login_existing_char(char_id, session_token)`.
     Outcome: gameplay protocol stays unchanged after the HTTP lobby.
124. Prefer same-origin serving or proxying for the account API.
     Outcome: cookies/session handling stays simple.
125. Define supported locales and fallback behavior.
     Outcome: internationalization has an explicit scope instead of ad hoc text
     replacement.
126. Extract browser gameplay UI strings into translation keys.
     Outcome: the in-game browser UI can be localized without editing code in
     place.
127. Extract account, auth, and lobby UI strings into translation keys.
     Outcome: login, session, and character-picking flows can be localized
     cleanly.
128. Separate player-facing server and browser messages from hardcoded
     shard-language text where localization is required.
     Outcome: localizable messages stop being trapped inside gameplay logic.
129. Keep protocol payloads language-neutral where possible.
     Outcome: localization does not require protocol forks for each language.
130. Add locale preference at the account or session level.
     Outcome: language choice is explicit and persistent.
131. Add browser language selection and persistence.
     Outcome: players can switch languages intentionally instead of relying on
     browser defaults only.
132. Add locale-aware number, date, and time formatting.
     Outcome: non-text formatting matches player locale expectations.
133. Verify fonts and glyph coverage for the supported languages.
     Outcome: translated UI and chat do not fail on missing glyphs.
134. Audit chat/input handling for accents, IME, and Unicode edge cases.
     Outcome: players from different language backgrounds can type reliably.
135. Add browser i18n test coverage.
     Outcome: translation keys, fallback behavior, and locale switching stay
     correct under change.
136. Decide which surfaces remain intentionally non-localized.
     Outcome: player names, GM commands, shard-specific content, and other
     exceptions are explicit instead of accidental.
137. Define the multi-realm architecture: one account system, many regional
     worlds.
     Outcome: region support is built on explicit realm boundaries instead of
     cross-region live-state shortcuts.
138. Add realm metadata and realm selection to the account/lobby backend.
     Outcome: the backend can list available realms before gameplay login.
139. Add realm selection to the browser lobby.
     Outcome: players choose a server region before opening the AO session.
140. Show per-realm character availability and state in the browser lobby.
     Outcome: region choice and character choice are visible together.
141. Route character session issuance through the selected realm.
     Outcome: `login_existing_char` tokens become realm-aware without changing
     the gameplay protocol shape.
142. Add deployment and runbook support for multiple regional realms.
     Outcome: the project can operate the same game stack in more than one
     country or region.
143. Add realm-aware monitoring and admin surfaces.
     Outcome: operators can inspect and manage each realm independently.
144. Define the controlled character-transfer policy between realms.
     Outcome: cross-realm movement is an explicit product rule with cooldowns,
     restrictions, and economics.
145. Implement controlled character transfer between realms if it remains in
     scope.
     Outcome: players can move characters across regions through a supported
     flow instead of ad hoc manual intervention.

### Backend Modernization

146. Replace NPC aggro full scans with spatial-grid queries.
     Outcome: hostile NPC target acquisition scales with local visibility, not
     full player count.
147. Replace pet target full scans with bounded or indexed lookup.
     Outcome: pets do not scale linearly with all NPCs on the map.
148. Add outbound backpressure for lagging sessions.
     Outcome: a slow client cannot grow process memory without bound.
149. Add per-MapServer hotspot telemetry.
     Outcome: player count, NPC count, tick duration, mailbox length, and
     broadcast rates are visible per map.
150. Add batch persistence / write-queue strategy for scattered DB writes.
     Outcome: autosave, logout, bank, and guild writes can be hardened and
     scaled without ad hoc call patterns.
151. Pre-resolve `.dat` references at load time where hot-path lookups still
     repeat.
     Outcome: gameplay avoids repeated definition lookups that can be resolved
     once at startup.
152. Unify interest management for players, NPCs, and ground items.
     Outcome: create/remove boundary behavior is consistent across visible world
     entities.
153. Add runtime admin tools for map/process inspection and control.
     Outcome: operators can inspect mailboxes, player counts, force save, and
     restart maps cleanly.
154. Add admin lookup for accounts, characters, and online players.
     Outcome: operators can inspect live and persisted entities.
155. Add admin moderation actions: kick, ban, mute, jail.
     Outcome: basic live moderation exists outside raw gameplay commands.
156. Add admin world actions: item/NPC spawn, teleport, locate.
     Outcome: operator world control exists in one supported surface.
157. Add admin logs and health views.
     Outcome: operators can inspect recent actions and system state quickly.
158. Add metrics and dashboards.
     Outcome: runtime health can be observed without log scraping.
159. Add alerts and release artifacts.
     Outcome: the project is releaseable and operationally monitorable.
160. Add deployment pipeline and backup/restore runbook.
     Outcome: releases and recovery have a documented path.
161. Add TLS for HTTPS and WSS.
     Outcome: production browser/session traffic is encrypted.
162. Add asset CDN/delivery strategy for static resources.
     Outcome: heavy client assets do not depend on the gameplay server path.
163. Add automated backups and database connection-pool tuning.
     Outcome: the database operational path is production-safe.
164. Add runtime-tunable settings for intervals, rates, and formula constants.
     Outcome: live tuning does not require a recompile for every server constant.
165. Verify graceful host shutdown.
     Outcome: shutdown does not lose player state or corrupt runtime processes.
166. Add pre-public scripted load/soak runs.
     Outcome: operational confidence exists before open testing.
167. Add post-parity anti-cheat hardening: movement anomaly scoring, rate
     validation, state-machine validation, economy invariants, structured
     anti-cheat events, and operator visibility.

### Legacy Features Disabled In The Inspected VB6 Baseline

168. If the selected shard explicitly re-enables clan relations, implement the
     live guild alliance/peace proposal, detail, and mailbox flows after the
     frontend and backend-modernization tracks are complete.
     Outcome: the re-enabled shard gets real alliance/peace UI and backend
     behavior without delaying parity for the inspected disabled baseline.
169. If the selected shard explicitly re-enables guild elections, implement the
     live election and democratic succession system after the frontend and
     backend-modernization tracks are complete.
     Outcome: the re-enabled shard gets real election flows without delaying
     parity for the inspected disabled baseline.
     Outcome: speed hacking, packet abuse, duping, and botting signals are
     detected, logged, and acted on systematically without changing legal
     gameplay behavior.

## Checks To Run

Run these on every branch that touches protocol, server gameplay, persistence,
or the web client:

```sh
cd server
mix compile
mix test

cd ../client
npm run typecheck
npm run build
```

When the parity gate exists, also run:

```sh
cd server
mix test test/parity
mix test test/property
mix test test/smoke

cd ../client
npm run test:e2e
```

## Finish Line

Call the compatibility backend finished only when:

- The current automated server/client checks are green from a clean supported
  checkout.
- The automated parity gate is green.
- The database migrates forward on a clean database and on a copy of a real dev
  database.
- A player can complete the scripted smoke journey with the web client.
- A player can complete the same smoke journey with an unmodified VB6 client.
- Known divergences are either fixed or explicitly moved to a post-compatibility
  product backlog.
