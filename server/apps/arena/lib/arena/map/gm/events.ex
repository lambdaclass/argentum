defmodule Arena.Map.Gm.Events do
  @moduledoc "GM event commands: NPC spawning, invasions, tournaments, events, faction messages, etc."

  alias Arena.AuditLog
  alias Arena.Map.{Helpers, Visibility}
  alias Arena.Entity.NpcEntity
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  def gm_spawn_npc(state, char_id, entity, npc_id_str) do
    case Integer.parse(npc_id_str) do
      {npc_id, ""} ->
        case GameData.get_npc(npc_id) do
          nil ->
            Helpers.gm_console(state, char_id, "NPC #{npc_id} not found in data.")
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

              raw = Encoder.encode(Helpers.npc_create_packet(npc_entity, npc_def))

              Visibility.broadcast_visible_all(state, tx, ty, fn pid ->
                send(pid, {:send_raw, raw})
              end)

              AuditLog.log_gm_action(char_id, "spawn_npc", "#{npc_def.name} at (#{tx},#{ty})")
              Helpers.gm_console(state, char_id, "Spawned NPC #{npc_def.name} (id #{npc_id}) at (#{tx}, #{ty}).")
              {:noreply, state}
            else
              Helpers.gm_console(state, char_id, "Cannot spawn NPC: facing tile (#{tx}, #{ty}) is blocked or occupied.")
              {:noreply, state}
            end
        end

      _ ->
        Helpers.gm_console(state, char_id, "Usage: /SPAWNNPC npc_id")
        {:noreply, state}
    end
  end

  def gm_spawn_npc_respawn(state, char_id, entity, npc_id_str) do
    gm_spawn_npc(state, char_id, entity, npc_id_str)
  end

  def gm_kill_npc(state, char_id, entity) do
    {tx, ty} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

    case Helpers.get_occupancy(state.occupancy, tx, ty) do
      {:npc, instance_id} ->
        case Map.get(state.npcs_live, instance_id) do
          nil ->
            Helpers.gm_console(state, char_id, "No NPC found at facing tile.")
            {:noreply, state}

          npc ->
            npc_def = GameData.get_npc(npc.npc_id)
            npc_name = if npc_def, do: npc_def.name, else: "NPC #{npc.npc_id}"

            state = Arena.Map.NpcDeath.resolve_npc_death(state, instance_id, npc, source: :gm)
            AuditLog.log_gm_action(char_id, "kill_npc", npc_name)
            Helpers.gm_console(state, char_id, "Killed NPC #{npc_name} (respawn enabled).")
            {:noreply, state}
        end

      _ ->
        Helpers.gm_console(state, char_id, "No NPC at facing tile (#{tx}, #{ty}).")
        {:noreply, state}
    end
  end

  def gm_kill_npc_permanent(state, char_id, entity) do
    {tx, ty} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

    case Helpers.get_occupancy(state.occupancy, tx, ty) do
      {:npc, instance_id} ->
        case Map.get(state.npcs_live, instance_id) do
          nil ->
            Helpers.gm_console(state, char_id, "No NPC found at facing tile.")
            {:noreply, state}

          npc ->
            npc_def = GameData.get_npc(npc.npc_id)
            npc_name = if npc_def, do: npc_def.name, else: "NPC #{npc.npc_id}"

            state = Arena.Map.NpcDeath.resolve_npc_death(state, instance_id, npc, source: :gm, permanent: true)
            AuditLog.log_gm_action(char_id, "kill_npc_permanent", npc_name)
            Helpers.gm_console(state, char_id, "Killed NPC #{npc_name} permanently (no respawn).")
            {:noreply, state}
        end

      _ ->
        Helpers.gm_console(state, char_id, "No NPC at facing tile (#{tx}, #{ty}).")
        {:noreply, state}
    end
  end

  def gm_mass_kill_npcs(state, char_id, entity) do
    aoi_x = Helpers.aoi_range_x()
    aoi_y = Helpers.aoi_range_y()

    {killed, state} =
      Enum.reduce(state.npcs_live, {0, state}, fn {inst_id, npc}, {count, st} ->
        if npc.alive and abs(npc.x - entity.x) <= aoi_x and abs(npc.y - entity.y) <= aoi_y do
          st = Arena.Map.NpcDeath.resolve_npc_death(st, inst_id, npc, source: :gm, permanent: true)
          {count + 1, st}
        else
          {count, st}
        end
      end)

    AuditLog.log_gm_action(char_id, "mass_kill_npcs", "#{killed} NPCs")
    Helpers.gm_console(state, char_id, "Killed #{killed} NPCs nearby.")
    {:noreply, state}
  end

  def gm_invasion(state, char_id, entity, map_str, npc_str, count_str) do
    with {map_id, ""} <- Integer.parse(map_str),
         {npc_id, ""} <- Integer.parse(npc_str),
         {count, ""} <- Integer.parse(count_str),
         true <- count > 0 and count <= 200 do
      case Arena.Events.InvasionServer.start_invasion(map_id, npc_id, count, entity.name) do
        {:ok, spawned} ->
          AuditLog.log_gm_action(char_id, "invasion", "map #{map_id} npc #{npc_id} count #{count}")
          Helpers.gm_console(state, char_id, "Invasion started: #{spawned} NPCs spawned on map #{map_id}.")

        {:error, :invasion_already_active} ->
          Helpers.gm_console(state, char_id, "An invasion is already active on map #{map_id}.")

        {:error, :npc_not_found} ->
          Helpers.gm_console(state, char_id, "NPC #{npc_id} not found.")

        {:error, :no_npcs_spawned} ->
          Helpers.gm_console(state, char_id, "Could not spawn any NPCs (no walkable tiles found).")

        {:error, reason} ->
          Helpers.gm_console(state, char_id, "Invasion failed: #{inspect(reason)}")
      end
    else
      _ -> Helpers.gm_console(state, char_id, "Usage: /INVASION map_id npc_id count (max 200)")
    end

    {:noreply, state}
  end

  def gm_invasion_stop(state, char_id, map_str) do
    case Integer.parse(map_str) do
      {map_id, ""} ->
        case Arena.Events.InvasionServer.stop_invasion(map_id) do
          :ok ->
            AuditLog.log_gm_action(char_id, "invasion_stop", "map #{map_id}")
            Helpers.gm_console(state, char_id, "Invasion on map #{map_id} stopped.")

          {:error, :no_invasion} ->
            Helpers.gm_console(state, char_id, "No active invasion on map #{map_id}.")
        end

      _ ->
        Helpers.gm_console(state, char_id, "Usage: /INVASION STOP map_id")
    end

    {:noreply, state}
  end

  def gm_invasion_list(state, char_id) do
    case Arena.Events.InvasionServer.list_invasions() do
      {:ok, invasions} when map_size(invasions) == 0 ->
        Helpers.gm_console(state, char_id, "No active invasions.")

      {:ok, invasions} ->
        Enum.each(invasions, fn {map_id, inv} ->
          Helpers.gm_console(state, char_id, "Map #{map_id}: NPC #{inv.npc_id}, #{inv.kills}/#{inv.total_count} killed")
        end)
    end

    {:noreply, state}
  end

  def gm_tournament_start(state, char_id, entity, max_str) do
    max_players = case Integer.parse(max_str) do
      {n, _} when n > 1 -> n
      _ -> 16
    end

    case Arena.Events.TournamentServer.start_tournament(max_players, entity.name) do
      :ok ->
        AuditLog.log_gm_action(char_id, "tournament_start", "max #{max_players}")
        Helpers.gm_console(state, char_id, "Tournament started (max #{max_players} players).")

      {:error, :tournament_already_active} ->
        Helpers.gm_console(state, char_id, "A tournament is already active.")
    end

    {:noreply, state}
  end

  def gm_tournament_begin(state, char_id) do
    case Arena.Events.TournamentServer.begin_matches() do
      :ok ->
        AuditLog.log_gm_action(char_id, "tournament_begin", "")
        Helpers.gm_console(state, char_id, "Tournament matches started.")

      {:error, :not_enough_players} ->
        Helpers.gm_console(state, char_id, "Not enough players to start.")

      {:error, reason} ->
        Helpers.gm_console(state, char_id, "Error: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def gm_tournament_cancel(state, char_id) do
    case Arena.Events.TournamentServer.cancel() do
      :ok ->
        AuditLog.log_gm_action(char_id, "tournament_cancel", "")
        Helpers.gm_console(state, char_id, "Tournament cancelled.")

      {:error, :no_tournament} ->
        Helpers.gm_console(state, char_id, "No active tournament.")
    end

    {:noreply, state}
  end

  def gm_tournament_status(state, char_id) do
    case Arena.Events.TournamentServer.get_state() do
      nil ->
        Helpers.gm_console(state, char_id, "No active tournament.")

      t ->
        participants = length(t.participants)
        Helpers.gm_console(state, char_id, "Tournament: phase=#{t.phase}, participants=#{participants}, round=#{t.current_round}")
    end

    {:noreply, state}
  end

  def gm_event_start(state, char_id, entity, type_str, duration_str) do
    type = case String.downcase(type_str) do
      "xp_bonus" -> :xp_bonus
      "gold_bonus" -> :gold_bonus
      "drop_bonus" -> :drop_bonus
      _ -> :custom
    end

    case Integer.parse(duration_str) do
      {minutes, _} when minutes > 0 ->
        case Arena.Events.EventManager.start_event(type, minutes, entity.name) do
          :ok ->
            AuditLog.log_gm_action(char_id, "event_start", "#{type} #{minutes}m")
            Helpers.gm_console(state, char_id, "Event #{type} started for #{minutes} minutes.")

          {:error, :event_already_active} ->
            Helpers.gm_console(state, char_id, "Event #{type} already active.")
        end

      _ ->
        Helpers.gm_console(state, char_id, "Usage: /EVENT START type duration_minutes")
    end

    {:noreply, state}
  end

  def gm_event_stop(state, char_id, type_str) do
    type = case String.downcase(type_str) do
      "xp_bonus" -> :xp_bonus
      "gold_bonus" -> :gold_bonus
      "drop_bonus" -> :drop_bonus
      _ -> :custom
    end

    case Arena.Events.EventManager.stop_event(type) do
      :ok ->
        AuditLog.log_gm_action(char_id, "event_stop", "#{type}")
        Helpers.gm_console(state, char_id, "Event #{type} stopped.")

      {:error, :no_such_event} ->
        Helpers.gm_console(state, char_id, "No active event of type #{type}.")
    end

    {:noreply, state}
  end

  def gm_event_list(state, char_id) do
    case Arena.Events.EventManager.list_events() do
      {:ok, []} ->
        Helpers.gm_console(state, char_id, "No active events.")

      {:ok, events} ->
        Enum.each(events, fn ev ->
          mins = div(ev.remaining_seconds, 60)
          Helpers.gm_console(state, char_id, "#{ev.type}: #{ev.description} (#{mins}m remaining, #{ev.participants} participants)")
        end)
    end

    {:noreply, state}
  end

  def gm_faction_message(state, char_id, faction, message) do
    faction_name =
      case faction do
        :royal_army -> "Armada Real"
        :chaos_legion -> "Legion del Caos"
      end

    raw =
      Encoder.encode(
        {:console_msg, %{message: "[#{faction_name}] #{message}", font_index: 0}}
      )

    Enum.each(state.players, fn {pid, entity} ->
      if entity.faction == faction do
        Helpers.send_to_session(state.sessions, pid, {:send_raw, raw})
      end
    end)

    AuditLog.log_gm_action(char_id, "faction_message", "#{faction_name}: #{message}")
    Helpers.gm_console(state, char_id, "Faction message sent to #{faction_name}.")
    {:noreply, state}
  end

  def gm_talk_as_npc(state, char_id, entity, message) do
    nearest_npc =
      state.npcs_live
      |> Enum.min_by(
        fn {_id, npc} -> Helpers.vb6_distancia(npc, entity) end,
        fn -> nil end
      )

    case nearest_npc do
      nil ->
        Helpers.gm_console(state, char_id, "No NPCs nearby.")
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

        Visibility.broadcast_to_map(state, fn pid -> send(pid, {:send_raw, chat_raw}) end)
        AuditLog.log_gm_action(char_id, "talk_as_npc", message)
        Helpers.gm_console(state, char_id, "#{npc_name} says: #{message}")
        {:noreply, state}
    end
  end

  def gm_accept_council(state, char_id, target_name, council_type) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        target = Map.put(target, :council, council_type)
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        label = if council_type == :royal, do: "Royal", else: "Chaos"
        AuditLog.log_gm_action(char_id, "accept_council", "#{target_name} #{label}")
        Helpers.gm_console(state, char_id, "#{target_name} added to #{label} Council.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end
end
