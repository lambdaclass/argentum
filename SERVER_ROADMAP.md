# Argentum Online: VB6 → Elixir Migration Roadmap

## Current State

**Status legend:**
- `Done` — implemented on the live path and good enough to treat as complete for roadmap sequencing
- `Mostly done` — core feature works, but important roadmap details or cleanup remain
- `Partially done` — groundwork exists, but the phase is not closeable yet
- `Missing` — not implemented on the live gameplay path yet

**Current phase snapshot:**
- `Compatibility Gate — AO20 / VB6 Protocol & Behavior Parity`: `Partially done`
- `Phase 1 — Runtime & Performance Foundations`: `Done`
- `Phase 2 — Character System, Persistence & Map Transitions`: `Done`
- `Phase 2A — Transition Quality & Client Map Pack`: `Done`
- `Phase 3 — Durable State & Persistence Shape`: `Done`
- `Phase 4 — Inventory`: `Done`
- `Phase 5 — Combat`: `Done`
- `Phase 6 — Spells`: `Done`
- `Phase 7 — NPC AI`: `Done`
- `Phase 8 — Commerce & Banking`: `Done`
- `Phase 9 — Crafting & Gathering`: `Missing`
- `Phase 10 — Social Systems`: `Partially done`
- `Phase 11 — Progression`: `Partially done`
- `Phase 12 — World Rules & Polish`: `Partially done`
- `Phase 13 — Auth & Account System`: `Done`
- `Phase 14 — Anti-Cheat & Server Hardening`: `Partially done`
- `Phase 15 — Operations & Infrastructure`: `Partially done`
- `Phase 16 — Chat Moderation`: `Missing`

**Implemented so far (~6.8k lines of Elixir + 295 lines Rust):**
- TCP + WebSocket networking with AO20 protocol support for the currently used gameplay subset; exact VB6 wire parity is not fully closed yet
- Authoritative `MapServer` with movement, chat, heading, map transitions, autosave, and direct session delivery
- AoI visibility lifecycle, `:global` / `:aoi_scan` / `:aoi_grid`, spatial grid, pre-encoded hot-path broadcasts
- Character creation, login, persistence, online directory, static `.dat` loading
- Inventory groundwork and most live inventory flows: pickup, drop, equip toggle, item use, ground items
- Full melee combat (PvP + PvNPC): hit/miss, damage, defense, shield block, XP/gold/loot, death/respawn
- Spell system: damage, heal, status effects (paralysis, poison, cure, invisibility), mana/stamina costs
- NPC AI: hostile targeting, pathfinding, attack, random walk, respawning, loot drops
- Full `.dat` loading: items, spells (Hechizos.dat), NPCs (npcs.dat), class combat modifiers (Balance.dat)
- Benchmark harness, benchmark maps, metrics, CI/release workflows, web test client

**Important roadmap/code divergence to keep in mind:**
- Phase 8 (Commerce & Banking) is now complete: shopkeeper commerce, bank, and player-to-player trade all exist on the live path
- Phases 10-14 are partially done with specific remaining gaps documented in each section
- Phase 9 (Crafting & Gathering) and Guilds are the two largest unstarted systems
- The live protocol module covers all 37 client→server and 52 server→client packet IDs, but some decoded packets still lack game logic handlers
- The top-level phase statuses below are the source of truth

**VB6 server:** ~93,000 lines across 50+ modules
**Estimated final Elixir server:** ~10,000–12,000 lines

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
- Remaining: a few client→server packets are decoded but have no game logic handler yet (request_atributes, mini_stats, double_click, online, use_spell_macro). Most previously unhandled packets (yell, whisper, rest, meditate, heal, resucitate, request_skills, bank ops, work, party_safe_toggle) now have handlers.

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
- Remaining open items:
  - interval clamps that may still differ from raw VB6 data-driven timing
  - ongoing invisibility / AI / spell-selection edge-case review
  - trainer NPC gating for skill training (currently direct skill-point spend only)

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
- Ranged attacks (bows/arrows)
- Player-vs-player and player-vs-NPC integration tests
- Golden-value / VB6 compatibility verification

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
- Buff/debuff duration timers (paralysis/poison wear off)
- Summon spells (invoca)
- Resurrection spells
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
- Shopkeeper interaction (comercia + shop_items parsed but unused)
- Quest NPC interaction
- NPC spell casting (lanza_spells + spells parsed but unused)

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

**Status:** `Missing`

**In code now:**
- Item definitions and map/object data provide some of the static groundwork

**Remaining gaps:**
- Gathering rules by tile/object/tool
- Crafting recipes and validation
- Skill/stamina costs
- Result item creation and progression hooks

**Goal:** Players can mine, fish, craft items.

