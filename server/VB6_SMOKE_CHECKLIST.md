# VB6 Release Smoke Checklist

Manual testing checklist for verifying the Elixir server against the real
(unmodified) VB6 client before releases. Every item must pass before a
compatibility release is tagged.

## Pre-flight

- [ ] Server compiles with `mix compile --warnings-as-errors`
- [ ] All tests pass with `mix test`
- [ ] Database migrations applied: `mix ecto.migrate`
- [ ] Server starts: `mix phx.server` or `iex -S mix`

## Core flows (test with VB6 client)

- [ ] **New account + character creation**: Create account, create character with each class (Guerrero, Mago, Cazador, Trabajador, etc.), verify spawn on correct map
- [ ] **Login/reconnect**: Login with existing character, verify stats/inventory/spells persist
- [ ] **Movement**: Walk in all 4 directions, verify map boundaries, verify walk cooldown (210ms)
- [ ] **Map transfer**: Walk onto exit tile, verify transfer to destination map + position
- [ ] **Chat**: Normal talk, yell, whisper to another player
- [ ] **Combat (PvE)**: Find NPC, attack, verify damage/HP updates, verify XP on kill
- [ ] **Combat (PvP)**: Two players attack each other (on PvP map), verify damage/HP
- [ ] **Spells**: Cast a spell, verify mana drain, verify effect
- [ ] **Items**: Pick up item, drop item, equip/unequip, use item
- [ ] **Inventory**: Verify all inventory slots sync on login
- [ ] **NPC Commerce**: Open NPC shop, buy item, sell item, close
- [ ] **Bank**: Open bank, deposit item, extract item, deposit/extract gold, close
- [ ] **User-to-user trade**: Two players trade items, verify both sides
- [ ] **Skills**: Verify skill values on login, use skill (mining, fishing, etc.)
- [ ] **Rest/Meditate**: Start resting, verify HP/mana regen, stop by walking
- [ ] **Safe mode**: Toggle safe mode on/off, verify combat restrictions
- [ ] **Guild**: Create guild, invite member, guild chat, leave guild
- [ ] **Faction**: Join/leave faction, faction chat
- [ ] **Hunger/Thirst**: Verify hunger/thirst decrease over time, eat/drink to restore
- [ ] **Death/Resurrect**: Die in combat, verify dead state, resurrect
- [ ] **GM commands**: Test key GM commands (warp, summon, kick)
- [ ] **Disconnect/cleanup**: Disconnect client, verify session cleanup, reconnect

## Performance

- [ ] 10+ concurrent VB6 clients connected without issues
- [ ] No memory leaks after 30 minutes of play
- [ ] Walk interval feels correct (not too fast, not too slow)

## Regression signals

- [ ] No `unknown_packet` warnings in server logs during normal play
- [ ] No Ecto/DB errors in server logs
- [ ] No Ranch connection crashes in server logs
