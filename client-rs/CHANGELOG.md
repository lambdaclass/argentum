# Rust/Bevy Client Changelog

This is the append-only home for closed roadmap tasks and dated, verified
milestones. Active execution order and phase completion gates live together in
`ROADMAP.md`.

Stable `W-NNNN` identities were introduced on 2026-08-16. Earlier work is
recorded as pre-ID foundation rather than assigned invented task identities
after the fact. Future closures use this form:

```markdown
### Completed Task W-NNNN — Title

Closed: YYYY-MM-DD (`commit`)
Evidence: commands, tests, captures and measurements
```

Never reuse a completed ID in the active roadmap.

## Pre-stable-ID foundation

### 2026-08-16 — Honest login request encoders

Existing-character login is packet 73 and new-character login is packet 74;
the latter's creation fields are no longer mislabeled as ignored padding.
Shared fixtures assert Rust bytes against the Elixir decoder.

### 2026-08-16 — Runtime configuration boundary

Hard-coded asset/gateway/character values were replaced by query string, page
metadata and page-origin resolution on web and `AO_*` variables on native.
Missing credentials no longer cause implicit character creation, and the build
checks that page configuration does not appear in the WASM artifact.

### 2026-08-16 — Initial lifecycle state machine

`AppState` covers `Boot -> LoadingWorld -> Playing` and scopes gameplay systems
to `Playing`. `MapLoadReported` was removed. Render memos and redraw triggers
were deliberately not mislabeled as application lifecycle states.

### 2026-08-16 — Game-socket latency probe

Client ping 900/server pong 204 uses one in-flight opaque token and a bounded
moving median. A real Ranch listener test covers the echo before login and
fails when the token is not returned unchanged.

### 2026-08-16 — Renderer and movement foundation

The client renders real map layers and artwork, composed characters, static
NPC/object records and real walk/position packets. Newest-key direction,
server-formula walk gating, under/over-character layer placement, tall-art
prefetch and a 35%/0.12s occluder fade are present. These are foundations for
later authoritative entities, depth sorting, trigger-driven roofs and bounded
streaming—not evidence that those phases are closed.

### 2026-08-16 — Recorded artifact baseline

The last recorded optimized client was 19.2 MB raw and 5.5 MB gzip. The gzip
measurement is the transfer baseline to defend; every budget gate must remeasure
the actual artifact rather than repeating this historical number as current.
