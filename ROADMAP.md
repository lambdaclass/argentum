# Argentum Roadmap

This file lists remaining work only. Completed work lives in `CHANGELOG.md`.
Testing rule: every runtime-safety, security, authority, persistence, and
economy task must land with a regression test for the abuse or failure path.
Parity tasks require golden/replay coverage. Browser state tasks require
reducer, contract, E2E, or visual coverage as appropriate.

## Phase 1. Maintenance

Execution order is literal at the top of the file: clear the known red suites
first, then finish or isolate half-finished active patches, then continue into
the parity phases below.

1. Fix the currently known failing bug/regression suites before any new
   parity, hardening, or feature work.
   **#1 is done.** All 6 suites green: `SpellAuthority`, `MerchantSession`,
   `SelectedNpcAccountReward`, `ChatAuthority`, `SupportRequestRateLimit`,
   `SessionLifecycle` (22 tests). 315 total tests, 0 failures.
   Outcome: the main line is green again on the currently known red suites, so
   new parity work starts from a trustworthy baseline.

2. Finish or isolate any active gameplay patch before unrelated work starts.
   Outcome: parity work does not overlap with half-integrated gameplay edits.

3. Keep the branch clean and update the top-level roadmap status after every
   large merge.
   Outcome: no stray generated files, half-finished migrations, or untracked
   parity tests remain on the main line, and the roadmap stays accurate instead
   of becoming historical fiction.

## Phase 2. Parity-Required Rules And Backend Behavior

These items come before modern hardening because the first priority is to make
the game behave like the inspected VB6 baseline.

4. Finish remaining trade-start validation gaps.
    **Done**: meditating, navigating, paralyzed checks; distance, target-dead,
    target-busy, already-trading checks. **Still open**: safe-zone
    restrictions on player-to-player trade initiation, same-map visibility
    recheck after request is accepted.
    Outcome: player-trade start matches the inspected VB6 safety rules.
    Tests required: safe-zone trade-initiation abuse tests and trade-accept
    visibility/map-drift revalidation tests.

5. Keep guild invite and request authority proven under DB-backed flows.
   **Done**: expired invite check at accept time, inviter-still-leads check,
   pending-request-required check, and consume-invite/request only after
   durable success. Failure-path tests added for accept_invite, accept_request,
   kick, and leave DB failures (synthetic fixtures — ETS consistency proven).
   **Still open**: DB-backed failure-path tests with real persisted guild/request
   rows for full end-to-end coverage, plus the remaining DB-failure semantics
   on `request_membership` and `list_requests` so persistence outage does not
   look like a normal authority rejection or an empty request queue.
   Outcome: guild invite/request authority stays correct even when persistence
   fails or guild state changes between issue and accept.
   Tests required: inviter-loses-leadership, inviter-leaves-guild,
   guild-deleted, expired-invite-without-cleanup, accept-request-without-
   request, request/invite preserved on DB failure, `request_membership`
   DB-failure-not-`already_requested`, `list_requests` DB-failure-not-empty,
   and DB-backed revalidation tests that fail only on missing authority
   checks, not because synthetic fixtures return `{:error, :db_error}` first.

6. Restore VB6 `leave_faction` restrictions.
    Outcome: faction leave requires the correct enlistador interaction and
    preserves the old aligned-clan restrictions/side effects instead of the
    current looser behavior.
    Tests required: leave without enlistador, leave with wrong enlistador,
    aligned-clan restriction cases, and no-side-effect regressions on reject.

7. Restore selected-NPC semantics for account-state and reward flows.
    **Done**: `last_clicked_npc_type` set on NPC double-click for banker,
    timbero, and enlistador. `handle_request_account_state` and
    `handle_request_reward` check clicked type instead of proximity scan.
    Adversarial tests pass (3 tests: nearby-banker, nearby-timbero,
    nearby-enlistador all correctly rejected without explicit click).
    **Still open**: wrong-NPC, stale-selection, out-of-range, and spoofed
    selected-NPC attempts for account-state and reward requests.
    Outcome: banker, timbero, and enlistador requests use the actual targeted
    NPC and correct faction-side checks instead of any nearby NPC of the right
    type.

