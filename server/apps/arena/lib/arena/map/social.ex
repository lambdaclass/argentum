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

          cond do
            # Mute enforcement
            entity.muted_until > 0 and now < entity.muted_until ->
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
          target = %{target | dead: true, hp: 0}
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
            muted_until = System.monotonic_time(:millisecond) + minutes * 60_000
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

  # Returns which skill group a skill belongs to.
  defp skill_group(skill) when skill in @combat_skills,  do: :combat
  defp skill_group(skill) when skill in @magic_skills,   do: :magic
  defp skill_group(skill) when skill in @trade_skills,   do: :trade
  defp skill_group(skill) when skill in @stealth_skills,  do: :stealth
  defp skill_group(_skill), do: :unknown

  # Check whether an NPC trainer accepts a given skill.
  # TODO: gate by npc_def.trainer_type when subtype data is available in npcs.dat.
  # Once trainer_type is loaded, match skill_group(skill_atom) against it.
  defp trainer_accepts_skill?(_npc_def, skill_atom) do
    _group = skill_group(skill_atom)
    true
  end

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
            ciudadanos_matados: 0,
            criminales_matados: 0,
            faction_status: case Map.get(entity, :faction, :none) do
              :royal_army -> 1
              :chaos_legion -> 2
              :none -> if entity.criminal, do: 3, else: 0
            end,
            npcs_killed: 0,
            class: Helpers.class_to_int(entity.class),
            penalty: 0,
            deaths: 0,
            gender: if(entity.gender == :male, do: 1, else: 2),
            fishing_points: 0,
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
  # Faction commands
  # ==================================================================

  def handle_enlist_faction(state, char_id, faction) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.criminal ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Los criminales no pueden enlistarse.", font_index: 0}})})
            {:noreply, state}

          entity.faction != :none ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Ya perteneces a una faccion. Usa /RENUNCIAR primero.", font_index: 0}})})
            {:noreply, state}

          true ->
            entity = %{entity | faction: faction}
            players = Map.put(state.players, char_id, entity)

            faction_name = faction_display_name(faction)
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Te has enlistado en #{faction_name}.", font_index: 0}})})

            {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_leave_faction(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.faction == :none do
          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "No perteneces a ninguna faccion.", font_index: 0}})})
          {:noreply, state}
        else
          entity = %{entity | faction: :none}
          players = Map.put(state.players, char_id, entity)

          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "Has renunciado a tu faccion.", font_index: 0}})})

          {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_faction_chat(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.faction == :none do
          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "No perteneces a ninguna faccion.", font_index: 0}})})
          {:noreply, state}
        else
          faction_name = faction_display_name(entity.faction)
          chat_msg = "[#{faction_name}] #{entity.name}: #{message}"
          raw = Encoder.encode({:console_msg, %{message: chat_msg, font_index: 0}})

          for {_cid, other} <- state.players, other.faction == entity.faction do
            Helpers.send_to_session(state.sessions, other.char_id, {:send_raw, raw})
          end

          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp faction_display_name(:royal_army), do: "Armada Real"
  defp faction_display_name(:chaos_legion), do: "Legion del Caos"
  defp faction_display_name(_), do: "Ninguna"

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
