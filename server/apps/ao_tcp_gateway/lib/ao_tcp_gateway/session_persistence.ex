defmodule AoTcpGateway.SessionPersistence do
  @moduledoc """
  Autosave and cleanup: persist entity state, unregister sessions.

  Autosave is a best-effort snapshot path via `AutosaveWriter` (async,
  coalescing, one in-flight write per character). Cleanup is the
  authoritative save boundary — synchronous, flush-then-save.
  """

  require Logger

  alias AoTcpGateway.AutosaveWriter

  def cleanup(state) do
    if state.character_id && state.map_id do
      # Drain any pending autosave before the authoritative cleanup save
      try do
        AutosaveWriter.flush(state.character_id, 5_000)
      catch
        :exit, _ -> :ok
      end

      case Arena.Map.MapServer.leave(state.map_id, state.character_id) do
        {:ok, entity} ->
          start = System.monotonic_time()
          snapshot = AutosaveWriter.snapshot_from_entity(entity)

          try do
            case GameBackend.Characters.save_snapshot(entity.char_id, snapshot.attrs,
                   inventory: snapshot.inventory,
                   equipment: snapshot.equipment,
                   skills: snapshot.skills,
                   spells: snapshot.spells
                 ) do
              {:ok, _} ->
                :telemetry.execute([:arena, :persistence, :cleanup],
                  %{duration: System.monotonic_time() - start},
                  %{char_id: entity.char_id, result: :ok})

              {:error, reason} ->
                :telemetry.execute([:arena, :persistence, :cleanup],
                  %{duration: System.monotonic_time() - start},
                  %{char_id: entity.char_id, result: :error})
                Logger.error("Cleanup save failed for #{entity.char_id}: #{inspect(reason)}")
            end
          rescue
            e ->
              :telemetry.execute([:arena, :persistence, :cleanup],
                %{duration: System.monotonic_time() - start},
                %{char_id: entity.char_id, result: :error})
              Logger.error("Cleanup save error for #{entity.char_id}: #{inspect(e)}")
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
    AutosaveWriter.submit(entity)
  end
end
