# Drift

Confirmed open backend drift against the inspected VB6 baseline.

Scope rules:
- Only include functionality that was enabled and working in the inspected VB6 baseline.
- Only include items confirmed from current code plus a VB6 reference.
- Keep fixed items out of this file once they land; they belong in `CHANGELOG.md`.
- Use `Needs Verification` for suspicious items that are not proven yet.

## NPC, Service, and Gameplay Flows

19. Status-clear encoders lack backing flags (partial close; encoders added,
    wiring pending subsystem ports).
Current:
- `server/apps/ao_protocol/lib/ao_protocol/server/encoder.ex` — all six encoders
  (`:paralize_ok`, `:blind_no_more`, `:dumb_no_more`, `:rest_ok`,
  `:work_request_target`, `:stun_start`) exist and are under test in
  `encoder_drift_19_test.exs`.
- Live call sites exist for `:paralize_ok` (`inventory_handlers.ex`,
  `status_ticks.ex`) and `:rest_ok` (`healing.ex`).
- No call sites for `:blind_no_more`, `:dumb_no_more`, `:work_request_target`,
  `:stun_start` — the underlying blind/dumb/stun flags and the VB6
  server-prompted work-target flow are not ported yet.
VB6:
- `old/server/Codigo/modHechizos.bas` (dispel paths for blind/dumb),
  `old/server/Codigo/SistemaCombate.bas` (stun on melee hit),
  `old/server/Codigo/Trabajo.bas` (work-request target prompt).
Notes:
- Encoders ship as-is so the subsystem ports can drop in without protocol churn.
- Needs: port the blind/dumb/stun buff system (flag on `PlayerEntity`,
  spell/combat side effects, buff-tick clear) and wire the three encoders at
  their clear sites. Port the server-prompted work-target flow and emit
  `:work_request_target` when a tool requires a target selection.

## Needs Verification

No items pending verification.
