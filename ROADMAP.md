# Argentum Unified Roadmap

This is the only roadmap. `CHANGELOG.md` tracks completed work.

## Current Status

- **Backend gameplay:** close for the modern web path, but not full VB6 parity.
  Do not call the backend compatible until the backend tasks below are closed
  or deliberately removed from scope.
- **Arena internal boundaries:** the first large backend refactor pass is
  landed: social handlers are split, combat handlers are split, and production
  map state now uses `%Arena.Map.State{}`. Arena tests now have a shared
  `%Arena.Map.State{}` factory path instead of old partial raw-map fixtures.
  The next backend modernization work should start from the authoritative
  persistence and refactor research plan in
  [research/arena-authoritative-persistence-and-refactor.md](research/arena-authoritative-persistence-and-refactor.md).
- **Parity gate:** the harness foundation is in place. The main remaining proof
  gap is a real VB6 traffic corpus and replay coverage built from captured
  sessions instead of synthetic fixtures alone.
- **Backend environment:** the supported `server/` Nix/dev shell compiles and
  tests cleanly, and recent migrations were verified on clean Postgres.
- **Web client:** playable development client. The big remaining frontend gap
  is no longer the in-game HUD. A minimal browser product shell is landed:
  HTTP username/password auth, session restore, character list/create/select,
  ranking, and gameplay launch via `login_existing_char(char_id, session_token)`.
  The main remaining frontend gaps are authoritative party/clan state,
  settings/audio polish, browser-side proof, and product-shell hardening.
- **Post-compat account flow:** partially built. Username/password browser
  account flow is landed; remaining product work is Google auth/account
  linking, browser-flow hardening, and later i18n/multi-realm.
- **Code size now:** backend runtime code is ~21k Elixir LOC, backend tests are
  ~17k Elixir LOC, and the web client source is ~15k TypeScript/React/CSS LOC.

## Frontend Product Snapshot

- **Big remaining frontend work:** hardening and extending the browser product
  shell around the gameplay client, not rebuilding the in-game HUD.
- **Actual gaps:**
  - the minimal browser account/lobby flow is now landed: HTTP username/
    password auth, session restore, character list/create/select, ranking, and
    unchanged AO socket login via `login_existing_char(char_id, session_token)`
  - product-shell hardening is still missing: browser login/lobby smoke
    coverage, stronger recovery behavior across refresh/logout/partial
    bootstrap, and clearer completion criteria for the account flow
  - party/clan UI exists, but it is not yet fully authoritative: the browser
    still needs richer backend truth for online state, roles/ranks,
    permissions, safe-state, alignment, and cleaner snapshots
  - user settings remain incomplete: browser music/SFX and utility-keybind
    persistence are landed, but broader browser preference coverage and polish
    are still thin
  - audio polish remains incomplete: MIDI/music exists, but combat/UI/world
    sound effects are still open
  - browser-side proof remains incomplete: reducer tests, visual fixture tests,
    and broader E2E coverage are still required
  - localization and multi-realm remain future product work, not shipped
    frontend features
- **Already present / not the main gap:**
  - snow already exists in the client path: packet decode, reducer state, and
    renderer hooks are landed
  - minimap already exists in the current browser client
  - trade metadata and spell hints already exist in the current browser client
    and should be treated as polish/testing work, not net-new surfaces
  - ghost/dead UX and explicit banned/muted/server-full/maintenance/
    token-expired states already exist in the client
- **Secondary gaps / investigation items:**
  - responsive layout still needs explicit desktop/laptop/common-zoom polish;
    the current client is playable, but not yet fully hardened across tighter
    browser sizes
  - social chat surfaces need careful investigation before implementation:
    faction/guild/party chat should likely become distinct browser streams, but
    the packet mapping, UX shape, and scope should be validated first so the
    client does not invent a social model the protocol or target product does
    not actually support
  - session/auth isolation should remain explicit: account/lobby flows must
    stay separate from gameplay packet semantics and must not leak product-shell
    concerns into the AO session protocol
  - map markers remain optional product scope: the minimap exists, but markers
    should be added only if the target web UX still wants them
  - performance discipline should remain an explicit frontend rule:
    non-gameplay/dev-only surfaces should stay lazy-loaded, bundle growth should
    be watched, and render-loop work must remain off the React path
  - visual regression proof for bodies, equipment overlays, and NPC sprite
    mappings is important enough to treat as a named frontend concern, not just
    a generic testing afterthought
