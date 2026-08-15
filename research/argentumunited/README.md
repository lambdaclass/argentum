# Argentum United — reference notes

Screenshots and analysis of `play.argentumunited.com`, captured 2026-08-15
(their build 1367). Kept as a design and architecture reference for our own
client work.

Files:

- `game-ui.png` — the client window

**Scope note.** These are notes on layout, information architecture and
technical approach. Their sprite art and UI assets are theirs; the AO visual
heritage (dark wood panels, gold trim, the stat-bar stack) is common to every
Argentum Online client including ours. Take the structure, not the assets.

## Architecture, from their own feature page

- **Client written in Go**, UI rendered with "embedded HTML technology"
- **Native multiplatform** — Windows, Linux, macOS; Android/iOS "coming soon"
- **Browser build via WebAssembly** — no install
- **Shader visual effects**, real-time
- **Partial resource patching** — updates ship only changed assets
- **Multilanguage** — English, Spanish, Portuguese
- **3D positional sound**

Confirmed by inspecting the page: `wasm_exec.js` is verbatim the Go toolchain
shim ("Copyright 2018 The Go Authors"), loading `game.wasm` (~10 MB) served as
`application/wasm`. They verify it with an SRI-style hash (`_wasmHash`,
`_wasmIntegrity`, `_verifyWasmHash`), cache assets in IndexedDB under
`argentum-cache`, and run a service worker (`sw.js`) with a cache-first policy
for images and audio (`ui-assets-v1`). Rendering is WebGL2.

Our `client-rs` (Bevy/Rust → wasm + native) is the same bet in a different
language: one codebase, browser and desktop.

## Layout

Roughly 1290x780 in the capture. Two columns: world viewport on the left,
fixed sidebar (~290px) on the right, hotbar along the bottom of the viewport.

**Title bar** — crest, `Argentum United [build 1367]`, then a live telemetry
row: `SUPPORT` button, `FPS 184`, `PING 9ms`, `ON 566` (players online), a
language globe, screenshot camera, mute, a combat toggle, settings, config, and
window controls.

Worth noting: they put **the build number in the title and FPS/ping/online in
the chrome**. Independent confirmation that the build stamp we added is the
right instinct — and the ping/online counters are cheap trust signals.

**World viewport** — full-bleed, no border. Chat renders as coloured text
overlaid on the world, top-left (others in red, self in blue). The minimap sits
as an overlay in the top-right corner of the *world*, not the sidebar, with
coordinates (`672, 355`) beneath it in gold.

**Event banner** — a dismissible gold-bordered pill centred over the world:
"Happy hour: 1.5x experience and 1.2x gold!" with a countdown and an X.

**Sidebar**, top to bottom:

1. Character name in large gold, class and level under it (`Cleric Level: 1`)
2. XP bar with `0 / 500`
3. In-game clock (`18:30`)
4. `Inventory` / `Spells` tabs
5. 6-column item grid. Equipped items carry a small `E`; slots beyond the
   unlocked count show a **gold padlock** rather than being hidden — the
   upsell is visible but not obnoxious
6. Selected-item detail panel: name, description, and a trash button
7. Active buffs as icons with remaining time (`+50%`, `+20%`, `16m`)
8. A compact stat row with icons (`1/3`, `0/0`, `1/1`, `1/2`)
9. Currency row: gold, and two carried-weight style counters
10. Status bars, each labelled with its numbers inside the bar:
    `HP: 20/20` (red), `Mana: 45/45` (blue), `Sta: 60/80` (yellow), then
    hunger (green) and thirst (cyan) as `75/100`
11. A row of ~10 small action buttons (quests, map, party, clan, etc.)

**Hotbar** — numbered 1–0 along the bottom of the viewport with a `>` expander
for further pages.

## Palette

| role | approx |
| --- | --- |
| panel background | `#1a1410` very dark warm brown |
| panel edge | `#3a2c1e` |
| accent / headings | `#d4a24c` gold |
| body text | `#e8dcc4` cream |
| HP | red | 
| Mana | blue |
| Stamina | yellow |
| Hunger | green |
| Thirst | cyan |

## What is worth taking

1. **Numbers inside the bars.** `HP: 20/20` printed on the bar itself, not
   beside it. Readable at a glance, no extra row.
2. **Locked slots shown, not hidden.** Communicates progression and the
   subscription tiers without a separate screen.
3. **Telemetry in the chrome.** FPS, ping and online count always visible.
4. **Chat over the world.** Saves vertical space; the sidebar stays for state.
5. **Minimap as a world overlay**, not a sidebar panel.
6. **Dismissible event banner** for time-limited server events.
7. **Service worker + IndexedDB asset cache.** We have neither; every session
   currently refetches sprites. This is the cheapest real win on the list.
8. **Partial resource patching** — only changed assets are downloaded.
