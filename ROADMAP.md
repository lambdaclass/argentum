# Argentum Roadmap

This is the linear task list. Use `SERVER_ROADMAP.md` and
`CLIENT_ROADMAP.md` as deeper reference, but keep this file as the short source
of truth for sequencing.

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

## Recently Closed Prerequisites

- Supported backend environment: use the `server/` Nix/dev shell for backend
  compile/test.
- Backend compile path verified in the supported environment.
- Backend test path verified in the supported environment.
- Recent migrations verified on clean Postgres and on an upgrade path.

## Linear Task List

### Branch, Toolchain, And Validation

1. Keep the branch clean.
   Outcome: no stray generated files, half-finished migrations, or untracked
   parity tests remain in normal working branches.
2. Finish or isolate any active gameplay patch before unrelated work starts.
   Outcome: parity work does not overlap with half-integrated gameplay edits.
3. Run the current client checks once from a clean checkout.
   Outcome: `npm run typecheck` and `npm run build` succeed.
4. Update the top-level roadmap status after every large merge.
   Outcome: the roadmap remains accurate instead of becoming historical fiction.

### Parity Gate

5. Add packet fixture replay tests from real VB6 client/server traffic.
    Outcome: protocol compatibility is proven by captured traffic, not memory.
6. Add an AO socket smoke bot for the core player journey.
    Outcome: login, movement, chat, combat, trade, and relog can be exercised
    automatically.
7. Add formula golden tests from VB6 traces.
    Outcome: combat, XP, regen, prices, and training formulas are checked
    against VB6 outputs.
8. Add packet property/fuzz coverage.
    Outcome: malformed/random bytes do not crash sessions or mutate gameplay
    state silently.
9. Add lifecycle tests for login/autosave/logout/crash cleanup/transfer.
    Outcome: persistence and ownership transitions stay correct under failure.
10. Add guild/faction/ban/mute persistence coverage.
    Outcome: shared cross-map state survives restart and migration.
11. Add web E2E smoke coverage for the current client gameplay path.
    Outcome: the browser path is tested end-to-end, not only by unit tests.
12. Add a load/soak gate.
    Outcome: long-running many-session behavior is tested before public use.
13. Add a manual VB6 release smoke checklist.
    Outcome: every compatibility claim is verified at least once with the
    unmodified VB6 client before release.

### Backend Core Parity Tail

14. Finish `/HOGAR` exact VB6 behavior.
    Outcome: home travel matches VB6 end-to-end, including delayed bar/effect,
    jail restricted area, NEWBIE zone, CARCEL trigger, reto/traveling cancel
    behavior, and arrival while still dead.
15. Finish old guild proposal UI behavior.
    Outcome: peace/alliance proposal-list/detail mailbox flows behave like the
    old clan UI and are covered by replay tests.
16. Replace the `gm_message` placeholder route.
    Outcome: `gm_message` becomes a real GM/server broadcast instead of a local
    chat shortcut.
17. Replace the `rain_toggle` placeholder route.
    Outcome: rain toggling becomes a direct backend action instead of chat
    indirection.
18. Implement `role_master_request`.
    Outcome: the remaining decoded-but-unhandled route has real behavior.
19. Keep elemental/rune combat effects data-driven.
    Outcome: elemental tags remain inert unless target data enables them; if it
    does, the combat matrix/effects are implemented without inventing new
    rules.

### Old-Client Packet/UI Tail

20. Finish the remaining old crafting UI packet surface.
    Outcome: old carpenter/blacksmith/alchemy/tailor windows can drive the
    existing crafting backend through open/add/remove/move/craft/close flows.
21. Decide the old GM/admin binary packet target.
    Outcome: the exact packet compatibility target is explicit instead of
    implicit.
22. Implement the remaining GM/admin binary packet behavior for that target.
    Outcome: the supported old GM/admin packet family works end-to-end.

### Full Old-VB6 Backend Systems

23. Implement quests and quest-NPC protocol.
    Outcome: quest state and quest NPC interactions exist on the backend.
24. Implement duels / reto exact flow.
    Outcome: the reto/duel lifecycle matches old server behavior instead of a
    simplified approximation.
25. Implement events / tournaments / lobby events / capture events /
    invasions / global world-event announcements.
    Outcome: server-side event systems match the selected old-server feature
    set.
