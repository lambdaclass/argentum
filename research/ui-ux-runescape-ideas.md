# UI/UX Ideas Inspired by RuneScape & RuneLite

Research notes for Argentum Online's web client, drawn from RuneScape (OSRS/RS2 era) and RuneLite (the open-source OSRS client with 120+ built-in plugins and 1000+ community plugins).

The core insight from RuneLite: **the vanilla game client shows you the minimum, and players want the maximum**. Every popular RuneLite feature follows the same pattern — take hidden game state and make it visible on screen. Once the server sends a piece of data (HP, item value, XP gain, buff duration), the client should have a way to display it persistently and prominently, not buried in a tab.

---

## Tier 1 — Build into the core client now

### Right-click context menus on world entities

RuneScape's signature interaction. Right-click any NPC, player, or ground item and get a stacked menu: *Talk-to*, *Attack*, *Trade*, *Examine*, *Follow*. Left-click performs the default action.

Currently Argentum has right-click only on inventory slots. Adding world-entity context menus would:
- Replace the "Pick Up" button in the chat panel with a natural in-world action
- Give a single interaction model that scales to NPCs, shops, doors, signs
- Stack future features (Trade, Follow, Party invite) without new UI panels

Implementation: on right-click, raycast the Pixi tile to find entities at that position, render a small absolute-positioned `<div>` menu over the canvas.

### Menu entry swapper (smart left-click defaults)

RuneLite's single most-used plugin. The idea: left-click does the *most common* action, not the first one. Left-click a banker opens the bank (not "Talk-to"), left-click a ground item picks it up, left-click an NPC with a shop opens the shop.

Implement as a priority table in the right-click context menu system — whichever action has highest priority becomes the left-click default.

### Ground item labels with value tiers

RuneLite's #1 QoL feature. Floating text above ground items, color-coded by value:
- White: common/low value
- Green: medium value
- Blue: high value
- Purple: rare
- Gold: extremely valuable

Items below a configurable threshold are hidden entirely. Add a despawn timer countdown next to the label. Lootbeams (vertical light effect) on high-value drops.

Implementation: purely a Pixi text rendering task on top of existing sprites.

### Opponent info widget

A small floating panel during combat showing: target name, HP bar (current/max), level. RuneLite renders this near the target or as a fixed overlay.

For AO: render as a Pixi container anchored above the target sprite. Needed the moment combat works.

### Interact highlight (hover glow)

When the mouse hovers over an NPC, player, or object, it gets a colored outline or brightened sprite. Gives immediate feedback about what would be clicked.

Implementation: in Pixi, apply a `ColorMatrixFilter` or `OutlineFilter` on hover. Cheap, huge usability win for a tile-based game where multiple entities can overlap.

### Status bars near the character

RuneLite draws HP/prayer bars next to the character sprite, always visible without checking the UI panel.

For AO: render a small HP bar (and optionally mana) directly above the player's sprite in the Pixi scene. Toggle-able in settings. Replaces the need to constantly glance at the sidebar.

### Status orbs near the minimap

RuneScape shows HP, Prayer, and Run energy as small circular orbs near the minimap — always visible without opening a tab.

Add 3 small circular indicators (HP/Mana/Stamina) as overlays on the game canvas near the minimap. Show fill level by color and flash when low.

### Chat with channels and visible history

RuneScape's chat box is the bottom ~25% of the screen with tabs: All, Game, Public, Private, Clan, Trade. Messages scroll up.

Add:
- A fixed chat area at the bottom of the game viewport (not in the sidebar)
- Tab filters: All / System / Chat / Combat
- Auto-scroll with a "scroll lock" toggle
- Semi-transparent background so the world is still visible underneath
- `/whisper player message` syntax for private messages
- Timestamps on every message (from RuneLite)
- Persist history to localStorage across sessions (last 500 messages)

### Equipment paperdoll tab

RuneScape's equipment screen shows a character silhouette with clickable slots (head, body, legs, feet, weapon, shield, ring, amulet, cape).

Add a dedicated tab showing:
- A simple body outline with slot positions
- Click a slot to unequip
- Hover for stat bonuses
- Total attack/defense summary at the bottom

Argentum already tracks 5 equipment slots in data — this is purely a UI addition.

---

## Tier 2 — Build before or during Phase 3

### Tile markers (persistent)

RuneLite: Shift+right-click a tile to mark it with a custom color and optional label. Marks persist across sessions.

Useful for: safe spots during boss fights, remembering NPC locations, marking paths.

Implementation: store `Map<string, {color, label}>` keyed by `mapId:x:y` in localStorage, render colored rectangles under the tile layer in Pixi.

### Notification system (idle + low HP + loot)