8. Align the remaining merchant/account-state behavior with the inspected VB6
    backend.
    **Partial**: `merchant_still_valid?/3` validates NPC is still alive in
    `npcs_live` and player within 3 tiles before buy/sell. 4 adversarial tests
    pass (MerchantSessionAuthorityTest: despawned buy/sell, far-away buy/sell).
    **Still open**: remaining old item rules, timbero account-state text/value
    semantics drift.
    Outcome: merchant sell restrictions such as the remaining old item rules,
    and the timbero account-state text/value semantics, stop drifting from the
    VB6 baseline.

9. Close the remaining interaction-radius and bank-open guard drifts.
    Outcome: NPC interaction radii and the old "already trading" bank-open
    rule match the inspected VB6 behavior instead of stricter or looser
    approximations.
    Tests required: boundary-radius adversarial cases, bank-open while
    trading, and stale-session/radius-drift regressions.

10. Audit remaining invisibility, NPC AI, and spell-selection edge cases
    against VB6.
    Outcome: the remaining known semantic edge cases are either matched or
    explicitly documented as out of scope.

11. Finish the remaining info/service/NPC-request window semantics.
    Outcome: help, MOTD, uptime, punishments, reward, account-state, banker,
    timbero, priest, enlistador, and related old request/response windows stop
    using placeholder text and match VB6 behavior.

12. Decide the old GM/admin binary packet target.
    Outcome: the exact packet compatibility target is explicit instead of
    implicit.

13. Implement the remaining GM/admin binary packet behavior for that target.
    Outcome: the supported old GM/admin packet family works end-to-end.

14. Implement events / tournaments / lobby events / capture events /
    invasions / global world-event announcements.
    Outcome: server-side event systems match the selected old-server feature
    set, including the old event-lobby protocol where that baseline depends on
    it.

15. Decide whether the old AO20-era account/lobby/control packet surfaces are
    still in scope.
    Outcome: the old lobby, anti-cheat session packets, feature toggles,
    hotkeys, skin/reset/delete-item flows, and premium/shop or publication
    control surfaces are either explicitly required for parity or explicitly
    cut from scope.

16. If those old AO20-era packet surfaces remain in scope, implement them.
    Outcome: the selected old account/lobby/control packet families exist as
    parity features instead of staying as decoder-only or completely absent
    protocol surfaces.

17. Close any remaining backend drift only by adding a failing parity test
    first.
    Outcome: no undocumented "close enough" backend differences remain.

18. Fix map-transfer and reconnect edge cases uncovered by lifecycle and
    replay tests.
    Outcome: map transfer, mid-transfer disconnect, and reconnect-after-transfer
    work correctly instead of leaving ghost sessions or losing player state.

## Phase 3. Parity Proof

19. Expand the current formula golden coverage to the remaining VB6 formulas
    and edge cases.
    Outcome: combat, XP, regen, prices, training, and remaining formula edge
    cases are checked against VB6 outputs.

20. Add `ao_session` unit tests for session-state transitions and protocol
    invariants.
    Outcome: session-level packet handling and state transitions are covered
    below the TCP smoke layer.

21. Add spell-effect golden tests for legacy spells and their edge cases.
    Outcome: individual spell outputs and side effects are checked against the
    VB6 baseline instead of only broad combat formulas.

22. Add pet/taming parity tests.
    Outcome: pet follow/attack/taming behavior is proven under the same parity
    gate as player combat and movement.

23. Add concurrent combat integration tests with multiple live clients.
    Outcome: two-client and multi-actor combat ordering is verified instead of
    assuming single-session happy paths.

