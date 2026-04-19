defmodule AoTcpGateway.SessionCommands.Gm do
  @moduledoc """
  GM command handlers for binary UI packets.

  All commands require `state.is_gm == true` (enforced by the router in SessionLogic).
  Most commands route to `Arena.Map.MapServer.chat/3` as equivalent text commands,
  which are then handled by the Arena.Map.Gm.* modules.
  """

  require Logger

  # ---- Character Warping ----

  def handle_command(state, {:go_to_char, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/GOTO #{name}")
    {state, []}
  end

  def handle_command(state, {:warp_me_to_target, _}) do
    if state.target_x != nil and state.target_y != nil do
      Arena.Map.MapServer.chat(
        state.map_id,
        state.character_id,
        "/TELEPORT #{state.map_id} #{state.target_x} #{state.target_y}"
      )

      {state, []}
    else
      {state,
       [
         {:console_msg,
          %{message: "Primero selecciona un objetivo con click izquierdo.", font_index: 0}}
       ]}
    end
  end

  def handle_command(state, {:warp_char, %{name: _name, map: map}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/TELEPORT #{map} 50 50")
    {state, []}
  end

  def handle_command(state, {:invisible, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/INVISIBLE")
    {state, []}
  end

  def handle_command(state, {:silence, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MUTE #{name} 10")
    {state, []}
  end

  def handle_command(state, {:jail, %{name: name, reason: _reason, minutes: minutes}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/JAIL #{name} #{minutes}")
    {state, []}
  end

  def handle_command(state, {:kick, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KICK #{name}")
    {state, []}
  end

  def handle_command(state, {:execute, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KILL #{name}")
    {state, []}
  end

  def handle_command(state, {:ban_char, %{name: name, reason: _reason}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/BAN #{name} 30")
    {state, []}
  end

  def handle_command(state, {:unban_char, %{name: name}}) do
    case GameBackend.Characters.get_by_name(name) do
      nil ->
        {state, [{:console_msg, %{message: "Personaje '#{name}' no encontrado.", font_index: 0}}]}

      character ->
        case GameBackend.Account.unban(character.account_id) do
          {:ok, _} ->
            {state, [{:console_msg, %{message: "#{name} ha sido desbaneado.", font_index: 0}}]}

          {:error, reason} ->
            {state,
             [{:console_msg, %{message: "Error al desbanear: #{inspect(reason)}", font_index: 0}}]}
        end
    end
  end

  def handle_command(state, {:revive_char, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/REVIVE #{name}")
    {state, []}
  end

  def handle_command(state, {:summon_char, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/LOCATE #{name}")
    {state, []}
  end

  # ---- NPC Management ----

  def handle_command(state, {:kill_npc, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KILLNPC")
    {state, []}
  end

  def handle_command(state, {:kill_npc_targeted, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KILLNPC")
    {state, []}
  end

  def handle_command(state, {:kill_npc_no_respawn, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KILLNPCPERM")
    {state, []}
  end

  def handle_command(state, {:kill_all_nearby_npcs, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MASSKILL")
    {state, []}
  end

  def handle_command(state, {:create_npc, %{npc_id: npc_id}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNNPC #{npc_id}")
    {state, []}
  end

  def handle_command(state, {:create_npc_with_respawn, %{npc_id: npc_id}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNNPCR #{npc_id}")
    {state, []}
  end

  def handle_command(state, {:spawn_creature, %{creature_id: creature_id}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNNPC #{creature_id}")
    {state, []}
  end

  def handle_command(state, {:spawn_list_request, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNLIST")
    {state, []}
  end

  def handle_command(state, {:creatures_in_map, %{map: map}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CREATURES #{map}")
    {state, []}
  end

  # ---- Character Info ----

  def handle_command(state, {:request_char_info, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/INFO #{name}")
    {state, []}
  end

  def handle_command(state, {:where, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/LOCATE #{name}")
    {state, []}
  end

  # ---- GM Communication ----

  # FONTTYPE_GMMSG = 16 in the VB6 e_FontTypeNames enum (0-based).
  @fonttype_gmmsg 16

  def handle_command(state, {:gm_message, %{message: message}}) do
    if byte_size(message) > 0 do
      sender_name = state.entity.name
      broadcast_msg = sender_name <> " > " <> message

      Logger.info("GM audit: #{sender_name} sent GM message: #{message}")

      raw =
        AoProtocol.Server.Encoder.encode(
          {:console_msg, %{message: broadcast_msg, font_index: @fonttype_gmmsg}}
        )

      AoSession.OnlineDirectory.broadcast_to_gms({:send_raw, raw})
    end

    {state, []}
  end

  def handle_command(state, {:server_message, %{message: message}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, message)
    {state, []}
  end

  def handle_command(state, {:online_gm, _}) do
    count = AoSession.OnlineDirectory.online_count()
    {state, [{:console_msg, %{message: "GMs en linea: #{count}", font_index: 0}}]}
  end

  def handle_command(state, {:rain_toggle, _}) do
    Arena.WorldWeather.toggle_rain()
    {state, []}
  end

  # ---- Item Creation ----

  def handle_command(state, {:create_item, %{item_id: item_id, amount: amount}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNITEM #{item_id} #{amount}")
    {state, []}
  end

  def handle_command(
        state,
        {:give_item, %{name: name, item_id: item_id, amount: amount, reason: _reason}}
      ) do
    Arena.Map.MapServer.chat(
      state.map_id,
      state.character_id,
      "/GIVEITEM #{name} #{item_id} #{amount}"
    )

    {state, []}
  end

  # ---- Character Stats ----

  def handle_command(state, {:request_char_stats, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARSTATS #{name}")
    {state, []}
  end

  def handle_command(state, {:request_char_gold, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARGOLD #{name}")
    {state, []}
  end

  def handle_command(state, {:request_char_inventory, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARINV #{name}")
    {state, []}
  end

  def handle_command(state, {:request_char_bank, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARBANK #{name}")
    {state, []}
  end

  def handle_command(state, {:request_char_skills, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARSKILLS #{name}")
    {state, []}
  end

  def handle_command(state, {:edit_char, %{name: name, option: option, arg1: arg1, arg2: _arg2}}) do
    Arena.Map.MapServer.chat(
      state.map_id,
      state.character_id,
      "/EDITCHAR #{name} #{option} #{arg1}"
    )

    {state, []}
  end

  def handle_command(state, {:alter_name, %{name: name, new_name: new_name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ALTERNAME #{name} #{new_name}")
    {state, []}
  end

  # ---- Punishment ----

  def handle_command(state, {:ban_cuenta, %{name: name, reason: reason}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/BANCUENTA #{name} #{reason}")
    {state, []}
  end

  def handle_command(state, {:unban_cuenta, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/UNBANCUENTA #{name}")
    {state, []}
  end

  def handle_command(state, {:ban_temporal, %{name: name, reason: reason, days: days}}) do
    Arena.Map.MapServer.chat(
      state.map_id,
      state.character_id,
      "/BANTEMPORAL #{name} #{days} #{reason}"
    )

    {state, []}
  end

  def handle_command(state, {:remove_punishment, %{name: name, num: num, text: text}}) do
    Arena.Map.MapServer.chat(
      state.map_id,
      state.character_id,
      "/REMOVEPUNISHMENT #{name} #{num} #{text}"
    )

    {state, []}
  end

  # ---- Faction Communication (GM) ----

  def handle_command(state, {:royal_army_message, %{message: message}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/RMSG #{message}")
    {state, []}
  end

  def handle_command(state, {:chaos_legion_message, %{message: message}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CMSG #{message}")
    {state, []}
  end

  def handle_command(state, {:talk_as_npc, %{message: message}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/TALKASNPC #{message}")
    {state, []}
  end

  # ---- Map & Environment ----

  def handle_command(state, {:nieve_toggle, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/NIEVE")
    {state, []}
  end

  def handle_command(state, {:niebla_toggle, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/NIEBLA")
    {state, []}
  end

  def handle_command(state, {:change_map_pk, %{value: value}}) do
    flag = if value, do: "1", else: "0"
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MAPPK #{flag}")
    {state, []}
  end

  def handle_command(state, {:change_map_no_magic, %{value: value}}) do
    flag = if value, do: "1", else: "0"
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MAPNOMAGIC #{flag}")
    {state, []}
  end

  def handle_command(state, {:change_map_no_invi, %{value: value}}) do
    flag = if value, do: "1", else: "0"
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MAPNOINVI #{flag}")
    {state, []}
  end

  def handle_command(state, {:change_map_no_resu, %{value: value}}) do
    flag = if value, do: "1", else: "0"
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MAPNORESU #{flag}")
    {state, []}
  end

  def handle_command(state, {:tile_blocked_toggle, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/TILEBLOCK")
    {state, []}
  end

  def handle_command(state, {:set_trigger, %{trigger: trigger}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SETTRIGGER #{trigger}")
    {state, []}
  end

  def handle_command(state, {:ask_trigger, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ASKTRIGGER")
    {state, []}
  end

  # ---- Audio ----

  def handle_command(state, {:force_midi_all, %{midi: midi}}) do
    raw = AoProtocol.Server.Encoder.encode({:play_midi, %{midi: midi, loops: -1}})
    AoSession.OnlineDirectory.broadcast_all({:send_raw, raw})
    {state, [{:console_msg, %{message: "MIDI #{midi} enviado a todos.", font_index: 0}}]}
  end

  def handle_command(state, {:force_wave_all, %{wave: wave}}) do
    raw = AoProtocol.Server.Encoder.encode({:play_wave, %{wave: wave, x: 0, y: 0}})
    AoSession.OnlineDirectory.broadcast_all({:send_raw, raw})
    {state, [{:console_msg, %{message: "Wave #{wave} enviado a todos.", font_index: 0}}]}
  end

  def handle_command(state, {:force_midi_map, %{midi: midi, map: map}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/FORCEMIDIMAP #{midi} #{map}")
    {state, []}
  end

  def handle_command(state, {:force_wave_map, %{wave: wave, x: x, y: y, map: map}}) do
    Arena.Map.MapServer.chat(
      state.map_id,
      state.character_id,
      "/FORCEWAVEMAP #{wave} #{x} #{y} #{map}"
    )

    {state, []}
  end

  # ---- Utility ----

  def handle_command(state, {:items_in_floor, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ITEMSFLOOR")
    {state, []}
  end

  def handle_command(state, {:destroy_items, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/DESTROYITEMS")
    {state, []}
  end

  def handle_command(state, {:destroy_all_area, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/DESTROYALLAREA")
    {state, []}
  end

  def handle_command(state, {:clean_world, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CLEANWORLD")
    {state, []}
  end

  def handle_command(state, {:show_name, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SHOWNAME")
    {state, []}
  end

  def handle_command(state, {:set_description, %{desc: desc}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SETDESC #{desc}")
    {state, []}
  end

  def handle_command(state, {:set_speed, %{speed: speed}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SETSPEED #{speed}")
    {state, []}
  end

  def handle_command(state, {:nick_to_ip, %{name: name}}) do
    case AoSession.OnlineDirectory.lookup_by_name(name) do
      {:ok, session} ->
        ip = Map.get(session, :ip, "desconocida")
        {state, [{:console_msg, %{message: "IP de #{name}: #{ip}", font_index: 0}}]}

      :not_found ->
        {state, [{:console_msg, %{message: "Jugador #{name} no encontrado.", font_index: 0}}]}
    end
  end

  def handle_command(state, {:ip_to_nick, %{ip: ip}}) do
    names = AoSession.OnlineDirectory.list_all_names()

    {state,
     [{:console_msg, %{message: "Busqueda IP #{ip}: #{Enum.join(names, ", ")}", font_index: 0}}]}
  end

  def handle_command(state, {:check_slot, %{name: name, slot: slot}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHECKSLOT #{name} #{slot}")
    {state, []}
  end

  # ---- Faction/Council ----

  def handle_command(state, {:council_kick, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/COUNCILKICK #{name}")
    {state, []}
  end

  def handle_command(state, {:accept_royal_council, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ROYALCOUNCIL #{name}")
    {state, []}
  end

  def handle_command(state, {:accept_chaos_council, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHAOSCOUNCIL #{name}")
    {state, []}
  end

  def handle_command(state, {:royal_army_kick, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ROYALKICK #{name}")
    {state, []}
  end

  def handle_command(state, {:chaos_legion_kick, %{name: name}}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHAOSKICK #{name}")
    {state, []}
  end

  # ---- SOS (support request tracking) ----
  # VB6 parity: SOS was a GM-visible queue of player /GM requests.
  # In this server, support requests are handled via QuestionGM / RoleMasterRequest
  # and logged through AuditLog. These stubs acknowledge the GM commands but the
  # underlying queue is not yet implemented — support requests go to Logger only.

  def handle_command(state, {:sos_show_list, _}) do
    requests = AoSession.SosQueue.list_requests()

    if requests == [] do
      {state, [{:console_msg, %{message: "Lista de SOS: (vacia)", font_index: 0}}]}
    else
      header = {:console_msg, %{message: "Lista de SOS (#{length(requests)}):", font_index: 0}}

      entries =
        requests
        |> Enum.with_index(1)
        |> Enum.map(fn {req, idx} ->
          {:console_msg,
           %{message: "#{idx}. #{req.name}: #{req.message}", font_index: 0}}
        end)

      {state, [header | entries]}
    end
  end

  def handle_command(state, {:sos_remove, %{name: name}}) do
    case AoSession.SosQueue.remove_request(name) do
      :ok ->
        {state, [{:console_msg, %{message: "SOS de #{name} removido.", font_index: 0}}]}

      {:error, :not_found} ->
        {state,
         [{:console_msg, %{message: "No se encontro SOS de #{name}.", font_index: 0}}]}
    end
  end

  def handle_command(state, {:clean_sos, _}) do
    AoSession.SosQueue.clear()
    {state, [{:console_msg, %{message: "Lista de SOS limpiada.", font_index: 0}}]}
  end

  # ---- Server Admin ----

  def handle_command(state, {:online, _}) do
    names = AoSession.OnlineDirectory.list_all_names()
    count = length(names)
    name_list = Enum.join(names, ", ")

    {state,
     [{:console_msg, %{message: "Jugadores online (#{count}): #{name_list}", font_index: 0}}]}
  end

  def handle_command(state, {:online_map, _}) do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ONLINEMAP")
    {state, []}
  end

  def handle_command(state, {:kick_all_chars, _}) do
    AoSession.OnlineDirectory.broadcast_all(:disconnect)

    {state,
     [{:console_msg, %{message: "Todos los jugadores han sido expulsados.", font_index: 0}}]}
  end

  def handle_command(state, {:server_open_toggle, _}) do
    current = Arena.Settings.get(:server_open, true)
    new_value = not current
    Arena.Settings.set(:server_open, new_value)

    msg =
      if new_value,
        do: "Servidor abierto a nuevas conexiones.",
        else: "Servidor cerrado a nuevas conexiones."

    Logger.info("GM audit: #{state.entity.name} toggled server_open to #{new_value}")
    {state, [{:console_msg, %{message: msg, font_index: 0}}]}
  end

  def handle_command(state, {:save_chars, _}) do
    AoSession.OnlineDirectory.broadcast_all(:force_save)
    {state, [{:console_msg, %{message: "Guardado de personajes iniciado.", font_index: 0}}]}
  end

  def handle_command(state, {:global_message, %{message: message}}) do
    if byte_size(message) > 0 do
      raw =
        AoProtocol.Server.Encoder.encode(
          {:console_msg, %{message: "Servidor> #{message}", font_index: 0}}
        )

      AoSession.OnlineDirectory.broadcast_all({:send_raw, raw})
    end

    {state, []}
  end
end
