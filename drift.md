# Drift

Confirmed open backend drift against the inspected VB6 baseline.

Scope rules:
- Only include functionality that was enabled and working in the inspected VB6 baseline.
- Only include items confirmed from current code plus a VB6 reference.
- Keep fixed items out of this file once they land; they belong in `CHANGELOG.md`.
- Use `Needs Verification` for suspicious items that are not proven yet.

## NPC, Service, and Gameplay Flows

1. `/HOGAR` timers are still simplified.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_transfer.ex`
VB6:
- `old/server/Codigo/Hogar.bas:33`
Notes:
- The duel/reto block is already in place.
- Current code only distinguishes GM `5s` vs non-GM `10s`.
- VB6 has separate non-GM timer buckets by user type.

2. Crafting production is still structurally different.
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
