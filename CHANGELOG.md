# Argentum Changelog

This file tracks completed work. `ROADMAP.md` tracks remaining work only.

## Recently Completed

- **Sync-first persistence: trade boundary (2026-04-18):**
  - Trade `execute_trade` now writes both players' gold and inventory to DB
    atomically (single `Repo.transaction` via `save_trade_snapshots/2`) before
    mutating in-memory state. On DB failure, both players' state stays unchanged
    and the trade ends with an error message.
  - Added `GameBackend.Characters.save_trade_snapshots/2`: atomic two-player
    save in a single transaction.
  - 5 persistence tests: one-side DB failure, both-fail commit, successful trade
    persists immediately, replay/double-accept, and reconnect shows pre-trade
    state after failed commit.
- **Guild server hardening and DB-first reordering (2026-04-17):**
  - Fixed accept_invite authority bug: now checks expires_at and verifies
    the inviter still leads the guild before proceeding. Invite is only
    deleted after DB success; on failure the invite is preserved for retry.
  - Fixed accept_request authority bug: now verifies a pending request
    exists before adding a member. Added `Guilds.request_exists?/2`.
  - Reordered all guild ETS mutations to DB-first: set_news, set_description,
    set_website, declare_war, propose_peace, propose_alliance, add_exp/level_up,
    and leader succession now only mutate ETS after the DB write succeeds.
  - Wrapped all remaining raw `Guilds.*` calls in try/rescue: create_guild,
    add_member, remove_member, delete_guild, create_request, delete_request,
    list_requests. GuildServer can no longer crash on DB exceptions.
  - Made leader succession transactional via `Guilds.remove_member_and_set_leader/3`
    using `Repo.transaction`. DB cannot end up pointing at a departed leader.
  - Converted `leave/1` and `kick/2` from `GenServer.cast` to `GenServer.call`
    so callers get commit results. Updated 4 callers in session_commands/guild.ex.
  - Updated guild persistence tests for DB-first semantics (ETS unchanged on
    failure). Updated authority tests for call-based kick.
- **AutosaveWriter + cleanup hardening (2026-04-17):**
  - Replaced `Task.start` + `Process.monitor` with `spawn_monitor/1` (unlinked
    + monitored in one call). Worker has internal try/rescue; {:DOWN} handler
    covers truly unexpected crashes. Clears in_flight, emits error telemetry,
    resolves flush waiters — preventing stuck chars and hanging flushes.
  - Session cleanup now logs a warning (with stale-autosave risk note) on
    flush timeout instead of silently swallowing. Final save failures emit
    `[:arena, :persistence, :cleanup_save_failed]` telemetry and log with
    data-loss-risk context instead of silent continuation.
  - Fixed kick/leave `{0, nil}` bug: `Repo.delete_all` returning zero deleted
    rows is now treated as an error, preventing ETS mutation when the DB row
    doesn't exist.
  - Added 7 failure-path tests: guild accept_invite/accept_request/kick/leave
    DB failure, autosave worker-death recovery (with and without pending
    snapshot), and cleanup_save_failed telemetry emission.
- **Sync-first persistence: bank boundary (2026-04-17):**
  - Reordered all bank operations to DB-first: deposit/extract items and
    gold now write to DB before modifying in-memory state. On DB failure,
    in-memory state stays unchanged and the player gets an error message.
  - Item deposit: `upsert_bank_item` checked before inventory mutation.
  - Item extract: `bank_withdraw` checked before inventory add. If
    inventory is full after DB withdraw, compensating re-deposit restores
    the bank slot.
  - Gold deposit/extract: `save_bank_gold` return value checked; rollback
    on failure.
  - All DB wrappers (`upsert_bank_item`, `bank_withdraw`, `save_bank_gold`)
    use `try/rescue` to catch raises from constraint errors or connection
    loss.
  - 5 new failure-path tests (`bank_persistence_test.exs`): gold deposit,
    gold extract, item deposit, item extract, and sequential multi-failure
    all verify in-memory state stays pristine on DB error.
  - 37 total bank tests passing (32 existing + 5 new), 0 regressions.
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
