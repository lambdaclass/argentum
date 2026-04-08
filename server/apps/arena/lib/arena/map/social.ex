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
  @npc_type_resucitador_newbie 9
  @yell_range_x (Application.compile_env(:arena, :aoi_range_x, 11)) * 2
  @yell_range_y (Application.compile_env(:arena, :aoi_range_y, 9)) * 2
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

      :error -> {:reply, {:error, :not_on_map}, state}
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
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "Estás silenciado.", font_index: 0}})})
              {:noreply, state}

            # Chat rate limit: 1 message per second
            now - entity.last_chat_at < @chat_cooldown_ms ->
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "Estás hablando demasiado rápido.", font_index: 0}})})
              {:noreply, state}

            true ->
              # Apply word filter
              filtered_message = Arena.ChatFilter.filter(message)

              # Update last_chat_at
              entity = %{entity | last_chat_at: now}
              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              chat_raw = Encoder.encode({:chat_over_head, %{
                message: filtered_message,
                char_index: entity.char_index,
                color: 0x00FFFFFF,
                x: entity.x,
                y: entity.y,
                min_display_time: 2000,
                max_display_time: 5000
              }})

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
  # GM Commands
  # ==================================================================

  defp gm_console(state, char_id, message) do
    Helpers.send_to_session(state.sessions, char_id,
      {:send_raw, Encoder.encode({:console_msg, %{message: message, font_index: 0}})})
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

      ["/JAIL", _name_upper] ->
        target_name = Enum.at(parts, 1)
        gm_jail(state, char_id, target_name)

      ["/SPAWNNPC", npc_id_str] ->
        gm_spawn_npc(state, char_id, entity, npc_id_str)

      ["/LOCATE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        gm_locate(state, char_id, target_name)

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
      Helpers.send_to_session(state.sessions, char_id,
        {:transfer, map_id, x, y, entity})
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

          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})})
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
          Helpers.send_to_session(state.sessions, char_id,
            {:transfer, entity.map_id, target.x, target.y, entity})
          gm_console(state, char_id, "Teleporting to #{target.name} at (#{target.x}, #{target.y})...")
          {:noreply, state}
        else
          # Target is on a different map — transfer there
          Helpers.send_to_session(state.sessions, char_id,
            {:transfer, target.map_id, target.x, target.y, entity})
          gm_console(state, char_id, "Teleporting to #{target.name} on map #{target.map_id} (#{target.x}, #{target.y})...")
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
        gm_console(state, char_id, "Dead: #{target.dead} | Criminal: #{target.criminal} | Invisible: #{target.invisible}")
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
          target = %{target | dead: true, hp: 0, deaths: target.deaths + 1}
          players = Map.put(state.players, target_id, target)
          state = %{state | players: players}

          # Notify the killed player
          Helpers.send_to_session(state.sessions, target_id,
            {:send_raw, Encoder.encode({:update_hp, %{min_hp: 0, shield: 0}})})
          Helpers.send_to_session(state.sessions, target_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "A GM has killed you.", font_index: 0}})})

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
        Helpers.send_to_session(state.sessions, target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido expulsado del servidor.", font_index: 0}})})
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

                Helpers.send_to_session(state.sessions, target_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido baneado por #{days} día(s).", font_index: 0}})})
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

            Helpers.send_to_session(state.sessions, target_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido silenciado por #{minutes} minuto(s).", font_index: 0}})})
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

        Helpers.send_to_session(state.sessions, target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Ya no estás silenciado.", font_index: 0}})})
        gm_console(state, char_id, "#{target.name} has been unmuted.")
        {:noreply, state}

      :not_found ->
        gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  # /JAIL name — teleport player to jail map (Cárcel de Ullathorpe)
  defp gm_jail(state, char_id, target_name) do
    case find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        Helpers.send_to_session(state.sessions, target_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido enviado a la cárcel.", font_index: 0}})})
        Helpers.send_to_session(state.sessions, target_id,
          {:transfer, @jail_map_id, @jail_x, @jail_y, target})
        gm_console(state, char_id, "#{target.name} has been jailed (map #{@jail_map_id}).")
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

              state = %{state |
                npcs_live: npcs_live,
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
          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
          {:noreply, state}
        else
          # VB6: yelling breaks invisibility
          entity = Helpers.break_invisibility(entity, state, char_id)
          players = Map.put(state.players, char_id, entity)

          yell_raw = Encoder.encode({:chat_over_head, %{
            message: message,
            char_index: entity.char_index,
            color: 0x00FF0000,
            x: entity.x,
            y: entity.y,
            min_display_time: 3000,
            max_display_time: 6000
          }})

          Visibility.broadcast_range(%{state | players: players}, entity.x, entity.y, @yell_range_x, @yell_range_y, fn pid ->
            send(pid, {:send_raw, yell_raw})
          end)

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
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
            {:noreply, state}

          entity.hp >= entity.max_hp ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas sano.", font_index: 0}})})
            {:noreply, state}

          true ->
            new_resting = not entity.resting
            entity = %{entity | resting: new_resting, meditating: false}
            players = Map.put(state.players, char_id, entity)

            msg = if new_resting, do: "Has comenzado a descansar.", else: "Has dejado de descansar."
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: msg, font_index: 0}})})

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
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
            {:noreply, state}

          entity.class not in @magical_classes ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Solo las clases magicas pueden meditar.", font_index: 0}})})
            {:noreply, state}

          entity.mana >= entity.max_mana ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Tienes el mana completo.", font_index: 0}})})
            {:noreply, state}

          true ->
            new_meditating = not entity.meditating
            entity = %{entity | meditating: new_meditating, resting: false}
            players = Map.put(state.players, char_id, entity)

            msg = if new_meditating, do: "Has comenzado a meditar.", else: "Has dejado de meditar."
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: msg, font_index: 0}})})

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
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
            {:noreply, state}

          entity.hp >= entity.max_hp ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas sano.", font_index: 0}})})
            {:noreply, state}

          true ->
            # VB6: heal is NPC interaction -- full heal from Revividor NPC.
            case find_nearby_npc_of_type(state, entity, [@npc_type_revividor, @npc_type_resucitador_newbie]) do
              {:ok, _npc, npc_def} ->
                # VB6: ResucitadorNewbie only serves newbies (level <= 12)
                if npc_def.npc_type == @npc_type_resucitador_newbie and entity.level > 12 do
                  Helpers.send_to_session(state.sessions, char_id,
                    {:send_raw, Encoder.encode({:console_msg, %{message: "Solo los newbies pueden ser curados aqui.", font_index: 0}})})
                  {:noreply, state}
                else
                  entity = %{entity | hp: entity.max_hp}
                  players = Map.put(state.players, char_id, entity)

                  Helpers.send_to_session(state.sessions, char_id,
                    {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido curado.", font_index: 0}})})
                  Helpers.send_to_session(state.sessions, char_id,
                    {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})})

                  {:noreply, %{state | players: players}}
                end

              :not_found ->
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un sacerdote cerca.", font_index: 0}})})
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
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Solo los newbies pueden ser resucitados aqui.", font_index: 0}})})
                {:noreply, state}
              else
                entity = %{entity |
                  dead: false,
                  hp: entity.max_hp,
                  mana: 0,
                  buffs: [],
                  paralyzed: false,
                  poisoned: false,
                  invisible: false
                }
                players = Map.put(state.players, char_id, entity)

                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})})
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:update_mana, %{min_mana: 0}})})
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido resucitado.", font_index: 0}})})

                state = %{state | players: players}
                Helpers.broadcast_character_change(state, entity)

                Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
                  send(pid, {:send_raw, Encoder.encode({:create_fx, %{char_index: entity.char_index, fx: 15, loops: 0}})})
                end)

                {:noreply, state}
              end

            :not_found ->
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un sacerdote cerca.", font_index: 0}})})
              {:noreply, state}
          end
        else
          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "No estas muerto.", font_index: 0}})})
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
        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:update_user_stats, %{
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
          }})})

        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:send_atributes, %{
            str: entity.str,
            agi: entity.agi,
            int: entity.int,
            con: entity.con,
            cha: entity.cha
          }})})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_request_skills(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @skill_order [
    :magic, :stealing, :combat_tactics, :combat_weapons, :meditation,
    :short_weapons, :hiding, :survival, :trading, :combat_defense,
    :leadership, :ranged_weapons, :wrestling, :navigation, :riding,
    :resistance, :woodcutting, :fishing, :mining, :blacksmithing,
    :carpentry, :alchemy, :tailoring, :taming
  ]

  @crafting_skills [:woodcutting, :fishing, :mining, :blacksmithing,
                    :carpentry, :alchemy, :tailoring, :taming]

  # -- Trainer skill groups (VB6 subtypes) --
  @combat_skills [:combat_tactics, :combat_weapons, :combat_defense,
                  :short_weapons, :ranged_weapons, :wrestling, :resistance]
  @magic_skills [:magic, :meditation]
  @trade_skills [:woodcutting, :fishing, :mining, :blacksmithing, :carpentry,
                 :alchemy, :tailoring, :taming, :trading, :navigation,
                 :survival, :riding, :leadership]
  @stealth_skills [:stealing, :hiding]

  @doc """
  Train a skill via a nearby Entrenador NPC, or attempt crafting work if no
  trainer is present.

  VB6 trainers have subtypes (combat, magic, trade, stealth) that restrict
  which skill groups they can teach. The skill groups are defined in the
  `@combat_skills`, `@magic_skills`, `@trade_skills`, and `@stealth_skills`
  module attributes above. Once NPC subtype data is loaded from the .dat
  files, `trainer_accepts_skill?/2` will gate training by group.
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
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Este entrenador no enseña esa habilidad.", font_index: 0}})})
            {:noreply, state}

          # Near trainer: train with skill points (all skills)
          near_trainer and entity.skill_points <= 0 ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "No tienes puntos de skill disponibles.", font_index: 0}})})
            {:noreply, state}

          near_trainer and Map.get(entity.skills, skill_atom, 0) >= 100 ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Ya tienes el maximo en esa habilidad.", font_index: 0}})})
            {:noreply, state}

          near_trainer ->
            current = Map.get(entity.skills, skill_atom, 0)
            cost = max(current * 10, 10)

            if entity.gold < cost do
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "No tienes suficiente oro. Costo: #{cost}", font_index: 0}})})
              {:noreply, state}
            else
              entity = %{entity |
                skills: Map.put(entity.skills, skill_atom, current + 1),
                skill_points: entity.skill_points - 1,
                gold: entity.gold - cost
              }
              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})})
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})})
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "Has entrenado! Costo: #{cost} oro. Skill points restantes: #{entity.skill_points}", font_index: 0}})})

              {:noreply, state}
            end

          # Not near trainer, but crafting skill: attempt work
          skill_atom in @crafting_skills ->
            Crafting.handle_work(state, char_id, skill_atom)

          # Not near trainer, not a crafting skill
          true ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un entrenador cerca.", font_index: 0}})})
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
        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:update_user_stats, %{
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
          }})})

        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:mini_stats, %{
            ciudadanos_matados: entity.citizens_killed,
            criminales_matados: entity.criminals_killed,
            faction_status: case Map.get(entity, :faction, :none) do
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
          }})})

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
                {:noreply, state}
            end
          else
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas demasiado lejos.", font_index: 0}})})
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
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Puedo resucitarte. Usa el comando /resucitar.", font_index: 0}})})
            else
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Puedo curarte. Usa el comando /curar.", font_index: 0}})})
            end
            {:noreply, state}

          # Enlistador — faction NPC
          npc_def.npc_type == @npc_type_enlistador ->
            handle_enlistador_click(state, char_id, entity, npc_def)

          # Banker
          npc_def.npc_type == @npc_type_banquero ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Bienvenido al banco.", font_index: 0}})})
            {:noreply, state}

          # Trainer
          npc_def.npc_type == @npc_type_entrenador ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Puedo entrenarte. Usa el boton Entrenar.", font_index: 0}})})
            {:noreply, state}

          # Default: show NPC name
          true ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Ves a #{npc_def.name}.", font_index: 0}})})
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
    expected_faccion = case faction do
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

          # Resend full inventory after stripping
          Enum.each(0..23, fn slot ->
            Helpers.send_inventory_slot(state.sessions, char_id, entity.inventory, slot)
          end)

          msg(%{state | players: players}, char_id, "Has renunciado a tu faccion.")
          {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp strip_faction_items(entity) do
    # VB6: remove items with Real=1 or Caos=1 flag
    # For now we don't have those flags on ItemDef, so this is a no-op placeholder.
    # TODO: add Real/Caos flags to ItemDef and strip faction-exclusive gear here.
    entity
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
      att_faction != :none and att_faction == def_faction -> 0

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

      true -> 0
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
          raw = Encoder.encode({:console_faction_message, %{
            message: chat_msg,
            font_index: font_index,
            faction_label: faction_label
          }})

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
    Helpers.send_to_session(state.sessions, char_id,
      {:send_raw, Encoder.encode({:console_msg, %{message: message, font_index: 0}})})
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
end
