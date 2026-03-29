# Argentum Online: Web Client Roadmap

## Current State

**Two clients exist:**

- **`test_client.html`** (~1,500 lines JS) — single-file debug client in `apps/ao_tcp_gateway/priv/static/`. Has sprite rendering, character compositing, 4 map layers, MIDI music, walk animations, client-side prediction. Served by the game server on port 7667. Good for protocol testing, not a real client.

- **`client/`** (~4,800 lines TypeScript) — Vite + React + Pixi.js standalone app. Has packet encode/decode, WebSocket session management, state reducer, inventory/HUD/chat UI panels, map data fetching, asset catalog, and music. Served separately on port 5173 via `make client.dev`. This is where the serious client grows.

**Status legend:**
- `Done` — implemented and working
- `Partially done` — groundwork exists, not complete
- `Missing` — not started

**Phase snapshot:**
- `Foundation — Rendering & Assets`: `Partially done`
- `Foundation — Login & Session`: `Partially done`
- `Phase 1 — Map Transitions`: `Partially done`
- `Phase 2 — Inventory & Equipment`: `Partially done`
- `Phase 3 — Combat Feedback`: `Missing`
- `Phase 4 — Spell UI`: `Missing`
- `Phase 5 — NPC Interaction`: `Missing`
- `Phase 6 — Commerce & Bank`: `Missing`
- `Phase 7 — Crafting`: `Missing`
- `Phase 8 — Social`: `Missing`
- `Phase 9 — Stats & Progression`: `Missing`
- `Phase 10 — Polish & Settings`: `Missing`

**Tech stack:** Vite 5.4 + TypeScript 5.6 (strict) + React 18 + Pixi.js 7.4

**VB6 client:** ~103,000 lines across 197 files. ~85% is reinventing what the browser gives for free (DirectX 8 rendering, Winsock networking, custom UI framework, audio device management, file parsers). The game-specific logic is ~15,000 lines.

---

## Constraints

- **The AO20 binary protocol stays the contract.** The web client talks to the same server using the same packet IDs, field order, and byte layout as the VB6 client, just over WebSocket instead of raw TCP.
- **The server is authoritative.** The client renders state and sends intents; it does not compute gameplay truth for movement, combat, inventory, or NPC interaction.
- **Web auth is a bootstrap layer, not a different game protocol.** If the browser uses username/password, that flow must end by obtaining the same character identity / session credentials needed to start the AO20 session.
- **The web client is the primary development client.** The VB6 client remains the protocol compatibility reference, but the web client is where players will actually play.

---

## Architecture

```
client/src/
├── app/           # App shell, state reducer, types
├── net/           # WebSocket session client, map API
├── protocol/      # Binary packet encode/decode
├── render/        # Pixi.js world renderer, asset catalog
├── ui/            # React UI panels
├── audio/         # Music playback
├── game/          # Client-side game logic (empty — reserved)
└── debug/         # Debug tools (empty — reserved)
```

**Data flow:** User input → React → SessionClient → binary encode → WebSocket → server → WebSocket → binary decode → appReducer dispatch → React re-render + Pixi update.

**State management:** Redux-style `useReducer` with `ClientState` containing connection, world, stats, inventory, and log sections.

---

## Foundation — Rendering & Assets

**Status:** `Partially done`

**In code now:**
- Pixi.js world viewport (736x608, 32px tiles)
- Asset catalog with GRH index loading
- Map data fetch from REST API
- Player rendered as green circle, others as orange squares
- Map music playback

**Still missing:**
- Sprite atlas / spritesheet loading from `resources/graficos/` and `resources/graficos_char/`
- Tile rendering from map layer data (4 layers: ground, below-chars, above-chars, roofs)
- Character compositing: body + head + weapon + shield + helmet sprites, directional facing
- Walk cycle animations (interpolated movement between tiles)
- NPC sprite rendering from NPC index definitions
- Ground object rendering from object index definitions
- Chat bubble rendering (text floating above characters)
- Camera follow with smooth scrolling

**Server dependency:** None — uses existing map API and static asset files.

**Difficulty:** Hard — this is the biggest single piece. Without it the client is colored squares.
**Estimate:** ~2,000 lines

---

## Foundation — Login & Session

**Status:** `Partially done`

**In code now:**
- Session token persistence in localStorage
- Reconnect with saved session (packet 73)
- Create new character (packet 74)
- SessionPanel with connect/disconnect and name input

**Still missing:**
- Login screen: proper full-screen UI with character name, connect button, server status indicator, error display
- Character creation screen: race/class selector with preview sprite, head selector, home city picker, stat display, confirm button
- Character selection: if account has multiple characters, pick which one to play
- Loading screen: asset download progress bar on first load
- Connection lost overlay: reconnect prompt, not just a log entry
- Error handling: server-full, banned, maintenance messages

