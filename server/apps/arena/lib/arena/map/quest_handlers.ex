defmodule Arena.Map.QuestHandlers do
  @moduledoc "Quest system handlers."

  alias Arena.Map.Helpers
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

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

          quest_state ->
            case Arena.QuestServer.build_quest_details(entity, quest_state) do
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
            available = Arena.QuestServer.available_quests_for_npc(npc_def, entity)
            quest_index = list_index - 1

            case Enum.at(available, quest_index) do
              nil ->
                msg(state, char_id, "Mision no disponible.")
                {:noreply, state}

              quest_def ->
                case Arena.QuestServer.can_accept_quest?(entity, quest_def) do
                  :ok ->
                    entity = Arena.QuestServer.accept_quest(entity, quest_def)
                    msg(state, char_id, "Mision aceptada: #{quest_def.name}")
                    state = put_in(state.players[char_id], entity)
                    {:noreply, state}

                  {:error, reason} ->
                    msg(state, char_id, reason)
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
            entity = Arena.QuestServer.abandon_quest(entity, quest_slot)
            msg(state, char_id, "Abandonaste la mision: #{name}")
            state = put_in(state.players[char_id], entity)
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  @doc "Handle the quest button click: opens quest list or NPC quest interaction."
  def handle_quest(state, char_id) do
    handle_quest_list_request(state, char_id)
  end
end
