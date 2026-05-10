defmodule Arena.Map.QuestHandlers do
  @moduledoc """
  Quest system handlers.

  All public handlers return `{:ok, state, [Effect.t()]}` and dispatch
  through `Arena.Map.Effects.run_handler/2`. Console-message rejections
  are surfaced as `Effects.send/2` effects rather than via the legacy
  `Helpers.msg/3` shim.
  """

  alias Arena.Map.{Effects, Helpers}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_quest 17

  @doc "Handle quest list request: send the player their active quests."
  def handle_quest_list_request(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        active = entity.active_quests
        count = length(active)
        quest_ids_str = Enum.map_join(active, ";", fn aq -> Integer.to_string(aq.quest_id) end)

        packet =
          Encoder.encode(
            {:quest_list_send, %{quest_count: count, quest_ids_str: quest_ids_str}}
          )

        {:ok, state, [Effects.send(char_id, packet)]}

      :error ->
        {:ok, state, []}
    end
  end

  @doc "Handle quest details request: send details for a quest at the given slot."
  def handle_quest_details_request(state, char_id, quest_slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        index = quest_slot - 1

        case Enum.at(entity.active_quests, index) do
          nil ->
            {:ok, state, [Effects.send(char_id, console("Mision no encontrada."))]}

          _quest_state ->
            case Arena.QuestServer.build_quest_details(entity, index) do
              nil ->
                {:ok, state,
                 [Effects.send(char_id, console("Datos de mision no disponibles."))]}

              details ->
                packet = Encoder.encode({:quest_details, details})
                {:ok, state, [Effects.send(char_id, packet)]}
            end
        end

      :error ->
        {:ok, state, []}
    end
  end

  @doc "Handle quest accept: player accepts a quest from the NPC list."
  def handle_quest_accept(state, char_id, list_index) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        npc_id = entity.quest_npc_id

        if npc_id == nil do
          {:ok, state,
           [Effects.send(char_id, console("No estas interactuando con un NPC de misiones."))]}
        else
          npc_def = GameData.get_npc(npc_id)

          if npc_def == nil do
            {:ok, state, []}
          else
            available = Arena.QuestServer.available_quests_for_npc(entity, npc_def)
            quest_index = list_index - 1

            case Enum.at(available, quest_index) do
              nil ->
                {:ok, state, [Effects.send(char_id, console("Mision no disponible."))]}

              quest_id ->
                quest_def = GameData.get_quest(quest_id)

                cond do
                  quest_def == nil ->
                    {:ok, state, [Effects.send(char_id, console("Mision no disponible."))]}

                  Arena.QuestServer.can_accept_quest?(entity, quest_def) ->
                    entity = Arena.QuestServer.accept_quest(entity, quest_def)
                    state = put_in(state.players[char_id], entity)

                    {:ok, state,
                     [Effects.send(char_id, console("Mision aceptada: #{quest_def.name}"))]}

                  true ->
                    {:ok, state,
                     [Effects.send(char_id, console("No puedes aceptar esta mision."))]}
                end
            end
          end
        end

      :error ->
        {:ok, state, []}
    end
  end

  @doc "Handle quest abandon: player abandons an active quest."
  def handle_quest_abandon(state, char_id, quest_slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        index = quest_slot - 1

        case Enum.at(entity.active_quests, index) do
          nil ->
            {:ok, state, [Effects.send(char_id, console("Mision no encontrada."))]}

          quest_state ->
            quest_def = GameData.get_quest(quest_state.quest_id)
            name = if quest_def, do: quest_def.name, else: "mision"
            entity = Arena.QuestServer.abandon_quest(entity, index)
            state = put_in(state.players[char_id], entity)

            {:ok, state,
             [Effects.send(char_id, console("Abandonaste la mision: #{name}"))]}
        end

      :error ->
        {:ok, state, []}
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
                state = put_in(state.players[char_id], updated_entity)

                desc_final_effects =
                  if quest_def.desc_final != "" do
                    [
                      Effects.send(
                        char_id,
                        console(npc_def.name <> " dice: " <> quest_def.desc_final)
                      )
                    ]
                  else
                    []
                  end

                gold_effects =
                  if quest_def.reward_gld > 0 do
                    [
                      Effects.send(
                        char_id,
                        console("Recibiste #{quest_def.reward_gld} monedas de oro.")
                      ),
                      Effects.send(
                        char_id,
                        Encoder.encode({:update_gold, %{gold: updated_entity.gold}})
                      )
                    ]
                  else
                    []
                  end

                exp_effects =
                  if quest_def.reward_exp > 0 do
                    [
                      Effects.send(
                        char_id,
                        console(
                          "Recibiste #{quest_def.reward_exp} puntos de experiencia."
                        )
                      )
                    ]
                  else
                    []
                  end

                effects = desc_final_effects ++ gold_effects ++ exp_effects
                {:ok, state, effects}
              else
                {:ok, state,
                 [Effects.send(char_id, console("No se pudo completar la mision."))]}
              end
            else
              available = Arena.QuestServer.available_quests_for_npc(entity, npc_def)

              if available == [] do
                {:ok, state,
                 [
                   Effects.send(
                     char_id,
                     console(npc_def.name <> " dice: No tengo misiones disponibles para ti.")
                   )
                 ]}
              else
                npc_quest_params = Arena.QuestServer.build_npc_quest_list(available)
                entity = %{entity | quest_npc_id: npc_def.id}
                state = put_in(state.players[char_id], entity)

                packet =
                  Encoder.encode({:npc_quest_list_send, %{quests: npc_quest_params}})

                {:ok, state, [Effects.send(char_id, packet)]}
              end
            end

          :not_found ->
            {:ok, state, [Effects.send(char_id, console("No hay un NPC de misiones cerca."))]}
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end
end
