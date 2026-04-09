# Argentum Online: VB6 → Elixir Migration Roadmap

**Linear plan:** start with `ROADMAP.md`. This file is the detailed backend
reference and historical phase plan.

## Current State

**Status legend:**
- `Done` — implemented on the live path and good enough to treat as complete for roadmap sequencing
- `Mostly done` — core feature works, but important roadmap details or cleanup remain
- `Partially done` — groundwork exists, but the phase is not closeable yet
- `Missing` — not implemented on the live gameplay path yet

**Current phase snapshot:**
- `Compatibility Gate — AO20 / VB6 Protocol & Behavior Parity`: `Mostly done`
- `Phase 1 — Runtime & Performance Foundations`: `Done`
- `Phase 2 — Character System, Persistence & Map Transitions`: `Done`
- `Phase 2A — Transition Quality & Client Map Pack`: `Done`
- `Phase 3 — Durable State & Persistence Shape`: `Done`
- `Phase 4 — Inventory`: `Done`
- `Phase 5 — Combat`: `Done`
- `Phase 6 — Spells`: `Done`
- `Phase 7 — NPC AI`: `Done`
- `Phase 8 — Commerce & Banking`: `Done`
- `Phase 9 — Crafting & Gathering`: `Mostly done`
- `Phase 10 — Social Systems`: `Mostly done`
- `Phase 11 — Progression`: `Mostly done`
- `Phase 12 — World Rules & Polish`: `Done`
- `Phase 13 — Auth & Account System`: `Done`
- `Phase 14 — Anti-Cheat & Server Hardening`: `Done`
- `Phase 15 — Operations & Infrastructure`: `Mostly done`
- `Phase 16 — Chat Moderation`: `Done`
- `Phase 17 — Scalability & Performance Hardening`: `Partially done`
- `Post-Compatibility — Web Account Auth & Character Lobby`: `Missing`

**Implemented so far (~16k lines of Elixir source + 295 lines Rust):**
- TCP + WebSocket networking with full AO20 protocol support (all 37 client→server, 52 server→client packet IDs)
- Authoritative `MapServer` with movement, chat, heading, map transitions, autosave, and direct session delivery
- AoI visibility lifecycle, `:global` / `:aoi_scan` / `:aoi_grid`, spatial grid, pre-encoded hot-path broadcasts
- Character creation, login, persistence, online directory, static `.dat` loading
- Full inventory: pickup, drop, equip toggle, item use, ground items
- Full melee + ranged combat (PvP + PvNPC): hit/miss, damage, defense, shield block, XP/gold/loot, death/respawn
- Spell system: damage, heal, status effects (paralysis, poison, cure, invisibility), mana/stamina costs, NPC spell casting
- NPC AI: hostile targeting, pathfinding, attack, random walk, respawning, loot drops, pet follow/attack
- Full crafting & gathering: mining, fishing, woodcutting, blacksmithing, carpentry, alchemy, tailoring, taming
- Commerce: NPC shopkeepers, bank, player-to-player trade
- Social: whisper, yell, parties (PartyServer with safe_toggle), guilds (GuildServer with DB persistence), rest/meditate, faction chat
- Factions: Royal Army / Chaos Legion enlist/leave, faction field on PlayerEntity, faction-gated map restrictions, same-faction PvP block, faction chat
- Progression: level-up with stat growth, skill training with trainer NPC gating + gold cost
- GM commands: teleport, spawn item, invisible, goto, info, kill, kick, ban, mute/unmute, jail, spawn NPC, locate
- Chat moderation: word filter, mute enforcement, chat rate limiting (1s cooldown)
- Anti-cheat: flood guard, speed hack detection, dead-state guards, range validation, cooldowns, structured audit logging
- Ops: graceful shutdown (terminate/2 autosave), audit logging for login/logout/trade/kill/GM actions
- Auth: accounts with bcrypt, character ownership
- Benchmark harness, benchmark maps, metrics, CI/release workflows, web test client
- Client: weather rendering (rain particles), faction HUD display, party panel, clan panel

**Recently closed backend parity items:**
1. **NPC XP parity** — proportional per-hit XP, NPC-side `exp_count`, party XP split, and pet XP guard are implemented.
2. **Player death entry points** — PvP, NPC, poison, starvation, and GM kill paths enter one death helper.
3. **Player death cleanup** — death clears transient combat/status state, closes trade/bank/commerce state, despawns owned pets, increments death counters, and broadcasts ghost visuals.
4. **Death inventory/equipment rules** — active death cleanup unequips equipped items and drops droppable inventory on unsafe maps.
5. **NPC gold reward semantics** — active combat code drops NPC `GiveGLD` as a gold ground object at the NPC death tile.
6. **Guild backend depth** — persistence, tags, levels/XP, metadata, alignment, requests/aspirants, wars, peace, alliances, successor promotion, and old UI response encoders are implemented.

**Recently closed:**
7. **Death recovery / home travel** — `/HOGAR` command implemented: dead players resurrect and teleport to home city.
8. **Guild UI route hardening** — all 27 guild packets decoded/routed. Elections reply "disabled" (VB6 parity). Accept/reject peace/alliance, website, member info wired.
9. **VB6 parity test suite** — `vb6_parity_test.exs` covers XP formulas, exp_count pool, death cleanup, unequip, gold drops, combat bounds, city spawns.

**Remaining backend gaps (gameplay tail):**
1. **Elemental/rune content support** — per-instance tags are persisted/protocol-visible. Current raw data scan found no active elemental values; defer unless content enables it.
2. **Automated parity gate expansion** — Initial parity test suite exists. Still needed: packet trace replay, AO smoke bot, property/fuzz, lifecycle tests, load/soak.
3. **Recent migrations need real DB verification** — Run clean-db + existing-dev-db migration path; verify character/inventory/bank/guild/faction loads after migration.
4. **Ops tail** — Dashboards, alerts, deploy pipeline, backup-restore, runbooks. Not gameplay, but backend production work (Phase 15 + 17).
5. **Perf tail** — NPC aggro still scans all players; pet targeting scans all NPCs; no outbound backpressure; no load/soak gate. NPC broadcast AoI is fixed (Phase 17).

**Remaining non-backend gaps:**
- Weather: snow rendering on client (server packet/state exists; rain rendering done)
- Post-compatibility web account flow: username/password or Google sign-in, account session, character list/create/select, token issue for `login_existing_char`

**VB6 server:** ~93,000 lines across 50+ modules
**Elixir server now:** ~16,000 lines source (+ tests)

---

## Linear Backend Plan

For the full product order, use `ROADMAP.md`. Backend sequencing is:

1. Stabilize the current branch: track all migrations, run migrations, run compile/tests from a clean checkout.
2. Build the automated parity gate: VB6 packet replay, formula golden fixtures, property/fuzz tests, lifecycle tests, AO smoke bot, browser E2E, load/soak.
3. Close backend compatibility tail in this order: `/HOGAR` death recovery, old guild UI route behavior + replay tests, elemental/rune content only if data enables it, migration/runtime verification.
4. Close operations tail: metrics, dashboards, alerts, release/deploy pipeline, backup/restore and shutdown runbooks.
5. Build post-compat account API only after the compatibility gate is green: username/password or Google account login, character list/create/select, character token issue, unchanged AO socket login.

---

## Stack & Constraints

- **Nix + devenv** for reproducible dev environment (Elixir, Rust, PostgreSQL, all dependencies)
- **PostgreSQL** for persistence (Ecto)
- **Elixir/OTP** for all server logic
- **Rust NIF** only for tile collision grid (existing `TileGrid`)
- **TCP** with the exact AO20 binary protocol — the VB6 client must be able to connect and play
- **WebSocket** as a parallel transport for the Pixi.js web client, same packet format

**The AO20 binary protocol is not negotiable.** The original VB6 client is the ultimate integration test. Every packet ID, field order, and byte layout must match. If the VB6 client can log in, walk, fight, and trade against our server, the implementation is correct. The web client is a convenience for development; the VB6 client is the source of truth.

### Client Map Data Format

- **Backend source of truth:** keep `.csm` map files as the authoritative content source.
- **Server runtime:** parse `.csm` into Elixir/Rust runtime structs; do not make client JSON the canonical format.
- **Serious web client:** ship a **prepacked binary map bundle** downloaded up front at client boot, or split into a few region packs if startup size becomes a problem.
- **Do not rely on per-map JSON fetches on transition** for the serious client. They are acceptable for debug tools, manual inspection, and development endpoints, but not the long-term runtime path.
- **Keep JSON as a dev/debug format only** so maps remain easy to inspect and test from the browser.

**Decision:** `.csm` on the backend, binary packed map data on the frontend, JSON only for tooling/debug.

---

## Compatibility Gate — AO20 / VB6 Protocol & Behavior Parity

**Status:** `Mostly done`

This gate sits above the feature phases. A phase is only truly complete when the
Elixir server remains playable by the original VB6 client without protocol
patching or behavior-specific workarounds.

**Done means:**
- The raw TCP AO20 path matches the VB6 packet IDs, field order, sizes, and byte layout for every implemented packet.
- The original VB6 client can log in, walk, chat, attack, cast, equip/use/drop, buy/sell, die/resurrect, and relog against the Elixir server.
- Web-only conveniences or extensions never become mandatory on the VB6 path.
- Behavior-level deviations from VB6 are either closed or explicitly tracked here as open work.

### Protocol parity backlog