- **Frontend architecture guardrail:**
  - React/DOM UI owns panels, forms, overlays, and product-shell state
  - frame-critical rendering, sprite movement, camera, and any other hot-path
    canvas/Pixi work must stay outside React on the imperative renderer path
  - React may mount host nodes and pass coarse-grained state into the renderer,
    but it must not own per-frame drawing, animation loops, or fast-path
    canvas mutations
- **Long-term browser-shell design:**
  - copy the old webclient's browser product flow, not its implementation or
    renderer architecture
  - treat login, register, session restore, character list/create/select,
    ranking, and similar account/lobby surfaces as normal HTTP browser product
    work
  - keep gameplay entry as a narrow handoff: the browser shell obtains
    `login_existing_char(char_id, session_token)` credentials, then the AO
    gameplay session starts unchanged
  - keep product-shell routes, modules, and state isolated from gameplay boot
    so account/lobby concerns do not spread through the gameplay client
  - do not use the AO gameplay protocol as the primary browser auth/lobby
    transport
- **Recommended frontend priority:**
  1. Fast tests and build gates.
  2. Frontend-only parity and UX.
  3. Protocol/reducer/visual test depth.
  4. Measured rendering/state performance work.
  5. Backend-authoritative social/UI.
  6. Account/lobby/i18n/multi-realm product work.

## Frontend Execution Order

Execute frontend work in these six passes, in this order:

### Pass 1. Keep the fast correctness lane green

- run and keep green:
  - typecheck
  - build
  - Vitest protocol/reducer/state tests
  - Playwright as a thin smoke + visual layer, not the only test layer

Why first:

- it makes every later frontend change cheaper and safer

### Pass 2. Finish frontend-only parity surfaces that are not backend-blocked

- weather parity such as `snow_toggle`
- trade metadata
- spell hints, cooldowns, requirements, and AoE cues
- dead/ghost cues
- loading/reconnect/error overlays
- responsive layout
- sound/settings polish

Why second:

- these are high-value, low-dependency UI wins

### Pass 3. Add real client correctness coverage

- packet fixture tests
- decoder fuzz tests
- reducer tests for inventory, bank, trade, party, clan, weather, and death
- curated visual regression tests for sprites, body overlays, and NPC mappings

Why third:

- once this exists, frontend regressions stop slipping through UI-only testing

### Pass 4. Improve runtime performance where it actually matters

- reduce hidden panel rerenders
- batch noisy packet/log/chat updates
- lazy-load non-core routes and harness code
- keep Pixi/rendering off the React churn path
- cache repeated sprite/metadata lookups
- profile boot, map load, map transfer, and panel open

Why fourth:

- optimize from measurements, not guesses

### Pass 5. Finish the backend-dependent frontend

- authoritative party/clan UI
- distinct party/guild/faction chat streams after protocol/UX investigation
- real gameplay E2E once backend contracts are stable

Why fifth:

- this depends on backend truth, so doing it too early creates rework

### Pass 6. Do the product layer last

- account/auth/lobby
- `login_existing_char(char_id, session_token)` flow
- i18n
- multi-realm
- copy the old browser flow shape where useful, but do not transplant old
  renderer/client implementation details
- keep the product shell on HTTP/browser routes and keep the AO gameplay socket
  handoff narrow and explicit

Why sixth:

- this is product work, not core gameplay-client parity

## Easy-To-Miss Frontend Concerns

### Frontend

- explicit browser support policy and minimum versions
- asset-failure UX: missing sprites, bad map pack, partial downloads, stale cache
- save/restore rules: which settings persist and which session state must not
  persist
- keyboard/accessibility pass: focus order, labels, escape paths, and
  non-mouse flows
- screenshot baseline discipline: who updates Playwright snapshots and when
- error taxonomy that distinguishes auth failure, protocol failure, map fetch
  failure, and render failure

### Client correctness

- contract tests against `ao_protocol`, so packet-shape drift is caught
  immediately
- replay/fixture sharing between server and client instead of two separate
  fixture worlds
