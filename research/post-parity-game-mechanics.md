# Post-Parity Game Mechanics Research

Goal: decide what to build after backend/client compatibility is closed, without
falling into low-leverage feature sprawl.

This document is not a backlog dump. It is a prioritization note for which
major game mechanics should come next, why they matter, and what must exist
before each one is worth building.

Related evidence and product recommendations are documented in
[Official Wiki and Patreon Feature Audit](wiki-patreon-feature-audit.md).

## Product Principle

After parity, the next mechanics should improve one or more of:

- long-term retention
- repeatable gameplay loops
- social coordination
- item/economy depth
- content leverage per developer hour

Avoid mechanics that are expensive, flashy, and shallow. The default test is:

- does this create a repeatable player goal?
- does it reuse existing systems well?
- does it deepen the world instead of adding another isolated minigame?

## Recommended Build Order

### 1. Quests

Why first:

- highest content multiplier
- gives structure to exploration and progression
- makes NPCs, maps, combat, items, and rewards all more valuable

What "good enough" means:

- quest definitions with objectives, states, rewards, prerequisites
- NPC dialogue and acceptance/turn-in flow
- repeatable and non-repeatable quest support
- backend persistence
- browser quest journal/UI

Dependencies:

- stable NPC interaction flow
- reliable persistence
- reward delivery

Risk:

- if quest logic is hardcoded per quest, it becomes unmaintainable fast

Recommendation:

- build a data-driven quest engine, not one-off scripted quests

### 2. Dungeons and Boss PvE

Why second:

- creates group goals and endgame structure
- gives itemization and progression a reason to exist
- turns the map/combat system into real repeatable content

What "good enough" means:

- dungeon entry/exit rules
- boss encounters with mechanics beyond raw HP
- reward tables
- lockout or reset rules
- group viability

Dependencies:

- stable combat
- stable AoI / NPC AI under pressure
- death/revive rules that feel fair in encounters

Risk:

- if bosses are only bigger stat blocks, the content gets solved immediately

Recommendation:

- start with 1-2 strong encounter patterns, not 20 weak bosses

### 3. Crafting Depth

Why third:

- gathering/crafting already exists, so this compounds existing work
- supports item economy and non-combat progression
- gives value to exploration and professions

What "good enough" means:

- larger recipe set
- recipe discovery or unlock progression
- profession specialization
- quality tiers or output variance
- meaningful sink/source loops

Dependencies:

- stable item economy
- clear profession identities

Risk:

- if outputs are flat stat copies, crafting becomes menu work, not progression

Recommendation:

- make professions create differentiated value, not just alternate acquisition

### 4. Itemization Depth

Why fourth:

- strong loot identity is a major retention driver
- improves PvE, crafting, and the economy at once

What "good enough" means:

- rare items with real identity
- controlled affix / enchant / rune depth
- item classes that matter beyond damage numbers
- progression from common -> uncommon -> rare -> chase items

Dependencies:

- telemetry on combat balance
- stable drop economy
- clear stat model

Risk:

- this can destroy balance if added too early

Recommendation:

- add depth carefully after economy data exists; do not rush affix inflation

### 5. Guild Progression

Why fifth:

- guilds already exist; progression gives them long-term purpose
- raises retention through social obligation and group identity

What "good enough" means:

- guild objectives or XP
- guild unlocks/perks/cosmetics
- shared storage or shared progression artifacts if desired
- clear anti-abuse rules

Dependencies:

- existing guild system stable
- backend admin/moderation tools strong enough to handle abuse

Risk:

- if guild perks are too strong, solo play becomes second-class

Recommendation:

- reward coordination and identity, not mandatory power creep

### 6. World Events

Why sixth:

- makes the world feel alive
- drives concurrency and social play
- excellent for retention if scheduled well

What "good enough" means:

- server-driven event scheduling
- map-wide or region-wide announcements
- shared objectives
- event rewards with controlled impact

Dependencies:

- enough players online to make events matter
- good ops visibility

Risk:

- events are wasted if the daily player base is too small or unstable

Recommendation:

- build this after basic retention loops exist

### 7. PvP Systems

Why seventh:

- strong replayability, but high balancing cost
- best once combat and itemization are already trustworthy

What "good enough" means:

- structured duels/arenas
- ladders or ranking if desired
- clear rewards that do not wreck progression
- anti-griefing rules

Dependencies:

- mature combat balance
- moderation tools
- matchmaking or at least structured entry points

Risk:

- PvP rewards can distort the entire economy if designed badly

Recommendation:

- treat PvP as a long-term system, not a patch for weak PvE

### 8. Social/Community Layer

Why eighth:

- this keeps people around after the novelty wears off
- helps realms feel populated and organized

Candidate mechanics:

- mail
- friends/ignore
- party finder
- guild recruitment tools
- event signup

Dependencies:

- account/lobby flow
- moderation/admin visibility

Recommendation:

- build this as glue between the stronger gameplay loops above

### 9. Pet and Mount Depth

Why ninth:

- good flavor, moderate retention
- lower leverage than quests/dungeons/crafting/itemization

What "good enough" means:

- pet progression or utility
- mount utility or travel identity
- cosmetic and mechanical distinction

Risk:

- high asset/UI burden for limited systemic depth

Recommendation:

- do not prioritize this over stronger loop-building systems

### 10. Seasonal / Live-Ops Progression

Why last:

- only valuable once the underlying game is strong
- should amplify a good game, not compensate for a weak one

What "good enough" means:

- seasonal goals
- cosmetic or controlled progression rewards
- event cadence

Risk:

- becomes treadmill design if the base game still lacks depth

Recommendation:

- only add after quests, PvE, crafting, and guild/event structure are healthy

## What Not To Rush

Avoid prioritizing these too early:

- monetization-shaped systems
- cross-realm free movement
- deep rune/affix complexity before telemetry
- many isolated side systems with no shared progression role
- cosmetic-heavy systems that do not strengthen the core loop

## Suggested First Three Post-Parity Tracks

If choosing only three major initiatives, build:

1. Quests
2. Dungeons/Boss PvE
3. Crafting depth plus controlled itemization depth

Why this trio:

- they reuse the most of the current backend
- they create both solo and group goals
- they deepen the economy naturally
- they provide a foundation for later guild and event systems

## Telemetry Needed Before Big Content Expansion

Before adding itemization, PvP rewards, or guild perks, collect:

- class pick rates
- level distribution
- item acquisition/destruction rates
- gold generation/sinks
- NPC kill/death rates
- spell usage rates
- map population and session duration
- party/guild participation

Without this, balancing new systems will be guesswork.

## Delivery Strategy

Good sequence after parity:

1. ship the compatibility baseline
2. add account/lobby and admin tooling
3. add quest framework
4. add first dungeon/boss loop
5. deepen crafting and itemization
6. add guild progression
7. add world events
8. add structured PvP
9. add broader social layer
10. add seasonal/live-ops only if the rest is healthy

## Summary

The best post-parity mechanics are the ones that multiply the value of systems
already built.

Highest leverage:

- quests
- dungeons/boss PvE
- deeper crafting
- controlled itemization
- guild progression

Lower leverage until later:

- pets/mounts depth
- seasonal systems
- broad cosmetic or side-system expansion
