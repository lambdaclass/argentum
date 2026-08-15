# Official Wiki and Patreon Feature Audit

Date: 2026-08-15

Goal: identify useful mechanics and supporter benefits from the official
Argentum Online wiki, Patreon material, and current official server source,
then translate them into a fair, practical feature direction for this project.

This is a product research note, not an implementation commitment. It should be
used together with [Post-Parity Game Mechanics Research](post-parity-game-mechanics.md)
and `ROADMAP.md`.

## Executive Recommendation

The strongest additions are:

1. finish the persistent, data-driven quest platform and browser quest journal
2. use it for server-wide contribution events that culminate in dungeon bosses
3. add an in-game codex, collection log, and build calculator
4. introduce free RuneScape-style regional realm selection
5. offer automatic chat translation as a supporter convenience
6. add mounts, cosmetic collections, and instanced housing after the core loops
7. delay deep rune itemization and seasonal systems until telemetry is reliable

World selection, quests, destinations, combat equipment, and normal progression
should remain available to every player. A supporter plan should fund the game
through translation, cosmetics, account organization, and community benefits,
not exclusive power.

## Audit Scope and Limitations

Sources reviewed:

- [production wiki](https://www.argentumonline.com.ar/wiki)
- [official public wiki repository](https://github.com/ao-org/ao20-wiki)
- [current indexed quest guide](https://staging.argentumonline.com.ar/wiki/guia-general/quests)
- [current indexed balance calculator](https://staging.argentumonline.com.ar/wiki/guia-general/calculator)
- [Patreon items page](https://www.argentumonline.com.ar/wiki/guia-general/items-patreon)
- [public Patreon benefits explanation](https://www.patreon.com/nolandstudios/posts/abril-es-el-para-125243330)
- [Noland Studios Patreon sitemap](https://www.patreon.com/cw/nolandstudios/sitemap)
- [official AO20 website and updates](https://www.argentumonline.com.ar/)
- [official server source at the audited revision](https://github.com/ao-org/argentum-online-server/commit/9e9f225f4e587e74b9ab6400619c06a6359bde9f)
- the current local server, browser client, roadmap, and research documents

The production wiki rejected automated crawling through Cloudflare during the
audit. The public wiki repository provides broad historical coverage but is an
older snapshot. Current indexed pages, public Patreon material, current news,
and the official server source were therefore used to validate newer systems.
Exact live pricing, tier contents, and rotating store inventory should be
rechecked manually before making commercial decisions.

## Systems Represented in the Wiki

The accessible wiki corpus covers these major areas:

- races, classes, attributes, levels, skills, and combat modifiers
- cities, maps, navigation, dungeons, and hostile creatures
- spells, equipment, consumables, chests, badges, mounts, and special items
- fishing, logging, carpentry, mining, and blacksmithing
- taming, pets, parties, clans, factions, challenges, and justice rules
- death, resurrection, home travel, NPC commerce, and player trade
- quests for level bands, factions, professions, mounts, spells, objects, skins,
  chests, and NPC drops

Not every topic represents a missing feature in this project. Parties, guilds,
factions, auctions, pets, gathering, crafting, combat, and several world events
already have meaningful foundations. The opportunity is to connect these
systems through persistent goals rather than reproduce isolated wiki features.

## Patreon Systems Observed

Public AO20 Patreon material has described:

- increased character capacity by tier
- recurring supporter credits and a credit shop
- expanded inventory
- a special travel passage
- supporter houses with private facilities
- a supporter daily quest
- character transfer between eligible accounts
- tier stars or badges
- staging-server access and Discord roles/channels

Newer public listings and official updates also reference Noble and Emperor
tiers and private castles. The current official source contains supporter tiers,
credit accounting, supporter-only checks, housing/castle mechanics, and other
entitlement-related behavior.

These are evidence of possible features, not a recommendation to copy their
commercial boundaries. Inventory capacity, travel advantages, exclusive
training areas, and world-controlling property can all affect competitive play.

## Current Project Gap Summary

### Existing foundations

- server-side quest acceptance, abandonment, kill/item objectives, rewards, and
  repeatability
- account Patreon flag and Normal, Adventurer, Hero, and Legend tier mapping
- chat channels and server-side broadcast infrastructure
- parties, guilds, factions, auctions, pets, gathering, crafting, and events
- elemental item-tag persistence
- a planned localization track and planned regional-realm architecture

### Important gaps

- active and completed quest persistence
- browser quest packet handling, journal, tracking, and turn-in experience
- quest chains, prerequisite enforcement, target restrictions, and global goals
- community/global contribution quests
- subscription lifecycle and provider-independent entitlements
- supporter credit ledger and cosmetic catalog
- automatic player-chat translation
- regional realm directory, selection, presence, and transfer policy
- transport NPC network
- in-game codex, build calculator, achievements, and collection log
- deep mount, wardrobe, housing, and elemental-rune gameplay

The current quest state lives on the player entity, so completing persistence
and browser UX is an extension of existing work rather than a greenfield system.
The roadmap already calls for language support and explicit regional realms.

## Recommended Features

### 1. Persistent Quest Platform

Build this first because it multiplies the value of NPCs, maps, combat, items,
professions, factions, and rewards.

Minimum complete platform:

- persisted active, completed, failed, and cooldown state
- browser journal with tracked objectives and authoritative progress
- NPC acceptance, dialogue, turn-in, and abandonment flows
- prerequisite quests and multi-step chains
- kill, item, gathering, crafting, location, dialogue, escort, and boss objectives
- level, class, faction, skill, item, and reputation requirements
- repeatable, daily, weekly, and one-time policies
- transactional reward delivery with recovery after disconnects
- map and minimap markers where product-approved
- data validation and authoring tools to prevent broken quest definitions

Suggested first content pack:

- a guided beginner chain covering travel, combat, banking, trade, and death
- one chain for each gathering/crafting profession
- faction introduction chains
- one spell-unlock chain
- one mount-unlock chain
- one dungeon-attunement chain
- repeatable bounty and delivery jobs

### 2. Global Community Quests

The current official AO20 server supports timed global gathering counters,
individual contribution records, threshold rewards, and boss spawns. This is a
high-leverage pattern for this project because it can reuse quests, events,
combat, gathering, broadcasts, persistence, and reward delivery.

Example event:

1. players deliver iron, wood, and monster trophies to rebuild a fortress
2. contribution milestones trigger attacks or roaming lieutenants
3. reaching the target opens a temporary dungeon
4. the server fights a staged boss
5. personal contribution grants reputation and cosmetics
6. completion changes a town or travel route for a limited time

Design safeguards:

- reward useful participation, not only the top contributors
- cap or diminish farmable contribution per account
- expose progress in the HUD and codex
- persist every contribution with an auditable source
- do not require a supporter subscription to participate or claim rewards

### 3. Dungeons and Mechanical Bosses

Add group PvE after the quest platform can introduce, track, and reward it.

Start with a small vocabulary of reusable encounter mechanics:

- telegraphed area attacks
- adds that change boss vulnerability
- interactable objectives or destructible structures
- positional phases and safe zones
- class-agnostic teamwork checks
- optional difficulty modifiers

Prefer rare recipes, cosmetic trophies, and controlled materials over unchecked
gold generation. A collection log can provide long-term goals without making
every rare drop a mandatory power increase.

### 4. In-Game Codex and Calculator

The game should expose authoritative information currently scattered through
wiki pages and data files:

- monsters, habitats, drops, resistances, and discovery state
- item sources, sinks, recipes, and equipment requirements
- spells, classes, races, skills, and combat calculations
- quest, dungeon, mount, skin, and achievement collections
- searchable locations and travel connections
- links such as "used in", "crafted from", and "dropped by"

Generate the codex and public reference material from shared definitions where
possible. This reduces documentation drift and turns exploration into a visible
collection goal.

### 5. Regional Realms

Regional realm selection should behave like a RuneScape world list:

- South America, North America, and Europe as initial compute regions
- visible ping, population, capacity, and activity designation
- shared account identity and one active character session
- explicit switch cooldown and safe logout/hand-off
- guild/friend presence showing their current realm
- realm-aware monitoring, abuse controls, and support tools

Decide these policies before implementation:

- whether character location and inventory are globally shared
- whether auctions, world bosses, weather, and community quests are global or
  realm-local
- how guilds and parties behave across realms
- whether PvP or seasonal worlds have isolated progression

Do not confuse server regions with continents inside the game world. Server
regions solve latency; ships, transporter NPCs, passages, and quest unlocks
should preserve geographic exploration.

### 6. Automatic Chat Translation

Translation is a good supporter benefit because it improves communication
without selling character power and has a real variable operating cost.

Recommended experience:

- every account selects a preferred language
- all players can manually translate an individual message
- supporters can enable automatic translation by channel
- translated messages retain an accessible original
- system, service, and authored NPC text use curated locale strings instead of
  generative translation
- party and guild translation takes priority over high-volume public channels

Operational safeguards:

- perform translation asynchronously outside the authoritative map loop
- cache by normalized message and target language
- batch identical requests
- impose fair-use limits and rate limits
- never delay delivery of the original message
- provide reporting, blocking, and moderation access to the original text
- record usage and cost per account, channel, and language pair

### 7. Travel Network

Add transporter NPCs and ships as world-building tools rather than paid skips.

- routes become discoverable in the codex
- some destinations unlock through quests or reputation
- prices and cooldowns act as modest gold sinks
- dangerous destinations may require physical travel first
- supporter presentation may be cosmetic, but core routes remain free

### 8. Mounts, Wardrobe, and Collections

Use mounts and skins as durable goals rather than disposable store inventory.

- account wardrobe with character-specific presets
- mounts earned through quests, bosses, professions, achievements, and cosmetics
- collection pages with silhouettes for undiscovered rewards
- cosmetic-only supporter variants
- non-tradeable or carefully controlled premium unlocks
- no supporter mount should provide exclusive combat power

### 9. Instanced Housing and Guild Halls

Begin with instanced property instead of player-placed castles on public maps.
This avoids collision, land scarcity, griefing, and pay-to-control-world-space
problems.

Initial scope:

- decorative furniture and achievement trophies
- wardrobe and account-storage organization
- guest permissions and guild access lists
- practice arena with no rewards or economic output
- guild notice board and event trophies
- cosmetic supporter decoration packs

Public castles can later become gameplay objectives earned and contested by
guilds. They should not be permanent territorial power purchased through a
subscription.

### 10. Crafting and Elemental Runes

Expand professions through recipe discovery, specialization, repair, and rare
encounter materials. Elemental runes can then add targeted resistance or damage
identity.

Do not launch a large random-affix or rune system before collecting:

- class and equipment usage
- damage and death distributions
- item creation and destruction
- market prices and liquidity
- boss completion rates

Prefer deterministic recipes and visible trade-offs over opaque random power.

## Supporter Subscription Policy

### Appropriate supporter benefits

- automatic chat translation with fair-use limits
- cosmetic badge, nameplate, profile treatment, or title
- recurring cosmetic currency
- extra character slots
- account wardrobe organization and additional presets
- additional account-bank organization that does not increase combat carry space
- housing decorations and cosmetic room themes
- test-realm access
- Discord roles, previews, and community votes
- optional supporter alias with moderation-visible canonical identity

### Benefits that should remain free

- regional realm selection
- all quests and quest rewards
- access to normal continents, cities, dungeons, and travel routes
- classes, spells, professions, and competitive equipment
- manual message translation
- guild, party, trade, and auction participation
- ordinary combat inventory capacity

### Benefits to avoid

- exclusive combat gear or statistical mount advantages
- XP, gold, drop-rate, or crafting-success multipliers
- supporter-only farming or training zones
- unlimited free consumables
- paid teleportation that materially bypasses risk or progression
- paid territory, castles, or economic control
- purchasable contribution in community events

## Entitlement Architecture

The current single patron integer is insufficient for billing and durable
entitlements. Introduce provider-independent records for:

- subscription provider and external customer/subscription identifiers
- tier, status, period start/end, cancellation, and grace period
- independently versioned entitlements
- idempotent webhook events
- auditable credit grants, spends, reversals, and expirations
- account-bound cosmetic ownership
- explicit downgrade behavior

Never delete items merely because a subscription expires. Locked capacity must
remain recoverable through a safe withdrawal-only or overflow mechanism.

## Proposed Delivery Order

### Track 1: quest foundation

1. quest persistence and transactional rewards
2. browser packets, journal, tracking, and markers
3. prerequisites, chains, and broader objective types
4. first substantial quest content pack

### Track 2: repeatable world content

1. first dungeon and mechanical boss
2. global contribution quest
3. codex and collection log
4. profession and rare-recipe expansion

### Track 3: international access

1. locale preference, Unicode, and curated UI/system translations
2. manual player-message translation
3. supporter automatic translation
4. regional realm directory and selection

### Track 4: identity and supporter value

1. provider-independent entitlement service
2. cosmetic wardrobe, badges, and credits ledger
3. mount collections
4. instanced housing and guild halls

### Later

- deep elemental rune itemization
- opt-in seasonal rulesets
- public guild-castle warfare
- controlled character transfers between isolated realm types

## First Shippable Milestone

If only one combined milestone is funded, ship:

- persistent quest progress
- a browser quest journal
- 20 to 30 connected quests across beginner, profession, faction, and dungeon
  categories
- one community gathering event
- one multi-phase dungeon boss unlocked by that event
- a small codex showing quest, item, and boss discoveries

This creates a coherent playable loop and validates the foundations required by
most of the later ideas.

## Open Product Decisions

Resolve these questions before promoting the affected ideas into delivery:

- Who is the initial target audience: existing AO players, returning players,
  or people new to the genre?
- Which languages and hosting regions have enough expected demand for launch?
- Do normal regional realms share character position, economy, auctions, guilds,
  community events, and world state?
- Are PvP or seasonal realms separate characters or alternate destinations for
  the same character?
- How much travel friction is important to the identity of the world?
- Should mounts be cosmetic, travel utility, or part of combat?
- Is housing personal, account-wide, guild-owned, or some combination?
- Which rewards may be traded, and which should remain account-bound?
- What monthly translation cost and supporter fair-use limit are sustainable?
- Which supporter benefits remain valuable after a subscription expires?

Record decisions and their reasoning. These choices affect architecture,
economy, moderation, and content design, so they should not be left implicit.

## Evidence and Metrics Plan

Capture a baseline before launching major post-parity systems so that changes
can be evaluated rather than judged only by anecdotes.

Player journey:

- registration-to-character-creation conversion
- character-creation-to-first-session conversion
- tutorial and early quest completion/drop-off points
- day 1, day 7, and day 30 retention
- session length, return frequency, and progression distribution

World and social health:

- map population by time and region
- latency, reconnects, disconnects, and failed realm switches
- party, guild, trade, duel, and event participation
- dungeon attempts, completion rates, and group composition
- reports, blocks, sanctions, and moderation response time

Economy and progression:

- gold creation, destruction, and concentration
- item creation, destruction, trade volume, and market price bands
- profession participation and recipe usage
- quest reward generation and repeatable-quest farming
- rare drop acquisition and boss reward concentration

Translation and supporter health:

- translations requested by channel and language pair
- cache rate, latency, error rate, and cost per active user
- manual-to-automatic translation conversion
- supporter conversion, renewal, cancellation, and benefit usage
- credit grants, spending, outstanding liability, and chargeback impact

Define a success threshold and rollback condition before each experiment starts.

## Player Research Plan

Use several evidence sources because existing enthusiasts and new players often
have different needs.

1. Interview small groups of existing, returning, and new players separately.
2. Observe first sessions without coaching and record where players become
   confused, idle, or leave.
3. Survey players with ranked problems rather than only open feature requests.
4. Test quest-journal, realm-list, codex, and translation mockups before building
   their complete backend systems.
5. Run staging events with explicit hypotheses and short feedback forms.
6. Compare stated preferences with production behavior after release.

Avoid treating the loudest request as representative without usage or survey
evidence.

## Technical and Economy Experiments

Recommended early spikes:

- persist and recover one complete multi-step quest across reconnects
- simulate duplicate quest completion and reward-delivery retries
- run a global contribution event under bot-like and bursty load
- prototype a realm directory and cross-region session hand-off
- measure translation latency, cache effectiveness, and per-message cost
- simulate premium-credit grants, purchases, reversals, and expiration
- model gold and material flows for the first dungeon reward table
- validate downgrade behavior for character slots, storage, and cosmetics
- test content definitions for broken references before server startup

Each spike should answer a named uncertainty. Disposable experiments should not
quietly become production architecture.

## Content Operations and Safety

New systems need operating tools as well as player-facing mechanics:

- quest and event validation, preview, scheduling, pause, and rollback
- reward audit trails and tools to repair incomplete delivery
- realm health, population, capacity, and transfer dashboards
- feature flags and kill switches for events, translation, and premium benefits
- translation access to original text for reports and moderator review
- disclosure and retention policies for messages sent to translation providers
- localized moderation rules and escalation paths
- refund, cancellation, chargeback, and entitlement-recovery procedures
- content ownership and localization review for authored text and cosmetics

These requirements belong in the initial design, especially where paid benefits
or external language services are involved.

## Research Brief Template

Use this structure for ideas entering Phase 9:

1. **Status:** exploring, validating, accepted, deferred, or rejected
2. **Player problem:** the observed need, not merely the proposed feature
3. **Audience:** which player segment benefits
4. **Hypothesis:** the expected behavioral or experiential improvement
5. **Smallest useful version:** the minimum coherent player experience
6. **Dependencies:** systems, content, operations, and external services
7. **Risks:** balance, economy, abuse, safety, accessibility, and pay-to-win
8. **Evidence:** source research, interviews, telemetry, prototypes, or tests
9. **Success measures:** metrics and qualitative acceptance criteria
10. **Decision:** outcome, reasoning, owner, and review date

## Decision Summary

Build now:

- quest persistence and browser UX
- quest chains and authored content
- community quests and a first dungeon boss
- codex and collection tracking

Design now, implement after the quest milestone:

- automatic translation
- regional realms
- supporter entitlements

Add later:

- mounts and wardrobe depth
- instanced housing and guild halls
- elemental runes and seasons

Reject as product policy:

- paid world selection
- paid quests or destinations
- subscriber combat power
- supporter-controlled public territory