- deterministic demo/harness states for every important UI surface
- recovery behavior after reconnect or partial bootstrap, not just happy-path
  login

### Performance / reliability

- explicit perf budgets for boot, first map render, reconnect, and map transfer
- cache invalidation/versioning for map packs and generated assets
- background-tab behavior: pause or reduce expensive loops when hidden
- memory growth checks for long sessions, especially logs, particles, and chat

### Product / scope

- an exact definition of "frontend parity done"
- which old-client quirks remain visible in the browser and which are
  intentionally modernized
- which features are backend-blocked versus frontend-owned, so the browser does
  not grow placeholders that later fight the real API

### Ops / release

- CI split: fast frontend gate versus slower Playwright/visual gate
- one release checklist for browser assets, snapshots, generated data, and
  cache-busting
- basic client-side telemetry for crashes and decode/render failures

### Most commonly forgotten

1. Shared protocol contract tests.
2. Asset/cache failure handling.
3. Explicit "frontend parity done" criteria.

## Linear Task List

Tasks `1-49` are the backend parity path. Tasks `50-159` are post-parity
browser/product work. Tasks `160-181` are backend modernization and
operations that should not block parity signoff unless explicitly pulled into
scope. Tasks `182-183` are optional legacy features that the inspected VB6
baseline kept disabled and should only be revisited after backend
modernization unless a target shard explicitly re-enables them. Tasks
`184-193` are follow-up security and parity drift items discovered during the
adversarial-test and VB6-code audit and should be closed before calling the
backend hardened.

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

## Frontend Parity Finish Line

Call frontend parity done only when:

- the supported browser matrix and minimum versions are explicit and verified
- fast frontend unit/protocol/reducer gates and slower browser/visual gates are
  both explicit and green
- browser protocol contract, fixture, reducer/state, and visual-regression
  suites are green
- deterministic harness/demo routes exist for the critical browser UI states
- asset/map-pack/cache/bootstrap/reconnect failure paths have explicit browser
  UX and test coverage
- asset, map-pack, and browser-cache versioning/invalidation rules are explicit
- accessibility and keyboard paths for the core browser panels are explicit and
  covered
- authoritative backend-driven browser surfaces are used where the UI depends
  on backend truth
- the client-side rule for authoritative vs inferred browser state is explicit
  enough that the browser does not invent gameplay semantics
- the visual snapshot workflow is explicit enough to update safely during real
  rendering changes
- frontend performance budgets for boot, first map render, reconnect, and map
  transfer are defined and checked
- long-session browser memory-growth checks are green
- any intentionally deferred browser product work is explicitly listed instead
  of being hand-waved as “later”

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
- **Tasks 50-159:** highly parallelizable once started. Split by browser
  surface: protocol tests, reducer/state tests, UI polish, account/lobby,
  i18n, multi-realm.
- **Tasks 160-181:** parallelize by subsystem. These are modernization tasks
  and should not block parity signoff unless explicitly promoted.
- **Tasks 182-183:** do only after backend modernization unless the target
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

19. Finish `/HOGAR` exact VB6 behavior. DONE.
    Outcome: `/HOGAR` matches the inspected VB6 baseline end-to-end: dead-only
    immediate return with gold cost, alive-use rejection, jail/NEWBIE/CARCEL
    and reto restrictions, and no invented delayed-travel flow.
20. Preserve the disabled guild relation semantics from the inspected VB6
    baseline. DONE.
    Outcome: alliance/peace proposal lists, details, and related clan-relation
    packets return the VB6 disabled responses instead of modern placeholder
    mailbox behavior. 13 tests verify all 12 disabled stubs.
21. Fix `gm_message` to match VB6 GM/admin broadcast semantics. DONE.
    Outcome: Fixed 5 bugs: wrong audience (was all players, now GM-only),
    wrong prefix (was "Servidor>", now "name > msg"), wrong font (was 1, now
    16/FONTTYPE_GMMSG), no empty-message guard, no audit logging. 5 tests.
22. Fix `rain_toggle` to match VB6 global weather semantics. DONE.
    Outcome: GM weather toggling now drives global rain+snow+thunder+flash
    matching VB6 HandleRainToggle. Added flash_screen packet, snow state
    tracking, thunder sound on rain start. 6 tests.
