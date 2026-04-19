# Drift

Confirmed open backend drift against the inspected VB6 baseline.

Scope rules:
- Only include functionality that was enabled and working in the inspected VB6 baseline.
- Only include items confirmed from current code plus a VB6 reference.
- Keep fixed items out of this file once they land; they belong in `CHANGELOG.md`.
- Use `Needs Verification` for suspicious items that are not proven yet.

## NPC, Service, and Gameplay Flows

1. `TrainList` still uses the wrong trainer targeting model.
Current:
- `server/apps/arena/lib/arena/map/npc_interaction.ex`
- `server/apps/arena/lib/arena/map/helpers.ex`
VB6:
- `old/server/Codigo/Protocol.bas:4211`
- `old/server/Codigo/Protocol.bas:4226`
- `old/server/Codigo/Matematicas.bas:117`
Notes:
- Current code resolves a nearby trainer through `find_nearby_npc_of_type/4`.
- VB6 requires selected `TargetNPC` plus `Distancia <= 10`.
- Current helper still uses square-range checks instead of VB6 `Distancia`.

2. The `Train` packet / trainer-creature flow is still missing.
Current:
- `server/apps/ao_protocol/lib/ao_protocol/client/decoder.ex`
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_logic.ex`
VB6:
- `old/server/Codigo/Protocol.bas:3141`
Notes:
- Current backend still hard-rejects `:train`.
- VB6 uses it to spawn trainer creatures from the selected trainer.

3. Gambling still uses the wrong NPC-targeting model.
Current:
- `server/apps/arena/lib/arena/map/npc_interaction.ex`
- `server/apps/arena/lib/arena/map/helpers.ex`
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:181`
- `old/server/Codigo/Matematicas.bas:117`
Notes:
- Win odds and amount handling are now closer.
- The remaining drift is target resolution: current code accepts any nearby timbero, while VB6 requires selected `TargetNPC` plus `Distancia <= 10`.

4. Priest-driven flows still use the wrong NPC-targeting model.
Current:
- `server/apps/arena/lib/arena/map/healing.ex`
- `server/apps/arena/lib/arena/map/npc_interaction.ex`
- `server/apps/arena/lib/arena/map/social.ex`
- `server/apps/arena/lib/arena/map/helpers.ex`
VB6:
- `old/server/Codigo/Protocol.bas:4378`
- `old/server/Codigo/Protocol.bas:4408`
- `old/server/Codigo/Protocol.bas:5563`
- `old/server/Codigo/Protocol.bas:6358`
- `old/server/Codigo/Matematicas.bas:117`
Notes:
- Heal, resurrect, forgive, and marriage still resolve “any nearby priest”.
- VB6 requires selected `TargetNPC` plus per-flow `Distancia` checks.

5. `/HOGAR` timers are still simplified.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_transfer.ex`
VB6:
- `old/server/Codigo/Hogar.bas:33`
Notes:
- The duel/reto block is already in place.
- Current code only distinguishes GM `5s` vs non-GM `10s`.
- VB6 has separate non-GM timer buckets by user type.

6. `Ocultarse`/hiding is still much simpler than VB6.
Current:
- `server/apps/arena/lib/arena/map/social.ex`
VB6:
- `old/server/Codigo/Trabajo.bas:107`
Notes:
- Current code uses a flat skill check and simple timer.
- VB6 has recent-hit cooldown, nonlinear chance, class-specific duration, and pirate behavior while sailing.

7. Taming is still much simpler than VB6.
Current:
- `server/apps/arena/lib/arena/map/crafting.ex`
VB6:
- `old/server/Codigo/Trabajo.bas:1719`
- `old/server/Codigo/Trabajo.bas:1796`
Notes:
- Current code uses a generic skill check and nearest hostile NPC.
- VB6 uses charisma, druid scaling, tame-level thresholds, duplicate-pet limits, and safe-zone rules.

8. Crafting production is still structurally different.
Current:
- `server/apps/arena/lib/arena/map/crafting.ex`
VB6:
- `old/server/Codigo/Acciones.bas:483`
- `old/server/Codigo/InvUsuario.bas:1859`
Notes:
- Current blacksmithing/carpentry/alchemy/tailoring depend on nearby workstation NPC types.
- VB6 ties blacksmithing to workstation objects and the other craft forms to equipped tool use.

9. The duel system is still simplified.
Current:
- `server/apps/arena/lib/arena/duel_server.ex`
Notes:
- Current code explicitly keeps players on the same map.
- VB6 used dedicated duel-room maps.

10. Treasure NPC events are still incomplete.
Current:
- `server/apps/arena/lib/arena/treasure_event.ex`
Notes:
- The `:npc` treasure path still returns `npc_instance_id: nil` and does not actually spawn the NPC.

## Pets

11. `PetStand` and `PetFollow` still target all pets instead of the selected pet.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_logic.ex`
- `server/apps/arena/lib/arena/map/pets.ex`
VB6:
- `old/server/Codigo/Protocol.bas:4052`
- `old/server/Codigo/Protocol.bas:4087`
- `old/server/Codigo/Matematicas.bas:117`
Notes:
- Current code changes every owned pet and does not require a selected target or distance check.
- VB6 requires selected `TargetNPC`, `Distancia <= 10`, and ownership validation.