**What to build:**
- Work/craft handled immediately in MapServer:
  - Check equipped tool, check skill, consume stamina
  - Gathering: mining at trigger tiles, fishing at water tiles, woodcutting at tree objects → skill check → add result to inventory
  - Crafting: validate materials in inventory → consume → produce item
- Gathering skills:
  - Mining: ore at resource spots, skill check, stamina cost
  - Fishing: water tiles (flag 0x20), skill check
  - Woodcutting: tree objects, get wood logs
- Crafting skills:
  - Blacksmithing: ore + coal → weapons/armor at forge
  - Carpentry: wood → bows/furniture at workbench
  - Alchemy: herbs + bottles → potions
  - Tailoring: hides → leather armor
- Recipe data in ETS (material requirements from obj.dat)
- Class modifier: Workers craft at 1x speed, all others at 3x time
- Skill gain on success

**Differential fuzzing:** golden vectors for craft_success rates

**VB6 reference:** `Trabajo.bas`

**Lines estimate:** ~400 Elixir

**Depends on:** Phase 4 (inventory), Phase 7 (resource nodes)

---

## Phase 10 — Social Systems

**Status:** `Partially done`

**In code now:**
- Online directory / presence lookup
- Local map chat on the live path
- Whisper (cross-map via OnlineDirectory) and yell (extended broadcast range) — both in `social.ex`
- Parties: `PartyServer` GenServer + ETS — invite, accept, leave, kick, party XP split, max 5 members
- Rest/meditate with FX broadcasts in `social.ex`
- NPC revive via `/RESUCITAR` command in `social.ex`
- Request skills / send_skills packet flow in `social.ex`

**Remaining gaps:**
- Guilds: entirely unstarted — DB-backed, cross-map, significant feature (~500 lines). VB6: create, join, leave, kick, elect leader, guild chat, guild wars, alliances
- Factions: Royal Army vs Chaos Legion enlist, faction-specific chat (minimal code exists for faction PvP exception in combat)

**Goal:** Players can whisper, form parties, create guilds.

**What to build:**
- Whisper (packet 77): session resolves target by normalized character name via `OnlineLookup`, sends message directly (no map involvement)
- Yell (packet 76): intent to MapServer, broadcast to wider tile range
- Parties:
  - Invite, accept, kick, leave — managed by a lightweight `PartyServer` GenServer
  - Shared XP: when MapServer awards XP, checks party membership and splits
  - Party membership tracked in MapServer entity state
- Guilds:
  - Ecto schema: `guilds` table (name, leader, description), `guild_members` table
  - Create guild, join, leave, kick, elect leader — DB operations via session process
  - Guild chat via PubSub topic `guild:#{guild_id}`
  - Guild wars, alliances, peace offers
  - Guild tag stored as display metadata in MapServer
- Factions: Royal Army vs Chaos Legion, enlist, faction-specific chat channels

**VB6 reference:** `Modulo_UsUaRiOs.bas`, `modGuilds.bas`

**Lines estimate:** ~500 Elixir

**Depends on:** Phase 2 (persistence for guilds)

---

## Phase 11 — Progression

**Status:** `Partially done`

**In code now:**
- Persisted `level`, `xp`, and `skill_points`
- Race/class stat tables and initial stat computation
- XP gain on NPC kill (melee + spell), with level-difference penalty
- Level-up with recursive multi-level support: HP growth, mana growth, stamina growth, skill points, base damage update, heal to full
- Skill training: direct skill-point spend via Work packet (skill_index → skill atom, increment by 1, send_skills packet)
- `update_user_stats` / `update_exp` packets sent on level-up

**Remaining gaps:**
- Trainer NPC flow: VB6 has trainer NPCs that gate skill training behind gold cost + proximity to specific NPC types. Currently skill training is free direct spend.
- Stat display packets (request_atributes/mini_stats) — decoded but no handler

**Goal:** Characters level up, gain stats, train skills.

**What to build:**
- Level up checked in MapServer after each XP award: `if xp >= xp_required(level)` → level up
- On level up:
  - HP gain: random biased within class/race range, capped ±10 from average
  - Mana: `intelligence * class_mana_mult + (class_mult_mana * intelligence) * (level - 1)`
  - Skill points: `class.skill_points_per_level`
  - Newbie status removed at threshold level
  - Send level up packets to client
- Skill training: client sends train_skill intent → MapServer applies if skill points available, capped at 100
- NPC trainers: interact with trainer NPC → deduct gold, increase skill (interact from Phase 7)
- Stat display: send full stats to client on request (packets 85, 86, 87)
- Pure Elixir `Arena.Formulas.xp_required/1`, `Arena.Formulas.hp_gain/3` for testing

