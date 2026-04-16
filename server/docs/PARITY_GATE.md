# Parity Gate

## What "Parity Gate Green" Means

Parity gate green means every test file listed below in Tier 1 and Tier 2 passes
with zero failures on the current commit. This is a concrete, verifiable state --
not a status label. A PR cannot merge unless both the `fast` and `slow` CI jobs
are green, which together cover Tier 1 and Tier 2 in full.

Tier 3 (soak) and Tier 4 (manual VB6 smoke) are not blocking for PRs but must
pass before cutting a release.


## Tier 1 -- Fast Gate

**Runs on:** every PR and push to main (CI job: `fast`)
**Time budget:** < 30 seconds
**Command:**

```sh
mix test --exclude integration --exclude soak --exclude fixture
```

This is what the CI `fast` job runs (`mix test --exclude integration --exclude soak`).
All files below are `async: true` and need no database, no TCP listener, and no
running application -- only the in-memory `GameData` ETS tables.

### Files

| # | File | What It Proves | Status |
|---|------|----------------|--------|
| 1 | `apps/ao_protocol/test/ao_protocol/reader_test.exs` | Binary reader primitives (int8/16/32, bool, real32, string8) match VB6 wire types; roundtrip with writer | Exists, passes |
| 2 | `apps/ao_protocol/test/ao_protocol/writer_test.exs` | Binary writer primitives produce exact VB6-compatible little-endian bytes | Exists, passes |
| 3 | `apps/ao_protocol/test/ao_protocol/golden_protocol_test.exs` | Server-to-client encoder and client-to-server decoder produce byte-identical output to VB6 Protocol_Writes.bas / Protocol.bas for all implemented packet IDs | Exists, passes |
| 4 | `apps/ao_protocol/test/ao_protocol/guild_protocol_test.exs` | All 27 guild client-to-server decoders and 7 guild server-to-client encoders match VB6 wire format; stream integrity under truncation | Exists, passes |
| 5 | `apps/game_backend/test/characters_conversion_test.exs` | PlayerEntity <-> DB attribute map round-trips preserve identity, race, class, gender, home_city (pure function, no DB) | Exists, passes |
| 6 | `apps/arena/test/combat_test.exs` | Core combat formulas (hit_chance, melee_damage, apply_defense, shield_block, xp_gain, spell_damage, magic_resistance, npc_hit_chance, npc_damage) return values in valid ranges | Exists, passes |
| 7 | `apps/arena/test/vb6_parity_test.exs` | XP per-hit formula, death side effects, XP pool mechanics, gold drops match original VB6 Argentum Online behavior | Exists, passes |
| 8 | `apps/arena/test/vb6_formula_golden_test.exs` | Golden fixtures for VB6 combat formulas -- hardcoded inputs produce exact expected outputs derived from VB6 source; regression protection against formula drift | Exists, passes |
| 9 | `apps/arena/test/character_creation_parity_test.exs` | Name validation, range checks, head validation, body assignment, starting stats with race modifiers, city spawn coordinates all match VB6 ConnectNewUser (TCP.bas:427-581) | Exists, passes |
| 10 | `apps/arena/test/balance_dat_parity_test.exs` | GameData ETS tables load Balance.dat / Ciudades.dat values (EXP table, city spawns, class modifiers) exactly matching canonical VB6 data files | Exists, passes |
| 11 | `apps/arena/test/combat_property_test.exs` | Property-based fuzz (1000 random samples per invariant) for hit_chance in [5,95], melee_damage >= 1, apply_defense >= 0, shield_block returns boolean, xp_gain >= 0, spell_damage > 0, apply_magic_resistance >= 0 | Exists, passes |
| 12 | `apps/arena/test/property_fuzz_expansion_test.exs` | Extended randomized fuzz for combat formula composition invariants, extreme/boundary values, character creation constraints, and binary protocol fuzzing (1000 iterations) | Exists, passes |
| 13 | `apps/arena/test/streamdata_property_test.exs` | StreamData / ExUnitProperties property tests for combat formulas, character creation, and binary protocol round-trips with proper shrinking | Exists, passes |
| 14 | `apps/arena/test/hunger_thirst_test.exs` | Hunger/thirst drain per regen tick, floor at 0, dead players skip drain, starvation/dehydration damage, regen blocking, starvation can kill -- matches VB6 behavior | Exists, passes |
| 15 | `apps/arena/test/inventory_test.exs` | Inventory add/stack/equip/unequip/use/drop operations; slot management; stackable vs non-stackable items | Exists, passes |
| 16 | `apps/arena/test/npc_ai_test.exs` | NPC AI targeting, movement, aggro range, leash behavior, attack cooldowns | Exists, passes |
| 17 | `apps/arena/test/crafting_test.exs` | Crafting recipe selection, skill gating, gathering, product selection | Exists, passes |
| 18 | `apps/arena/test/appearance_bugs_test.exs` | Regression: character_create_packet and character_change_packet include equipment fields; death/equip broadcast; FX field name | Exists, passes |
| 19 | `apps/arena/test/trainer_weather_test.exs` | Trainer NPC proximity gating for skill training; weather packet on map enter | Exists, passes |
| 20 | `apps/ao_tcp_gateway/test/stale_position_test.exs` | Regression: session entity cache diverges from MapServer after movement -- proves design invariant that authoritative position lives in MapServer | Exists, passes |