24. Expand lifecycle tests for login/autosave/logout/crash cleanup/transfer.
   **Partial**: crash-then-re-login, double crash, online directory cleanup,
   and graceful-vs-crash save semantics are covered. Still open: map transfer
   edge cases, autosave timing under load, multi-map transfer chains,
   cleanup DB failure behavior, autosave flush timeout behavior, autosave
   worker-crash/start-failure behavior, stale autosave-vs-cleanup ordering,
   and explicit graceful-disconnect behavior under final-save failure.
   Shutdown-started command races and pending-autosave behavior during
   graceful shutdown are now covered by shutdown drain tests (#35).
   Outcome: persistence and ownership transitions stay correct under failure.

25. Expand guild/faction/ban/mute persistence coverage.
    Outcome: shared cross-map state survives restart and migration.

26. Add a high-load bot benchmark as part of the load/soak gate.
    Outcome: the parity gate includes an explicit many-session benchmark, not
    just ad hoc long-running tests.

27. Add a load/soak gate.
    Outcome: long-running many-session behavior is tested before public use.

28. Define the exact parity-gate required suites.
    Outcome: "parity gate green" means a concrete, documented set of passing
    suites instead of a vague status label.

29. **BLOCKED on Windows/VB6 environment.** Build and version a real VB6
    packet-capture corpus using `mix capture.packets` against an unmodified
    VB6 client.
    Outcome: replay tests have captured byte fixtures from the real old client
    instead of ad hoc locally built packet sequences, and the capture workflow
    is part of the normal parity toolchain.
    **Cannot proceed until a Windows environment with VB6 toolchain is
    available.**

30. **BLOCKED on #29.** Add packet replay coverage for login, character
    creation, and session bootstrap.
    Outcome: authentication and initial game-state delivery are proven against
    captured traffic.

31. **BLOCKED on #29.** Add packet replay coverage for movement, map transfer,
    chat, and info/service requests.
    Outcome: common non-combat session flows are proven against captured
    traffic.

32. **BLOCKED on #29.** Add packet replay coverage for inventory, equip/use,
    combat, spells, and death.
    Outcome: the core gameplay packet loops are proven against captured
    traffic.

33. **BLOCKED on #29.** Add packet replay coverage for bank, trade, party,
    guild, faction, reconnect, and logout.
    Outcome: the remaining social/economy/session packet flows are proven
    against captured traffic.

## Phase 4. Critical Runtime Safety

These items address live data-loss risks and production crash risks. They
remain important infrastructure work, but the roadmap puts VB6 parity first.
Authoritative gameplay and economy writes stay sync-first. Existing async DB
writes are temporary exceptions to contain, not a model to expand.
While a player is online, in-memory state stays authoritative; the DB is the
offline source of truth and the target of explicit durable commit boundaries.
Autosave remains a best-effort snapshot path, not the commit point for economy
or permission changes.

34. Implement the sync-first persistence boundary (broader architecture).
   Audit all `GameBackend.*` write sites. Keep authoritative writes explicit
   and synchronous by default: logout/cleanup, bank, trade,
   inventory/equipment, guild membership/invites, and other economy-affecting
   state changes. Replace ad hoc write triggers with clear persistence
   boundaries, but do not turn them into write-behind caches. Treat autosave
   as a best-effort snapshot path unless telemetry later proves a stronger
   async design is needed. Only consider ordered async writers after the
   sync-first path is correct, observable, and demonstrably too slow.
   See [research/arena-authoritative-persistence-and-refactor.md](research/arena-authoritative-persistence-and-refactor.md).
   Outcome: authoritative state changes commit through explicit sync
   boundaries; async persistence remains limited, intentional, and
   observable instead of becoming the default model.
   Tests required: authoritative persistence regressions for logout/cleanup,
   bank, trade, inventory/equipment, guild membership/invites, and failure
   cases that must leave in-memory and durable state consistent.
   Progress: guild fire-and-forget writes replaced with sync helpers (done);
   bank operations reordered to DB-first with failure rollback (done); guild
   membership/invite/request/relation paths reordered to DB-first and hardened
   against DB exceptions (done).
   AutosaveWriter worker model replaced with `spawn_monitor/1` (unlinked +
   monitored, worker crash cannot take down the writer). Flush reliable under
   worker-crash paths. Cleanup/logout "log and proceed" behavior is now explicit
   and tested (cleanup_save_failed telemetry + logging). Kick/leave `{0, nil}`
   bug fixed (Repo.delete_all returning zero rows treated as error). 7 failure-
   path tests added (guild accept_invite/request/kick/leave DB failure, autosave
   worker-death recovery, cleanup_save_failed telemetry).
   Trade boundary done: `execute_trade` now persists both players atomically
   via `save_trade_snapshots/2` before mutating in-memory state; on DB failure
   both players stay unchanged. 5 trade persistence tests added.
   Guild DB-failure semantics fixed: `request_membership` returns `:db_error`
   (not `:already_requested`) on DB failure; `list_requests` returns
   `{:error, :db_error}` (not empty list). Cleanup/logout final-save policy
   documented as accepted best-effort under DB failure, with telemetry and
   logging. Authoritative writes (trade, bank, guild) are the true commit
   boundaries.
   **#34 is done.** All authoritative write paths (guild, bank, trade) are
   sync-first. Cleanup is documented best-effort with observability.

35. Verify graceful host shutdown.
   Depends on #34 — shutdown verification is more meaningful once the
   persistence path is less ad hoc.
   Outcome: shutdown does not lose player state or corrupt runtime processes.
   **#35 is done.** Coordinated shutdown drain via `prep_stop/1`:
   ShutdownDrain stops TCP/WS listeners, sends `:shutdown_drain` to all
   transport pids, polls until sessions drain or timeout. AutosaveWriter
   `terminate/2` waits up to 10s for in-flight writes and drains pending
   coalesced snapshots. TCP ClientHandler and WS WsHandler handle
   `:shutdown_drain` with cleanup + close. Global `shutdown_in_progress?`
   gate via `:persistent_term` rejects commands arriving after drain starts.
   Contract: must-finish (authoritative writes, registry cleanup),
   best-effort (autosave including pending coalesced snapshots),
   may-drop (new connections/commands after shutdown begins).
   Telemetry for all 6 shutdown phases. 9 tests: empty drain, session drain,
   in-flight autosave, terminate flush, pending autosave drain, shutdown gate,
   telemetry contract (2), crash-vs-graceful contrast.

## Phase 5. Security And Hardening

These items harden the server after parity-required behavior is in place.
Every task in this phase closes only with an adversarial regression for the
abuse path plus a normal-path control test.

36. Enforce mute/dead/cooldown rules on guild and party chat.
    **#36 is done.** Mute check on `guild_message` binary packet, dead check
    on `/CC` text guild chat path, mute+cooldown checks on `grupo_msg` party
    chat. 4 adversarial tests pass (ChatAuthorityTest).
    Outcome: all social chat paths follow the same moderation and spam rules,
    not just normal chat and faction chat.

37. Rate-limit `question_gm` and `role_master_request`.
    **#37 is done.** ETS-based per-character cooldown (30s) on both handlers.
    Second immediate call returns rate-limit message and does not broadcast
    to GMs. 2 adversarial tests pass (SupportRequestRateLimitTest).
    Outcome: support/admin channels cannot be flooded even when packet replay
    protection is already in place.

38. Keep the exploit and parity audit executable.
   Outcome: every bug above has a regression test in the adversarial/parity
   suites, and roadmap comments are updated when a gap is fixed so audit
   notes do not become stale folklore.
   Tests required: keep the adversarial suites runnable in CI and update them
   whenever a security or authority fix lands, including guild
   invite/request-consumption failures, guild DB-failure survival on kick/leave
   and related membership paths, cleanup final-save failure, and autosave
   worker/flush failure regressions.

39. Add anti-cheat hardening: movement anomaly scoring, rate validation,
    state-machine validation, economy invariants, structured anti-cheat
    events, and operator visibility.
    Outcome: speed hacking, packet abuse, duping, and botting signals are
    detected, logged, and acted on systematically without changing legal
    gameplay behavior.
    Tests required: adversarial movement/packet/economy fixtures that prove
    detection triggers on abuse and stays quiet on legal gameplay.

## Phase 6. Observability And Ops

40. Finish telemetry wiring and make emitted events operationally useful.
    **Partial**: events emit for map ticks, movement, broadcasts, combat
    (attack/spell), persistence (cleanup/autosave), session (login/crash).
    **Still open**: PromEx/Prometheus reporter initialization, Grafana
    dashboard wiring, bank and guild_write events, per-map cardinality
    strategy.
    Outcome: the telemetry stack is live and feeding real dashboards, not just
    emitting events into the void.

41. Add metrics and dashboards.
    Outcome: Prometheus and Grafana reflect real telemetry for map ticks,
    movement, broadcasts, persistence latency/failure, crash cleanup, and
    reconnect behavior instead of placeholder dashboards with no backing
    events.

42. Add alerts.
    Outcome: critical runtime and operational failures page operators before
    they become player-visible incidents.

43. Add runtime admin tools for map/process inspection and control.
    Outcome: operators can inspect mailboxes, player counts, force save, and
    restart maps cleanly.

44. Add admin lookup for accounts, characters, and online players.
    Outcome: operators can inspect live and persisted entities.

45. Add admin moderation actions: kick, ban, mute, jail.
    Outcome: basic live moderation exists outside raw gameplay commands.

46. Add admin world actions: item/NPC spawn, teleport, locate.
    Outcome: operator world control exists in one supported surface.

47. Add admin logs and health views.
    Outcome: operators can inspect recent actions and system state quickly.

## Phase 7. Backend Architecture

Code quality and performance improvements that follow the earlier runtime
safety, security, observability, and parity phases.

48. Replace NPC aggro full scans with spatial-grid queries.
    Outcome: hostile NPC target acquisition scales with local visibility, not
    full player count.

49. Replace pet target full scans with bounded or indexed lookup.
    Outcome: pets do not scale linearly with all NPCs on the map.

50. Introduce handler effects only where they remove real coupling: GM audit
    logs, persistence operations, and packet broadcasts in bank/trade/autosave
    paths. Start with the bank, autosave, and guild control-plane paths that
    currently mix inline side effects and fire-and-forget background writes.
    Do not do a full `{state, effects}` rewrite.
    Outcome: low-frequency persistence/audit/control-plane paths are decoupled
    from inline send calls and ad hoc `Task.start` write triggers.

51. Split guild_server.ex into focused modules: GuildServer (shell),
    GuildMembership, GuildRequests, GuildRelations, GuildContent,
    GuildPersistence. Last remaining god-module.
    Outcome: guild domain logic is navigable and testable per-concern instead
    of one 1,500+ line file mixing membership, diplomacy, and DB writes.

52. Pre-resolve `.dat` references at load time where hot-path lookups still
    repeat.
    Outcome: gameplay avoids repeated definition lookups that can be resolved
    once at startup.

53. Unify interest management for players, NPCs, and ground items.
    Outcome: create/remove boundary behavior is consistent across visible world
    entities.

54. Add runtime-tunable settings for intervals, rates, and formula constants.
    Outcome: live tuning does not require a recompile for every server constant.

## Phase 8. Deployment And Release

55. Add release artifacts, deployment pipeline, and backup/restore runbook.
    Outcome: releases and recovery have a documented path.

56. Add TLS for HTTPS and WSS.
    Outcome: production browser/session traffic is encrypted.

57. Add asset CDN/delivery strategy for static resources.
    Outcome: heavy client assets do not depend on the gameplay server path.

58. Add automated backups and database connection-pool tuning.
    Outcome: the database operational path is production-safe.

59. Define live database migration strategy: expand/contract migrations,
    backward-compatible deploy window, rollback rules, and data backfill
    policy.
    Outcome: schema changes can be applied safely to a running system with
    players online, without requiring downtime or risking data loss.

60. Add pre-public scripted load/soak runs.
    Outcome: operational confidence exists before open testing.

## Phase 9. Legacy Features Disabled In The Inspected VB6 Baseline

61. If the selected shard explicitly re-enables clan relations, implement the
    live guild alliance/peace proposal, detail, and mailbox flows after the
    backend-modernization track is complete.
    Outcome: the re-enabled shard gets real alliance/peace UI and backend
    behavior without delaying parity for the inspected disabled baseline; any
    browser UI work stays in the final frontend/product track.

62. If the selected shard explicitly re-enables guild elections, implement the
    live election and democratic succession system after the
    backend-modernization track is complete.
    Outcome: the re-enabled shard gets real election flows without delaying
    parity for the inspected disabled baseline; any browser UI work stays in
    the final frontend/product track.

## Phase 10. Browser Proof

63. Run `npm run typecheck` from a clean checkout.
    Outcome: the current browser code passes the static TypeScript gate.

64. Run `npm run build` from a clean checkout.
    Outcome: the production browser bundle builds successfully.

65. Keep client packet decode/encode locked to current server protocol.
    Outcome: browser packet handling does not drift from `ao_protocol`.

66. Add browser-side packet fixture tests using the shared VB6 fixtures.
    Outcome: client protocol compatibility is checked against the same captured
    bytes as the server.

67. Add browser-side decoder fuzz tests.
    Outcome: malformed packet payloads do not crash or corrupt client state.

68. Add browser-side reducer/state tests for inventory.
    Outcome: inventory state stays deterministic under packet sequences.

69. Add browser-side reducer/state tests for bank.
    Outcome: bank state stays deterministic under packet sequences.

70. Add browser-side reducer/state tests for trade.
    Outcome: trade state stays deterministic under packet sequences.

71. Add browser-side reducer/state tests for party and clan.
    Outcome: social state stays deterministic under packet sequences.

72. Add browser-side reducer/state tests for weather and death.
    Outcome: weather/death state stays deterministic under packet sequences.

73. Add browser visual fixture tests for player bodies and equipment overlays.
    Outcome: body/head/equipment composition does not drift visually.

74. Add browser visual fixture tests for common NPC sprites.
    Outcome: skeleton/boar/wolf/ant style mapping regressions are caught early.

75. Keep WebSocket/session bootstrap isolated from gameplay bytes.
    Outcome: browser auth/lobby flow never contaminates AO gameplay packet
    semantics.

76. Keep NPC sprite/body mappings checked by fixture or screenshot tests.
    Outcome: visual regressions in body-to-sprite mapping are caught early.

77. Add web E2E smoke coverage for browser login/lobby flows once they exist.
    Outcome: the account/lobby browser path is tested end-to-end.

78. Add web E2E smoke coverage for connect, map load, and inventory.
    Outcome: the basic gameplay browser path is tested end-to-end.

79. Add web E2E smoke coverage for combat, spells, death, and revive.
    Outcome: the core gameplay browser path is tested end-to-end.

80. Add web E2E smoke coverage for bank, trade, social UI, weather, and
    reconnect.
    Outcome: advanced browser gameplay flows are tested end-to-end.

## Phase 11. Frontend Product And UX

81. Make party panels use authoritative state instead of console-text
    inference.
    Outcome: party UI reflects backend truth.

82. Make clan panels use authoritative state instead of console-text inference.
    Outcome: clan UI reflects backend truth.

83. Show party member online state, leader/permissions, and party safe state.
    Outcome: party UI surfaces the real backend state instead of a flat member
    list.

84. Show clan member online state, rank/role, and faction/guild alignment.
    Outcome: clan UI surfaces the real backend state instead of a flat member
    list.

85. Keep faction chat visible as a distinct chat stream.
    Outcome: faction communication is not collapsed into generic log lines.

86. Keep guild chat visible as a distinct chat stream.
    Outcome: guild communication is not collapsed into generic log lines.

87. Keep party chat visible as a distinct chat stream.
    Outcome: party communication is not collapsed into generic log lines.

88. Do not add a browser graphics-quality menu by default; only add optional
    visual preferences if profiling later proves a real need.
    Outcome: the 2D client stays fast by design instead of outsourcing
    performance to a quality menu.

89. Add map markers if they remain part of the web UX target.
    Outcome: navigation targets are explicit instead of ad hoc.

90. Add combat and spell sound effects.
    Outcome: combat feedback is not visually silent.

91. Add inventory and UI sound effects.
    Outcome: inventory and menu interactions have immediate feedback.

92. Add door, teleport, and weather sound effects.
    Outcome: world transitions and ambience have immediate feedback.

93. Add a responsive layout pass for desktop.
    Outcome: the client remains usable on normal desktop browser sizes.

94. Add a responsive layout pass for laptop and common browser zoom levels.
    Outcome: the client remains usable on tighter browser layouts and zoomed
    views.

## Phase 12. Browser Account And Lobby

95. Add `POST /api/auth/google`.
    Outcome: account-level Google login exists over HTTP.

96. Support Google-only accounts.
    Outcome: the account model works without a local password.

97. Support linked password+Google accounts.
    Outcome: one account can support both auth methods cleanly.

98. Build the browser Google login flow.
    Outcome: Google auth is first-class in the browser, not a token paste
    path.

99. Build the browser Google account-link flow.
    Outcome: existing accounts can attach Google auth cleanly.

100. Add browser stat choices to the character create flow.
    Outcome: browser-side character creation exposes stat setup instead of
    relying only on defaults; head and home choices are already landed.

## Phase 13. Localization

101. Define supported locales and fallback behavior.
     Outcome: internationalization has an explicit scope instead of ad hoc text
     replacement.

102. Extract browser gameplay UI strings into translation keys.
     Outcome: the in-game browser UI can be localized without editing code in
     place.

103. Extract account, auth, and lobby UI strings into translation keys.
     Outcome: login, session, and character-picking flows can be localized
     cleanly.

104. Separate player-facing server and browser messages from hardcoded
     shard-language text where localization is required.
     Outcome: localizable messages stop being trapped inside gameplay logic.

105. Keep protocol payloads language-neutral where possible.
     Outcome: localization does not require protocol forks for each language.

106. Add locale preference at the account or session level.
     Outcome: language choice is explicit and persistent.

107. Add browser language selection and persistence.
     Outcome: players can switch languages intentionally instead of relying on
     browser defaults only.

108. Add locale-aware number, date, and time formatting.
     Outcome: non-text formatting matches player locale expectations.

109. Verify fonts and glyph coverage for the supported languages.
     Outcome: translated UI and chat do not fail on missing glyphs.

110. Audit chat/input handling for accents, IME, and Unicode edge cases.
     Outcome: players from different language backgrounds can type reliably.

111. Add browser i18n test coverage.
     Outcome: translation keys, fallback behavior, and locale switching stay
     correct under change.

112. Decide which surfaces remain intentionally non-localized.
     Outcome: player names, GM commands, shard-specific content, and other
     exceptions are explicit instead of accidental.

## Phase 14. Multi-Realm

113. Define the multi-realm architecture: one account system, many regional
     worlds.
     Outcome: region support is built on explicit realm boundaries instead of
     cross-region live-state shortcuts.

114. Add realm metadata and realm selection to the account/lobby backend.
     Outcome: the backend can list available realms before gameplay login.

115. Add realm selection to the browser lobby.
     Outcome: players choose a server region before opening the AO session.

116. Show per-realm character availability and state in the browser lobby.
     Outcome: region choice and character choice are visible together.

117. Route character session issuance through the selected realm.
     Outcome: `login_existing_char` tokens become realm-aware without changing
     the gameplay protocol shape.

118. Add deployment and runbook support for multiple regional realms.
     Outcome: the project can operate the same game stack in more than one
     country or region.

119. Add realm-aware monitoring and admin surfaces.
     Outcome: operators can inspect and manage each realm independently.

120. Define the controlled character-transfer policy between realms.
     Outcome: cross-realm movement is an explicit product rule with cooldowns,
     restrictions, and economics.

121. Implement controlled character transfer between realms if it remains in
     scope.
     Outcome: players can move characters across regions through a supported
     flow instead of ad hoc manual intervention.

## Phase 15. Browser Hardening And Release

122. Define the supported browser matrix and minimum versions.
     Outcome: browser support is explicit instead of accidental and frontend
     parity is measured against a real compatibility target.

123. Add shared client-vs-`ao_protocol` contract tests for browser packet
     shapes.
     Outcome: protocol drift between the browser client and `ao_protocol` is
     caught immediately instead of surfacing later as runtime decode bugs.

124. Add deterministic harness/demo routes or fixtures for the critical
     browser UI states.
     Outcome: loading, reconnect, dead/ghost, social, trade, weather, and
     other key browser states stay reproducible without depending on ad hoc
     manual setup.

125. Add asset/map-pack/cache failure handling and explicit fallback UI.
     Outcome: stale cache, missing assets, map-pack download failures, and
     similar browser-side breakages degrade visibly and recoverably instead of
     collapsing into opaque errors.

126. Expand reconnect and partial-bootstrap recovery behavior and browser
     tests.
     Outcome: the browser can recover cleanly from mid-bootstrap disconnects,
     reconnect paths, and partial session initialization without poisoning
     client state.

127. Add an explicit Playwright snapshot/update discipline and release check
     for visual baselines.
     Outcome: screenshot regressions stay reviewable and snapshot updates stop
     becoming an ad hoc side effect of unrelated UI changes.

128. Add client-side telemetry for decode, render, bootstrap, and asset-load
     failures.
     Outcome: real browser failures become observable instead of disappearing
     into user bug reports and local console logs only.

129. Define frontend performance budgets for boot, first map render, reconnect,
     and map transfer.
     Outcome: browser performance work is measured against explicit targets
     instead of vague "feels fast enough" claims.

130. Add long-session browser memory-growth checks.
     Outcome: long-lived play sessions, noisy logs, particle effects, and UI
     history surfaces do not accumulate memory without detection.

131. Define the fast frontend unit-test lane and keep it separate from browser
     smoke and visual checks.
     Outcome: protocol, reducer, and small UI-state regressions are caught in a
     fast local and CI lane instead of relying on Playwright for everything.

132. Add accessibility and keyboard coverage for the core browser panels.
     Outcome: spellbook, trade, bank, party, clan, overlays, and the main
     product-shell states remain usable without a mouse and regressions are
     caught automatically.

133. Define asset/map-pack/browser-cache versioning and invalidation rules.
     Outcome: browser assets and map packs can be rolled forward safely without
     stale-cache drift, invisible partial upgrades, or ad hoc cache clears.

134. Split frontend CI into a fast unit/protocol lane and a slower browser/
     visual-regression lane.
     Outcome: developers get quick feedback for most browser changes while
     still keeping real-browser and snapshot checks in the release path.

135. Make the authoritative-vs-inferred browser UI rule explicit and test it.
     Outcome: the browser stops inventing gameplay state where backend truth is
     required, and the remaining intentional inferences are documented and
     covered.
