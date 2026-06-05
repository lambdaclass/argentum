# Argentum Changelog

This file tracks completed work. `ROADMAP.md` tracks remaining work only.

## Recently Completed

- **Drift #19 audit — blind / dumb / work-target encoders verified wired
  (2026-06-05):**
  - `:blind_no_more` is emitted both from
    `Arena.Map.StatusTicks.process_player_buffs/4` on `:blind` buff expiry
    and from `Arena.Map.SpellEffects` on a `cura_ceguera`-spell clear (VB6
    `modHechizos.bas` `If .flags.Ceguera > 0` guard preserved). Coverage:
    `apps/arena/test/blind_no_more_drift_test.exs`.
  - `:dumb_no_more` is emitted from the same two paths for `:dumb` /
    `cura_estupidez`. Coverage: `apps/arena/test/dumb_no_more_drift_test.exs`.
  - `:work_request_target` is emitted from
    `Arena.Map.CombatHandlers.handle_attack/4` when the player casts a
    non-`AutoLanzar` spell with no target picked (VB6
    `modHechizos.bas:4150-4156`). Coverage:
    `apps/arena/test/work_request_target_drift_test.exs`.
  - The drift entry overstated the gap; the only residual is `:stun_start`,
    which still needs the melee stun-on-hit buff system (kept as Drift #19
    in `drift.md`).

- **Map-layer effects migration fully closed (2026-05-11):**
  - Migrated the last three legacy GM sub-handlers —
    `Arena.Map.Gm.Inspection`, `Arena.Map.Gm.Teleport`, and
    `Arena.Map.Gm.Permissions` — to the `{:ok, state, [Effect.t()]}`
    contract. `Inspection` covers 15 public handlers (charinfo, charstats,
    charinventory, charbank, locate, onlinemap, checkslot, etc.) and
    `Teleport` covers `gm_teleport` / `gm_goto` / `gm_summon`, all routing
    relocations through `Effects.transfer/5`. `Permissions` was already
    pure (predicates returning `:ok` / `{:error, _}`) and joined the
    send_raw guard with no handler changes.
  - Dropped `Arena.Map.GmCommands.bridge_legacy/2` and all 90 of its call
    sites. Every GM sub-handler now returns `{:ok, state, effects}` and
    `handle_gm_command/4` delegates directly. The bridge wrapper plus its
    moduledoc paragraph are gone.
  - 31 map-handler modules are now in the `effects_send_raw_guard_test.exs`
    allowlist; the guard fails the build on any new `{:send_raw, _}` in a
    migrated producer.
  - Added `Arena.Test.Scenario.Snapshot`: stable serializers for player
    state, inventory, buffs, AoI-visible set, and emitted effects, plus
    `diff_snapshots/2`, `format_diff/1`, and `assert_state_equal/3`.
    Failure output surfaces the first meaningful divergence path. 25-test
    smoke suite (`scenario_snapshot_test.exs`) exercises every API path.
  - Full arena suite green at 4151 tests after all three GM migrations,
    bridge removal, and snapshot tooling landed.

- **Golden fixture expansion and effects cleanup closure (2026-05-09):**
  - Added `gamble_golden_test.exs` with deterministic win/loss coverage and
    all reachable gamble-handler branches pinned through the scenario DSL.
  - Added `potions_golden_test.exs` covering every `tipo_pocion` branch:
    HP, mana, stamina, strength, agility, poison cure, paralysis cure,
    unknown potion handling, duration stacking, and `tick(:buff)` expiry.
  - Migrated `Arena.Map.Bank` and `Arena.Map.Banking` to the effects
    contract, converting bank open/deposit/withdraw/gold handlers away from
    the legacy `{:send_raw, _}` lane.
  - Migrated `Arena.Map.Trade` entry points to the effects contract while
    preserving two-player flow semantics and the existing persistence path.
  - Added `bank_golden_test.exs` with DB-backed bank scenarios for banker
    selection/range, item and gold deposit/withdraw, stack caps, full-bank
    rollback, and rejection of untradeable or gold-as-item cases.
  - Added `trade_golden_test.exs` covering initiation, rejection/cancel,
    item offers, slot updates, both-player effects, and documented current
    handler divergences for destructive reject, missing gold-offer setter,
    Commerce-owned initiate guards, and commit coverage split.
  - Closed the effects cleanup pass: bank, banking, and trade joined the
    migrated producer set, `SEND_RAW_AUDIT.md` was updated, and
    `effects_send_raw_guard_test.exs` now prevents `{:send_raw, _}`
    regressions across the migrated map modules.
  - Full arena suite is green at 4070 tests after the bank and trade golden
    fixture expansion.

