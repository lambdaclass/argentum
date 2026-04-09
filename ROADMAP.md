# Argentum Roadmap

This is the linear execution plan. Use `SERVER_ROADMAP.md` and
`CLIENT_ROADMAP.md` as deeper reference, but keep this file as the short source
of truth for sequencing.

## Current Status

- **Backend gameplay:** close, but not finishable until the explicit VB6 parity
  tail below is closed or deliberately reclassified. The highest-risk tail is
  combat/death rewards, death recovery, NPC gold semantics, old guild UI
  packets, runtime/migration validation, and parity automation.
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
- Finish/review the active combat patch before doing unrelated work: NPC
  per-hit XP, NPC `exp_count`, centralized player death cleanup, NPC/player
  death call sites, GM kill, poison, starvation, and NPC-player kill paths.
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

### 2. Close the backend compatibility tail

- **NPC XP parity:** VB6 awards proportional XP on every damaging hit, caps it
  with an NPC-side remaining `ExpCount`, and pays any leftover on kill. Keep
  party XP split working and do not award XP for hitting/killing pets.
- **Player death parity:** all death paths must enter one helper. Match the VB6
  side effects that affect gameplay: HP/stamina/target/combat-status cleanup,
  poison/paralysis/invisibility/buff cleanup, meditation/rest cleanup, open
  commerce/bank/trade cleanup, pet handling, ghost character change, persistence
  of counters, and death prompt/recovery flow.
- **Death inventory/equipment rules:** implement or explicitly defer the VB6
  drop/unequip rules for non-safe maps. The ghost packet hiding equipment is not
  the same thing as unequipping/dropping items.
- **Death recovery / home travel:** implement the `/HOGAR` / home-city recovery
  path and/or document the replacement flow. Spell/NPC resurrection alone is not
  enough for the classic "dead player returns home" loop.
- **NPC gold parity:** audit and choose the target behavior. In the inspected
  VB6 path, NPC `GiveGLD` is dropped on the NPC tile as gold items; one old
  group-gold helper exists, but was not found as the main kill path. Current
  Elixir/direct patches that add gold to a killer or split it to a party are a
  behavior choice and need a parity test.
- **Old guild UI protocol:** guild/clan gameplay exists via slash commands and
  backend state. If the unmodified VB6 guild window must work, add the old
  binary guild/clan request/list/news/war/alliance/election packet family, or
  explicitly mark that UI as not targeted.
- **Elemental/rune content:** per-instance `elemental_tags` are persisted,
  banked, traded, and sent. Current raw data appears dormant for elemental-only
  spells / NPC tags / damage matrix; keep this as future content support unless
  new data enables it. If enabled, parse static item/NPC tags, enforce
  elemental-only spell targeting, support elemental rune application, and apply
  `ElementalMatrixForNpcs`.
- **Home/rune/mount audit:** home city is stored and boats/navigation exist.
  Audit classic runes/home travel and mounts before declaring world-item parity.
- Run and verify all recent migrations in a real dev database.
- Keep auditing edge cases against VB6 only by adding a failing parity test
  first.

### 3. Close the web gameplay client tail

- Decode, dispatch, and render snow when `snow_toggle` is active.
- Make party and clan panels use authoritative state packets or a documented
  snapshot API instead of inferring membership from console text.
- Show trade item name / GRH / tags in the trade panel.
- Improve death UX: dead/ghost HUD state, disabled rejected actions, clear
  resurrect/help prompts.
- Add settings, reconnect, error, banned, muted, and maintenance-state polish.
- Update `CLIENT_ROADMAP.md` whenever a client feature moves from "planned" to
  "done".

### 4. Build the web account and character lobby

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

### 5. Add admin / operations

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