23. Implement the remaining player-to-staff request packet behavior. DONE.
    Outcome: role_master_request forwards to online GMs with VB6 format,
    question_gm routes support queries to admins. Fixed decoder to read
    request payload. 12 tests.
24. Keep elemental/rune combat effects data-driven. DONE.
    Elemental tags parsed from obj.dat/npcs.dat, bitmask matrix from Balance.dat,
    apply_elemental_modifiers/3 implements VB6 cross-product loop. 8 tests.
25. Audit remaining interval/timer clamps against VB6. DONE.
    Separate thirst (54 ticks/~162s) and hunger (60 ticks/~180s) counters,
    poison at 3600ms, stamina drain when starving. Updated parity tests.
26. Audit remaining invisibility, NPC AI, and spell-selection edge cases
    against VB6.
    Outcome: the remaining known semantic edge cases are either matched or
    explicitly documented as out of scope.
26a. Fix: spell invisibility must NOT break on walking (VB6 parity). DONE.
    VB6: only Oculto (stealth) breaks on walk for non-Thief/Bandit classes.
    Spell invisibility (`invisible` flag) is never cleared by movement.
    Removed incorrect break_invisibility call in movement.ex do_move/8.
26b. Implement Oculto (stealth/hide skill) as a separate flag from spell invisibility. DONE.
    Oculto timer with regen-tick decrement, hunter+camo exemption, NPC AI
    filtering, work skill activation, break on attack/death. 18 tests.
26c. Fix: offensive spell casting should break both invisible and oculto. DONE.
    Only breaks on target_effect_type == 2 (offensive). 14 tests for 26c-i.
26d. Fix: add NPC leash distance (~15 tiles) so chasing NPCs return to spawn. DONE.
    Outcome: hostile NPCs stop chasing beyond leash range, matching VB6.
26e. Fix: melee hits should transfer NPC aggro (currently only spells do). DONE.
    Outcome: both melee and spell damage set npc.target_id to the attacker.
26f. Fix: NPC spell damage should use actual NPC level instead of hardcoded 20. DONE.
    Outcome: npc_def_level/1 returns the NPC definition's level field.
26g. Implement NoDetectable flag for immunity to RemoveInvisibility spells. DONE.
    Added no_detectable field; RemoveInvisibility skips players with flag set.
26h. Fix: entering no-invi maps (SinInviOcul) should clear both flags. DONE.
    22 maps have SinInviOcul (cities + mines). Both flags stripped on entry.
26i. Fix: equipping mount should break both invisible and oculto. DONE.
    Mount equip (obj_type 44) calls break_invisibility.
27. Add authoritative party/clan snapshot packets. DONE.
    datos_grupo (ID 143) sent on join/leave/kick/login, guild_details and
    guild_news binary packets replace console text. 6 tests.
28. Finish pet/trainer command parity for the selected VB6 baseline. DONE.
    Outcome: pet AI clause reordered, nil-safe interval/damage calculations.
29. Add out-of-sequence packet validation. DONE.
    Outcome: is_dead guards on attack/cast/equip/use, in_trade guards on
    commerce packets. 14 tests.
30. Expand remaining production recipe coverage to the target data set. DONE.
    Complete rewrite with correct VB6 ingredient IDs for all 4 skills
    (blacksmith, carpenter, alchemy, tailoring). craftable_item_ids/2,
    find_recipe_by_item/2 APIs.
31. Finish the remaining old crafting UI packet surface. DONE.
    All 4 crafting skills: open window sends recipe list, craft_item/4 validates
    skill + ingredients. Encoder/decoder for all crafting packets. 15+ tests.
32. Finish the remaining training/spell window response semantics. DONE.
    Trainer creature list packet (ID 104) with CI1-CI5 NPC parsing, spell info
    packet (ID 105). train_list routed through MapServer to social. 8 tests.
33. Finish the remaining info/service/NPC-request window semantics.
    Outcome: help, MOTD, uptime, punishments, reward, account-state, banker,
    timbero, priest, enlistador, and related old request/response windows stop
    using placeholder text and match VB6 behavior.
34. Finish the remaining faction/council old response behavior. DONE.
    OnlineDirectory tracks faction, list_by_faction/1 API, online_royal_army
    and online_chaos_legion packets (132/133), council_message with faction
    verification. 22 tests.
