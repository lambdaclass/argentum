defmodule Arena.Map.Pets do
  @moduledoc "Pet command handlers."

  alias Arena.Map.Helpers

  defp msg(state, char_id, message), do: Helpers.msg(state, char_id, message)

  def handle_pet_stand(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          state = set_pet_mode(state, char_id, :stand)
          msg(state, char_id, "Tus mascotas se quedan quietas.")
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_pet_follow(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          state = set_pet_mode(state, char_id, :follow)
          msg(state, char_id, "Tus mascotas te siguen.")
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_pet_leave(state, char_id, pet_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          if pet_id in (entity.pet_ids || []) do
            case Map.get(state.npcs_live, pet_id) do
              nil ->
                entity = %{entity | pet_ids: List.delete(entity.pet_ids, pet_id)}
                state = %{state | players: Map.put(state.players, char_id, entity)}
                {:noreply, state}

              npc ->
                {state, effects} = Arena.NpcAi.despawn_pet(state, pet_id, npc)
                Arena.NpcAi.dispatch_effects(state, effects)
                entity = Map.fetch!(state.players, char_id)
                entity = %{entity | pet_ids: List.delete(entity.pet_ids, pet_id)}
                state = %{state | players: Map.put(state.players, char_id, entity)}
                msg(state, char_id, "Has liberado una mascota.")
                {:noreply, state}
            end
          else
            msg(state, char_id, "No tienes mascotas.")
            {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_pet_leave_all(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          state =
            Enum.reduce(entity.pet_ids || [], state, fn instance_id, st ->
              case Map.get(st.npcs_live, instance_id) do
                nil -> st
                npc ->
                  {st, effects} = Arena.NpcAi.despawn_pet(st, instance_id, npc)
                  Arena.NpcAi.dispatch_effects(st, effects)
                  st
              end
            end)

          entity = %{entity | pet_ids: []}
          state = %{state | players: Map.put(state.players, char_id, entity)}
          msg(state, char_id, "Has liberado todas tus mascotas.")
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # Set pet behavior mode — :stand stops movement/attack, :follow resumes normal AI
  defp set_pet_mode(state, char_id, mode) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        npcs_live =
          Enum.reduce(entity.pet_ids || [], state.npcs_live, fn instance_id, npcs ->
            case Map.get(npcs, instance_id) do
              nil -> npcs
              npc -> Map.put(npcs, instance_id, %{npc | pet_mode: mode})
            end
          end)

        %{state | npcs_live: npcs_live}

      :error ->
        state
    end
  end
end
