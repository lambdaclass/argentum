defmodule Arena.Map.GmCommands do
  @moduledoc "GM command handlers."

  require Logger

  alias Arena.Map.{Helpers, Visibility}
  alias Arena.Entity.NpcEntity
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @jail_map_id 66
  @jail_x 33
  @jail_y 33

  # GM command dispatch (called by Chat module when message starts with "/")
  def dispatch_gm_command(state, char_id, entity, message),
    do: handle_gm_command(state, char_id, entity, message)

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
          {target, state} = Arena.Map.PlayerDeath.handle_player_death(state, target_id, %{target | hp: 0})
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
    # Toggle the weather flag in meta
    current = Map.get(state.meta, weather_type, false)
    new_val = !current
    meta = Map.put(state.meta, weather_type, new_val)
    state = %{state | meta: meta}
    status = if new_val, do: "activada", else: "desactivada"
    gm_console(state, char_id, "#{label} #{status} en este mapa.")
    {:noreply, state}
  end

  defp gm_change_map_flag(state, char_id, flag, value_str) do
    new_val = value_str == "1"
    meta = Map.put(state.meta, flag, new_val)
    state = %{state | meta: meta}
    status = if new_val, do: "activado", else: "desactivado"
    gm_console(state, char_id, "Map flag #{flag} #{status}.")
    {:noreply, state}
  end

  defp gm_tile_block_toggle(state, char_id, entity) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    {blocked_tiles, status} =
      if MapSet.member?(state.gm_blocked_tiles, {fx, fy}) do
        {MapSet.delete(state.gm_blocked_tiles, {fx, fy}), "unblocked"}
      else
        {MapSet.put(state.gm_blocked_tiles, {fx, fy}), "blocked"}
      end

    state = %{state | gm_blocked_tiles: blocked_tiles}
    gm_console(state, char_id, "Tile (#{fx},#{fy}) #{status}.")
    {:noreply, state}
  end

  defp gm_set_trigger(state, char_id, entity, trigger_str) do
    case Integer.parse(trigger_str) do
      {trigger, _} ->
        {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

        triggers = Map.put(state.triggers, {fx, fy}, trigger)
        state = %{state | triggers: triggers}

        gm_console(state, char_id, "Trigger #{trigger} set at (#{fx},#{fy}).")
        {:noreply, state}

      :error ->
        gm_console(state, char_id, "Invalid trigger value.")
        {:noreply, state}
    end
  end

  defp gm_ask_trigger(state, char_id, entity) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    trigger = Map.get(state.triggers, {fx, fy}, 0)
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
    items = state.ground_items
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
    ground_items = Map.delete(state.ground_items, {fx, fy})
    state = %{state | ground_items: ground_items}
    gm_console(state, char_id, "Items at (#{fx},#{fy}) destroyed.")
    {:noreply, state}
  end

  defp gm_destroy_all_area(state, char_id, entity) do
    range = 10

    ground_items =
      Enum.reject(state.ground_items, fn {{x, y}, _item} ->
        abs(x - entity.x) <= range and abs(y - entity.y) <= range
      end)
      |> Map.new()

    state = %{state | ground_items: ground_items}
    gm_console(state, char_id, "All items in area destroyed.")
    {:noreply, state}
  end

  defp gm_clean_world(state, char_id) do
    state = %{state | ground_items: %{}}
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

end