35. Decide the old GM/admin binary packet target.
    Outcome: the exact packet compatibility target is explicit instead of
    implicit.
36. Implement the remaining GM/admin binary packet behavior for that target.
    Outcome: the supported old GM/admin packet family works end-to-end.
37. Implement quests and quest-NPC protocol. DONE.
    Outcome: quest state, quest NPC interactions, quest list/details/accept/
    abandon handlers, protocol packets, and QuestServer edge-case coverage
    exist on the backend.
38. Implement duels / reto exact flow. DONE.
    DuelServer GenServer: best-of-3 rounds, gold betting with 10% tax,
    /RETAR /ACEPTAR /CANCELAR /ABANDONAR commands, combat restriction +
    death hook. 12 tests.
39. Implement events / tournaments / lobby events / capture events /
    invasions / global world-event announcements.
    Outcome: server-side event systems match the selected old-server feature
    set, including the old event-lobby protocol where that baseline depends on
    it.
40. Implement auction / subasta. DONE.
    Auction GenServer: timed bidding, auto-cancel, 5% fee, Subastador NPC
    (type 16) handler. Encoder/decoder for auction packets. 10 tests.
41. Implement land mounts (saddle system). DONE.
    Saddle equipment slot (obj_type 44), mounted flag, Jinete skill speed
    scaling (10 tiers, 1.1x-2.0x), attack/invisibility blocked while mounted,
    navigation conflict check. 12 tests.
42. Implement gambling / priest-forgiveness / arena-payment side systems. DONE.
    Timbero NPC gambling (10% win, 1-5000 gold, stats tracking), priest
    forgiveness (gold cost per citizen killed, Caos blocked), ArenaGuard
    NPC entry fees with warp. 15 tests.
43. Implement treasure search. DONE.
    TreasureEvent GenServer: treasure/gift/NPC GM events, place_event_item/5,
    check_treasure_event/4 on item pickup. Tesoros.dat loader. 8 tests.
44. Implement forum / in-game message board. DONE.
    Forum GenServer with per-forum_id message storage, 35-message cap, file
    persistence, object-linked forums via forum_id field. 7 tests.
45. Implement marriage. DONE.
    Outcome: /PROPONER and /DIVORCIAR commands, priest NPC requirement, mutual
    proposal flow, spouse_id persistence, DB migration. 18 tests.
46. Preserve the disabled guild election semantics from the inspected VB6
    baseline. DONE.
    Outcome: guild election packets return VB6 disabled responses. Already
    correctly implemented; verified with tests in guild_disabled_stubs_test.
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
63. Decode and dispatch `snow_toggle`. DONE.
    Outcome: snow state reaches the browser renderer correctly.
64. Render snow when `snow_toggle` is active. DONE.
    Outcome: weather parity is visually complete in the browser.
65. Show trade item name in the trade panel. DONE.
    Outcome: the player sees the real item label from packet 100.
66. Show trade item `GRH`/sprite metadata in the trade panel. DONE.
    Outcome: trade visuals use the metadata already sent by the server.
67. Show trade item elemental tags in the trade panel. DONE.
    Outcome: non-zero item tags are visible instead of hidden protocol data.
68. Show spell cooldown hints. DONE.
    Outcome: spell timing constraints are visible before the server rejects the
    cast.
69. Show spell requirement hints. DONE.
    Outcome: land/water/staff/dead targeting rules are visible in the browser.
70. Show spell AoE/radius hints. DONE.
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
79. Add clear ghost/dead HUD cues. DONE.
    Outcome: dead state is visually obvious in the browser.
80. Disable actions that the dead state will reject anyway. DONE.
    Outcome: obvious dead-state rejections are prevented client-side.
81. Add a loading overlay. DONE.
    Outcome: map/session transitions are visible instead of abrupt.
82. Add a reconnect overlay. DONE.
    Outcome: connection recovery is visible and less confusing.
83. Add a banned error state. DONE.
    Outcome: banned users get an explicit browser state instead of a generic
    failure.
84. Add a muted error/state message. DONE.
     Outcome: muted users see a clear chat restriction state.
85. Add a server-full error state. DONE.
    Outcome: capacity failures are explicit in the browser.
