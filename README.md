# Argentum Online — Elixir Server

Rewrite of the Argentum Online VB6 MMORPG server in Elixir. The original server is ~93,000 lines of VB6 across 50+ modules; this implementation targets ~12,000 lines of Elixir.

## Architecture

**One MapServer GenServer per active map is the sole authority for all online gameplay state on that map.** While a player is online, their full entity (position, HP, inventory, equipment, buffs, stats, gold, flags) lives in the MapServer's Elixir state. There is no CharacterServer for gameplay.

- **Session processes are thin** — socket, packet decode/encode, flood protection. They forward player intents to the current MapServer and nothing else.
- **Player actions are processed immediately in mailbox order** — no tick batching, no intent queues. The GenServer mailbox serializes access like VB6's single thread, but the implementation is better structured and parallel across maps.
- **Cooldowns are per-action server-side timestamps, not ticks.** Each entity tracks `next_move_at`, `next_attack_at`, etc. Walk speed uses a soft accumulator matching VB6's speed hack detection.
- **Direct MapServer-to-session sends are the hot-path delivery mechanism.** MapServer holds `%{char_id => pid()}` and sends packets to session pids directly. PubSub is used only for cross-map features (guild chat, global announcements).
- **Dynamic occupancy is a dense 100×100 positional grid**, separate from the static collision NIF. Answers "who is on tile (x, y)?" in O(1). `players_by_id` is for entity lookup; the occupancy grid is a positional index.
- **Ground items are position-oriented** — keyed by `{x, y}` for pickup checks ("what's at my feet?").
- **Bank is out of hot state** — loaded from DB on demand when interacting with a bank NPC.
- **Rust NIF is narrow:** existing tile collision grid only (`TileGrid`). All gameplay logic is pure Elixir. Do not broaden Rust scope without profiling evidence.
- **Periodic timers** handle background-only work: NPC AI (100ms), respawns, buff decay, regen, hunger/thirst drain, autosave.
- **DB is authoritative only when the player is offline.** Periodic snapshots while online, final save on logout.

See [SERVER_ROADMAP.md](SERVER_ROADMAP.md) for the full implementation plan.

## Current State

**Phase status snapshot:**
- `Phase 1 — Runtime & Performance Foundations`: `Done`
- `Phase 2 — Character System, Persistence & Map Transitions`: `Mostly done`
- `Phase 3 — Durable State & Persistence Shape`: `Partially done`
- `Phase 4 — Inventory`: `Mostly done`
- `Phase 5 — Combat`: `Missing`
- `Phase 6 — Spells`: `Missing`
- `Phase 7 — NPC AI`: `Missing`
- `Phase 8 — Commerce & Banking`: `Missing`
- `Phase 9 — Crafting & Gathering`: `Missing`
- `Phase 10 — Social Systems`: `Partially done`
- `Phase 11 — Progression`: `Partially done`
- `Phase 12 — World Rules & Polish`: `Missing`

**Implemented so far:**
- TCP + WebSocket networking with AO20 binary protocol
- Map loading from .csm files with Rust NIF for tile collision
- Multiplayer movement, chat, position sync, heading changes
- AoI visibility lifecycle with `:global`, `:aoi_scan`, and `:aoi_grid` modes
- Spatial grid for nearby-player lookup on the hot path
- Character creation (packet 74) with VB6-accurate stat computation
- Database persistence (characters, snapshots, autosave on logout)
- Map transitions via exit tiles
- Inventory groundwork and most live inventory flows: pickup, drop, equip toggle, item use, ground items
- Session registry, online directory, flood protection
- Static game data loading from VB6 .dat files (Balance.dat, Ciudades.Dat)
- Web client with Pixi.js (4 sprite layers, NPCs, objects, MIDI music)

**Main remaining gaps:**
- Finish Phase 2 cleanup: auth/account model and remaining login/transfer test stabilization
- Finish Phase 3 cleanup: normalize the remaining durable character sub-state (`skills`, `spells`, `bank_items`) and keep transient state out of the DB model
- Finish Phase 4 cleanup: equip restrictions, effective stat recomputation, and remaining inventory edge cases
- Build the missing gameplay backbone: combat, spells, NPC AI
- After that: commerce, crafting, social systems, progression, and world-rule polish

## Scaling