### Pass Criteria

All 20 files pass with 0 failures, 0 errors. No test is tagged `:skip` or
`:pending`. Total wall-clock time under 30 seconds on CI.


## Tier 2 -- Integration Gate

**Runs on:** every PR and push to main, after Tier 1 passes (CI job: `slow`)
**Time budget:** < 3 minutes
**Requires:** PostgreSQL, Ranch TCP listener, full application boot
**Command:**

```sh
# Full suite including integration (excludes only soak):
mix test --exclude soak
```

This is what the CI `slow` job runs (`mix test` with the default bot_army
test_helper excluding `:soak`). It includes all Tier 1 tests plus the
integration tests below.

### Files (integration-only, beyond Tier 1)

| # | File | What It Proves | Status |
|---|------|----------------|--------|
| 1 | `apps/ao_tcp_gateway/test/ao_tcp_gateway/client_handler_integration_test.exs` | Full TCP flow: connect -> login -> walk -> talk -> disconnect through Ranch TCP -> ClientHandler -> Session -> MapServer; asserts exact AO20 packet sequences | Exists, passes |
| 2 | `apps/ao_tcp_gateway/test/ao_smoke_bot_test.exs` | TCP-level smoke bot: login, walk, chat, request stats through the full network stack; validates actual AO20 binary protocol end-to-end | Exists, passes |
| 3 | `apps/ao_tcp_gateway/test/ao_extended_smoke_test.exs` | Extended TCP smoke: bank, commerce, safe-toggle, meditate, reconnect, whisper, yell, online-request flows end-to-end | Exists, passes |
| 4 | `apps/ao_tcp_gateway/test/packet_trace_replay_test.exs` | Synthetic client packet sequences replayed over real TCP: login, walk, chat, heading, stats, quit phases verified step by step | Exists, passes |
| 5 | `apps/ao_tcp_gateway/test/fixture_replay_test.exs` | Replay `.bin` packet capture fixtures (synthetic or real VB6 traces) against server over TCP; verify response packet IDs match `.json` sidecar expectations | Exists, passes |
| 6 | `apps/ao_tcp_gateway/test/ws_integration_test.exs` | WebSocket integration: login, character creation, walk through the WS transport layer; tagged `@moduletag :integration` | Exists, passes |
| 7 | `apps/arena/test/smoke_bot_test.exs` | MapServer-level smoke: enter, walk, heading, chat, yell, rest, request attributes/skills/mini-stats -- all core actions return valid responses without crashing | Exists, passes |
| 8 | `apps/arena/test/stub_handlers_test.exs` | Compatibility gate stubs: yell, rest, meditate, heal, resucitate, request_atributes/skills/mini_stats, double_click, regen tick all handled without crash | Exists, passes |
| 9 | `apps/arena/test/map_server_bugs_test.exs` | MapServer regression tests: bugs found in Phase 1 review; requires tile NIF and map files | Exists, passes |
| 10 | `apps/arena/test/combat_lifecycle_test.exs` | Full combat lifecycle: enter -> fight -> die -> verify death state -> snapshot; runs against real MapServer | Exists, passes |
| 11 | `apps/arena/test/aoi_visibility_test.exs` | AoI grid visibility culling: players outside AoI range do NOT receive broadcasts, players inside range DO; uses production AoI half-ranges | Exists, passes |
| 12 | `apps/ao_tcp_gateway/test/lifecycle_persistence_test.exs` | Full TCP lifecycle: login, autosave on disconnect (position/stats/inventory persist), crash cleanup (kill process removes entity and session), map transfer persistence, concurrent disconnect safety, double-login rejection, dead-state persistence, online directory cleanup, session token validation | Exists, passes |
| 13 | `apps/arena/test/session_lifecycle_test.exs` | MapServer-level session lifecycle: login/entity spawn, autosave to DB, clean logout, crash cleanup via :DOWN monitor, map transfer without duplicates, double-login prevention, dead-state disconnect, online directory consistency, session registry lifecycle | Exists, passes |

