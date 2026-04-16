defmodule Arena.Map.Gm.Moderation do
  @moduledoc "GM moderation commands: kick, ban, mute, jail, kill, etc."

  require Logger

  alias Arena.AuditLog
  alias Arena.Map.Helpers
  alias AoProtocol.Server.Encoder

  @jail_map_id 66
  @jail_x 33
  @jail_y 33

  def gm_kick(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, _target} ->
        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido expulsado del servidor.", font_index: 0}})}
        )

        Helpers.send_to_session(state.sessions, target_id, :disconnect)
        AuditLog.log_gm_action(char_id, "kick", target_name)
        Helpers.gm_console(state, char_id, "#{target_name} has been kicked.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  def gm_ban(state, char_id, target_name, days_str) do
    case Integer.parse(days_str) do
      {days, ""} when days > 0 ->
        case Helpers.find_player_by_name(state, target_name) do
          {:ok, target_id, target} ->
            banned_until = DateTime.add(DateTime.utc_now(), days * 24 * 3600, :second)

            case GameBackend.Account.ban(target.account_id, banned_until) do
              {:ok, _account} ->
                Arena.AuditLog.log_gm_action(char_id, "ban", "#{target_name} for #{days} day(s)")
                Logger.warning("GM ban: #{target_name} for #{days} days (account_id=#{target.account_id})")

                Helpers.send_to_session(
                  state.sessions,
                  target_id,
                  {:send_raw,
                   Encoder.encode({:console_msg, %{message: "Has sido baneado por #{days} día(s).", font_index: 0}})}
                )

                Helpers.send_to_session(state.sessions, target_id, :disconnect)
                Helpers.gm_console(state, char_id, "#{target_name} banned for #{days} day(s).")

              {:error, reason} ->
                Logger.error("Failed to persist ban for #{target_name}: #{inspect(reason)}")
                Helpers.gm_console(state, char_id, "Failed to persist ban for #{target_name}.")
            end

            {:noreply, state}

          :not_found ->
            Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
            {:noreply, state}
        end

      _ ->
        Helpers.gm_console(state, char_id, "Usage: /BAN name days")
        {:noreply, state}
    end
  end

  def gm_mute(state, char_id, target_name, minutes_str) do
    case Integer.parse(minutes_str) do
      {minutes, ""} when minutes > 0 ->
        case Helpers.find_player_by_name(state, target_name) do
          {:ok, target_id, target} ->
            muted_until = System.system_time(:millisecond) + minutes * 60_000
            target = %{target | muted_until: muted_until}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}

            Helpers.send_to_session(
              state.sessions,
              target_id,
              {:send_raw,
               Encoder.encode(
                 {:console_msg, %{message: "Has sido silenciado por #{minutes} minuto(s).", font_index: 0}}
               )}
            )

            AuditLog.log_gm_action(char_id, "mute", "#{target.name} for #{minutes} min")
            Helpers.gm_console(state, char_id, "#{target.name} muted for #{minutes} minute(s).")
            {:noreply, state}

          :not_found ->
            Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
            {:noreply, state}
        end

      _ ->
        Helpers.gm_console(state, char_id, "Usage: /MUTE name minutes")
        {:noreply, state}
    end
  end

  def gm_unmute(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | muted_until: 0}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Ya no estás silenciado.", font_index: 0}})}
        )

        AuditLog.log_gm_action(char_id, "unmute", target.name)
        Helpers.gm_console(state, char_id, "#{target.name} has been unmuted.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  def gm_jail(state, char_id, target_name, minutes) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | penalty: minutes}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw,
           Encoder.encode(
             {:console_msg, %{message: "Has sido enviado a la cárcel por #{minutes} minutos.", font_index: 0}}
           )}
        )

        Helpers.send_to_session(state.sessions, target_id, {:transfer, @jail_map_id, @jail_x, @jail_y, target})
        AuditLog.log_gm_action(char_id, "jail", "#{target.name} for #{minutes} min")
        Helpers.gm_console(state, char_id, "#{target.name} jailed for #{minutes} min (map #{@jail_map_id}).")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  def gm_kill(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        if target.dead do
          Helpers.gm_console(state, char_id, "#{target.name} is already dead.")
          {:noreply, state}
        else
          {target, state} = Arena.Map.PlayerDeath.handle_player_death(state, target_id, %{target | hp: 0})
          players = Map.put(state.players, target_id, target)
          state = %{state | players: players}

          Helpers.send_to_session(
            state.sessions,
            target_id,
            {:send_raw, Encoder.encode({:update_hp, %{min_hp: 0, shield: 0}})}
          )

          Helpers.send_to_session(
            state.sessions,
            target_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "A GM has killed you.", font_index: 0}})}
          )

          Helpers.broadcast_character_change(state, target)
          AuditLog.log_gm_action(char_id, "kill", target.name)
          Helpers.gm_console(state, char_id, "#{target.name} has been killed.")
          {:noreply, state}
        end

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  def gm_ban_cuenta(state, char_id, target_name, reason) do
    case GameBackend.Account.ban(target_name, reason) do
      :ok ->
        case AoSession.OnlineDirectory.lookup_by_name(target_name) do
          {:ok, session} -> send(session.pid, :disconnect)
          _ -> :ok
        end

        AuditLog.log_gm_action(char_id, "ban_cuenta", "#{target_name}: #{reason}")
        Helpers.gm_console(state, char_id, "Account for #{target_name} banned: #{reason}")

      {:error, err} ->
        Helpers.gm_console(state, char_id, "Ban failed: #{inspect(err)}")
    end

    {:noreply, state}
  end

  def gm_unban_cuenta(state, char_id, target_name) do
    case GameBackend.Account.unban(target_name) do
      :ok -> Helpers.gm_console(state, char_id, "Account for #{target_name} unbanned.")
      {:error, err} -> Helpers.gm_console(state, char_id, "Unban failed: #{inspect(err)}")
    end

    {:noreply, state}
  end

  def gm_ban_temporal(state, char_id, target_name, days_str, reason) do
    case Integer.parse(days_str) do
      {days, _} when days > 0 ->
        case GameBackend.Account.ban(target_name, "#{reason} (#{days} dias)") do
          :ok ->
            case AoSession.OnlineDirectory.lookup_by_name(target_name) do
              {:ok, session} -> send(session.pid, :disconnect)
              _ -> :ok
            end

            AuditLog.log_gm_action(char_id, "ban_temporal", "#{target_name} #{days}d: #{reason}")
            Helpers.gm_console(state, char_id, "#{target_name} banned for #{days} days: #{reason}")

          {:error, err} ->
            Helpers.gm_console(state, char_id, "Temp ban failed: #{inspect(err)}")
        end

      _ ->
        Helpers.gm_console(state, char_id, "Invalid days value.")
    end

    {:noreply, state}
  end

  def gm_remove_punishment(state, char_id, target_name, _num_str, _text) do
    Helpers.gm_console(state, char_id, "Punishment removed from #{target_name}.")
    {:noreply, state}
  end

  def gm_council_kick(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = Map.put(target, :council, false)
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        AuditLog.log_gm_action(char_id, "council_kick", target_name)
        Helpers.gm_console(state, char_id, "#{target_name} removed from council.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  def gm_faction_kick(state, char_id, target_name, faction) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | faction: :none}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        label = if faction == :royal_army, do: "Armada Real", else: "Legion Oscura"
        AuditLog.log_gm_action(char_id, "faction_kick", "#{target_name} from #{label}")
        Helpers.gm_console(state, char_id, "#{target_name} expelled from #{label}.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end
end
