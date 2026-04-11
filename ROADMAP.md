# Argentum Unified Roadmap

This is the only roadmap. `SERVER_ROADMAP.md` and `CLIENT_ROADMAP.md` are
technical appendices, not separate plans.

## Current Status

- **Backend gameplay:** close for the modern web path, but not full VB6 parity.
  Do not call the backend compatible until the backend tasks below are closed
  or deliberately removed from scope.
- **Backend environment:** the supported `server/` Nix/dev shell compiles and
  tests cleanly, and recent migrations were verified on clean Postgres.
- **Web client:** playable development client. Remaining work is weather/social
  polish, authoritative party/clan state, trade metadata display, E2E coverage,
  and UX polish.
- **Post-compat account flow:** not built. Target is username/password or Google
  account login over HTTP, character selection in the browser, then unchanged
  AO socket login with `login_existing_char(char_id, session_token)`.
- **Code size now:** backend app source is ~16k Elixir LOC; web client source is
  ~15k TypeScript/React/CSS LOC.

## Linear Task List

Backend work comes first. Frontend/browser work starts only after the backend
tasks below are closed or explicitly deferred.

### Branch, Toolchain, And Validation

1. Keep the branch clean.
   Outcome: no stray generated files, half-finished migrations, or untracked
   parity tests remain in normal working branches.
2. Finish or isolate any active gameplay patch before unrelated work starts.
   Outcome: parity work does not overlap with half-integrated gameplay edits.
3. Update the top-level roadmap status after every large merge.
   Outcome: the roadmap remains accurate instead of becoming historical fiction.

### Parity Gate

4. Add packet fixture replay tests from real VB6 client/server traffic.
    Outcome: protocol compatibility is proven by captured traffic, not memory.
5. Add an AO socket smoke bot for the core player journey.
    Outcome: login, movement, chat, combat, trade, and relog can be exercised
    automatically.
6. Add formula golden tests from VB6 traces.
    Outcome: combat, XP, regen, prices, and training formulas are checked
    against VB6 outputs.
7. Add packet property/fuzz coverage.
    Outcome: malformed/random bytes do not crash sessions or mutate gameplay
    state silently.
8. Add lifecycle tests for login/autosave/logout/crash cleanup/transfer.
    Outcome: persistence and ownership transitions stay correct under failure.
9. Add guild/faction/ban/mute persistence coverage.
    Outcome: shared cross-map state survives restart and migration.
10. Add a load/soak gate.
    Outcome: long-running many-session behavior is tested before public use.
11. Add a manual VB6 release smoke checklist.
    Outcome: every compatibility claim is verified at least once with the
    unmodified VB6 client before release.

### Backend Core Parity Tail

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

### Old-Client Packet/UI Tail

18. Finish the remaining old crafting UI packet surface.
    Outcome: old carpenter/blacksmith/alchemy/tailor windows can drive the
    existing crafting backend through open/add/remove/move/craft/close flows.
19. Decide the old GM/admin binary packet target.
    Outcome: the exact packet compatibility target is explicit instead of
    implicit.
20. Implement the remaining GM/admin binary packet behavior for that target.
    Outcome: the supported old GM/admin packet family works end-to-end.

### Full Old-VB6 Backend Systems

21. Implement quests and quest-NPC protocol.
    Outcome: quest state and quest NPC interactions exist on the backend.
22. Implement duels / reto exact flow.
    Outcome: the reto/duel lifecycle matches old server behavior instead of a
    simplified approximation.
23. Implement events / tournaments / lobby events / capture events /
    invasions / global world-event announcements.
    Outcome: server-side event systems match the selected old-server feature
    set.
24. Implement auction / subasta.
    Outcome: the old auction backend exists and is reachable through the
    compatible protocol/UI path.
25. Implement mounts if the target data expects mounts separate from
    boats/navigation.
    Outcome: mount behavior is present where the target shard/data requires it.
26. Implement gambling / arena-payment side systems.
    Outcome: the remaining economy side systems from the old server exist.
