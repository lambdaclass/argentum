defmodule Arena.Map.Gm.Moderation do
  @moduledoc """
  GM moderation commands: kick, ban, mute, jail, kill, etc.

  All public handlers return `{:ok, state, [Effect.t()]}`. The
  `GmCommands` router dispatches them through
  `Arena.Map.Effects.run_handler/2` so the produced effects are run
  against the post-handler state and the cast surface stays at
  `{:noreply, state}`.

  Handlers fan to two recipients in the typical case: a console-style
  audit confirmation to the GM and a notification + state mutation to
  the target. Persistence side effects (AuditLog, GameBackend.Account
  ban/unban, OnlineDirectory disconnects) are still imperative — they
  do not produce packets — and therefore stay as direct calls inside
  the handler body. Only the player-facing packet emissions move to
  the effects list.
  """

  require Logger

  alias Arena.AuditLog
  alias Arena.Map.{Effects, Helpers}
  alias AoProtocol.Server.Encoder

  @jail_map_id 66
  @jail_x 33
  @jail_y 33

  def gm_kick(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, _target} ->
        AuditLog.log_gm_action(char_id, "kick", target_name)
        # `:disconnect` is an out-of-band session control message, not a
        # packet, so it stays on `Helpers.send_to_session/3`. The
        # client-facing console and GM audit confirmation flow through
        # the effects runner.
        Helpers.send_to_session(state.sessions, target_id, :disconnect)

        effects = [
          Effects.send(target_id, console("Has sido expulsado del servidor.")),
          Effects.send(char_id, console("#{target_name} has been kicked."))
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state, [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
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
                AuditLog.log_gm_action(char_id, "ban", "#{target_name} for #{days} day(s)")
                Logger.warning("GM ban: #{target_name} for #{days} days (account_id=#{target.account_id})")
                Helpers.send_to_session(state.sessions, target_id, :disconnect)

                effects = [
                  Effects.send(target_id, console("Has sido baneado por #{days} día(s).")),
                  Effects.send(char_id, console("#{target_name} banned for #{days} day(s)."))
                ]

                {:ok, state, effects}

              {:error, reason} ->
                Logger.error("Failed to persist ban for #{target_name}: #{inspect(reason)}")

                {:ok, state,
                 [Effects.send(char_id, console("Failed to persist ban for #{target_name}."))]}
            end

          :not_found ->
            {:ok, state,
             [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
        end

      _ ->
        {:ok, state, [Effects.send(char_id, console("Usage: /BAN name days"))]}
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

            AuditLog.log_gm_action(char_id, "mute", "#{target.name} for #{minutes} min")

            effects = [
              Effects.send(target_id, console("Has sido silenciado por #{minutes} minuto(s).")),
              Effects.send(char_id, console("#{target.name} muted for #{minutes} minute(s)."))
            ]

            {:ok, state, effects}

          :not_found ->
            {:ok, state,
             [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
        end

      _ ->
        {:ok, state, [Effects.send(char_id, console("Usage: /MUTE name minutes"))]}
    end
  end

  def gm_unmute(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | muted_until: 0}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        AuditLog.log_gm_action(char_id, "unmute", target.name)

        effects = [
          Effects.send(target_id, console("Ya no estás silenciado.")),
          Effects.send(char_id, console("#{target.name} has been unmuted."))
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
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

        AuditLog.log_gm_action(char_id, "jail", "#{target.name} for #{minutes} min")

        effects = [
          Effects.send(target_id, console("Has sido enviado a la cárcel por #{minutes} minutos.")),
          Effects.transfer(target_id, @jail_map_id, @jail_x, @jail_y, target),
          Effects.send(char_id, console("#{target.name} jailed for #{minutes} min (map #{@jail_map_id})."))
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
    end
  end

  def gm_kill(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        if target.dead do
          {:ok, state, [Effects.send(char_id, console("#{target.name} is already dead."))]}
        else
          # PlayerDeath returns canonical map effects which we now thread
          # through the returned list — the legacy `Effects.run/2` bridge
          # is gone because gm_kill is on the effects contract.
          {target, state, pd_effects} =
            Arena.Map.PlayerDeath.handle_player_death(state, target_id, %{target | hp: 0})

          players = Map.put(state.players, target_id, target)
          state = %{state | players: players}

          AuditLog.log_gm_action(char_id, "kill", target.name)

          effects =
            pd_effects ++
              [
                Effects.send(target_id, Encoder.encode({:update_hp, %{min_hp: 0, shield: 0}})),
                Effects.send(target_id, console("A GM has killed you.")),
                Effects.broadcast_character_change(target),
                Effects.send(char_id, console("#{target.name} has been killed."))
              ]

          {:ok, state, effects}
        end

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
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

        {:ok, state,
         [Effects.send(char_id, console("Account for #{target_name} banned: #{reason}"))]}

      {:error, err} ->
        {:ok, state, [Effects.send(char_id, console("Ban failed: #{inspect(err)}"))]}
    end
  end

  def gm_unban_cuenta(state, char_id, target_name) do
    case GameBackend.Account.unban(target_name) do
      :ok ->
        {:ok, state,
         [Effects.send(char_id, console("Account for #{target_name} unbanned."))]}

      {:error, err} ->
        {:ok, state, [Effects.send(char_id, console("Unban failed: #{inspect(err)}"))]}
    end
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

            {:ok, state,
             [Effects.send(char_id, console("#{target_name} banned for #{days} days: #{reason}"))]}

          {:error, err} ->
            {:ok, state,
             [Effects.send(char_id, console("Temp ban failed: #{inspect(err)}"))]}
        end

      _ ->
        {:ok, state, [Effects.send(char_id, console("Invalid days value."))]}
    end
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

          {:ok, state,
           [Effects.send(char_id, console("Punishment ##{num} removed from #{target_name}."))]}
        else
          {:ok, state,
           [Effects.send(char_id, console("Punishment ##{num} not found for #{target_name}."))]}
        end

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
    end
  end

  def gm_council_kick(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = Map.put(target, :council, false)
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        AuditLog.log_gm_action(char_id, "council_kick", target_name)

        {:ok, state,
         [Effects.send(char_id, console("#{target_name} removed from council."))]}

      :not_found ->
        {:ok, state, [Effects.send(char_id, console("Player '#{target_name}' not found."))]}
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

        {:ok, state,
         [Effects.send(char_id, console("#{target_name} expelled from #{label}."))]}

      :not_found ->
        {:ok, state, [Effects.send(char_id, console("Player '#{target_name}' not found."))]}
    end
  end

  def gm_unjail(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | penalty: 0}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        AuditLog.log_gm_action(char_id, "unjail", target.name)

        effects = [
          Effects.send(target_id, console("Has sido liberado de la cárcel.")),
          Effects.send(char_id, console("#{target.name} has been unjailed (penalty cleared)."))
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
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
        AuditLog.log_gm_action(char_id, "navigando", "#{target.name} #{status}")

        effects = [
          Effects.send(target_id, console("Navegación #{status}.")),
          Effects.send(char_id, console("#{target.name} navigation #{status}."))
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
    end
  end

  def gm_rm_criminal(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | criminal: false}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        AuditLog.log_gm_action(char_id, "rm_criminal", target.name)

        effects = [
          Effects.send(target_id, console("Tu status de criminal ha sido removido.")),
          Effects.send(char_id, console("#{target.name} is no longer a criminal."))
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
    end
  end

  def gm_rm_citizen(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | criminal: true}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        AuditLog.log_gm_action(char_id, "rm_citizen", target.name)

        effects = [
          Effects.send(target_id, console("Ahora eres un criminal.")),
          Effects.send(char_id, console("#{target.name} is now a criminal."))
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
    end
  end

  @doc "/KICKALLCHARS — kick all non-GM players from this map."
  def gm_kick_all_chars(state, char_id) do
    {kicked, kick_effects} =
      Enum.reduce(state.players, {0, []}, fn {pid, entity}, {count, effs} ->
        if not entity.gm do
          # `:disconnect` stays as an imperative session-control side
          # effect; it is not a packet and therefore not routed through
          # the effects runner.
          Helpers.send_to_session(state.sessions, pid, :disconnect)

          {count + 1,
           effs ++ [Effects.send(pid, console("Todos los jugadores han sido expulsados."))]}
        else
          {count, effs}
        end
      end)

    AuditLog.log_gm_action(char_id, "kick_all_chars", "#{kicked} players")

    effects =
      kick_effects ++
        [Effects.send(char_id, console("Kicked #{kicked} non-GM player(s) from this map."))]

    {:ok, state, effects}
  end

  @doc "/UNBAN name — unban a character by looking them up on the current map first."
  def gm_unban(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        msg =
          case GameBackend.Account.unban(target.account_id) do
            {:ok, _} -> "#{target_name} unbanned."
            {:error, err} -> "Unban failed: #{inspect(err)}"
          end

        {:ok, state, [Effects.send(char_id, console(msg))]}

      :not_found ->
        {:ok, state,
         [Effects.send(char_id, console("Player '#{target_name}' not found on this map."))]}
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

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  defp gm_name_for(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, gm_entity} -> gm_entity.name
      :error -> "GM"
    end
  end
end
