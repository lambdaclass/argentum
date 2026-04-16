defmodule Arena.Map.Gm.Teleport do
  @moduledoc "GM teleport commands: teleport, goto."

  alias Arena.AuditLog
  alias Arena.Map.Helpers

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
        AuditLog.log_gm_action(char_id, "goto", target.name)

        if target.map_id == entity.map_id do
          Helpers.send_to_session(state.sessions, char_id, {:transfer, entity.map_id, target.x, target.y, entity})
          Helpers.gm_console(state, char_id, "Teleporting to #{target.name} at (#{target.x}, #{target.y})...")
          {:noreply, state}
        else
          Helpers.send_to_session(state.sessions, char_id, {:transfer, target.map_id, target.x, target.y, entity})

          Helpers.gm_console(
            state,
            char_id,
            "Teleporting to #{target.name} on map #{target.map_id} (#{target.x}, #{target.y})..."
          )

          {:noreply, state}
        end

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end
end
