# Argentum Unified Roadmap

This is the only roadmap. `CHANGELOG.md` tracks completed work.

## Current Status

- **Backend gameplay:** close for the modern web path, but not full VB6 parity.
  Do not call the backend compatible until the backend tasks below are closed
  or deliberately removed from scope.
- **Parity gate:** partially built. `Balance.dat` parity checks, formula golden
  fixtures, character-creation parity, and a first `MapServer` smoke layer now
  exist. Packet replay, AO socket smoke, broader fuzz/property coverage, and
  load/soak are still open.
- **Backend environment:** the supported `server/` Nix/dev shell compiles and
  tests cleanly, and recent migrations were verified on clean Postgres.
- **Web client:** playable development client. Remaining work is weather/social
  polish, authoritative party/clan state, trade metadata display, browser-side
  parity tests, and session/auth UX polish.
- **Post-compat account flow:** not built. Target is username/password or Google
  account login over HTTP, character selection in the browser, then unchanged
  AO socket login with `login_existing_char(char_id, session_token)`.
- **Code size now:** backend app source is ~16k Elixir LOC; web client source is
  ~15k TypeScript/React/CSS LOC.

## Linear Task List

Backend work comes first. Frontend/browser work starts only after the backend
tasks below are closed or explicitly deferred.

1. Keep the branch clean.
   Outcome: no stray generated files, half-finished migrations, or untracked
   parity tests remain in normal working branches.
2. Finish or isolate any active gameplay patch before unrelated work starts.
   Outcome: parity work does not overlap with half-integrated gameplay edits.
3. Update the top-level roadmap status after every large merge.
   Outcome: the roadmap remains accurate instead of becoming historical fiction.
4. Add packet fixture replay tests from real VB6 client/server traffic.
   Outcome: protocol compatibility is proven by captured traffic, not memory.
5. Expand the current smoke coverage into an AO socket smoke bot for the core
   player journey.
   Outcome: the real protocol path for login, movement, chat, combat, trade,
   and relog can be exercised automatically instead of stopping at direct
   `MapServer` calls.
6. Expand the current formula golden coverage to the remaining VB6 formulas and
   edge cases.
   Outcome: combat, XP, regen, prices, training, and remaining formula edge
   cases are checked against VB6 outputs.
7. Expand packet property/fuzz coverage.
   Outcome: malformed/random bytes do not crash sessions or mutate gameplay
   state silently.
8. Expand lifecycle tests for login/autosave/logout/crash cleanup/transfer.
   Outcome: persistence and ownership transitions stay correct under failure.
9. Expand guild/faction/ban/mute persistence coverage.
   Outcome: shared cross-map state survives restart and migration.
10. Add a load/soak gate.
    Outcome: long-running many-session behavior is tested before public use.
11. Add a manual VB6 release smoke checklist.
    Outcome: every compatibility claim is verified at least once with the
    unmodified VB6 client before release.
12. Finish `/HOGAR` exact VB6 behavior.
    Outcome: home travel matches VB6 end-to-end, including delayed bar/effect,
    jail restricted area, NEWBIE zone, CARCEL trigger, reto/traveling cancel
    behavior, and arrival while still dead.
13. Finish old guild proposal UI behavior.
    Outcome: peace/alliance proposal-list/detail mailbox flows behave like the
    old clan UI and are covered by replay tests.
14. Replace the `gm_message` placeholder route.
    Outcome: `gm_message` becomes a real GM/server broadcast instead of a local
    chat shortcut.
15. Replace the `rain_toggle` placeholder route.
    Outcome: rain toggling becomes a direct backend action instead of chat
    indirection.
16. Implement `role_master_request`.
    Outcome: the remaining decoded-but-unhandled route has real behavior.
17. Keep elemental/rune combat effects data-driven.
    Outcome: elemental tags remain inert unless target data enables them; if it
    does, the combat matrix/effects are implemented without inventing new
    rules.
18. Audit remaining interval/timer clamps against VB6.
    Outcome: regen, hunger/thirst, buff timing, and other periodic behavior do
    not drift on edge intervals.
19. Audit remaining invisibility, NPC AI, and spell-selection edge cases
    against VB6.
    Outcome: the remaining known semantic edge cases are either matched or
    explicitly documented as out of scope.
20. Add authoritative party/clan snapshot packets or a documented backend
    snapshot API for the browser.
    Outcome: frontend party/clan UI can consume backend truth instead of chat
    log inference.
21. Implement trainer skill-group restrictions if target data requires them.
    Outcome: training parity matches the trainer/skill-group rules of the target
    shard instead of "all trainers teach everything".