- **Phase 1 parity harness and effects-migration closure (2026-05-09):**
  - Deterministic scenario harness and gameplay-shaped DSL are now in active
    use for golden fixtures. Scenario ticks can record emitted effects from
    buff, regen, and NPC AI paths so tests assert with helpers such as
    `assert_effect/3` instead of mailbox timing.
  - Added the first high-drift golden gameplay fixtures:
    `healing_golden_test.exs` covers rest, meditate, heal, and resurrect;
    `forgive_golden_test.exs` covers the `/PERDON` donation flow.
  - Completed the `StatusTicks` effects migration. `process_player_buffs/4`
    and `process_regen_tick/1` now return `{state, effects}` and emit
    canonical `Arena.Map.Effects.*` entries for status clears, poison,
    hunger/thirst, HP/mana/stamina updates, invisibility reveal, character
    change, and player-death side effects. `MapServer` accumulates those
    effects across players and runs them once at the tick boundary.
  - Completed NPC AI effect unification. `Arena.NpcAi.tick/1` now returns the
    same canonical map-layer effect shape as other producers; the separate
    `Arena.NpcAi.dispatch_effects/2` runner was removed, and pet despawn,
    NPC death, and player-death effects flow up through the tick accumulator.
  - Updated adjacent drift, potion, invisibility, hunger/thirst, timer clamp,
    NPC AI, and scenario tests for the unified effect-return shape. The full
    arena suite is green at 3939 tests after removing the now-dead
    `dispatch_effects/2` tests.

- **Browser product surface foundations (2026-05-02):**
  - Browser account/lobby basics are wired against real backend APIs:
    `/api/auth/session`, `/api/auth/login`, `/api/auth/register`,
    `/api/auth/logout`, `/api/characters`, and
    `/api/characters/:id/session`.
  - Browser character creation, listing, and launch-session credential
    endpoints are covered by backend API tests; the product shell calls those
    APIs through `client/src/product/api.ts`.
  - The browser product shell has a deterministic Playwright harness covering
    register, create character, and launch character.
  - Party, guild, and faction chat streams have client packet encoders,
    channel-aware log routing, and UI filters.
  - Saved reconnect/session-token UX, persisted settings, keybindings, map
    music, and sound-effect playback are already wired in the client.

- **Roadmap foundation cleanup (2026-05-02):**
  - Rewrote `ROADMAP.md` as a remaining-work plan with explicit phases,
    goals, tasks, and exit criteria.
  - Moved completed foundation work out of the roadmap so this changelog is
    the record for shipped work.
  - Removed stale README references to missing `SERVER_ROADMAP.md` and
    `CLIENT_ROADMAP.md`.

- **Effects refactor and outbound parity tail closed (2026-05-02):**
  - Effects refactor completed end-to-end across `Arena.Map.Healing`,
    `Arena.Map.NpcInteraction`, `Arena.Map.Social`,
    `Arena.Map.InventoryHandlers`, and `Arena.Map.CombatHandlers`.
  - Spell, death, criminal-status, XP, level, and loot helper paths now use
    the common effects return contract and runner pattern.
  - Public combat and spell handlers use the effects contracts
    `{:ok, state, reply, effects}` or `{:ok, state, effects}` for cast
    internals.
  - Known outbound parity tail now has encoder support and known call-site
    wiring for `blind_no_more`, `dumb_no_more`, `work_request_target`, and
    `stun_start`.
  - Remaining egress shim cleanup is intentionally deferred:
    `Helpers.break_invisibility/3`, `StatusTicks` reveal/hide expiry paths,
    and pet despawn dispatch still need alignment with the map-layer runner.

