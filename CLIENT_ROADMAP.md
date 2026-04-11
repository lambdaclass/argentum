# Argentum Client Appendix

`ROADMAP.md` is the only roadmap. This file tracks client-specific reference
notes and browser product details.

## Current State

- **Serious client:** `client/` is a Vite + React + Pixi-style/canvas game
  client with ~15k LOC in `client/src`.
- **Debug client:** `server/apps/ao_tcp_gateway/priv/static/test_client.html`
  still exists for quick protocol/debug work.
- **Protocol constraint:** gameplay packets stay AO20-compatible. Browser-only
  auth/lobby work must end before normal AO socket gameplay begins.

## Status Snapshot

- `AO20 WebSocket session`: `Mostly done`
- `Map / terrain rendering`: `Done`
- `Character / NPC / item rendering`: `Mostly done`
- `Inventory / equipment UI`: `Done`
- `HUD / vitals / stats / skills`: `Mostly done`
- `Combat / spells`: `Mostly done`
- `Shop / bank / user trade`: `Mostly done`
- `Party / clan panels`: `Partially done`
- `Faction HUD / faction chat decode`: `Mostly done`
- `Weather`: `Partially done` — rain done, snow rendering open
- `Modern account + character lobby`: `Missing`
- `Browser E2E tests`: `Missing`

## Linear Client Plan

### 1. Keep protocol decode/encode locked to the server

- Keep client packet cases updated with `ao_protocol` encoder/decoder changes.
- Add browser-side packet fixture tests using the same VB6 `.bin` fixtures as
  the server parity suite.
- Keep WebSocket/session bootstrap isolated from gameplay bytes.

### 2. Close visible gameplay gaps

- Decode, dispatch, and render snow from `snow_toggle`.
- Render real trade item display from packet 100 fields: item ID, name, GRH,
  amount, elemental tags.
- Add clearer dead/ghost UX: HUD state, action-disabled affordances, resurrect
  instruction, remote ghost verification.
- Improve spell panel hints: cooldown, requirements, land/water/staff/dead
  target semantics, AoE/radius when the server exposes the data.
- Keep NPC sprite ID mappings checked by fixture/screenshot tests so skeleton,
  boar, wolf, ant, etc. do not drift again.

### 3. Make social UI authoritative

- Replace party/clan membership inferred from console text with authoritative
  snapshot packets or a documented HTTP/session snapshot.
- Show member online state, rank/role, faction/guild alignment, party safe
  state, leader/permissions when supported.
- Keep faction/guild/party chat visible as distinct chat streams instead of
  only generic log lines.

### 4. Build account login and character lobby

Post-compatibility product feature. See `ROADMAP.md`.

- Login with username/password.
- Login or link with Google.
- Restore account session.
- List characters owned by the account.
- Create a new character with race/class/head/home/stat choices.
- Select character.
- Request/rotate selected character session token.
- Connect to AO socket using `login_existing_char(char_id, session_token)`.
- Stop using socket `login_new_char` as the primary browser account flow.

### 5. Polish player experience

- Loading and reconnect overlays.
- Server-full / banned / muted / maintenance / token-expired error states.
- Settings: music, SFX, renderer quality, keybinds.
- Minimap and/or map markers if kept in the web UX.
- Sound effects for combat, spells, inventory, UI, doors/teleports, weather.
- Responsive layout pass for laptop, desktop, and common browser zoom levels.

## Client Test Plan

Create and run:

- TypeScript typecheck: `npm run typecheck`
- Production build: `npm run build`
- Packet fixture tests against captured VB6 packet bytes
- Decoder fuzz tests for malformed packet payloads
- Reducer/state tests for inventory, bank, trade, party, clan, weather, death,
  target selection, selected slot, selected spell, account/lobby once built
- Browser E2E smoke: account/lobby once built, connect, map render, player
  render, NPC render, inventory, shop, bank, trade, party, clan, chat, spells,
  death/ghost, weather, transfer, reload/reconnect
- Visual fixture test for common NPC/player bodies and equipment overlays

## Server Dependencies

- Account/lobby API: HTTP endpoints listed in `ROADMAP.md`
- Authoritative party/clan snapshots or packets
- Real per-instance `elemental_tags` before the client can render non-zero tags
- Snow toggle already exists server-side; client still needs rendering

## Finish Line

The web client is ready for private playtesting when a fresh browser can log in,
choose/create a character, enter the world, complete the smoke-bot player
journey, survive a browser reload/reconnect, and show no unknown packet or React
runtime errors during that journey.