- ~~Expand `AoProtocol` packet coverage~~ — **Done.** All 37 client→server packet IDs have decoders; all 52 server→client packet IDs have encoders. No reduced subset.
- ~~Fix server packet ID mismatches (commerce/shop flows)~~ — **Done.** Commerce IDs (10/8) were verified correct against VB6 source; stale encoder comments fixed.
- ~~Fix payload layout mismatches~~ — **Done.** All known mismatches fixed:
  - server→client: `change_spell_slot`, `character_change`, `character_remove`, `npc_hit_user`, `user_hitted_user`, `user_hitted_by_user`, `create_fx`, `play_wave`, `change_npc_inventory_slot`
  - client→server: `talk`, `whisper`, `attack`, `drop`, `cast_spell`, `left_click`, `use_item`, `equip_item` (packet_counter consumption added)
- ~~Keep extension packets out of VB6 path~~ — **Done.** `session_token` (ID 200) is WS-only, injected by WsHandler, never sent on TCP.
- Remaining: old guild/clan UI response encoders, core routes, and payload
  consumption for known old-client guild packets exist. Harden the remaining
  route behaviors and add VB6 packet replay tests. `online` returns player count; `use_spell_macro` is
  intentionally server-side no-op because the client resolves macros into
  `cast_spell`.

### Behavior parity backlog

- Keep auditing gameplay semantics against VB6 and treat "close enough" as incomplete.
- Closed items:
  - ~~ranged attacks (bow/arrow, ammo consumption, distance targeting)~~ — **Done.** Bow/arrow with ammo consumption in combat_handlers.ex.
  - ~~buff/debuff timers (paralysis, poison, invisibility never expire)~~ — **Done.** Buff expiry via `expires_at` + `process_player_buffs` in buff_tick.
  - ~~resurrection spells (spell_def.revivir parsed but unchecked)~~ — **Done.** `apply_spell_resurrect` in combat_handlers.ex + NPC revive in social.ex.
  - ~~NPC spell casting (npc_def.lanza_spells parsed but unused)~~ — **Done.** `maybe_cast_spell` in npc_ai.ex.
  - ~~appearance packets missing equipment fields~~ — **Done.** character_create/character_change include weapon/shield/helmet/body from equipment.
  - ~~death/revive not broadcasting character_change~~ — **Done.** All death/revive paths broadcast ghost body (829) / alive body.
  - ~~armor equip not updating body_id~~ — **Done.** Ropaje lookup from obj.dat, base_body_id for naked body restoration.
  - ~~FX packets using wrong field name (fx_id vs fx)~~ — **Done.** Fixed in social.ex meditate/resurrect.
  - ~~duplicated packet builder in SessionLogic~~ — **Done.** Removed; all sites use Helpers.character_create_packet.
  - ~~hunger/thirst drain missing~~ — **Done.** Drain by 1 per regen tick, starvation damage at 0, regen blocked.
  - ~~trainer NPC gating for skill training~~ — **Done.** Proximity check for npc_type 3 (entrenador) + gold cost (`max(current * 10, 10)`) + update_gold packet.
  - ~~trade packet 100 full VB6 shape~~ — **Done.** Encoder includes name/GRH/tags fields.
  - ~~`party_safe_toggle` handler~~ — **Done.** PartyServer.safe_toggle/1 toggles `:safe` flag on party, combat_handlers checks `party_safe?/2`.
  - ~~hunger/thirst VB6 semantics~~ — **Done.** Interval counters (@hunger_thirst_drain_interval=10), stamina pressure before HP damage, starvation kills at 0 HP.
  - ~~faction system~~ — **Done.** `faction` field on PlayerEntity (:none/:royal_army/:chaos_legion), enlist/leave via `/ENLISTAR`/`/RENUNCIAR`, faction-gated map restrictions, same-faction PvP block, faction chat via `/FACCION`, faction_status in mini_stats.
  - ~~NPC per-hit XP + exp_count~~ — **Done.** XP is awarded on damaging hits and capped by the live NPC pool.
  - ~~deep player death helper~~ — **Done.** PvP, NPC, poison, starvation, and GM kill enter the same cleanup path.
  - ~~NPC gold drop~~ — **Done.** NPC `GiveGLD` drops as a gold ground object.
- Remaining open items:
  - `/HOGAR` / home-city death recovery
  - old guild UI route/election behavior and replay tests
  - interval clamps that may still differ from raw VB6 data-driven timing
  - ongoing invisibility / AI / spell-selection edge-case review

### Compatibility test gate

- ~~Add byte-golden tests for every implemented packet~~ — **Done.** 150 golden tests cover all encoder/decoder pairs.
- Add fixture/trace tests derived from the VB6 client and server packet writers/readers.
- Add explicit VB6-client smoke coverage for:
  - ~~login~~ / reconnect
  - ~~walk~~ / map transfer
  - ~~whisper / yell~~ / console flow
  - ~~melee~~ / ~~ranged~~ / ~~spell cast~~
  - ~~equip / use / drop / pickup~~
  - ~~shop open / buy / sell~~
  - ~~bank open / deposit / withdraw~~
  - ~~death / resurrect~~ / relog persistence

No server phase that changes networking or gameplay semantics should be marked
`Done` if this gate regresses.

---

## Architecture: Authoritative MapServer

Each MapServer GenServer owns the complete authoritative state for everything happening on that map while players are online. There is no CharacterServer for gameplay state. This eliminates all cross-process coordination and race conditions — the same model as the VB6 server (single-threaded per-map authority), but parallelized across maps.

### Core model

- **One authoritative MapServer per active map.** While a player is online, their full gameplay state lives in that map's Elixir state.
- **Session processes are thin:** socket, packet decode/encode, current `map_pid`, `char_id`, basic flood protection.
- **Persistence owns offline state only.** DB is canonical when the player is logged out.
- **Static data** (item defs, spell defs, NPC defs, race/class tables) lives in ETS or `:persistent_term`.
- **Rust NIF is narrow:** tile collision grid, optionally LOS and pathfinding if profiling justifies it. Does not hold gameplay state.

### Why this model

- One writer for all live gameplay state — no races, no coordination.
- Closest to VB6 semantics: immediate action processing, periodic background timers.
- Parallel across maps without splitting one player across multiple authorities.
- The VB6 server runs all gameplay in interpreted Basic and handles hundreds of players. Elixir is faster than VB6 — no need for Rust to own gameplay state.

### Process tree

```
SessionSupervisor
  └─ one session process per connection

MapSupervisor
  └─ dynamic MapServer per active map

PersistenceSupervisor
  └─ snapshot/save workers

Global services
  ├─ auth/account
  ├─ bank (DB-backed, loaded on demand)
  ├─ guild/faction (DB-backed, cross-map)
  ├─ online lookup service: name ↔ char_id, char_id → map_id/session_pid
  └─ presence directory: char_id → map_id
```

### What MapServer owns

All live mutations while a player is on the map:

- **Player entities:** `%{char_id => %PlayerEntity{}}` — position, heading, HP/mana/stamina, level, XP, stats, skills, inventory, equipment, buffs, debuffs, cooldowns, spells, gold, flags
- **NPC entities:** `%{npc_id => %NpcEntity{}}` — position, aggro target, patrol state, stats, respawn timer, AI type
- **Ground items:** indexed by `{x, y}` for pickup lookups
- **Dynamic occupancy:** dense 100×100 structure (`:array` or tuple-backed grid)
- **Session bindings:** `%{char_id => pid()}` — direct sends, not PubSub
- **Map-local timers:** NPC AI, respawn, weather, autosave
- **All gameplay operations:** move, attack, cast, equip, use item, pickup/drop, death/revive, loot/XP, enter/leave/transfer

### Data structures

| Data | Structure | Why |
|------|-----------|-----|
| Players by ID | `Map` (`%{char_id => %PlayerEntity{}}`) | BEAM maps are the right default for entity lookup |
| NPCs by ID | `Map` (`%{npc_id => %NpcEntity{}}`) | Same |
| Sessions | `Map` (`%{char_id => pid()}`) | Direct sends to session pids |
| Ground items | `Map` (`%{{x, y} => [%GroundItem{}]}`) | Pickup checks "what's at my feet" |
| Static tile collision | Rust NIF (existing `TileGrid`) | Dense 100×100 grid, hammered on every move |
| Dynamic occupancy | `:array` or tuple-backed 100×100 | Dense integer-indexed, fast position checks |
| Item/spell/NPC defs | ETS or `:persistent_term` | Read-heavy, shared across maps, write-never |

### Execution model: immediate processing, not ticks

The VB6 server processes every player action **immediately** when the packet arrives — no tick batching, no intent queues. The main loop is `While(True)` → `Server.Poll` (dispatches packet handlers synchronously) → `Server.Flush` → `Sleep 1`. Each handler mutates world state and queues response packets inline. Timers exist only for background work (NPC AI, respawns).

Our Elixir MapServer mirrors this exactly. The GenServer mailbox provides the same serialization guarantee as VB6's single thread — one message processed at a time, no races. Player actions are `handle_call`/`handle_cast` callbacks that execute immediately.

**Periodic timers (background only):**
- NPC AI: `Process.send_after(self(), :npc_ai_tick, 100)` — every 100ms
- Respawn: check respawn timers
- Autosave: snapshot dirty entities to DB every 60s
- Buff/debuff decay: tick counters down
- Regen: HP/mana/stamina if resting/meditating
- Hunger/thirst: slow drain

### Action rate limiting

Server-side cooldowns per player, not ticks. Each entity has:

```elixir
%PlayerEntity{
  next_move_at: 0,      # System.monotonic_time(:millisecond)
  next_attack_at: 0,
  next_spell_at: 0,
  next_item_use_at: 0,
  speed_hack_counter: 0.0,
  ...
}
```

On each intent:
1. `now = System.monotonic_time(:millisecond)`
2. Reject if `now < next_*_at`
3. Otherwise process immediately, update cooldown

Walk speed limiting mirrors VB6's soft accumulator:
- `min_interval = base_walk_interval / speeding`
- `elapsed = now - last_step_at`
- `delta = (min_interval - elapsed) / min_interval`
- If `delta > 0`: `speed_hack_counter += delta` — if over threshold, reject and snap position
- If `delta <= 0`: `speed_hack_counter += delta * 5` — decay 5× faster