- **Autosave under Task.Supervisor (2026-04-25):**
  - `AoTcpGateway.AutosaveTaskSupervisor` added to the gateway supervision
    tree. `AutosaveWriter.start_write/3` now spawns DB writes via
    `Task.Supervisor.async_nolink/2` instead of a bare `spawn_monitor/1`.
  - Workers are unlinked from `AutosaveWriter` (a crash still surfaces as
    `{:DOWN, ...}` and clears `in_flight`) but linked to the task supervisor,
    so application shutdown gives in-flight writes the supervisor's grace
    window instead of being orphaned.
  - Result protocol switched from `send(parent, {:write_done, ...})` to the
    task's native return value (`{ref, {char_id, result, duration}}`),
    matching standard `async_nolink` semantics. Demonitor with `:flush` on
    completion suppresses the trailing `:DOWN` per OTP convention.
  - `terminate/2`'s `wait_in_flight` loop updated to the same shape; the
    10s shutdown drain is unchanged. Existing fault-injection tests
    (synthetic `{:DOWN, ...}`, in-flight retry of pending snapshot,
    cleanup_save_failed telemetry) continue to pass — 15/15 autosave tests
    green, no public API change.

- **Outbound backpressure foundation (2026-04-22):**
  - New `AoSession.Outbound` envelope (`:critical | :lossy | :coalesce`) with
    constructors `critical/1`, `lossy/1`, `coalesce/2`, `from_class/3`. Single
    producer API `AoSession.Egress.enqueue/2` posts `{:egress, %Outbound{}}`
    to the session pid.
  - New `AoSession.Egress` holds per-session bounded state (critical queue,
    coalesce map with oldest-update-first order, lossy ring). Flush order is
    critical → coalesce → lossy. Byte + depth budgets emit
    `{:disconnect, :critical_overflow, state}` on sustained overflow. Lossy
    and coalesce shed-counters are tracked for telemetry.
  - New `AoSession.PressureRegistry` (ETS-backed, O(1) reads, missing ⇒ `:ok`)
    exposes current per-session pressure level (`:ok | :warn | :critical`)
    for cheap producer-side checks. Registered under the ao_session
    supervisor.
  - New `AoProtocol.Classify.class_for/1` maps server packet IDs to
    `:critical | :lossy | :coalesce`. Lives in ao_protocol (zero deps) so
    both ao_session and arena can consume it without a cycle.
  - TCP (`AoTcpGateway.ClientHandler`) and WS (`AoTcpGateway.WsHandler`)
    session loops integrated: new `{:egress, %Outbound{}}` receive clause
    flushes in batches of 128 through a single `transport.send`; legacy
    `{:send_raw, _}` and `{:send_packet, _}` are kept as migration shims
    that wrap and classify via the packet-ID peek. One disconnect path
    now covers `:mailbox_overflow | :send_timeout | :critical_overflow`
    and always calls `PressureRegistry.clear/1`.
  - Canary producer migration: `Arena.Map.Visibility` (`hide_from_non_gm`,
    `reveal_to_non_gm`, `enter_visibility`, `remove_from_visibility`,
    `update_visible_set_on_move`) now emits through
    `Helpers.send_outbound/3` / `Egress.enqueue/2`. Arena xref excludes
    extended for `AoSession.Egress` and `AoSession.Outbound`
    (arena still must not compile-depend on ao_session).
  - Telemetry: `[:arena, :session, :backpressure]` fires on pressure level
    transitions and disconnects. Measurements include `queued_bytes`,
    `critical_depth`, `lossy_depth`, `coalesce_size`, `dropped_lossy`,
    `dropped_coalesce_replaced`. Metadata includes
    `character_id`, `transport`, `action`, `cause`, `level`, `prev_level`.
  - Tests: 4 `Outbound`, 16 `Egress`, 4 `PressureRegistry`, 20 `Classify`.
    Visibility-slice suites updated to accept both `{:send_raw, _}` and
    `{:egress, %{payload: _}}` shapes during the migration.

