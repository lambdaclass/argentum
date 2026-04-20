# Drift

Confirmed open backend drift against the inspected VB6 baseline.

Scope rules:
- Only include functionality that was enabled and working in the inspected VB6 baseline.
- Only include items confirmed from current code plus a VB6 reference.
- Keep fixed items out of this file once they land; they belong in `CHANGELOG.md`.
- Use `Needs Verification` for suspicious items that are not proven yet.

## NPC, Service, and Gameplay Flows

1. GM panel request path is missing.
Current:
- `server/apps/ao_protocol/lib/ao_protocol/server/encoder.ex` (encoder for packet 84 exists)
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:764` (`HandleGMPanel`)
- `old/server/Codigo/Protocol_Writes.bas:2605` (`WriteShowGMPanelForm`)
- Client sends packet 116 (`eGMPanel` / `/PANELGM`)
Notes:
- The Elixir server has the outbound encoder for `show_gm_panel_form` (packet 84) but no
  inbound decoder for packet 116, no route, and no handler. The encoder is never called.
- Needs: decoder for packet 116, route in SessionRouteManifest, handler that reads
  character appearance data and sends it back via the encoder.

## Needs Verification

No items pending verification.