**VB6 reference:** `Modulo_UsUaRiOs.bas:CheckUserLevel()`

**Lines estimate:** ~300 Elixir

**Depends on:** Phase 5 (XP from combat)

---

## Phase 12 — World Rules & Polish

**Status:** `Partially done`

**In code now:**
- Safe zones: `safe_zone` flag from .csm, enforced in PvP attack path (with faction exception)
- Criminal flag: set on attacking innocent players in combat_handlers.ex
- Rest/meditate: toggle via chat commands, HP/mana regen in regen_tick, FX broadcast to nearby players
- Hunger/thirst drain: -1 per regen tick (3s), starvation/dehydration damage at 0, regen blocked, can kill
- Food/drink items restore hunger/thirst with `update_hunger_and_thirst` packets

**Remaining gaps:**
- Jail system: GM command to teleport criminal to jail map (not implemented)
- Pets/summons: VB6 has follower NPCs summoned by players (entirely unstarted)
- GM commands: teleport, kick, spawn item/NPC, locate, ban (not implemented)
- Weather: rain/snow from .csm flags sent on map enter (not implemented, client-side rendering only)

**Goal:** Zone enforcement, GM tools, remaining features.

**What to build:**
- Safe zones: MapServer checks `safe_zone` flag before resolving PvP attacks — blocked attacks send rejection packet
- Criminal system: MapServer detects attack on innocent → sets criminal flag on attacker entity
- Jail: GM command to export entity from current map, import on jail map
- Rest/meditate: periodic timer ticks HP/mana regen when entity has resting/meditating flag and hasn't moved
- Hunger/thirst: periodic timer ticks slow drain, applies debuff when empty
- Pets: summoned as NPC entities in MapServer, AI type follower — follow owner, attack on command
- GM commands: session validates GM privilege → sends privileged intent to MapServer (teleport, kick, spawn item, spawn NPC)
- Weather: rain/snow flags from .csm, sent to client on map enter (client-side rendering only)

**Lines estimate:** ~500 Elixir

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

## Phase 14 — Anti-Cheat & Server Hardening

**Status:** `Partially done`

**In code now:**
- Flood guard (packet rate limiting per session)
- Speed hack detection: soft accumulator + position snap-back in movement.ex
- Cooldown fields on PlayerEntity for all timed actions (move, attack, spell, item use)
- Range validation on melee attacks (adjacent tile check)
- Damage is fully server-authoritative (client values never trusted)

**Remaining gaps:**
- Teleport detection: reject movement that skips tiles (movement currently only checks walkability, not adjacency)
- Range validation on ranged attacks and spell casts (target_x/target_y bounds check)
- Invalid packet rejection hardening (e.g., equip before login, action while dead)
- Structured logging of flagged anti-cheat events

**Goal:** The server rejects or corrects cheating attempts without false positives on legitimate play.

**What to build:**
- Speed hack: implement the soft accumulator described in Phase 1 architecture (track `speed_hack_counter`, snap position when threshold exceeded)
- Teleport detection: reject movement that skips tiles
- Range validation: attack/spell/pickup must be within valid range of entity position
- Damage sanity: server computes all damage, client damage values are never trusted (already the case by architecture)
- Packet validation: reject malformed or out-of-sequence packets (e.g., equip before login)
- Logging: structured log of flagged events for review

**Lines estimate:** ~300 Elixir

**Depends on:** Phase 5 (combat range checks), Phase 1 (movement validation)

---

## Phase 15 — Operations & Infrastructure

**Status:** `Partially done`

**In code now:**
- Basic Telemetry metrics
- Health check endpoint
- Nix-based dev environment

**Remaining gaps:**
- Graceful shutdown
- Structured logging
- Monitoring/alerting
- Deployment pipeline
- Asset delivery

**Goal:** The server can be deployed, monitored, and operated in production.

**What to build:**
- Graceful shutdown: on SIGTERM, save all online player entities to DB, drain connections, flush MapServer state
- Structured logging: consistent JSON log format for player actions (login, trade, combat kills, GM actions) for audit trails
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

**Status:** `Missing`

**In code now:**
- Basic local chat exists

**Remaining gaps:**
- Word filter
- Mute system
- Report system
- Chat rate limiting (separate from packet flood guard)

**Goal:** Chat is moderated to prevent abuse.

**What to build:**
- Word filter: configurable blocklist, applied server-side before broadcast
- Mute: GM command to mute player for duration, stored on entity/account
- Report: player sends report intent → logged to DB for GM review
- Chat rate limiting: per-player message rate cap (separate from packet flood), anti-spam

**Lines estimate:** ~150 Elixir

**Depends on:** Phase 10 (social/chat infrastructure)

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

Run alongside Phases 3–7 to verify formula correctness.

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