Session-level flood protection: token bucket or messages/sec cap, disconnect obvious packet flooders.

### Online lookup service

A lightweight global lookup service tracks online characters by both ID and normalized name:

- `char_id -> %{name, map_id, session_pid}`
- `normalized_name -> char_id`

Used for:
- whisper / tell by character name
- party invites and friend lookups
- GM locate / online queries
- any session routing that starts from a name instead of an ID

Updated on:
- login / successful map enter
- map transfer
- logout / disconnect

### Race condition prevention

**There are no cross-process races for gameplay state.** All gameplay-visible state lives in one MapServer GenServer, processed one message at a time. The problems from dual-authority designs (stale projections, BEAM mailbox ordering across processes, epoch/version tagging) don't exist.

The only coordination points:

**Enter map (synchronous):**
1. Session loads character from DB (or receives entity struct from old map)
2. Session calls `MapServer.enter(map_id, player_entity, {x, y})` synchronously
3. MapServer puts entity into state, updates occupancy
4. MapServer sends create packets to nearby sessions directly
5. Returns `:ok` — character is now on the map

**Leave map / map transfer:**
1. MapServer detects exit tile (or receives leave intent)
2. MapServer extracts full `%PlayerEntity{}` from state, removes from occupancy
3. MapServer sends leave packets to nearby sessions
4. MapServer sends `{:transfer, dest_map, dest_x, dest_y, entity}` to session
5. Session calls `MapServer.enter(dest_map, entity, {dest_x, dest_y})` on new map
6. At no point do two maps both own the same player

**Logout / disconnect:**
1. MapServer exports player entity
2. Session saves to DB
3. Character is now offline — DB is authoritative again

