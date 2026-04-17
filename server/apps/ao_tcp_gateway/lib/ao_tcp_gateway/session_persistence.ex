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
        kind, reason ->
          Logger.warning(
            "AutosaveWriter.flush timed out or failed for char #{state.character_id}: " <>
              "#{inspect(kind)} #{inspect(reason)}. " <>
              "A stale autosave may still be in-flight and could overwrite the cleanup snapshot."
          )
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
                :telemetry.execute([:arena, :persistence, :cleanup_save_failed],
                  %{},
                  %{char_id: entity.char_id})
                Logger.error(
                  "Final save failed for char #{entity.char_id}, " <>
                    "session cleanup proceeding with data loss risk: #{inspect(reason)}"
                )
            end
          rescue
            e ->
              :telemetry.execute([:arena, :persistence, :cleanup],
                %{duration: System.monotonic_time() - start},
                %{char_id: entity.char_id, result: :error})
              :telemetry.execute([:arena, :persistence, :cleanup_save_failed],
                %{},
                %{char_id: entity.char_id})
              Logger.error(
                "Final save failed for char #{entity.char_id}, " <>
                  "session cleanup proceeding with data loss risk: #{inspect(e)}"
              )
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
