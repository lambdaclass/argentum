defmodule Arena.Map.Gm.Teleport do
  @moduledoc "GM teleport commands: teleport, goto, summon."

  alias Arena.AuditLog
  alias Arena.Map.Helpers
  alias Arena.Map.Gm.Permissions

  # VB6 parity: high-tier GMs (admin, dios, semi_dios) can /GOTO anyone.
  # Lower-tier GMs (consejero) can only /GOTO players with active SOS requests.
  @high_tier_for_goto :semi_dios

  def gm_teleport(state, char_id, entity, map_str, x_str, y_str) do
    with {map_id, ""} <- Integer.parse(map_str),
         {x, ""} <- Integer.parse(x_str),
         {y, ""} <- Integer.parse(y_str) do
      Helpers.send_to_session(state.sessions, char_id, {:transfer, map_id, x, y, entity})
      AuditLog.log_gm_action(char_id, "teleport", "map #{map_id} (#{x}, #{y})")
      Helpers.gm_console(state, char_id, "Teleporting to map #{map_id} (#{x}, #{y})...")
      {:noreply, state}
    else
      _ ->
        Helpers.gm_console(state, char_id, "Usage: /TELEPORT map_id x y")
        {:noreply, state}
    end
  end

  def gm_goto(state, char_id, entity, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        # VB6 parity (Protocol_GmCommands.bas:367): lower-tier GMs need Ayuda.Existe(username)
        if goto_allowed?(entity, target_name) do
          do_goto(state, char_id, entity, target)
        else
          Helpers.gm_console(
            state,
            char_id,
            "No podes ir cerca de ningun Usuario si no pidio SOS."
          )

          {:noreply, state}
        end

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  defp goto_allowed?(entity, target_name) do
    Permissions.has_tier?(entity, @high_tier_for_goto) or
      AoSession.SosQueue.has_request?(target_name)
  end

  defp do_goto(state, char_id, entity, target) do
    AuditLog.log_gm_action(char_id, "goto", target.name)

    if target.map_id == entity.map_id do
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:transfer, entity.map_id, target.x, target.y, entity}
      )

      Helpers.gm_console(
        state,
        char_id,
        "Teleporting to #{target.name} at (#{target.x}, #{target.y})..."
      )

      {:noreply, state}
    else
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:transfer, target.map_id, target.x, target.y, entity}
      )

      Helpers.gm_console(
        state,
        char_id,
        "Teleporting to #{target.name} on map #{target.map_id} (#{target.x}, #{target.y})..."
      )

      {:noreply, state}
    end
  end

  @doc """
  /SUMMON target_name — teleport the target player to the GM's current position.
  The reverse of /GOTO.
  """
  def gm_summon(state, char_id, entity, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        AuditLog.log_gm_action(char_id, "summon", target.name)

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:transfer, entity.map_id, entity.x, entity.y, target}
        )

        Helpers.gm_console(
          state,
          char_id,
          "Summoning #{target.name} to your position (map #{entity.map_id}, #{entity.x}, #{entity.y})..."
        )

        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end
end