86. Add a maintenance error state. DONE.
     Outcome: maintenance mode is explicit in the browser.
87. Add a token-expired error state. DONE.
     Outcome: auth/session expiry is explicit in the browser.
88. Add browser music settings. DONE.
     Outcome: music can be enabled, disabled, and persisted intentionally.
89. Add browser SFX settings. DONE.
     Outcome: sound effects can be enabled, disabled, and persisted
     intentionally.
90. Do not add a browser graphics-quality menu by default; only add optional
    visual preferences if profiling later proves a real need.
     Outcome: the 2D client stays fast by design instead of outsourcing
     performance to a quality menu.
91. Add browser keybind settings. DONE.
     Outcome: controls can be configured instead of hardcoded.
92. Add a minimap if it remains part of the web UX target. DONE.
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
103. Add `POST /api/auth/login`. DONE.
     Outcome: account-level username/password login exists over HTTP.
104. Add `POST /api/auth/google`.
     Outcome: account-level Google login exists over HTTP.
105. Add `GET /api/auth/session`. DONE.
     Outcome: browser session restore works without touching the AO socket.
106. Add `POST /api/auth/logout`. DONE.
     Outcome: account logout is explicit and clean.
107. Add `GET /api/characters`. DONE.
     Outcome: the browser can list account-owned characters.
108. Add `POST /api/characters`. DONE.
     Outcome: character creation exists in the account lobby flow.
109. Add `POST /api/characters/:id/session`. DONE.
     Outcome: selecting a character yields the token needed for unchanged AO
     socket entry.
110. Support password-only accounts. DONE.
     Outcome: the account model works without Google linkage.
111. Support Google-only accounts.
     Outcome: the account model works without a local password.
112. Support linked password+Google accounts.
     Outcome: one account can support both auth methods cleanly.
113. Build the browser username/password login flow. DONE.
     Outcome: users can sign in with credentials before the AO session starts.
114. Build the browser session-restore flow. DONE.
     Outcome: users can resume account sessions cleanly.
115. Build the browser Google login flow.
     Outcome: Google auth is first-class in the browser, not a token paste
     path.
116. Build the browser Google account-link flow.
     Outcome: existing accounts can attach Google auth cleanly.
117. Build the browser character list flow. DONE.
     Outcome: the browser shows owned characters before opening the AO session.
118. Build the browser character creation flow. DONE.
     Outcome: the browser can create a new character before opening the AO
     session.
119. Build the browser character selection flow. DONE.
     Outcome: the browser chooses a character before opening the AO session.
120. Include race/class choices in the browser character create flow. DONE.
     Outcome: browser-side character creation exposes core class/race setup.
121. Add browser stat choices to the character create flow.
     Outcome: browser-side character creation exposes stat setup instead of
     relying only on defaults; head and home choices are already landed.
122. Stop using socket `login_new_char` as the primary browser account flow. DONE.
     Outcome: account auth and gameplay auth are clearly separated.
123. Launch the AO socket with `login_existing_char(char_id, session_token)`. DONE.
     Outcome: gameplay protocol stays unchanged after the HTTP lobby.
124. Prefer same-origin serving or proxying for the account API. DONE.
     Outcome: cookies/session handling stays simple.
     Design note: this browser product-shell lane should copy the old web flow
     shape where it helps, but must not copy old renderer/client architecture
     or let account/lobby state leak into the gameplay fast path.
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
146. Define the supported browser matrix and minimum versions.
     Outcome: browser support is explicit instead of accidental and frontend
     parity is measured against a real compatibility target.
147. Add shared client-vs-`ao_protocol` contract tests for browser packet
     shapes.
     Outcome: protocol drift between the browser client and `ao_protocol` is
     caught immediately instead of surfacing later as runtime decode bugs.
148. Add deterministic harness/demo routes or fixtures for the critical
     browser UI states.
     Outcome: loading, reconnect, dead/ghost, social, trade, weather, and
     other key browser states stay reproducible without depending on ad hoc
     manual setup.
149. Add asset/map-pack/cache failure handling and explicit fallback UI.
     Outcome: stale cache, missing assets, map-pack download failures, and
     similar browser-side breakages degrade visibly and recoverably instead of
     collapsing into opaque errors.
