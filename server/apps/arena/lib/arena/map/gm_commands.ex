defmodule Arena.Map.GmCommands do
  @moduledoc """
  GM command parser/router. Dispatches to family modules.

  Public surface returns `{:ok, state, [Effect.t()]}`. Sub-handler family
  modules (`Arena.Map.Gm.*`) are migrated independently — until they all
  speak the effects contract, calls into them are wrapped in
  `bridge_legacy/2`, which runs the legacy `{:noreply, _}` /
  `{:reply, _, _}` body inline (its `{:send_raw, _}` packets fire through
  the legacy shim) and surfaces zero effects. Once a sub-handler migrates,
  remove its bridge call so the effects flow through the canonical runner.
  """

  alias Arena.Map.Effects
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
          {:ok, state, [Effects.send(char_id, console(reason))]}
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

  # Strips the leading slash command from `message` case-insensitively and
  # returns the remainder. VB6 `/RMSG` / `/CMSG` / `/TALKASNPC` arrive as
  # binary packets (Protocol.bas:5177-5209), so VB6 never sees the command
  # token at all. In Elixir the dispatcher uppercases for matching but the
  # original message preserves user case; extract the body by splitting on
  # whitespace so any case of the prefix is stripped.
  defp extract_command_body(message) do
    message
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> case do
      [_cmd, rest] -> rest
      [_cmd] -> ""
      [] -> ""
    end
  end

  def handle_gm_rain_toggle(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.gm ->
        new_rain = not state.meta.rain
        meta = %{state.meta | rain: new_rain}
        state = %{state | meta: meta}

        rain_packet = Encoder.encode({:rain_toggle, %{raining: new_rain}})

        # Fan to every session on the map (rain is map-global, not AoI-scoped).
        broadcast = Effects.broadcast_map(rain_packet)

        label = if new_rain, do: "ON", else: "OFF"
        feedback = Effects.send(char_id, console("Rain toggled #{label} on this map."))

        {:ok, state, [broadcast, feedback]}

      {:ok, _entity} ->
        {:ok, state, [Effects.send(char_id, console("You are not a GM."))]}

      :error ->
        {:ok, state, []}
    end
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  # Runs a sub-handler that is still on the legacy GenServer contract
  # (`{:noreply, _}` / `{:reply, _, _}`), discards the reply, and surfaces
  # zero effects. Sub-handlers' `{:send_raw, _}` calls fire through the
  # legacy shim before this returns; once the sub-handler migrates to
  # `{:ok, state, effects}`, drop the bridge wrapper at the call site.
  #
  # Bridge — sub-handlers in Arena.Map.Gm.* not yet migrated.
  defp bridge_legacy(default_state, fun) do
    case fun.() do
      {:reply, _result, new_state} -> {:ok, new_state, []}
      {:noreply, new_state} -> {:ok, new_state, []}
      {:ok, new_state, effects} when is_list(effects) -> {:ok, new_state, effects}
      _ -> {:ok, default_state, []}
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
        bridge_legacy(state, fn ->
          Teleport.gm_teleport(state, char_id, entity, map_str, x_str, y_str)
        end)

      ["/GOTO", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Teleport.gm_goto(state, char_id, entity, target_name) end)

      ["/SUMMON", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Teleport.gm_summon(state, char_id, entity, target_name) end)

      # World
      ["/SPAWNITEM", item_str, amount_str] ->
        bridge_legacy(state, fn ->
          World.gm_spawn_item(state, char_id, entity, item_str, amount_str)
        end)

      ["/SPAWNITEM", item_str] ->
        bridge_legacy(state, fn ->
          World.gm_spawn_item(state, char_id, entity, item_str, "1")
        end)

      ["/RAIN"] ->
        bridge_legacy(state, fn -> World.gm_rain_toggle(state, char_id) end)

      ["/INVISIBLE"] ->
        bridge_legacy(state, fn -> World.gm_invisible(state, char_id, entity) end)

      ["/NIEVE"] ->
        bridge_legacy(state, fn -> World.gm_toggle_weather(state, char_id, :snow) end)

      ["/NIEBLA"] ->
        bridge_legacy(state, fn -> World.gm_toggle_weather(state, char_id, :fog) end)

      ["/MAPPK", flag] ->
        bridge_legacy(state, fn -> World.gm_change_map_flag(state, char_id, :pk, flag) end)

      ["/MAPNOMAGIC", flag] ->
        bridge_legacy(state, fn -> World.gm_change_map_flag(state, char_id, :no_magic, flag) end)

      ["/MAPNOINVI", flag] ->
        bridge_legacy(state, fn -> World.gm_change_map_flag(state, char_id, :no_invi, flag) end)

      ["/MAPNORESU", flag] ->
        bridge_legacy(state, fn -> World.gm_change_map_flag(state, char_id, :no_resu, flag) end)

      ["/TILEBLOCK"] ->
        bridge_legacy(state, fn -> World.gm_tile_block_toggle(state, char_id, entity) end)

      ["/SETTRIGGER", trigger_str] ->
        bridge_legacy(state, fn ->
          World.gm_set_trigger(state, char_id, entity, trigger_str)
        end)

      ["/ASKTRIGGER"] ->
        bridge_legacy(state, fn -> World.gm_ask_trigger(state, char_id, entity) end)

      ["/FORCEMIDIMAP", midi_str, map_str] ->
        bridge_legacy(state, fn ->
          World.gm_force_midi_map(state, char_id, midi_str, map_str)
        end)

      ["/FORCEWAVEMAP", wave_str, x_str, y_str | _rest] ->
        map_str = Enum.at(upper_parts, 4, "0")

        bridge_legacy(state, fn ->
          World.gm_force_wave_map(state, char_id, wave_str, x_str, y_str, map_str)
        end)

      ["/ITEMSFLOOR"] ->
        bridge_legacy(state, fn -> World.gm_items_in_floor(state, char_id) end)

      ["/DESTROYITEMS"] ->
        bridge_legacy(state, fn -> World.gm_destroy_items(state, char_id, entity) end)

      ["/DESTROYALLAREA"] ->
        bridge_legacy(state, fn -> World.gm_destroy_all_area(state, char_id, entity) end)

      ["/CLEANWORLD"] ->
        bridge_legacy(state, fn -> World.gm_clean_world(state, char_id) end)

      # Inspection
      ["/INFO", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Inspection.gm_info(state, char_id, target_name) end)

      ["/LOCATE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Inspection.gm_locate(state, char_id, target_name) end)

      ["/ONLINEMAP"] ->
        bridge_legacy(state, fn -> Inspection.gm_online_map(state, char_id) end)

      ["/ONLINE"] ->
        bridge_legacy(state, fn -> Inspection.gm_online(state, char_id) end)

      ["/WHERECHAR", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Inspection.gm_wherechar(state, char_id, target_name) end)

      ["/IPCHAR", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Inspection.gm_ipchar(state, char_id, target_name) end)

      ["/SYSTEMINFO"] ->
        bridge_legacy(state, fn -> Inspection.gm_system_info(state, char_id) end)

      ["/CHARSTATS", _name] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Inspection.gm_char_stats(state, char_id, target_name) end)

      ["/CHARGOLD", _name] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Inspection.gm_char_gold(state, char_id, target_name) end)

      ["/CHARINV", _name] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Inspection.gm_char_inventory(state, char_id, target_name) end)

      ["/CHARBANK", _name] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Inspection.gm_char_bank(state, char_id, target_name) end)

      ["/CHARSKILLS", _name] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Inspection.gm_char_skills(state, char_id, target_name) end)

      ["/CHECKSLOT", _name, slot_str] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          Inspection.gm_check_slot(state, char_id, target_name, slot_str)
        end)

      ["/CREATURES", map_str] ->
        bridge_legacy(state, fn -> Inspection.gm_creatures_in_map(state, char_id, map_str) end)

      ["/SPAWNLIST"] ->
        bridge_legacy(state, fn -> Inspection.gm_spawn_list(state, char_id) end)

      # Moderation
      ["/KILL", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_kill(state, char_id, target_name) end)

      ["/KICK", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_kick(state, char_id, target_name) end)

      ["/BAN", _name_upper, days_str] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_ban(state, char_id, target_name, days_str) end)

      ["/MUTE", _name_upper, minutes_str] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          Moderation.gm_mute(state, char_id, target_name, minutes_str)
        end)

      ["/UNMUTE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_unmute(state, char_id, target_name) end)

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

        bridge_legacy(state, fn ->
          Moderation.gm_jail(state, char_id, target_name, minutes)
        end)

      ["/UNJAIL", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_unjail(state, char_id, target_name) end)

      ["/BANCUENTA", _name | _rest] ->
        target_name = Enum.at(parts, 1)
        reason = Enum.at(parts, 2, "Sin motivo")

        bridge_legacy(state, fn ->
          Moderation.gm_ban_cuenta(state, char_id, target_name, reason)
        end)

      ["/UNBANCUENTA", _name] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_unban_cuenta(state, char_id, target_name) end)

      ["/BANTEMPORAL", _name, days_str | _rest] ->
        target_name = Enum.at(parts, 1)
        reason = Enum.at(parts, 3, "Sin motivo")

        bridge_legacy(state, fn ->
          Moderation.gm_ban_temporal(state, char_id, target_name, days_str, reason)
        end)

      ["/REMOVEPUNISHMENT", _name, num_str | _rest] ->
        target_name = Enum.at(parts, 1)
        text = Enum.at(parts, 3, "")

        bridge_legacy(state, fn ->
          Moderation.gm_remove_punishment(state, char_id, target_name, num_str, text)
        end)

      ["/COUNCILKICK", _name] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_council_kick(state, char_id, target_name) end)

      ["/ROYALKICK", _name] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          Moderation.gm_faction_kick(state, char_id, target_name, :royal_army)
        end)

      ["/CHAOSKICK", _name] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          Moderation.gm_faction_kick(state, char_id, target_name, :chaos_legion)
        end)

      ["/KICKALLCHARS"] ->
        bridge_legacy(state, fn -> Moderation.gm_kick_all_chars(state, char_id) end)

      ["/UNBAN", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_unban(state, char_id, target_name) end)

      ["/NAVIGANDO", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_navigando(state, char_id, target_name) end)

      ["/RMCRIMINAL", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_rm_criminal(state, char_id, target_name) end)

      ["/RMCITIZEN", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> Moderation.gm_rm_citizen(state, char_id, target_name) end)

      # CharEdit
      ["/GIVEITEM", _name, item_str, amount_str] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          CharEdit.gm_give_item(state, char_id, target_name, item_str, amount_str)
        end)

      ["/EDITCHAR", _name, option_str, arg1] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          CharEdit.gm_edit_char(state, char_id, target_name, option_str, arg1)
        end)

      ["/ALTERNAME", _old, _new] ->
        old_name = Enum.at(parts, 1)
        new_name = Enum.at(parts, 2)

        bridge_legacy(state, fn ->
          CharEdit.gm_alter_name(state, char_id, old_name, new_name)
        end)

      ["/REVIVE", _name_upper] ->
        target_name = Enum.at(parts, 1)
        bridge_legacy(state, fn -> CharEdit.gm_revive(state, char_id, target_name) end)

      ["/SHOWNAME"] ->
        bridge_legacy(state, fn -> CharEdit.gm_show_name(state, char_id, entity) end)

      ["/SETDESC" | _rest] ->
        desc = String.trim_leading(String.trim(message), "/SETDESC ")

        bridge_legacy(state, fn ->
          CharEdit.gm_set_description(state, char_id, entity, desc)
        end)

      ["/SETSPEED", speed_str] ->
        bridge_legacy(state, fn ->
          CharEdit.gm_set_speed(state, char_id, entity, speed_str)
        end)

      ["/SETBODY", _name, body_str] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          CharEdit.gm_set_body(state, char_id, target_name, body_str)
        end)

      ["/SETHEAD", _name, head_str] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          CharEdit.gm_set_head(state, char_id, target_name, head_str)
        end)

      ["/SETSKIN", _name, body_str] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          CharEdit.gm_set_body(state, char_id, target_name, body_str)
        end)

      ["/SETGOLD", _name, gold_str] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          CharEdit.gm_set_gold(state, char_id, target_name, gold_str)
        end)

      ["/SETLEVEL", _name, level_str] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          CharEdit.gm_set_level(state, char_id, target_name, level_str)
        end)

      ["/SETSKILL", _name, _skill_str, value_str] ->
        target_name = Enum.at(parts, 1)
        skill_name = Enum.at(parts, 2)

        bridge_legacy(state, fn ->
          CharEdit.gm_set_skill(state, char_id, target_name, skill_name, value_str)
        end)

      # Events
      ["/SPAWNNPC", npc_id_str] ->
        bridge_legacy(state, fn -> Events.gm_spawn_npc(state, char_id, entity, npc_id_str) end)

      ["/SPAWN", npc_id_str] ->
        bridge_legacy(state, fn -> Events.gm_spawn_npc(state, char_id, entity, npc_id_str) end)

      ["/SPAWNNPCR", npc_id_str] ->
        bridge_legacy(state, fn ->
          Events.gm_spawn_npc_respawn(state, char_id, entity, npc_id_str)
        end)

      ["/KILLNPC"] ->
        bridge_legacy(state, fn -> Events.gm_kill_npc(state, char_id, entity) end)

      ["/KILLNPCPERM"] ->
        bridge_legacy(state, fn -> Events.gm_kill_npc_permanent(state, char_id, entity) end)

      ["/MASSKILL"] ->
        bridge_legacy(state, fn -> Events.gm_mass_kill_npcs(state, char_id, entity) end)

      ["/RMSG" | _rest] ->
        msg_text = extract_command_body(message)

        bridge_legacy(state, fn ->
          Events.gm_faction_message(state, char_id, :royal_army, msg_text)
        end)

      ["/CMSG" | _rest] ->
        msg_text = extract_command_body(message)

        bridge_legacy(state, fn ->
          Events.gm_faction_message(state, char_id, :chaos_legion, msg_text)
        end)

      ["/TALKASNPC" | _rest] ->
        msg_text = extract_command_body(message)

        bridge_legacy(state, fn ->
          Events.gm_talk_as_npc(state, char_id, entity, msg_text)
        end)

      ["/INVASION", map_str, npc_str, count_str] ->
        bridge_legacy(state, fn ->
          Events.gm_invasion(state, char_id, entity, map_str, npc_str, count_str)
        end)

      ["/INVASION", "STOP", map_str] ->
        bridge_legacy(state, fn -> Events.gm_invasion_stop(state, char_id, map_str) end)

      ["/INVASION", "LIST"] ->
        bridge_legacy(state, fn -> Events.gm_invasion_list(state, char_id) end)

      ["/TOURNAMENT", "START" | rest] ->
        max_str = List.first(rest) || "16"

        bridge_legacy(state, fn ->
          Events.gm_tournament_start(state, char_id, entity, max_str)
        end)

      ["/TOURNAMENT", "BEGIN"] ->
        bridge_legacy(state, fn -> Events.gm_tournament_begin(state, char_id) end)

      ["/TOURNAMENT", "CANCEL"] ->
        bridge_legacy(state, fn -> Events.gm_tournament_cancel(state, char_id) end)

      ["/TOURNAMENT", "STATUS"] ->
        bridge_legacy(state, fn -> Events.gm_tournament_status(state, char_id) end)

      ["/EVENT", "START", type_str, duration_str] ->
        bridge_legacy(state, fn ->
          Events.gm_event_start(state, char_id, entity, type_str, duration_str)
        end)

      ["/EVENT", "STOP", type_str] ->
        bridge_legacy(state, fn -> Events.gm_event_stop(state, char_id, type_str) end)

      ["/EVENT", "LIST"] ->
        bridge_legacy(state, fn -> Events.gm_event_list(state, char_id) end)

      ["/ROYALCOUNCIL", _name] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          Events.gm_accept_council(state, char_id, target_name, :royal)
        end)

      ["/CHAOSCOUNCIL", _name] ->
        target_name = Enum.at(parts, 1)

        bridge_legacy(state, fn ->
          Events.gm_accept_council(state, char_id, target_name, :chaos)
        end)

      _ ->
        {:ok, state, [Effects.send(char_id, console("Unknown GM command: #{message}"))]}
    end
  end
end
