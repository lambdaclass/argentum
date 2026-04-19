# Drift

Confirmed open backend drift against the inspected VB6 baseline.

Scope rules:
- Only include functionality that was enabled and working in the inspected VB6 baseline.
- Only include items confirmed from current code plus a VB6 reference.
- Keep fixed items out of this file once they land; they belong in `CHANGELOG.md`.
- Use `Needs Verification` for suspicious items that are not proven yet.

## NPC, Service, and Gameplay Flows

No confirmed open backend drift is currently tracked against the inspected VB6 baseline.

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
