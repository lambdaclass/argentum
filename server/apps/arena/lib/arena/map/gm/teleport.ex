defmodule Arena.Map.Gm.Teleport do
  @moduledoc """
  GM teleport commands: teleport, goto, summon.

  Public handlers return `{:ok, state, [Effect.t()]}`. Console
  confirmations flow through `Effects.send/2`; the actual relocation
  message — the bare `{:transfer, _, _, _, _}` tuple expected by
  `AoTcpGateway` — flows through `Effects.transfer/5`, which is
  intentionally out-of-band of the egress queue (transfers are
  session-control, not packet traffic).
  """

  alias Arena.AuditLog
  alias Arena.Map.{Effects, Helpers}
  alias Arena.Map.Gm.Permissions
  alias AoProtocol.Server.Encoder

  # VB6 parity: high-tier GMs (admin, dios, semi_dios) can /GOTO anyone.
  # Lower-tier GMs (consejero) can only /GOTO players with active SOS requests.
  @high_tier_for_goto :semi_dios

  def gm_teleport(state, char_id, entity, map_str, x_str, y_str) do
    with {map_id, ""} <- Integer.parse(map_str),
         {x, ""} <- Integer.parse(x_str),
         {y, ""} <- Integer.parse(y_str) do
      AuditLog.log_gm_action(char_id, "teleport", "map #{map_id} (#{x}, #{y})")

      effects = [
        Effects.transfer(char_id, map_id, x, y, entity),
        Effects.send(char_id, console("Teleporting to map #{map_id} (#{x}, #{y})..."))
      ]

      {:ok, state, effects}
    else
      _ ->
        {:ok, state, [Effects.send(char_id, console("Usage: /TELEPORT map_id x y"))]}
    end
  end

  def gm_goto(state, char_id, entity, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        # VB6 parity (Protocol_GmCommands.bas:367): lower-tier GMs need Ayuda.Existe(username)
        if goto_allowed?(entity, target_name) do
          do_goto(state, char_id, entity, target)
        else
          {:ok, state,
           [
             Effects.send(
               char_id,
               console("No podes ir cerca de ningun Usuario si no pidio SOS.")
             )
           ]}
        end

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
    end
  end

  defp goto_allowed?(entity, target_name) do
    Permissions.has_tier?(entity, @high_tier_for_goto) or
      AoSession.SosQueue.has_request?(target_name)
  end

  defp do_goto(state, char_id, entity, target) do
    AuditLog.log_gm_action(char_id, "goto", target.name)

    if target.map_id == entity.map_id do
      effects = [
        Effects.transfer(char_id, entity.map_id, target.x, target.y, entity),
        Effects.send(
          char_id,
          console("Teleporting to #{target.name} at (#{target.x}, #{target.y})...")
        )
      ]

      {:ok, state, effects}
    else
      effects = [
        Effects.transfer(char_id, target.map_id, target.x, target.y, entity),
        Effects.send(
          char_id,
          console(
            "Teleporting to #{target.name} on map #{target.map_id} (#{target.x}, #{target.y})..."
          )
        )
      ]

      {:ok, state, effects}
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

        effects = [
          Effects.transfer(target_id, entity.map_id, entity.x, entity.y, target),
          Effects.send(
            char_id,
            console(
              "Summoning #{target.name} to your position (map #{entity.map_id}, #{entity.x}, #{entity.y})..."
            )
          )
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
    end
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end
end
