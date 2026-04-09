# Parity Automation Plan

Goal: stop relying on repeated manual audits. Keep the original VB6 client and
server as the oracle, but convert their observable behavior into tests that run
against the Elixir server and web client.

## Principle

- Do **not** create a second "VB6 behavior" implementation in Python or
  TypeScript.
- Use the real VB6 code, captured packets, fixture rows, and hand-verified
  traces as the oracle.
- Every discovered drift becomes a fixture or regression test before or beside
  the fix.

## Milestone 1 — Current Green Gate

Run this before adding more compatibility work:

```sh
cd server
mix compile
mix test

cd ../client
npm run typecheck
npm run build
```

Expected result: zero compile errors, zero test failures, and a client build
that can connect to a local server.

## Milestone 2 — Packet Fixture Replay

Build a small fixture format:

```text
test/fixtures/packets/
  client/
    001_login_existing.bin
    002_walk_north.bin
  server/
    001_logged.bin
    002_pos_update.bin
```

For each fixture, test all applicable paths:

- Elixir decoder accepts the exact VB6 client bytes.
- Elixir encoder emits the exact VB6 server bytes for the same packet.
- Web decoder reads the fixture into the expected TypeScript packet object.
- Web encoder emits the expected gameplay bytes, wrapped only by the WebSocket
  transport.

Minimum fixture set:

- login existing / login result / reconnect token
- walk / position update / map change
- local chat / whisper / yell / faction chat / guild chat
- inventory slot update / pickup / drop / use / equip
- melee attack / ranged attack / damage / miss / death / resurrect
- spell cast / spell slot / FX / wave / buff-visible cases
- shop open / buy / sell
- bank open / deposit / withdraw / gold update
- user trade init / offer / slot change / accept / reject / close
- party invite / accept / safe toggle
- rain toggle / snow toggle
- character create / character change / character remove / NPC create

## Milestone 3 — Scripted AO Smoke Bot

Create a headless client that speaks the AO socket protocol and can run a YAML
or JSON script.

Required smoke scripts:

- `login_walk_chat`: login, enter map, walk four directions, talk, logout, relog
- `map_transfer`: enter an exit tile, load on destination map, return to source
- `inventory_loop`: pickup item, equip it, unequip it, use item, drop item
- `combat_npc`: find or spawn hostile NPC, attack, receive damage, kill NPC,
  verify XP/gold/loot
- `combat_pvp`: two bots attack, block/miss/damage, death, ghost visual,
  resurrect
- `spells`: damage spell, heal spell, cure/poison/paralyze/invisibility where
  available
- `commerce_bank`: open shop, buy, sell, open bank, deposit/withdraw item and
  gold, relog
- `trade`: two bots trade item and gold, accept, reject, cancel, verify
  conservation
- `party_guild_faction`: invite party, split XP, toggle safe, guild chat,
  faction chat, same-faction PvP rejection
- `crafting`: mine, fish, woodcut, craft one item, alchemy item, tailoring item
- `world_rules`: safe-zone rejection, hunger/thirst transition, jail/penalty,
  pet tame/follow/despawn

## Milestone 4 — Differential Formula Fixtures

For each formula, store explicit input/output fixtures verified against VB6.

Start with:

- melee hit chance
- ranged hit chance
- critical-hit chance and multiplier
- shield block chance
- armor / helmet / shield defense
- spell damage
- magic resistance reduction
- healing
- HP / mana / stamina regeneration
- hunger / thirst / starvation
- XP award
- party XP split
- level-up HP / mana / stamina gain
- skill-up / trainer skill increase
- shop buy / sell price
- craft / gather success chance
- tame success chance
- faction score / rank thresholds

## Milestone 5 — Property And Fuzz Tests

Add random tests for invariants, not for exact VB6 values.

Packet invariants:

- Random bytes never crash the decoder.
- Re-encoding a decoded known packet preserves the fixture bytes.
- Unknown packet IDs are rejected or logged without killing the session.

Gameplay invariants:

- HP, mana, stamina, hunger, thirst, gold, amount, and XP never become negative.
- Inventory amount is conserved across pickup/drop/bank/trade except for
  explicit consume/sell paths.
- Trade commit is atomic: either both players receive the final exchange or
  neither does.
- Occupancy has at most one living player/NPC occupant per tile.
- Map transfer leaves a character in exactly one MapServer.
- Autosave never saves stale source-map state after transfer.
- Dead players cannot move, bank, trade, attack, cast normal spells, or mutate
  inventory through regular actions.
- Server accepted movement is adjacent unless the flow is an explicit teleport,
  GM action, revive, login, or transfer.

## Milestone 6 — Browser E2E

Use a browser E2E runner for player-visible regressions.

Core assertions:

- Login/lobby chooses a character and reaches the game.
- Map tiles render; character sprite renders; NPC sprites use the correct body.
- HUD shows HP/mana/stamina/gold/level/XP/dead/navigation/weather/faction.
- Inventory, bank, shop, trade, party, clan, spell, skills, stats, chat, map,
  and settings panels open without client errors.
- Rain and snow toggles change the viewport.
- Death changes own player and remote players into ghost/dead appearance.
- Reconnect returns to the same character/map after a browser reload.

## Milestone 7 — Load And Soak

Create bot scenarios that hold a map open long enough to catch timers:

- 50 bots idle/chat/walk for 30 minutes
- 100 bots crossing AoI boundaries for 10 minutes
- 20 bots fighting NPCs for 30 minutes
- 10 simultaneous trades repeated 100 times
- server shutdown while players are online, then restart and relog

Track memory, reductions, mailbox lengths, DB query time, tick duration, packet
rate, disconnects, and anti-cheat false positives.

## CI Shape

- Pull request: compile, unit, integration, protocol golden, TypeScript
  typecheck, client build.
- Nightly: property/fuzz, smoke bot, browser E2E, migration on anonymized dev
  snapshot, load subset.
- Release candidate: full nightly plus manual VB6-client smoke pass.
