# RNG Audit

Parity-sensitive gameplay code must draw randomness through `Arena.Rng`
(`uniform/0`, `uniform/1`, `between/2`) rather than calling `:rand.uniform`,
`:rand.uniform_real`, `Enum.random`, or `Enum.shuffle` directly. Routing
through the shim is what lets golden and property fixtures install a
deterministic strategy via `Process.put(:arena_test_rng, fn)` (see
`Arena.Test.Rng`); a stray direct call silently re-introduces
non-determinism into a formula whose output we otherwise pin to VB6.

This is enforced by `apps/arena/test/rng_guard_test.exs`. That test walks
each guarded module's AST for the forbidden call shapes. The two lists
below mirror the `@guarded` and `@allowlisted` attributes in that file —
**keep them in sync.**

## Guarded (must route through `Arena.Rng`)

Every random draw in these modules feeds a VB6-pinned formula:

| Module | Parity-bearing draws |
|--------|----------------------|
| `lib/arena/combat.ex` | melee/weapon/user damage, defense roll, hit location, crit & shield-block chance, spell damage, NPC damage, `RandomIntBiased` |
| `lib/arena/character_creation.ex` | starting stamina roll |
| `lib/arena/entity/npc_entity.ex` | NPC spawn HP between min/max |
| `lib/arena/map/combat_handlers.ex` | PvP physical-damage defense roll |
| `lib/arena/map/spell_effects.ex` | heal / damage / mana / stamina spell magnitudes |
| `lib/arena/map/status_ticks.ex` | poison damage-per-tick |
| `lib/arena/map/social.ex` | hiding success roll, hiding duration |
| `lib/arena/map/inventory_handlers.ex` | potion `modificador` magnitude |
| `lib/arena/map/npc_interaction.ex` | gamble (`/APUESTAS`) win roll |
| `lib/arena/map/crafting.ex` | taming gate, skill check, skill-up roll |

## Allowlist (raw RNG permitted — event flavor / non-parity)

These draws are cosmetic placement or AI flavor, not parity-bearing
gameplay magnitudes. They may keep `:rand.*` / `Enum.*` directly. If one
of these is ever fully migrated, the guard's "allowlisted modules actually
use raw RNG" test will flag it — promote it to the guarded list then.

| Module | Why exempt |
|--------|-----------|
| `lib/arena/npc_ai.ex` | NPC wander direction and AI roll cadence are flavor; the hit/spell-magnitude draws here are a known follow-up (not yet split out from the movement RNG) |
| `lib/arena/treasure_event.ex` | random treasure map / item / spawn-coordinate selection |
| `lib/arena/map/map_server.ex` | random spawn coordinates within map bounds |
| `lib/arena/events/invasion_server.ex` | invasion spawn coordinates |
| `lib/arena/events/siege_server.ex` | siege NPC-type and spawn-box selection |
| `lib/arena/events/tournament_server.ex` | `Enum.shuffle` of participants for bracket seeding |

## Out of scope

Benchmarks and property/fuzz suites (`*_property_test.exs`, `*_fuzz_*`,
`bench/`) intentionally exercise raw RNG and live under `test/` — the
guard only scans `lib/`, so they are exempt by construction.

`Arena.Rng` itself (`lib/arena/rng.ex`) is the one place `:rand.uniform`
may be called: it *is* the shim.