**Server dependency:** Phase 13 (Auth & Account System) for real authentication. Works without it using the current simplified auth.

**Difficulty:** Medium
**Estimate:** ~800 lines

---

## Phase 1 — Map Transitions

**Status:** `Partially done`

**In code now:**
- Map data fetched on `change_map` packet
- Basic scene swap on map change

**Still missing:**
- Prepacked binary map bundle downloaded at boot (replaces per-transition JSON fetch)
- Map cache: decoded map data kept for the full session, not re-fetched
- Static Pixi scene reuse: build map layers once, swap containers on transition instead of rebuilding
- Transfer state machine: suppress stale source-map corrections, don't resume prediction until destination confirmed
- Visual continuity: no black frame, no flash, optional fade

**Server dependency:** Phase 2A (server-side map bundle generation endpoint).

**Difficulty:** Medium — architecture-heavy, not much UI
**Estimate:** ~1,000 lines

---

## Phase 2 — Inventory & Equipment

**Status:** `Partially done`

**In code now:**
- 24-slot inventory grid with item display
- Slot selection, equip/use/drop buttons
- Detail card showing item ID, amount, equipped status, value
- Inventory state in reducer from `change_inventory_slot` packets

**Still missing:**
- Item sprites from GRH index (currently shows item ID numbers)
- Drag and drop: reorder slots, drop to ground, equip by dragging to equipment panel
- Right-click context menu: use, equip, drop, info
- Equipment panel: visual body silhouette with head/body/weapon/shield slots showing equipped item sprites
- Item tooltips: name, stats, restrictions, value on hover
- Stack amount overlay on item sprites
- Gold display integration with inventory panel

**Server dependency:** Phase 4 remaining (equip restrictions, stat recomputation).

**Difficulty:** Medium (drag-drop is the most complex UI piece)
**Estimate:** ~600 lines

---

## Phase 3 — Combat Feedback

**Status:** `Missing`

**What to build:**
- Damage numbers: float up from target position, color-coded (red=damage, green=heal, gray=miss, blue=block)
- HP bars on other players/NPCs (small bar above sprite)
- Hit/miss/block sound effects
- Attack animation: weapon swing sprite overlay
- Death overlay: "You have died" full-screen with respawn button
- XP bar in HUD with flash on gain
- Combat log entries in chat panel

**Server dependency:** Phase 5 (Combat) — needs attack/damage/death/XP packets.

**Difficulty:** Medium
**Estimate:** ~800 lines

---

## Phase 4 — Spell UI

**Status:** `Missing`

**What to build:**
- Spell book panel: list of known spells with icons, mana cost, cooldown, description
- Spell hotbar: 10 slots (F1-F10 or 1-0), drag spells from book to bar
- Cast targeting: click target after selecting spell, range indicator circle
- Spell FX: particle effects or flash overlay on cast and impact
- Buff/debuff icons: small icons near HP bar with remaining duration tooltip
- Meditation visual: sitting animation, mana regen indicator

**Server dependency:** Phase 6 (Spells) — needs cast/buff/debuff/spell-list packets.

**Difficulty:** Medium
**Estimate:** ~700 lines

---

## Phase 5 — NPC Interaction

**Status:** `Missing`

**What to build:**
- NPC name labels: floating text above NPC sprites (different color from players)
- NPC dialogue window: modal panel with NPC name, text, response options
- Shop window: item grid with prices, buy/sell buttons, quantity selector, gold display
- Quest dialogue: accept/decline buttons, objective display

**Server dependency:** Phase 7 (NPC AI) — needs NPC interaction/shop/quest packets.

**Difficulty:** Medium
**Estimate:** ~600 lines

---

## Phase 6 — Commerce & Bank

**Status:** `Missing`

**What to build:**
- Bank window: grid similar to inventory, deposit/withdraw by dragging between panels
- Trade window: two-panel view (yours / theirs), confirm/cancel buttons, lock mechanism before final accept
- Gold input: amount field for deposits/withdrawals/trades
- Price display: formatted gold amounts with separators

**Server dependency:** Phase 8 (Commerce & Banking) — needs shop/bank/trade packets.

**Difficulty:** Medium
**Estimate:** ~600 lines

---

## Phase 7 — Crafting

**Status:** `Missing`

**What to build:**
- Crafting panel: recipe list filtered by skill type, material requirements shown with have/need counts
- Craft button with progress indicator
- Success/fail feedback animation
- Skill gain notification

**Server dependency:** Phase 9 (Crafting & Gathering) — needs craft result/skill gain packets.

**Difficulty:** Easy
**Estimate:** ~300 lines

---

## Phase 8 — Social

**Status:** `Missing`