RuneLite alerts players via sound, screen flash, or system notification when: HP drops below threshold, character goes idle, a valuable item drops.

For the web client:
- Web Notifications API for system-level alerts
- Screen border flash effect (red vignette on low HP)
- Audio cues via Web Audio API
- Critical for AFK gameplay which is core to the genre

### Loot tracker sidebar

RuneLite logs every kill with drops received and their values, grouped by NPC name.

Add a "Loot" tab in the sidebar that accumulates drops per mob type with counts and total gold value. Store in localStorage. Turns grinding into a visible progress tracker.

### XP / skill progress overlay

When gaining XP in a skill, show: XP gained this session, XP/hour rate, XP remaining to next level, estimated time to level.

Render as a small Pixi overlay near the minimap or as a sidebar tab. Requires the server to send XP change events.

### XP drops (floating text)

Customizable floating XP numbers when gaining experience. Position, size, speed, color all configurable.

### Minimap click-to-walk

RuneScape's minimap is clickable — click a point and your character pathfinds there. Needs server-side pathfinding or client-side A* with the tile blockmap (already available in `GameRuntime.isTileBlocked`).

### Drag-and-drop inventory rearrangement

RuneScape lets you drag items between inventory slots. Implementation: HTML5 drag events on the inventory grid, send a reorder packet to the server.

### Anti-drag (inventory)

RuneLite adds a configurable delay (~200ms) before an inventory drag begins. Prevents accidental item movement during fast combat gear switches. Trivial to implement with a `mousedown` timer.

---

## Tier 3 — Nice to have, build when relevant

### Inventory setups (saved loadouts)

Save named equipment+inventory configurations. When preparing for an activity, load a setup and it highlights which slots don't match. Store in localStorage.

### Inventory tags (color groups)

Assign colored backgrounds to inventory items by category — red for food, blue for potions, green for gear. Helps distinguish items at a glance during combat.

### Entity hider toggles

RuneLite has 16 separate toggles for hiding players, pets, NPCs, projectiles, etc.

Start with: hide other players (useful in crowded areas), hide pets, hide dead NPCs. Render as checkboxes in a settings panel.

### NPC indicators (tagging)

RuneLite: tag specific NPCs by name or wildcard pattern. Three highlight modes: tile square, hull outline, or name label. Custom colors per NPC type. Useful for Slayer-style task tracking.

### Player indicators (category coloring)

Six distinct player categories with independent colors: self, friends, clan, team, non-clan, other. Shows colored overhead names, minimap dots, tile highlights. Color-codes right-click menus by category.

### Screen markers (user-drawn rectangles)

Let users draw colored rectangles anywhere on the client window as personal reference marks. Alt+drag to reposition. Niche but beloved by RuneLite users.

### Chat commands

In-game chat commands for instant lookups: `!price [item]`, `!level [skill]`, `!stats`. Results display in chat.

### Chat filter

Filter/collapse spam messages by regex or keyword. Separate filters for public, private, system, trade chat.

### Screenshot auto-capture

Auto-capture screenshots on triggers: level ups, boss kills, valuable drops, deaths. Optional upload to Discord/Imgur.

### Idle notifier

System notification when: character goes idle, low HP, about to log out, animation stops. Configurable timeout threshold.

---

## Architectural Idea: Layered Overlay System

RuneLite's most powerful design pattern is its **layered overlay system**. Every plugin registers overlays that render at specific Z-layers. Users can Alt+drag any overlay to reposition it.

For the AO web client, build as a Pixi overlay manager:

```
OverlayLayer.UNDER_ENTITIES   — tile markers, ground item labels
OverlayLayer.ABOVE_ENTITIES   — HP bars, name tags, interact highlight
OverlayLayer.ABOVE_SCENE      — opponent info, XP drops, combat text
OverlayLayer.HUD              — status orbs, minimap, notifications
```

Each overlay is a Pixi `Container` added to the appropriate layer. A settings panel lets users toggle overlays on/off individually. This scales to any future feature without refactoring the renderer.

---

## What NOT to copy

- **RuneScape's fixed 765x503 viewport** — product of 2004 web constraints. Responsive canvas is better.
- **GPU plugin / extended draw distance** — irrelevant for 2D tile rendering.
- **Prayer/spellbook grid layout** — AO's skill system is different. Don't force-fit RS's icon grid.
- **Bank tabs** — premature. Get basic inventory working first.
- **Grand Exchange** — way too complex for early phases. Player-to-player trade first.
- **World hopper** — single server for now.
- **Fairy ring / teleport helpers** — AO has a different transport system.
- **Clue scroll solvers** — not applicable.
- **Plugin hub / external plugin loading** — massive overkill for now.
- **Skill XP drops** — AO doesn't have the same skill XP model. Would feel grafted on until skills are implemented.