- **VB6 parity drift closures (2026-04-21):**
  - **Drift #1** — GM panel request flow. Added client packet 116
    (`gm_panel_request`) decoder, `:gm`-group route, and handler that responds
    via the existing `:show_gm_panel_form` encoder.
  - **Drift #2** — NPC melee poison 30% roll. Gated `npc_ai.ex` poison
    application on `:rand.uniform(100) < 30` per `MODULO_NPCs.bas:780-794`.
  - **Drift #3** — Binary duel packets. Added `:duel` / `:accept_duel` /
    `:cancel_duel` / `:quit_duel` decoders, routes, and a new
    `SessionCommands.Duel` module. Extended `Arena.DuelServer` to carry
    `pociones_maximas` and `caen_items` end-to-end (missing from the text
    `/RETO` path).
  - **Drift #4** — Council-rank faction messages. `/RMSG` and `/CMSG` now
    bypass the GM gate for Royal/Chaos council members; non-council non-GM
    senders still rejected. Rewired `session_logic.ex`, `chat.ex`, and
    `gm_commands.ex`.
  - **Drift #5** — Inventory slots by patron tier.
    `Inventory.max_slots_for_tier/1` (24/30/36/42 for
    normal/adventurer/hero/legend), inventory resized at login, bank and
    commerce slot bounds now dynamic.
  - **Drift #6** — `@max_active_quests` 20 → 5 per `Declares.bas:1474`.
  - **Drift #7** — Commerce sell rejects items flagged `destruye`.
  - **Drift #8** — Trabajador sell-price discount: denom subtracts
    `level * 0.025` from `REDUCTOR_PRECIOVENTA` (clamped at 2).
  - **Drift #9** — Commerce sell blocks `:consejero` / `:semi_dios` tiers.
  - **Drift #10** — `/CHATCOLOR` + per-entity `chat_color`. Added packet 421
    decoder, GM-gated handler, role/council defaults
    (`PlayerEntity.default_chat_color/2`), and threading into chat-over-head
    broadcasts.
  - **Drift #11** — Skill-up formula rewrite. Replaced flat 35% with VB6
    quadratic `Prob = Int(0.1 * Lvl^2 + 15)`, added hunger gate, per-level
    cap, and `5 * xp_mult` XP bonus side effect.
  - **Drift #12** — Royal Army class gate narrowed from 4 classes to `:thief`
    only per `ModFacciones.bas:50-53`.
  - **Drift #13** — Chaos Legion now rejects non-criminal Ciudadanos per
    `ModFacciones.bas:183-186`.
  - **Drift #14** — `MAX_FACTION_ENLISTMENTS = 0` guard on both enlist paths.
  - **Drift #15** — Full `VolverCriminal` port. New
    `Arena.Map.CriminalStatus` honours trigger-6 safe tiles, resets
    `faction_score` on Ciudadano→Criminal, warps criminals out of NoPKs maps
    to `MapInfo.Salida`, and disbands parties.
  - **Drift #16** — HP potion DivineBlood gate + SelfHealingBonus multiplier.
    Added `divine_blood` and `self_healing_bonus` fields on `PlayerEntity`;
    `apply_potion` for `tipo_pocion == 1` rejects under DivineBlood and
    multiplies the roll by `max(1 + bonus, 0)`.
  - **Drift #17** — Mana potion now restores
    `div(max_mana * item_def.porcentaje, 100)` per `InvUsuario.bas:1946-1956`.
  - **Drift #18** — Str/Agi potion duration + cap. Added `str_backup` /
    `agi_backup` / `duracion_efecto` / `tomo_pocion` fields and
    `str_potion_delta` / `agi_potion_delta` trackers. Clamps at
    `backup * 2`; `StatusTicks.tick_potion_duration/1` runs at the existing
    1 s `:buff_tick` cadence and restores the attribute on expiry.
  - **Drift #19** (partial) — Six missing outbound encoders added:
    `:paralize_ok`, `:blind_no_more`, `:dumb_no_more`, `:rest_ok`,
    `:work_request_target`, `:stun_start`. Wired `:paralize_ok` (inventory
    cure + buff-expiry in `StatusTicks`) and `:rest_ok` (/DESCANSAR). The
    other four await their flag subsystems — ticket remains open in
    `drift.md` scoped to the missing wiring.

- **Final backend parity sweep + tooling cleanup (2026-04-19):**
  - Closed the late-stage parity sweep that landed after the Phase 2/3 roadmap
    closures: core combat/spell/leveling formulas, trade/drop/bank item-rule
    gaps, quest handler bugs, healing/gambling/`/PERDON` behavior, packet
    semantics for `eInformation` and `eQuest`, selected-NPC targeting for
    trainer/gamble/priest flows, `Ocultarse`, taming, pet commands, GM/SOS
    support behavior, treasure NPC events, duel rooms, trainer creature spawn,
    and selected-banker gold transfer.
  - Added the structural parity helpers that make future audits cheaper:
    canonical `vb6_distancia`, explicit selected-vs-nearby NPC resolution,
    expanded `SessionRouteManifest` coverage, `mix parity.audit`, and the
    `NpcInteraction` split into smaller domain modules.