**What to build:**
- Chat tabs: general / whisper / party / guild / global, with unread indicators
- Whisper UI: `/w name message` command or click-to-whisper on player name
- Party panel: member list with HP bars, invite/kick/leave buttons
- Guild panel: member list with ranks, guild chat tab, guild info display
- Player context menu: right-click player name → whisper, invite to party, trade, info

**Server dependency:** Phase 10 (Social Systems) — needs whisper/party/guild packets.

**Difficulty:** Medium
**Estimate:** ~600 lines

---

## Phase 9 — Stats & Progression

**Status:** `Missing`

**What to build:**
- Stats panel: full character attributes (STR, AGI, INT, CON, CHA), class, race, level
- Skills panel: skill list with current values, training buttons, skill point counter
- Level-up celebration: FX/sound, stat increase summary
- Trainer NPC dialogue with skill purchase options

**Server dependency:** Phase 11 (Progression) — needs level-up/stat/skill packets.

**Difficulty:** Easy
**Estimate:** ~400 lines

---

## Phase 10 — Polish & Settings

**Status:** `Missing`

**What to build:**
- Minimap: small map overview with player dot, NPC/exit markers, toggle with M key
- Weather effects: rain/snow particle overlay (client-side, from map flags sent on enter)
- Sound effects: footsteps, combat sounds, UI clicks, ambient sounds
- Settings panel: music/sound volume sliders, key rebinding, graphics quality toggle
- Responsive layout: handle window resize, preserve viewport aspect ratio
- Loading/splash screen: first-load asset progress bar
- Error recovery: reconnection prompt overlay, session timeout handling

**Server dependency:** Phase 12 (World Rules) for weather data. Settings are client-only.

**Difficulty:** Easy-Medium
**Estimate:** ~800 lines

---

## Client ↔ Server Dependency Map

Each client phase is blocked by the corresponding server phase. Build server first, then client.

| Client Phase | Blocked by Server Phase | Key packets needed |
|---|---|---|
| Foundation — Rendering | None | Existing map API + static assets |
| Foundation — Login | Phase 13 (Auth) for real auth; works without it | Account/auth packets |
| Phase 1 — Transitions | Phase 2A (map bundle endpoint) | `change_map`, `pos_update` |
| Phase 2 — Inventory | Phase 4 remaining (equip restrictions) | `change_inventory_slot` |
| Phase 3 — Combat | **Phase 5 (Combat)** | Attack, damage, death, XP packets |
| Phase 4 — Spells | **Phase 6 (Spells)** | Cast, buff/debuff, spell list packets |
| Phase 5 — NPC | **Phase 7 (NPC AI)** | NPC interaction, shop, quest packets |
| Phase 6 — Commerce | **Phase 8 (Commerce)** | Shop, bank, trade packets |
| Phase 7 — Crafting | **Phase 9 (Crafting)** | Craft result, skill gain packets |
| Phase 8 — Social | **Phase 10 (Social)** | Whisper, party, guild packets |
| Phase 9 — Stats | **Phase 11 (Progression)** | Level-up, stat, skill packets |
| Phase 10 — Polish | Phase 12 (World Rules) for weather | Weather data on map enter |

**Bold** = hard blocker. The client foundation (rendering + login) can proceed independently of most server work.

---

## Timeline Summary

| Phase | Feature | Lines | Cumulative |
|-------|---------|------:|----------:|
| Done | Packets, session, reducer, basic UI panels, map fetch, music | 4,800 | 4,800 |
| Foundation — Rendering | Sprite atlas, tile rendering, character compositing, walk animations | 2,000 | 6,800 |
| Foundation — Login | Login screen, char creation, char selection, loading screen | 800 | 7,600 |
| 1 | Map transitions, binary map pack, scene cache | 1,000 | 8,600 |
| 2 | Inventory sprites, drag-drop, equipment panel, tooltips | 600 | 9,200 |
| 3 | Combat feedback, damage numbers, death screen, HP bars | 800 | 10,000 |
| 4 | Spell book, hotbar, cast targeting, buff icons | 700 | 10,700 |
| 5 | NPC dialogue, shop window, quest UI | 600 | 11,300 |
| 6 | Bank, trade windows | 600 | 11,900 |
| 7 | Crafting UI | 300 | 12,200 |
| 8 | Chat tabs, party/guild panels | 600 | 12,800 |
| 9 | Stats panel, skill training, level-up FX | 400 | 13,200 |
| 10 | Minimap, weather, sounds, settings, error recovery | 800 | 14,000 |

**~14,000 lines of TypeScript replacing ~103,000 lines of VB6 — a 7× reduction.**

The rendering foundation is the critical path — it unblocks everything visual. Combat feedback (Phase 3) is the next biggest piece after that and depends on server Phase 5.
