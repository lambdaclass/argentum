defmodule AoTcpGateway.SessionCommands.Chat do
  @moduledoc """
  Chat and communication command handlers.

  Handles the complex `:talk` command (which parses party, guild, faction,
  marriage, report, and duel text commands), plus whisper, yell, group chat,
  faction messages, and council messages.
  """

  require Logger

  alias AoTcpGateway.SessionCommands.Guild, as: GuildCommands
  alias AoTcpGateway.SessionTransfer

  import AoTcpGateway.SessionHelpers, only: [send_console: 1, resolve_char_name: 1]

  # ---- Talk (the big nested parser) ----

  def handle_command(state, {:talk, %{message: message}}) when state.character_id != nil do
    case parse_party_command(message) do
      {:party_invite, target_name} ->
        case AoSession.OnlineDirectory.lookup_by_name(target_name) do
          {:ok, target_id, _info} ->
            Arena.PartyServer.invite(state.character_id, target_id)
          :not_found ->
            send_console("Jugador no encontrado.")
        end
        {state, []}

      :party_leave ->
        Arena.PartyServer.leave(state.character_id)
        {state, []}

      {:party_kick, target_name} ->
        case AoSession.OnlineDirectory.lookup_by_name(target_name) do
          {:ok, target_id, _info} ->
            Arena.PartyServer.kick(state.character_id, target_id)
          :not_found ->
            send_console("Jugador no encontrado.")
        end
        {state, []}

      :party_accept ->
        Arena.PartyServer.accept_invite(state.character_id)
        {state, []}

      :not_party_command ->
        case GuildCommands.parse_guild_command(message) do
          :not_guild_command ->
            handle_non_guild_talk(state, message)

          guild_cmd ->
            GuildCommands.handle_talk_guild(state, guild_cmd)
        end
    end
  end

  def handle_command(state, {:talk, _}), do: {state, []}

  # ---- Yell ----

  def handle_command(state, {:yell, %{message: message}}) when state.character_id != nil do
    Arena.Map.MapServer.yell(state.map_id, state.character_id, message)
    {state, []}
  end

  # ---- Whisper (cross-map) ----

  def handle_command(state, {:whisper, %{target_name: target_name, message: message}})
      when state.character_id != nil do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, _target_char_id, target_info} ->
        sender_name =
          case AoSession.OnlineDirectory.lookup_by_id(state.character_id) do
            {:ok, info} -> info.name
            :not_found -> "?"
          end

        whisper_msg = "#{sender_name} te dice: #{message}"
        send(target_info.session_pid, {:send_raw,
          AoProtocol.Server.Encoder.encode({:console_msg, %{message: whisper_msg, font_index: 5}})})

        confirm_msg = "Le dices a #{target_name}: #{message}"
        {state, [{:console_msg, %{message: confirm_msg, font_index: 5}}]}

      :not_found ->
        {state, [{:console_msg, %{message: "Jugador no encontrado.", font_index: 0}}]}
    end
  end

  # ---- Group/party chat ----

  def handle_command(state, {:grupo_msg, %{message: message}}) when state.character_id != nil do
    if state.is_dead == true do
      {state, []}
    else
      case Arena.PartyServer.get_party(state.character_id) do
        {:ok, party} ->
          sender_name =
            case AoSession.OnlineDirectory.lookup_by_id(state.character_id) do
              {:ok, info} -> info.name
              :not_found -> "?"
            end

          for member_id <- party.members, member_id != state.character_id do
            case AoSession.OnlineDirectory.lookup_by_id(member_id) do
              {:ok, member_info} ->
                msg = "[Grupo] #{sender_name}: #{message}"
                send(member_info.session_pid, {:send_raw,
                  AoProtocol.Server.Encoder.encode({:console_msg, %{message: msg, font_index: 3}})})
              :not_found -> :ok
            end
          end
          {state, [{:console_msg, %{message: "[Grupo] #{sender_name}: #{message}", font_index: 3}}]}

        :not_in_party ->
          {state, [{:console_msg, %{message: "No estas en un grupo.", font_index: 0}}]}
      end
    end
  end

  # ---- Faction message (binary packet) ----

  def handle_command(state, {:faction_message, %{message: message}}) when state.character_id != nil do
    Arena.Map.MapServer.faction_chat(state.map_id, state.character_id, message)
    {state, []}
  end

  # ---- Council message ----

  def handle_command(state, {:council_message, %{message: message}}) when state.character_id != nil do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} when entity.faction != :none ->
        Arena.Map.MapServer.faction_chat(state.map_id, state.character_id, message)
        {state, []}

      {:ok, _entity} ->
        {state, [{:console_msg, %{message: "No perteneces a ninguna faccion.", font_index: 0}}]}

      _ ->
        {state, []}
    end
  end

  # ---- Private: non-guild talk commands (faction, marriage, report, duel, hogar, tournament) ----

  defp handle_non_guild_talk(state, message) do
    case parse_faction_command(message) do
      {:enlist, faction} ->
        Arena.Map.MapServer.enlist_faction(state.map_id, state.character_id, faction)
        {state, []}

      :leave_faction ->
        Arena.Map.MapServer.leave_faction(state.map_id, state.character_id)
        {state, []}

      {:faction_chat, faction_msg} ->
        Arena.Map.MapServer.faction_chat(state.map_id, state.character_id, faction_msg)
        {state, []}

      :not_faction_command ->
        case parse_marriage_command(message) do
          {:propose, target_name} ->
            case AoSession.OnlineDirectory.lookup_by_name(target_name) do
              {:ok, target_id, _info} ->
                Arena.Map.MapServer.propose_marriage(state.map_id, state.character_id, target_id)
              :not_found ->
                send_console("Usuario offline.")
            end
            {state, []}

          :divorce ->
            Arena.Map.MapServer.divorce(state.map_id, state.character_id)
            {state, []}

          :not_marriage_command ->
            case parse_report_command(message) do
              {:report, target_name, reason} ->
                Arena.AuditLog.log_report(state.character_id, target_name, reason)
                {state, [{:console_msg, %{message: "Denuncia registrada.", font_index: 0}}]}

              :not_report_command ->
                case parse_duel_command(message) do
                  {:retar, target_name, bet} ->
                    handle_duel_challenge(state, target_name, bet)

                  {:aceptar, challenger_name} ->
                    handle_duel_accept(state, challenger_name)

                  :cancelar_reto ->
                    handle_duel_cancel(state)

                  :abandonar_reto ->
                    handle_duel_abandon(state)

                  :not_duel_command ->
                    handle_special_talk(state, message)
                end
            end
        end
    end
  end

  defp handle_special_talk(state, message) do
    upper = String.upcase(String.trim(message))
    cond do
      upper == "/HOGAR" ->
        SessionTransfer.handle_hogar(state)

      upper == "/TOURNAMENT JOIN" ->
        name = state.entity.name
        case Arena.Events.TournamentServer.join(state.character_id, name) do
          :ok -> {state, [{:console_msg, %{message: "Te has registrado en el torneo.", font_index: 0}}]}
          {:error, :no_tournament} -> {state, [{:console_msg, %{message: "No hay torneo activo.", font_index: 0}}]}
          {:error, :already_registered} -> {state, [{:console_msg, %{message: "Ya estas registrado.", font_index: 0}}]}
          {:error, :tournament_full} -> {state, [{:console_msg, %{message: "El torneo esta lleno.", font_index: 0}}]}
          {:error, _} -> {state, [{:console_msg, %{message: "No se pudo registrar.", font_index: 0}}]}
        end

      upper == "/TOURNAMENT LEAVE" ->
        case Arena.Events.TournamentServer.leave(state.character_id) do
          :ok -> {state, [{:console_msg, %{message: "Te has retirado del torneo.", font_index: 0}}]}
          {:error, _} -> {state, [{:console_msg, %{message: "No estas en un torneo.", font_index: 0}}]}
        end

      true ->
        Arena.Map.MapServer.chat(state.map_id, state.character_id, message)
        {state, []}
    end
  end

  # ---- Text command parsers ----

  defp parse_party_command(message) do
    upper = String.upcase(String.trim(message))
    cond do
      String.starts_with?(upper, "/PARTY ") ->
        name = String.trim(String.slice(message, 7..-1//1))
        {:party_invite, name}
      upper == "/SALIRGRUPO" -> :party_leave
      String.starts_with?(upper, "/ECHARGRUPO ") ->
        name = String.trim(String.slice(message, 12..-1//1))
        {:party_kick, name}
      upper == "/ACEPTARGRUPO" -> :party_accept
      true -> :not_party_command
    end
  end

  defp parse_faction_command(message) do
    upper = String.upcase(String.trim(message))
    cond do
      upper == "/ENLISTAR REAL" -> {:enlist, :royal_army}
      upper == "/ENLISTAR CAOS" -> {:enlist, :chaos_legion}
      upper == "/RENUNCIAR" -> :leave_faction
      String.starts_with?(upper, "/FACCION ") ->
        msg = String.trim(String.slice(message, 9..-1//1))
        {:faction_chat, msg}
      true -> :not_faction_command
    end
  end

  @doc false
  def parse_marriage_command(message) do
    upper = String.upcase(String.trim(message))

    cond do
      String.starts_with?(upper, "/PROPONER ") ->
        name = String.trim(String.slice(message, 10..-1//1))
        {:propose, name}

      upper == "/DIVORCIAR" ->
        :divorce

      true ->
        :not_marriage_command
    end
  end

  defp parse_report_command(message) do
    upper = String.upcase(String.trim(message))
    cond do
      String.starts_with?(upper, "/DENUNCIAR ") ->
        rest = String.trim(String.slice(message, 11..-1//1))
        case String.split(rest, ~r/\s+/, parts: 2) do
          [target_name, reason] -> {:report, target_name, reason}
          [target_name] -> {:report, target_name, ""}
          _ -> :not_report_command
        end
      true -> :not_report_command
    end
  end

  @doc false
  def parse_duel_command(message) do
    upper = String.upcase(String.trim(message))

    cond do
      String.starts_with?(upper, "/RETAR ") ->
        rest = String.trim(String.slice(message, 7..-1//1))

        case String.split(rest, ~r/\s+/, parts: 2) do
          [target_name, bet_str] ->
            case Integer.parse(bet_str) do
              {bet, _} when bet > 0 -> {:retar, target_name, bet}
              _ -> :not_duel_command
            end

          _ ->
            :not_duel_command
        end

      String.starts_with?(upper, "/ACEPTAR ") ->
        name = String.trim(String.slice(message, 9..-1//1))
        if String.length(name) > 0, do: {:aceptar, name}, else: :not_duel_command

      upper == "/CANCELAR" ->
        :cancelar_reto

      upper == "/ABANDONAR" ->
        :abandonar_reto

      true ->
        :not_duel_command
    end
  end

  # ---- Duel handlers ----

  defp handle_duel_challenge(state, target_name, bet) do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, target_id, _info} ->
        case Arena.DuelServer.create_challenge(state.character_id, target_id, bet) do
          :ok ->
            notify_duel_target(target_id, state.character_id, bet)
            send_console("Has enviado una solicitud de reto a #{target_name}. Apuesta: #{bet} monedas de oro.")
            send_console("Escribe /CANCELAR para anular la solicitud.")

          {:error, :cannot_challenge_self} ->
            send_console("No puedes retarte a ti mismo.")

          {:error, :invalid_bet} ->
            send_console("La apuesta debe ser mayor a 0.")

          {:error, :already_in_duel} ->
            send_console("Ya te encuentras en un reto.")

          {:error, :target_in_duel} ->
            send_console("El jugador ya se encuentra en un reto.")

          {:error, :already_has_challenge} ->
            send_console("Ya tienes una solicitud de reto pendiente. Escribe /CANCELAR para cancelarla.")

          {:error, _} ->
            send_console("No se pudo crear el reto.")
        end

        {state, []}

      :not_found ->
        send_console("Jugador no encontrado.")
        {state, []}
    end
  end

  defp handle_duel_accept(state, challenger_name) do
    case Arena.DuelServer.accept_challenge(state.character_id, challenger_name) do
      {:ok, duel} ->
        start_duel_on_map(state, duel)
        {state, []}

      {:error, :no_pending_challenge} ->
        send_console("No tienes ninguna invitacion de reto pendiente.")
        {state, []}

      {:error, :already_in_duel} ->
        send_console("Ya te encuentras en un reto.")
        {state, []}

      {:error, _} ->
        send_console("No se pudo aceptar el reto.")
        {state, []}
    end
  end

  defp handle_duel_cancel(state) do
    case Arena.DuelServer.cancel_challenge(state.character_id) do
      :ok ->
        send_console("Has cancelado la solicitud de reto.")

      {:error, :no_challenge} ->
        send_console("No tienes ninguna solicitud de reto.")
    end

    {state, []}
  end

  defp handle_duel_abandon(state) do
    case Arena.DuelServer.abandon_duel(state.character_id) do
      {:ok, result} ->
        handle_duel_result(state, result)

      {:error, :not_in_duel} ->
        send_console("No te encuentras en un reto.")
    end

    {state, []}
  end

  defp notify_duel_target(target_id, challenger_id, bet) do
    challenger_name =
      case AoSession.OnlineDirectory.lookup_by_id(challenger_id) do
        {:ok, info} -> info.name
        _ -> "Unknown"
      end

    msg =
      AoProtocol.Server.Encoder.encode(
        {:console_msg,
         %{
           message:
             "#{challenger_name} te invita a un reto. Apuesta: #{bet} monedas de oro. " <>
               "Escribe /ACEPTAR #{challenger_name} para participar.",
           font_index: 0
         }}
      )

    case AoSession.OnlineDirectory.lookup_by_id(target_id) do
      {:ok, info} -> send(info.session_pid, {:send_raw, msg})
      _ -> :ok
    end
  end

  defp start_duel_on_map(state, duel) do
    set_duel_flags(duel.player_a, duel.player_b)
    set_duel_flags(duel.player_b, duel.player_a)

    player_a_name = resolve_char_name(duel.player_a)
    player_b_name = resolve_char_name(duel.player_b)

    notify_duel_start(duel.player_a, player_b_name, duel.bet)
    notify_duel_start(duel.player_b, player_a_name, duel.bet)
    _ = state
  end

  defp set_duel_flags(char_id, opponent_id) do
    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} ->
        Arena.Map.MapServer.set_duel_state(info.map_id, char_id, true, opponent_id)
      _ -> :ok
    end
  end

  defp clear_duel_flags(char_id) do
    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} ->
        Arena.Map.MapServer.set_duel_state(info.map_id, char_id, false, nil)
      _ -> :ok
    end
  end

  defp notify_duel_start(char_id, opponent_name, bet) do
    msg =
      AoProtocol.Server.Encoder.encode(
        {:console_msg,
         %{
           message:
             "Ha comenzado el reto contra #{opponent_name}! Apuesta: #{bet} monedas de oro. " <>
               "Escribe /ABANDONAR para admitir la derrota.",
           font_index: 5
         }}
      )

    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} -> send(info.session_pid, {:send_raw, msg})
      _ -> :ok
    end
  end

  defp handle_duel_result(_state, %{type: :winner, winner: winner_id, loser: loser_id, prize: prize}) do
    winner_name = resolve_char_name(winner_id)
    loser_name = resolve_char_name(loser_id)

    case AoSession.OnlineDirectory.lookup_by_id(winner_id) do
      {:ok, info} ->
        Arena.Map.MapServer.modify_gold(info.map_id, winner_id, prize)
      _ -> :ok
    end

    notify_duel_end(winner_id, "Has ganado el reto contra #{loser_name}! Ganas #{prize} monedas de oro.")
    notify_duel_end(loser_id, "Has perdido el reto contra #{winner_name}.")
    clear_duel_flags(winner_id)
    clear_duel_flags(loser_id)
  end

  defp handle_duel_result(_state, %{type: :tie, player_a: a, player_b: b, refund: refund}) do
    for id <- [a, b] do
      case AoSession.OnlineDirectory.lookup_by_id(id) do
        {:ok, info} -> Arena.Map.MapServer.modify_gold(info.map_id, id, refund)
        _ -> :ok
      end

      notify_duel_end(id, "El reto ha terminado en empate. Se devuelven #{refund} monedas de oro.")
      clear_duel_flags(id)
    end
  end

  defp notify_duel_end(char_id, message) do
    msg =
      AoProtocol.Server.Encoder.encode(
        {:console_msg, %{message: message, font_index: 5}}
      )

    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} -> send(info.session_pid, {:send_raw, msg})
      _ -> :ok
    end
  end
end
