defmodule Arena.Map.Social do
  @moduledoc "Chat, social commands, stat requests, and NPC interaction."

  require Logger

  alias Arena.Map.{Helpers, Visibility, Crafting}
  alias Arena.Entity.NpcEntity
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_revividor 1
  @npc_type_entrenador 3
  @npc_type_banquero 4
  @npc_type_enlistador 5
  @npc_type_timbero 6
  @npc_type_resucitador_newbie 9
  @npc_type_arena_guard 10
  @npc_type_subastador 16
  @npc_type_entrega_pesca 20
  @yell_range_x Application.compile_env(:arena, :aoi_range_x, 11) * 2
  @yell_range_y Application.compile_env(:arena, :aoi_range_y, 9) * 2
  @magical_classes [:mage, :cleric, :druid, :bard, :paladin]
  @jail_map_id 66
  @jail_x 33
  @jail_y 33
  @chat_cooldown_ms 1000

  # ==================================================================
  # Safe toggle
  # ==================================================================

  def handle_safe_toggle(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        new_safe = not entity.safe_mode
        entity = %{entity | safe_mode: new_safe}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        packet = if new_safe, do: {:safe_mode_on, %{}}, else: {:safe_mode_off, %{}}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode(packet)})

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_on_map}, state}
    end
  end

  # ==================================================================
  # Chat / Social
  # ==================================================================

  def handle_chat(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if String.starts_with?(message, "/") do
          if entity.gm do
            handle_gm_command(state, char_id, entity, message)
          else
            # Non-GM typed a slash command — silently ignore (don't broadcast)
            {:noreply, state}
          end
        else
          now = System.monotonic_time(:millisecond)
          wall_now = System.system_time(:millisecond)

          cond do
            # Mute enforcement (wall-clock ms for persistence across restarts)
            entity.muted_until > 0 and wall_now < entity.muted_until ->
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "Estás silenciado.", font_index: 0}})}
              )

              {:noreply, state}

            # Chat rate limit: 1 message per second
            now - entity.last_chat_at < @chat_cooldown_ms ->
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode({:console_msg, %{message: "Estás hablando demasiado rápido.", font_index: 0}})}
              )

              {:noreply, state}

            true ->
              # Apply word filter
              filtered_message = Arena.ChatFilter.filter(message)

              # Update last_chat_at
              entity = %{entity | last_chat_at: now}
              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              chat_raw =
                Encoder.encode(
                  {:chat_over_head,
                   %{
                     message: filtered_message,
                     char_index: entity.char_index,
                     color: 0x00FFFFFF,
                     x: entity.x,
                     y: entity.y,
                     min_display_time: 2000,
                     max_display_time: 5000
                   }}
                )

              # Send to nearby players including the speaker
              chat_recipients =
                Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
                  send(pid, {:send_raw, chat_raw})
                end)

              Arena.Metrics.inc_chat(chat_recipients)

              {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # GM Rain Toggle (binary packet, not chat)
  # ==================================================================

  def handle_gm_rain_toggle(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.gm ->
        new_rain = not state.meta.rain
        meta = %{state.meta | rain: new_rain}
        state = %{state | meta: meta}

        rain_raw = Encoder.encode({:rain_toggle, %{raining: new_rain}})

        for {_cid, pid} <- state.sessions do
          send(pid, {:send_raw, rain_raw})
        end

        label = if new_rain, do: "ON", else: "OFF"
        gm_console(state, char_id, "Rain toggled #{label} on this map.")

        {:noreply, state}

      {:ok, _entity} ->
        gm_console(state, char_id, "You are not a GM.")
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # GM Commands
  # ==================================================================

  defp gm_console(state, char_id, message) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:console_msg, %{message: message, font_index: 0}})}
    )
  end

  defp handle_gm_command(state, char_id, entity, message) do
    upper = String.upcase(String.trim(message))
    parts = String.split(String.trim(message), ~r/\s+/, parts: 4)
    upper_parts = String.split(upper, ~r/\s+/, parts: 4)

    case upper_parts do
      ["/TELEPORT", map_str, x_str, y_str] ->
        gm_teleport(state, char_id, entity, map_str, x_str, y_str)

      ["/SPAWNITEM", item_str, amount_str] ->
        gm_spawn_item(state, char_id, entity, item_str, amount_str)

      ["/SPAWNITEM", item_str] ->
        gm_spawn_item(state, char_id, entity, item_str, "1")

      ["/INVISIBLE"] ->
        gm_invisible(state, char_id, entity)

      ["/GOTO", _name_upper] ->
        # Use original-case name from parts
        target_name = Enum.at(parts, 1)
        gm_goto(state, char_id, entity, target_name)

      ["/INFO", _name_upper] ->
        target_name = Enum.at(parts, 1)
        gm_info(state, char_id, target_name)

      ["/KILL", _name_upper] ->
        target_name = Enum.at(parts, 1)
        gm_kill(state, char_id, target_name)

      ["/KICK", _name_upper] ->
        target_name = Enum.at(parts, 1)
        gm_kick(state, char_id, target_name)

      ["/BAN", _name_upper, days_str] ->
        target_name = Enum.at(parts, 1)
        gm_ban(state, char_id, target_name, days_str)

      ["/MUTE", _name_upper, minutes_str] ->
        target_name = Enum.at(parts, 1)
        gm_mute(state, char_id, target_name, minutes_str)

      ["/UNMUTE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        gm_unmute(state, char_id, target_name)

      ["/JAIL", _name_upper | _rest] ->
        target_name = Enum.at(parts, 1)

        minutes =
          case Enum.at(parts, 2) do
            nil ->
              10

            str ->
              case Integer.parse(str) do
                {m, _} when m > 0 -> m
                _ -> 10
              end
          end

        gm_jail(state, char_id, target_name, minutes)

      ["/SPAWNNPC", npc_id_str] ->
        gm_spawn_npc(state, char_id, entity, npc_id_str)

      ["/LOCATE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        gm_locate(state, char_id, target_name)

      ["/REVIVE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        gm_revive(state, char_id, target_name)

      ["/ONLINEMAP"] ->
        gm_online_map(state, char_id)

      ["/KILLNPC"] ->
        gm_kill_npc(state, char_id, entity)

      ["/KILLNPCPERM"] ->
        gm_kill_npc_permanent(state, char_id, entity)

      ["/MASSKILL"] ->
        gm_mass_kill_npcs(state, char_id, entity)

      ["/SPAWNNPCR", npc_id_str] ->
        gm_spawn_npc_respawn(state, char_id, entity, npc_id_str)

      ["/SPAWNLIST"] ->
        gm_spawn_list(state, char_id)

      ["/CREATURES", map_str] ->
        gm_creatures_in_map(state, char_id, map_str)

      ["/GIVEITEM", _name, item_str, amount_str] ->
        target_name = Enum.at(parts, 1)
        gm_give_item(state, char_id, target_name, item_str, amount_str)

      ["/CHARSTATS", _name] ->
        target_name = Enum.at(parts, 1)
        gm_char_stats(state, char_id, target_name)

      ["/CHARGOLD", _name] ->
        target_name = Enum.at(parts, 1)
        gm_char_gold(state, char_id, target_name)

      ["/CHARINV", _name] ->
        target_name = Enum.at(parts, 1)
        gm_char_inventory(state, char_id, target_name)

      ["/CHARBANK", _name] ->
        target_name = Enum.at(parts, 1)
        gm_char_bank(state, char_id, target_name)

      ["/CHARSKILLS", _name] ->
        target_name = Enum.at(parts, 1)
        gm_char_skills(state, char_id, target_name)

      ["/EDITCHAR", _name, option_str, arg1] ->
        target_name = Enum.at(parts, 1)
        gm_edit_char(state, char_id, target_name, option_str, arg1)

      ["/ALTERNAME", _old, _new] ->
        old_name = Enum.at(parts, 1)
        new_name = Enum.at(parts, 2)
        gm_alter_name(state, char_id, old_name, new_name)

      # Batch 4: Punishment & Communication
      ["/BANCUENTA", _name | _rest] ->
        target_name = Enum.at(parts, 1)
        reason = Enum.at(parts, 2, "Sin motivo")
        gm_ban_cuenta(state, char_id, target_name, reason)

      ["/UNBANCUENTA", _name] ->
        target_name = Enum.at(parts, 1)
        gm_unban_cuenta(state, char_id, target_name)

      ["/BANTEMPORAL", _name, days_str | _rest] ->
        target_name = Enum.at(parts, 1)
        reason = Enum.at(parts, 3, "Sin motivo")
        gm_ban_temporal(state, char_id, target_name, days_str, reason)

      ["/REMOVEPUNISHMENT", _name, num_str | _rest] ->
        target_name = Enum.at(parts, 1)
        text = Enum.at(parts, 3, "")
        gm_remove_punishment(state, char_id, target_name, num_str, text)

      ["/RMSG" | _rest] ->
        msg_text = String.trim_leading(String.trim(message), "/RMSG ")
        gm_faction_message(state, char_id, :royal_army, msg_text)

      ["/CMSG" | _rest] ->
        msg_text = String.trim_leading(String.trim(message), "/CMSG ")
        gm_faction_message(state, char_id, :chaos_legion, msg_text)

      ["/TALKASNPC" | _rest] ->
        msg_text = String.trim_leading(String.trim(message), "/TALKASNPC ")
        gm_talk_as_npc(state, char_id, entity, msg_text)

      # Batch 5: Map & Environment
      ["/NIEVE"] ->
        gm_toggle_weather(state, char_id, :snow)

      ["/NIEBLA"] ->
        gm_toggle_weather(state, char_id, :fog)

      ["/MAPPK", flag] ->
        gm_change_map_flag(state, char_id, :pk, flag)

      ["/MAPNOMAGIC", flag] ->
        gm_change_map_flag(state, char_id, :no_magic, flag)

      ["/MAPNOINVI", flag] ->
        gm_change_map_flag(state, char_id, :no_invi, flag)

      ["/MAPNORESU", flag] ->
        gm_change_map_flag(state, char_id, :no_resu, flag)

      ["/TILEBLOCK"] ->
        gm_tile_block_toggle(state, char_id, entity)

      ["/SETTRIGGER", trigger_str] ->
        gm_set_trigger(state, char_id, entity, trigger_str)

      ["/ASKTRIGGER"] ->
        gm_ask_trigger(state, char_id, entity)

      # Batch 6: Audio & Utility
      ["/FORCEMIDIMAP", midi_str, map_str] ->
        gm_force_midi_map(state, char_id, midi_str, map_str)

      ["/FORCEWAVEMAP", wave_str, x_str, y_str | _rest] ->
        map_str = Enum.at(upper_parts, 4, "0")
        gm_force_wave_map(state, char_id, wave_str, x_str, y_str, map_str)

      ["/ITEMSFLOOR"] ->
        gm_items_in_floor(state, char_id)

      ["/DESTROYITEMS"] ->
        gm_destroy_items(state, char_id, entity)

      ["/DESTROYALLAREA"] ->
        gm_destroy_all_area(state, char_id, entity)

      ["/CLEANWORLD"] ->
        gm_clean_world(state, char_id)

      ["/SHOWNAME"] ->
        gm_show_name(state, char_id, entity)

      ["/SETDESC" | _rest] ->
        desc = String.trim_leading(String.trim(message), "/SETDESC ")
        gm_set_description(state, char_id, entity, desc)

      ["/SETSPEED", speed_str] ->
        gm_set_speed(state, char_id, entity, speed_str)

      ["/CHECKSLOT", _name, slot_str] ->
        target_name = Enum.at(parts, 1)
        gm_check_slot(state, char_id, target_name, slot_str)

      # Batch 7: Faction/Council + SOS
      ["/COUNCILKICK", _name] ->
        target_name = Enum.at(parts, 1)
        gm_council_kick(state, char_id, target_name)

      ["/ROYALCOUNCIL", _name] ->
        target_name = Enum.at(parts, 1)
        gm_accept_council(state, char_id, target_name, :royal)

      ["/CHAOSCOUNCIL", _name] ->
        target_name = Enum.at(parts, 1)
        gm_accept_council(state, char_id, target_name, :chaos)

      ["/ROYALKICK", _name] ->
        target_name = Enum.at(parts, 1)
        gm_faction_kick(state, char_id, target_name, :royal_army)

      ["/CHAOSKICK", _name] ->
        target_name = Enum.at(parts, 1)
        gm_faction_kick(state, char_id, target_name, :chaos_legion)

      # Events, Invasions, Tournaments
      ["/INVASION", map_str, npc_str, count_str] ->
        gm_invasion(state, char_id, entity, map_str, npc_str, count_str)

      ["/INVASION", "STOP", map_str] ->
        gm_invasion_stop(state, char_id, map_str)

      ["/INVASION", "LIST"] ->
        gm_invasion_list(state, char_id)

      ["/TOURNAMENT", "START" | rest] ->
        max_str = List.first(rest) || "16"
        gm_tournament_start(state, char_id, entity, max_str)

      ["/TOURNAMENT", "BEGIN"] ->
        gm_tournament_begin(state, char_id)

      ["/TOURNAMENT", "CANCEL"] ->
        gm_tournament_cancel(state, char_id)

      ["/TOURNAMENT", "STATUS"] ->
        gm_tournament_status(state, char_id)

      ["/EVENT", "START", type_str, duration_str] ->
        gm_event_start(state, char_id, entity, type_str, duration_str)

      ["/EVENT", "STOP", type_str] ->
        gm_event_stop(state, char_id, type_str)

      ["/EVENT", "LIST"] ->
        gm_event_list(state, char_id)

      _ ->
        gm_console(state, char_id, "Unknown GM command: #{message}")
        {:noreply, state}
    end
  end

  # /TELEPORT map_id x y — transfer GM to another map
  defp gm_teleport(state, char_id, entity, map_str, x_str, y_str) do
    with {map_id, ""} <- Integer.parse(map_str),
         {x, ""} <- Integer.parse(x_str),
         {y, ""} <- Integer.parse(y_str) do
      Helpers.send_to_session(state.sessions, char_id, {:transfer, map_id, x, y, entity})
      gm_console(state, char_id, "Teleporting to map #{map_id} (#{x}, #{y})...")
      {:noreply, state}
    else
      _ ->
        gm_console(state, char_id, "Usage: /TELEPORT map_id x y")
        {:noreply, state}
    end
  end

  # /SPAWNITEM item_id [amount] — add item to GM inventory
  defp gm_spawn_item(state, char_id, entity, item_str, amount_str) do
    with {item_id, ""} <- Integer.parse(item_str),
         {amount, ""} <- Integer.parse(amount_str),
         true <- amount > 0 do
      case Arena.Inventory.add_item(entity.inventory, item_id, amount) do
        {:ok, new_inventory, slot} ->
          entity = %{entity | inventory: new_inventory}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, slot)
          gm_console(state, char_id, "Spawned #{amount}x item #{item_id} in slot #{slot + 1}.")
          {:noreply, state}

        {:gold, gold_amount} ->
          entity = %{entity | gold: entity.gold + gold_amount}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
          )

          gm_console(state, char_id, "Added #{gold_amount} gold.")
          {:noreply, state}

        {:error, :inventory_full} ->
          gm_console(state, char_id, "Inventory full.")
          {:noreply, state}
      end
    else
      _ ->
        gm_console(state, char_id, "Usage: /SPAWNITEM item_id [amount]")
        {:noreply, state}
    end
  end

  # /INVISIBLE — toggle GM invisibility
  defp gm_invisible(state, char_id, entity) do
    new_invisible = not entity.invisible
    entity = %{entity | invisible: new_invisible}
    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}

    msg = if new_invisible, do: "You are now invisible.", else: "You are now visible."
    gm_console(state, char_id, msg)
    Helpers.broadcast_character_change(state, entity)
    {:noreply, state}
  end

  # /GOTO name — teleport GM to target player on the same map
  defp gm_goto(state, char_id, entity, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        if target.map_id == entity.map_id do
          # Transfer to same map at target position
          Helpers.send_to_session(state.sessions, char_id, {:transfer, entity.map_id, target.x, target.y, entity})
          gm_console(state, char_id, "Teleporting to #{target.name} at (#{target.x}, #{target.y})...")
          {:noreply, state}
        else
          # Target is on a different map — transfer there
          Helpers.send_to_session(state.sessions, char_id, {:transfer, target.map_id, target.x, target.y, entity})

          gm_console(
            state,
            char_id,
            "Teleporting to #{target.name} on map #{target.map_id} (#{target.x}, #{target.y})..."
          )

          {:noreply, state}
        end

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  # /INFO name — show target player stats
  defp gm_info(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        gm_console(state, char_id, "=== Player Info: #{target.name} ===")
        gm_console(state, char_id, "HP: #{target.hp}/#{target.max_hp} | Mana: #{target.mana}/#{target.max_mana}")
        gm_console(state, char_id, "Level: #{target.level} | Class: #{target.class} | Race: #{target.race}")
        gm_console(state, char_id, "Position: map #{target.map_id} (#{target.x}, #{target.y})")
        gm_console(state, char_id, "Gold: #{target.gold} | XP: #{target.xp}")

        gm_console(
          state,
          char_id,
          "Dead: #{target.dead} | Criminal: #{target.criminal} | Invisible: #{target.invisible}"
        )

        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  # /KILL name — kill a target player on the same map
  defp gm_kill(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        if target.dead do
          gm_console(state, char_id, "#{target.name} is already dead.")
          {:noreply, state}
        else
          {target, state} = Arena.Map.CombatHandlers.handle_player_death(state, target_id, %{target | hp: 0})
          players = Map.put(state.players, target_id, target)
          state = %{state | players: players}

          # Notify the killed player
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
          gm_console(state, char_id, "#{target.name} has been killed.")
          {:noreply, state}
        end

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  # /KICK name — kick player from the server
  defp gm_kick(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, target_id, _target} ->
        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido expulsado del servidor.", font_index: 0}})}
        )

        Helpers.send_to_session(state.sessions, target_id, :disconnect)
        gm_console(state, char_id, "#{target_name} has been kicked.")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  # /BAN name days — ban player and persist to the database
  defp gm_ban(state, char_id, target_name, days_str) do
    case Integer.parse(days_str) do
      {days, ""} when days > 0 ->
        case find_player_by_name(state, target_name) do
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
                gm_console(state, char_id, "#{target_name} banned for #{days} day(s).")

              {:error, reason} ->
                Logger.error("Failed to persist ban for #{target_name}: #{inspect(reason)}")
                gm_console(state, char_id, "Failed to persist ban for #{target_name}.")
            end

            {:noreply, state}

          :not_found ->
            gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
            {:noreply, state}
        end

      _ ->
        gm_console(state, char_id, "Usage: /BAN name days")
        {:noreply, state}
    end
  end

  # /MUTE name minutes — mute a player for N minutes
  defp gm_mute(state, char_id, target_name, minutes_str) do
    case Integer.parse(minutes_str) do
      {minutes, ""} when minutes > 0 ->
        case find_player_by_name(state, target_name) do
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

            gm_console(state, char_id, "#{target.name} muted for #{minutes} minute(s).")
            {:noreply, state}

          :not_found ->
            gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
            {:noreply, state}
        end

      _ ->
        gm_console(state, char_id, "Usage: /MUTE name minutes")
        {:noreply, state}
    end
  end

  # /UNMUTE name — remove mute from a player
  defp gm_unmute(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | muted_until: 0}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}

        Helpers.send_to_session(
          state.sessions,
          target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Ya no estás silenciado.", font_index: 0}})}
        )

        gm_console(state, char_id, "#{target.name} has been unmuted.")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  # /JAIL name [minutes] — teleport player to jail map and set penalty timer
  defp gm_jail(state, char_id, target_name, minutes) do
    case find_player_by_name(state, target_name) do
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
        gm_console(state, char_id, "#{target.name} jailed for #{minutes} min (map #{@jail_map_id}).")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  # /SPAWNNPC npc_id — spawn an NPC at the GM's facing tile
  defp gm_spawn_npc(state, char_id, entity, npc_id_str) do
    case Integer.parse(npc_id_str) do
      {npc_id, ""} ->
        case GameData.get_npc(npc_id) do
          nil ->
            gm_console(state, char_id, "NPC #{npc_id} not found in data.")
            {:noreply, state}

          npc_def ->
            {tx, ty} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

            if tx >= 1 and tx <= Helpers.map_width() and
                 ty >= 1 and ty <= Helpers.map_height() and
                 TileGrid.is_walkable(state.map_id, tx, ty) and
                 Helpers.get_occupancy(state.occupancy, tx, ty) == nil do
              instance_id = state.next_char_index
              npc_entity = NpcEntity.from_def(npc_def, instance_id, instance_id, tx, ty)

              npcs_live = Map.put(state.npcs_live, instance_id, npc_entity)
              npc_char_indices = Map.put(state.npc_char_indices, instance_id, instance_id)
              occupancy = Helpers.set_occupancy(state.occupancy, tx, ty, {:npc, instance_id})

              state = %{
                state
                | npcs_live: npcs_live,
                  npc_char_indices: npc_char_indices,
                  occupancy: occupancy,
                  next_char_index: instance_id + 1
              }

              # Broadcast character_create for the new NPC
              raw = Encoder.encode(Helpers.npc_create_packet(npc_entity, npc_def))

              Visibility.broadcast_visible_all(state, tx, ty, fn pid ->
                send(pid, {:send_raw, raw})
              end)

              gm_console(state, char_id, "Spawned NPC #{npc_def.name} (id #{npc_id}) at (#{tx}, #{ty}).")
              {:noreply, state}
            else
              gm_console(state, char_id, "Cannot spawn NPC: facing tile (#{tx}, #{ty}) is blocked or occupied.")
              {:noreply, state}
            end
        end

      _ ->
        gm_console(state, char_id, "Usage: /SPAWNNPC npc_id")
        {:noreply, state}
    end
  end

  # /KILLNPC — kill the NPC at the GM's facing tile (allows respawn)
  defp gm_kill_npc(state, char_id, entity) do
    {tx, ty} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

    case Helpers.get_occupancy(state.occupancy, tx, ty) do
      {:npc, instance_id} ->
        case Map.get(state.npcs_live, instance_id) do
          nil ->
            gm_console(state, char_id, "No NPC found at facing tile.")
            {:noreply, state}

          npc ->
            npc_def = GameData.get_npc(npc.npc_id)
            npc_name = if npc_def, do: npc_def.name, else: "NPC #{npc.npc_id}"

            # Mark NPC as dead with respawn (same as combat death)
            dead_npc = %{
              npc
              | alive: false,
                respawn_at:
                  System.monotonic_time(:millisecond) +
                    if(npc_def, do: npc_def.intervalo_respawn, else: 60) * 1000
            }

            npcs_live = Map.put(state.npcs_live, instance_id, dead_npc)
            occupancy = Helpers.clear_occupancy(state.occupancy, npc.x, npc.y)

            # Broadcast removal
            raw = Encoder.encode({:character_remove, %{char_index: npc.char_index}})

            Visibility.broadcast_visible_all(state, npc.x, npc.y, fn pid ->
              send(pid, {:send_raw, raw})
            end)

            state = %{state | npcs_live: npcs_live, occupancy: occupancy}
            gm_console(state, char_id, "Killed NPC #{npc_name} (respawn enabled).")
            {:noreply, state}
        end

      _ ->
        gm_console(state, char_id, "No NPC at facing tile (#{tx}, #{ty}).")
        {:noreply, state}
    end
  end

  # /KILLNPCPERM — kill the NPC at the GM's facing tile permanently (no respawn)
  defp gm_kill_npc_permanent(state, char_id, entity) do
    {tx, ty} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

    case Helpers.get_occupancy(state.occupancy, tx, ty) do
      {:npc, instance_id} ->
        case Map.get(state.npcs_live, instance_id) do
          nil ->
            gm_console(state, char_id, "No NPC found at facing tile.")
            {:noreply, state}

          npc ->
            npc_def = GameData.get_npc(npc.npc_id)
            npc_name = if npc_def, do: npc_def.name, else: "NPC #{npc.npc_id}"

            # Remove NPC entirely (no respawn)
            npcs_live = Map.delete(state.npcs_live, instance_id)
            occupancy = Helpers.clear_occupancy(state.occupancy, npc.x, npc.y)

            # Broadcast removal
            raw = Encoder.encode({:character_remove, %{char_index: npc.char_index}})

            Visibility.broadcast_visible_all(state, npc.x, npc.y, fn pid ->
              send(pid, {:send_raw, raw})
            end)

            state = %{state | npcs_live: npcs_live, occupancy: occupancy}
            gm_console(state, char_id, "Killed NPC #{npc_name} permanently (no respawn).")
            {:noreply, state}
        end

      _ ->
        gm_console(state, char_id, "No NPC at facing tile (#{tx}, #{ty}).")
        {:noreply, state}
    end
  end

  # /MASSKILL — kill all NPCs within AOI range
  defp gm_mass_kill_npcs(state, char_id, entity) do
    aoi_x = Helpers.aoi_range_x()
    aoi_y = Helpers.aoi_range_y()

    {killed, state} =
      Enum.reduce(state.npcs_live, {0, state}, fn {inst_id, npc}, {count, st} ->
        if npc.alive and abs(npc.x - entity.x) <= aoi_x and abs(npc.y - entity.y) <= aoi_y do
          npcs_live = Map.delete(st.npcs_live, inst_id)
          occupancy = Helpers.clear_occupancy(st.occupancy, npc.x, npc.y)

          raw = Encoder.encode({:character_remove, %{char_index: npc.char_index}})

          Visibility.broadcast_visible_all(st, npc.x, npc.y, fn pid ->
            send(pid, {:send_raw, raw})
          end)

          {count + 1, %{st | npcs_live: npcs_live, occupancy: occupancy}}
        else
          {count, st}
        end
      end)

    gm_console(state, char_id, "Killed #{killed} NPCs nearby.")
    {:noreply, state}
  end

  # /SPAWNNPCR npc_id — spawn an NPC at the GM's facing tile (with respawn flag)
  defp gm_spawn_npc_respawn(state, char_id, entity, npc_id_str) do
    # For now, spawns the same way as /SPAWNNPC — respawn persistence is a future enhancement
    gm_spawn_npc(state, char_id, entity, npc_id_str)
  end

  # /SPAWNLIST — list all live NPCs on the current map
  defp gm_spawn_list(state, char_id) do
    entries =
      Enum.filter(state.npcs_live, fn {_inst_id, npc} -> npc.alive end)
      |> Enum.map(fn {inst_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)
        name = if npc_def, do: npc_def.name, else: "?"
        "#{inst_id}: #{name} (#{npc.npc_id}) at (#{npc.x},#{npc.y})"
      end)

    gm_console(state, char_id, "NPCs on map (#{length(entries)}):")

    Enum.each(entries, fn entry ->
      gm_console(state, char_id, entry)
    end)

    {:noreply, state}
  end

  # /CREATURES map_id — list NPCs on a specific map
  defp gm_creatures_in_map(state, char_id, map_str) do
    case Integer.parse(map_str) do
      {map_id, ""} ->
        if map_id == state.map_id do
          # Local map — reuse spawn list logic
          gm_spawn_list(state, char_id)
        else
          gm_console(state, char_id, "Cross-map NPC queries are not supported yet.")
          {:noreply, state}
        end

      _ ->
        gm_console(state, char_id, "Usage: /CREATURES map_id")
        {:noreply, state}
    end
  end

  # /LOCATE name — find a player's location (uses OnlineDirectory if available)
  defp gm_locate(state, char_id, target_name) do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, _target_char_id, info} ->
        gm_console(state, char_id, "#{target_name} está en mapa #{info.map_id}")
        {:noreply, state}

      :not_found ->
        # Fall back to searching current map only
        case find_player_by_name(state, target_name) do
          {:ok, _target_id, target} ->
            gm_console(state, char_id, "#{target.name} está en mapa #{state.map_id} (#{target.x}, #{target.y})")
            {:noreply, state}

          :not_found ->
            gm_console(state, char_id, "Player '#{target_name}' not found.")
            {:noreply, state}
        end
    end
  end

  # /REVIVE name — resurrect a dead player on this map
  defp gm_revive(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        if not target.dead do
          gm_console(state, char_id, "#{target.name} no esta muerto.")
          {:noreply, state}
        else
          target = %{target | dead: false, hp: target.max_hp}
          players = Map.put(state.players, target_id, target)
          state = %{state | players: players}

          Helpers.send_to_session(
            state.sessions,
            target_id,
            {:send_raw, Encoder.encode({:update_hp, %{min_hp: target.hp}})}
          )

          Helpers.send_to_session(
            state.sessions,
            target_id,
            {:send_raw,
             Encoder.encode(
               {:console_msg, %{message: "Un GM te ha resucitado.", font_index: 0}}
             )}
          )

          Helpers.broadcast_character_change(state, target)
          gm_console(state, char_id, "#{target.name} ha sido resucitado.")
          {:noreply, state}
        end

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  # /ONLINEMAP — list players on current map
  defp gm_online_map(state, char_id) do
    names = Enum.map(state.players, fn {_id, entity} -> entity.name end)
    count = length(names)
    gm_console(state, char_id, "Jugadores en mapa (#{count}): #{Enum.join(names, ", ")}")
    {:noreply, state}
  end

  # ---- Batch 3: Character Management GM helpers ----

  defp gm_give_item(state, char_id, target_name, item_str, amount_str) do
    with {item_id, ""} <- Integer.parse(item_str),
         {amount, ""} <- Integer.parse(amount_str),
         true <- amount > 0 do
      case find_player_by_name(state, target_name) do
        {:ok, target_id, target} ->
          case Arena.Inventory.add_item(target.inventory, item_id, amount) do
            {:ok, new_inventory, slot} ->
              target = %{target | inventory: new_inventory}
              players = Map.put(state.players, target_id, target)
              state = %{state | players: players}
              Helpers.send_inventory_slot(state.sessions, target_id, new_inventory, slot)
              gm_console(state, char_id, "Gave #{amount}x item #{item_id} to #{target.name}.")
              {:noreply, state}

            {:gold, gold_amount} ->
              target = %{target | gold: target.gold + gold_amount}
              players = Map.put(state.players, target_id, target)
              state = %{state | players: players}

              Helpers.send_to_session(
                state.sessions,
                target_id,
                {:send_raw, Encoder.encode({:update_gold, %{gold: target.gold}})}
              )

              gm_console(state, char_id, "Gave #{gold_amount} gold to #{target.name}.")
              {:noreply, state}

            {:error, :inventory_full} ->
              gm_console(state, char_id, "#{target.name}'s inventory is full.")
              {:noreply, state}
          end

        :not_found ->
          gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
          {:noreply, state}
      end
    else
      _ ->
        gm_console(state, char_id, "Usage: /GIVEITEM name item_id amount")
        {:noreply, state}
    end
  end

  defp gm_char_stats(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        gm_console(state, char_id, "=== Stats: #{target.name} ===")
        gm_console(state, char_id, "STR: #{target.str} AGI: #{target.agi} INT: #{target.int}")
        gm_console(state, char_id, "CON: #{target.con} CHA: #{target.cha}")
        gm_console(state, char_id, "Level: #{target.level} XP: #{target.xp}")
        gm_console(state, char_id, "HP: #{target.hp}/#{target.max_hp} Mana: #{target.mana}/#{target.max_mana}")
        gm_console(state, char_id, "Stamina: #{target.stamina}/#{target.max_stamina}")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  defp gm_char_gold(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        gm_console(state, char_id, "#{target.name} gold: #{target.gold}")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  defp gm_char_inventory(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        gm_console(state, char_id, "=== Inventory: #{target.name} ===")

        target.inventory
        |> Enum.with_index(1)
        |> Enum.each(fn {item, slot} ->
          if item != nil do
            item_def = GameData.get_item(item.item_id)
            name = if item_def, do: item_def.name, else: "?"
            gm_console(state, char_id, "Slot #{slot}: #{name} (#{item.item_id}) x#{item.amount}")
          end
        end)

        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  defp gm_char_bank(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        gm_console(state, char_id, "#{target.name} bank gold: #{Map.get(target, :bank_gold, 0)}")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  defp gm_char_skills(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        gm_console(state, char_id, "=== Skills: #{target.name} ===")

        Enum.each(target.skills, fn {skill, level} ->
          gm_console(state, char_id, "#{skill}: #{level}")
        end)

        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  defp gm_edit_char(state, char_id, target_name, option_str, value_str) do
    case find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        case {option_str, Integer.parse(value_str)} do
          {"1", {value, _}} ->
            target = %{target | gold: max(value, 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}

            Helpers.send_to_session(
              state.sessions,
              target_id,
              {:send_raw, Encoder.encode({:update_gold, %{gold: target.gold}})}
            )

            gm_console(state, char_id, "Set #{target.name} gold to #{target.gold}.")
            {:noreply, state}

          {"2", {value, _}} ->
            target = %{target | level: max(min(value, 50), 1)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            gm_console(state, char_id, "Set #{target.name} level to #{target.level}.")
            {:noreply, state}

          {"3", {value, _}} ->
            target = %{target | xp: max(value, 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            gm_console(state, char_id, "Set #{target.name} XP to #{target.xp}.")
            {:noreply, state}

          {"4", {value, _}} ->
            target = %{target | hp: max(min(value, target.max_hp), 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}

            Helpers.send_to_session(
              state.sessions,
              target_id,
              {:send_raw, Encoder.encode({:update_hp, %{min_hp: target.hp, shield: 0}})}
            )

            gm_console(state, char_id, "Set #{target.name} HP to #{target.hp}.")
            {:noreply, state}

          {"5", {value, _}} ->
            target = %{target | mana: max(min(value, target.max_mana), 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}

            Helpers.send_to_session(
              state.sessions,
              target_id,
              {:send_raw, Encoder.encode({:update_mana, %{min_mana: target.mana}})}
            )

            gm_console(state, char_id, "Set #{target.name} mana to #{target.mana}.")
            {:noreply, state}

          _ ->
            gm_console(state, char_id, "Usage: /EDITCHAR name option value")
            gm_console(state, char_id, "Options: 1=Gold 2=Level 3=XP 4=HP 5=Mana")
            {:noreply, state}
        end

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  defp gm_alter_name(state, char_id, old_name, new_name) do
    case find_player_by_name(state, old_name) do
      {:ok, target_id, target} ->
        target = %{target | name: new_name}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        Helpers.broadcast_character_change(state, target)
        gm_console(state, char_id, "Renamed #{old_name} to #{new_name}.")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{old_name}' not found.")
        {:noreply, state}
    end
  end

  # ---- Batch 4: Punishment & Communication GM helpers ----

  defp gm_ban_cuenta(state, char_id, target_name, reason) do
    case GameBackend.Account.ban(target_name, reason) do
      :ok ->
        # Kick if online
        case AoSession.OnlineDirectory.lookup_by_name(target_name) do
          {:ok, session} -> send(session.pid, :disconnect)
          _ -> :ok
        end

        gm_console(state, char_id, "Account for #{target_name} banned: #{reason}")

      {:error, err} ->
        gm_console(state, char_id, "Ban failed: #{inspect(err)}")
    end

    {:noreply, state}
  end

  defp gm_unban_cuenta(state, char_id, target_name) do
    case GameBackend.Account.unban(target_name) do
      :ok -> gm_console(state, char_id, "Account for #{target_name} unbanned.")
      {:error, err} -> gm_console(state, char_id, "Unban failed: #{inspect(err)}")
    end

    {:noreply, state}
  end

  defp gm_ban_temporal(state, char_id, target_name, days_str, reason) do
    case Integer.parse(days_str) do
      {days, _} when days > 0 ->
        case GameBackend.Account.ban(target_name, "#{reason} (#{days} dias)") do
          :ok ->
            case AoSession.OnlineDirectory.lookup_by_name(target_name) do
              {:ok, session} -> send(session.pid, :disconnect)
              _ -> :ok
            end

            gm_console(state, char_id, "#{target_name} banned for #{days} days: #{reason}")

          {:error, err} ->
            gm_console(state, char_id, "Temp ban failed: #{inspect(err)}")
        end

      _ ->
        gm_console(state, char_id, "Invalid days value.")
    end

    {:noreply, state}
  end

  defp gm_remove_punishment(state, char_id, target_name, _num_str, _text) do
    gm_console(state, char_id, "Punishment removed from #{target_name}.")
    {:noreply, state}
  end

  defp gm_faction_message(state, char_id, faction, message) do
    faction_name =
      case faction do
        :royal_army -> "Armada Real"
        :chaos_legion -> "Legion Oscura"
      end

    raw =
      Encoder.encode(
        {:console_msg, %{message: "[#{faction_name}] #{message}", font_index: 0}}
      )

    # Broadcast to all players on this map who are in the faction
    Enum.each(state.players, fn {pid, entity} ->
      if entity.faction == faction do
        Helpers.send_to_session(state.sessions, pid, {:send_raw, raw})
      end
    end)

    gm_console(state, char_id, "Faction message sent to #{faction_name}.")
    {:noreply, state}
  end

  defp gm_talk_as_npc(state, char_id, entity, message) do
    # Find nearest NPC to the GM
    nearest_npc =
      state.npcs_live
      |> Enum.min_by(
        fn {_id, npc} -> abs(npc.x - entity.x) + abs(npc.y - entity.y) end,
        fn -> nil end
      )

    case nearest_npc do
      nil ->
        gm_console(state, char_id, "No NPCs nearby.")
        {:noreply, state}

      {_npc_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)
        npc_name = if npc_def, do: npc_def.name, else: "NPC"

        chat_raw =
          Encoder.encode(
            {:chat_over_head,
             %{
               message: message,
               char_index: npc.char_index,
               color: 0x0000FF00,
               x: npc.x,
               y: npc.y,
               min_display_time: 3000,
               max_display_time: 6000
             }}
          )

        Enum.each(state.sessions, fn {_id, pid} -> send(pid, {:send_raw, chat_raw}) end)
        gm_console(state, char_id, "#{npc_name} says: #{message}")
        {:noreply, state}
    end
  end

  # ---- Batch 5: Map & Environment GM helpers ----

  defp gm_toggle_weather(state, char_id, weather_type) do
    label = if weather_type == :snow, do: "Nieve", else: "Niebla"
    # Toggle the weather flag in map state
    current = Map.get(state, weather_type, false)
    new_val = !current
    state = Map.put(state, weather_type, new_val)
    status = if new_val, do: "activada", else: "desactivada"
    gm_console(state, char_id, "#{label} #{status} en este mapa.")
    {:noreply, state}
  end

  defp gm_change_map_flag(state, char_id, flag, value_str) do
    new_val = value_str == "1"
    state = Map.put(state, flag, new_val)
    status = if new_val, do: "activado", else: "desactivado"
    gm_console(state, char_id, "Map flag #{flag} #{status}.")
    {:noreply, state}
  end

  defp gm_tile_block_toggle(state, char_id, entity) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    blocked_tiles = Map.get(state, :gm_blocked_tiles, MapSet.new())

    {blocked_tiles, status} =
      if MapSet.member?(blocked_tiles, {fx, fy}) do
        {MapSet.delete(blocked_tiles, {fx, fy}), "unblocked"}
      else
        {MapSet.put(blocked_tiles, {fx, fy}), "blocked"}
      end

    state = Map.put(state, :gm_blocked_tiles, blocked_tiles)
    gm_console(state, char_id, "Tile (#{fx},#{fy}) #{status}.")
    {:noreply, state}
  end

  defp gm_set_trigger(state, char_id, entity, trigger_str) do
    case Integer.parse(trigger_str) do
      {trigger, _} ->
        {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

        triggers = Map.get(state, :triggers, %{})
        triggers = Map.put(triggers, {fx, fy}, trigger)
        state = Map.put(state, :triggers, triggers)

        gm_console(state, char_id, "Trigger #{trigger} set at (#{fx},#{fy}).")
        {:noreply, state}

      :error ->
        gm_console(state, char_id, "Invalid trigger value.")
        {:noreply, state}
    end
  end

  defp gm_ask_trigger(state, char_id, entity) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    triggers = Map.get(state, :triggers, %{})
    trigger = Map.get(triggers, {fx, fy}, 0)
    gm_console(state, char_id, "Trigger at (#{fx},#{fy}): #{trigger}")
    {:noreply, state}
  end

  # ---- Batch 6: Audio & Utility GM helpers ----

  defp gm_force_midi_map(state, char_id, midi_str, map_str) do
    with {midi, _} <- Integer.parse(midi_str),
         {_map_id, _} <- Integer.parse(map_str) do
      raw = Encoder.encode({:play_midi, %{midi: midi, loops: -1}})
      Enum.each(state.sessions, fn {_id, pid} -> send(pid, {:send_raw, raw}) end)
      gm_console(state, char_id, "MIDI #{midi} sent to map.")
    else
      _ -> gm_console(state, char_id, "Usage: /FORCEMIDIMAP midi map")
    end

    {:noreply, state}
  end

  defp gm_force_wave_map(state, char_id, wave_str, x_str, y_str, _map_str) do
    with {wave, _} <- Integer.parse(wave_str),
         {x, _} <- Integer.parse(x_str),
         {y, _} <- Integer.parse(y_str) do
      raw = Encoder.encode({:play_wave, %{wave: wave, x: x, y: y}})
      Enum.each(state.sessions, fn {_id, pid} -> send(pid, {:send_raw, raw}) end)
      gm_console(state, char_id, "Wave #{wave} sent to map at (#{x},#{y}).")
    else
      _ -> gm_console(state, char_id, "Usage: /FORCEWAVEMAP wave x y map")
    end

    {:noreply, state}
  end

  defp gm_items_in_floor(state, char_id) do
    items = Map.get(state, :ground_items, %{})
    count = map_size(items)
    gm_console(state, char_id, "Items on floor: #{count}")

    Enum.take(items, 20)
    |> Enum.each(fn {{x, y}, item} ->
      item_def = GameData.get_item(item.item_id)
      name = if item_def, do: item_def.name, else: "?"
      gm_console(state, char_id, "(#{x},#{y}): #{name} (#{item.item_id}) x#{item.amount}")
    end)

    {:noreply, state}
  end

  defp gm_destroy_items(state, char_id, entity) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    ground_items = Map.get(state, :ground_items, %{})
    ground_items = Map.delete(ground_items, {fx, fy})
    state = Map.put(state, :ground_items, ground_items)
    gm_console(state, char_id, "Items at (#{fx},#{fy}) destroyed.")
    {:noreply, state}
  end

  defp gm_destroy_all_area(state, char_id, entity) do
    ground_items = Map.get(state, :ground_items, %{})
    range = 10

    ground_items =
      Enum.reject(ground_items, fn {{x, y}, _item} ->
        abs(x - entity.x) <= range and abs(y - entity.y) <= range
      end)
      |> Map.new()

    state = Map.put(state, :ground_items, ground_items)
    gm_console(state, char_id, "All items in area destroyed.")
    {:noreply, state}
  end

  defp gm_clean_world(state, char_id) do
    state = Map.put(state, :ground_items, %{})
    gm_console(state, char_id, "All ground items on this map cleaned.")
    {:noreply, state}
  end

  defp gm_show_name(state, char_id, entity) do
    show = !Map.get(entity, :show_name, true)
    entity = Map.put(entity, :show_name, show)
    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}
    status = if show, do: "visible", else: "hidden"
    gm_console(state, char_id, "Name #{status}.")
    {:noreply, state}
  end

  defp gm_set_description(state, char_id, entity, desc) do
    entity = Map.put(entity, :description, desc)
    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}
    gm_console(state, char_id, "Description set to: #{desc}")
    {:noreply, state}
  end

  defp gm_set_speed(state, char_id, entity, speed_str) do
    case Float.parse(speed_str) do
      {speed, _} ->
        entity = Map.put(entity, :speed_mod, speed)
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}
        gm_console(state, char_id, "Speed set to #{speed}.")
        {:noreply, state}

      :error ->
        gm_console(state, char_id, "Invalid speed value.")
        {:noreply, state}
    end
  end

  defp gm_check_slot(state, char_id, target_name, slot_str) do
    case {find_player_by_name(state, target_name), Integer.parse(slot_str)} do
      {{:ok, _target_id, target}, {slot, _}} when slot >= 1 ->
        inventory = Map.get(target, :inventory, %{})

        case Map.get(inventory, slot) do
          nil ->
            gm_console(state, char_id, "#{target.name} slot #{slot}: (empty)")

          item ->
            item_def = GameData.get_item(item.item_id)
            name = if item_def, do: item_def.name, else: "?"
            gm_console(state, char_id, "#{target.name} slot #{slot}: #{name} (#{item.item_id}) x#{item.amount}")
        end

        {:noreply, state}

      {:not_found, _} ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}

      _ ->
        gm_console(state, char_id, "Invalid slot.")
        {:noreply, state}
    end
  end

  # ---- Batch 7: Faction/Council + SOS GM helpers ----

  defp gm_council_kick(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = Map.put(target, :council, false)
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        gm_console(state, char_id, "#{target_name} removed from council.")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  defp gm_accept_council(state, char_id, target_name, council_type) do
    case find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = Map.put(target, :council, council_type)
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        label = if council_type == :royal, do: "Royal", else: "Chaos"
        gm_console(state, char_id, "#{target_name} added to #{label} Council.")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  defp gm_faction_kick(state, char_id, target_name, faction) do
    case find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = %{target | faction: :none}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        label = if faction == :royal_army, do: "Armada Real", else: "Legion Oscura"
        gm_console(state, char_id, "#{target_name} expelled from #{label}.")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  # ---- Events / Invasions / Tournaments GM helpers ----

  defp gm_invasion(state, char_id, entity, map_str, npc_str, count_str) do
    with {map_id, ""} <- Integer.parse(map_str),
         {npc_id, ""} <- Integer.parse(npc_str),
         {count, ""} <- Integer.parse(count_str),
         true <- count > 0 and count <= 200 do
      case Arena.Events.InvasionServer.start_invasion(map_id, npc_id, count, entity.name) do
        {:ok, spawned} ->
          gm_console(state, char_id, "Invasion started: #{spawned} NPCs spawned on map #{map_id}.")

        {:error, :invasion_already_active} ->
          gm_console(state, char_id, "An invasion is already active on map #{map_id}.")

        {:error, :npc_not_found} ->
          gm_console(state, char_id, "NPC #{npc_id} not found.")

        {:error, :no_npcs_spawned} ->
          gm_console(state, char_id, "Could not spawn any NPCs (no walkable tiles found).")

        {:error, reason} ->
          gm_console(state, char_id, "Invasion failed: #{inspect(reason)}")
      end
    else
      _ -> gm_console(state, char_id, "Usage: /INVASION map_id npc_id count (max 200)")
    end

    {:noreply, state}
  end

  defp gm_invasion_stop(state, char_id, map_str) do
    case Integer.parse(map_str) do
      {map_id, ""} ->
        case Arena.Events.InvasionServer.stop_invasion(map_id) do
          :ok -> gm_console(state, char_id, "Invasion on map #{map_id} stopped.")
          {:error, :no_invasion} -> gm_console(state, char_id, "No active invasion on map #{map_id}.")
        end

      _ ->
        gm_console(state, char_id, "Usage: /INVASION STOP map_id")
    end

    {:noreply, state}
  end

  defp gm_invasion_list(state, char_id) do
    case Arena.Events.InvasionServer.list_invasions() do
      {:ok, invasions} when map_size(invasions) == 0 ->
        gm_console(state, char_id, "No active invasions.")

      {:ok, invasions} ->
        Enum.each(invasions, fn {map_id, inv} ->
          gm_console(state, char_id, "Map #{map_id}: NPC #{inv.npc_id}, #{inv.kills}/#{inv.total_count} killed")
        end)
    end

    {:noreply, state}
  end

  defp gm_tournament_start(state, char_id, entity, max_str) do
    max_players = case Integer.parse(max_str) do
      {n, _} when n > 1 -> n
      _ -> 16
    end

    case Arena.Events.TournamentServer.start_tournament(max_players, entity.name) do
      :ok -> gm_console(state, char_id, "Tournament started (max #{max_players} players).")
      {:error, :tournament_already_active} -> gm_console(state, char_id, "A tournament is already active.")
    end

    {:noreply, state}
  end

  defp gm_tournament_begin(state, char_id) do
    case Arena.Events.TournamentServer.begin_matches() do
      :ok -> gm_console(state, char_id, "Tournament matches started.")
      {:error, :not_enough_players} -> gm_console(state, char_id, "Not enough players to start.")
      {:error, reason} -> gm_console(state, char_id, "Error: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp gm_tournament_cancel(state, char_id) do
    case Arena.Events.TournamentServer.cancel() do
      :ok -> gm_console(state, char_id, "Tournament cancelled.")
      {:error, :no_tournament} -> gm_console(state, char_id, "No active tournament.")
    end

    {:noreply, state}
  end

  defp gm_tournament_status(state, char_id) do
    case Arena.Events.TournamentServer.get_state() do
      nil ->
        gm_console(state, char_id, "No active tournament.")

      t ->
        participants = length(t.participants)
        gm_console(state, char_id, "Tournament: phase=#{t.phase}, participants=#{participants}, round=#{t.current_round}")
    end

    {:noreply, state}
  end

  defp gm_event_start(state, char_id, entity, type_str, duration_str) do
    type = case String.downcase(type_str) do
      "xp_bonus" -> :xp_bonus
      "gold_bonus" -> :gold_bonus
      "drop_bonus" -> :drop_bonus
      _ -> :custom
    end

    case Integer.parse(duration_str) do
      {minutes, _} when minutes > 0 ->
        case Arena.Events.EventManager.start_event(type, minutes, entity.name) do
          :ok -> gm_console(state, char_id, "Event #{type} started for #{minutes} minutes.")
          {:error, :event_already_active} -> gm_console(state, char_id, "Event #{type} already active.")
        end

      _ ->
        gm_console(state, char_id, "Usage: /EVENT START type duration_minutes")
    end

    {:noreply, state}
  end

  defp gm_event_stop(state, char_id, type_str) do
    type = case String.downcase(type_str) do
      "xp_bonus" -> :xp_bonus
      "gold_bonus" -> :gold_bonus
      "drop_bonus" -> :drop_bonus
      _ -> :custom
    end

    case Arena.Events.EventManager.stop_event(type) do
      :ok -> gm_console(state, char_id, "Event #{type} stopped.")
      {:error, :no_such_event} -> gm_console(state, char_id, "No active event of type #{type}.")
    end

    {:noreply, state}
  end

  defp gm_event_list(state, char_id) do
    case Arena.Events.EventManager.list_events() do
      {:ok, []} ->
        gm_console(state, char_id, "No active events.")

      {:ok, events} ->
        Enum.each(events, fn ev ->
          mins = div(ev.remaining_seconds, 60)
          gm_console(state, char_id, "#{ev.type}: #{ev.description} (#{mins}m remaining, #{ev.participants} participants)")
        end)
    end

    {:noreply, state}
  end

  # Look up a player on this map by name (case-insensitive)
  defp find_player_by_name(state, name) do
    lower_name = String.downcase(name)

    Enum.find_value(state.players, :not_found, fn {id, entity} ->
      if String.downcase(entity.name) == lower_name do
        {:ok, id, entity}
      end
    end)
  end

  def handle_yell(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})}
          )

          {:noreply, state}
        else
          # VB6: yelling breaks invisibility
          entity = Helpers.break_invisibility(entity, state, char_id)
          players = Map.put(state.players, char_id, entity)

          yell_raw =
            Encoder.encode(
              {:chat_over_head,
               %{
                 message: message,
                 char_index: entity.char_index,
                 color: 0x00FF0000,
                 x: entity.x,
                 y: entity.y,
                 min_display_time: 3000,
                 max_display_time: 6000
               }}
            )

          Visibility.broadcast_range(
            %{state | players: players},
            entity.x,
            entity.y,
            @yell_range_x,
            @yell_range_y,
            fn pid ->
              send(pid, {:send_raw, yell_raw})
            end
          )

          {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_rest(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})}
            )

            {:noreply, state}

          entity.hp >= entity.max_hp ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas sano.", font_index: 0}})}
            )

            {:noreply, state}

          true ->
            new_resting = not entity.resting
            entity = %{entity | resting: new_resting, meditating: false}
            players = Map.put(state.players, char_id, entity)

            msg = if new_resting, do: "Has comenzado a descansar.", else: "Has dejado de descansar."

            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: msg, font_index: 0}})}
            )

            {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_meditate(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})}
            )

            {:noreply, state}

          entity.class not in @magical_classes ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "Solo las clases magicas pueden meditar.", font_index: 0}})}
            )

            {:noreply, state}

          entity.mana >= entity.max_mana ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Tienes el mana completo.", font_index: 0}})}
            )

            {:noreply, state}

          true ->
            new_meditating = not entity.meditating
            entity = %{entity | meditating: new_meditating, resting: false}
            players = Map.put(state.players, char_id, entity)

            msg = if new_meditating, do: "Has comenzado a meditar.", else: "Has dejado de meditar."

            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: msg, font_index: 0}})}
            )

            # VB6: show meditate FX (varies by level/faction; simplified to fx_id 4 here)
            if new_meditating do
              Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
                send(pid, {:send_raw, Encoder.encode({:create_fx, %{char_index: entity.char_index, fx: 4, loops: 0}})})
              end)
            end

            {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_heal(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})}
            )

            {:noreply, state}

          entity.hp >= entity.max_hp ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas sano.", font_index: 0}})}
            )

            {:noreply, state}

          true ->
            # VB6: heal is NPC interaction -- full heal from Revividor NPC.
            case find_nearby_npc_of_type(state, entity, [@npc_type_revividor, @npc_type_resucitador_newbie]) do
              {:ok, _npc, npc_def} ->
                # VB6: ResucitadorNewbie only serves newbies (level <= 12)
                if npc_def.npc_type == @npc_type_resucitador_newbie and entity.level > 12 do
                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw,
                     Encoder.encode(
                       {:console_msg, %{message: "Solo los newbies pueden ser curados aqui.", font_index: 0}}
                     )}
                  )

                  {:noreply, state}
                else
                  entity = %{entity | hp: entity.max_hp}
                  players = Map.put(state.players, char_id, entity)

                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido curado.", font_index: 0}})}
                  )

                  Helpers.send_to_session(
                    state.sessions,
                    char_id,
                    {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})}
                  )

                  {:noreply, %{state | players: players}}
                end

              :not_found ->
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un sacerdote cerca.", font_index: 0}})}
                )

                {:noreply, state}
            end
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_resucitate(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          # VB6: resurrection requires Revividor NPC nearby
          case find_nearby_npc_of_type(state, entity, [@npc_type_revividor, @npc_type_resucitador_newbie]) do
            {:ok, _npc, npc_def} ->
              # VB6: ResucitadorNewbie only serves newbies (level <= 12)
              if npc_def.npc_type == @npc_type_resucitador_newbie and entity.level > 12 do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw,
                   Encoder.encode(
                     {:console_msg, %{message: "Solo los newbies pueden ser resucitados aqui.", font_index: 0}}
                   )}
                )

                {:noreply, state}
              else
                entity = %{
                  entity
                  | dead: false,
                    hp: entity.max_hp,
                    mana: 0,
                    buffs: [],
                    paralyzed: false,
                    poisoned: false,
                    invisible: false
                }

                players = Map.put(state.players, char_id, entity)

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})}
                )

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:update_mana, %{min_mana: 0}})}
                )

                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido resucitado.", font_index: 0}})}
                )

                state = %{state | players: players}
                Helpers.broadcast_character_change(state, entity)

                Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
                  send(
                    pid,
                    {:send_raw, Encoder.encode({:create_fx, %{char_index: entity.char_index, fx: 15, loops: 0}})}
                  )
                end)

                {:noreply, state}
              end

            :not_found ->
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un sacerdote cerca.", font_index: 0}})}
              )

              {:noreply, state}
          end
        else
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "No estas muerto.", font_index: 0}})}
          )

          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Stat requests
  # ==================================================================

  def handle_request_atributes(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw,
           Encoder.encode(
             {:update_user_stats,
              %{
                max_hp: entity.max_hp,
                min_hp: entity.hp,
                shield: 0,
                max_mana: entity.max_mana,
                min_mana: entity.mana,
                max_sta: entity.max_stamina,
                min_sta: entity.stamina,
                gold: entity.gold,
                gold_cap: 1_000_000,
                level: entity.level,
                exp_next_level: GameData.exp_for_level(entity.level + 1) || 0,
                exp: entity.xp,
                class: Helpers.class_to_int(entity.class)
              }}
           )}
        )

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw,
           Encoder.encode(
             {:send_atributes,
              %{
                str: entity.str,
                agi: entity.agi,
                int: entity.int,
                con: entity.con,
                cha: entity.cha
              }}
           )}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_request_skills(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @skill_order [
    :magic,
    :stealing,
    :combat_tactics,
    :combat_weapons,
    :meditation,
    :short_weapons,
    :hiding,
    :survival,
    :trading,
    :combat_defense,
    :leadership,
    :ranged_weapons,
    :wrestling,
    :navigation,
    :riding,
    :resistance,
    :woodcutting,
    :fishing,
    :mining,
    :blacksmithing,
    :carpentry,
    :alchemy,
    :tailoring,
    :taming
  ]

  @crafting_skills [:woodcutting, :fishing, :mining, :blacksmithing, :carpentry, :alchemy, :tailoring, :taming]

  # -- Trainer skill groups (VB6 subtypes) --
  # Used when trainer_accepts_skill? is wired to enforce per-trainer restrictions.
  @combat_skills [
    :combat_tactics,
    :combat_weapons,
    :combat_defense,
    :short_weapons,
    :ranged_weapons,
    :wrestling,
    :resistance
  ]
  @magic_skills [:magic, :meditation]
  @trade_skills [
    :woodcutting,
    :fishing,
    :mining,
    :blacksmithing,
    :carpentry,
    :alchemy,
    :tailoring,
    :taming,
    :trading,
    :navigation,
    :survival,
    :riding,
    :leadership
  ]
  @stealth_skills [:stealing, :hiding]
  _ = {@combat_skills, @magic_skills, @trade_skills, @stealth_skills}

  @doc """
  Train a skill via a nearby Entrenador NPC, or attempt crafting work if no
  trainer is present.

  VB6 trainers have subtypes (combat, magic, trade, stealth) that restrict
  which skill groups they can teach. The skill groups are defined in the
  `@combat_skills`, `@magic_skills`, `@trade_skills`, and `@stealth_skills`
  module attributes above. VB6 trainers teach all skills; the creature
  list (CI1..CI5) is for the summoning feature, not skill gating.
  """
  def handle_train_skill(state, char_id, skill_index) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        skill_atom = Enum.at(@skill_order, skill_index)
        trainer_result = find_nearby_npc_of_type(state, entity, [@npc_type_entrenador])
        near_trainer = trainer_result != :not_found

        trainer_npc_def =
          case trainer_result do
            {:ok, _npc, npc_def} -> npc_def
            :not_found -> nil
          end

        cond do
          skill_atom == nil ->
            {:noreply, state}

          # Near trainer but this trainer does not teach the requested skill group
          near_trainer and not trainer_accepts_skill?(trainer_npc_def, skill_atom) ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "Este entrenador no enseña esa habilidad.", font_index: 0}})}
            )

            {:noreply, state}

          # Near trainer: train with skill points (all skills)
          near_trainer and entity.skill_points <= 0 ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "No tienes puntos de skill disponibles.", font_index: 0}})}
            )

            {:noreply, state}

          near_trainer and Map.get(entity.skills, skill_atom, 0) >= 100 ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "Ya tienes el maximo en esa habilidad.", font_index: 0}})}
            )

            {:noreply, state}

          near_trainer ->
            current = Map.get(entity.skills, skill_atom, 0)
            cost = max(current * 10, 10)

            if entity.gold < cost do
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode({:console_msg, %{message: "No tienes suficiente oro. Costo: #{cost}", font_index: 0}})}
              )

              {:noreply, state}
            else
              entity = %{
                entity
                | skills: Map.put(entity.skills, skill_atom, current + 1),
                  skill_points: entity.skill_points - 1,
                  gold: entity.gold - cost
              }

              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})}
              )

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
              )

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode(
                   {:console_msg,
                    %{
                      message: "Has entrenado! Costo: #{cost} oro. Skill points restantes: #{entity.skill_points}",
                      font_index: 0
                    }}
                 )}
              )

              {:noreply, state}
            end

          # Not near trainer, but crafting skill: attempt work
          skill_atom in @crafting_skills ->
            Crafting.handle_work(state, char_id, skill_atom)

          # Not near trainer, not a crafting skill
          true ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un entrenador cerca.", font_index: 0}})}
            )

            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # VB6: trainers teach ALL skills — ModifySkills has no NPC or skill-group check.
  # The trainer NPC's creature list (CI1..CI5) is for the creature summoning feature,
  # not for restricting which skills can be trained.
  defp trainer_accepts_skill?(_npc_def, _skill_atom), do: true

  def handle_request_mini_stats(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw,
           Encoder.encode(
             {:update_user_stats,
              %{
                max_hp: entity.max_hp,
                min_hp: entity.hp,
                shield: 0,
                max_mana: entity.max_mana,
                min_mana: entity.mana,
                max_sta: entity.max_stamina,
                min_sta: entity.stamina,
                gold: entity.gold,
                gold_cap: 1_000_000,
                level: entity.level,
                exp_next_level: GameData.exp_for_level(entity.level + 1) || 0,
                exp: entity.xp,
                class: Helpers.class_to_int(entity.class)
              }}
           )}
        )

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw,
           Encoder.encode(
             {:mini_stats,
              %{
                ciudadanos_matados: entity.citizens_killed,
                criminales_matados: entity.criminals_killed,
                faction_status:
                  case Map.get(entity, :faction, :none) do
                    :royal_army -> 1
                    :chaos_legion -> 2
                    :none -> if entity.criminal, do: 3, else: 0
                  end,
                npcs_killed: entity.npcs_killed,
                class: Helpers.class_to_int(entity.class),
                penalty: entity.penalty,
                deaths: entity.deaths,
                gender: if(entity.gender == :male, do: 1, else: 2),
                fishing_points: entity.fishing_points,
                race: Helpers.race_to_int(entity.race)
              }}
           )}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Double-click / NPC interaction
  # ==================================================================

  def handle_double_click(state, char_id, x, y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          {:noreply, state}
        else
          # VB6 uses distance <= 4 for most NPC interactions
          if abs(entity.x - x) <= 4 and abs(entity.y - y) <= 4 do
            case Helpers.get_occupancy(state.occupancy, x, y) do
              {:npc, instance_id} ->
                handle_npc_double_click(state, char_id, entity, instance_id)

              _ ->
                # Check for forum object on ground
                case Map.get(state.ground_items, {x, y}) do
                  %{item_id: item_id} ->
                    item_def = GameData.get_item(item_id)

                    if item_def != nil and item_def.forum_id > 0 do
                      handle_forum_open(state, char_id, item_def.forum_id)
                    else
                      {:noreply, state}
                    end

                  _ ->
                    {:noreply, state}
                end
            end
          else
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas demasiado lejos.", font_index: 0}})}
            )

            {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_npc_double_click(state, char_id, entity, instance_id) do
    case Map.get(state.npcs_live, instance_id) do
      nil ->
        {:noreply, state}

      npc ->
        npc_def = GameData.get_npc(npc.npc_id)

        cond do
          npc_def == nil ->
            {:noreply, state}

          # Shopkeeper -- open commerce
          npc_def.comercia ->
            GenServer.cast(self(), {:open_commerce_internal, char_id, entity.x, entity.y, npc, npc_def})
            {:noreply, state}

          # Revividor / ResucitadorNewbie -- show healer prompt
          npc_def.npc_type in [@npc_type_revividor, @npc_type_resucitador_newbie] ->
            if entity.dead do
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode(
                   {:console_msg,
                    %{message: "#{npc_def.name} dice: Puedo resucitarte. Usa el comando /resucitar.", font_index: 0}}
                 )}
              )
            else
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode(
                   {:console_msg,
                    %{message: "#{npc_def.name} dice: Puedo curarte. Usa el comando /curar.", font_index: 0}}
                 )}
              )
            end

            {:noreply, state}

          # Enlistador — faction NPC
          npc_def.npc_type == @npc_type_enlistador ->
            handle_enlistador_click(state, char_id, entity, npc_def)

          # Banker — open bank UI (VB6: NPC double-click on banker opens bóveda)
          npc_def.npc_type == @npc_type_banquero ->
            # Pass NPC position so Bank module can resolve the banker via occupancy
            case Arena.Map.Bank.handle_open_bank(state, char_id, npc.x, npc.y) do
              {:reply, _result, new_state} -> {:noreply, new_state}
              _ -> {:noreply, state}
            end

          # Trainer
          npc_def.npc_type == @npc_type_entrenador ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode(
                 {:console_msg,
                  %{message: "#{npc_def.name} dice: Puedo entrenarte. Usa el boton Entrenar.", font_index: 0}}
               )}
            )

            {:noreply, state}

          # EntregaPesca — fish delivery NPC
          npc_def.npc_type == @npc_type_entrega_pesca ->
            handle_fish_delivery(state, char_id, entity, npc_def)

          # Timbero — gambling NPC (VB6: npc_type 6)
          npc_def.npc_type == @npc_type_timbero ->
            msg(state, char_id, "#{npc_def.name} dice: Haz tu apuesta con /APOSTAR cantidad (1-5000 monedas).")
            {:noreply, state}

          # Arena guard (VB6: npc_type 10)
          npc_def.npc_type == @npc_type_arena_guard ->
            fee = Map.get(npc_def, :arena_price, 0)

            if fee > 0 do
              msg(state, char_id, "#{npc_def.name} dice: La entrada a la arena cuesta #{fee} monedas de oro.")
            else
              msg(state, char_id, "#{npc_def.name} dice: Bienvenido a la arena.")
            end

            {:noreply, state}

          # Subastador — auction NPC (VB6: npc_type 16)
          npc_def.npc_type == @npc_type_subastador ->
            handle_subastador_click(state, char_id, entity, npc_def)

          # Default: show NPC name
          true ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Ves a #{npc_def.name}.", font_index: 0}})}
            )

            {:noreply, state}
        end
    end
  end

  # ==================================================================
  # Faction system (VB6: ModFacciones)
  # ==================================================================

  # NPC faccion values: 3 = Armada, 2 = Caos (from npcs.dat)
  defp npc_faccion_to_atom(3), do: :royal_army
  defp npc_faccion_to_atom(2), do: :chaos_legion
  defp npc_faccion_to_atom(_), do: :none

  defp handle_enlistador_click(state, char_id, entity, npc_def) do
    npc_faction = npc_faccion_to_atom(npc_def.faccion)

    cond do
      entity.dead ->
        msg(state, char_id, "Estas muerto!")
        {:noreply, state}

      npc_faction == :none ->
        msg(state, char_id, "#{npc_def.name} no puede enlistarte.")
        {:noreply, state}

      # Already in this faction — offer rank advancement
      entity.faction == npc_faction ->
        handle_faction_rank_up(state, char_id, entity, npc_faction)

      # In opposing faction — must leave first
      entity.faction != :none ->
        msg(state, char_id, "Ya perteneces a una faccion. Usa /RENUNCIAR primero.")
        {:noreply, state}

      # Royal Army blocks criminals and citizen killers
      npc_faction == :royal_army and entity.criminal ->
        msg(state, char_id, "Los criminales no pueden enlistarse en la Armada Real.")
        {:noreply, state}

      npc_faction == :royal_army and entity.citizens_killed > 0 ->
        msg(state, char_id, "Has asesinado ciudadanos inocentes. No puedes enlistarte en la Armada Real.")
        {:noreply, state}

      # Thieves cannot join Royal Army
      npc_faction == :royal_army and entity.class in [:thief, :bandit, :assassin, :pirate] ->
        msg(state, char_id, "Tu clase no puede enlistarse en la Armada Real.")
        {:noreply, state}

      true ->
        # Check rank 1 requirements
        ranks = GameData.faction_ranks(npc_faction)
        rank1 = List.first(ranks)

        cond do
          rank1 != nil and entity.level < rank1.required_level ->
            msg(state, char_id, "Necesitas nivel #{rank1.required_level} para enlistarte.")
            {:noreply, state}

          true ->
            entity = %{entity | faction: npc_faction}
            # Assign first rank
            entity = assign_rank(entity, npc_faction, 1)
            # Give rank 1 rewards
            {entity, state} = give_faction_rewards(entity, state, char_id, npc_faction, 0, 1)
            players = Map.put(state.players, char_id, entity)

            # Update online directory with new faction
            AoSession.OnlineDirectory.update_faction(char_id, npc_faction)

            faction_name = faction_display_name(npc_faction)
            msg(%{state | players: players}, char_id, "Te has enlistado en #{faction_name}.")
            {:noreply, %{state | players: players}}
        end
    end
  end

  defp handle_faction_rank_up(state, char_id, entity, faction) do
    current_rank = current_faction_rank(entity, faction)
    ranks = GameData.faction_ranks(faction)
    next_rank_def = Enum.find(ranks, fn r -> r.rank == current_rank + 1 end)

    cond do
      next_rank_def == nil ->
        msg(state, char_id, "Ya tienes el rango maximo.")
        {:noreply, state}

      entity.level < next_rank_def.required_level ->
        needed = next_rank_def.required_level - entity.level
        msg(state, char_id, "Te faltan #{needed} niveles para poder recibir la proxima recompensa.")
        {:noreply, state}

      entity.faction_score < next_rank_def.required_score ->
        needed = next_rank_def.required_score - entity.faction_score
        msg(state, char_id, "Te faltan #{needed} puntos de faccion para subir de rango.")
        {:noreply, state}

      true ->
        new_rank = next_rank_def.rank
        entity = assign_rank(entity, faction, new_rank)
        {entity, state} = give_faction_rewards(entity, state, char_id, faction, current_rank, new_rank)
        players = Map.put(state.players, char_id, entity)

        msg(%{state | players: players}, char_id, "Has ascendido al rango #{new_rank}: #{next_rank_def.title}!")
        {:noreply, %{state | players: players}}
    end
  end

  defp current_faction_rank(entity, :royal_army), do: entity.faction_rank_armada
  defp current_faction_rank(entity, :chaos_legion), do: entity.faction_rank_chaos

  defp assign_rank(entity, :royal_army, rank), do: %{entity | faction_rank_armada: rank}
  defp assign_rank(entity, :chaos_legion, rank), do: %{entity | faction_rank_chaos: rank}

  defp give_faction_rewards(entity, state, char_id, faction, old_rank, new_rank) do
    rewards = GameData.faction_rewards(faction)

    rewards_to_give =
      Enum.filter(rewards, fn r -> r.rank > old_rank and r.rank <= new_rank end)

    Enum.reduce(rewards_to_give, {entity, state}, fn reward, {ent, st} ->
      item_def = GameData.get_item(reward.obj_index)

      if item_def == nil do
        {ent, st}
      else
        case Arena.Inventory.add_item(ent.inventory, reward.obj_index, 1) do
          {:ok, new_inv, slot} ->
            ent = %{ent | inventory: new_inv}
            Helpers.send_inventory_slot(st.sessions, char_id, new_inv, slot)
            msg(st, char_id, "Has recibido #{item_def.name}.")
            {ent, st}

          _ ->
            msg(st, char_id, "No tienes espacio para #{item_def.name}.")
            {ent, st}
        end
      end
    end)
  end

  def handle_enlist_faction(state, char_id, faction) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        # Require nearby Enlistador NPC of the correct faction
        case find_nearby_enlistador(state, entity, faction) do
          {:ok, _npc, npc_def} ->
            handle_enlistador_click(state, char_id, entity, npc_def)

          :not_found ->
            msg(state, char_id, "Necesitas estar cerca de un enlistador para enlistarte.")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp find_nearby_enlistador(state, entity, faction) do
    expected_faccion =
      case faction do
        :royal_army -> 3
        :chaos_legion -> 2
      end

    result =
      Enum.find_value(state.npcs_live, fn {_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)

        if npc_def != nil and
             npc_def.npc_type == @npc_type_enlistador and
             npc_def.faccion == expected_faccion and
             abs(npc.x - entity.x) <= 5 and
             abs(npc.y - entity.y) <= 5 do
          {npc, npc_def}
        end
      end)

    case result do
      {npc, npc_def} -> {:ok, npc, npc_def}
      nil -> :not_found
    end
  end

  def handle_leave_faction(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.faction == :none do
          msg(state, char_id, "No perteneces a ninguna faccion.")
          {:noreply, state}
        else
          # VB6: strip faction items from inventory
          entity = strip_faction_items(entity)
          entity = %{entity | faction: :none, faction_reenlistadas: entity.faction_reenlistadas + 1}
          players = Map.put(state.players, char_id, entity)

          # Update online directory
          AoSession.OnlineDirectory.update_faction(char_id, :none)

          # Resend full inventory after stripping
          Enum.each(0..23, fn slot ->
            Helpers.send_inventory_slot(state.sessions, char_id, entity.inventory, slot)
          end)

          # Broadcast visual change if armor was stripped (body_id reverted)
          state = %{state | players: players}
          Helpers.broadcast_character_change(state, entity)

          msg(state, char_id, "Has renunciado a tu faccion.")
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp strip_faction_items(entity) do
    # VB6: unequip items with Real=1 or Caos=1 flag when leaving a faction.
    # Clears equipped flag, equipment slot, and restores body_id if armor.
    alias Arena.Data.GameData

    Enum.reduce(0..(length(entity.inventory) - 1), entity, fn slot_idx, ent ->
      case Enum.at(ent.inventory, slot_idx) do
        %{item_id: item_id, equipped: true} when item_id > 0 ->
          case GameData.get_item(item_id) do
            nil ->
              ent

            item_def ->
              if item_def.real or item_def.caos do
                inv = List.update_at(ent.inventory, slot_idx, &%{&1 | equipped: false})
                ent = %{ent | inventory: inv}

                # Clear equipment slot
                ent =
                  if item_def.equip_slot do
                    equipment = Map.put(ent.equipment, item_def.equip_slot, nil)
                    %{ent | equipment: equipment}
                  else
                    ent
                  end

                # Restore base body_id if it was armor
                if item_def.equip_slot == :armor do
                  %{ent | body_id: ent.base_body_id}
                else
                  ent
                end
              else
                ent
              end
          end

        _ ->
          ent
      end
    end)
  end

  @doc """
  Calculate faction score for a PvP kill. VB6: HandleFactionScoreForKill.

  Returns the score delta (can be 0 if same alignment or no faction relevance).
  """
  def faction_score_for_kill(attacker, defender) do
    att_faction = attacker.faction
    def_faction = defender.faction

    cond do
      # Same faction — fratricide penalty (no score)
      att_faction != :none and att_faction == def_faction ->
        0

      # Cross-faction kills earn score
      att_faction != :none and def_faction != :none and att_faction != def_faction ->
        base = faction_score_base(attacker.level, defender.level)
        # 1.5x bonus for opposing faction kills
        min(trunc(base * 1.5), 20)

      # Faction member kills criminal
      att_faction == :royal_army and defender.criminal ->
        min(faction_score_base(attacker.level, defender.level), 20)

      # Criminal/chaos kills citizen
      (att_faction == :chaos_legion or attacker.criminal) and
        def_faction == :none and not defender.criminal ->
        min(faction_score_base(attacker.level, defender.level), 20)

      true ->
        0
    end
  end

  defp faction_score_base(att_level, def_level) do
    if att_level < def_level do
      10 + def_level - max(att_level, 0)
    else
      max(10 - (att_level - def_level), 0)
    end
  end

  def handle_faction_chat(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.faction == :none do
          msg(state, char_id, "No perteneces a ninguna faccion.")
          {:noreply, state}
        else
          # VB6: uses eConsoleFactionMessage (ID 38) with faction label key
          {faction_label, font_index} = faction_chat_style(entity.faction)
          chat_msg = "#{entity.name}: #{message}"

          raw =
            Encoder.encode(
              {:console_faction_message,
               %{
                 message: chat_msg,
                 font_index: font_index,
                 faction_label: faction_label
               }}
            )

          for {_cid, other} <- state.players, other.faction == entity.faction do
            Helpers.send_to_session(state.sessions, other.char_id, {:send_raw, raw})
          end

          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp faction_chat_style(:royal_army), do: {"MENSAJE_ARMADA", 0}
  defp faction_chat_style(:chaos_legion), do: {"MENSAJE_LEGION", 0}
  defp faction_chat_style(_), do: {"", 0}

  defp faction_display_name(:royal_army), do: "Armada Real"
  defp faction_display_name(:chaos_legion), do: "Legion del Caos"
  defp faction_display_name(_), do: "Ninguna"

  defp msg(state, char_id, message) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:console_msg, %{message: message, font_index: 0}})}
    )
  end

  def find_nearby_npc_of_type(state, entity, npc_types) do
    result =
      Enum.find_value(state.npcs_live, fn {_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)

        if npc_def != nil and
             npc_def.npc_type in npc_types and
             abs(npc.x - entity.x) <= 5 and
             abs(npc.y - entity.y) <= 5 do
          {npc, npc_def}
        end
      end)

    case result do
      {npc, npc_def} -> {:ok, npc, npc_def}
      nil -> :not_found
    end
  end

  # ==================================================================
  # Fish delivery (VB6: EntregaPesca NPC type 20)
  # ==================================================================

  defp handle_fish_delivery(state, char_id, entity, npc_def) do
    # VB6: only Trabajador (worker) class can deliver fish
    if entity.class != :trabajador do
      msg(state, char_id, "#{npc_def.name} dice: Solo los trabajadores pueden entregar peces.")
      {:noreply, state}
    else
      # Scan inventory for items with puntos_pesca > 0
      {total_points, total_gold, slots_to_clear} =
        entity.inventory
        |> Enum.with_index()
        |> Enum.reduce({0, 0, []}, fn {item, idx}, {pts, gold, slots} ->
          case item do
            %{item_id: item_id, amount: amount} when amount > 0 ->
              item_def = GameData.get_item(item_id)

              if item_def != nil and item_def.puntos_pesca > 0 do
                {pts + item_def.puntos_pesca * amount, gold + item_def.valor * amount, [idx | slots]}
              else
                {pts, gold, slots}
              end

            _ ->
              {pts, gold, slots}
          end
        end)

      if total_points == 0 do
        msg(state, char_id, "#{npc_def.name} dice: No tienes peces especiales para entregar.")
        {:noreply, state}
      else
        # Remove fish from inventory
        new_inv =
          Enum.reduce(slots_to_clear, entity.inventory, fn idx, inv ->
            List.replace_at(inv, idx, nil)
          end)

        entity = %{
          entity
          | inventory: new_inv,
            fishing_points: entity.fishing_points + total_points,
            gold: entity.gold + total_gold
        }

        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        # Send inventory updates for cleared slots
        Enum.each(slots_to_clear, fn slot ->
          Helpers.send_inventory_slot(state.sessions, char_id, entity.inventory, slot)
        end)

        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
        )

        msg(state, char_id, "Has entregado peces. Puntos: +#{total_points}, Oro: +#{total_gold}.")
        {:noreply, state}
      end
    end
  end

  # ==================================================================
  # Subastador -- Auction NPC (VB6: npc_type 16)
  # ==================================================================

  defp handle_subastador_click(state, char_id, entity, npc_def) do
    # VB6: The player must drop an item at their feet, then click the NPC.
    # The item on the ground at the player's position is picked up for auction.
    tile_key = {entity.x, entity.y}
    item_on_ground = Map.get(state.ground_items || %{}, tile_key)

    case Arena.Auction.initiate(char_id, item_on_ground) do
      :ok ->
        # Remove item from ground if present
        new_ground = Map.delete(state.ground_items || %{}, tile_key)
        state = %{state | ground_items: new_ground}

        # Notify clients the object was picked up
        Helpers.broadcast_object_delete(state, entity.x, entity.y)

        msg(
          state,
          char_id,
          "#{npc_def.name} dice: Escribe /OFERTAINICIAL (cantidad) para comenzar la subasta. Tienes 15 segundos!"
        )

        {:noreply, state}

      {:error, :auction_in_progress} ->
        msg(
          state,
          char_id,
          "#{npc_def.name} dice: Oye amigo, espera tu turno, estoy subastando en este momento."
        )

        {:noreply, state}

      {:error, :already_initiating} ->
        msg(
          state,
          char_id,
          "#{npc_def.name} dice: Ya estas preparando una subasta. Escribe /OFERTAINICIAL (cantidad)."
        )

        {:noreply, state}

      {:error, :no_item} ->
        msg(
          state,
          char_id,
          "#{npc_def.name} dice: Pues acaso el aire esta en venta ahora? Bribon!"
        )

        {:noreply, state}
    end
  end

  # ==================================================================
  # Pet commands (VB6: /QUIETO, /ACOMPAÑAR, /LIBERAR)
  # ==================================================================

  def handle_pet_stand(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          state = set_pet_mode(state, char_id, :stand)
          msg(state, char_id, "Tus mascotas se quedan quietas.")
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_pet_follow(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          state = set_pet_mode(state, char_id, :follow)
          msg(state, char_id, "Tus mascotas te siguen.")
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_pet_leave(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          case entity.pet_ids do
            [first_pet | rest_pets] ->
              case Map.get(state.npcs_live, first_pet) do
                nil ->
                  entity = %{entity | pet_ids: rest_pets}
                  state = %{state | players: Map.put(state.players, char_id, entity)}
                  {:noreply, state}

                npc ->
                  state = Arena.NpcAi.despawn_pet(state, first_pet, npc)
                  entity = %{entity | pet_ids: rest_pets}
                  state = %{state | players: Map.put(state.players, char_id, entity)}
                  msg(state, char_id, "Has liberado una mascota.")
                  {:noreply, state}
              end

            _ ->
              msg(state, char_id, "No tienes mascotas.")
              {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_pet_leave_all(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          state =
            Enum.reduce(entity.pet_ids || [], state, fn instance_id, st ->
              case Map.get(st.npcs_live, instance_id) do
                nil -> st
                npc -> Arena.NpcAi.despawn_pet(st, instance_id, npc)
              end
            end)

          entity = %{entity | pet_ids: []}
          state = %{state | players: Map.put(state.players, char_id, entity)}
          msg(state, char_id, "Has liberado todas tus mascotas.")
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # Set pet behavior mode — :stand stops movement/attack, :follow resumes normal AI
  defp set_pet_mode(state, char_id, mode) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        npcs_live =
          Enum.reduce(entity.pet_ids || [], state.npcs_live, fn instance_id, npcs ->
            case Map.get(npcs, instance_id) do
              nil -> npcs
              npc -> Map.put(npcs, instance_id, %{npc | pet_mode: mode})
            end
          end)

        %{state | npcs_live: npcs_live}

      :error ->
        state
    end
  end

  # ==================================================================
  # Move spell (VB6: reorder spell slots)
  # ==================================================================

  def handle_move_spell(state, char_id, upwards, slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        spells = entity.spells || []
        # Convert 1-based slot to 0-based index
        idx = slot - 1
        swap_idx = if upwards, do: idx - 1, else: idx + 1

        if idx >= 0 and idx < length(spells) and swap_idx >= 0 and swap_idx < length(spells) do
          a = Enum.at(spells, idx)
          b = Enum.at(spells, swap_idx)
          spells = spells |> List.replace_at(idx, b) |> List.replace_at(swap_idx, a)
          entity = %{entity | spells: spells}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          # Send updated spell slots to client
          send_spell_slot(state.sessions, char_id, spells, idx)
          send_spell_slot(state.sessions, char_id, spells, swap_idx)
          {:noreply, state}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp send_spell_slot(sessions, char_id, spells, idx) do
    spell_id = Enum.at(spells, idx) || 0
    packet = Encoder.encode({:change_spell_slot, %{slot: idx + 1, spell_id: spell_id}})
    Helpers.send_to_session(sessions, char_id, {:send_raw, packet})
  end

  # ==================================================================
  # Modify skills (VB6: distribute skill points from stats screen)
  # ==================================================================

  @skill_order [
    :magic,
    :stealing,
    :combat_tactics,
    :combat_weapons,
    :meditation,
    :short_weapons,
    :hiding,
    :survival,
    :trading,
    :combat_defense,
    :leadership,
    :ranged_weapons,
    :wrestling,
    :navigation,
    :riding,
    :resistance,
    :woodcutting,
    :fishing,
    :mining,
    :blacksmithing,
    :carpentry,
    :alchemy,
    :tailoring,
    :taming
  ]

  def handle_modify_skills(state, char_id, points_list) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          msg(state, char_id, "Estas muerto!")
          {:noreply, state}
        else
          # Sum requested points — must not exceed available skill_points
          total_requested = Enum.sum(points_list)

          if total_requested <= 0 or total_requested > entity.skill_points do
            msg(state, char_id, "No tienes suficientes puntos de habilidad.")
            {:noreply, state}
          else
            # Apply points to skills, capping each at 100
            {new_skills, points_used} =
              @skill_order
              |> Enum.zip(points_list)
              |> Enum.reduce({entity.skills, 0}, fn {skill_atom, pts}, {skills, used} ->
                if pts > 0 do
                  current = Map.get(skills, skill_atom, 0)
                  add = min(pts, 100 - current)

                  if add > 0 do
                    {Map.put(skills, skill_atom, current + add), used + add}
                  else
                    {skills, used}
                  end
                else
                  {skills, used}
                end
              end)

            entity = %{entity | skills: new_skills, skill_points: entity.skill_points - points_used}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            # Send updated skills back
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})}
            )

            {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Change description
  # ==================================================================

  @max_description_length 200

  def handle_change_description(state, char_id, desc) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        desc = String.slice(desc, 0, @max_description_length)
        entity = %{entity | description: desc}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}
        msg(state, char_id, "Descripcion cambiada.")
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Spell info (VB6: show spell details for a slot)
  # ==================================================================

  def handle_spell_info(state, char_id, slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        idx = slot - 1
        spell_id = Enum.at(entity.spells || [], idx)

        if spell_id && spell_id > 0 do
          case GameData.get_spell(spell_id) do
            nil ->
              msg(state, char_id, "Hechizo no encontrado.")

            spell_def ->
              info = "#{spell_def.name} - Mana: #{spell_def.mana_required}"

              info =
                if spell_def.min_hp && spell_def.min_hp > 0,
                  do: info <> " - Daño: #{spell_def.min_hp}-#{spell_def.max_hp}",
                  else: info

              msg(state, char_id, info)
          end
        else
          msg(state, char_id, "No hay hechizo en ese slot.")
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Move item (swap inventory slots)
  # ==================================================================

  def handle_move_item(state, char_id, from_slot, to_slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        inv = entity.inventory || []
        from_idx = from_slot - 1
        to_idx = to_slot - 1

        if from_idx >= 0 and from_idx < length(inv) and to_idx >= 0 and to_idx < length(inv) do
          a = Enum.at(inv, from_idx)
          b = Enum.at(inv, to_idx)
          inv = inv |> List.replace_at(from_idx, b) |> List.replace_at(to_idx, a)
          entity = %{entity | inventory: inv}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          # Send updated slots
          Helpers.send_inventory_slot(state.sessions, char_id, inv, from_idx)
          Helpers.send_inventory_slot(state.sessions, char_id, inv, to_idx)
          {:noreply, state}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Modify gold (add or subtract)
  # ==================================================================

  def handle_modify_gold(state, char_id, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        new_gold = max(entity.gold + amount, 0)
        entity = %{entity | gold: new_gold}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:update_gold, %{gold: new_gold}})})
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Marriage system (VB6: HandleCasamiento)
  # ==================================================================

  @doc """
  Handle a marriage proposal.

  VB6 flow (Protocol.bas HandleCasamiento):
  1. Target must be online (on same map)
  2. Proposer must have clicked a priest NPC (Revividor, type 1)
  3. Priest must be within 10 tiles
  4. Cannot marry yourself
  5. Proposer must not already be married
  6. Target must not already be married
  7. If target already proposed to proposer (mutual), marry them
  8. Otherwise, set proposer's candidato = target, notify target
  """
  def handle_propose_marriage(state, char_id, target_char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case Map.fetch(state.players, target_char_id) do
          {:ok, target_entity} ->
            do_propose_marriage(state, char_id, entity, target_char_id, target_entity)

          :error ->
            msg(state, char_id, "El jugador no se encuentra en este mapa.")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp do_propose_marriage(state, char_id, entity, target_char_id, target_entity) do
    priest_result = find_nearby_npc_of_type(state, entity, [@npc_type_revividor])

    cond do
      # Must be near a priest
      priest_result == :not_found ->
        msg(state, char_id, "Primero haz click sobre un sacerdote.")
        {:noreply, state}

      # Priest too far (find_nearby_npc_of_type already checks distance <= 5)
      # If we got here, priest is nearby. Check other conditions.

      # Cannot marry yourself
      char_id == target_char_id ->
        msg(state, char_id, "No puedes casarte contigo mismo.")
        {:noreply, state}

      # Proposer already married
      entity.spouse_id != 0 and entity.spouse_id != nil ->
        msg(state, char_id, "Ya estas casado! Debes divorciarte de tu actual pareja para casarte nuevamente.")
        {:noreply, state}

      # Target already married
      target_entity.spouse_id != 0 and target_entity.spouse_id != nil ->
        msg(state, char_id, "Tu pareja debe divorciarse antes de tomar tu mano en matrimonio.")
        {:noreply, state}

      # Mutual proposal: target already proposed to us -> marry!
      target_entity.marriage_proposal_target == char_id ->
        {:ok, _npc, _npc_def} = priest_result

        # Set both as married
        entity = %{entity | spouse_id: target_entity.char_id, marriage_proposal_target: nil}
        target_entity = %{target_entity | spouse_id: entity.char_id, marriage_proposal_target: nil}

        players =
          state.players
          |> Map.put(char_id, entity)
          |> Map.put(target_char_id, target_entity)

        state = %{state | players: players}

        # Broadcast marriage announcement (VB6: SendData ToAll)
        announce = "El sacerdote celebra el casamiento entre #{entity.name} y #{target_entity.name}."

        Enum.each(state.sessions, fn {_cid, session_pid} ->
          send(session_pid, {:send_packet, {:console_msg, %{message: announce, font_index: 0}}})
        end)

        # Congratulations to both (VB6: Msg1414/1415)
        congrats = "Los declaro unidos en legal matrimonio. Felicidades!"
        msg(state, char_id, congrats)
        msg(state, target_char_id, congrats)

        {:noreply, state}

      # First proposal: set candidato, notify target
      true ->
        entity = %{entity | marriage_proposal_target: target_char_id}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        msg(state, char_id, "La solicitud de casamiento ha sido enviada a #{target_entity.name}.")

        # VB6: Msg1956
        msg(
          state,
          target_char_id,
          "#{entity.name} desea casarse contigo, para permitirlo haz click en el sacerdote y escribe /PROPONER #{entity.name}."
        )

        {:noreply, state}
    end
  end

  @doc """
  Handle divorce.

  VB6 uses a special potion, but we also support a /DIVORCIAR command.
  Both players must be on the same map. Sets spouse_id = 0 on both.
  """
  # ==================================================================
  # Ocultarse (hiding skill) — task 26b
  # ==================================================================

  def handle_ocultarse(state, char_id, skill_level) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            msg(state, char_id, "Estas muerto!")
            {:noreply, state}

          entity.oculto ->
            msg(state, char_id, "Ya estas oculto.")
            {:noreply, state}

          skill_level < 1 ->
            msg(state, char_id, "No tienes habilidad suficiente para ocultarte.")
            {:noreply, state}

          true ->
            # VB6: hide timer = skill_level / 2 regen ticks
            timer = max(div(skill_level, 2), 1)
            entity = %{entity | oculto: true, oculto_timer: timer}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            Helpers.broadcast_character_change(state, %{entity | invisible: true})
            msg(state, char_id, "Te has ocultado entre las sombras.")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Trainer creature list — task 32
  # ==================================================================

  def handle_train_list(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        # Find nearby trainer NPC
        trainer =
          Enum.find_value(state.npcs_live, fn {_id, npc} ->
            npc_def = GameData.get_npc(npc.npc_id)

            if npc_def != nil and
                 npc_def.npc_type == @npc_type_entrenador and
                 abs(npc.x - entity.x) <= 5 and
                 abs(npc.y - entity.y) <= 5 do
              npc_def
            end
          end)

        if trainer != nil and trainer.creatures != [] do
          raw =
            Encoder.encode({:trainer_creature_list, %{creature_names: trainer.creatures}})

          Helpers.send_to_session(state.sessions, char_id, {:send_raw, raw})
        else
          msg(state, char_id, "No hay criaturas disponibles para entrenar.")
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Gamble (timbero NPC) — task 42
  # ==================================================================

  def handle_gamble(state, char_id, amount, _npc_instance_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            msg(state, char_id, "Estas muerto!")
            {:noreply, state}

          amount <= 0 ->
            msg(state, char_id, "La apuesta debe ser mayor a 0.")
            {:noreply, state}

          entity.gold < amount ->
            msg(state, char_id, "No tienes suficiente oro.")
            {:noreply, state}

          true ->
            # 50/50 chance
            won = :rand.uniform(2) == 1

            entity =
              if won do
                %{entity |
                  gold: entity.gold + amount,
                  gamble_wins: entity.gamble_wins + 1,
                  gamble_plays: entity.gamble_plays + 1}
              else
                %{entity |
                  gold: entity.gold - amount,
                  gamble_losses: entity.gamble_losses + 1,
                  gamble_plays: entity.gamble_plays + 1}
              end

            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
            )

            if won do
              msg(state, char_id, "Has ganado #{amount} monedas de oro!")
            else
              msg(state, char_id, "Has perdido #{amount} monedas de oro.")
            end

            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Forgive (priest NPC) — task 42
  # ==================================================================

  def handle_forgive(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.criminal do
          entity = %{entity | criminal: false}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}
          msg(state, char_id, "Has sido perdonado.")
          {:noreply, state}
        else
          msg(state, char_id, "No eres un criminal.")
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Arena entry — task 42
  # ==================================================================

  def handle_arena_entry(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        # Find nearby arena guard NPC
        guard =
          Enum.find_value(state.npcs_live, fn {_id, npc} ->
            npc_def = GameData.get_npc(npc.npc_id)

            if npc_def != nil and
                 npc_def.npc_type == @npc_type_arena_guard and
                 npc_def.arena_enabled and
                 abs(npc.x - entity.x) <= 5 and
                 abs(npc.y - entity.y) <= 5 do
              npc_def
            end
          end)

        cond do
          guard == nil ->
            msg(state, char_id, "No hay un guardia de arena cerca.")
            {:noreply, state}

          entity.dead ->
            msg(state, char_id, "Estas muerto!")
            {:noreply, state}

          entity.gold < guard.map_entry_price ->
            msg(state, char_id, "Necesitas #{guard.map_entry_price} monedas de oro para entrar.")
            {:noreply, state}

          true ->
            entity = %{entity | gold: entity.gold - guard.map_entry_price}
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
            )

            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:transfer, guard.map_target_entry, guard.map_target_entry_x, guard.map_target_entry_y, entity}
            )

            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Forum (double-click on forum object) — task 44
  # ==================================================================

  def handle_forum_open(state, char_id, forum_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, _entity} ->
        messages = Arena.Forum.get_messages(forum_id)

        raw =
          Encoder.encode(
            {:show_forum_form,
             %{
               forum_id: forum_id,
               messages: messages
             }}
          )

        Helpers.send_to_session(state.sessions, char_id, {:send_raw, raw})

        # Tell the session handler which forum is open
        Helpers.send_to_session(state.sessions, char_id, {:set_viewing_forum, forum_id})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_divorce(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.spouse_id == 0 or entity.spouse_id == nil do
          msg(state, char_id, "No estas casado.")
          {:noreply, state}
        else
          spouse_id = entity.spouse_id

          entity = %{entity | spouse_id: 0, marriage_proposal_target: nil}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          # Try to update spouse if on same map
          case Map.fetch(state.players, spouse_id) do
            {:ok, spouse_entity} ->
              spouse_entity = %{spouse_entity | spouse_id: 0, marriage_proposal_target: nil}
              players = Map.put(state.players, spouse_id, spouse_entity)
              state = %{state | players: players}

              msg(state, char_id, "Te has divorciado.")
              msg(state, spouse_id, "#{entity.name} se ha divorciado de ti.")

              {:noreply, state}

            :error ->
              # Spouse offline or on another map -- only clear our side
              msg(state, char_id, "Te has divorciado.")
              {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Account state — VB6: HandleRequestAccountState
  # Banker shows bank gold, Timbero shows gambling stats.
  # ==================================================================

  def handle_request_account_state(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        msg(state, char_id, "No puedes hacer eso estando muerto.")
        {:noreply, state}

      {:ok, entity} ->
        # Find nearby banker or timbero NPC (within 3 tiles, like VB6)
        nearby_npc =
          Enum.find_value(state.npcs_live, fn {_id, npc} ->
            npc_def = GameData.get_npc(npc.npc_id)

            if npc_def != nil and
                 npc_def.npc_type in [@npc_type_banquero, @npc_type_timbero] and
                 abs(npc.x - entity.x) <= 3 and
                 abs(npc.y - entity.y) <= 3 do
              npc_def
            end
          end)

        cond do
          nearby_npc == nil ->
            msg(state, char_id, "Primero debes seleccionar un personaje, haz click izquierdo sobre el.")
            {:noreply, state}

          nearby_npc.npc_type == @npc_type_banquero ->
            bank_gold = Map.get(entity, :bank_gold, 0)
            msg(state, char_id, "Tenes #{bank_gold} monedas de oro en tu cuenta.")
            {:noreply, state}

          nearby_npc.npc_type == @npc_type_timbero ->
            wins = Map.get(entity, :gamble_wins, 0)
            losses = Map.get(entity, :gamble_losses, 0)
            earnings = wins - losses
            msg(state, char_id, "Ganancias: #{earnings} monedas de oro.")
            {:noreply, state}

          true ->
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Reward — VB6: HandleReward requires targeting enlistador NPC
  # ==================================================================

  def handle_request_reward(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        msg(state, char_id, "No puedes hacer eso estando muerto.")
        {:noreply, state}

      {:ok, entity} ->
        # Find nearby enlistador NPC (within 4 tiles, like VB6)
        enlistador =
          Enum.find_value(state.npcs_live, fn {_id, npc} ->
            npc_def = GameData.get_npc(npc.npc_id)

            if npc_def != nil and
                 npc_def.npc_type == @npc_type_enlistador and
                 abs(npc.x - entity.x) <= 4 and
                 abs(npc.y - entity.y) <= 4 do
              npc_def
            end
          end)

        cond do
          enlistador == nil ->
            msg(state, char_id, "Primero debes seleccionar un personaje, haz click izquierdo sobre el.")
            {:noreply, state}

          entity.faction == :none ->
            msg(state, char_id, "No perteneces a ninguna faccion.")
            {:noreply, state}

          true ->
            # VB6: checks faction_score vs rank requirements, then awards items.
            # TODO: Implement rank thresholds and reward items when faction data is loaded.
            msg(state, char_id, "No hay recompensas disponibles en este momento.")
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

end