22. Add out-of-sequence packet validation.
    Outcome: trade/commercial/admin packet families reject invalid state
    transitions instead of relying on happy-path ordering.
23. Expand remaining production recipe coverage to the target data set.
    Outcome: tailoring and any still-missing production recipes are covered if
    the target shard expects them.
24. Finish the remaining old crafting UI packet surface.
    Outcome: old carpenter/blacksmith/alchemy/tailor windows can drive the
    existing crafting backend through open/add/remove/move/craft/close flows.
25. Finish the remaining training/spell window response semantics.
    Outcome: the VB6 client gets the exact remaining responses it still expects
    for train lists, spell info, spell movement, and related flows.
26. Finish the remaining info/service window response semantics.
    Outcome: help, MOTD, uptime, punishments, reward/info/account-balance style
    windows have the remaining old-client responses they need.
27. Finish the remaining faction/council old response behavior.
    Outcome: the old faction/council UI and command surface do not depend on
    slash-command-only replacements.
28. Decide the old GM/admin binary packet target.
    Outcome: the exact packet compatibility target is explicit instead of
    implicit.
29. Implement the remaining GM/admin binary packet behavior for that target.
    Outcome: the supported old GM/admin packet family works end-to-end.
30. Implement quests and quest-NPC protocol.
    Outcome: quest state and quest NPC interactions exist on the backend.
31. Implement duels / reto exact flow.
    Outcome: the reto/duel lifecycle matches old server behavior instead of a
    simplified approximation.
32. Implement events / tournaments / lobby events / capture events /
    invasions / global world-event announcements.
    Outcome: server-side event systems match the selected old-server feature
    set.
33. Implement auction / subasta.
    Outcome: the old auction backend exists and is reachable through the
    compatible protocol/UI path.
34. Implement mounts if the target data expects mounts separate from
    boats/navigation.
    Outcome: mount behavior is present where the target shard/data requires it.
35. Implement gambling / arena-payment side systems.
    Outcome: the remaining economy side systems from the old server exist.
36. Implement treasure search.
    Outcome: treasure-search gameplay exists on the backend.
37. Implement forum / in-game message board.
    Outcome: the old in-game board/forum backend exists and persists correctly.
38. Implement marriage.
    Outcome: marriage-related backend state and actions exist.
39. Implement guild leader elections/democratic succession if the target shard
    requires them.
    Outcome: guild leadership parity matches the selected shard instead of
    stopping at successor promotion only.
40. Decide whether the old account/lobby packet system is still in scope.
    Outcome: either the old account/lobby backend is explicitly required, or
    the HTTP account/character lobby is explicitly accepted as the replacement.
41. If old account/lobby packets remain in scope, implement them.
    Outcome: the old account/lobby backend exists as a parity feature, not a
    future maybe.
42. Close any remaining backend drift only by adding a failing parity test
    first.
    Outcome: no undocumented "close enough" backend differences remain.
43. Replace NPC aggro full scans with spatial-grid queries.
    Outcome: hostile NPC target acquisition scales with local visibility, not
    full player count.
44. Replace pet target full scans with bounded or indexed lookup.
    Outcome: pets do not scale linearly with all NPCs on the map.
45. Add outbound backpressure for lagging sessions.
    Outcome: a slow client cannot grow process memory without bound.
46. Add per-MapServer hotspot telemetry.
    Outcome: player count, NPC count, tick duration, mailbox length, and
    broadcast rates are visible per map.
47. Add batch persistence / write-queue strategy for scattered DB writes.
    Outcome: autosave, logout, bank, and guild writes can be hardened and
    scaled without ad hoc call patterns.
48. Pre-resolve `.dat` references at load time where hot-path lookups still
    repeat.
    Outcome: gameplay avoids repeated definition lookups that can be resolved
    once at startup.
49. Unify interest management for players, NPCs, and ground items.
    Outcome: create/remove boundary behavior is consistent across visible world
    entities.
50. Add runtime admin tools for map/process inspection and control.
    Outcome: operators can inspect mailboxes, player counts, force save, and
    restart maps cleanly.
51. Add admin lookup for accounts, characters, and online players.
    Outcome: operators can inspect live and persisted entities.
52. Add admin moderation actions: kick, ban, mute, jail.
    Outcome: basic live moderation exists outside raw gameplay commands.
53. Add admin world actions: item/NPC spawn, teleport, locate.
    Outcome: operator world control exists in one supported surface.
54. Add admin logs and health views.
    Outcome: operators can inspect recent actions and system state quickly.