150. Expand reconnect and partial-bootstrap recovery behavior and browser
     tests.
     Outcome: the browser can recover cleanly from mid-bootstrap disconnects,
     reconnect paths, and partial session initialization without poisoning
     client state.
151. Add an explicit Playwright snapshot/update discipline and release check
     for visual baselines.
     Outcome: screenshot regressions stay reviewable and snapshot updates stop
     becoming an ad hoc side effect of unrelated UI changes.
152. Add client-side telemetry for decode, render, bootstrap, and asset-load
     failures.
     Outcome: real browser failures become observable instead of disappearing
     into user bug reports and local console logs only.
153. Define frontend performance budgets for boot, first map render, reconnect,
     and map transfer.
     Outcome: browser performance work is measured against explicit targets
     instead of vague “feels fast enough” claims.
154. Add long-session browser memory-growth checks.
     Outcome: long-lived play sessions, noisy logs, particle effects, and UI
     history surfaces do not accumulate memory without detection.
155. Define the fast frontend unit-test lane and keep it separate from browser
     smoke and visual checks.
     Outcome: protocol, reducer, and small UI-state regressions are caught in a
     fast local and CI lane instead of relying on Playwright for everything.
156. Add accessibility and keyboard coverage for the core browser panels.
     Outcome: spellbook, trade, bank, party, clan, overlays, and the main
     product-shell states remain usable without a mouse and regressions are
     caught automatically.
157. Define asset/map-pack/browser-cache versioning and invalidation rules.
     Outcome: browser assets and map packs can be rolled forward safely without
     stale-cache drift, invisible partial upgrades, or ad hoc cache clears.
158. Split frontend CI into a fast unit/protocol lane and a slower browser/
     visual-regression lane.
     Outcome: developers get quick feedback for most browser changes while
     still keeping real-browser and snapshot checks in the release path.
159. Make the authoritative-vs-inferred browser UI rule explicit and test it.
     Outcome: the browser stops inventing gameplay state where backend truth is
     required, and the remaining intentional inferences are documented and
     covered.

### Backend Modernization

160. Replace NPC aggro full scans with spatial-grid queries.
     Outcome: hostile NPC target acquisition scales with local visibility, not
     full player count.
161. Replace pet target full scans with bounded or indexed lookup.
     Outcome: pets do not scale linearly with all NPCs on the map.
162. Add outbound backpressure for lagging sessions.
     Outcome: a slow client cannot grow process memory without bound.
163. Add per-MapServer hotspot telemetry.
     Outcome: player count, NPC count, tick duration, mailbox length, and
     broadcast rates are visible per map.
164. Implement the authoritative persistence and backend refactor plan from
     [research/arena-authoritative-persistence-and-refactor.md](research/arena-authoritative-persistence-and-refactor.md).
     The arena test-state migration to `%Arena.Map.State{}` is done; next add
     state helpers, audit all `GameBackend.*` write sites, add persistence
     telemetry, introduce ordered per-character writers, add an idempotent
     operation ledger, and migrate bank/inventory/trade persistence behind
     flush barriers.
     Outcome: autosave, logout, bank, inventory, trade, auction, and guild
     writes are authoritative, ordered, retryable, observable, and no longer
     depend on ad hoc blocking calls from the map loop.
165. Pre-resolve `.dat` references at load time where hot-path lookups still
     repeat.
     Outcome: gameplay avoids repeated definition lookups that can be resolved
     once at startup.
166. Unify interest management for players, NPCs, and ground items.
     Outcome: create/remove boundary behavior is consistent across visible world
     entities.
167. Add runtime admin tools for map/process inspection and control.
     Outcome: operators can inspect mailboxes, player counts, force save, and
     restart maps cleanly.
168. Add admin lookup for accounts, characters, and online players.
     Outcome: operators can inspect live and persisted entities.
169. Add admin moderation actions: kick, ban, mute, jail.
     Outcome: basic live moderation exists outside raw gameplay commands.
170. Add admin world actions: item/NPC spawn, teleport, locate.
     Outcome: operator world control exists in one supported surface.
171. Add admin logs and health views.
     Outcome: operators can inspect recent actions and system state quickly.
172. Add metrics and dashboards.
     Outcome: runtime health can be observed without log scraping.
173. Add alerts and release artifacts.
     Outcome: the project is releaseable and operationally monitorable.
