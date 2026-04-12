# RuneScape / RuneLite UI UX Ideas

Focused UI/UX research for Argentum Online's browser client.

This document consolidates the older broad RuneScape note and the newer
RuneLite-focused note into one source of truth.

The goal is not to clone RuneScape's UI. The goal is to copy the strongest
ideas from RuneLite's product shell while preserving Argentum's own gameplay,
visual identity, and renderer architecture.

## Core Principle

Copy the product-shell strengths, not the game renderer.

RuneLite is strongest where it:

- makes hidden or easy-to-miss state visible
- gives players strong control over the client
- organizes dense information without forcing constant panel switching
- keeps optional UX power separate from the game simulation itself

For Argentum, that means the best things to copy are settings, overlays,
filters, search, status surfaces, recovery states, and map/navigation helpers.
It does not mean copying RuneScape's layout, fixed viewport assumptions, or
plugin-sprawl culture.

## Hard Architecture Rule

React/DOM UI must not own the fast render path.

- React should own panels, forms, overlays, settings, account/lobby flows, and
  product-shell state.
- Pixi/canvas should own frame-critical rendering, sprite movement, camera,
  animation timing, hover/selection highlights, and other hot-path visual work.
- React may mount host nodes and pass coarse-grained state into the renderer,
  but it must not become the render loop or perform per-frame canvas work.

If a feature needs to update every frame or follow live world transforms, it
belongs in the renderer path, not in React state churn.

## Best Ideas To Copy First

### 1. Persistent settings everywhere

Highest-value RuneLite trait: users can shape the client intentionally.

Priority settings to add:

- music on/off and volume
- SFX on/off and volume groups
- renderer-quality/performance presets
- hotkeys and keybind remapping
- minimap preferences
- overlay toggles
- chat filters and visibility preferences
- debug/dev toggles kept behind explicit settings

Requirement:

- persist them locally from day one

### 2. Strong chat organization

RuneLite is much easier to live in because chat is organized by purpose.

What to copy:

- separate tabs or streams for system, local/public, private, party, guild,
  faction, trade, and combat as appropriate
- message filtering instead of one undifferentiated log
- timestamps
- scroll lock and unread indicators

Important caution:

- do not implement this blindly
- first inspect the actual AO packet families, current shard expectations, and
  desired UX model
- the browser should not invent social semantics that the protocol does not
  really support

This is an investigation-first item before it becomes a UI build item.

### 3. Infobox-style status surfaces

RuneLite is strong at turning background state into compact, glanceable UI.

Good AO candidates:

- active buff/debuff timers
- spell cooldown timers
- reconnect state
- hunger/thirst if exposed to players
- temporary penalties or protection states
- target/opponent status summaries

These should be compact and glanceable, not giant warning banners.

### 4. Search and filtering in dense panels

This is one of the safest modern UX upgrades.

Best surfaces:

- spells
- inventory
- bank
- party/clan rosters
- trade or merchant lists

Principle:

- when a panel can grow, assume it will need search

### 5. Better minimap and map affordances

What is worth copying:

- better marker/highlight systems
- optional points of interest
- hover detail
- clearer navigation cues

What needs product validation first:

- persistent user markers
- route guidance or breadcrumbs
- any click-to-move behavior driven from the minimap

We already have a minimap. The useful question is not "should we add one" but
"what map assistance is worth adding without harming the game's feel?"

### 6. Keybind customization

Hardcoded controls age badly.

What to copy:

- bind and rebind important actions cleanly
- let users disable accidental bindings
- expose the active bindings in the UI

This is product-shell work with high leverage and low gameplay risk.

### 7. Clear recovery and error states

RuneLite-style practicality matters here more than style.

The browser client should be explicit about:

- reconnecting
- session expired
- banned
- muted
- maintenance
- server full
- asset-load failures

The key idea to copy is not the exact presentation, but the expectation that
the client explains what happened and what the player can do next.

### 8. Modular feature surfaces

RuneLite benefits from a plugin mindset even when features are built-in.

Argentum should copy the modularity, not the plugin hub.

Goal:

- panels and optional UX features should be composable and isolated
- adding a new overlay or settings surface should not require turning the main
  app shell into a monolith

Do this as internal architecture first. Public plugin loading is not a current
priority.

## Concrete Feature Ideas Worth Exploring

These are RuneScape/RuneLite-style feature candidates, not all immediate
priorities.

### World-entity context menus

Right-click any NPC, player, or ground item and get stacked actions such as
talk, attack, trade, follow, or examine.

Why it matters:

- gives one interaction model for many systems
- scales better than adding one-off buttons for each feature
- makes the world feel interactive instead of panel-driven

Implementation note:

- renderer hit testing should identify the entity or tile
- the menu itself can still be a React/DOM overlay

### Smart left-click defaults

RuneLite's menu-entry-swapper idea is high leverage: make left-click perform
the most common action for the current context.

Examples:

- banker -> bank
- shop NPC -> commerce
- ground item -> pick up
- sign or service NPC -> inspect/use

This should be data-driven, not hardcoded per screen.

### Ground-item labels with value tiers

Floating labels above loot are one of the most useful modern-client features.

Good AO version:

- color-code by value tier
- allow value threshold filtering
- optionally show despawn countdown
- reserve stronger effects such as lootbeams for rare/high-value drops

Implementation note:

- this belongs in Pixi/canvas, not in DOM overlays

### Opponent info widget

A small combat-focused summary showing target name, HP, and possibly level or
status.

Can be rendered:

- near the target in the world
- as a fixed compact HUD element

### Hover/interact highlight

When the cursor is over an NPC, player, item, or interactive object, give
clear visual feedback.

Possible implementations:

- outline
- brighten/highlight filter
- hover label

### Character-adjacent status bars

HP and optionally mana/stamina bars near the character reduce sidebar scanning.

This is especially valuable in a browser client where glance cost matters.

### Minimap status orbs

Small always-visible circular indicators near the minimap can expose:

- HP
- mana
- stamina or equivalent movement resource

Use sparingly. Keep them compact.

### Equipment paperdoll

A dedicated equipment view with slot positions is a strong usability upgrade if
the inventory/equipment flow grows more complex.

### Tile markers

Potentially useful for navigation, party coordination, or PvE positioning.

Open questions:

- personal only or shared?
- minimap only or world-visible too?
- temporary or persisted?

### Notification system

Potential uses:

- low HP
- idle state
- valuable drop
- reconnect lost/recovered

Keep it restrained. Do not turn the client into a notification machine.

### Loot and session trackers

Good modern-client feature once gameplay telemetry is stable.

Examples:

- loot history
- session gold earned
- recent kills
- per-NPC drop summary

### Inventory drag polish

Worth considering later:

- drag-and-drop reordering
- anti-drag delay to prevent accidental moves
- saved loadouts or setup helpers if the game grows into them

## Layered Overlay System

RuneLite's most powerful design pattern is its layered overlay system. Argentum
should copy the layering idea without copying plugin sprawl.

Possible renderer layers:

```text
UNDER_ENTITIES   - tile markers, ground-item labels
ABOVE_ENTITIES   - HP bars, name tags, hover highlight
ABOVE_SCENE      - opponent info, combat text, transient alerts
HUD              - status orbs, minimap affordances, notifications
```

Each overlay should have:

- a clear owner
- a stable layer
- a settings toggle if optional
- a renderer implementation if it follows scene transforms or updates at
  frame-rate

## Things Not To Copy

### Do not copy RuneScape's layout literally

Argentum should not inherit:

- fixed old-school viewport assumptions
- old tab metaphors just because RuneScape used them
- UI density that exists only to work around 2000s constraints

### Do not copy plugin sprawl

Public plugin ecosystems create:

- support burden
- design inconsistency
- automation pressure
- balance problems if overlays drift into gameplay assistance

Internal modularity is good. Open-ended plugin sprawl is not an early target.

### Do not copy automation-adjacent helpers casually

Be careful with anything that starts acting like:

- decision support that trivializes game knowledge
- combat assistance that approaches scripting
- exhaustive world-state revelation beyond intended play

The client should improve clarity and control, not play the game for people.

### Do not push renderer work into React

This is worth repeating because it is where web game clients degrade.

Avoid:

- per-frame React state updates for world visuals
- DOM overlays that track dozens of moving entities every frame
- React-managed animation loops for scene-critical elements

If it moves every frame, it should almost certainly live in Pixi/canvas.

## Recommended Adoption Order

1. Persistent settings and keybinds.
2. Clear account/session/recovery product shell.
3. Investigation-first design for chat stream separation.
4. Infobox/timer system for compact high-signal state.
5. Search/filter on dense panels.
6. Map markers and navigation helpers, if product scope still wants them.

## Fit With Current Frontend Roadmap

These ideas should complement, not replace, the current frontend priorities:

1. HTTP auth/lobby/character selection.
2. Authoritative party/clan data.
3. Settings + audio polish.
4. Broader browser test coverage.

RuneLite-inspired work is most valuable when it improves the shell around those
foundations instead of distracting from them.
