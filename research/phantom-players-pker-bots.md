# Phantom Players: PKer Bots That Look Like Real Players

Goal: populate the world with 100-200 bot-controlled characters that are
indistinguishable from human players. They walk around, fight NPCs, and
periodically attack real players — creating the feeling of a lived-in,
dangerous world.

## Why Not Just Inflate The Online Count

Lying about the number is cheap but brittle. The moment a player types `/online`
and sees 12 names instead of 200, the illusion breaks. Phantom players must
exist on maps, have visible bodies, move, fight, and die like real players.

## Design Principles

1. **They must be killable and drop loot.** A bot that can't die is instantly
   suspicious. Killing a phantom player and looting their gear is a gameplay
   moment players will talk about.
2. **They must lose sometimes.** Perfectly optimal play is a tell. Bots should
   miss attacks, use the wrong spell, hesitate before acting.
3. **They must not all behave the same.** Different personalities: some are
   aggressive PKers, some are passive farmers, some flee when low on HP.
4. **Distribution matters.** 200 bots on one map is a red flag. 3-8 per zone,
   weighted by zone danger and popularity, feels natural.
5. **They need human-like timing.** 200-600ms reaction delays, irregular
   movement, occasional pauses. Never frame-perfect.

## Architecture Options

### Option A: External Bots via `bot_army` (WebSocket clients)

The `bot_army` app already has the scaffolding: `BotArmy.Bot` connects via
WebSocket, sends walk/talk/attack packets, and tracks position from server
responses. `BotArmy.Swarm` manages lifecycle and batched spawning.

**What exists:**
- WebSocket client (`BotArmy.WsClient`)
- Login, walk, talk, attack packet builders
- Profile system (`:walk_only`, `:walk_chat`, `:default`)
- Swarm with DynamicSupervisor, batch spawning, metrics

**What needs to be added:**
- Combat AI: target selection, spell casting, potion use, flee logic
- World awareness: parse AoI packets to know who's nearby, track other
  players' positions and HP
- Behavior profiles: PKer, farmer, wanderer, coward
- Name/appearance generation: human-like names, varied classes/gear/levels
- Zone assignment: spawn distribution rules per map
- Anti-detection: timing jitter, imperfect play, varied chat lines

**Pros:**
- Bots use the exact same code path as real players — no special server-side
  support, no risk of state divergence
- Easy to run on a separate machine if CPU is a concern
- Already half-built

**Cons:**
- Each bot is a full TCP/WS connection + session process + DB character row
- 200 bots = 200 connections, 200 session processes, 200 entries in every
  `MapServer.players` map they inhabit
- Must parse server packets to know the world state (AoI, HP, positions)
- Network overhead even on localhost (serialization/deserialization roundtrip)

### Option B: Server-Side Phantom Entities

Add phantom players directly inside `MapServer` state. They look like player
entries in `state.players` but are driven by a server-side AI tick (similar to
`NpcAi.tick/1`).

**How it works:**
- `PhantomAi.tick(state)` runs every 500ms alongside `NpcAi.tick(state)`
- Phantom entities are `PlayerEntity` structs with a `:phantom` flag
- They appear in `state.players`, have char_indices, show up in AoI broadcasts
- Combat uses the real player combat path (`CombatHandlers.handle_attack`)
- They die, drop inventory items, and respawn on a timer (like NPCs)
- Gateway never creates a session for them — no transport process, no DB
  persistence of transient state

