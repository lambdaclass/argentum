defmodule Arena.Map.QuestHandlers do
  @moduledoc "Quest system handlers."

  alias Arena.Map.Helpers
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_quest 17

  defp msg(state, char_id, message), do: Helpers.msg(state, char_id, message)

  @doc "Handle quest list request: send the player their active quests."
  def handle_quest_list_request(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        active = entity.active_quests
        count = length(active)
        quest_ids_str = Enum.map_join(active, ";", fn aq -> Integer.to_string(aq.quest_id) end)

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw,
           Encoder.encode({:quest_list_send, %{quest_count: count, quest_ids_str: quest_ids_str}})}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @doc "Handle quest details request: send details for a quest at the given slot."
  def handle_quest_details_request(state, char_id, quest_slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        index = quest_slot - 1

        case Enum.at(entity.active_quests, index) do
          nil ->
            msg(state, char_id, "Mision no encontrada.")
            {:noreply, state}

          _quest_state ->
            case Arena.QuestServer.build_quest_details(entity, index) do
              nil ->
                msg(state, char_id, "Datos de mision no disponibles.")
                {:noreply, state}

              details ->
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:quest_details, details})}
                )

                {:noreply, state}
            end
        end

      :error ->
        {:noreply, state}
    end
  end

  @doc "Handle quest accept: player accepts a quest from the NPC list."
  def handle_quest_accept(state, char_id, list_index) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        npc_id = entity.quest_npc_id

        if npc_id == nil do
          msg(state, char_id, "No estas interactuando con un NPC de misiones.")
          {:noreply, state}
        else
          npc_def = GameData.get_npc(npc_id)

          if npc_def == nil do
            {:noreply, state}
          else
            available = Arena.QuestServer.available_quests_for_npc(entity, npc_def)
            quest_index = list_index - 1

            case Enum.at(available, quest_index) do
              nil ->
                msg(state, char_id, "Mision no disponible.")
                {:noreply, state}

              quest_id ->
                quest_def = GameData.get_quest(quest_id)

                cond do
                  quest_def == nil ->
                    msg(state, char_id, "Mision no disponible.")
                    {:noreply, state}

                  Arena.QuestServer.can_accept_quest?(entity, quest_def) ->
                    entity = Arena.QuestServer.accept_quest(entity, quest_def)
                    msg(state, char_id, "Mision aceptada: #{quest_def.name}")
                    state = put_in(state.players[char_id], entity)
                    {:noreply, state}

                  true ->
                    msg(state, char_id, "No puedes aceptar esta mision.")
                    {:noreply, state}
                end
            end
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  @doc "Handle quest abandon: player abandons an active quest."
  def handle_quest_abandon(state, char_id, quest_slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        index = quest_slot - 1

        case Enum.at(entity.active_quests, index) do
          nil ->
            msg(state, char_id, "Mision no encontrada.")
            {:noreply, state}

          quest_state ->
            quest_def = GameData.get_quest(quest_state.quest_id)
            name = if quest_def, do: quest_def.name, else: "mision"
            entity = Arena.QuestServer.abandon_quest(entity, index)
            msg(state, char_id, "Abandonaste la mision: #{name}")
            state = put_in(state.players[char_id], entity)
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  @doc """
  Handle the eQuest packet (VB6: HandleQuest).

  VB6 behaviour: find a nearby quest NPC within range 5 and show that NPC's
  available quests. If no quest NPC is nearby, send an error message.
  """
  def handle_quest(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case Helpers.resolve_nearby_npc(state, entity, [@npc_type_quest], 5) do
          {:ok, _npc, npc_def} ->
            quest_ids_set = MapSet.new(npc_def.quest_numbers)

            completable =
              entity.active_quests
              |> Enum.with_index()
              |> Enum.filter(fn {aq, idx} ->
                MapSet.member?(quest_ids_set, aq.quest_id) and
                  Arena.QuestServer.quest_complete?(entity, idx)
              end)

            if completable != [] do
              {aq, slot} = hd(completable)
              quest_def = GameData.get_quest(aq.quest_id)
              updated_entity = Arena.QuestServer.complete_quest(entity, slot)

              if updated_entity != entity and quest_def != nil do
                if quest_def.desc_final != "" do
                  msg(state, char_id, npc_def.name <> " dice: " <> quest_def.desc_final)
                end

                if quest_def.reward_gld > 0 do
                  msg(state, char_id, "Recibiste #{quest_def.reward_gld} monedas de oro.")

                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw,
                     Encoder.encode({:update_gold, %{gold: updated_entity.gold}})}
                  )
                end

                if quest_def.reward_exp > 0 do
                  msg(state, char_id, "Recibiste #{quest_def.reward_exp} puntos de experiencia.")
                end

                state = put_in(state.players[char_id], updated_entity)
                {:noreply, state}
              else
                msg(state, char_id, "No se pudo completar la mision.")
                {:noreply, state}
              end
            else
              available = Arena.QuestServer.available_quests_for_npc(entity, npc_def)

              if available == [] do
                msg(state, char_id, npc_def.name <> " dice: No tengo misiones disponibles para ti.")
                {:noreply, state}
              else
                npc_quest_params = Arena.QuestServer.build_npc_quest_list(available)

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:npc_quest_list_send, %{quests: npc_quest_params}})}
                )

                entity = %{entity | quest_npc_id: npc_def.id}
                state = put_in(state.players[char_id], entity)
                {:noreply, state}
              end
            end

          :not_found ->
            msg(state, char_id, "No hay un NPC de misiones cerca.")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end
end