On a single machine (14-core M3 Max, 48GB RAM), the current benchmark harness (`mix bench.visibility`) confirms **1,000 players on one map at 14.8% scheduler with zero queue depth**, and **2,000 world-spread players across 25 maps at 9.6% scheduler with 5,553 moves/sec**. The bottleneck at 5,000+ bots is DB pool saturation during the login storm, not game logic.

### One GenServer per map — natural parallelism

Each map is an independent GenServer process. The BEAM scheduler runs them across all CPU cores automatically. Maps share nothing — a busy city doesn't slow down a quiet dungeon. The VB6 original was single-threaded; this architecture is the single biggest structural improvement over it. With 14 cores and dozens of active maps, the game logic parallelizes without any explicit threading or locking.

Two additional techniques reduce the work each MapServer does:

### Area of Interest (AoI)

The classic MMORPG problem: if every player move broadcasts to every other player on the map, cost is O(n) per move. With 5,000 players, one walk sends 4,999 packets — the server spends all its time on broadcasts.

AoI fixes this by only broadcasting to players within visual range. The VB6 AO client viewport is 23×19 tiles (half-range: 11×9). The server skips any player outside that rectangle. On a 100×100 map with 5,000 players, a move notifies ~20 nearby players instead of 4,999. This applies to the three high-frequency broadcasts: movement (packet 44), chat (packet 35), and heading changes. Enter/leave/transfer now use the same visibility lifecycle so create/remove also track who can actually see whom.

AoI changes broadcast complexity from **O(n) to O(k)** where k is the number of nearby players (typically 5-30 regardless of total map population).

### Spatial Grid

Without optimization, finding "who is nearby?" still requires iterating all players to check distances — O(n) per broadcast. The spatial grid avoids this by bucketing players into cells. Each cell covers a square region at least as large as the AoI range. To find nearby players, only 9 cells (a 3×3 neighborhood) need to be checked, making the lookup O(1).

The grid is maintained inline during movement: `grid_remove(old_x, old_y)` then `grid_add(new_x, new_y)`. Both are single `MapSet` operations.

### Benchmark (bots + server on same machine, `mix bench.visibility`)

**aoi_grid mode with pre-encoded broadcasts** (the production-intended configuration):

| Players | Scenario | Sched% | RAM | Queue | Recip/move | Moves/s | RTT p50 |
|---------|----------|--------|-----|-------|------------|---------|---------|
| 500 | hot_spread (100x100) | 3.8% | 125MB | 0 | 52.5 | 1,506 | 0ms |
| 500 | crowd (25x25 arena) | 8.2% | 202MB | 0.1 | 433.8 | 309 | 1ms |
| 500 | crowd_saturated (210ms fixed) | 11.0% | 202MB | 43.2 | 434.3 | 414 | 17ms |
| 1,000 | hot_spread (100x100) | 14.8% | 178MB | 0 | 108.2 | 2,860 | 0ms |

**aoi_grid vs global at 1,000 players on one map:**

| Metric | global | aoi_grid |
|--------|--------|----------|
| Recipients/move | 999 | 108 |
| MapServer queue | 997 | 0 |
| Memory | 5.7 GB | 178 MB |
| RTT p50 | 156ms | 0ms |

Global is unplayable at 1,000 players. AoI grid handles it with room to spare. Full results in [`docs/benchmark_visibility_2026_03_28.md`](docs/benchmark_visibility_2026_03_28.md).

### Single-node improvements still available

- **OS tuning**: `ulimit -n 65536` for file descriptors — the 10k bot test crashed at ~13k from TCP connection limits, not game logic.
- **ETS for reads**: `snapshot_entity` and `get_info` can read from ETS instead of blocking the MapServer GenServer.
- **Map sharding**: split a hot 100×100 map into quadrants, each its own GenServer, for true parallel processing within a single map.

### Multi-node architecture (planned)

The natural shard is already one map = one GenServer. Multi-node scaling builds on this with plain Erlang distribution — no Horde, no riak_core.

**Node roles:**

- **Gateway nodes** — run TCP/WS sessions. Hold the player's socket. Forward intents to remote map nodes via `GenServer.call`/`:erpc`. Sessions never move.
- **Map nodes** — run authoritative MapServer processes. Own all gameplay state for their assigned maps.
- **MapDirectory** — answers "which node owns map 42?" Consulted on login, map transfer, and failover.

**Map placement:**

