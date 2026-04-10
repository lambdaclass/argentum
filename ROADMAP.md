# Argentum Roadmap

This is the linear execution plan. Use `SERVER_ROADMAP.md` and
`CLIENT_ROADMAP.md` as deeper reference, but keep this file as the short source
of truth for sequencing.

## Current Status

- **Backend gameplay:** close for the modern web path, but not full VB6 parity.
  Do not call the backend compatible until the explicit backend parity backlog
  below is either implemented or deliberately removed from the target.
- **Web client:** playable development client. The remaining work is the modern
  account/character lobby, weather/social polish, authoritative party/clan UI
  state, trade metadata display, E2E coverage, and UX polish.
- **Post-compat account flow:** not built. Target is username/password or Google
  account login over HTTP, character selection in the browser, then unchanged
  AO socket login with `login_existing_char(char_id, session_token)`.
- **Code size now:** backend app source is ~16k Elixir LOC; web client source is
  ~15k TypeScript/React/CSS LOC.

## Linear Plan

### 0. Stabilize the current branch

- Commit or intentionally discard any leftover generated migrations/files.
- Commit the pending protocol/combat tests if they are wanted:
  `server/apps/ao_protocol/test/ao_protocol/guild_protocol_test.exs` and
  `server/apps/arena/test/combat_lifecycle_test.exs`.
- Finish/review any active local combat patch before doing unrelated work.
- Fix any local Elixir/Hex/OTP toolchain mismatch. `mix compile` and `mix test`
  must run from a clean checkout before compatibility sign-off.
- Run the new migrations on a dev database.
- Run the current server and client checks once from a clean checkout.
- Update the top-level current-status sections after every large merge.

### 1. Build the parity test gate

This is the next infrastructure milestone. After it exists, every backend or
protocol change must pass it.

- Add packet fixture replay tests from real VB6 client/server traffic.
- Add an AO socket smoke bot that exercises the core player journey.
- Add formula golden tests generated from the VB6 server or hand-verified VB6
  traces.
- Add property / fuzz tests for binary packet parsing, formulas, inventory
  conservation, trade conservation, movement, visibility, and occupancy.
- Add lifecycle tests for login, autosave, logout, crash cleanup, map transfer,
  migrations, ban/mute persistence, guild persistence, and faction persistence.
- Add web E2E smoke coverage for login/session, map load, NPC visibility,
  inventory, combat, spells, bank, trade, party, clan, weather, death, and
  reconnect.
- Add a manual-release checklist that uses an unmodified VB6 client for one
  end-to-end smoke pass.

Detailed plan: `research/parity-automation-plan.md`.

### Backend parity tail checklist

Close this list in order if the target is the old VB6 server plus old client UI,
not just the playable web core.

#### A. Core VB6 parity still to close

1. **`/HOGAR` final parity:** no revive/full-heal; paid delayed home travel;
   travel bar/effect; jail restricted area, NEWBIE zone, CARCEL trigger,
   penalty/jail timer, reto, traveling cancel, already-home, no-gold handling.
2. **Raw `ehome` route:** packet ID 264 is decoded. Route `{:home, %{}}` to the
   `/HOGAR` handler.
3. ~~**Home-city mapping:** one VB6 enum everywhere: 1 Ulla, 2 Nix,
   3 Banderbill, 4 Lindos, 5 Arghal, 6 Arkhein, 7 Forgat, 8 Eldoria, 9 Penthar.~~
   **Done.**
4. **Elemental/rune combat effect:** tags are stored/sent; add active damage
   modifier only if target data actually enables elemental content.
5. **Guild proposal UI fidelity:** finish old peace/alliance/list/detail mailbox
   behavior instead of console-only placeholders.

#### B. Old VB6 client packet coverage

6. **Pet command packets:** `/QUIETO`, `/ACOMPANAR`, `/LIBERAR`, follow-all,
   leave-all. Decoders exist; route to pet handlers.
7. **Crafting UI packets:** open/add/remove/move/craft item; blacksmith,
   carpenter, alchemy, tailor windows. Some old craft decoders exist; complete
   the remaining decoders and route them to crafting.
8. **Training/spell UI packets:** train list, trainer creature list, spell info,
   move spell. Some decoders exist; route them and add response packets.
9. **Info UI packets:** `/AYUDA`, `/MOTD`, `/UPTIME`, `/BALANCE`, `/EST`,
   `/INFO`, `/RECOMPENSA`. Some decoders exist; route them and add responses.
10. **Faction/council binary command packets:** keep slash behavior, but expose
    the old packet surface too. Some decoders exist; route them.
11. **Full GM/admin binary packet family:** practical slash GM commands exist;
    some decoders exist. Route the old packet family or formally define the
    replacement.

#### C. Big old systems not fully rebuilt

12. **Quests and quest NPC protocol.**
13. **Auction / subasta.**
14. **Forum / in-game message board.**
15. **Events / tournaments / lobby events / capture events.**
16. **Duels / reto exact flow.**
17. **Invasions / global world events.**
18. **Treasure search.**
19. **Marriage.**
20. **Gambling / arena-payment side systems.**
21. **Mounts**, if target data has mounts separate from boats/navigation.
22. **Old account/lobby packet system**, unless explicitly replaced with the
    HTTP account API below.

