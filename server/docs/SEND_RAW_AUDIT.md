# `{:send_raw, _}` audit

This file enumerates every remaining `{:send_raw, _}` site in production
code, classified into three buckets:

1. **Out-of-band / session-control** — intentionally bypasses the egress
   queue. These will not migrate.
2. **Non-map global lanes** — party / guild / world / event broadcasts
   issued from singletons that don't go through a `MapServer`. Need
   their own structured contract; not part of the map-layer effects
   migration.
3. **Still-legacy map handlers** — `Arena.Map.*` modules whose handlers
   are not yet on the `{:ok, state, [Effect.t()]}` contract. Will
   migrate as part of Phase 1 / Item 6.

The grep guard test (`test/effects_send_raw_guard_test.exs`) reads from
this file's allowlists. Adding a new `{:send_raw, _}` site requires
either listing the file here or migrating the producer to
`Arena.Map.Effects.*`.

## 1. Out-of-band / session-control

These live in `ao_tcp_gateway` (the session-loop layer) and are part of
the protocol-level transport. They are not eligible for the egress
queue because they implement it.

- `ao_tcp_gateway/lib/ao_tcp_gateway/client_handler.ex`
- `ao_tcp_gateway/lib/ao_tcp_gateway/ws_handler.ex`
- `ao_tcp_gateway/lib/ao_tcp_gateway/session_helpers.ex`
- `ao_tcp_gateway/lib/ao_tcp_gateway/session_logic.ex`
- `ao_tcp_gateway/lib/ao_tcp_gateway/session_commands/chat.ex`
- `ao_tcp_gateway/lib/ao_tcp_gateway/session_commands/duel.ex`
- `ao_tcp_gateway/lib/ao_tcp_gateway/session_commands/gm.ex`
- `ao_tcp_gateway/lib/ao_tcp_gateway/session_commands/guild.ex`

## 2. Non-map global lanes

Producers that don't run inside a `MapServer` and broadcast via
`AoSession.OnlineDirectory` or directly to per-pid mailboxes. A
parallel structured contract for these is desirable but out of scope
for the map-layer effects migration.

- `arena/lib/arena/party_server.ex`
- `arena/lib/arena/guild_server.ex`
- `arena/lib/arena/treasure_event.ex`
- `arena/lib/arena/world_weather.ex`
- `arena/lib/arena/events/event_manager.ex`
- `arena/lib/arena/events/tournament_server.ex`
- `arena/lib/arena/events/invasion_server.ex`

## 3. Still-legacy map handlers

These are `Arena.Map.*` handlers whose surface is still on the
GenServer `{:noreply, state}` / `{:reply, _, state}` contract. They
emit `{:send_raw, _}` directly through `Helpers.send_to_session/3` and
are the next migration targets.

(All map handlers are now on the effects contract.)

`arena/lib/arena/map/map_server.ex` and `arena/lib/arena/map/helpers.ex`
also contain `{:send_raw, _}`. In MapServer the references are the
generic egress shim path the gateway loops still use; in Helpers they
live inside the `send_to_session/3` / `gm_console/3` / `console/3`
helpers that the legacy modules call. They will be cleaned up
incrementally as the legacy map handlers above move onto the effects
contract.

## Modules already on the effects contract (must stay clean)

The grep guard fails the build if a `{:send_raw, _}` shows up in any
module here:

- `arena/lib/arena/map/healing.ex`
- `arena/lib/arena/map/inventory_handlers.ex`
- `arena/lib/arena/map/social.ex`
- `arena/lib/arena/map/combat_handlers.ex`
- `arena/lib/arena/map/spell_effects.ex`
- `arena/lib/arena/map/npc_interaction.ex` (header only — `:send_raw`
  appears in moduledoc references describing the migration; no actual
  emissions)
- `arena/lib/arena/map/status_ticks.ex`
- `arena/lib/arena/map/effects.ex` (moduledoc reference only)
- `arena/lib/arena/map/visibility.ex`
- `arena/lib/arena/map/player_death.ex`
- `arena/lib/arena/map/npc_death.ex`
- `arena/lib/arena/map/criminal_status.ex`
- `arena/lib/arena/map/bank.ex`
- `arena/lib/arena/map/banking.ex`
- `arena/lib/arena/map/trade.ex`
- `arena/lib/arena/map/commerce.ex`
- `arena/lib/arena/map/faction.ex`
- `arena/lib/arena/map/chat.ex`
- `arena/lib/arena/map/movement.ex`
- `arena/lib/arena/map/quest_handlers.ex`
- `arena/lib/arena/map/training.ex`
- `arena/lib/arena/map/crafting.ex`
- `arena/lib/arena/map/gm/char_edit.ex`
- `arena/lib/arena/map/gm/events.ex`
- `arena/lib/arena/map/gm/inspection.ex`
- `arena/lib/arena/map/gm/moderation.ex`
- `arena/lib/arena/map/gm/permissions.ex`
- `arena/lib/arena/map/gm/teleport.ex`
- `arena/lib/arena/map/gm/world.ex`
- `arena/lib/arena/map/gm_commands.ex`
- `arena/lib/arena/npc_ai.ex`