- Simplest first: static ranges (maps 1–50 on node A, 51–100 on node B).
- Better: DB-backed leases. A `map_leases(map_id, owner_node, lease_until)` table where each owner renews periodically. If a node dies and its lease expires, another node claims the map.

**Why gateway/map separation matters:**

When a map node dies, the player's socket stays alive on the gateway. The gateway notices the map is gone, asks MapDirectory for the new owner, and reattaches the player. No reconnect needed.

**Failover levels:**

1. **Same-node** — OTP restarts a crashed MapServer process on the same node. Already works.
2. **Cross-node cold** (recommended first) — if a node dies, another node claims its maps and starts fresh MapServers from static map data. Players see a short hitch, then resume. Player state is recovered from the last DB autosave (worst case: 60 seconds of lost progress).
3. **Cross-node warm** — periodically snapshot dynamic map state (players, dropped items, NPC states) to a shared store. On failover, load the latest snapshot instead of starting fresh.
4. **Hot** — event-log replication or shadow standby processes. Much more complexity for marginal early value.

**Stack:**

- `libcluster` for node discovery
- Local `DynamicSupervisor` per node for map processes
- Explicit `MapDirectory` service for ownership lookups
- Postgres-backed map leases for ownership and failover
- `:erpc` / `GenServer.call` between gateway and map nodes

**What we deliberately avoid:**

- **riak_core** — wrong abstraction; designed for partitioned data stores, not game processes
- **Horde** — uses CRDTs with eventual consistency, which is a bad fit for authoritative game state
- **Active-active map ownership** — two nodes thinking they own the same map leads to split-brain state corruption

## Setup

Requires [Nix](https://nixos.org/download) + [devenv](https://devenv.sh/getting-started/).

devenv provides PostgreSQL 16, Elixir 1.16, Erlang/OTP 26, Rust, and Node.js — no manual installation needed.

```bash
# Start services (PostgreSQL) in background
devenv up -d

# Enter dev shell
devenv shell

# First time: install deps, create DB, and run
make start

# Subsequent runs (DB already exists)
make run
```

Other useful targets:

```bash
make test       # run all tests
make check      # format + credo
make console    # iex -S mix
make client.dev # run the new Vite web client on :5173
make clean      # remove build artifacts
make purge      # full reset (devenv + _build + deps)
```

> **Without nix:** Install Elixir, Erlang, Rust, and PostgreSQL manually (see `.tool-versions` for versions). Alternatively, `docker-compose up -d postgres` provides just the database.

### Connect

- **TCP client (AO20 protocol):** connect to `localhost:7666`
- **WebSocket client:** open `http://localhost:7667/test_client.html`
- **Serious web client:** run `make client.build`, then open `http://localhost:7667/client/`
- **Map data API:** `http://localhost:7667/api/map/1`
- **Standalone web client scaffold:** see [`client/README.md`](client/README.md)
  - `nix develop --command make client.dev`

## Project Structure

```
apps/
├── arena/              # Game logic
│   ├── lib/arena/
│   │   ├── map/        # MapServer, CsmParser
│   │   └── ...
│   └── native/tile_grid/  # Rust NIF for tile collision
├── ao_tcp_gateway/     # TCP + WebSocket networking
│   ├── lib/ao_tcp_gateway/
│   │   ├── tcp_handler.ex
│   │   ├── ws_handler.ex
│   │   ├── ws_router.ex
│   │   └── packet_*.ex
│   └── priv/static/    # Web client, sprites, indices
├── game_backend/       # Ecto schemas, persistence
└── ...
client/                 # Standalone web client (Vite + TypeScript + React + Pixi)
```

## Umbrella Apps

- **arena** — MapServer, entity state, gameplay logic, combat formulas, NPC AI, Rust NIF for tile collision
- **ao_tcp_gateway** — TCP and WebSocket transport, AO20 binary protocol encode/decode, static debug client assets
- **game_backend** — Ecto schemas, database persistence, migrations

## Web Clients

- [`apps/ao_tcp_gateway/priv/static/test_client.html`](apps/ao_tcp_gateway/priv/static/test_client.html) remains the debug/protocol fallback client.
- [`client/`](client/) is the new standalone `Vite + TypeScript + React + Pixi` web client where the serious browser client should grow.
- After `make client.build`, the Elixir gateway serves the web client at `http://localhost:4001/client/`.
