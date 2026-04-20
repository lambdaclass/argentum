# Drift

Confirmed open backend drift against the inspected VB6 baseline.

Scope rules:
- Only include functionality that was enabled and working in the inspected VB6 baseline.
- Only include items confirmed from current code plus a VB6 reference.
- Keep fixed items out of this file once they land; they belong in `CHANGELOG.md`.
- Use `Needs Verification` for suspicious items that are not proven yet.

## NPC, Service, and Gameplay Flows

1. GM panel request path is missing.
Current:
- `server/apps/ao_protocol/lib/ao_protocol/server/encoder.ex` (encoder for packet 84 exists)
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:764` (`HandleGMPanel`)
- `old/server/Codigo/Protocol_Writes.bas:2605` (`WriteShowGMPanelForm`)
- Client sends packet 116 (`eGMPanel` / `/PANELGM`)
Notes:
- The Elixir server has the outbound encoder for `show_gm_panel_form` (packet 84) but no
  inbound decoder for packet 116, no route, and no handler. The encoder is never called.
- Needs: decoder for packet 116, route in SessionRouteManifest, handler that reads
  character appearance data and sends it back via the encoder.

2. NPC melee poison always applies; VB6 rolls a 30% chance.
Current:
- `server/apps/arena/lib/arena/npc_ai.ex:723-743` — `if npc_def.veneno > 0 and not poisoned`
  applies the poison debuff unconditionally on every landed hit.
VB6:
- `old/server/Codigo/MODULO_NPCs.bas:780-794` (`NpcEnvenenarUser`) — rolls
  `n = RandomNumber(1, 100)` and only poisons when `n < 30`.
- Called from `old/server/Codigo/SistemaCombate.bas:614`.
Notes:
- CHANGELOG `(2026-04-19)` records that the `veneno` field was added; the probabilistic
  gate was dropped along the way. `npc_ai_parity_test.exs` asserts unconditional
  application, so it encodes the drift.
- Needs: gate the poison application on a 1–100 roll < 30 (using whatever RNG source
  npc_ai already uses) and relax the test to allow both outcomes.

3. Binary duel packets (`eDuel`, `eAcceptDuel`, `eCancelDuel`, `eQuitDuel`) are unrouted.
Current:
- `server/apps/ao_protocol/lib/ao_protocol/client/decoder.ex` — no decoder cases for the
  four duel packet ids.
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_route_manifest.ex` — no duel routes.
- Duels work only via the text `/RETO` command parsed in
  `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_commands/chat.ex:195-206`.
VB6:
- `old/server/Codigo/PacketId.bas:454-457` (packet ids `eDuel`..`eQuitDuel`).
- `old/server/Codigo/Protocol.bas:725-732` (dispatch).
- `old/server/Codigo/Protocol.bas:5931-5981` (`HandleDuel`, `HandleAcceptDuel`,
  `HandleCancelDuel`, `HandleQuitDuel`). `HandleDuel` reads `Players`, `Bet`,
  `PocionesMaximas`, `CaenItems` — the text path loses the potion cap and "items drop"
  fields.
Notes:
- Needs: four decoders, routes, and handlers mapping to `Arena.DuelServer`. The handlers
  must also honour `pociones_maximas` and `caen_items`, which the text command never sets.

4. `:royal_army_message` / `:chaos_legion_message` are gated GM-only; VB6 also allows
   faction council members.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_route_manifest.ex:62-63,361-362` —
  grouped under `:gm`.
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_logic.ex:85-93` — the `:gm` group
  is dispatched only when `state.is_gm == true`, otherwise replies "No tienes privilegios".
- `server/apps/arena/lib/arena/map/gm/permissions.ex:85` — `/RMSG /CMSG` require `:dios`
  tier on the text path too.
VB6:
- `old/server/Codigo/Protocol.bas:5177-5209` (`HandleRoyalArmyMessage`,
  `HandleChaosLegionMessage`) — sends when the user has GM privileges **or**
  `.Faccion.Status = e_Facciones.consejo` / `.concilio`.
Notes:
- Council-rank Royal Army / Chaos Legion members cannot broadcast over the council
  channel in Elixir.
- Needs: either split the routes out of the GM group with a council-or-GM guard, or let
  the GM handler fall through to a council-rank path before rejecting.

5. Inventory size does not expand with patron tier; stays at 24 slots.
Current:
- `server/apps/arena/lib/arena/inventory.ex:11` — `@max_slots 24` (hardcoded).
- `server/apps/arena/lib/arena/map/commerce.ex:188` — `slot < 1 or slot > 24` hard bound.
- Patron tier is already plumbed into `PlayerEntity` per the 2026-04-19 `/HOGAR` work, but
  nothing reads it for inventory sizing.
VB6:
- `old/server/Codigo/Declares.bas:1480,1484` — `MAX_INVENTORY_SLOTS = 42`,
  `MAX_USERINVENTORY_SLOTS = 24` (base).
