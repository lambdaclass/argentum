defmodule Arena.Map.PlayerDeath do
  @moduledoc "Player death handling, inventory drops, and PvP kill tracking."

  alias Arena.Map.Helpers
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @doc """
  VB6 deep death: clear all transient combat/status state.
  Called from every path that sets dead: true.
  Despawns pets owned by the dying player.
  """
  def handle_player_death(state, char_id, player) do
    player = %{
      player
      | dead: true,
        deaths: player.deaths + 1,
        stamina: 0,
        hunger: 0,
        thirst: 0,
        paralyzed: false,
        blind: false,
        invisible: false,
        oculto: false,
        oculto_timer: 0,
        mounted: false,
        poisoned: false,
        meditating: false,
        resting: false,
        immobilized: false,
        buffs: [],
        commerce_npc_id: nil,
        bank_npc_id: nil,
        trade_partner_id: nil,
        trade_request_target: nil,
        trade_offer_gold: 0,
        trade_offer_items: [],
        trade_accepted: false
    }

    # VB6: unequip all equipped items on death
    {player, unequipped_slots} = unequip_all_on_death(player)

    # VB6: TirarTodosLosItems — drop inventory on ground in unsafe zones
    {player, state} =
      if not Map.get(state.meta, :safe_zone, false) do
        drop_inventory_on_death(state, player)
      else
        {player, state}
      end

    # Despawn all pets owned by this player
    pet_ids =
      state.npcs_live
      |> Enum.filter(fn {_id, npc} -> npc.owner_id == char_id end)
      |> Enum.map(fn {id, _npc} -> id end)

    state =
      Enum.reduce(pet_ids, state, fn instance_id, st ->
        case Map.get(st.npcs_live, instance_id) do
          nil -> st
          npc ->
            {st, effects} = Arena.NpcAi.despawn_pet(st, instance_id, npc)
            Arena.NpcAi.dispatch_effects(st, effects)
            st
        end
      end)

    # Send unequip slot updates to client
    for slot <- unequipped_slots do
      Helpers.send_inventory_slot(state.sessions, char_id, player.inventory, slot)
    end

    # VB6: /HOGAR message in unsafe zones
    if not Map.get(state.meta, :safe_zone, false) do
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw,
         Encoder.encode(
           {:console_msg, %{message: "Escribe /HOGAR si deseas regresar rápido a tu hogar.", font_index: 5}}
         )}
      )
    end

    # VB6: MuereEnReto — notify DuelServer when a dueling player dies
    if player.in_duel do
      notify_duel_death(char_id)
    end

    {player, state}
  end

  # VB6: CriminalesMatados / ciudadanosMatados — track kill type based on victim status
  def update_pvp_kill_counters(attacker, defender) do
    cond do
      # Victim is criminal or chaos faction → increment criminals_killed
      defender.criminal or defender.faction in [:chaos_legion] ->
        %{attacker | criminals_killed: attacker.criminals_killed + 1}

      # Victim is citizen or armada faction → increment citizens_killed
      not defender.criminal and defender.faction in [:none, :royal_army] ->
        %{attacker | citizens_killed: attacker.citizens_killed + 1}

      true ->
        attacker
    end
  end

  # Asynchronously notify DuelServer about a duel participant's death.
  # Uses spawn to avoid blocking the MapServer process.
  defp notify_duel_death(char_id) do
    spawn(fn ->
      try do
        Arena.DuelServer.player_died(char_id)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # Unequip all equipped items. Returns {updated_player, list_of_changed_slot_indices}.
  defp unequip_all_on_death(player) do
    {new_inventory, changed_slots} =
      player.inventory
      |> Enum.with_index()
      |> Enum.reduce({player.inventory, []}, fn {item, idx}, {inv, slots} ->
        if item != nil and item.equipped do
          new_item = %{item | equipped: false}
          {List.replace_at(inv, idx, new_item), [idx | slots]}
        else
          {inv, slots}
        end
      end)

    equipment = %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil}
    player = %{player | inventory: new_inventory, equipment: equipment}
    {player, changed_slots}
  end

  # Drop all non-newbie items on the ground at player position.
  # VB6: TirarTodosLosItems — drops each item from inventory to the floor.
  defp drop_inventory_on_death(state, player) do
    {new_inventory, state} =
      player.inventory
      |> Enum.with_index()
      |> Enum.reduce({player.inventory, state}, fn {item, idx}, {inv, st} ->
        if item != nil do
          item_def = GameData.get_item(item.item_id)
          # VB6: don't drop newbie items or quest items
          newbie = item_def != nil and Map.get(item_def, :newbie, false)

          if newbie do
            {inv, st}
          else
            pos = {player.x, player.y}
            # Only drop if tile doesn't already have a ground item
            st =
              unless Map.has_key?(st.ground_items, pos) do
                ground_items =
                  Map.put(st.ground_items, pos, %{
                    item_id: item.item_id,
                    amount: item.amount,
                    elemental_tags: Map.get(item, :elemental_tags, 0)
                  })

                st = %{st | ground_items: ground_items}

                Helpers.broadcast_object_create(
                  st,
                  player.x,
                  player.y,
                  item.item_id,
                  item.amount,
                  Map.get(item, :elemental_tags, 0)
                )

                st
              else
                st
              end

            {List.replace_at(inv, idx, nil), st}
          end
        else
          {inv, st}
        end
      end)

    {%{player | inventory: new_inventory}, state}
  end
end