#### D. Verification / release blockers

23. ~~**Track pending tests:** commit or intentionally remove
    `guild_protocol_test.exs` and `combat_lifecycle_test.exs`.~~ **Done.**
24. **Real Postgres migration run:** clean database and copy of a dev database.
25. **Automated parity gate:** VB6 formula golden tests, packet replay, smoke
    bot, decoder fuzz, combat/death integration, migration tests.
26. **Reliable local test toolchain:** fix Hex/OTP so `mix test` runs.
27. **Load/soak gate:** maps, NPC AI, trade, bank, guild, autosave, respawn,
    crash cleanup, and shutdown under many sessions.

#### E. After VB6 backend parity

28. **HTTP account-auth API.**
29. **Username/password account login.**
30. **Google login.**
31. **Multi-character list/create/select API.**
32. **Character session issuance:** selected character enters with the normal AO
    socket `login_existing_char(char_id, session_token)`.

#### Parity test checklist

Create these suites and keep them green:

- **Current regression suite:** `mix compile`, `mix test`, `npm run typecheck`,
  `npm run build`.
- **Protocol golden suite:** replay captured VB6 `.bin` packets for login,
  movement, map change, chat, inventory, combat, spells, NPCs, shop, bank,
  trade, party, guild, faction, weather, create/change/remove character.
- **Packet fuzz suite:** feed malformed/random bytes into client and server
  decoders; assert no session/server crash and no silent gameplay mutation.
- **Formula golden suite:** combat, spells, defense, block, criticals, XP,
  level-up, skill training, shop prices, hunger/thirst, regen, crafting,
  gathering, taming, faction ranks.
- **Formula property suite:** chance bounds, monotonic stats where expected,
  non-negative vitals/gold/XP, damage/defense bounds, price bounds.
- **MapServer integration suite:** enter, leave, movement, heading, transfer,
  AoI visibility, NPC visibility, occupancy, safe zones, death/ghost, revive,
  pet follow, weather.
- **Persistence/lifecycle suite:** migrations, character round trip, inventory,
  bank, guild, faction, counters, mute/ban, autosave, logout save, crash cleanup,
  transfer autosave stale-data guard.
- **Inventory/economy conservation suite:** pickup/drop/use/equip, bank,
  commerce, user trade accept/reject/cancel, gold transfer, item amount transfer.
- **Headless AO smoke bot:** scripted login, walk, transfer, chat, inventory,
  NPC combat, PvP, spells, death/revive, shop, bank, trade, party, guild,
  faction, crafting, gathering, pet, GM/admin smoke.
- **Web E2E smoke suite:** account/lobby once built, connect, map render, NPC
  render, HUD, inventory, spell, bank, trade, party, clan, chat, weather,
  ghost/death, reconnect.
- **Load/soak suite:** many bots walking/chatting/fighting/trading for long
  enough to exercise NPC AI, buffs, regen, hunger/thirst, autosave, respawn,
  crash cleanup, and graceful shutdown.
- **Manual VB6 release smoke:** use the unmodified VB6 client for one full
  player journey before claiming compatibility.

### 2. Close the core backend compatibility tail

Done in the recent backend parity pass; keep covered by tests:

- **NPC XP parity:** proportional per-hit XP, NPC-side `exp_count`, party XP
  split, and pet XP guard are implemented.
- **Player death entry points:** PvP, NPC, poison, starvation, and GM kill paths
  enter one death helper.
- **Player death cleanup:** death clears transient combat/status state, closes
  trade/bank/commerce state, despawns owned pets, increments death counters, and
  broadcasts ghost visuals.
- **Death inventory/equipment rules:** active death cleanup unequips equipped
  items and drops droppable inventory on unsafe maps.
- **NPC gold parity:** active combat code drops NPC `GiveGLD` as a gold ground
  object at the NPC death tile.
- **Guild backend depth:** guild persistence, tags, levels/XP, metadata,
  alignment, requests/aspirants, wars, peace, alliances, successor promotion,
  and old guild UI response encoders are implemented.

- **Guild UI route hardening:** all 27 client→server guild packets are decoded
  and routed. Elections/vote reply with VB6-parity "disabled" message.
  Accept/reject peace/alliance, website, member info are now wired to backend.
- **VB6 parity test suite:** `vb6_parity_test.exs` covers XP formulas,
  exp_count pool, death state cleanup, unequip-on-death, gold floor drops,
  combat formula bounds, and city spawn lookups.

Still open before calling backend compatibility done:

- **Death recovery / home travel:** make `/HOGAR` match VB6 exactly. A dead
  ghost starts a paid delayed home travel; it must not resurrect or full-heal.
  Preserve VB6 restrictions: jail restricted area, NEWBIE zone, CARCEL trigger,
  penalty/jail timer, reto, already-at-home, existing-travel cancel, gold cost,
  travel bar/effect, home arrival while still dead.
