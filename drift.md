# Drift

Confirmed open backend drift against the inspected VB6 baseline.

Scope rules:
- Only include functionality that was enabled and working in the inspected VB6 baseline.
- Only include items confirmed from current code plus a VB6 reference.
- Keep fixed items out of this file once they land; they belong in `CHANGELOG.md`.
- Use `Needs Verification` for suspicious items that are not proven yet.

## NPC, Service, and Gameplay Flows

19. `:stun_start` encoder lacks a backing stun buff (residual from the
    Drift #19 audit; blind/dumb/work-target wiring is now closed — see
    `CHANGELOG.md`).
Current:
- `server/apps/ao_protocol/lib/ao_protocol/server/encoder.ex:707` — the
  `:stun_start` encoder (eStunStart = 98, Int16 Duration) is in place and
  pinned by `apps/ao_protocol/test/encoder_drift_19_test.exs`.
- No live call site. `PlayerEntity` exposes `paralyzed`/`blind`/`dumb` flags
  but no `stun` flag, and `Arena.Map.CombatHandlers.handle_attack/4` does not
  roll a melee stun proc.
- `Arena.Map.StatusTicks.process_player_buffs/4` already clears
  `:paralyzed` / `:blind` / `:dumb` buffs from the same `entity.buffs` list,
  so a `:stun` buff type would slot in without restructuring.
VB6:
- `old/server/Codigo/SistemaCombate.bas` — stun-on-melee chance roll
  (post-hit, weapon-dependent).
- `old/server/Codigo/Protocol_Writes.bas:2460` — `WriteStunStart` body
  (Int16 duration in ms).
Needs:
- Add a `stun` flag and buff-type to `PlayerEntity` / status-tick clearing.
- Wire the VB6 stun chance into the post-hit path in
  `Arena.Map.CombatHandlers` and emit `:stun_start` via `Effects.send/2`
  when the proc lands.
- Mirror the `blind_no_more_drift_test.exs` shape in a `stun_drift_test.exs`.

## Needs Verification

No items pending verification.
