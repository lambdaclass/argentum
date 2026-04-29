defmodule Arena.Map.PlayerDeath do
  @moduledoc """
  Player death handling, inventory drops, and PvP kill tracking.

  `handle_player_death/3` returns `{player, state, effects}` — every
  side effect (unequip slot updates, /HOGAR console, dropped item
  broadcasts, pet despawn character_remove broadcasts) flows through
  the runner. Pet despawn no longer hits the legacy NpcAi side
  channel; `Arena.NpcAi.despawn_pet/3` returns map-layer effects since
  the pet-despawn unification commit.
  """

  alias Arena.Map.Effects
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @doc """
  VB6 deep death: clear all transient combat/status state. Returns
  `{player, state, effects}` — pet despawn effects from
  `Arena.NpcAi.despawn_pet/3` are folded into the same effects list,
  so the runner dispatches every player-facing and pet-removal packet
  uniformly.
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
        dumb: false,
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
    {player, state, drop_effects} =
      if not Map.get(state.meta, :safe_zone, false) do
        drop_inventory_on_death(state, player)
      else
        {player, state, []}
      end

    # Despawn all pets owned by this player. NpcAi.despawn_pet/3 returns
    # map-layer effects, so we accumulate them alongside the rest.
    pet_ids =
      state.npcs_live
      |> Enum.filter(fn {_id, npc} -> npc.owner_id == char_id end)
      |> Enum.map(fn {id, _npc} -> id end)

    {state, pet_effects} =
      Enum.reduce(pet_ids, {state, []}, fn instance_id, {st, accum} ->
        case Map.get(st.npcs_live, instance_id) do
          nil ->
            {st, accum}

          npc ->
            {st, effs} = Arena.NpcAi.despawn_pet(st, instance_id, npc)
            {st, accum ++ effs}
        end
      end)

    # Send unequip slot updates to client
    slot_effects =
      Enum.map(unequipped_slots, fn slot ->
        Effects.send(char_id, encoded_inventory_slot(player.inventory, slot))
      end)

    hogar_effect =
      if not Map.get(state.meta, :safe_zone, false) do
        [
          Effects.send(
            char_id,
            Encoder.encode(
              {:console_msg,
               %{message: "Escribe /HOGAR si deseas regresar rápido a tu hogar.", font_index: 5}}
            )
          )
        ]
      else
        []
      end

    # VB6: MuereEnReto — notify DuelServer when a dueling player dies
    if player.in_duel do
      notify_duel_death(char_id)
    end

    {player, state, drop_effects ++ pet_effects ++ slot_effects ++ hogar_effect}
  end

  defp encoded_inventory_slot(inventory, slot_idx) do
    case Enum.at(inventory, slot_idx) do
      nil ->
        Encoder.encode(
          {:change_inventory_slot,
           %{slot: slot_idx + 1, obj_index: 0, amount: 0, equipped: false, valor: 0.0}}
        )

      item ->
        item_def = GameData.get_item(item.item_id)
        valor = if item_def, do: item_def.valor / 1, else: 0.0

        Encoder.encode(
          {:change_inventory_slot,
           %{
             slot: slot_idx + 1,
             obj_index: item.item_id,
             amount: item.amount,
             equipped: Map.get(item, :equipped, false),
             valor: valor
           }}
        )
    end
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
  # Returns {player, state, effects}.
  defp drop_inventory_on_death(state, player) do
    {new_inventory, state, effects} =
      player.inventory
      |> Enum.with_index()
      |> Enum.reduce({player.inventory, state, []}, fn {item, idx}, {inv, st, effs} ->
        if item != nil do
          item_def = GameData.get_item(item.item_id)
          # VB6: don't drop newbie items or quest items
          newbie = item_def != nil and Map.get(item_def, :newbie, false)

          if newbie do
            {inv, st, effs}
          else
            pos = {player.x, player.y}
            # Only drop if tile doesn't already have a ground item
            if Map.has_key?(st.ground_items, pos) do
              {inv, st, effs}
            else
              elemental_tags = Map.get(item, :elemental_tags, 0)

              ground_items =
                Map.put(st.ground_items, pos, %{
                  item_id: item.item_id,
                  amount: item.amount,
                  elemental_tags: elemental_tags
                })

              st = %{st | ground_items: ground_items}
              effect = object_create_effect(player.x, player.y, item.item_id, item.amount, elemental_tags)

              {List.replace_at(inv, idx, nil), st, effs ++ [effect]}
            end
          end
        else
          {inv, st, effs}
        end
      end)

    {%{player | inventory: new_inventory}, state, effects}
  end

  defp object_create_effect(x, y, item_id, amount, elemental_tags) do
    grh =
      case GameData.get_item(item_id) do
        nil -> 0
        item_def -> item_def.grh_index
      end

    packet =
      Encoder.encode(
        {:object_create,
         %{x: x, y: y, obj_index: grh, amount: amount, elemental_tags: elemental_tags}}
      )

    Effects.broadcast_visible_all(x, y, packet)
  end
end
