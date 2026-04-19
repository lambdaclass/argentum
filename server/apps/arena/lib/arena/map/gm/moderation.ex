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
        gm_name = gm_name_for(state, char_id)
        target = add_punishment(target, "Carcel #{minutes} min", gm_name)
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

  def gm_remove_punishment(state, char_id, target_name, num_str, _text) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        num =
          case Integer.parse(num_str) do
            {n, _} -> n
            :error -> 0
          end

        existing = Map.get(target, :punishments, [])

        if Enum.any?(existing, &(&1.number == num)) do
          new_punishments = Enum.reject(existing, &(&1.number == num))
          target = %{target | punishments: new_punishments}
          players = Map.put(state.players, target_id, target)
          state = %{state | players: players}

          AuditLog.log_gm_action(char_id, "remove_punishment", "#{target_name} ##{num}")
          Helpers.gm_console(state, char_id, "Punishment ##{num} removed from #{target_name}.")
          {:noreply, state}
        else
          Helpers.gm_console(state, char_id, "Punishment ##{num} not found for #{target_name}.")
          {:noreply, state}
        end

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
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
        label = if faction == :royal_army, do: "Armada Real", else: "Legion del Caos"
        AuditLog.log_gm_action(char_id, "faction_kick", "#{target_name} from #{label}")
        Helpers.gm_console(state, char_id, "#{target_name} expelled from #{label}.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  def gm_unjail(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | penalty: 0}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido liberado de la cárcel.", font_index: 0}})}
        )

        AuditLog.log_gm_action(char_id, "unjail", target.name)
        Helpers.gm_console(state, char_id, "#{target.name} has been unjailed (penalty cleared).")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  def gm_navigando(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        new_navigating = not target.navigating
        target = %{target | navigating: new_navigating}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        status = if new_navigating, do: "activada", else: "desactivada"

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Navegación #{status}.", font_index: 0}})}
        )

        AuditLog.log_gm_action(char_id, "navigando", "#{target.name} #{status}")
        Helpers.gm_console(state, char_id, "#{target.name} navigation #{status}.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  def gm_rm_criminal(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | criminal: false}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw,
           Encoder.encode({:console_msg, %{message: "Tu status de criminal ha sido removido.", font_index: 0}})}
        )

        AuditLog.log_gm_action(char_id, "rm_criminal", target.name)
        Helpers.gm_console(state, char_id, "#{target.name} is no longer a criminal.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  def gm_rm_citizen(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | criminal: true}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Ahora eres un criminal.", font_index: 0}})}
        )

        AuditLog.log_gm_action(char_id, "rm_citizen", target.name)
        Helpers.gm_console(state, char_id, "#{target.name} is now a criminal.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  @doc "/KICKALLCHARS — kick all non-GM players from this map."
  def gm_kick_all_chars(state, char_id) do
    kicked =
      Enum.reduce(state.players, 0, fn {pid, entity}, count ->
        if not entity.gm do
          Helpers.send_to_session(
            state.sessions,
            pid,
            {:send_raw,
             Encoder.encode({:console_msg, %{message: "Todos los jugadores han sido expulsados.", font_index: 0}})}
          )

          Helpers.send_to_session(state.sessions, pid, :disconnect)
          count + 1
        else
          count
        end
      end)

    AuditLog.log_gm_action(char_id, "kick_all_chars", "#{kicked} players")
    Helpers.gm_console(state, char_id, "Kicked #{kicked} non-GM player(s) from this map.")
    {:noreply, state}
  end

  @doc "/UNBAN name — unban a character by looking them up on the current map first."
  def gm_unban(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        case GameBackend.Account.unban(target.account_id) do
          {:ok, _} -> Helpers.gm_console(state, char_id, "#{target_name} unbanned.")
          {:error, err} -> Helpers.gm_console(state, char_id, "Unban failed: #{inspect(err)}")
        end

        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  # ── Punishment record helpers ──────────────────────────────────────

  @doc """
  Append a punishment record to an entity's prontuario.
  """
  def add_punishment(entity, text, gm_name) do
    existing = Map.get(entity, :punishments, [])
    next_number = if existing == [], do: 1, else: Enum.max_by(existing, & &1.number).number + 1

    record = %{
      number: next_number,
      text: text,
      date: Date.utc_today() |> Date.to_string(),
      gm_name: gm_name
    }

    Map.put(entity, :punishments, existing ++ [record])
  end

  @doc "Format punishment records for display."
  def format_punishments([]), do: "Sin prontuario."

  def format_punishments(punishments) do
    lines =
      Enum.map(punishments, fn p ->
        "#{p.number}. [#{p.date}] #{p.text} (#{p.gm_name})"
      end)

    "Prontuario:\n" <> Enum.join(lines, "\n")
  end

  defp gm_name_for(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, gm_entity} -> gm_entity.name
      :error -> "GM"
    end
  end
end