### Pass Criteria

All 33 files (20 Tier 1 + 13 Tier 2) pass with 0 failures, 0 errors. Database
migrations apply cleanly. No test is tagged `:skip` or `:pending`. Total
wall-clock time under 3 minutes on CI.


## Tier 3 -- Soak Gate

**Runs on:** on demand / nightly (not in CI PR gate)
**Time budget:** ~2 minutes per run (configurable)
**Requires:** full application running, bot_army app
**Command:**

```sh
mix test --only soak
```

### Files

| # | File | What It Proves | Status |
|---|------|----------------|--------|
| 1 | `apps/bot_army/test/soak_test.exs` | 10 bots survive 30 seconds without crashes; validates server stability under sustained multi-client load; tagged `@moduletag :soak`, excluded from default runs | Exists, passes |

### Pass Criteria

More than half of spawned bots remain connected after the soak duration. No
server crashes, no OTP supervisor restarts during the run. Wall-clock time
under 2 minutes.

### Gaps

- No load benchmark suite yet (100+ bots, measure tick latency p99).
- No memory/process leak detection over extended soak (10+ minutes).
- No concurrent combat soak (multiple bots fighting simultaneously).


## Tier 4 -- Manual Gate (Before Release)

**Runs on:** before every tagged release
**Requires:** VB6 Argentum Online client connected to the Elixir server

### VB6 Smoke Checklist

- [ ] Login with existing character -- loads correct position, stats, inventory
- [ ] Create new character -- all race/class/gender/city combos spawn correctly
- [ ] Walk in all 4 directions -- position updates smoothly, no rubber-banding
- [ ] Change map -- map transition packet received, new map renders
- [ ] Chat (talk, yell, whisper) -- messages appear in correct channels
- [ ] Pick up / drop / use / equip / unequip items -- inventory syncs
- [ ] Melee attack NPC -- hit/miss/damage/XP all display correctly
- [ ] Cast spell on NPC -- spell damage, mana drain, cooldown
- [ ] Die and resurrect -- death state, ghost mode, resurrection flow
- [ ] Rest and meditate -- HP/mana regen, hunger/thirst drain
- [ ] Open bank -- deposit/withdraw items and gold
- [ ] Start commerce with NPC -- buy/sell flow
- [ ] Guild operations -- create, invite, chat, leave
- [ ] Trainer NPC -- skill training with gold cost
- [ ] Crafting -- mine/fish/woodcut, craft items at forge/anvil
- [ ] Disconnect and reconnect -- session resumes, no duplicate entities

### Pass Criteria

All checklist items verified by a human tester with zero protocol errors or
server crashes observed.


## Current Status Summary

| Tier | Files | All Pass? | CI Gate? |
|------|-------|-----------|----------|
| Tier 1 -- Fast | 20 | Yes | Yes (`fast` job) |
| Tier 2 -- Integration | 13 (+20 from T1) | Yes | Yes (`slow` job) |
| Tier 3 -- Soak | 1 | Yes | No (on-demand) |
| Tier 4 -- Manual | checklist | N/A | No (pre-release) |

Total test files: **34**


## Gaps -- Missing Coverage

### Tier 1 (Fast)

- **ao_session unit tests**: the `ao_session` app has zero test files. Session
  lifecycle (create, resume, expire, token validation) should have pure-function
  unit tests.
- **Spell system parity**: no golden tests for individual spell effects (heal
  amounts, buff durations, paralysis, invisibility) compared to VB6.
- **Level-up formula parity**: no explicit golden test that leveling thresholds
  and stat gains per level match VB6 Balance.dat `[LEVELUP]` section.
- **Pet/taming unit tests**: no tests for pet AI, taming success rates, pet
  commands.
- **Faction system unit tests**: no tests for faction assignment, faction-based
  PvP rules, faction persistence.