- **Crafting trigger-model parity (2026-04-19):**
  - Blacksmithing no longer depends on workstation NPCs. Using the equipped
    smith hammer now requires a selected anvil/forge object target, and
    blacksmith craft requests revalidate that object target before consuming
    materials.
  - Carpentry, alchemy, and tailoring no longer require nearby workstation
    NPCs. Their forms now open from equipped working-tool use, and the craft
    requests themselves revalidate the correct tool instead of NPC proximity.
  - Production `work` packets no longer act as a shortcut trigger for those
    production skills; the trigger path now matches the old VB6 tool/object
    model instead of the later NPC-workstation shortcut.
  - Updated crafting route metadata from intentional divergence to exact parity,
    added regression coverage in `crafting_test.exs` and
    `crafting_bank_train_drift_test.exs`, and cleared the last confirmed item
    from `drift.md`.

- **`/HOGAR` tiered timer parity + account patron tiers (2026-04-19):**
  - Added legacy `accounts.is_active_patron` support to the backend account
    schema and mapped the old VB6 patron ids to online user tiers
    (`normal/adventurer/hero/legend`).
  - Login now injects the account tier into `PlayerEntity`, and
    `character_create_packet` now populates the AO20 `tipo_usuario` field from
    that online tier instead of always dropping it.
  - `/HOGAR` no longer treats all non-GM players the same: it now selects the
    travel delay from runtime-configurable per-tier buckets
    (`gm/normal/adventurer/hero/legend`) instead of only `GM 5s / everyone 10s`.
  - Added focused tests in `hogar_drift_test.exs`, `account_test.exs`, and
    `user_tier_packet_test.exs`.