**Pros:**
- Zero network overhead — no connections, no serialization roundtrip
- AI has direct access to map state (knows every player's position, HP, etc.)
- Much lighter per-bot: just a `PlayerEntity` struct in the map, no process
- Easier to make them interact naturally (they see everything instantly)

**Cons:**
- New code path: phantom entities go through player combat but skip
  persistence, sessions, and transport. Every place that calls
  `Helpers.send_to_session` for a phantom must be a no-op.
- Risk of state divergence: phantom players might behave differently from real
  players in subtle ways because they bypass the gateway
- Adds complexity to `MapServer` tick — more work per tick
- Must guard every `send_to_session` call against phantom char_ids
- Testing burden: need to verify phantoms don't break real player flows

### Option C: Hybrid — Server-Side AI, External Identity

Register phantom characters in the DB and `OnlineDirectory` so they show up in
`/online` counts. Run AI logic server-side in `MapServer` (no WebSocket
connection). The phantom entity is a `PlayerEntity` with a flag.

This is essentially Option B but with proper identity registration so the
online count, whisper targets, and guild rosters work correctly.

**Pros:**
- Combines the performance of Option B with the identity correctness of
  Option A
- `/online` shows phantom names
- Players can whisper phantom bots (and get canned responses)

**Cons:**
- Same `send_to_session` guard burden as Option B
- DB rows for phantom characters (minor)
- Must handle phantom entries in `OnlineDirectory` carefully (no real session
  PID — need a stub or the `MapServer` PID as proxy)

## Recommended: Option A (External Bots) First, Option C Later

Option A is the pragmatic choice for a first pass:

1. **Already half-built.** `bot_army` has login, walk, talk, attack. Adding
   combat AI and zone distribution is incremental work.
2. **Zero server changes.** The server doesn't know or care that a connection
   is a bot. No phantom flags, no `send_to_session` guards, no new tick logic.
3. **Battle-tested path.** Bots exercise the exact same code as real players.
   If something breaks for bots, it would break for players too.
4. **Easy to tune.** Behavior profiles, spawn rates, and aggression levels are
   all bot-side configuration. No server deploys needed to adjust.

The cost is ~200 WebSocket connections, which on a single server should be
fine for early population levels. If it becomes a bottleneck, migrate to
Option C.

## Bot Behavior Design

### Personality Profiles

| Profile      | % of Pop | Behavior                                              |
|-------------|----------|-------------------------------------------------------|
| `pker`      | 20%      | Hunt players within level range, attack on sight      |
| `farmer`    | 35%      | Kill NPCs, pick up loot, ignore players unless attacked |
| `wanderer`  | 25%      | Walk between zones, occasionally rest/meditate        |
| `coward`    | 10%      | Farm NPCs, flee from any player that approaches       |
| `socializer`| 10%      | Stand in cities, say random lines, never fight        |

### Combat AI (for `pker` and `farmer` profiles)

```
every tick (500ms):
  if HP < 30%:
    drink potion if available
    if still low, flee (walk away from target)
    return

  if has_target:
    if target_dead or target_out_of_range:
      clear_target
    else:
      if can_cast_spell and spell_off_cooldown:
        cast_best_spell(target)  # with 20% chance of picking wrong spell
      else:
        if in_melee_range:
          attack
        else:
          walk_toward(target)
  else:
    if profile == pker:
      scan for nearby players in level range
      if found and random(100) < aggression_pct:
        set_target
        maybe_say(trash_talk_line)  # 30% chance
    elif profile == farmer:
      scan for nearby hostile NPCs
      if found: set_target
    else:
      wander randomly
```

### Imperfect Play

- **Reaction delay:** 200-600ms before responding to a new target or HP change
- **Wrong spell:** 15-20% chance of casting a suboptimal spell
- **Missed opportunity:** 10% chance of doing nothing on a tick (hesitation)
- **Potion fumble:** Sometimes wait 1-2 extra ticks before drinking a potion
- **Chase limit:** Give up chasing after 10-15 tiles (real players get bored)

### Trash Talk Lines (Spanish, in-character)

```
["Dejame tu oro y no te hago nada"
 "Este mapa es mio"
 "Otro mas para la coleccion"
 "Te encontre"
 "No deberias estar aca solo"
 "jaja"
 "?"
 "gg"
 "nos vemos en el cementerio"]
```

### Death and Respawn

When a phantom bot dies:
- Drop inventory items following the same rules as real player death
- Drop gold
- "Respawn" in a city (same as real player death)
- Walk back to their assigned zone after a delay (2-5 minutes)
- Or get reassigned to a different zone (variety)

When a phantom bot kills a player:
- Pick up loot from the ground (like a real PKer would)
- Maybe say "gg" or "gracias"
- Continue wandering or look for next target

### Zone Distribution

```
safe_zones (cities):       socializers only, 2-4 per city
newbie_zones (level 1-15): farmers + cowards, 3-5 per map
mid_zones (level 15-30):   all profiles, 5-8 per map
danger_zones (level 30+):  pkers + farmers, 3-6 per map
dungeons:                  pkers, 1-3 per dungeon floor
```

Total with 15-20 populated maps: ~100-200 bots.

## Name and Appearance Generation

### Names

Maintain a pool of 500+ Spanish-sounding gamer names. Mix styles:
- Fantasy: "Eldric", "Sombra_Roja", "Valkiria"
- Typical MMO: "xDarkKnightx", "Killer_99", "NoobSlayer"
- Normal: "Martin", "Lucas_ar", "Nico"
- Clan-tagged: "[LOS] Cazador", "[DKZ] Sombra"

Never use "Bot_" prefix or sequential numbers. Each phantom gets a name from
the pool on creation.

### Appearance

- Class distribution should roughly match the server's real class distribution
  (if most players are warriors, most phantoms should be too)
- Equipment should match level — a level 30 phantom shouldn't wear newbie gear
- Vary heads/bodies within the available range
- Some phantoms should have no helmet (like real players who prioritize looks)

## Implementation Roadmap

### Phase 1: Combat-Capable Bot (extend `BotArmy.Bot`)

1. Parse AoI server packets: `character_create`, `character_remove`,
   `character_change`, `pos_update` — build a local view of nearby entities
2. Parse combat packets: `user_hit_by`, `update_hp`, `update_mana`
3. Add spell casting packet builder (packet ID for cast_spell)
4. Add potion use packet builder (packet ID for use_item)
5. Implement target selection (scan local entity list)
6. Implement basic combat loop (approach → attack/cast → flee if low)
7. Add `pker` and `farmer` profiles to `random_action/1`

### Phase 2: Human-Like Behavior

1. Add timing jitter to all actions (variable delays, not fixed intervals)
2. Implement imperfect play (wrong spells, hesitation, chase limits)
3. Add trash talk system with random line selection
4. Add flee/potion logic with intentional delays
5. Implement death handling (respawn, walk back to zone)

### Phase 3: Identity and Distribution

1. Name pool generation and assignment
2. Character creation with varied classes, levels, and equipment
3. Zone assignment rules (which maps, how many per map)
4. Spawn staggering (bots arrive over minutes, not all at once)
5. Map rotation (bots occasionally change zones)

### Phase 4: Swarm Management

1. GM command to control phantom population: `/PHANTOMS 200`, `/PHANTOMS 0`
2. Runtime config for aggression levels, zone weights
3. Monitoring: telemetry for phantom count, kills, deaths, disconnects
4. Auto-scaling: spawn more phantoms during low-population hours

## Packet Parsing Needed (Phase 1)

The bot currently only parses `pos_update` (ID 31), `change_map` (ID 30), and
`error_msg` (ID 73). For combat AI, it needs:

| Packet              | ID  | Fields Needed                        |
|--------------------|-----|--------------------------------------|
| `character_create` | 12  | char_index, name, x, y, heading, body, head, class |
| `character_remove` | 14  | char_index                           |
| `character_change` | 13  | char_index, x, y, heading, body, head |
| `update_hp`        | 35  | min_hp, max_hp                       |
| `update_mana`      | 36  | min_mana, max_mana                   |
| `user_hit_by`      | various | source, damage                    |
| `chat_over_head`   | 26  | char_index, message                  |

These are all already defined in `AoProtocol.Server.Encoder` — the bot just
needs decoders for the server→client direction.

## Resource Estimates

### Option A (200 external bots)
- 200 WebSocket connections (trivial for Cowboy)
- 200 session processes (~200 KB RAM total)
- 200 DB character rows (~negligible)
- 200 entries in OnlineDirectory ETS
- ~5-15 entries per MapServer `state.players` map (distributed across maps)
- CPU: AI tick logic runs in bot processes, not MapServer — server only sees
  normal player traffic
- Network: localhost WebSocket, ~1-2 KB/s per bot = ~200-400 KB/s total

### Option C (200 server-side phantoms)
- 0 connections
- 0 session processes
- 200 PlayerEntity structs in MapServer state (distributed)
- CPU: AI tick runs inside MapServer — adds ~1-5ms per map tick
- No network overhead

Both are well within a single server's capacity.

## Open Questions

1. **Should phantoms have persistent progression?** If a phantom kills NPCs and
   levels up over time, it feels more real. But it adds persistence complexity.
   Recommendation: yes, persist phantom characters to DB, run them through the
   same XP/level-up path. The cost is minimal and the realism gain is high.

2. **Should phantoms be in guilds?** Having 2-3 fake guilds with phantom
   members makes guild rankings look populated. But guild chat from phantoms
   could be weird. Recommendation: yes, put some phantoms in guilds, but don't
   have them chat in guild channel.

3. **Should phantoms party with each other?** Groups of 2-3 phantoms hunting
   together is very convincing but adds coordination complexity.
   Recommendation: defer to Phase 5. Solo phantoms are enough for v1.

4. **How to handle GM inspection?** A GM who inspects a phantom will see a
   normal player character. This is fine — phantoms ARE real characters, just
   automated. GMs should know which names are phantoms (a GM command like
   `/ISPHANTOM name` or a flag in the DB).

5. **What happens when server population grows?** Gradually reduce phantom
   count as real players join. At 200+ real players, disable phantoms entirely.
   This should be automatic based on real player count.