174. Add deployment pipeline and backup/restore runbook.
     Outcome: releases and recovery have a documented path.
175. Add TLS for HTTPS and WSS.
     Outcome: production browser/session traffic is encrypted.
176. Add asset CDN/delivery strategy for static resources.
     Outcome: heavy client assets do not depend on the gameplay server path.
177. Add automated backups and database connection-pool tuning.
     Outcome: the database operational path is production-safe.
178. Add runtime-tunable settings for intervals, rates, and formula constants.
     Outcome: live tuning does not require a recompile for every server constant.
179. Verify graceful host shutdown.
     Outcome: shutdown does not lose player state or corrupt runtime processes.
180. Add pre-public scripted load/soak runs.
     Outcome: operational confidence exists before open testing.
181. Add post-parity anti-cheat hardening: movement anomaly scoring, rate
     validation, state-machine validation, economy invariants, structured
     anti-cheat events, and operator visibility.
     Outcome: speed hacking, packet abuse, duping, and botting signals are
     detected, logged, and acted on systematically without changing legal
     gameplay behavior.

### Legacy Features Disabled In The Inspected VB6 Baseline

182. If the selected shard explicitly re-enables clan relations, implement the
     live guild alliance/peace proposal, detail, and mailbox flows after the
     frontend and backend-modernization tracks are complete.
     Outcome: the re-enabled shard gets real alliance/peace UI and backend
     behavior without delaying parity for the inspected disabled baseline.
183. If the selected shard explicitly re-enables guild elections, implement the
     live election and democratic succession system after the frontend and
     backend-modernization tracks are complete.
     Outcome: the re-enabled shard gets real election flows without delaying
     parity for the inspected disabled baseline.

### Security And Remaining Drift Audit

- Already closed during the recent audit:
  - packet-counter anti-replay is now enforced on the counted VB6 packet set
  - request-position resync is landed and bound in the browser client
  - negative `commerce_buy` / `commerce_sell` amount exploits are fixed
  - bank slot `0` / invalid-slot guards and extract-to-gold withdrawal are fixed
  - bank-session proximity is revalidated on each bank operation
  - trade over-offer and receiver-full item-loss regressions are fixed
  - faction chat now respects dead/mute/cooldown rules
- Remaining work from the same audit should stay visible here until closed.

184. Make party invites authoritative and leader-only.
     Outcome: non-leaders cannot invite, and accepting a stale invite cannot
     move a player into a second party or corrupt party membership state.
185. Enforce mute/dead/cooldown rules on guild and party chat.
     Outcome: all social chat paths follow the same moderation and spam rules,
     not just normal chat and faction chat.
186. Rate-limit `question_gm` and `role_master_request`.
     Outcome: support/admin channels cannot be flooded even when packet replay
     protection is already in place.
187. Finish secure trade start validation to match the inspected VB6 safety
     rules.
     Outcome: player-trade start rechecks distance, same-map visibility,
     target-alive/not-busy state, and any safe-zone restrictions instead of
     only proximity and existence.
188. Revalidate guild invite authority on accept.
     Outcome: a stale invite cannot still be accepted after the inviter loses
     leadership or the guild state changes.
189. Restore VB6 `leave_faction` restrictions.
     Outcome: faction leave requires the correct enlistador interaction and
     preserves the old aligned-clan restrictions/side effects instead of the
     current looser behavior.
190. Restore selected-NPC semantics for account-state and reward flows.
     Outcome: banker, timbero, and enlistador requests use the actual targeted
     NPC and correct faction-side checks instead of any nearby NPC of the right
     type.
191. Align the remaining merchant/account-state behavior with the inspected VB6
     backend.
     Outcome: merchant sell restrictions such as the remaining old item rules,
     and the timbero account-state text/value semantics, stop drifting from the
     VB6 baseline.
192. Close the remaining interaction-radius and bank-open guard drifts.
     Outcome: NPC interaction radii and the old "already trading" bank-open
     rule match the inspected VB6 behavior instead of stricter or looser
     approximations.
193. Keep the exploit and parity audit executable.
     Outcome: every bug above has a regression test in the adversarial/parity
     suites, and roadmap comments are updated when a gap is fixed so audit
     notes do not become stale folklore.

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