- **GM command unit tests**: no tests for `/KILL`, `/BAN`, `/KICK`, `/SUMMON`
  and other GM commands in isolation.
- **Chat moderation unit tests**: no tests for mute, word filter, rate limiting.
- **Account ban unit tests**: no tests for ban check on login, ban expiry.

### Tier 2 (Integration)

- **Concurrent combat integration**: no test with two TCP clients attacking the
  same NPC simultaneously.
- **Guild persistence integration**: no test that creates a guild over TCP,
  restarts, and verifies guild state survives.
- **Trade/commerce integration**: no TCP-level test for the full NPC buy/sell
  flow with gold and inventory changes persisted.

### Tier 3 (Soak)

- **High-load benchmark** (100+ bots, tick latency p99, memory growth tracking).
- **Long-duration soak** (10+ minutes, detect slow leaks).
- **Combat soak** (bots actively fighting, not just walking).
- **Map transition soak** (bots repeatedly changing maps).

### Tier 4 (Manual)

- **Packet capture diffing**: no tooling to record VB6 client packet traces and
  diff them against Elixir server responses automatically.
- **Visual regression**: no screenshot comparison for client rendering under
  Elixir server vs VB6 server.


## How to Add a New Parity Test

### Naming Convention

```
apps/<app>/test/<descriptive_name>_test.exs
```

Use these suffixes to signal intent:

| Suffix | Meaning | Tier |
|--------|---------|------|
| `_test.exs` | Unit test (default) | 1 |
| `_parity_test.exs` | VB6 behavior parity check | 1 |
| `_golden_test.exs` | Hardcoded input/output golden fixture | 1 |
| `_property_test.exs` | Property-based / fuzz test | 1 |
| `_integration_test.exs` | Needs TCP/DB/full app | 2 |
| `_smoke_test.exs` | End-to-end smoke through real stack | 2 |
| `_replay_test.exs` | Packet trace replay | 2 |
| `_soak_test.exs` | Long-running stability test | 3 |

### Tagging Convention

```elixir
# Tier 1 -- no tag needed, just use `async: true`
use ExUnit.Case, async: true

# Tier 2 integration -- use `async: false`, tag if TCP/DB dependent:
@moduletag :integration

# Tier 2 fixture replay:
@moduletag :fixture

# Tier 3 soak -- MUST tag so default runs exclude it:
@moduletag :soak
```

### Where to Put It

| Domain | App | Directory |
|--------|-----|-----------|
| Binary protocol (reader/writer/encoder/decoder) | `ao_protocol` | `apps/ao_protocol/test/ao_protocol/` |
| Session lifecycle, tokens | `ao_session` | `apps/ao_session/test/` |
| DB schemas, persistence, conversions | `game_backend` | `apps/game_backend/test/` |
| Combat, inventory, crafting, NPC AI, map logic | `arena` | `apps/arena/test/` |
| TCP/WS integration, smoke bots, replay | `ao_tcp_gateway` | `apps/ao_tcp_gateway/test/` |
| Soak, load, benchmarks | `bot_army` | `apps/bot_army/test/` |

### Template for a New VB6 Parity Golden Test

```elixir
defmodule Arena.NewFeatureParityTest do
  @moduledoc """
  Golden tests verifying <feature> matches VB6 behavior.
  Expected values derived from <VB6 source file and line>.
  """
  use ExUnit.Case, async: true

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
    :ok
  end

  describe "<VB6 function name> parity" do
    test "<specific scenario from VB6>" do
      # Inputs from VB6 source
      result = Module.function(args)
      # Expected output computed by hand from VB6 code
      assert result == expected
    end
  end
end
```


## CI Workflow Mapping

The `.github/workflows/ci.yml` file defines two jobs that map to the parity
gate tiers:

- **`fast` job** -- Tier 1. Runs `mix test --exclude integration --exclude soak`.
  No database. Covers all async unit, golden, property, and parity tests.
- **`slow` job** -- Tier 1 + Tier 2. Needs `fast` to pass first. Boots
  PostgreSQL, runs `mix test` (full suite minus soak, which bot_army's
  test_helper excludes by default). Covers all integration, smoke, and replay
  tests.
- **Tier 3 (soak)** -- not in CI. Run manually with `mix test --only soak`.
- **Tier 4 (manual)** -- not in CI. Human tester with VB6 client.
