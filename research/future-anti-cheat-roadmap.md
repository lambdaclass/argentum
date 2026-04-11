# Future Anti-Cheat Roadmap

This note covers anti-cheat work that makes sense after the core parity path is
stable. The rule is simple: keep server authority and VB6 gameplay behavior,
then harden validation, detection, and operator visibility around it.

## Current Baseline

The current server already enforces core movement timing on the server side:

- walk interval is server-authoritative
- early walk packets are rejected
- repeated early movement accumulates a speed-hack counter
- extreme movement abuse snaps the player back and applies a penalty

That is the correct foundation. Future anti-cheat work should extend the same
model to other packet families and economic invariants instead of building a
separate client-trust system.

## Recommended Future Work

1. Movement anomaly scoring
- Track repeated early walks, impossible boat/water state, impossible transfer
  timing, and suspicious heading/move patterns.

2. Combat, spell, and item cadence validation
- Enforce legal attack, cast, item-use, and work/gather timing server-side.
- Add explicit anti-cheat events when clients repeatedly hammer rejected
  actions.

3. State-machine validation
- Reject impossible bank, trade, crafting, party, guild, and admin packet
  sequences.
- Treat invalid packet ordering as an anti-cheat signal, not only a normal
  error.

4. Economy and inventory invariants
- Add conservation checks for gold, inventory stacks, trade outcomes, bank
  state, and drop/pickup flows.
- Surface suspicious duplicate or impossible item-growth patterns.

5. Position and path sanity checks
- Detect impossible tile occupation, impossible cross-map actions, and
  teleport-like jumps without a legal server-side transition.

6. Session abuse controls
- Add packet-family flood thresholds, reconnect abuse detection, and repeated
  invalid-command tracking.

7. Botting heuristics
- Flag perfectly regular action cadences, highly repetitive loops, and
  suspiciously deterministic reactions.
- Keep this downstream of hard server validation, not as the first defense.

8. Structured anti-cheat event pipeline
- Promote anti-cheat detections from ad hoc log lines into structured events.
- Support severity levels, temporary penalties, silent throttling, auto-jail,
  or alert-only policies.

9. GM/admin abuse audit
- Record privileged actions such as spawn, teleport, item grants, ban/mute,
  and forced movement in a searchable audit trail.

10. Operator visibility
- Add dashboards and alerts for anti-cheat events by account, character, map,
  session, and IP.

## Recommended Order

1. Strengthen server validation.
2. Add invariants and state-machine checks.
3. Emit structured anti-cheat events.
4. Add dashboards and alerts.
5. Add botting heuristics last.

## Non-Goals

- Do not trust client-side timing or client-side anti-cheat logic.
- Do not invent new gameplay restrictions that change legal VB6 behavior.
- Do not prioritize fuzzy bot heuristics over hard server-side validation.
