defmodule AoTcpGateway.SessionCommands.Duel do
  @moduledoc """
  Binary duel packet handlers (drift #3, VB6 parity).

  VB6 references:
    * `PacketId.bas:454-457` — eDuel, eAcceptDuel, eCancelDuel, eQuitDuel.
    * `Protocol.bas:5931-5981` — HandleDuel, HandleAcceptDuel,
      HandleCancelDuel, HandleQuitDuel.

  These handlers sit next to the text `/RETAR /ACEPTAR /CANCELAR /ABANDONAR`
  flow in `SessionCommands.Chat` — the binary path is preferred because
  it preserves `pociones_maximas` and `caen_items` (the text path ignores
  both fields). Both paths route through `Arena.DuelServer`.
  """

  require Logger

  import AoTcpGateway.SessionHelpers, only: [send_console: 1, resolve_char_name: 1]

  alias AoProtocol.Server.Encoder

  # ---- eDuel → create challenge (VB6 HandleDuel / CrearReto) ------------

  def handle_command(state, {:duel, payload}) when state.character_id != nil do
    %{
      target_username: target_name,
      bet: bet,
      pociones_maximas: pociones_maximas,
      caen_items: caen_items
    } = payload

    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, target_id, _info} ->
        opts = %{pociones_maximas: pociones_maximas, caen_items: caen_items}

        case Arena.DuelServer.challenge(state.character_id, target_id, bet, opts) do
          :ok ->
            notify_duel_target(target_id, state.character_id, bet)
            send_console(
              "Has enviado una solicitud de reto a #{target_name}. Apuesta: #{bet} monedas de oro."
            )

          {:error, :cannot_challenge_self} ->
            send_console("No puedes retarte a ti mismo.")

          {:error, :invalid_bet} ->
            send_console("La apuesta debe ser mayor a 0.")

          {:error, :already_in_duel} ->
            send_console("Ya te encuentras en un reto.")

          {:error, :target_in_duel} ->
            send_console("El jugador ya se encuentra en un reto.")

          {:error, :already_has_challenge} ->
            send_console(
              "Ya tienes una solicitud de reto pendiente. Escribe /CANCELAR para cancelarla."
            )

          {:error, _} ->
            send_console("No se pudo crear el reto.")
        end

        {state, []}

      :not_found ->
        send_console("Jugador no encontrado.")
        {state, []}
    end
  end

  # ---- eAcceptDuel → accept challenge (VB6 HandleAcceptDuel / AceptarReto) ----

  def handle_command(state, {:accept_duel, %{target_username: challenger_name}})
      when state.character_id != nil do
    case Arena.DuelServer.accept_challenge(state.character_id, challenger_name) do
      {:ok, duel} ->
        start_duel_on_map(duel)
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

  # ---- eCancelDuel → cancel challenge (VB6 HandleCancelDuel) ------------

  def handle_command(state, {:cancel_duel, _}) when state.character_id != nil do
    case Arena.DuelServer.cancel_challenge(state.character_id) do
      :ok ->
        send_console("Has cancelado la solicitud de reto.")

      {:error, :no_challenge} ->
        send_console("No tienes ninguna solicitud de reto.")
    end

    {state, []}
  end

  # ---- eQuitDuel → abandon active duel (VB6 HandleQuitDuel) -------------

  def handle_command(state, {:quit_duel, _}) when state.character_id != nil do
    case Arena.DuelServer.abandon_duel(state.character_id) do
      {:ok, result} ->
        handle_duel_result(result)

      {:error, :not_in_duel} ->
        send_console("No te encuentras en un reto.")
    end

    {state, []}
  end

  # Fallback for requests arriving before the player is fully logged in.
  def handle_command(state, {_cmd, _}), do: {state, []}

  # ---- Internal helpers (mirror SessionCommands.Chat duel helpers) -------

  defp notify_duel_target(target_id, challenger_id, bet) do
    challenger_name =
      case AoSession.OnlineDirectory.lookup_by_id(challenger_id) do
        {:ok, info} -> info.name
        _ -> "Unknown"
      end

    msg =
      Encoder.encode(
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

  defp start_duel_on_map(duel) do
    set_duel_flags(duel.player_a, duel.player_b)
    set_duel_flags(duel.player_b, duel.player_a)

    player_a_name = resolve_char_name(duel.player_a)
    player_b_name = resolve_char_name(duel.player_b)

    notify_duel_start(duel.player_a, player_b_name, duel.bet)
    notify_duel_start(duel.player_b, player_a_name, duel.bet)
  end

  defp set_duel_flags(char_id, opponent_id) do
    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} ->
        Arena.Map.MapServer.set_duel_state(info.map_id, char_id, true, opponent_id)

      _ ->
        :ok
    end
  end

  defp clear_duel_flags(char_id) do
    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} ->
        Arena.Map.MapServer.set_duel_state(info.map_id, char_id, false, nil)

      _ ->
        :ok
    end
  end

  defp notify_duel_start(char_id, opponent_name, bet) do
    msg =
      Encoder.encode(
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

  defp handle_duel_result(%{type: :winner, winner: winner_id, loser: loser_id, prize: prize}) do
    winner_name = resolve_char_name(winner_id)
    loser_name = resolve_char_name(loser_id)

    case AoSession.OnlineDirectory.lookup_by_id(winner_id) do
      {:ok, info} ->
        Arena.Map.MapServer.modify_gold(info.map_id, winner_id, prize)

      _ ->
        :ok
    end

    notify_duel_end(
      winner_id,
      "Has ganado el reto contra #{loser_name}! Ganas #{prize} monedas de oro."
    )

    notify_duel_end(loser_id, "Has perdido el reto contra #{winner_name}.")
    clear_duel_flags(winner_id)
    clear_duel_flags(loser_id)
  end

  defp handle_duel_result(%{type: :tie, player_a: a, player_b: b, refund: refund}) do
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
      Encoder.encode({:console_msg, %{message: message, font_index: 5}})

    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} -> send(info.session_pid, {:send_raw, msg})
      _ -> :ok
    end
  end
end