- **Raw `/HOGAR` packet:** decode and route old client `ehome` in addition to
  any web-client text command. Decoder exists; SessionLogic route is still open.
- ~~**Home-city mapping:** keep city enum, creation storage, `Ciudades.Dat`
  loading, fallback spawns, and `/HOGAR` lookup on one documented mapping.~~
  **Done.**
- **Guild proposal UI behavior:** keep old guild UI packets decoded, but finish
  the remaining peace/alliance proposal-list/detail behavior and cover it with
  packet replay tests.
- **Elemental/rune content:** per-instance `elemental_tags` are persisted,
  banked, traded, and sent. Current raw data appears dormant for elemental-only
  spells / NPC tags / damage matrix; keep this as future content support unless
  new data enables it.
- **Home/rune/mount audit:** home city is stored and boats/navigation exist.
  Audit classic runes/home travel and mounts before declaring world-item parity.
- Run and verify all recent migrations in a real dev database.
- Keep auditing edge cases against VB6 only by adding a failing parity test
  first.

### 3. Close old VB6 client packet / UI parity

This is required if "everything equal" means the unmodified old client can use
the whole old UI surface, not just the modern web UI and slash-command subset.

- **Pet UI packets:** `/QUIETO`, `/ACOMPANAR`, `/LIBERAR`, follow-all,
  leave-all. Decoders exist; route them to the existing pet ownership/AI system.
- **Crafting UI packets:** old open/add/remove/move/craft item packets,
  blacksmith/carpenter/alchemy/tailor forms, and close-crafting flow. Route
  them to the existing crafting backend. Some legacy craft decoders exist.
- **Trainer/spell UI packets:** train list, trainer creature list, spell info,
  move spell, and related response packets. Some decoders exist.
- **Info/service packets:** help, MOTD, uptime, account balance, stats/info,
  reward, punishments, map entrance price, online faction lists. Some decoders
  exist.
- **Faction/council packets:** binary faction/council messages and leave-faction
  command packets. Keep the slash/web commands, but do not require them for the
  old client. Some decoders exist.
- **GM/admin binary packets:** decide exact compatibility target, then decode
  and route the old GM packet family or explicitly document the replacement.
  A core GM decoder subset exists.

### 4. Rebuild any VB6 side systems kept in the target

These are backend/product systems from the old server. They are not required for
the narrow combat/shop/bank/trade loop, but they are required for "everything
equal" if the target shard used them.

- Quests and quest-NPC protocol.
- Auction / subasta.
- Forum / in-game message board.
- Events, tournaments, lobby events, capture events, invasions, and global
  world-event announcements.
- Duels / reto flow.
- Treasure-search system.
- Marriage.
- Gambling and arena / paid-entrance side flows.
- Mounts, if required separately from boats/navigation.
- Old account/lobby packet system, unless replaced by the HTTP account lobby
  below as an explicit product decision.

### 5. Close the web gameplay client tail

- Decode, dispatch, and render snow when `snow_toggle` is active.
- Make party and clan panels use authoritative state packets or a documented
  snapshot API instead of inferring membership from console text.
- Show trade item name / GRH / tags in the trade panel.
- Improve death UX: dead/ghost HUD state, disabled rejected actions, clear
  resurrect/help prompts.
- Add settings, reconnect, error, banned, muted, and maintenance-state polish.
- Update `CLIENT_ROADMAP.md` whenever a client feature moves from "planned" to
  "done".

### 6. Build the web account and character lobby

This is post-compatibility. It must not change the AO20 gameplay protocol.

- Backend HTTP API:
  `POST /api/auth/login`,
  `POST /api/auth/google`,
  `GET /api/auth/session`,
  `POST /api/auth/logout`,
  `GET /api/characters`,
  `POST /api/characters`,
  `POST /api/characters/:id/session`.
- Account model supports password-only, Google-only, and password+Google-linked
  accounts.
- Browser has account login, Google sign-in, account session restore,
  character picker, character create flow, and selected-character launch.
- AO socket entry stays `login_existing_char(char_id, session_token)`.
- Prefer same-origin serving or a proxy for the API; avoid cross-origin cookie
  and CORS complexity.

### 7. Add admin / operations

- Add an admin surface for account lookup, character lookup, online players,
  kicks/bans/mutes/jail, item/NPC spawn, teleport/locate, logs, and health.
- Optional product work: guild elections / democratic leader succession if the
  target shard needs it.
- Add structured metrics, dashboards, alerts, release artifact, deployment
  pipeline, backup/restore runbook, and graceful host shutdown verification.
- Add load/soak tests with many scripted players before public testing.

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

- The current automated server/client checks are green from a clean checkout.
- The automated parity gate is green.
- The database migrates forward on a clean database and on a copy of a real dev
  database.
- A player can complete the scripted smoke journey with the web client.
- A player can complete the same smoke journey with an unmodified VB6 client.
- Known divergences are either fixed or explicitly moved to a post-compatibility
  product backlog.