- `old/server/Codigo/CharacterPersistence.bas:95-109` (`get_num_inv_slots_from_tier`) —
  base 24 + 6 for Aventurero, +12 for Heroe, +18 for Leyenda.
Notes:
- Heroe/Leyenda/Aventurero accounts should see extra inventory slots; in Elixir they never
  do.
- Needs: derive the slot count from the account tier at character load and thread it
  through `Inventory` / `Commerce` slot validations (currently hardcoded to 24).

6. Max active quests is 20 in Elixir; VB6 cap is 5.
Current:
- `server/apps/arena/lib/arena/quest_server.ex:11` — `@max_active_quests 20`.
- `can_accept_quest?` in the same file gates on this value.
VB6:
- `old/server/Codigo/Declares.bas:1474` — `MAXUSERQUESTS As Integer = 5`.
- Enforced in `old/server/Codigo/ModQuest.bas:38,53,321` and
  `old/server/Codigo/Protocol.bas:7103-7118` (quest slot write path rejects `Slot > 5`).
Notes:
- Players can currently hold four times the intended number of quests simultaneously.
- Needs: drop `@max_active_quests` to 5. Check whether existing save data has >5 active
  quests and decide on truncation vs. grandfathering before changing.

7. Commerce sell accepts items flagged `Destruye`.
Current:
- `server/apps/arena/lib/arena/map/commerce.ex:172-317` (`handle_commerce_sell`) — checks
  `newbie`, `instransferible`, quest items, gold, and equipped items, but never consults
  `item_def.destruye` even though the field exists on the item struct.
VB6:
- `old/server/Codigo/Comercio.bas:104-107` — `ElseIf ObjData(ObjIndex).Destruye = 1 Then …
  WriteLocaleMsg MSG_NO_SIENTO_PUEDO_COMPRARTE_ESE_ITEM; Exit Sub`.
Notes:
- Needs: add a `destruye` guard to the sell cond chain, with the "Lo siento, no puedo
  comprarte ese item." message.

8. Commerce sell price ignores the Trabajador worker-class discount.
Current:
- `server/apps/arena/lib/arena/map/commerce.ex:260` — `sell_price = div(item_def.valor, 3) * amount`
  (flat /3 for every class).
VB6:
- `old/server/Codigo/Comercio.bas:294-310` (`SalePrice`) — base denom = `REDUCTOR_PRECIOVENTA`
  (3, line 34); for `e_Class.Trabajador` subtracts `level * 0.025` from the denom (clamped
  at 2). Gated behind `IsFeatureEnabled("destroy_npc_bought_items")`.
- `old/server/Example.feature_toggle.ini:60-62` — `destroy_npc_bought_items = 1` in the
  shipped baseline, so the discount path is active.
Notes:
- A level 40 Trabajador should get denom ≈ 2 (max sell price); Elixir always returns
  `valor / 3`.
- Needs: compute the denominator per class+level when selling and keep the float math
  (`Fix(valor / denom)`) to match VB6 rounding.

9. Commerce sell does not block junior-GM classes (`Consejero`, `SemiDios`).
Current:
- `server/apps/arena/lib/arena/map/commerce.ex:172-317` — no privilege check in the sell
  path. Only the merchant open/buy path guards against gm_class.
VB6:
- `old/server/Codigo/Comercio.bas:130-133` — `If Privilegios And (Consejero Or SemiDios)
  Then MSG_NO_PODES_VENDER_ITEMS; Exit Sub`.
Notes:
- Consejero/SemiDios characters can launder items into gold on Elixir while VB6 blocks
  them. Lower severity than 1-8 because these roles are staff-controlled.
- Needs: reject the sell when the caller's privilege flags contain Consejero or SemiDios.

10. `eChatColor` (`/CHATCOLOR`) handler missing.
Current:
- No references to `chat_color` / `ChatColor` in `server/apps`. Decoder, route, and
  character flag are absent.
VB6:
- `old/server/Codigo/PacketId.bas:438` (`eChatColor`).
- `old/server/Codigo/Protocol.bas:695-696,5548-5561` (`HandleChatColor`) — GM-only: reads
  three `Int8` bytes as `RGB` and stores in `flags.ChatColor`.
- `old/server/Codigo/Modulo_UsUaRiOs.bas:602-624` sets defaults by faction/role.
- Consumed by chat broadcasts, e.g. `old/server/Codigo/Protocol.bas:1503`.
Notes:
- GMs can't customise their chat colour on Elixir, and player chat does not carry a
  per-player colour at all (all text uses the font default).
- Needs: add the `flags.ChatColor` state, decoder for `eChatColor`, GM-gated handler, and
  include the colour on outbound chat-over-head / console broadcasts.

## Needs Verification

No items pending verification.
