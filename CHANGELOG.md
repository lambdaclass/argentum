# Argentum Changelog

This file tracks completed work. `ROADMAP.md` tracks remaining work only.

## Recently Completed

- Client NPC body loading and bootstrap state handling fixed so NPC sprites use
  the full client body table instead of falling back to incorrect placeholder
  rendering.
- Arena social handlers split out of the former large `social.ex` module into
  focused chat, healing, pets, quests, faction, NPC interaction, GM command, and
  remaining social modules.
- `%Arena.Map.State{}` introduced for explicit map-state fields and compile-time
  key safety on the production map state path.
- Arena combat handlers split into focused combat dispatch, spell effects,
  player death, and status tick modules.
- MapServer routing cleanup grouped `deduct_gold` with the other map-server
  calls.
- Arena authoritative persistence and backend refactor research added in
  [research/arena-authoritative-persistence-and-refactor.md](research/arena-authoritative-persistence-and-refactor.md).
- Arena test fixtures migrated to a shared `%Arena.Map.State{}` factory path,
  replacing old partial raw-map fixtures and removing stale `floor_items` /
  `next_floor_id` test-state drift.
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
  [server/VB6_SMOKE_CHECKLIST.md](/Users/unbalancedparen/projects/argentum/server/VB6_SMOKE_CHECKLIST.md).
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
