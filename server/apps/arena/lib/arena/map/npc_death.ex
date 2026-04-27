defmodule Arena.Map.NpcDeath do
  @moduledoc """
  Consolidated NPC death handling.

  All NPC death scenarios funnel through `resolve_npc_death/4` to avoid
  duplicating the occupancy-clear / broadcast-remove / respawn-schedule /
  reward sequence across combat_handlers, spell_effects, npc_ai, and
  gm_commands.

  Returns `{entity_or_nil, state, effects}` — uniform shape regardless of
  whether a `killer_entity` was provided. When no killer is given the
  entity slot is `nil`.

  ## Options

    * `:killer_char_id`  — the player character id that killed the NPC (nil when
      killed by another NPC or a GM command).
    * `:killer_entity`   — the player entity struct of the killer (needed for XP /
      loot / quest rewards). When nil, no player rewards are given.
    * `:final_damage`    — damage dealt on the killing blow (used for per-hit XP).
    * `:source`          — `:melee`, `:spell`, `:pet`, `:gm`, or `:gm_perm`.
    * `:permanent`       — if true, the NPC is deleted from npcs_live with no
      respawn (GM /KILLNPCPERM and /MASSKILL).
    * `:send_mana_update` — if true, append an `update_mana` packet to the
      killer's effects (spell kills need this).
  """

  alias Arena.Data.GameData
  alias Arena.Map.{Effects, Helpers}
  alias AoProtocol.Server.Encoder

  @doc """
  Handle the death of an NPC instance. Returns
  `{entity_or_nil, state, effects}`.
  """
  def resolve_npc_death(state, instance_id, npc, opts \\ []) do
    killer_char_id = Keyword.get(opts, :killer_char_id)
    killer_entity = Keyword.get(opts, :killer_entity)
    final_damage = Keyword.get(opts, :final_damage, 0)
    _source = Keyword.get(opts, :source, :melee)
    permanent = Keyword.get(opts, :permanent, false)
    send_mana_update = Keyword.get(opts, :send_mana_update, false)

    npc_def = GameData.get_npc(npc.npc_id)
    is_pet = npc.owner_id != nil

    # --- 1. Mark NPC dead or remove entirely ---
    state =
      cond do
        is_pet ->
          # Pets are removed from npcs_live and owner's pet_ids
          handle_pet_removal(state, instance_id, npc)

        permanent ->
          # GM permanent kill — delete from npcs_live, no respawn
          npcs_live = Map.delete(state.npcs_live, instance_id)
          %{state | npcs_live: npcs_live}

        true ->
          # Normal wild NPC death — schedule respawn
          respawn_delay = if npc_def, do: npc_def.intervalo_respawn, else: 60

          dead_npc = %{
            npc
            | alive: false,
              respawn_at: System.monotonic_time(:millisecond) + respawn_delay * 1000
          }

          put_in(state.npcs_live[instance_id], dead_npc)
      end

    # --- 2. Clear occupancy ---
    occupancy = Helpers.clear_occupancy(state.occupancy, npc.x, npc.y)
    state = %{state | occupancy: occupancy}

    # --- 3. Broadcast NPC removal ---
    remove_effect =
      Effects.broadcast_visible_all(
        npc.x,
        npc.y,
        Encoder.encode({:character_remove, %{char_index: npc.char_index}})
      )

    # --- 4. Player rewards (only for player-killed wild NPCs) ---
    cond do
      killer_entity != nil and killer_char_id != nil and not is_pet and not permanent ->
        {entity, state, reward_effects} =
          award_player_rewards(state, killer_char_id, killer_entity, npc, npc_def, final_damage, instance_id)

        mana_effects =
          if send_mana_update,
            do: [Effects.send(killer_char_id, Encoder.encode({:update_mana, %{min_mana: entity.mana}}))],
            else: []

        {entity, state, [remove_effect | reward_effects] ++ mana_effects}

      killer_entity != nil and killer_char_id != nil and is_pet ->
        # Killing a pet: no rewards, but still return the killer entity
        entity = killer_entity

        mana_effects =
          if send_mana_update,
            do: [Effects.send(killer_char_id, Encoder.encode({:update_mana, %{min_mana: entity.mana}}))],
            else: []

        {entity, state, [remove_effect | mana_effects]}

      true ->
        {nil, state, [remove_effect]}
    end
  end

  # --- Private helpers ---

  defp handle_pet_removal(state, instance_id, npc) do
    # Remove pet from npcs_live entirely (pets don't respawn)
    npcs_live = Map.delete(state.npcs_live, instance_id)
    state = %{state | npcs_live: npcs_live}

    # Remove instance_id from owner's pet_ids
    case Map.get(state.players, npc.owner_id) do
      nil ->
        state

      owner ->
        owner = %{owner | pet_ids: List.delete(owner.pet_ids, instance_id)}
        players = Map.put(state.players, npc.owner_id, owner)
        %{state | players: players}
    end
  end

  defp award_player_rewards(state, char_id, entity, npc, npc_def, final_damage, instance_id) do
    # Per-hit XP on the killing blow
    {entity, state, xp_effects} =
      Arena.Map.CombatHandlers.award_hit_xp(state, char_id, entity, final_damage, npc_def, instance_id)

    # Increment kill counter
    entity = %{entity | npcs_killed: entity.npcs_killed + 1}

    # Track quest NPC kill progress
    npc_id_for_quest = if npc_def, do: npc_def.id, else: 0

    entity =
      if npc_id_for_quest > 0,
        do: Arena.QuestServer.record_npc_kill(entity, npc_id_for_quest),
        else: entity

    # Notify invasion system about NPC kill
    Arena.Events.InvasionServer.notify_npc_killed(state.map_id, instance_id)

    # Award guild XP on NPC kill
    give_exp = if npc_def, do: npc_def.give_exp, else: 0

    if give_exp > 0 do
      case Arena.GuildServer.guild_id_for(char_id) do
        nil -> :ok
        gid -> Arena.GuildServer.add_guild_exp(gid, max(div(give_exp, 10), 1))
      end
    end

    # VB6: NPCTirarOro — drop gold on the floor at NPC position
    give_gld = if npc_def, do: npc_def.give_gld, else: 0
    {state, gold_effects} = Arena.Map.CombatHandlers.drop_npc_gold(state, npc, give_gld)

    # Drop loot
    {state, loot_effects} = Arena.Map.CombatHandlers.drop_npc_loot(state, npc, npc_def)

    # Persist entity into state
    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}

    {entity, state, xp_effects ++ gold_effects ++ loot_effects}
  end
end
