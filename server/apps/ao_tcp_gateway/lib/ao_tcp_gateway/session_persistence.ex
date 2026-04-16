defmodule AoTcpGateway.SessionPersistence do
  @moduledoc """
  Autosave and cleanup: persist entity state, unregister sessions.

  Extracted from SessionLogic as a pure structural refactor.
  """

  require Logger

  def cleanup(state) do
    if state.character_id && state.map_id do
      case Arena.Map.MapServer.leave(state.map_id, state.character_id) do
        {:ok, entity} ->
          try do
            attrs = GameBackend.Characters.from_entity(entity)
            inventory = GameBackend.Characters.inventory_from_entity(entity)
            equipment = GameBackend.Characters.equipment_from_entity(entity)
            skills = GameBackend.Characters.skills_from_entity(entity)
            spells = GameBackend.Characters.spells_from_entity(entity)

            case GameBackend.Characters.save_snapshot(entity.char_id, attrs,
                   inventory: inventory,
                   equipment: equipment,
                   skills: skills,
                   spells: spells
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Logger.error("Cleanup save failed for #{entity.char_id}: #{inspect(reason)}")
            end
          rescue
            e -> Logger.error("Cleanup save error for #{entity.char_id}: #{inspect(e)}")
          end

        :not_found ->
          :ok
      end
    end

    if state.character_id do
      Arena.PartyServer.leave(state.character_id)
      AoSession.OnlineDirectory.unregister(state.character_id)
      AoSession.unregister(state.character_id)
    end

    :ok
  end

  def autosave(entity) do
    Task.start(fn ->
      attrs = GameBackend.Characters.from_entity(entity)
      inventory = GameBackend.Characters.inventory_from_entity(entity)
      equipment = GameBackend.Characters.equipment_from_entity(entity)
      skills = GameBackend.Characters.skills_from_entity(entity)
      spells = GameBackend.Characters.spells_from_entity(entity)

      case GameBackend.Characters.save_snapshot(entity.char_id, attrs,
             inventory: inventory,
             equipment: equipment,
             skills: skills,
             spells: spells
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("Autosave failed for #{entity.char_id}: #{inspect(reason)}")
      end
    end)
  end
end
