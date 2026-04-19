# Drift

Confirmed open backend drift against the inspected VB6 baseline.

Scope rules:
- Only include functionality that was enabled and working in the inspected VB6 baseline.
- Only include items confirmed from current code plus a VB6 reference.
- Keep fixed items out of this file once they land; they belong in `CHANGELOG.md`.
- Use `Needs Verification` for suspicious items that are not proven yet.

## NPC, Service, and Gameplay Flows

1. `TrainList` still uses the wrong trainer targeting model.
Current:
- `server/apps/arena/lib/arena/map/npc_interaction.ex`
- `server/apps/arena/lib/arena/map/helpers.ex`
VB6:
- `old/server/Codigo/Protocol.bas:4211`
- `old/server/Codigo/Protocol.bas:4226`
- `old/server/Codigo/Matematicas.bas:117`
Notes:
- Current code resolves a nearby trainer through `find_nearby_npc_of_type/4`.
- VB6 requires selected `TargetNPC` plus `Distancia <= 10`.
- Current helper still uses square-range checks instead of VB6 `Distancia`.

2. Gambling still uses the wrong NPC-targeting model.
Current:
- `server/apps/arena/lib/arena/map/npc_interaction.ex`
- `server/apps/arena/lib/arena/map/helpers.ex`
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:181`
- `old/server/Codigo/Matematicas.bas:117`
Notes:
- Win odds and amount handling are now closer.
- The remaining drift is target resolution: current code accepts any nearby timbero, while VB6 requires selected `TargetNPC` plus `Distancia <= 10`.

3. Priest-driven flows still use the wrong NPC-targeting model.
Current:
- `server/apps/arena/lib/arena/map/healing.ex`
- `server/apps/arena/lib/arena/map/npc_interaction.ex`
- `server/apps/arena/lib/arena/map/social.ex`
- `server/apps/arena/lib/arena/map/helpers.ex`
VB6:
- `old/server/Codigo/Protocol.bas:4378`
- `old/server/Codigo/Protocol.bas:4408`
- `old/server/Codigo/Protocol.bas:5563`
- `old/server/Codigo/Protocol.bas:6358`
- `old/server/Codigo/Matematicas.bas:117`
Notes:
- Heal, resurrect, forgive, and marriage still resolve "any nearby priest".
- VB6 requires selected `TargetNPC` plus per-flow `Distancia` checks.

4. `/HOGAR` timers are still simplified.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_transfer.ex`
VB6:
- `old/server/Codigo/Hogar.bas:33`
Notes:
- The duel/reto block is already in place.
- Current code only distinguishes GM `5s` vs non-GM `10s`.
- VB6 has separate non-GM timer buckets by user type.

5. Crafting production is still structurally different.
Current:
- `server/apps/arena/lib/arena/map/crafting.ex`
VB6:
- `old/server/Codigo/Acciones.bas:483`
- `old/server/Codigo/InvUsuario.bas:1859`
Notes:
- Current blacksmithing/carpentry/alchemy/tailoring depend on nearby workstation NPC types.
- VB6 ties blacksmithing to workstation objects and the other craft forms to equipped tool use.
- This is an intentional divergence for now (documented in crafting.ex moduledoc).

## Needs Verification

1. Crafting NPC type collision is suspicious but not proven.
Current:
- `server/apps/arena/lib/arena/map/crafting.ex`
- `server/apps/arena/lib/arena/map/npc_interaction.ex`
Notes:
- Do not treat this as confirmed until it is matched against real data and VB6 behavior.

2. GM panel request path appears missing, but the exact client-side trigger still needs proof.
Current:
- `server/apps/ao_protocol/lib/ao_protocol/server/encoder.ex`
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:764`
- `old/server/Codigo/Protocol_Writes.bas:2605`
Notes:
- The server encoder for `show_gm_panel_form` exists.
- I have not yet found the corresponding live inbound request path in the current backend.