27. Implement treasure search.
    Outcome: treasure-search gameplay exists on the backend.
28. Implement forum / in-game message board.
    Outcome: the old in-game board/forum backend exists and persists correctly.
29. Implement marriage.
    Outcome: marriage-related backend state and actions exist.
30. Decide whether the old account/lobby packet system is still in scope.
    Outcome: either the old account/lobby backend is explicitly required, or
    the HTTP account/character lobby is explicitly accepted as the replacement.
31. If old account/lobby packets remain in scope, implement them.
    Outcome: the old account/lobby backend exists as a parity feature, not a
    future maybe.
32. Close any remaining backend drift only by adding a failing parity test
    first.
    Outcome: no undocumented "close enough" backend differences remain.

### Backend Operations And Administration

33. Add admin lookup for accounts, characters, and online players.
    Outcome: operators can inspect live and persisted entities.
34. Add admin moderation actions: kick, ban, mute, jail.
    Outcome: basic live moderation exists outside raw gameplay commands.
35. Add admin world actions: item/NPC spawn, teleport, locate.
    Outcome: operator world control exists in one supported surface.
36. Add admin logs and health views.
    Outcome: operators can inspect recent actions and system state quickly.
37. Add metrics and dashboards.
    Outcome: runtime health can be observed without log scraping.
38. Add alerts and release artifacts.
    Outcome: the project is releaseable and operationally monitorable.
39. Add deployment pipeline and backup/restore runbook.
    Outcome: releases and recovery have a documented path.
40. Verify graceful host shutdown.
    Outcome: shutdown does not lose player state or corrupt runtime processes.
41. Add pre-public scripted load/soak runs.
    Outcome: operational confidence exists before open testing.

### Frontend And Browser Product Work

42. Run the current client checks once from a clean checkout.
    Outcome: `npm run typecheck` and `npm run build` succeed.
43. Decode, dispatch, and render snow when `snow_toggle` is active.
    Outcome: weather parity is visually complete in the browser.
44. Make party panels use authoritative state instead of console-text
    inference.
    Outcome: party UI reflects backend truth.
45. Make clan panels use authoritative state instead of console-text inference.
    Outcome: clan UI reflects backend truth.
46. Show trade item name / GRH / tags in the trade panel.
    Outcome: trade metadata visible in packets is actually shown to the user.
47. Improve death UX in the web client.
    Outcome: ghost/dead state is visually obvious and rejected actions are
    pre-disabled where appropriate.
48. Add settings/reconnect/error/banned/muted/maintenance polish.
    Outcome: the web client can handle common live-session edge states cleanly.
49. Add web E2E smoke coverage for the current client gameplay path.
    Outcome: the browser path is tested end-to-end, not only by unit tests.

### Web Account And Character Lobby

50. Add `POST /api/auth/login`.
    Outcome: account-level username/password login exists over HTTP.
51. Add `POST /api/auth/google`.
    Outcome: account-level Google login exists over HTTP.
52. Add `GET /api/auth/session`.
    Outcome: browser session restore works without touching the AO socket.
53. Add `POST /api/auth/logout`.
    Outcome: account logout is explicit and clean.
54. Add `GET /api/characters`.
    Outcome: the browser can list account-owned characters.
55. Add `POST /api/characters`.
    Outcome: character creation exists in the account lobby flow.
56. Add `POST /api/characters/:id/session`.
    Outcome: selecting a character yields the token needed for unchanged AO
    socket entry.
57. Support password-only, Google-only, and linked accounts.
    Outcome: account identity model is explicit and flexible.
58. Build browser login/session restore flow.
    Outcome: users can authenticate and resume browser sessions cleanly.
59. Build browser character picker/create flow.
    Outcome: the browser chooses a character before opening the AO session.
60. Launch the AO socket with `login_existing_char(char_id, session_token)`.
    Outcome: gameplay protocol stays unchanged after the HTTP lobby.
61. Prefer same-origin serving or proxying for the account API.
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