**Bank access:**
- Bank lives in DB, not in MapServer (doesn't affect live gameplay)
- Bank open: session reads bank from DB, sends to client
- Deposit: intent to MapServer → removes item from entity inventory → session writes to bank table
- Withdraw: session reads from bank → intent to MapServer → adds item to entity inventory

### Rust NIF scope

Rust is **narrow and optional** — only for operations where a dense data structure clearly beats BEAM maps:

```
TileGrid.load_map(map_id, tiles)     → :ok
TileGrid.is_walkable(map_id, x, y)  → boolean
TileGrid.move_entity(map_id, x, y, dir) → {:ok, pos} | {:error, :blocked}
TileGrid.get_tile(map_id, x, y)     → integer
TileGrid.unload_map(map_id)         → :ok
```

This already exists and works. Do not expand Rust scope unless profiling shows a bottleneck. All gameplay formulas, entity state, combat, inventory, spells, AI — pure Elixir.

### State ownership summary

| State | Owner while online | Owner while offline |
|-------|-------------------|-------------------|
| Position, heading | MapServer entity | DB |
| HP, mana, stamina | MapServer entity | DB |
| Inventory (carried) | MapServer entity | DB |
| Equipped items | MapServer entity | DB |
| Buffs, debuffs, cooldowns | MapServer entity | DB (persisted subset) |
| Stats, skills, level, XP | MapServer entity | DB |
| Gold on hand | MapServer entity | DB |
| Flags (dead, criminal, etc.) | MapServer entity | DB |
| NPC state | MapServer | N/A (respawn from data files) |
| Ground items | MapServer | N/A (ephemeral) |
| Bank inventory | DB | DB |
| Quest progress | MapServer entity | DB |
| Guild/faction membership | DB (shared across maps) | DB |
| Account/auth | DB | DB |

**Rule of thumb:**
- If it changes during gameplay → MapServer entity state
- If it's networking, supervision, or orchestration → Elixir session / supervisor
- If it must survive logout → DB (snapshotted periodically while online)
- If it's shared across maps (guilds, factions) → DB + PubSub
- If it's static definitions (items, spells, NPCs) → ETS / `:persistent_term`

### Character Identity
- Database PK: integer (auto-increment), not UUID — matches VB6 protocol's Int32 char_id
- Client-visible ID: same integer, sent in login packet
- Session process name: `{:via, Registry, {Arena.SessionRegistry, char_id}}`

---

## Phase 1 — Runtime & Performance Foundations

**Status:** `Done`

**In code now:**
- AoI visibility lifecycle on enter / move / leave
- `:global`, `:aoi_scan`, and `:aoi_grid` visibility modes
- Spatial grid for nearby-player lookup
- Pre-encoded / raw hot-path broadcasts
- Benchmark harness, benchmark maps, and broadcast metrics

**Remaining gaps before calling this truly finished in operations terms:**
- Better AoI-specific test coverage under non-`global` test config
- Ongoing benchmark regression discipline as later phases land

**Goal:** The server is measurably fast before more gameplay systems land. Visibility, broadcast cost, and benchmarking must be explicit foundations, not scattered optimizations.

**What to build:**

### Visibility model
- Match classic AO visibility: 23×19 viewport, half-range 11×9
- Add full visibility lifecycle in MapServer:
  - enter returns only visible players
  - leave / transfer send `character_remove` only to visible observers
  - move diffs old vs new visibility and sends `character_create` / `character_remove` on boundary crossings
- Route movement, chat, and heading through shared visibility helpers instead of ad hoc broadcast paths

### Visibility modes
- Add config-driven `visibility_mode`:
  - `:global` — no AoI, everyone sees everyone
  - `:aoi_scan` — AoI by scanning all players
  - `:aoi_grid` — AoI with spatial grid (production mode)
- Read mode from runtime config so the same server build can be benchmarked under every mode
- Use `AO_VISIBILITY_MODE=global|aoi_scan|aoi_grid` for repeatable local and CI benchmarks

### Spatial grid
- Maintain grid inline on enter / move / leave
- Keep cell size at least as large as the larger AoI axis so nearby lookup only touches the 3×3 neighboring cells
- Keep grid ownership inside MapServer; no extra process or ETS index unless profiling proves it is needed

### Packet delivery hot path
- Add pre-encoded / raw packet sends for the high-frequency observer packets:
  - `character_move`
  - `chat_over_head`
  - `character_change_heading`
  - `character_create`
  - `character_remove`
- Keep session processes thin; they should forward raw binaries when available and only encode on cold paths

### Benchmark harness
- Add deterministic one-map load-test scenarios:
  - `spread` — players distributed across a large open area
  - `hotspot` — players constrained to a dense rectangle
- Extend `bot_army` with explicit profiles:
  - `idle`
  - `walk_only`
  - `walk_chat`
- Add a benchmark map or benchmark mode with exits disabled so per-map tests stay on one map

### Metrics and acceptance criteria
- Record:
  - recipients per move
  - bytes/sec out
  - p50 / p95 walk latency
  - MapServer mailbox length
  - scheduler utilization
  - RSS / CPU
- Benchmark and compare all three visibility modes before Phase 2 work is considered complete
- Keep results in the repo so later feature work can be checked against a known baseline

**Why this phase is first:**
- AoI changes the scaling curve
- the spatial grid changes lookup cost
- raw packet sends reduce constant overhead
- benchmarking tells us whether the next gameplay phases are staying inside budget

**Lines estimate:** ~500 Elixir + benchmark scripts/docs

**Depends on:** nothing beyond the current AO20 transport and map loading work

---

## Phase 2 — Character System, Persistence & Map Transitions

**Status:** `Done`

**In code now:**
- DB-backed characters and `%PlayerEntity{}`
- Character creation and login on the live session path
- Autosave/logout save flow
- Map transitions through exit tiles
- Online directory / presence lookup
- Static race/class/item data loading
- Real accounts table with bcrypt password hashing (Phase 13 merged here)
- `belongs_to :account` FK on characters
- Skills and spells normalized into `character_skills` and `character_spells` tables
- Integration tests: auth (invalid token, wrong password), persistence roundtrips (stats, inventory, spells), transfer stress (rapid transitions, state persistence, concurrent players)

**Goal:** Players can create characters, log in with real state, persist across sessions, spawn on the correct map, and transfer between maps.

**What to build:**

### Database
- Ecto schema: `characters` table with integer PK
  - name, race, class, gender, home_city
  - level, xp, skill_points
  - map_id, pos_x, pos_y, heading
  - hp, max_hp, mana, max_mana, stamina, max_stamina
  - hunger, thirst
  - str, agi, int, con, cha
  - gold, bank_gold
  - flags (dead, poisoned, criminal, etc.)
- Ecto schema: `inventory_items` (character_id, slot, item_id, amount, equipped)
- Ecto schema: `character_skills` (character_id, skill_id, value)
- Ecto schema: `character_spells` (character_id, slot, spell_id)
- Ecto schema: `bank_items` (character_id, slot, item_id, amount)
- Migration to create all tables with integer PKs

### PlayerEntity struct
- Define `%Arena.Entity.PlayerEntity{}` with all gameplay fields
- Position, heading, stats, skills, inventory slots, equipped slots, buffs, cooldowns, flags
- Cooldown fields: `next_move_at`, `next_attack_at`, `next_spell_at`, `next_item_use_at`
- Speed hack fields: `last_step_at`, `speed_hack_counter`, `speeding`

### Session process (thin, no gameplay state)
- Started on login, registered via `{:via, Registry, {Arena.SessionRegistry, char_id}}`
- Loads character from DB → builds `%PlayerEntity{}` → calls `MapServer.enter(map_id, entity)`
- Forwards all client packets as messages to current MapServer
- Enforces basic flood protection: token bucket / per-second packet cap, disconnect obvious spam
- On disconnect: triggers `MapServer.leave` → gets entity back → saves to DB
- Periodic autosave: asks MapServer for snapshot → writes to DB

### Online lookup service
- Add lightweight `OnlineLookup` service (GenServer + ETS or Registry-backed index)
- Track `char_id -> %{name, map_id, session_pid}` and `normalized_name -> char_id`
- Register on login, update on transfer, unregister on disconnect
- Used by whispers, party invites, GM locate, `/who`, and name-based online checks

### MapServer refactor
- Replace current per-entity `%{x, y, char_index}` with full `%PlayerEntity{}`
- Replace PubSub broadcasts with direct sends to session pids via `sessions` map
- Add `handle_call({:enter, ...})` and `handle_call({:leave, ...})` with entity import/export
- Movement: check cooldown → check collision (Rust NIF) → check occupancy → update entity → send to nearby sessions

### Character creation (packet 74)
- Validate name (length, allowed chars, uniqueness)
- Race selection: Humano, Elfo, Drow, Enano, Gnomo, Orco
- Class selection: Mage, Cleric, Paladin, Hunter, Trabajador, Warrior, Thief, Bandit, Assassin, Druid, Bard, Pirate
- Base attributes: 18 + race modifier per stat
- Starting HP/mana/stamina from class tables
- Starting items per class (weapons, potions, armor)
- Insert into DB → build entity → enter starting map

### Login (packet 73)
- Load character from DB → build entity → enter saved map
- MapServer sends create packets to nearby sessions
- Send real stats to client (from entity state, not hardcoded)

### Map transitions
- On exit tile: MapServer extracts entity → sends to session → session enters new map
- Load maps on demand: `MapSupervisor` starts MapServer if not already running
- Starting cities: Ullathorpe (map 1, 56/44), Nix (map 34, 40/86), Arghal (map 151, 52/36)

### Static data loading
- `resources/raw/Dat/Razas.dat` → ETS race attribute modifiers
- `resources/raw/Dat/Clases.dat` → ETS class modifiers (mana multiplier, HP range, skill points per level)
- `resources/raw/Dat/obj.dat` → ETS item definitions

**VB6 reference:** `TCP.bas:ConnectNewUser()`, `CharacterPersistence.bas`, `Modulo_UsUaRiOs.bas`

**Lines estimate:** ~1,200 Elixir

**Depends on:** PostgreSQL running (already configured in game_backend)

---

## Phase 2A — Transition Quality & Client Map Pack

**Status:** `Done`

**In code now:**
- Map transfers work on the live path, covered by authority-level and TCP integration tests
- Prepacked binary map bundle (59MB, 842 maps) downloaded at client boot
- Scene caching with adjacent map warmup in the web client
- Transfer state machine in GameRuntime — suppresses stale corrections, snaps to destination
- No blank-frame flash on transitions
- Integration tests cover rapid back-and-forth transitions, state persistence across transfers, and concurrent player transfers

**Goal:** Map transitions should feel effectively instant, stable, and visually continuous in the serious client, matching or exceeding the historical test client.

**What to build:**

### Client map data delivery
- Keep `.csm` as the backend/source format
- Generate a **prepacked binary map bundle** for the serious web client at build time
- Download the full bundle at boot, or split into a few region packs only if startup size becomes a problem
- Keep JSON endpoints only for debug/dev tooling

### Client map runtime cache
- Decode packed map data once into client-native typed structures
- Cache decoded map data for the full session
- Build and reuse static Pixi map scenes instead of rebuilding them on every handoff
- Keep static map layers separate from dynamic entities, chat bubbles, and ground objects

### Transfer state machine
- Treat map transfer as a special client-side runtime state
- Suppress stale source-map movement corrections once transfer begins
- Do not resume normal local prediction until destination map data and destination self-position are both confirmed
- Snap self cleanly to the destination map bootstrap packets instead of allowing backtrack/rubber-band artifacts

### Server packet cleanup
- Keep source leave / destination enter ordering safe
- Consider a more explicit transfer packet flow so the client does not have to infer handoff state from an exit-tile `pos_update` followed by `change_map`
- Preserve AO protocol compatibility while reducing transfer ambiguity where possible

### Visual polish
- No empty-frame flash, black-frame swap, or obvious scene teardown during transfer
- Optional fade/crossfade only after correctness and timing are solid
- Preserve the historical viewport-first presentation: gameplay view dominates, side panels remain secondary

### Acceptance criteria
- Repeated city/outdoor map swaps show no visible flash, black frame, or “move then snap back” artifact
- Destination maps are available without per-transition network fetch latency in the serious client’s normal runtime path
- The serious client transitions feel at least as stable as `test_client.html`
- Real client smoke: walk back and forth through multiple exits continuously without desync or jarring scene changes

**Lines estimate:** client-heavy phase; mostly TypeScript/build tooling plus a small amount of supporting Elixir

**Depends on:** Phase 2 (basic character enter/leave/transfer flow), Phase 1 (serious web client foundation)

---

## Phase 3 — Durable State & Persistence Shape

**Status:** `Done`

**In code now:**
- Inventory and equipment in dedicated tables (`inventory_slots`, `character_equipment`)
- Skills normalized into `character_skills` table (name + level, upsert on save)
- Spells normalized into `character_spells` table (spell_id, upsert on save)
- Bank items in `bank_items` table with `has_many` on Characters and `save_bank_items` helper
- Character load/save paths assemble/disassemble all normalized associations
- `bank_items_from_db/1` helper for Phase 8 NPC interaction
- The runtime model keeps live authoritative state in `MapServer`, not in the DB
- Decide the durable boundary for future systems like quests/guild state
- Keep transient runtime state out of the database model

**Goal:** Durable character state is stored in a stable, queryable shape without turning transient gameplay state into database churn.

**What to build:**

### Keep inline on `characters`
- Identity and presentation fields
- Race, class, gender, home_city
- Level, XP, skill_points
- HP, mana, stamina, hunger, thirst
- Map/position/heading
- Gold / bank_gold
- Major persistent flags

### Normalize into dedicated tables
- `inventory_slots`
- `character_equipment`
- `character_skills`
- `character_spells`
- `bank_items`

### Keep out of normalized persistent tables
- Cooldowns
- Temporary buffs/debuffs
- AoI/session/runtime-only state
- Short-lived combat state

### Persistence behavior
- `MapServer` remains authoritative while online
- Writes happen on autosave/logout/checkpoints, not per action
- Load/save code should assemble and disassemble a full `%PlayerEntity{}` cleanly

### Verification
- Round-trip load/save tests across all normalized associations
- Relog tests that prove entity state is equivalent before and after persistence
- Migration tests for inventory/equipment/schema refactors

**Lines estimate:** ~400 Elixir + migrations/tests

**Depends on:** Phase 2 (basic character persistence and map entry/exit)

---

## Phase 4 — Inventory

**Status:** `Done`

**In code now:**
- `obj.dat` item loading with full restriction fields (forbidden_classes, allowed_races, gender_restriction, destruye)
- Pure inventory logic module with 4-arity `equip_toggle` validating level/class/race/gender restrictions
- Ground items in `MapServer` with `Destruye` flag handling (items destroyed on drop instead of placed on ground)
- Pickup, drop, equip toggle, and item use on the live path
- Inventory sync on login
- `CombatStats` module for effective defense/damage computation from equipment
- Bank items persistence via upsert pattern (offline-only, for Phase 8 NPC interaction)
- Full test coverage: inventory unit tests + integration tests for persistence roundtrips

**Goal:** Players can pick up, drop, equip, use, and manage items.

**What to build:**
- Inventory logic in `%PlayerEntity{}`: 24 slots, stacking, equipped slot tracking
- Item data from `obj.dat` already in ETS (Phase 1)
- All inventory operations handled immediately in MapServer `handle_cast`/`handle_call`:
  - Pick up: check ground item at entity position → add to inventory → remove from ground (atomic, same process)
  - Drop: remove from inventory → place on ground. Respect `Destruye` flag
  - Equip/unequip: validate class/level/gender restrictions, update equipped slots, recalculate effective stats
  - Use item by type:
    - `otPotions` (11): heal HP/mana/stamina, apply stat buff with duration
    - `otUseOnce` (1): food (restore hunger)
    - `otDrinks` (13): restore thirst
    - `otWeapon` (2): equip validation
- Stacking rules: same item ID + same elemental tags, max 10,000 per slot
- Gold special case: obj 12 goes straight to entity gold counter
- Send inventory update and equip change packets to client directly

**VB6 reference:** `InvUsuario.bas`

**Lines estimate:** ~600 Elixir

**Depends on:** Phase 3 (durable inventory/equipment persistence shape)

---

## Phase 5 — Combat

**Status:** `Done`

**In code now:**
- `Arena.Combat` — pure formula module: hit_chance, melee_damage, apply_defense, shield_block?, xp_gain, npc_hit/damage
- `Arena.CombatStats.shield_defense_pct/1` — shield percentage from equipment
- Class combat modifiers loaded from Balance.dat (attack, damage, evasion, shield)
- MapServer `handle_call({:attack, char_id})` — full PvNPC and PvP melee pipeline
- PvNPC: hit/miss, damage with defense, NPC death (respawn timer, XP, gold, loot drops), target acquisition on retaliation
- PvP: safe_mode/safe_zone checks, hit/miss, shield block, damage, criminal flag, death
- Combat packet encoders: char_swing, user_hitted_user/by_user, npc_hit_user, shield block, npc_kill_user, safe_mode_on/off
- 22 unit tests covering all combat formulas

**Remaining gaps:**
- Golden-value / VB6 compatibility verification
- More player-vs-player and player-vs-NPC integration tests for the death,
  inventory-drop, NPC gold-drop, XP-pool, pet, and party paths

**Goal:** Players can fight NPCs and other players with melee, ranged, and unarmed attacks.

**What to build:**
- Pure Elixir combat formula module: `Arena.Combat.Formulas`
- Attack processed immediately in MapServer when intent arrives:
  1. Check attacker cooldown, stamina, alive/not-paralyzed
  2. Resolve target at facing tile from entity position + occupancy
  3. Compute hit/miss, damage, defense — all data local in MapServer state
  4. Apply HP loss to defender entity, apply XP gain to attacker entity
  5. Send hit/block/damage/death packets to affected sessions directly
- Hit/miss calculation:
  ```
  attack_power = (skill + 3 * skill / 100 * agility) * class_mod + 2.5 * max(level - 12, 0)
  evasion = (tactics + 3 * tactics / 100 * agility) * class_mod + 2.5 * max(level - 12, 0)
  hit_chance = clamp(50 + (attack_power - evasion) * 0.4, 5, 95)
  ```
- Damage calculation:
  ```
  damage = (3 * weapon_dmg + max_weapon * 0.2 * max(0, strength - 15) + base_dmg) * class_mod
  ```
- Defense: random hit location (1/6 head → helmet, 5/6 body → armor + shield)
- Shield block: `clamp(shield_pct * defense_skill / (defense_skill + tactics), 10, 90)`
- NPC combat: same formulas, NPC stats from MapServer state
- Death: set dead flag, drop items to ground (if criminal), lose XP
- XP gain: `(damage_dealt * npc_xp) / npc_max_hp`, level delta penalty after 4 levels

**Differential fuzzing:**
- Generate golden test vectors by running the actual VB6 server with controlled TCP inputs
- Property tests with StreamData: random {skill, agility, level, class} tuples, verify invariants (hit_chance 5–95, damage ≥ 0, XP ≥ 0)
- Golden value tests: specific input/output pairs verified against VB6

**VB6 reference:** `SistemaCombate.bas`

**Lines estimate:** ~800 Elixir (formulas + MapServer handlers + fuzz tests)

**Depends on:** Phase 4 (equipped weapons affect damage calculations)

---

## Phase 6 — Spells

**Status:** `Done`

**In code now:**
- `Arena.Data.SpellDef` — full spell definition struct parsed from Hechizos.dat (293 spells)
- `GameData.get_spell/1` — ETS lookup for spell definitions
- MapServer `handle_call({:cast_spell, ...})` — cooldown, mana/stamina, target resolution
- Spell effects: damage (with magic resistance), heal (self/other), status (paralysis, poison, cure, invisibility)
- FX/WAV broadcast to nearby players via create_fx and play_wave packets
- Left-click target tracking in session state for spell targeting

**Remaining gaps:**
- Summon-spell / pet edge-case verification against VB6
- Spell verification against VB6 behavior

**Goal:** Players can cast offensive, healing, and buff/debuff spells.

**What to build:**
- Spell data: parse `resources/raw/Dat/Hechizos.dat` into ETS
- Cast spell processed immediately in MapServer:
  - Mana check → cooldown check → skill check → target resolution → apply effect
- Spell damage: `random(min, max) + 3% per level`, mages 0.7x modifier
- Magic resistance: `damage = damage - damage * (magic_resistance_pct / 100)`
- Healing spells: direct HP recovery on target entity
- Buff/debuff effects: paralyze, poison, invisibility, stat boosts — stored as entries in entity buff list with remaining duration, decremented by the periodic timer
- Resurrection: `cost = target_level * 1.5 + caster_hp * 0.45`
- Summoning: create pet NPC entity in MapServer state, bound to caster
- Mana recovery via meditation: regen calculated in periodic timer when entity has meditation flag

**Differential fuzzing:** golden vectors from VB6, property tests for spell_damage, magic_resistance, heal_amount

**VB6 reference:** `modHechizos.bas`

**Lines estimate:** ~600 Elixir

**Depends on:** Phase 5 (damage/healing framework)

---

## Phase 7 — NPC AI

**Status:** `Done`

**In code now:**
- `Arena.Data.NpcDef` — full NPC definition struct parsed from npcs.dat (1404 NPCs) with loot tables, spells, shop items
- `Arena.Entity.NpcEntity` — runtime NPC state struct (HP, position, target, cooldowns, respawn timer)
- `Arena.NpcAi` — pure tick function called every 500ms from MapServer
- NPC spawning in MapServer from CSM map data, with occupancy grid integration
- AI behaviors: hostile target acquisition (nearest player in 10-tile range), chase pathfinding, random walk (movement=2)
- NPC attacks: hit chance, damage with player defense, death handling
- Respawn system: dead NPCs respawn at spawn point after configurable interval
- NPC visibility: character_create packets sent to entering players
- Loot drops on NPC death (probabilistic from loot table)

**Remaining gaps:**
- Quest NPC interaction
- NPC aggro/targeting performance hardening
- NPC spell-casting and hostile-AI parity verification against VB6 traces

**Goal:** NPCs walk around, attack players, sell items, give quests.

**What to build:**
- NPC data: parse `resources/raw/Dat/npcs.dat` into ETS (stats, AI type, loot tables, hostility)
- NPC entities live in MapServer state: `%{npc_id => %NpcEntity{}}`
- AI ticked every 100ms via `Process.send_after(self(), :npc_ai_tick, 100)`:
  - Static: don't move (shopkeepers, quest givers)
  - Random walk: move randomly within home area
  - Hostile: detect players in 15×13 tile range, pathfind + attack
  - Follow master: pets follow owner
- NPC combat: same formula module as player combat, resolved immediately
- NPC death: drop loot to ground, grant XP to damagers, start respawn timer
- NPC respawn: countdown in entity state, re-spawn at original position when timer expires
- NPC interaction: session sends intent → MapServer validates adjacency → sends shop/dialogue/quest data to client

**VB6 reference:** `MODULO_NPCs.bas`, `AI_NPC.bas`

**Lines estimate:** ~700 Elixir

**Depends on:** Phase 5 (combat), Phase 4 (loot drops)

---

## Phase 8 — Commerce & Banking

**Status:** `Done`

**In code now:**
- Shopkeeper commerce on the live path: open / buy / sell / close, pricing formulas, and inventory mutations
- Bank: open / deposit / withdraw / bank gold — fully implemented in `bank.ex`
- Player-to-player trade: request / accept / offer items+gold / confirm / cancel — fully implemented in `trade.ex`
- Commerce protocol uses correct VB6 packet IDs (verified against VB6 source)

**Remaining gaps:**
- None blocking. Minor edge cases may surface during VB6 client testing.

**Goal:** Players can buy/sell from NPC shops and store items in bank.

**What to build:**
- Commerce processed immediately in MapServer:
  - Commerce start: validate player adjacent to shop NPC → send shop inventory to client
  - Buy: `price = ceil(item_value / (1 + trading_skill / 100) * quantity)`, deduct gold, add item to inventory
  - Sell: `price = item_value / 3` (workers: `3 - level * 0.025`, min 2), add gold, remove item
- Bank: lives in DB, loaded on demand during NPC interaction
  - Bank open (packet 54): session reads bank from DB, sends to client
  - Deposit: intent to MapServer → removes from entity inventory → session writes to bank table
  - Withdraw: session reads from bank → intent to MapServer → adds to entity inventory
  - Bank gold deposit/withdraw: similar flow
- Player-to-player trading: both players on same map → resolved atomically in MapServer

**Differential fuzzing:** golden vectors for shop_buy_price, shop_sell_price

**VB6 reference:** `Comercio.bas`, `ModShopAO20.bas`

**Lines estimate:** ~400 Elixir

**Depends on:** Phase 4 (inventory), Phase 7 (NPC interaction)

---

## Phase 9 — Crafting & Gathering

**Status:** `Mostly done`

**In code now:**
- Full crafting/gathering module in `crafting.ex` (~380 lines): mining, fishing, woodcutting, blacksmithing, carpentry, alchemy, tailoring
- Recipe data in `crafting_recipes.ex`: gathering products by skill tier (real obj.dat IDs), production recipes with ingredient requirements
- Tool validation: pickaxe, fishing rod, woodcutting axe, hammer, saw, sewing tools, alchemy pot — all real VB6 item IDs
- Resource detection: trigger map from CSM files (trigger 6 = mineral vein, trigger 7 = tree), water tiles for fishing
- NPC workstation proximity for production skills (forge, workbench, alchemy table, loom)
- Skill roll: `rand(1..100) <= skill_value`, skill-up chance on both success and failure
- Stamina cost (15 per work action), inventory management (add product, consume ingredients)
- Taming system: find nearby tameable hostile NPCs, skill check, set ownership, pet AI follow/attack
- Work packet routed through Social → Crafting fallthrough when no trainer NPC nearby

**Remaining gaps:**
- More production recipes (tailoring recipes not yet defined)

**Goal:** Players can mine, fish, craft items.

**What to build (remaining):**
- ~~Work/craft framework~~ — **Done.** Tool check, skill check, stamina cost, gathering, production, taming all in crafting.ex
- ~~Gathering skills (mining, fishing, woodcutting)~~ — **Done.** Trigger map + water tile detection, skill roll, product tiers
- ~~Production skills (blacksmithing, carpentry)~~ — **Done.** Ingredient consumption, workstation NPC proximity
- ~~Alchemy recipes~~ — **Done.** HP potion, mana potion, poison recipes added
- ~~Class modifier~~ — **Done.** Workers craft at 1x stamina, all others at 3x (`@non_worker_stamina_multiplier`)
- Expand tailoring recipes: hides → leather armor (framework exists, recipes not defined)

**VB6 reference:** `Trabajo.bas`

---

## Phase 10 — Social Systems

**Status:** `Done`

**In code now:**
- Online directory / presence lookup
- Local map chat on the live path, with word filter and rate limiting
- Whisper (cross-map via OnlineDirectory) and yell (extended broadcast range) — both in `social.ex`
- Parties: `PartyServer` GenServer + ETS — invite, accept, leave, kick, party XP split, max 5 members, `party_safe_toggle` for friendly-fire control
- Guilds: `GuildServer` GenServer + ETS with DB write-through — create, invite, accept, leave, kick, guild chat, same-guild checks. Ecto schemas for `guilds` + `guild_members` tables, load from DB on startup
- Factions: Royal Army / Chaos Legion — `faction` field on PlayerEntity, enlist/leave via `/ENLISTAR`/`/RENUNCIAR`, faction-gated map restrictions, same-faction PvP block, faction chat via `/FACCION`, faction_status in mini_stats
- Rest/meditate with FX broadcasts in `social.ex`
- NPC revive via `/RESUCITAR` command in `social.ex`
- Request skills / send_skills packet flow in `social.ex`

**Remaining gaps:**
- Guild levels/XP, metadata, alignment, wars, peace, alliances, aspirant/request flow, DB persistence, and guild tag display

**Goal:** Players can whisper, form parties, create guilds, enlist in factions.

**What to build (remaining):**
- ~~Whisper / yell~~ — **Done.**
- ~~Parties~~ — **Done.** PartyServer GenServer + ETS, invite/accept/leave/kick, party XP split, safe_toggle
- ~~Guilds base~~ — **Done.** GuildServer GenServer + ETS, create/invite/accept/leave/kick, guild chat
- ~~Guilds DB persistence~~ — **Done.** Ecto schema `guilds` + `guild_members` tables, load on startup, write-through on mutation
- ~~`party_safe_toggle` handler~~ — **Done.** Toggle friendly-fire within party, combat_handlers checks `party_safe?/2`
- ~~Factions~~ — **Done.** Enlist/leave, faction chat, map restrictions, PvP block
- ~~Guild tag in character display packets~~ — **Done.** `clan_index` and `clan_nivel` are populated from GuildServer.
- ~~Guild levels / XP / metadata~~ — **Done.**
- ~~Guild alignment~~ — **Done.** VB6 `e_ALINEACION_GUILD` parity.
- ~~Guild wars / peace / alliances~~ — **Done.**
- ~~Guild aspirant / request system~~ — **Done.**
- Optional product work: leader elections / democratic succession, if required by the target shard.
- Factions: add `faction` field to PlayerEntity, Royal Army / Chaos Legion enlist flow, faction-gated areas, faction chat

**VB6 reference:** `Modulo_UsUaRiOs.bas`, `modGuilds.bas`

---

## Phase 11 — Progression

**Status:** `Mostly done`

**In code now:**
- Persisted `level`, `xp`, and `skill_points`
- Race/class stat tables and initial stat computation
- XP gain on NPC kill (melee + spell), with level-difference penalty
- Level-up with recursive multi-level support: HP growth, mana growth, stamina growth, skill points, base damage update, heal to full
- Skill training: direct skill-point spend via Work packet (skill_index → skill atom, increment by 1, send_skills packet)
- Trainer NPC gating: proximity check for npc_type 3 (entrenador) — skills only trainable near a trainer NPC
- Crafting skill fallthrough: Work packet for crafting skills (mining, fishing, etc.) routes to Crafting module when no trainer nearby
- `update_user_stats` / `update_exp` / `send_skills` packets sent on level-up and skill change
- Stat display: `handle_request_atributes`, `handle_request_mini_stats` handlers in social.ex

**Remaining gaps:**
- Skill training cap enforcement per trainer type (some trainers only teach specific skill groups)

**Goal:** Characters level up, gain stats, train skills.

**What to build (remaining):**
- ~~Level up with stat growth~~ — **Done.** HP/mana/stamina growth, skill points, base damage, heal to full, recursive multi-level
- ~~Skill training via Work packet~~ — **Done.** Trainer NPC proximity + gold cost + skill increment
- ~~Stat display packets~~ — **Done.** request_atributes (send_atributes ID 81), request_mini_stats
- Trainer skill-group restrictions: some trainers only teach specific skill groups in VB6

**VB6 reference:** `Modulo_UsUaRiOs.bas:CheckUserLevel()`

---

## Phase 12 — World Rules & Polish

**Status:** `Done`

**In code now:**
- Safe zones: `safe_zone` flag from .csm, enforced in PvP attack path (with faction exception)
- Criminal flag: set on attacking innocent players in combat_handlers.ex
- Rest/meditate: toggle via chat commands, HP/mana regen in regen_tick, FX broadcast to nearby players
- Hunger/thirst drain: VB6-parity interval counters (every 10th regen tick), stamina pressure at 0 hunger/thirst, HP damage only when stamina depleted, starvation can kill
- Food/drink items restore hunger/thirst with `update_hunger_and_thirst` packets
- Pets/taming: taming in crafting.ex, pet AI in npc_ai.ex (follow owner, attack nearby hostiles, despawn on owner disconnect), `owner_id` on NpcEntity, `pet_ids` on PlayerEntity
- GM commands: 13 commands in social.ex — `/TELEPORT`, `/SPAWNITEM`, `/INVISIBLE`, `/GOTO`, `/INFO`, `/KILL`, `/KICK`, `/BAN`, `/MUTE`, `/UNMUTE`, `/JAIL`, `/SPAWNNPC`, `/LOCATE`. GM flag gating on chat intercept
- Weather: `rain_toggle` packet sent on map enter and transfer from `state.meta.rain/snow` flags. Client renders rain particles
- Dead-state guards: bank, commerce, inventory, movement, trade all reject actions when dead
- Spell requirements: `work_on_dead` check on target, `staff_afecta` weapon type requirement

**Remaining gaps:**
- Weather: snow rendering on client (rain done)

**Goal:** Zone enforcement, GM tools, remaining features.

**What to build (remaining):**
- ~~Safe zones~~ — **Done.**
- ~~Criminal system~~ — **Done.**
- ~~Rest/meditate~~ — **Done.**
- ~~Hunger/thirst drain~~ — **Done.** VB6-style interval counters + stamina
  pressure before HP damage.
- ~~Pets/taming~~ — **Done.** Taming skill, pet AI follow/attack/despawn, owner_id/pet_ids fields
- ~~GM commands~~ — **Done.** 13 commands: teleport, spawn item, invisible, goto, info, kill, kick, ban, mute, unmute, jail, spawn NPC, locate
- ~~Weather server-side~~ — **Done.** rain_toggle on enter/transfer. Client renders rain particles
- ~~Dead-state guards~~ — **Done.** bank, commerce, inventory, movement, trade
- ~~Jail system~~ — **Done.** GM command `/JAIL name`
- ~~Additional GM commands~~ — **Done.** `/KICK`, `/BAN`, `/MUTE`, `/UNMUTE`, `/SPAWNNPC`, `/LOCATE`
- ~~Weather client rendering~~ — **Done.** Rain particles. Snow rendering remaining.
- ~~Hunger/thirst VB6 parity~~ — **Done.** Interval counters + stamina pressure model

**Depends on:** All previous phases

---

## Phase 13 — Auth & Account System

**Status:** `Done`

**In code now:**
- `accounts` table with username (unique, case-insensitive) and bcrypt password hash
- `GameBackend.Account` schema: `create/2`, `get_by_username/1`, `verify_password/2`, `get_or_create/2`
- Characters have `belongs_to :account` integer FK (migrated from string account_id)
- Packet 74 login creates account if new, verifies password if existing
- Packet 73 login validates session token
- Integration tests for wrong password and invalid session token

**Remaining gaps:**
- Rate limiting on auth endpoints
- Account-level bans

**Goal:** Players have real accounts with password protection. The web client uses a login form; the VB6 client uses the existing packet flow.

**Scope note:** This phase is intentionally compatibility-preserving. It covers
account ownership and password auth on the existing AO packet path. The richer
web-first account lobby flow is tracked separately below because it is not
required for VB6 parity.

**What to build:**
- Ecto schema: `accounts` table (username, password_hash, email, banned_until, created_at)
- Registration: validate username uniqueness + password strength, hash with `Bcrypt`
- Login: verify password → return account_id → existing character selection / creation flow
- Web auth: REST endpoint or initial WebSocket handshake that authenticates before the AO20 session begins
- Rate limiting: max 5 failed login attempts per IP per minute
- Account ban: GM command to set `banned_until`, checked on login
- Character ownership: characters belong to accounts, enforce on login

**Lines estimate:** ~400 Elixir

**Depends on:** None (can be built at any time)

---

## Post-Compatibility — Web Account Auth & Character Lobby

**Status:** `Missing`

**This is not part of VB6 parity.** It is a web-first account layer to add
after the Compatibility Gate is closed, so the browser can use modern account
auth without changing the traditional AO gameplay socket flow.

**Goal:** Browser users authenticate at the account level with either
username/password or Google, choose or create a character, and only then enter
the world through the unchanged `login_existing_char(char_id, session_token)`
path.

**Target flow:**
1. Browser authenticates account via HTTP API
2. Backend creates or loads the account session
3. Browser loads account info plus owned characters
4. Browser creates or selects a character
5. Backend issues or rotates a per-character session token
6. Browser opens the AO socket and sends `login_existing_char`

**What to build:**
- Account auth API on the web path:
  - `POST /api/auth/login` for username/password
  - `POST /api/auth/google` for Google ID token or OAuth callback result
  - `GET /api/auth/session`
  - `POST /api/auth/logout`
- Character lobby API:
  - `GET /api/characters`
  - `POST /api/characters`
  - `POST /api/characters/:id/session`
- Account model support for:
  - password-only accounts
  - Google-only accounts
  - linked accounts that can use either method
- Character ownership checks before issuing gameplay session tokens
- Browser lobby UI for:
  - sign in
  - sign out
  - list characters
  - create character
  - select character and enter world

**Important constraints:**
- Keep the auth API on the same origin as the web client, or proxy it there.
  Do not create unnecessary CORS/cookie/session complexity between `:7667` and
  `:4000`.
- Keep account auth separate from AO packet login. The browser should stop
  using `login_new_char` as its primary account-login mechanism.
- Reuse the existing gameplay socket auth path instead of inventing a second
  in-world login protocol.

**Lines estimate:** ~300-700 backend + ~300-700 frontend

**Depends on:** Compatibility Gate, Phase 13

---

## Phase 14 — Anti-Cheat & Server Hardening

**Status:** `Done`

**In code now:**
- Flood guard: token bucket rate limiter per session (flood_guard.ex)
- Speed hack detection: soft accumulator + position snap-back in movement.ex, structured `[ANTICHEAT]` logging
- Teleport prevention: movement is strictly directional via `TileGrid.move_entity`, non-adjacent jumps fail validation
- Cooldown fields on PlayerEntity for all timed actions (move, attack, spell, item use)
- Range validation on melee attacks (adjacent tile via `facing_tile`), ranged attacks (Chebyshev distance 18), and spell casts (AoI range)
- Damage is fully server-authoritative (client values never trusted)
- Dead-state guards on all handler entry points: bank, commerce, inventory, movement, trade reject actions when entity.dead is true
- Structured audit logging: `Arena.AuditLog` with `[AUDIT]` prefixed entries for login/logout/trade/kill/GM actions
- Spell requirement enforcement: `work_on_dead` check, `staff_afecta` weapon type check

**Goal:** The server rejects or corrects cheating attempts without false positives on legitimate play.

**What to build (remaining):**
- ~~Speed hack~~ — **Done.**
- ~~Teleport detection~~ — **Done.**
- ~~Range validation~~ — **Done.**
- ~~Damage sanity~~ — **Done.**
- ~~Dead-state guards~~ — **Done.** All handler entry points reject actions when dead
- ~~Structured anti-cheat logging~~ — **Done.** `[ANTICHEAT]` prefixed structured logging for speed hacks, `[AUDIT]` logging for all significant actions
- Out-of-sequence packet validation: reject trade packets when not in trade session, commerce packets without open shop, etc.

**Depends on:** Phase 5 (combat range checks), Phase 1 (movement validation)

---

## Phase 15 — Operations & Infrastructure

**Status:** `Mostly done`

**In code now:**
- Basic Telemetry metrics
- Health check endpoint
- Nix-based dev environment
- Graceful shutdown: `terminate/2` callback in MapServer saves all player entities via session autosave path, `shutdown: 15_000` on child_spec
- Structured audit logging: `Arena.AuditLog` module with `[AUDIT]` prefixed entries for login, logout, trade, kills, GM actions

**Remaining gaps:**
- Monitoring/alerting dashboards
- Deployment pipeline
- Asset delivery

**Goal:** The server can be deployed, monitored, and operated in production.

**What to build:**
- ~~Graceful shutdown~~ — **Done.** terminate/2 autosave, shutdown: 15_000
- ~~Structured logging~~ — **Done.** `Arena.AuditLog` with `[AUDIT]` prefix
- Monitoring: Prometheus metrics via `TelemetryMetricsPrometheus` — player count, map count, mailbox depth, request latency
- Deployment: Dockerfile, `mix release`, CI pipeline for build + test + release
- TLS: HTTPS for web client, WSS for WebSocket transport
- Asset CDN: serve `resources/` (sprites, indices, sounds) from a CDN, not the game server
- Database: automated backups, connection pool tuning
- Config: runtime-tunable settings (intervals, rates, formula constants) via config or ETS without recompile

**Lines estimate:** ~400 Elixir + infrastructure config

**Depends on:** None (can be built incrementally alongside other phases)

---

## Phase 16 — Chat Moderation

**Status:** `Done`

**In code now:**
- Word filter: `Arena.ChatFilter` replaces blocked words with asterisks, Spanish profanity list
- Mute system: `muted_until` field on PlayerEntity, GM `/MUTE name minutes` and `/UNMUTE name` commands, mute enforcement in chat handler
- Chat rate limiting: 1-second cooldown per player (`last_chat_at` field), separate from packet flood guard
- `/BAN name` and `/KICK name` GM commands for session/account-level enforcement
- All chat paths (local, whisper, yell, guild, faction) pass through filter + mute check

**Remaining gaps:**
- Report system (player → DB log for GM review)
- Account-level ban persistence (`banned_until` field in accounts table, checked on login)

**Goal:** Chat is moderated to prevent abuse.

**What to build:**
- Word filter: configurable blocklist loaded from file/config, applied server-side before broadcast. Replace or reject messages containing filtered words
- Mute: GM command `/MUTE name minutes` → set `muted_until` on entity, check before all chat/yell/whisper. Persist across sessions via DB
- Ban: GM command `/BAN name days` → set `banned_until` on account, reject login
- Report: client report command → insert into `reports` table with reporter, target, message, timestamp
- Chat rate limiting: per-player message rate cap (e.g., 5 messages/10s), separate from packet flood guard. Warn then temp-mute

**Lines estimate:** ~200 Elixir

**Depends on:** Phase 10 (social/chat infrastructure), Phase 13 (accounts for ban)

---

## Phase 17 — Scalability & Performance Hardening

**Status:** `Partially done`

**In code now:**
- NPC broadcasts use AoI grid (`broadcast_visible_all`) instead of sending to all sessions
- Player visibility uses spatial grid with `:aoi_grid` / `:aoi_scan` / `:global` modes

**Remaining gaps:**

1. **NPC aggro uses O(NPCs × players) scan** — `find_nearest_player` in `npc_ai.ex` scans all players for each hostile NPC every 500ms. Should query the spatial grid instead.
2. **Pet targeting is O(pets × NPCs)** — `find_nearest_wild_npc` scans all NPCs per pet. Fine now, scales poorly with many pets/summons.
3. **Load-test gate** — No automated soak test. Need a "100 players + NPCs" scenario tracking tick latency, mailbox size, packets/sec, CPU.
4. **Batch persistence** — Autosave, logout, bank, guild writes are scattered individual DB calls. Should go through a dedicated write queue for batching.
5. **Pre-resolve .dat references** — NPC spells, loot, item visuals, shop lists, recipes do repeated ID lookups during gameplay. Should be resolved once at load time into ready-to-use defs.
6. **Packet backpressure** — No per-session outbound queue limits. A lagging client can grow process memory unbounded.
7. **Map hot-spot telemetry** — Per MapServer metrics: player count, NPC count, tick duration, mailbox length, movement cmds/sec, broadcasts/sec.
8. **Interest management for ground items/NPCs** — NPCs and ground items should use the same create/remove boundary model as players, not broadcast broadly on every map enter.
9. **Admin/runtime tools** — Web admin or CLI for: player count per map, process health, kick/teleport, inspect mailbox, force save, restart map cleanly.

**Goal:** The server can sustain 100+ concurrent players per map with stable tick latency and bounded memory.

**Priority order:** NPC aggro grid → load-test gate → batch persistence → backpressure → telemetry → the rest.

**Lines estimate:** ~600 Elixir

**Depends on:** Phase 15 (telemetry/monitoring foundation). Should be done after VB6 parity gate.

---

## Cross-Cutting: Client ↔ Server Dependencies

Each server phase unlocks corresponding client work. Neither roadmap should be read in isolation.

| Server Phase | Client Phase | What the client needs from the server |
|---|---|---|
| Phase 5 — Combat | Client Phase 3 — Combat Feedback | Attack packets, damage/death/XP packets, HP update packets |
| Phase 6 — Spells | Client Phase 4 — Spell UI | Cast packets, buff/debuff packets, spell list packet |
| Phase 7 — NPC AI | Client Phase 5 — NPC Interaction | NPC interaction packets, shop data packets, quest data packets |
| Phase 8 — Commerce | Client Phase 6 — Commerce & Bank | Shop buy/sell packets, bank open/deposit/withdraw packets, trade packets |
| Phase 9 — Crafting | Client Phase 7 — Crafting | Craft result packets, skill gain packets |
| Phase 10 — Social | Client Phase 8 — Social | Whisper/yell packets, party packets, guild packets |
| Phase 11 — Progression | Client Phase 9 — Stats | Level-up packets, stat display packets, skill training packets |
| Phase 12 — World Rules | Client Phase 10 — Polish | Weather data on map enter, safe zone flag, criminal flag |
| Phase 13 — Auth | Client Foundation — Login screen | Auth endpoint/packet, account creation endpoint |
| Post-Compatibility — Web Account Auth & Character Lobby | Client Foundation — Account lobby | Account session API, character list/create/select, Google sign-in, per-character token issue |
| Phase 15 — Operations | Client Foundation — Asset delivery | CDN URL for assets, TLS for WebSocket |

---

## Phase Verification & Definition of Done

A phase is not complete just because the code exists. It is complete when the behavior is verified at the right level.

### Definition of done for every phase

- Pure logic and parser code has deterministic tests for the new formulas/rules
- Real process integration tests exercise the feature through MapServer/session boundaries
- AO20 packet compatibility still passes for any packets touched by the phase
- A real client smoke test succeeds for the new player-facing flow
- If the phase touches a hot path, the benchmark baseline does not regress

### Verification by phase

- **Phase 1 — Runtime & Performance Foundations**
  - Verify movement, visibility lifecycle, AoI boundary crossing, and position sync with real integration tests
  - Benchmark `:global`, `:aoi_scan`, and `:aoi_grid` under the same scenarios and store the results in-repo
  - Manual smoke: real client/web client can log in, walk, chat, and stay synchronized

- **Phase 2 — Character System, Persistence & Map Transitions**
  - Insert real character rows in DB, log in, assert the entity is loaded with correct persisted state
  - Verify autosave, logout save, reconnect, and map transfer with real session + MapServer processes
  - Manual smoke: create a character, relog, and walk through a map exit into another map

- **Phase 2A — Transition Quality & Client Map Pack**
  - Verify packed map bundle decode and cache correctness against the same source map data used by the server
  - Repeated transition smoke: move back and forth across exits and assert no black frame, no flash, and no local move-then-correction artifact
  - Manual smoke: serious web client transitions should feel at least as stable as `test_client.html`

- **Phase 3 — Durable State & Persistence Shape**
  - Round-trip load/save tests across normalized associations
  - Relog tests that prove entity state is equivalent before and after persistence
  - Migration tests for inventory/equipment/schema refactors

- **Phase 4 — Inventory**
  - Real MapServer tests for pickup, drop, equip, unequip, stacking, gold handling, and consumable use
  - Assert ground items and inventory state change atomically in the same server process
  - Manual smoke: pick up loot, equip an item, use a potion, and relog to confirm persistence

- **Phase 5 — Combat**
  - Golden-value tests for hit, damage, defense, XP, and death behavior verified against VB6 references
  - Property tests for invariants like hit chance bounds, non-negative damage, and non-negative XP
  - Real combat integration tests for player-vs-player and player-vs-NPC flows
  - Manual smoke: attack, miss, block, damage, die, and gain XP through the client

- **Phase 6 — Spells**
  - Golden-value tests for spell damage, healing, resistance, and cost/cooldown behavior
  - Integration tests for target resolution, mana consumption, buffs, debuffs, summons, and resurrection
  - Manual smoke: cast offensive, healing, and utility spells and confirm visible client effects

- **Phase 7 — NPC AI**
  - AI tests that place NPCs and players on a real map and tick behavior forward
  - Verify aggro, patrol/random walk, combat, death, loot, and respawn
  - Manual smoke: watch hostile NPCs react, shopkeepers stay stable, and quest/shop interactions work

- **Phase 8 — Commerce & Banking**
  - Integration tests for buy, sell, deposit, withdraw, bank gold, and player-to-player trade
  - Verify inventory/gold consistency across both live entity state and DB-backed bank state
  - Manual smoke: buy from a shop, sell an item, bank it, withdraw it, and relog

- **Phase 9 — Crafting & Gathering**
  - Integration tests for tile/tool checks, stamina costs, skill checks, material consumption, and produced items
  - Golden-value or fixture tests for recipe outputs and success rates where needed
  - Manual smoke: mine, fish, cut wood, and craft a real item end-to-end

- **Phase 10 — Social Systems**
  - Multi-session tests for whisper, yell, party invite/leave, guild membership, and guild chat
  - Verify cross-map lookups and persistence for guild/faction state
  - Manual smoke: whisper another player, form a party, and use guild/social channels

- **Phase 11 — Progression**
  - Pure formula tests for XP thresholds, HP/mana gains, and skill point rules
  - Integration tests for leveling, skill training, trainer interactions, and stat packet refresh
  - Manual smoke: gain XP, level up, spend skill points, and confirm updated stats in the client

- **Phase 12 — World Rules & Polish**
  - Integration tests for safe zones, criminal flagging, jail transfer, rest/meditation, hunger/thirst, pets, and GM actions
  - Verify rule enforcement server-side, not just client-side display
  - Manual smoke: attempt blocked PvP in safe zones, trigger criminal behavior, use GM/admin flows, and confirm world-state polish features

---

## Testing Strategy

**No mocks.** All tests use real processes with real state. The only external dependency is PostgreSQL (Ecto sandbox).

For the current linear test gate, start with `ROADMAP.md` and the detailed
automation design in `research/parity-automation-plan.md`. The sections below
are the backend test categories; do not read them as optional future work.

### Unit tests — pure functions

- `Arena.Combat.Formulas` — hit chance, damage, defense, XP gain
- `Arena.Formulas` — XP thresholds, level up HP/mana gains, shop prices, crafting success
- `Arena.Map.CsmParser` — parse known .csm files, assert tile counts and metadata
- Packet encode/decode — round-trip tests for every packet type

### MapServer integration tests

Start a real MapServer with a real map, exercise gameplay through the public API:

- `MapServer.enter/3` → assert entity in state, occupancy grid updated
- Send move intent → assert position changed, occupancy updated, old tile cleared
- Send attack intent → assert target HP decreased, attacker XP increased
- Send pickup intent → assert item in inventory, removed from ground items
- Map transfer: enter map 1 → walk to exit tile → assert entity exported from map 1, imported on map 2
- Cooldown rejection: send two moves faster than `min_interval` → assert second rejected
- Speed hack accumulator: flood moves → assert position snapped back after threshold
- Safe zone: attack player on safe map → assert attack rejected
- Death: kill entity → assert dead flag, items dropped (if criminal), XP lost

### Lifecycle tests

- Login: insert character in DB → login → assert entity loaded into MapServer with correct state
- Logout: entity on map → disconnect → assert entity saved to DB, removed from MapServer
- Autosave: entity on map → wait for snapshot interval → assert DB updated
- Crash recovery: kill MapServer → restart → players reconnect → assert state from last snapshot

### NPC AI tests

- Place hostile NPC + player within 15×13 vision range → tick AI → assert NPC moved toward player
- Place hostile NPC + player out of range → tick AI → assert NPC does random walk or stays
- Kill NPC → assert respawn timer started → tick until expired → assert NPC respawned at home position
- Shopkeeper NPC → send interact intent → assert shop data returned, NPC didn't move

### Test organization

```
test/
├── arena/
│   ├── combat/
│   │   ├── formulas_test.exs      # unit: pure formula tests
│   │   └── combat_integration_test.exs  # MapServer combat flow
│   ├── map/
│   │   ├── map_server_test.exs    # enter/leave/move/transfer
│   │   └── csm_parser_test.exs
│   ├── inventory_test.exs
│   ├── npc_ai_test.exs
│   └── lifecycle_test.exs         # login/logout/autosave/crash
├── ao_tcp_gateway/
│   └── packet_test.exs            # encode/decode round-trips
└── fuzz/                           # differential fuzzing (see below)
```

---

## Differential Fuzzing Strategy

Run continuously as part of the parity gate to verify formula and behavior
correctness.

### Oracle: golden values from VB6, not a Python reimplementation

A Python reimplementation would just be another place to get the math wrong. Instead:

**Option A (preferred):** Run the actual VB6 server, send controlled inputs via TCP, capture outputs. This gives authoritative golden values including VB6-specific integer truncation and rounding.

**Option B (fallback):** Hand-trace VB6 code for ~50 specific input/output pairs per formula, verified by two people. Store as `test/fixtures/combat_golden.json`, `test/fixtures/commerce_golden.json`, etc.

### Test types

1. **Golden value tests:** exact input → expected output, verified against VB6
2. **Property tests (StreamData):** random inputs, verify invariants:
   - `hit_chance` always in 5..95
   - `damage` never negative
   - `xp_gain` never negative
   - `defense` never exceeds raw damage
   - `shop_sell_price` always ≤ `shop_buy_price`
3. **Boundary tests:** edge cases (level 1, level 50, skill 0, skill 100, str 1, str 50)

### Formulas to test

| Formula | Inputs | Invariants |
|---------|--------|------------|
| `attack_power` | skill, agility, level, class_mod | ≥ 0, monotonic in skill/agi/level |
| `hit_chance` | attack_power, evasion | 5 ≤ result ≤ 95 |
| `melee_damage` | weapon_min/max, strength, base_min/max, class_mod | ≥ 0 |
| `defense` | armor_min/max, shield_min/max, helmet_min/max, location | ≥ 0 |
| `shield_block` | shield_pct, defense_skill, tactics | 10 ≤ result ≤ 90 |
| `xp_gain` | damage, npc_xp, npc_hp, level_delta | ≥ 0 |
| `spell_damage` | min, max, level, class, magic_resist | ≥ 0 |
| `shop_buy_price` | value, trading_skill, quantity | ≥ value (no discount below base) |
| `shop_sell_price` | value, class, level | ≤ value |

### Running
```
mix test test/fuzz/ --seed 0      # reproducible
mix test test/fuzz/ --seed rand   # explore new inputs
```

---

## Timeline Summary

| Phase | System | Lines | Cumulative |
|-------|--------|-------|------------|
| Done | Networking, maps, movement, chat, AoI, benchmarks | 5,245 | 5,245 |
| 2 (remaining) | Auth cleanup, transition/login test stabilization | 200 | 5,445 |
| 2A (remaining) | Prepacked map bundles, transition polish | 200 | 5,645 |
| 3 (remaining) | Normalize skills, spells, bank_items tables | 300 | 5,945 |
| 4 (remaining) | Equip restrictions, stat recomputation, edge cases | 200 | 6,145 |
| 5 | Combat + fuzz tests | 800 | 6,945 |
| 6 | Spells | 600 | 7,545 |
| 7 | NPC AI | 700 | 8,245 |
| 8 | Commerce & banking | 400 | 8,645 |
| 9 | Crafting & gathering | 400 | 9,045 |
| 10 | Social (parties, guilds) | 500 | 9,545 |
| 11 | Progression (leveling, skills) | 300 | 9,845 |
| 12 | World rules & polish | 500 | 10,345 |
| 13 | Auth & account system | 400 | 10,745 |
| 14 | Anti-cheat & server hardening | 300 | 11,045 |
| 15 | Operations & infrastructure | 400 | 11,445 |
| 16 | Chat moderation | 150 | 11,595 |

**~11,600 lines of Elixir (+ 295 lines existing Rust NIF for tile collision) replacing ~93,000 lines of VB6 — an 8× reduction.**

Rust is kept narrow: tile collision grid only. All gameplay logic, entity state, combat formulas, inventory, AI, and persistence are pure Elixir. One language, one debugger, one process per map owning all state.
