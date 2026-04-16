defmodule Arena.Map.Faction do
  @moduledoc "Faction system handlers (VB6: ModFacciones)."

  alias Arena.Map.Helpers
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_enlistador 5

  defp msg(state, char_id, message), do: Helpers.msg(state, char_id, message)
  defdelegate find_nearby_npc_of_type(state, entity, npc_types), to: Helpers

  defp npc_faccion_to_atom(3), do: :royal_army
  defp npc_faccion_to_atom(2), do: :chaos_legion
  defp npc_faccion_to_atom(_), do: :none

  def handle_enlistador_click(state, char_id, entity, npc_def) do
    npc_faction = npc_faccion_to_atom(npc_def.faccion)

    cond do
      entity.dead ->
        msg(state, char_id, "Estas muerto!")
        {:noreply, state}

      npc_faction == :none ->
        msg(state, char_id, "#{npc_def.name} no puede enlistarte.")
        {:noreply, state}

      entity.faction == npc_faction ->
        handle_faction_rank_up(state, char_id, entity, npc_faction)

      entity.faction != :none ->
        msg(state, char_id, "Ya perteneces a una faccion. Usa /RENUNCIAR primero.")
        {:noreply, state}

      npc_faction == :royal_army and entity.criminal ->
        msg(state, char_id, "Los criminales no pueden enlistarse en la Armada Real.")
        {:noreply, state}

      npc_faction == :royal_army and entity.citizens_killed > 0 ->
        msg(state, char_id, "Has asesinado ciudadanos inocentes. No puedes enlistarte en la Armada Real.")
        {:noreply, state}

      npc_faction == :royal_army and entity.class in [:thief, :bandit, :assassin, :pirate] ->
        msg(state, char_id, "Tu clase no puede enlistarse en la Armada Real.")
        {:noreply, state}

      true ->
        ranks = GameData.faction_ranks(npc_faction)
        rank1 = List.first(ranks)

        cond do
          rank1 != nil and entity.level < rank1.required_level ->
            msg(state, char_id, "Necesitas nivel #{rank1.required_level} para enlistarte.")
            {:noreply, state}

          true ->
            entity = %{entity | faction: npc_faction}
            entity = assign_rank(entity, npc_faction, 1)
            {entity, state} = give_faction_rewards(entity, state, char_id, npc_faction, 0, 1)
            players = Map.put(state.players, char_id, entity)

            AoSession.OnlineDirectory.update_faction(char_id, npc_faction)

            faction_name = faction_display_name(npc_faction)
            msg(%{state | players: players}, char_id, "Te has enlistado en #{faction_name}.")
            {:noreply, %{state | players: players}}
        end
    end
  end

  defp handle_faction_rank_up(state, char_id, entity, faction) do
    current_rank = current_faction_rank(entity, faction)
    ranks = GameData.faction_ranks(faction)
    next_rank_def = Enum.find(ranks, fn r -> r.rank == current_rank + 1 end)

    cond do
      next_rank_def == nil ->
        msg(state, char_id, "Ya tienes el rango maximo.")
        {:noreply, state}

      entity.level < next_rank_def.required_level ->
        needed = next_rank_def.required_level - entity.level
        msg(state, char_id, "Te faltan #{needed} niveles para poder recibir la proxima recompensa.")
        {:noreply, state}

      entity.faction_score < next_rank_def.required_score ->
        needed = next_rank_def.required_score - entity.faction_score
        msg(state, char_id, "Te faltan #{needed} puntos de faccion para subir de rango.")
        {:noreply, state}

      true ->
        new_rank = next_rank_def.rank
        entity = assign_rank(entity, faction, new_rank)
        {entity, state} = give_faction_rewards(entity, state, char_id, faction, current_rank, new_rank)
        players = Map.put(state.players, char_id, entity)

        msg(%{state | players: players}, char_id, "Has ascendido al rango #{new_rank}: #{next_rank_def.title}!")
        {:noreply, %{state | players: players}}
    end
  end

  defp current_faction_rank(entity, :royal_army), do: entity.faction_rank_armada
  defp current_faction_rank(entity, :chaos_legion), do: entity.faction_rank_chaos

  defp assign_rank(entity, :royal_army, rank), do: %{entity | faction_rank_armada: rank}
  defp assign_rank(entity, :chaos_legion, rank), do: %{entity | faction_rank_chaos: rank}

  defp give_faction_rewards(entity, state, char_id, faction, old_rank, new_rank) do
    rewards = GameData.faction_rewards(faction)

    rewards_to_give =
      Enum.filter(rewards, fn r -> r.rank > old_rank and r.rank <= new_rank end)

    Enum.reduce(rewards_to_give, {entity, state}, fn reward, {ent, st} ->
      item_def = GameData.get_item(reward.obj_index)

      if item_def == nil do
        {ent, st}
      else
        case Arena.Inventory.add_item(ent.inventory, reward.obj_index, 1) do
          {:ok, new_inv, slot} ->
            ent = %{ent | inventory: new_inv}
            Helpers.send_inventory_slot(st.sessions, char_id, new_inv, slot)
            msg(st, char_id, "Has recibido #{item_def.name}.")
            {ent, st}

          _ ->
            msg(st, char_id, "No tienes espacio para #{item_def.name}.")
            {ent, st}
        end
      end
    end)
  end

  def handle_enlist_faction(state, char_id, faction) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case find_nearby_enlistador(state, entity, faction) do
          {:ok, _npc, npc_def} ->
            handle_enlistador_click(state, char_id, entity, npc_def)

          :not_found ->
            msg(state, char_id, "Necesitas estar cerca de un enlistador para enlistarte.")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp find_nearby_enlistador(state, entity, faction) do
    expected_faccion =
      case faction do
        :royal_army -> 3
        :chaos_legion -> 2
      end

    result =
      Enum.find_value(state.npcs_live, fn {_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)

        if npc_def != nil and
             npc_def.npc_type == @npc_type_enlistador and
             npc_def.faccion == expected_faccion and
             abs(npc.x - entity.x) <= 5 and
             abs(npc.y - entity.y) <= 5 do
          {npc, npc_def}
        end
      end)

    case result do
      {npc, npc_def} -> {:ok, npc, npc_def}
      nil -> :not_found
    end
  end

  def handle_leave_faction(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.faction == :none do
          msg(state, char_id, "No perteneces a ninguna faccion.")
          {:noreply, state}
        else
          case find_nearby_npc_of_type(state, entity, [@npc_type_enlistador]) do
            :not_found ->
              msg(state, char_id, "Necesitas estar cerca de un enlistador.")
              {:noreply, state}

            {:ok, _npc, _npc_def} ->
              entity = strip_faction_items(entity)
              entity = %{entity | faction: :none, faction_reenlistadas: entity.faction_reenlistadas + 1}
              players = Map.put(state.players, char_id, entity)

              AoSession.OnlineDirectory.update_faction(char_id, :none)

              Enum.each(0..23, fn slot ->
                Helpers.send_inventory_slot(state.sessions, char_id, entity.inventory, slot)
              end)

              state = %{state | players: players}
              Helpers.broadcast_character_change(state, entity)

              msg(state, char_id, "Has renunciado a tu faccion.")
              {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  defp strip_faction_items(entity) do
    alias Arena.Data.GameData

    Enum.reduce(0..(length(entity.inventory) - 1), entity, fn slot_idx, ent ->
      case Enum.at(ent.inventory, slot_idx) do
        %{item_id: item_id, equipped: true} when item_id > 0 ->
          case GameData.get_item(item_id) do
            nil ->
              ent

            item_def ->
              if item_def.real or item_def.caos do
                inv = List.update_at(ent.inventory, slot_idx, &%{&1 | equipped: false})
                ent = %{ent | inventory: inv}

                ent =
                  if item_def.equip_slot do
                    equipment = Map.put(ent.equipment, item_def.equip_slot, nil)
                    %{ent | equipment: equipment}
                  else
                    ent
                  end

                if item_def.equip_slot == :armor do
                  %{ent | body_id: ent.base_body_id}
                else
                  ent
                end
              else
                ent
              end
          end

        _ ->
          ent
      end
    end)
  end

  def faction_score_for_kill(attacker, defender) do
    att_faction = attacker.faction
    def_faction = defender.faction

    cond do
      att_faction != :none and att_faction == def_faction ->
        0

      att_faction != :none and def_faction != :none and att_faction != def_faction ->
        base = faction_score_base(attacker.level, defender.level)
        min(trunc(base * 1.5), 20)

      att_faction == :royal_army and defender.criminal ->
        min(faction_score_base(attacker.level, defender.level), 20)

      (att_faction == :chaos_legion or attacker.criminal) and
        def_faction == :none and not defender.criminal ->
        min(faction_score_base(attacker.level, defender.level), 20)

      true ->
        0
    end
  end

  defp faction_score_base(att_level, def_level) do
    if att_level < def_level do
      10 + def_level - max(att_level, 0)
    else
      max(10 - (att_level - def_level), 0)
    end
  end

  def handle_faction_chat(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        now = System.monotonic_time(:millisecond)
        wall_now = System.system_time(:millisecond)

        cond do
          entity.dead ->
            {:noreply, state}

          entity.muted_until > 0 and wall_now < entity.muted_until ->
            msg(state, char_id, "Estás silenciado.")
            {:noreply, state}

          entity.faction == :none ->
            msg(state, char_id, "No perteneces a ninguna faccion.")
            {:noreply, state}

          now - entity.last_chat_at < chat_cooldown_ms() ->
            msg(state, char_id, "Estás hablando demasiado rápido.")
            {:noreply, state}

          true ->
            {faction_label, font_index} = faction_chat_style(entity.faction)
            chat_msg = "#{entity.name}: #{message}"

            raw =
              Encoder.encode(
                {:console_faction_message,
                 %{
                   message: chat_msg,
                   font_index: font_index,
                   faction_label: faction_label
                 }}
              )

            for {_cid, other} <- state.players, other.faction == entity.faction do
              Helpers.send_to_session(state.sessions, other.char_id, {:send_raw, raw})
            end

            entity = %{entity | last_chat_at: now}
            players = Map.put(state.players, char_id, entity)
            {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp chat_cooldown_ms, do: Arena.Settings.get(:chat_cooldown_ms)

  defp faction_chat_style(:royal_army), do: {"MENSAJE_ARMADA", 0}
  defp faction_chat_style(:chaos_legion), do: {"MENSAJE_LEGION", 0}
  defp faction_chat_style(_), do: {"", 0}

  defp faction_display_name(:royal_army), do: "Armada Real"
  defp faction_display_name(:chaos_legion), do: "Legion del Caos"
  defp faction_display_name(_), do: "Ninguna"
end
