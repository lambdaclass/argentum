defmodule Arena.Map.GmCommands do
  @moduledoc "GM command parser/router. Dispatches to family modules."

  alias Arena.Map.Helpers
  alias AoProtocol.Server.Encoder

  alias Arena.Map.Gm.{
    CharEdit,
    Events,
    Inspection,
    Moderation,
    Permissions,
    Teleport,
    World
  }

  # GM command dispatch (called by Chat module when message starts with "/")
  def dispatch_gm_command(state, char_id, entity, message) do
    # Drift #4 — VB6 Protocol.bas:5177-5209 allows Faccion.Status = consejo
    # members to use /RMSG and /CMSG without GM tier. Skip the tier check
    # when the council rank matches the targeted faction command.
    if council_faction_bypass?(entity, message) do
      handle_gm_command(state, char_id, entity, message)
    else
      case Permissions.check_permission(entity, message) do
        :ok ->
          handle_gm_command(state, char_id, entity, message)

        {:error, reason} ->
          Helpers.gm_console(state, char_id, reason)
          {:noreply, state}
      end
    end
  end

  defp council_faction_bypass?(entity, message) do
    command =
      message
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first("")
      |> String.upcase()

    council = Map.get(entity, :council, false)

    (command == "/RMSG" and council == :royal) or
      (command == "/CMSG" and council == :chaos)
  end

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
        Helpers.gm_console(state, char_id, "Rain toggled #{label} on this map.")

        {:noreply, state}

      {:ok, _entity} ->
        Helpers.gm_console(state, char_id, "You are not a GM.")
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # GM Command Router
  # ==================================================================

  defp handle_gm_command(state, char_id, entity, message) do
    upper = String.upcase(String.trim(message))
    parts = String.split(String.trim(message), ~r/\s+/, parts: 4)
    upper_parts = String.split(upper, ~r/\s+/, parts: 4)

    case upper_parts do
      # Teleport
      ["/TELEPORT", map_str, x_str, y_str] ->
        Teleport.gm_teleport(state, char_id, entity, map_str, x_str, y_str)

      ["/GOTO", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Teleport.gm_goto(state, char_id, entity, target_name)

      ["/SUMMON", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Teleport.gm_summon(state, char_id, entity, target_name)

      # World
      ["/SPAWNITEM", item_str, amount_str] ->
        World.gm_spawn_item(state, char_id, entity, item_str, amount_str)

      ["/SPAWNITEM", item_str] ->
        World.gm_spawn_item(state, char_id, entity, item_str, "1")

      ["/RAIN"] ->
        World.gm_rain_toggle(state, char_id)

      ["/INVISIBLE"] ->
        World.gm_invisible(state, char_id, entity)

      ["/NIEVE"] ->
        World.gm_toggle_weather(state, char_id, :snow)

      ["/NIEBLA"] ->
        World.gm_toggle_weather(state, char_id, :fog)

      ["/MAPPK", flag] ->
        World.gm_change_map_flag(state, char_id, :pk, flag)

      ["/MAPNOMAGIC", flag] ->
        World.gm_change_map_flag(state, char_id, :no_magic, flag)

      ["/MAPNOINVI", flag] ->
        World.gm_change_map_flag(state, char_id, :no_invi, flag)

      ["/MAPNORESU", flag] ->
        World.gm_change_map_flag(state, char_id, :no_resu, flag)

      ["/TILEBLOCK"] ->
        World.gm_tile_block_toggle(state, char_id, entity)

      ["/SETTRIGGER", trigger_str] ->
        World.gm_set_trigger(state, char_id, entity, trigger_str)

      ["/ASKTRIGGER"] ->
        World.gm_ask_trigger(state, char_id, entity)

      ["/FORCEMIDIMAP", midi_str, map_str] ->
        World.gm_force_midi_map(state, char_id, midi_str, map_str)

      ["/FORCEWAVEMAP", wave_str, x_str, y_str | _rest] ->
        map_str = Enum.at(upper_parts, 4, "0")
        World.gm_force_wave_map(state, char_id, wave_str, x_str, y_str, map_str)

      ["/ITEMSFLOOR"] ->
        World.gm_items_in_floor(state, char_id)

      ["/DESTROYITEMS"] ->
        World.gm_destroy_items(state, char_id, entity)

      ["/DESTROYALLAREA"] ->
        World.gm_destroy_all_area(state, char_id, entity)

      ["/CLEANWORLD"] ->
        World.gm_clean_world(state, char_id)

      # Inspection
      ["/INFO", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_info(state, char_id, target_name)

      ["/LOCATE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_locate(state, char_id, target_name)

      ["/ONLINEMAP"] ->
        Inspection.gm_online_map(state, char_id)

      ["/ONLINE"] ->
        Inspection.gm_online(state, char_id)

      ["/WHERECHAR", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_wherechar(state, char_id, target_name)

      ["/IPCHAR", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_ipchar(state, char_id, target_name)

      ["/SYSTEMINFO"] ->
        Inspection.gm_system_info(state, char_id)

      ["/CHARSTATS", _name] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_char_stats(state, char_id, target_name)

      ["/CHARGOLD", _name] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_char_gold(state, char_id, target_name)

      ["/CHARINV", _name] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_char_inventory(state, char_id, target_name)

      ["/CHARBANK", _name] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_char_bank(state, char_id, target_name)

      ["/CHARSKILLS", _name] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_char_skills(state, char_id, target_name)

      ["/CHECKSLOT", _name, slot_str] ->
        target_name = Enum.at(parts, 1)
        Inspection.gm_check_slot(state, char_id, target_name, slot_str)

      ["/CREATURES", map_str] ->
        Inspection.gm_creatures_in_map(state, char_id, map_str)

      ["/SPAWNLIST"] ->
        Inspection.gm_spawn_list(state, char_id)

      # Moderation
      ["/KILL", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_kill(state, char_id, target_name)

      ["/KICK", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_kick(state, char_id, target_name)

      ["/BAN", _name_upper, days_str] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_ban(state, char_id, target_name, days_str)

      ["/MUTE", _name_upper, minutes_str] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_mute(state, char_id, target_name, minutes_str)

      ["/UNMUTE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_unmute(state, char_id, target_name)

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

        Moderation.gm_jail(state, char_id, target_name, minutes)

      ["/UNJAIL", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_unjail(state, char_id, target_name)

      ["/BANCUENTA", _name | _rest] ->
        target_name = Enum.at(parts, 1)
        reason = Enum.at(parts, 2, "Sin motivo")
        Moderation.gm_ban_cuenta(state, char_id, target_name, reason)

      ["/UNBANCUENTA", _name] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_unban_cuenta(state, char_id, target_name)

      ["/BANTEMPORAL", _name, days_str | _rest] ->
        target_name = Enum.at(parts, 1)
        reason = Enum.at(parts, 3, "Sin motivo")
        Moderation.gm_ban_temporal(state, char_id, target_name, days_str, reason)

      ["/REMOVEPUNISHMENT", _name, num_str | _rest] ->
        target_name = Enum.at(parts, 1)
        text = Enum.at(parts, 3, "")
        Moderation.gm_remove_punishment(state, char_id, target_name, num_str, text)

      ["/COUNCILKICK", _name] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_council_kick(state, char_id, target_name)

      ["/ROYALKICK", _name] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_faction_kick(state, char_id, target_name, :royal_army)

      ["/CHAOSKICK", _name] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_faction_kick(state, char_id, target_name, :chaos_legion)

      ["/KICKALLCHARS"] ->
        Moderation.gm_kick_all_chars(state, char_id)

      ["/UNBAN", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_unban(state, char_id, target_name)

      ["/NAVIGANDO", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_navigando(state, char_id, target_name)

      ["/RMCRIMINAL", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_rm_criminal(state, char_id, target_name)

      ["/RMCITIZEN", _name_upper] ->
        target_name = Enum.at(parts, 1)
        Moderation.gm_rm_citizen(state, char_id, target_name)

      # CharEdit
      ["/GIVEITEM", _name, item_str, amount_str] ->
        target_name = Enum.at(parts, 1)
        CharEdit.gm_give_item(state, char_id, target_name, item_str, amount_str)

      ["/EDITCHAR", _name, option_str, arg1] ->
        target_name = Enum.at(parts, 1)
        CharEdit.gm_edit_char(state, char_id, target_name, option_str, arg1)

      ["/ALTERNAME", _old, _new] ->
        old_name = Enum.at(parts, 1)
        new_name = Enum.at(parts, 2)
        CharEdit.gm_alter_name(state, char_id, old_name, new_name)

      ["/REVIVE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        CharEdit.gm_revive(state, char_id, target_name)

      ["/SHOWNAME"] ->
        CharEdit.gm_show_name(state, char_id, entity)

      ["/SETDESC" | _rest] ->
        desc = String.trim_leading(String.trim(message), "/SETDESC ")
        CharEdit.gm_set_description(state, char_id, entity, desc)

      ["/SETSPEED", speed_str] ->
        CharEdit.gm_set_speed(state, char_id, entity, speed_str)

      ["/SETBODY", _name, body_str] ->
        target_name = Enum.at(parts, 1)
        CharEdit.gm_set_body(state, char_id, target_name, body_str)

      ["/SETHEAD", _name, head_str] ->
        target_name = Enum.at(parts, 1)
        CharEdit.gm_set_head(state, char_id, target_name, head_str)

      ["/SETSKIN", _name, body_str] ->
        target_name = Enum.at(parts, 1)
        CharEdit.gm_set_body(state, char_id, target_name, body_str)

      ["/SETGOLD", _name, gold_str] ->
        target_name = Enum.at(parts, 1)
        CharEdit.gm_set_gold(state, char_id, target_name, gold_str)

      ["/SETLEVEL", _name, level_str] ->
        target_name = Enum.at(parts, 1)
        CharEdit.gm_set_level(state, char_id, target_name, level_str)

      ["/SETSKILL", _name, _skill_str, value_str] ->
        target_name = Enum.at(parts, 1)
        skill_name = Enum.at(parts, 2)
        CharEdit.gm_set_skill(state, char_id, target_name, skill_name, value_str)

      # Events
      ["/SPAWNNPC", npc_id_str] ->
        Events.gm_spawn_npc(state, char_id, entity, npc_id_str)

      ["/SPAWN", npc_id_str] ->
        Events.gm_spawn_npc(state, char_id, entity, npc_id_str)

      ["/SPAWNNPCR", npc_id_str] ->
        Events.gm_spawn_npc_respawn(state, char_id, entity, npc_id_str)

      ["/KILLNPC"] ->
        Events.gm_kill_npc(state, char_id, entity)

      ["/KILLNPCPERM"] ->
        Events.gm_kill_npc_permanent(state, char_id, entity)

      ["/MASSKILL"] ->
        Events.gm_mass_kill_npcs(state, char_id, entity)

      ["/RMSG" | _rest] ->
        msg_text = String.trim_leading(String.trim(message), "/RMSG ")
        Events.gm_faction_message(state, char_id, :royal_army, msg_text)

      ["/CMSG" | _rest] ->
        msg_text = String.trim_leading(String.trim(message), "/CMSG ")
        Events.gm_faction_message(state, char_id, :chaos_legion, msg_text)

      ["/TALKASNPC" | _rest] ->
        msg_text = String.trim_leading(String.trim(message), "/TALKASNPC ")
        Events.gm_talk_as_npc(state, char_id, entity, msg_text)

      ["/INVASION", map_str, npc_str, count_str] ->
        Events.gm_invasion(state, char_id, entity, map_str, npc_str, count_str)

      ["/INVASION", "STOP", map_str] ->
        Events.gm_invasion_stop(state, char_id, map_str)

      ["/INVASION", "LIST"] ->
        Events.gm_invasion_list(state, char_id)

      ["/TOURNAMENT", "START" | rest] ->
        max_str = List.first(rest) || "16"
        Events.gm_tournament_start(state, char_id, entity, max_str)

      ["/TOURNAMENT", "BEGIN"] ->
        Events.gm_tournament_begin(state, char_id)

      ["/TOURNAMENT", "CANCEL"] ->
        Events.gm_tournament_cancel(state, char_id)

      ["/TOURNAMENT", "STATUS"] ->
        Events.gm_tournament_status(state, char_id)

      ["/EVENT", "START", type_str, duration_str] ->
        Events.gm_event_start(state, char_id, entity, type_str, duration_str)

      ["/EVENT", "STOP", type_str] ->
        Events.gm_event_stop(state, char_id, type_str)

      ["/EVENT", "LIST"] ->
        Events.gm_event_list(state, char_id)

      ["/ROYALCOUNCIL", _name] ->
        target_name = Enum.at(parts, 1)
        Events.gm_accept_council(state, char_id, target_name, :royal)

      ["/CHAOSCOUNCIL", _name] ->
        target_name = Enum.at(parts, 1)
        Events.gm_accept_council(state, char_id, target_name, :chaos)

      _ ->
        Helpers.gm_console(state, char_id, "Unknown GM command: #{message}")
        {:noreply, state}
    end
  end
end