12. `PetFollowAll` is missing.
Current:
- no current decode/handler path
VB6:
- `old/server/Codigo/Protocol.bas:4117`
- `old/server/Codigo/PacketId.bas:547`

## Economy and Banking

13. Bank gold transfer is the wrong feature.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_logic.ex`
VB6:
- `old/server/Codigo/Protocol.bas:6000`
Notes:
- Current code moves wallet gold directly to an online target.
- VB6 requires a selected banker, uses bank-account gold, supports offline delivery, rate limits transfers, and blocks GM use.

## Support and GM

14. `QuestionGM` no longer enqueues the SOS/support queue.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_logic.ex`
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:3348`
- `old/server/Codigo/Protocol_GmCommands.bas:3380`
Notes:
- Current code only broadcasts a generic support notice to GMs and logs the text.
- VB6 pushes the request into the `Ayuda` queue and notifies GMs.

15. `RoleMasterRequest` is routed to all GMs instead of role masters.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_logic.ex`
- `server/apps/ao_session/lib/ao_session/online_directory.ex`
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:119`
Notes:
- Current code uses `broadcast_to_gms/1`.
- VB6 sends the request to `ToRolesMasters`.

16. Support cooldown semantics still drift from VB6.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_logic.ex`
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:111`
- `old/server/Codigo/Protocol_GmCommands.bas:3372`
Notes:
- Current code uses one shared `30_000ms` cooldown for both `/GM` and `/ROL`.
- VB6 applies a 5-minute limit to `QuestionGM`, and the shown `RoleMasterRequest` path does not use the same limiter.

17. SOS GM commands are still stubbed.
Current:
- `server/apps/ao_tcp_gateway/lib/ao_tcp_gateway/session_commands/gm.ex`
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:681`
- `old/server/Codigo/Protocol_Writes.bas:2566`
Notes:
- `sos_show_list`, `sos_remove`, and `clean_sos` still return canned messages instead of operating on a real queue.

18. GM `/GOTO` bypasses the old `GoNearby` restrictions.
Current:
- `server/apps/arena/lib/arena/map/gm/teleport.ex`
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:354`
- `old/server/Codigo/Protocol_GmCommands.bas:385`
- `old/server/Codigo/Protocol_GmCommands.bas:412`
Notes:
- Current code teleports directly to any found player.
- VB6 gates lower-tier usage through the SOS queue and additional safety checks.

## Needs Verification

1. Crafting NPC type collision is suspicious but not proven.
Current:
- `server/apps/arena/lib/arena/map/crafting.ex`
- `server/apps/arena/lib/arena/map/npc_interaction.ex`
Notes:
- Do not treat this as confirmed until it is matched against real data and VB6 behavior.

2. GM panel request path appears missing, but the exact client-side trigger still needs proof.
Current:
- `server/apps/ao_protocol/lib/ao_protocol/server/encoder.ex`
VB6:
- `old/server/Codigo/Protocol_GmCommands.bas:764`
- `old/server/Codigo/Protocol_Writes.bas:2605`
Notes:
- The server encoder for `show_gm_panel_form` exists.
- I have not yet found the corresponding live inbound request path in the current backend.
