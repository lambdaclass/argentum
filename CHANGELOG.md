# Argentum Changelog

This file tracks completed work. `ROADMAP.md` tracks remaining work only.

## Recently Completed

- **Sync-first persistence: guild writes (2026-04-17):**
  - Replaced all 8 fire-and-forget `Task.start` guild DB writes in
    `GuildServer` with synchronous `persist_guild_update/2` and
    `persist_relation/4` helpers. Covers: set_news, set_description,
    set_website, declare_war, propose_peace, propose_alliance, level_up,
    and leader succession on leave.
  - All persist helpers wrapped in `try/rescue` so DB failures (constraint
    errors, connection loss) log the error and return `:error` without
    crashing the GenServer or corrupting ETS state.
  - Hardened `accept_invite` `add_member` call with the same
    `try/rescue` pattern — previously a constraint error would crash the
    GenServer.
  - 5 new failure-path tests (`guild_sync_persistence_test.exs`):
    set_news, set_description, set_website, and declare_war all verify
    ETS consistency and GenServer survival when DB writes fail.
    Multi-failure sequencing test confirms repeated failures don't
    degrade the process.
  - Updated 2 guild authority test expectations to accept `{:error,
    :db_error}` (previously these tests crashed the GenServer via
    unhandled constraint errors).
- **Runtime safety: backpressure and autosave (2026-04-17):**
  - Added outbound backpressure for lagging sessions (TCP + WebSocket).
    Mailbox length check before each loop iteration/outbound send, warning
    at 500 messages, hard disconnect at 1000 (config-backed via
    `Application.compile_env`). TCP send_timeout of 5s prevents stuck sends.
    Telemetry event `[:arena, :session, :backpressure]` with cause metadata
    (`:mailbox_overflow` vs `:send_timeout`). Two regression tests: lagging
    client disconnect and healthy noisy session control.
  - Replaced naked `Task.start` autosave with coalescing `AutosaveWriter`
    GenServer. One in-flight DB write per character, latest-snapshot-wins
    coalescing, `flush/1` for synchronous drain on cleanup/disconnect.
    Shared `snapshot_from_entity/1` builder for autosave and cleanup paths.
    Telemetry events: submitted, coalesced, started, ok, error. Cleanup is
    the authoritative persistence boundary (synchronous flush-then-save).
    12 tests including 7 adversarial: stale overwrite, concurrent flush,
    rapid-fire 50x coalesce, cross-char isolation, GenServer survival after
    write failure.
