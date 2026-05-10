defmodule Arena.Map.Gm.Events do
  @moduledoc """
  GM event commands: NPC spawning, invasions, tournaments, events,
  faction messages, etc.

  All public handlers return `{:ok, state, [Arena.Map.Effect.t()]}`.
  The `Arena.Map.GmCommands` dispatcher runs the effect list against
  the post-handler state and adapts the return to the cast/`{:noreply,
  state}` contract that `Arena.Map.MapServer` still uses for chat-driven
  GM commands.

  NpcDeath bridges (gm_kill_npc, gm_kill_npc_permanent, gm_mass_kill_npcs)
  no longer call `Arena.Map.Effects.run/2` inline; the effects produced by
  `Arena.Map.NpcDeath.resolve_npc_death/4` are appended to the returned
  effect list so the runner is the single dispatch site.
  """

  alias Arena.AuditLog
  alias Arena.Map.{Effects, Helpers}
  alias Arena.Entity.NpcEntity
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  defp gm_console_effect(char_id, message), do: Effects.send(char_id, console(message))

  def gm_spawn_npc(state, char_id, entity, npc_id_str) do
    case Integer.parse(npc_id_str) do
      {npc_id, ""} ->
        case GameData.get_npc(npc_id) do
          nil ->
            {:ok, state, [gm_console_effect(char_id, "NPC #{npc_id} not found in data.")]}

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

              create_packet = Encoder.encode(Helpers.npc_create_packet(npc_entity, npc_def))

              AuditLog.log_gm_action(char_id, "spawn_npc", "#{npc_def.name} at (#{tx},#{ty})")

              effects = [
                Effects.broadcast_visible_all(tx, ty, create_packet),
                gm_console_effect(
                  char_id,
                  "Spawned NPC #{npc_def.name} (id #{npc_id}) at (#{tx}, #{ty})."
                )
              ]

              {:ok, state, effects}
            else
              {:ok, state,
               [
                 gm_console_effect(
                   char_id,
                   "Cannot spawn NPC: facing tile (#{tx}, #{ty}) is blocked or occupied."
                 )
               ]}
            end
        end

      _ ->
        {:ok, state, [gm_console_effect(char_id, "Usage: /SPAWNNPC npc_id")]}
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
            {:ok, state, [gm_console_effect(char_id, "No NPC found at facing tile.")]}

          npc ->
            npc_def = GameData.get_npc(npc.npc_id)
            npc_name = if npc_def, do: npc_def.name, else: "NPC #{npc.npc_id}"

            {nil, state, death_effects} =
              Arena.Map.NpcDeath.resolve_npc_death(state, instance_id, npc, source: :gm)

            AuditLog.log_gm_action(char_id, "kill_npc", npc_name)

            effects =
              death_effects ++
                [gm_console_effect(char_id, "Killed NPC #{npc_name} (respawn enabled).")]

            {:ok, state, effects}
        end

      _ ->
        {:ok, state, [gm_console_effect(char_id, "No NPC at facing tile (#{tx}, #{ty}).")]}
    end
  end

  def gm_kill_npc_permanent(state, char_id, entity) do
    {tx, ty} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

    case Helpers.get_occupancy(state.occupancy, tx, ty) do
      {:npc, instance_id} ->
        case Map.get(state.npcs_live, instance_id) do
          nil ->
            {:ok, state, [gm_console_effect(char_id, "No NPC found at facing tile.")]}

          npc ->
            npc_def = GameData.get_npc(npc.npc_id)
            npc_name = if npc_def, do: npc_def.name, else: "NPC #{npc.npc_id}"

            {nil, state, death_effects} =
              Arena.Map.NpcDeath.resolve_npc_death(state, instance_id, npc,
                source: :gm,
                permanent: true
              )

            AuditLog.log_gm_action(char_id, "kill_npc_permanent", npc_name)

            effects =
              death_effects ++
                [gm_console_effect(char_id, "Killed NPC #{npc_name} permanently (no respawn).")]

            {:ok, state, effects}
        end

      _ ->
        {:ok, state, [gm_console_effect(char_id, "No NPC at facing tile (#{tx}, #{ty}).")]}
    end
  end

  def gm_mass_kill_npcs(state, char_id, entity) do
    aoi_x = Helpers.aoi_range_x()
    aoi_y = Helpers.aoi_range_y()

    {killed, state, death_effects} =
      Enum.reduce(state.npcs_live, {0, state, []}, fn {inst_id, npc}, {count, st, eacc} ->
        if npc.alive and abs(npc.x - entity.x) <= aoi_x and abs(npc.y - entity.y) <= aoi_y do
          {nil, st, effs} =
            Arena.Map.NpcDeath.resolve_npc_death(st, inst_id, npc,
              source: :gm,
              permanent: true
            )

          {count + 1, st, eacc ++ effs}
        else
          {count, st, eacc}
        end
      end)

    AuditLog.log_gm_action(char_id, "mass_kill_npcs", "#{killed} NPCs")

    effects = death_effects ++ [gm_console_effect(char_id, "Killed #{killed} NPCs nearby.")]

    {:ok, state, effects}
  end

  def gm_invasion(state, char_id, entity, map_str, npc_str, count_str) do
    with {map_id, ""} <- Integer.parse(map_str),
         {npc_id, ""} <- Integer.parse(npc_str),
         {count, ""} <- Integer.parse(count_str),
         true <- count > 0 and count <= 200 do
      msg =
        case Arena.Events.InvasionServer.start_invasion(map_id, npc_id, count, entity.name) do
          {:ok, spawned} ->
            AuditLog.log_gm_action(char_id, "invasion", "map #{map_id} npc #{npc_id} count #{count}")
            "Invasion started: #{spawned} NPCs spawned on map #{map_id}."

          {:error, :invasion_already_active} ->
            "An invasion is already active on map #{map_id}."

          {:error, :npc_not_found} ->
            "NPC #{npc_id} not found."

          {:error, :no_npcs_spawned} ->
            "Could not spawn any NPCs (no walkable tiles found)."

          {:error, reason} ->
            "Invasion failed: #{inspect(reason)}"
        end

      {:ok, state, [gm_console_effect(char_id, msg)]}
    else
      _ ->
        {:ok, state,
         [gm_console_effect(char_id, "Usage: /INVASION map_id npc_id count (max 200)")]}
    end
  end

  def gm_invasion_stop(state, char_id, map_str) do
    msg =
      case Integer.parse(map_str) do
        {map_id, ""} ->
          case Arena.Events.InvasionServer.stop_invasion(map_id) do
            :ok ->
              AuditLog.log_gm_action(char_id, "invasion_stop", "map #{map_id}")
              "Invasion on map #{map_id} stopped."

            {:error, :no_invasion} ->
              "No active invasion on map #{map_id}."
          end

        _ ->
          "Usage: /INVASION STOP map_id"
      end

    {:ok, state, [gm_console_effect(char_id, msg)]}
  end

  def gm_invasion_list(state, char_id) do
    effects =
      case Arena.Events.InvasionServer.list_invasions() do
        {:ok, invasions} when map_size(invasions) == 0 ->
          [gm_console_effect(char_id, "No active invasions.")]

        {:ok, invasions} ->
          for {map_id, inv} <- invasions do
            gm_console_effect(
              char_id,
              "Map #{map_id}: NPC #{inv.npc_id}, #{inv.kills}/#{inv.total_count} killed"
            )
          end
      end

    {:ok, state, effects}
  end

  def gm_tournament_start(state, char_id, entity, max_str) do
    max_players =
      case Integer.parse(max_str) do
        {n, _} when n > 1 -> n
        _ -> 16
      end

    msg =
      case Arena.Events.TournamentServer.start_tournament(max_players, entity.name) do
        :ok ->
          AuditLog.log_gm_action(char_id, "tournament_start", "max #{max_players}")
          "Tournament started (max #{max_players} players)."

        {:error, :tournament_already_active} ->
          "A tournament is already active."
      end

    {:ok, state, [gm_console_effect(char_id, msg)]}
  end

  def gm_tournament_begin(state, char_id) do
    msg =
      case Arena.Events.TournamentServer.begin_matches() do
        :ok ->
          AuditLog.log_gm_action(char_id, "tournament_begin", "")
          "Tournament matches started."

        {:error, :not_enough_players} ->
          "Not enough players to start."

        {:error, reason} ->
          "Error: #{inspect(reason)}"
      end

    {:ok, state, [gm_console_effect(char_id, msg)]}
  end

  def gm_tournament_cancel(state, char_id) do
    msg =
      case Arena.Events.TournamentServer.cancel() do
        :ok ->
          AuditLog.log_gm_action(char_id, "tournament_cancel", "")
          "Tournament cancelled."

        {:error, :no_tournament} ->
          "No active tournament."
      end

    {:ok, state, [gm_console_effect(char_id, msg)]}
  end

  def gm_tournament_status(state, char_id) do
    msg =
      case Arena.Events.TournamentServer.get_state() do
        nil ->
          "No active tournament."

        t ->
          participants = length(t.participants)
          "Tournament: phase=#{t.phase}, participants=#{participants}, round=#{t.current_round}"
      end

    {:ok, state, [gm_console_effect(char_id, msg)]}
  end

  def gm_event_start(state, char_id, entity, type_str, duration_str) do
    type =
      case String.downcase(type_str) do
        "xp_bonus" -> :xp_bonus
        "gold_bonus" -> :gold_bonus
        "drop_bonus" -> :drop_bonus
        _ -> :custom
      end

    msg =
      case Integer.parse(duration_str) do
        {minutes, _} when minutes > 0 ->
          case Arena.Events.EventManager.start_event(type, minutes, entity.name) do
            :ok ->
              AuditLog.log_gm_action(char_id, "event_start", "#{type} #{minutes}m")
              "Event #{type} started for #{minutes} minutes."

            {:error, :event_already_active} ->
              "Event #{type} already active."
          end

        _ ->
          "Usage: /EVENT START type duration_minutes"
      end

    {:ok, state, [gm_console_effect(char_id, msg)]}
  end

  def gm_event_stop(state, char_id, type_str) do
    type =
      case String.downcase(type_str) do
        "xp_bonus" -> :xp_bonus
        "gold_bonus" -> :gold_bonus
        "drop_bonus" -> :drop_bonus
        _ -> :custom
      end

    msg =
      case Arena.Events.EventManager.stop_event(type) do
        :ok ->
          AuditLog.log_gm_action(char_id, "event_stop", "#{type}")
          "Event #{type} stopped."

        {:error, :no_such_event} ->
          "No active event of type #{type}."
      end

    {:ok, state, [gm_console_effect(char_id, msg)]}
  end

  def gm_event_list(state, char_id) do
    effects =
      case Arena.Events.EventManager.list_events() do
        {:ok, []} ->
          [gm_console_effect(char_id, "No active events.")]

        {:ok, events} ->
          for ev <- events do
            mins = div(ev.remaining_seconds, 60)

            gm_console_effect(
              char_id,
              "#{ev.type}: #{ev.description} (#{mins}m remaining, #{ev.participants} participants)"
            )
          end
      end

    {:ok, state, effects}
  end

  def gm_faction_message(state, char_id, faction, message) do
    faction_name =
      case faction do
        :royal_army -> "Armada Real"
        :chaos_legion -> "Legion del Caos"
      end

    packet =
      Encoder.encode(
        {:console_msg, %{message: "[#{faction_name}] #{message}", font_index: 0}}
      )

    broadcast_effects =
      for {pid, entity} <- state.players, entity.faction == faction do
        Effects.send(pid, packet)
      end

    AuditLog.log_gm_action(char_id, "faction_message", "#{faction_name}: #{message}")

    effects =
      broadcast_effects ++
        [gm_console_effect(char_id, "Faction message sent to #{faction_name}.")]

    {:ok, state, effects}
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
        {:ok, state, [gm_console_effect(char_id, "No NPCs nearby.")]}

      {_npc_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)
        npc_name = if npc_def, do: npc_def.name, else: "NPC"

        chat_packet =
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

        AuditLog.log_gm_action(char_id, "talk_as_npc", message)

        effects = [
          Effects.broadcast_map(chat_packet),
          gm_console_effect(char_id, "#{npc_name} says: #{message}")
        ]

        {:ok, state, effects}
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

        {:ok, state, [gm_console_effect(char_id, "#{target_name} added to #{label} Council.")]}

      :not_found ->
        {:ok, state, [gm_console_effect(char_id, "Player '#{target_name}' not found.")]}
    end
  end
end