- **Phase 3 proof tests — ROADMAP #23-29 closed (2026-04-19):**
  - **Pet/taming parity** (#26): 35 tests — stat inheritance from NPC def, attack
    damage formula, adjacent-only range, aggro range, death handling (no XP, no
    respawn, pet_ids cleanup), taming edge cases (stamina cost, skill-up on
    success and failure, max 3 pets), mode commands, /LIBERAR order.
  - **Concurrent combat** (#27): 13 integration tests — AoE spell hitting 3+
    targets with state consistency, AoE killing mid-iteration, mutual lethal PvP,
    three-way combat deaths, party safe blocking, faction PvP safe-zone exception,
    spell cooldown isolation, mixed melee+spell attacker types.
  - **Lifecycle expansion** (#28): 14 tests — autosave coalescing under rapid
    changes, multi-map A→B→C transfer chains, cleanup DB failure, flush timeout,
    worker crash recovery, stale autosave ordering, graceful-disconnect final-save
    failure.
  - **Persistence coverage** (#29): 38 tests — faction membership/score/rank/kill
    counters round-trip through save_snapshot/to_entity, account ban/unban, character
    muted_until, GM /BAN and /MUTE paths, expiration edge cases.
  - **Pre-existing test fixes**: 10 failures fixed across 6 files (missing
    commerce_npc_instance_id, Ecto Sandbox setup, Registry cleanup race, ranking
    pagination). Full suite now 0 failures.

- **Event systems: capture, siege, rewards, scheduler — ROADMAP #15-18 closed (2026-04-19):**
  - **Capture events** (#15): `Arena.Events.CaptureServer` GenServer — team-based flag
    capture with registration validation (level/gold/state checks), level-balanced
    team assignment, round progression (best-of-N), escalating death timers, flag
    pickup/hold-to-capture/drop-on-death mechanics, registration retry with extension.
    62 tests in `capture_server_test.exs`.
  - **Siege events** (#16): `Arena.Events.SiegeServer` GenServer — wall HP objective,
    configurable spawn boxes with wave spawning, max NPC limits, top-10 scoreboard
    with sorted insertion, defender/attacker win conditions, duration timeout,
    GM commands (start/stop/status/list). 51 tests in `siege_server_test.exs`.
  - **Event rewards + validation** (#17): `Arena.Events.Rewards` pure module —
    capture (entry_fee * 2 to winners), siege (50K * gold_mult to top-10 defenders),
    tournament (configurable prize pool split). `Arena.Events.ParticipantValidation`
    with 11-point registration checks (level, gold, dead, jailed, trading, navigating,
    mounted, meditating, resting, in_commerce, already_registered). 40 tests across
    `event_rewards_test.exs` and `participant_validation_test.exs`.
  - **Event scheduler** (#18): `Arena.Events.EventScheduler` GenServer — 24 hourly
    slots, auto-start on hour match, duration tracking with auto-cleanup, manual
    override via `force_event/2`, injectable clock function for deterministic testing.
    34 tests in `event_scheduler_test.exs`.

- **GM commands + stub fixes + ROADMAP #12-14, #19-21 closed (2026-04-19):**
  - **GM target locked to VB6 parity** (#12): tiered text commands over both TCP
    and WS. 4-tier hierarchy (admin > dios > semi_dios > consejero) preserved.
  - **14 new GM commands** (#13): /ONLINE, /WHERECHAR, /IPCHAR, /SYSTEMINFO,
    /RAIN, /SETBODY, /SETHEAD, /SETSKIN, /SETGOLD, /SETLEVEL, /SETSKILL,
    /KICKALLCHARS, /UNBAN, /SPAWN. 42 tests in `gm_commands_parity_test.exs`.
  - **No dead GM stubs** (#14): audit found all existing GM functions implemented.
  - **AO20 binary scope resolved** (#19): no AO20-only binary client→server
    packets exist. Account/lobby is REST, already implemented.
  - **Stub fixes** (#20-21): `server_open_toggle` now toggles
    `Arena.Settings.server_open`; `warp_me_to_target` now teleports GM to
    target. Remaining stubs documented as intentional no-ops. 15 tests in
    `parity_stub_handlers_test.exs`.

- **Backend parity: bank guards, NPC AI, spells, rewards, timbero, guild relations (2026-04-19):**
  - **Bank-open guards**: meditating, navigating, and paralyzed players can no
    longer open the bank (VB6 parity). 4 tests in `bank_guards_parity_test.exs`.
  - **NPC AI parity**: NPC melee poison (`veneno` field), diagonal movement, and
    Chebyshev distance for target selection. 8 tests in
    `npc_ai_parity_test.exs`.
  - **Spell target validation**: spell `target` field (1=user, 2=NPC, 3=both,
    4=terrain) now enforced before mana is consumed. Casting breaks
    meditation/rest. 9 tests in `spell_selection_parity_test.exs`.
  - **/REWARD NPC flow**: players can now claim faction rank-up rewards from
    enlistador NPCs. Validates level, score, max rank, and enlistador faction
    side (VB6: Protocol.bas:4618). Grants items to inventory. 14 tests in
    `reward_npc_parity_test.exs`.
  - **Timbero account-state**: fixed wrong "Ganancias" computation (was
    subtracting counters), now shows wins/losses/plays separately. Gamble
    messages use `npc_def.name` instead of hardcoded "Timbero". 2 tests in
    `npc_text_parity_test.exs`.
  - **Guild relation stubs**: wired `/PROPONERPAZ` and `/ALIANZA` text commands
    and binary `guild_offer_peace`/`guild_offer_alliance` packet handlers to
    GuildServer. Added idempotency guards to war declaration and
    conflict/duplicate checks to alliance proposals. Accept/reject/details/
    prop_list handlers remain disabled (Phase 8 — full proposal queue flow).
    26 tests in `guild_relations_parity_test.exs`.

- **Commerce double-click fix + walk-away session cleanup (2026-04-19):**
  - **Commerce on NPC double-click**: double-clicking a merchant NPC now opens
    the commerce window directly instead of casting to a nonexistent internal
    handler. Calls `Commerce.open_npc_commerce/4` inline from
    `NpcInteraction.handle_npc_double_click/4`.
  - **Walk-away session cleanup**: moving away from a commerce NPC (> 3 tiles)
    or a banker NPC (> 6 tiles) now auto-closes the session and sends the
    appropriate `commerce_end` / `bank_end` packet to the client.
    `Movement.check_npc_session_proximity/2` runs after every successful move.
    Handles NPC despawn (nil lookup) by closing the session.
  - 7 tests in `walk_away_parity_test.exs`.

- **Invisibility visibility layer fix + equipped item sell block (2026-04-18):**
  - **Invisibility visibility**: invisible players are now hidden from
    non-GM clients at the broadcast/visibility layer. `enter_visibility`,
    movement broadcasts, AoI enter/leave, heading changes, and invis/oculto
    on/off transitions all filter invisible entities from non-GM recipients.
    GMs see invisible players normally. Combat resolution unchanged — blind
    melee, arrows, and spells aimed at the correct tile still connect.
    `break_invisibility` now internally calls `reveal_to_non_gm`. Buff and
    oculto timer expiry also trigger reveal. 7 new tests in
    `invisibility_visibility_test.exs`.
  - **Equipped item sell block**: selling an equipped item now returns
    `{:error, :equipped_item}` with console message instead of silently
    vendoring from equipped state. VB6 parity. Test in
    `merchant_session_authority_test.exs`.
  - **Comprehensive 5-agent parity audit**: audited merchant/timbero,
    interaction radius/bank, NPC AI/invisibility, service
    windows/punishments/rewards, GM commands/events/unknown drift.

- **Roadmap closures moved out of `ROADMAP.md` (2026-04-18):**
  - **Known red suites back to green:** `SpellAuthority`,
    `MerchantSession`, `SelectedNpcAccountReward`, `ChatAuthority`,
    `SupportRequestRateLimit`, and `SessionLifecycle` now pass again, so new
    parity work starts from a clean baseline instead of a branch with known red
    regressions.
  - **Trade-start parity:** added the missing safe-zone trade block and the
    accept-time revalidation that rejects execution if the peer is no longer a
    valid nearby trade target.
  - **Guild invite/request authority under real DB-backed flows:** invite
    and request revalidation, DB-failure handling, and the remaining
    request-membership/list-requests semantics are now covered by the committed
    guild hardening work and DB-backed authority tests instead of synthetic
    happy-path checks.
  - **`leave_faction` parity:** leaving faction now requires the correct
    enlistador for the player faction and rejects aligned-guild cases that VB6
    also blocked.
  - **Selected-NPC authority for account-state/reward flows:** account-state
    and reward requests now bind to the actual clicked NPC instance instead of
    any nearby NPC of the same type; stale, spoofed, mismatched, and out-of-
    range selection cases are rejected by adversarial coverage.
  - **Merchant/account-state parity (partial):** merchant sessions are bound
    to the original merchant instance, and equipped items are now rejected on
    sell instead of being vendored directly from equipped state. Remaining old
    merchant item rules and timbero text/value semantics stay in the roadmap.
  - **Map-transfer/reconnect parity:** transfer no longer ignores
    `MapServer.leave/2`, clears transfer-sensitive transient state, cancels
    hogar timing on tile exit, and updates online-directory state in the safer
    order needed to avoid ghost/orphaned sessions.
  - **Sync-first persistence closure:** guild, bank, and trade all now
    commit through explicit DB-first or atomic sync boundaries; autosave is
    bounded and observable instead of a naked background write path; cleanup
    remains explicit best-effort with telemetry instead of pretending to be a
    stronger durability guarantee than it is.
  - **Graceful host shutdown closure:** coordinated shutdown drain now runs
    from `prep_stop/1`, stops listeners, rejects new commands after drain
    starts, drains active sessions, and waits for in-flight plus pending
    autosave work according to the documented must-finish / best-effort /
    may-drop contract.
  - **Guild/party chat moderation:** guild chat now enforces mute/dead
    checks across both packet and text-command paths, and party chat now
    enforces mute plus cooldown behavior.
  - **Support request throttling:** `question_gm` and
    `role_master_request` now share an ETS-backed per-character cooldown so
    burst spam is rejected instead of broadcast to operators.

- **Guild DB-failure semantics and cleanup policy (2026-04-18):**
  - Fixed `request_membership`: DB failure now returns `:db_error` instead of
    masquerading as `:already_requested`. Uses `has_unique_constraint_error?/1`
    to distinguish genuine duplicate from DB outage.
  - Fixed `list_requests`: DB failure now returns `{:error, :db_error}` instead
    of silently returning an empty list.
  - Documented cleanup/logout final-save policy: accepted best-effort under DB
    failure. Authoritative writes (trade, bank, guild) are the true commit
    boundaries; cleanup save is the soft-state catch-all.
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