26. Implement auction / subasta.
    Outcome: the old auction backend exists and is reachable through the
    compatible protocol/UI path.
27. Implement mounts if the target data expects mounts separate from
    boats/navigation.
    Outcome: mount behavior is present where the target shard/data requires it.
28. Implement gambling / arena-payment side systems.
    Outcome: the remaining economy side systems from the old server exist.
29. Implement treasure search.
    Outcome: treasure-search gameplay exists on the backend.
30. Implement forum / in-game message board.
    Outcome: the old in-game board/forum backend exists and persists correctly.
31. Implement marriage.
    Outcome: marriage-related backend state and actions exist.
32. Decide whether the old account/lobby packet system is still in scope.
    Outcome: either the old account/lobby backend is explicitly required, or
    the HTTP account/character lobby is explicitly accepted as the replacement.
33. If old account/lobby packets remain in scope, implement them.
    Outcome: the old account/lobby backend exists as a parity feature, not a
    future maybe.
34. Close any remaining backend drift only by adding a failing parity test
    first.
    Outcome: no undocumented "close enough" backend differences remain.

### Web Gameplay Client Tail

35. Decode, dispatch, and render snow when `snow_toggle` is active.
    Outcome: weather parity is visually complete in the browser.
36. Make party panels use authoritative state instead of console-text
    inference.
    Outcome: party UI reflects backend truth.
37. Make clan panels use authoritative state instead of console-text inference.
    Outcome: clan UI reflects backend truth.
38. Show trade item name / GRH / tags in the trade panel.
    Outcome: trade metadata visible in packets is actually shown to the user.
39. Improve death UX in the web client.
    Outcome: ghost/dead state is visually obvious and rejected actions are
    pre-disabled where appropriate.
40. Add settings/reconnect/error/banned/muted/maintenance polish.
    Outcome: the web client can handle common live-session edge states cleanly.
41. Keep `CLIENT_ROADMAP.md` synced with completed client work.
    Outcome: client status does not drift from actual implementation.

### Web Account And Character Lobby

42. Add `POST /api/auth/login`.
    Outcome: account-level username/password login exists over HTTP.
43. Add `POST /api/auth/google`.
    Outcome: account-level Google login exists over HTTP.
44. Add `GET /api/auth/session`.
    Outcome: browser session restore works without touching the AO socket.
45. Add `POST /api/auth/logout`.
    Outcome: account logout is explicit and clean.
46. Add `GET /api/characters`.
    Outcome: the browser can list account-owned characters.
47. Add `POST /api/characters`.
    Outcome: character creation exists in the account lobby flow.
48. Add `POST /api/characters/:id/session`.
    Outcome: selecting a character yields the token needed for unchanged AO
    socket entry.
49. Support password-only, Google-only, and linked accounts.
    Outcome: account identity model is explicit and flexible.
50. Build browser login/session restore flow.
    Outcome: users can authenticate and resume browser sessions cleanly.
51. Build browser character picker/create flow.
    Outcome: the browser chooses a character before opening the AO session.
52. Launch the AO socket with `login_existing_char(char_id, session_token)`.
    Outcome: gameplay protocol stays unchanged after the HTTP lobby.
53. Prefer same-origin serving or proxying for the account API.
    Outcome: cookies/session handling stays simple.

### Admin And Operations

54. Add admin lookup for accounts, characters, and online players.
    Outcome: operators can inspect live and persisted entities.
55. Add admin moderation actions: kick, ban, mute, jail.
    Outcome: basic live moderation exists outside raw gameplay commands.
56. Add admin world actions: item/NPC spawn, teleport, locate.
    Outcome: operator world control exists in one supported surface.
57. Add admin logs and health views.
    Outcome: operators can inspect recent actions and system state quickly.
58. Add metrics and dashboards.
    Outcome: runtime health can be observed without log scraping.
59. Add alerts and release artifacts.
    Outcome: the project is releaseable and operationally monitorable.
60. Add deployment pipeline and backup/restore runbook.
    Outcome: releases and recovery have a documented path.
61. Verify graceful host shutdown.
    Outcome: shutdown does not lose player state or corrupt runtime processes.
62. Add pre-public scripted load/soak runs.
    Outcome: operational confidence exists before open testing.

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