55. Add metrics and dashboards.
    Outcome: runtime health can be observed without log scraping.
56. Add alerts and release artifacts.
    Outcome: the project is releaseable and operationally monitorable.
57. Add deployment pipeline and backup/restore runbook.
    Outcome: releases and recovery have a documented path.
58. Add TLS for HTTPS and WSS.
    Outcome: production browser/session traffic is encrypted.
59. Add asset CDN/delivery strategy for static resources.
    Outcome: heavy client assets do not depend on the gameplay server path.
60. Add automated backups and database connection-pool tuning.
    Outcome: the database operational path is production-safe.
61. Add runtime-tunable settings for intervals, rates, and formula constants.
    Outcome: live tuning does not require a recompile for every server constant.
62. Verify graceful host shutdown.
    Outcome: shutdown does not lose player state or corrupt runtime processes.
63. Add pre-public scripted load/soak runs.
    Outcome: operational confidence exists before open testing.
64. Run `npm run typecheck` from a clean checkout.
    Outcome: the current browser code passes the static TypeScript gate.
65. Run `npm run build` from a clean checkout.
    Outcome: the production browser bundle builds successfully.
66. Keep client packet decode/encode locked to current server protocol.
    Outcome: browser packet handling does not drift from `ao_protocol`.
67. Add browser-side packet fixture tests using the shared VB6 fixtures.
    Outcome: client protocol compatibility is checked against the same captured
    bytes as the server.
68. Add browser-side decoder fuzz tests.
    Outcome: malformed packet payloads do not crash or corrupt client state.
69. Add browser-side reducer/state tests for inventory.
    Outcome: inventory state stays deterministic under packet sequences.
70. Add browser-side reducer/state tests for bank.
    Outcome: bank state stays deterministic under packet sequences.
71. Add browser-side reducer/state tests for trade.
    Outcome: trade state stays deterministic under packet sequences.
72. Add browser-side reducer/state tests for party and clan.
    Outcome: social state stays deterministic under packet sequences.
73. Add browser-side reducer/state tests for weather and death.
    Outcome: weather/death state stays deterministic under packet sequences.
74. Add browser visual fixture tests for player bodies and equipment overlays.
    Outcome: body/head/equipment composition does not drift visually.
75. Add browser visual fixture tests for common NPC sprites.
    Outcome: skeleton/boar/wolf/ant style mapping regressions are caught early.
76. Keep WebSocket/session bootstrap isolated from gameplay bytes.
    Outcome: browser auth/lobby flow never contaminates AO gameplay packet
    semantics.
77. Decode and dispatch `snow_toggle`.
    Outcome: snow state reaches the browser renderer correctly.
78. Render snow when `snow_toggle` is active.
    Outcome: weather parity is visually complete in the browser.
79. Show trade item name in the trade panel.
    Outcome: the player sees the real item label from packet 100.
80. Show trade item `GRH`/sprite metadata in the trade panel.
    Outcome: trade visuals use the metadata already sent by the server.
81. Show trade item elemental tags in the trade panel.
    Outcome: non-zero item tags are visible instead of hidden protocol data.
82. Show spell cooldown hints.
    Outcome: spell timing constraints are visible before the server rejects the
    cast.
83. Show spell requirement hints.
    Outcome: land/water/staff/dead targeting rules are visible in the browser.
84. Show spell AoE/radius hints.
    Outcome: spell area semantics are visible before cast.
85. Keep NPC sprite/body mappings checked by fixture or screenshot tests.
    Outcome: visual regressions in body-to-sprite mapping are caught early.
86. Make party panels use authoritative state instead of console-text
    inference.
    Outcome: party UI reflects backend truth.
87. Make clan panels use authoritative state instead of console-text inference.
    Outcome: clan UI reflects backend truth.
88. Show party member online state, leader/permissions, and party safe state.
    Outcome: party UI surfaces the real backend state instead of a flat member
    list.
89. Show clan member online state, rank/role, and faction/guild alignment.
    Outcome: clan UI surfaces the real backend state instead of a flat member
    list.
90. Keep faction chat visible as a distinct chat stream.
    Outcome: faction communication is not collapsed into generic log lines.
91. Keep guild chat visible as a distinct chat stream.
    Outcome: guild communication is not collapsed into generic log lines.
92. Keep party chat visible as a distinct chat stream.
    Outcome: party communication is not collapsed into generic log lines.
93. Add clear ghost/dead HUD cues.
    Outcome: dead state is visually obvious in the browser.
94. Disable actions that the dead state will reject anyway.
    Outcome: obvious dead-state rejections are prevented client-side.