- **Security and observability hardening (2026-04-17):**
  - Added adversarial tests (114 tests) for party, trade, guild, bank/NPC, and
    faction authority. Fixed 7 security gaps: party leader-only invite, expired
    invite rejection, kick cooldown, leader-only safe_toggle, and
    meditating/navigating/paralyzed trade blocks.
  - Added telemetry event emission for map ticks, movement, broadcasts, combat
    (attack/spell), persistence (cleanup/autosave), and sessions
    (login/crash). PromEx/Grafana wiring still pending.
  - Added session-recovery regression tests (crash→re-login, double crash,
    online directory cleanup, graceful vs crash save). Replaced
    `Process.sleep(500)` with poll-based waits across lifecycle tests.
  - Party invites are now authoritative and leader-only (old roadmap #50).
- **Backend modernization, gateway split, and dependency cleanup (2026-04-15/16):**
  - Added `Arena.Map.State` update helpers, extracted pure combat/progression
    seams, consolidated NPC/player death resolution, split
    `apply_spell_damage`, and made NPC AI return `{state, effects}` where it
    materially improves tests.
  - Split `gm_commands.ex` into focused `Gm.Moderation`, `Gm.Teleport`,
    `Gm.Inspection`, `Gm.World`, `Gm.Events`, and `Gm.Faction` modules.
  - Split `SessionLogic` twice: first by lifecycle phase
    (`SessionLogin` / `SessionWorld` / `SessionTransfer` /
    `SessionPersistence`), then by command domain
    (`SessionCommands.Chat` / `Commerce` / `Guild` / `Gm`) so gateway command
    routing is no longer one giant module.
  - Added `AoSession.SessionMonitor` and stale-session crash-cleanup coverage,
    cached guild display info on `PlayerEntity`, and broke the compile-time
    `arena` ↔ `game_backend` cycle by extracting `AoEntities.PlayerEntity`
    into a shared `ao_entities` umbrella app.
  - Cleaned the `server/` root: parity/smoke docs moved under `server/docs/`,
    monitoring assets under `server/docs/monitoring/`, helper scripts under
    `server/scripts/`, orphaned `package-lock.json` removed, and ignore rules
    updated for local cache noise.
- **Arena internal boundaries refactor (2026-04-14/15):**
  - Split `social.ex` (4,192 → 772 lines) into 8 focused modules: Chat,
    Healing, Pets, QuestHandlers, Faction, NpcInteraction, GmCommands, Social.
  - Introduced `%Arena.Map.State{}` struct for compile-time key safety on the
    production map state path (22 explicit fields, 6 previously-dynamic).
  - Split `combat_handlers.ex` (2,489 → 1,083 lines) into 4 focused modules:
    CombatHandlers, SpellEffects, PlayerDeath, StatusTicks.
  - Migrated all 13 test files to shared `Arena.Test.MapStateFactory`, removing
    stale `floor_items`/`next_floor_id` fields and raw-map drift.
  - Updated MapServer `@moduledoc` to reflect all 16 domain modules.
  - 2,774 tests passing, zero compile warnings. Runtime model unchanged.
- Client NPC body loading and bootstrap state handling fixed so NPC sprites use
  the full client body table instead of falling back to incorrect placeholder
  rendering.
- Arena authoritative persistence and backend refactor research added in
  [research/arena-authoritative-persistence-and-refactor.md](research/arena-authoritative-persistence-and-refactor.md).
- Browser product shell completed for the current username/password path:
  register/login/logout/session restore, character options/list/create/select,
  ranking, and `login_existing_char(char_id, session_token)` gameplay launch.
- Browser gameplay UI parity surfaces completed for snow rendering, trade item
  names/GRH/elemental tags, spell cooldown/requirement/AoE hints, dead/error/
  loading/reconnect states, music/SFX/keybind settings, and minimap display.
- Recent adversarial/security fixes closed multiple economy, social, and
  persistence drift bugs, including commerce gold minting, trade atomicity,
  bank revalidation, invalid slot handling, mute/dead chat checks, safe-zone
  spell effects, and TOCTOU gold-transfer issues.
- Parity-gate TCP harness hardened: deterministic packet waits, shared TCP
  packet decoder/helpers, SQL sandbox owner lifecycle for Ranch/TCP tests,
  and default soak exclusion.
- CI parity lanes added: fast lane for compile/format/credo/unit and slow lane
  for heavier integration/parity coverage.
- StreamData property tests added for combat formulas, character creation, and
  protocol round-trip invariants.
- TCP smoke coverage expanded with bank, commerce, safe toggle, meditate,
  reconnect, whisper, online, yell, and rest flows.
- Fixture replay harness and `mix capture.packets` workflow added, with a
  synthetic seed fixture corpus pending replacement by real VB6 captures.
- Manual VB6 smoke checklist added in
  [server/docs/VB6_SMOKE_CHECKLIST.md](server/docs/VB6_SMOKE_CHECKLIST.md).
- Supported backend environment verified: the `server/` Nix/dev shell compiles
  and tests cleanly.
- Recent migrations verified on clean Postgres and on an upgrade path.
- Docker support added for local Postgres, migration, and test flows.
- Home-city mapping fixed to match VB6 `e_Ciudad`.
- Raw `ehome` packet decoded and routed to `/HOGAR`.
- Old-client packet coverage pass added 50+ decoders and routed the great
  majority of them.
- Gameplay wiring pass completed for `modify_skills`, `change_description`,
  `spell_info`, `move_item`, `move_spell`, `modify_gold`, pet control, party
  chat, gold transfer, and faction donate.
- Guild UI route hardening completed for current clan UI behavior.
- VB6 parity test suite seed added.
- Automated parity gate expanded with `Balance.dat` parity checks, formula
  golden fixtures, character-creation parity, and a first smoke-bot layer.

## Core Backend Systems Already Implemented

- TCP + WebSocket networking for the current AO20 gameplay/web path
- Authoritative `MapServer`
- AoI visibility lifecycle and spatial grid
- Character creation, login, persistence, online directory, static `.dat`
  loading
- Inventory, equipment, ground items
- Melee + ranged combat
- Spell system and NPC spell casting
- NPC AI, loot drops, and pet follow/attack
- Crafting and gathering
- Commerce: shopkeepers, bank, player trade
- Social systems: whisper, yell, parties, guilds, rest/meditate, faction chat
- Factions
- Progression
- GM commands
- Chat moderation
- Anti-cheat basics
- Graceful shutdown and audit logging
- Accounts with bcrypt and character ownership

## Recently Closed Backend Parity Items

- NPC XP parity
- Player death entry-point unification
- Player death cleanup
- Death inventory/equipment rules
- NPC gold reward semantics
- Guild backend depth