95. Add a loading overlay.
    Outcome: map/session transitions are visible instead of abrupt.
96. Add a reconnect overlay.
    Outcome: connection recovery is visible and less confusing.
97. Add a banned error state.
    Outcome: banned users get an explicit browser state instead of a generic
    failure.
98. Add a muted error/state message.
    Outcome: muted users see a clear chat restriction state.
99. Add a server-full error state.
    Outcome: capacity failures are explicit in the browser.
100. Add a maintenance error state.
     Outcome: maintenance mode is explicit in the browser.
101. Add a token-expired error state.
     Outcome: auth/session expiry is explicit in the browser.
102. Add browser music settings.
     Outcome: music can be enabled, disabled, and persisted intentionally.
103. Add browser SFX settings.
     Outcome: sound effects can be enabled, disabled, and persisted
     intentionally.
104. Add browser renderer-quality settings.
     Outcome: users can trade fidelity for performance explicitly.
105. Add browser keybind settings.
     Outcome: controls can be configured instead of hardcoded.
106. Add a minimap if it remains part of the web UX target.
     Outcome: navigation support is explicit instead of ad hoc.
107. Add map markers if they remain part of the web UX target.
     Outcome: navigation targets are explicit instead of ad hoc.
108. Add combat and spell sound effects.
     Outcome: combat feedback is not visually silent.
109. Add inventory and UI sound effects.
     Outcome: inventory and menu interactions have immediate feedback.
110. Add door, teleport, and weather sound effects.
     Outcome: world transitions and ambience have immediate feedback.
111. Add a responsive layout pass for desktop.
     Outcome: the client remains usable on normal desktop browser sizes.
112. Add a responsive layout pass for laptop and common browser zoom levels.
     Outcome: the client remains usable on tighter browser layouts and zoomed
     views.
113. Add web E2E smoke coverage for browser login/lobby flows once they exist.
     Outcome: the account/lobby browser path is tested end-to-end.
114. Add web E2E smoke coverage for connect, map load, and inventory.
     Outcome: the basic gameplay browser path is tested end-to-end.
115. Add web E2E smoke coverage for combat, spells, death, and revive.
     Outcome: the core gameplay browser path is tested end-to-end.
116. Add web E2E smoke coverage for bank, trade, social UI, weather, and
     reconnect.
     Outcome: advanced browser gameplay flows are tested end-to-end.
117. Add `POST /api/auth/login`.
     Outcome: account-level username/password login exists over HTTP.
118. Add `POST /api/auth/google`.
     Outcome: account-level Google login exists over HTTP.
119. Add `GET /api/auth/session`.
     Outcome: browser session restore works without touching the AO socket.
120. Add `POST /api/auth/logout`.
     Outcome: account logout is explicit and clean.
121. Add `GET /api/characters`.
     Outcome: the browser can list account-owned characters.
122. Add `POST /api/characters`.
     Outcome: character creation exists in the account lobby flow.
123. Add `POST /api/characters/:id/session`.
     Outcome: selecting a character yields the token needed for unchanged AO
     socket entry.
124. Support password-only accounts.
     Outcome: the account model works without Google linkage.
125. Support Google-only accounts.
     Outcome: the account model works without a local password.
126. Support linked password+Google accounts.
     Outcome: one account can support both auth methods cleanly.
127. Build the browser username/password login flow.
     Outcome: users can sign in with credentials before the AO session starts.
128. Build the browser session-restore flow.
     Outcome: users can resume account sessions cleanly.
129. Build the browser Google login flow.
     Outcome: Google auth is first-class in the browser, not a token paste
     path.
130. Build the browser Google account-link flow.
     Outcome: existing accounts can attach Google auth cleanly.
131. Build the browser character list flow.
     Outcome: the browser shows owned characters before opening the AO session.
132. Build the browser character creation flow.
     Outcome: the browser can create a new character before opening the AO
     session.
133. Build the browser character selection flow.
     Outcome: the browser chooses a character before opening the AO session.
134. Include race/class choices in the browser character create flow.
     Outcome: browser-side character creation exposes core class/race setup.
135. Include head/home/stat choices in the browser character create flow.
     Outcome: browser-side character creation exposes the remaining setup
     choices the backend expects.
136. Stop using socket `login_new_char` as the primary browser account flow.
     Outcome: account auth and gameplay auth are clearly separated.
137. Launch the AO socket with `login_existing_char(char_id, session_token)`.
     Outcome: gameplay protocol stays unchanged after the HTTP lobby.
138. Prefer same-origin serving or proxying for the account API.
     Outcome: cookies/session handling stays simple.

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
