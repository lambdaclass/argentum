defmodule AoTcpGateway.SessionLogic do
  @moduledoc """
  Shared session lifecycle logic for TCP and WebSocket handlers.

  Functions operate on a session state map and return `{state, [packet_commands]}`
  where packet_commands are tuples that `AoProtocol.Server.Encoder` understands.
  Transport-specific concerns (sending bytes, framing) stay in each handler.
  """

  require Logger

  @default_map_id 1

  # ---- Login ----

  def login_existing(state, char_id, token) do
    case GameBackend.Characters.get(char_id) do
      nil ->
        {state, [{:error_msg, %{message: "Character not found."}}]}

      character ->
        if GameBackend.Characters.valid_token?(character, token) do
          do_login(state, character.account_id, character)
        else
          Logger.warning("Invalid session token for char_id #{char_id}")
          {state, [{:error_msg, %{message: "Invalid session token."}}]}
        end
    end
  end

  def login_new(state, params) do
    name = params.username
    password = params.session_token

    case GameBackend.Account.get_or_create(name, password) do
      {:error, :wrong_password} ->
        {state, [{:error_msg, %{message: "Wrong password."}}]}

      {:error, changeset} ->
        Logger.error("Account creation failed: #{inspect(changeset)}")
        {state, [{:error_msg, %{message: "Failed to create account."}}]}

      {:ok, account} ->
        if GameBackend.Characters.get_by_name(name) != nil do
          {state, [{:error_msg, %{message: "Character name already taken."}}]}
        else
          case Arena.CharacterCreation.create(%{
            name: name,
            race: params.race,
            gender: params.gender,
            class: params.class,
            head: params.head,
            home_city: params.home_city,
            account_id: account.id
          }) do
            {:ok, entity} ->
              attrs = GameBackend.Characters.from_entity(entity)
              inventory = GameBackend.Characters.inventory_from_entity(entity)
              equipment = GameBackend.Characters.equipment_from_entity(entity)
              skills = GameBackend.Characters.skills_from_entity(entity)
              spells = GameBackend.Characters.spells_from_entity(entity)

              case GameBackend.Characters.create(attrs,
                     inventory: inventory,
                     equipment: equipment,
                     skills: skills,
                     spells: spells
                   ) do
                {:ok, character} ->
                  do_login(state, account.id, character)

                {:error, changeset} ->
                  Logger.error("Failed to save new character: #{inspect(changeset)}")
                  {state, [{:error_msg, %{message: "Failed to create character."}}]}
              end

            {:error, reason} ->
              {state, [{:error_msg, %{message: creation_error_message(reason)}}]}
          end
        end
    end
  end

  defp do_login(state, account_id, character) do
    account = GameBackend.Repo.get(GameBackend.Account, account_id)

    if account != nil and GameBackend.Account.banned?(account) do
      formatted = Calendar.strftime(account.banned_until, "%Y-%m-%d %H:%M UTC")

      {state,
       [
         {:console_msg, %{message: "Tu cuenta está baneada hasta #{formatted}.", font_index: 0}},
         {:error_msg, %{message: "Account banned."}}
       ]}
    else
      entity = GameBackend.Characters.to_entity(character)
      char_id = entity.char_id

      case AoSession.register(account_id, char_id, self()) do
        :ok ->
          {state, packets} = enter_world(state, account_id, entity)

          if state.character_id do
            {state, packets}
          else
            AoSession.unregister(char_id)
            {state, packets}
          end

        {:error, :already_connected} ->
          Logger.warning("char_id #{char_id} already connected")
          {state, [{:error_msg, %{message: "Already connected."}}]}
      end
    end
  end

  # ---- Enter world ----

  def enter_world(state, account_id, entity) do
    map_id = entity.map_id || @default_map_id

    with :ok <- ensure_map_started(map_id),
         {:ok, char_index, all_players, weather} <-
           Arena.Map.MapServer.enter(map_id, entity, position: {entity.x, entity.y}) do
      entity = Map.get(all_players, entity.char_id)

      Logger.info(
        "#{entity.name} entered map #{map_id} at (#{entity.x}, #{entity.y}) index=#{char_index}"
      )

      state = %{
        state
        | account_id: account_id,
          character_id: entity.char_id,
          char_index: char_index,
          map_id: map_id,
          entity: entity,
          is_gm: entity.gm == true
      }

      global_rain = try do Arena.WorldWeather.raining?() rescue _ -> weather.rain catch :exit, _ -> weather.rain end
      weather_packets =
        (if global_rain, do: [{:rain_toggle, %{raining: true}}], else: []) ++
        (if weather.snow, do: [{:snow_toggle, %{snowing: true}}], else: [])

      packets =
        [
          {:logged, %{new_user: false}},
          {:user_index_in_server, %{user_index: 1}},
          {:change_map, %{map_id: map_id, version: 0}},
          {:user_char_index_in_server, %{char_index: char_index}},
          Arena.Map.Helpers.character_create_packet(entity),
          {:pos_update, %{x: entity.x, y: entity.y}},
          {:intervals, %{walk: 210}},
          {:update_hp, %{min_hp: entity.hp}},
          {:update_mana, %{min_mana: entity.mana}},
          {:update_stamina, %{min_sta: entity.stamina}},
          {:update_gold, %{gold: entity.gold}},
          {:update_hunger_and_thirst, %{
            max_hunger: 100,
            min_hunger: entity.hunger,
            max_thirst: 100,
            min_thirst: entity.thirst
          }}
        ] ++
          weather_packets ++
          exp_login_packets(entity) ++
          inventory_login_packets(entity) ++
          spell_login_packets(entity) ++
          skill_login_packets(entity) ++
          for {cid, other} <- all_players, cid != entity.char_id do
            Arena.Map.Helpers.character_create_packet(other)
          end ++
          [{:console_msg, %{message: "Welcome to Argentum Online!", font_index: 0}}]

      AoSession.OnlineDirectory.register(entity.char_id, entity.name, map_id, self())
      {state, packets}
    else
      {:error, reason} ->
        Logger.error("Failed to enter map #{map_id}: #{inspect(reason)}")
        {state, [{:error_msg, %{message: "Map not available. Try again later."}}]}
    end
  end

  # ---- Map transfer ----

  def transfer(state, dest_map, dest_x, dest_y, entity) do
    source_map = state.map_id

    with :ok <- ensure_map_started(dest_map),
         {:ok, char_index, all_players, weather} <-
           Arena.Map.MapServer.enter(dest_map, entity, position: {dest_x, dest_y}) do
      # Destination entry succeeded — now remove from source
      Arena.Map.MapServer.leave(source_map, entity.char_id)

      entity = Map.get(all_players, entity.char_id)

      Logger.info("#{entity.name} transferred to map #{dest_map} at (#{dest_x}, #{dest_y})")

      state = %{state | map_id: dest_map, char_index: char_index, entity: entity}

      global_rain = try do Arena.WorldWeather.raining?() rescue _ -> weather.rain catch :exit, _ -> weather.rain end
      weather_packets =
        (if global_rain, do: [{:rain_toggle, %{raining: true}}], else: [{:rain_toggle, %{raining: false}}]) ++
        (if weather.snow, do: [{:snow_toggle, %{snowing: true}}], else: [{:snow_toggle, %{snowing: false}}])

      packets =
        [
          {:change_map, %{map_id: dest_map, version: 0}},
          {:user_char_index_in_server, %{char_index: char_index}},
          Arena.Map.Helpers.character_create_packet(entity),
          {:pos_update, %{x: entity.x, y: entity.y}}
        ] ++
          weather_packets ++
          for {cid, other} <- all_players, cid != entity.char_id do
            Arena.Map.Helpers.character_create_packet(other)
          end

      AoSession.OnlineDirectory.update_map(state.character_id, dest_map)
      {state, packets}
    else
      {:error, reason} ->
        Logger.error("Failed to transfer to map #{dest_map}: #{inspect(reason)}")
        {state, [{:error_msg, %{message: "Destination map not available."}}]}
    end
  end

  # ---- Game commands ----

  def handle_command(state, {:walk, %{direction: direction}}) when state.character_id != nil do
    {state, cancel_packets} = maybe_cancel_hogar(state)
    Arena.Map.MapServer.move_character(state.map_id, state.character_id, direction)
    {state, cancel_packets}
  end

  def handle_command(state, {:walk, _}), do: {state, []}

  def handle_command(state, {:talk, %{message: message}}) when state.character_id != nil do
    case parse_party_command(message) do
      {:party_invite, target_name} ->
        case AoSession.OnlineDirectory.lookup_by_name(target_name) do
          {:ok, target_id, _info} ->
            Arena.PartyServer.invite(state.character_id, target_id)
          :not_found ->
            send_console(state, "Jugador no encontrado.")
        end
        {state, []}

      :party_leave ->
        Arena.PartyServer.leave(state.character_id)
        {state, []}

      {:party_kick, target_name} ->
        case AoSession.OnlineDirectory.lookup_by_name(target_name) do
          {:ok, target_id, _info} ->
            Arena.PartyServer.kick(state.character_id, target_id)
          :not_found ->
            send_console(state, "Jugador no encontrado.")
        end
        {state, []}

      :party_accept ->
        Arena.PartyServer.accept_invite(state.character_id)
        {state, []}

      :not_party_command ->
        case parse_guild_command(message) do
          {:guild_create, name} ->
            alignment =
              case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
                {:ok, entity} -> Arena.GuildAlignment.from_character(entity)
                _ -> 0
              end

            Arena.GuildServer.create_guild(state.character_id, name, alignment)
            {state, []}

          {:guild_invite, target_name} ->
            case AoSession.OnlineDirectory.lookup_by_name(target_name) do
              {:ok, target_id, _info} ->
                Arena.GuildServer.invite(state.character_id, target_id)
              :not_found ->
                send_console(state, "Jugador no encontrado.")
            end
            {state, []}

          :guild_accept ->
            Arena.GuildServer.accept_invite(state.character_id)
            {state, []}

          :guild_leave ->
            Arena.GuildServer.leave(state.character_id)
            {state, []}

          {:guild_kick, target_name} ->
            case AoSession.OnlineDirectory.lookup_by_name(target_name) do
              {:ok, target_id, _info} ->
                Arena.GuildServer.kick(state.character_id, target_id)
              :not_found ->
                send_console(state, "Jugador no encontrado.")
            end
            {state, []}

          {:guild_chat, guild_message} ->
            Arena.GuildServer.guild_chat(state.character_id, guild_message)
            {state, []}

          {:guild_news, text} ->
            Arena.GuildServer.set_guild_news(state.character_id, text)
            {state, []}

          :guild_news_read ->
            case Arena.GuildServer.get_guild(state.character_id) do
              {:ok, guild} ->
                news = if guild.news == "", do: "Sin noticias.", else: guild.news
                msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: "Noticias del clan: #{news}", font_index: 0}})
                {state, [{:send_raw, msg}]}
              :not_in_guild ->
                {state, []}
            end

          {:guild_desc, text} ->
            Arena.GuildServer.set_guild_description(state.character_id, text)
            {state, []}

          :guild_online ->
            case Arena.GuildServer.guild_online(state.character_id) do
              {:ok, names} ->
                msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: "Miembros online: #{Enum.join(names, ", ")}", font_index: 0}})
                {state, [{:send_raw, msg}]}
              :not_in_guild ->
                {state, []}
            end

          :guild_info ->
            case Arena.GuildServer.guild_info(state.character_id) do
              {:ok, guild, required} ->
                req_str = if required == :max, do: "MAX", else: "#{required}"
                align_name = Arena.GuildAlignment.name(guild.alignment)
                info = "Clan: #{guild.name} | Nivel: #{guild.level} | EXP: #{guild.current_exp}/#{req_str} | Alineacion: #{align_name} | Miembros: #{length(guild.members)}"
                msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: info, font_index: 0}})
                {state, [{:send_raw, msg}]}
              :not_in_guild ->
                {state, []}
            end

          {:guild_war, target_name} ->
            Arena.GuildServer.declare_war(state.character_id, target_name)
            {state, []}

          {:guild_peace, target_name} ->
            Arena.GuildServer.propose_peace(state.character_id, target_name)
            {state, []}

          {:guild_alliance, target_name} ->
            Arena.GuildServer.propose_alliance(state.character_id, target_name)
            {state, []}

          {:guild_request, guild_name, desc} ->
            Arena.GuildServer.request_membership(state.character_id, guild_name, desc)
            {state, []}

          :guild_list_requests ->
            Arena.GuildServer.list_requests(state.character_id)
            {state, []}

          {:guild_accept_request, target_name} ->
            Arena.GuildServer.accept_request(state.character_id, target_name)
            {state, []}

          {:guild_reject_request, target_name} ->
            Arena.GuildServer.reject_request(state.character_id, target_name)
            {state, []}

          :not_guild_command ->
            case parse_faction_command(message) do
              {:enlist, faction} ->
                Arena.Map.MapServer.enlist_faction(state.map_id, state.character_id, faction)
                {state, []}

              :leave_faction ->
                Arena.Map.MapServer.leave_faction(state.map_id, state.character_id)
                {state, []}

              {:faction_chat, faction_msg} ->
                Arena.Map.MapServer.faction_chat(state.map_id, state.character_id, faction_msg)
                {state, []}

              :not_faction_command ->
                case parse_report_command(message) do
                  {:report, target_name, reason} ->
                    Arena.AuditLog.log_report(state.character_id, target_name, reason)
                    {state, [{:console_msg, %{message: "Denuncia registrada.", font_index: 0}}]}

                  :not_report_command ->
                    if String.upcase(String.trim(message)) == "/HOGAR" do
                      handle_hogar(state)
                    else
                      Arena.Map.MapServer.chat(state.map_id, state.character_id, message)
                      {state, []}
                    end
                end
            end
        end
    end
  end

  def handle_command(state, {:talk, _}), do: {state, []}

  def handle_command(state, {:change_heading, %{heading: heading_int}})
      when state.character_id != nil do
    heading = int_to_heading(heading_int)
    Arena.Map.MapServer.change_heading(state.map_id, state.character_id, heading)
    {state, []}
  end

  def handle_command(state, {:change_heading, _}), do: {state, []}

  def handle_command(state, {:pick_up, _}) when state.character_id != nil do
    Arena.Map.MapServer.pick_up(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:drop, %{slot: slot, amount: amount}})
      when state.character_id != nil do
    Arena.Map.MapServer.drop_item(state.map_id, state.character_id, slot, amount)
    {state, []}
  end

  # ---- Dead guards for equip/use/attack/cast ----

  def handle_command(state, {:equip_item, _})
      when state.character_id != nil and state.is_dead == true do
    {state, [{:console_msg, %{message: "Estás muerto. No podés equipar objetos.", font_index: 0}}]}
  end

  def handle_command(state, {:equip_item, %{slot: slot}}) when state.character_id != nil do
    case Arena.Map.MapServer.equip_item(state.map_id, state.character_id, slot) do
      {:error, :dead} ->
        {%{state | is_dead: true},
         [{:console_msg, %{message: "Estás muerto. No podés equipar objetos.", font_index: 0}}]}

      _ ->
        {state, []}
    end
  end

  def handle_command(state, {:use_item, _})
      when state.character_id != nil and state.is_dead == true do
    {state, [{:console_msg, %{message: "Estás muerto. No podés usar objetos.", font_index: 0}}]}
  end

  def handle_command(state, {:use_item, %{slot: slot}}) when state.character_id != nil do
    case Arena.Map.MapServer.use_item(state.map_id, state.character_id, slot) do
      {:error, :dead} ->
        {%{state | is_dead: true},
         [{:console_msg, %{message: "Estás muerto. No podés usar objetos.", font_index: 0}}]}

      _ ->
        {state, []}
    end
  end

  def handle_command(state, {:attack, _})
      when state.character_id != nil and state.is_dead == true do
    {state, [{:console_msg, %{message: "Estás muerto. No podés atacar.", font_index: 0}}]}
  end

  def handle_command(state, {:attack, _}) when state.character_id != nil do
    {state, cancel_packets} = maybe_cancel_hogar(state)

    case Arena.Map.MapServer.attack(state.map_id, state.character_id, state.target_x, state.target_y) do
      {:error, :dead} ->
        {%{state | is_dead: true},
         cancel_packets ++
           [{:console_msg, %{message: "Estás muerto. No podés atacar.", font_index: 0}}]}

      _ ->
        {state, cancel_packets}
    end
  end

  def handle_command(state, {:request_position_update, _})
      when state.map_id != nil and state.character_id != nil do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} -> {state, [{:pos_update, %{x: entity.x, y: entity.y}}]}
      {:error, _} -> {state, []}
    end
  end

  def handle_command(state, {:request_position_update, _}), do: {state, []}

  def handle_command(state, {:cast_spell, _})
      when state.character_id != nil and state.is_dead == true do
    {state, [{:console_msg, %{message: "Estás muerto. No podés lanzar hechizos.", font_index: 0}}]}
  end

  def handle_command(state, {:cast_spell, %{spell_slot: slot}}) when state.character_id != nil do
    {state, cancel_packets} = maybe_cancel_hogar(state)

    case Arena.Map.MapServer.cast_spell(state.map_id, state.character_id, slot, state.target_x, state.target_y) do
      {:error, :dead} ->
        {%{state | is_dead: true},
         cancel_packets ++
           [{:console_msg, %{message: "Estás muerto. No podés lanzar hechizos.", font_index: 0}}]}

      _ ->
        {state, cancel_packets}
    end
  end

  def handle_command(state, {:left_click, %{x: x, y: y}}) when state.character_id != nil do
    {%{state | target_x: x, target_y: y}, []}
  end

  def handle_command(state, {:safe_toggle, _}) when state.character_id != nil do
    Arena.Map.MapServer.safe_toggle(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:commerce_start, _}) when state.character_id != nil do
    case Arena.Map.MapServer.open_commerce(state.map_id, state.character_id, state.target_x, state.target_y) do
      :ok -> {%{state | in_commerce: true}, []}
      _ -> {state, []}
    end
  end

  def handle_command(state, {:commerce_buy, %{slot: slot, amount: amount}})
      when state.character_id != nil and state.in_commerce == true do
    Arena.Map.MapServer.commerce_buy(state.map_id, state.character_id, slot, amount)
    {state, []}
  end

  def handle_command(state, {:commerce_buy, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No estas en un comercio.", font_index: 0}}]}
  end

  def handle_command(state, {:commerce_sell, %{slot: slot, amount: amount}})
      when state.character_id != nil and state.in_commerce == true do
    Arena.Map.MapServer.commerce_sell(state.map_id, state.character_id, slot, amount)
    {state, []}
  end

  def handle_command(state, {:commerce_sell, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No estas en un comercio.", font_index: 0}}]}
  end

  def handle_command(state, {:commerce_end, _}) when state.character_id != nil do
    Arena.Map.MapServer.commerce_end(state.map_id, state.character_id)
    {%{state | in_commerce: false}, []}
  end

  # ---- Banking ----

  def handle_command(state, {:bank_start, _}) when state.character_id != nil do
    case Arena.Map.MapServer.open_bank(state.map_id, state.character_id, state.target_x, state.target_y) do
      :ok -> {%{state | in_bank: true}, []}
      _ -> {state, []}
    end
  end

  def handle_command(state, {:bank_deposit, %{slot: slot, amount: amount, slot_destino: slot_destino}})
      when state.character_id != nil and state.in_bank == true do
    Arena.Map.MapServer.bank_deposit(state.map_id, state.character_id, slot, amount, slot_destino)
    {state, []}
  end

  def handle_command(state, {:bank_deposit, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No estas en un banco.", font_index: 0}}]}
  end

  def handle_command(state, {:bank_extract_item, %{slot: slot, amount: amount, slot_destino: slot_destino}})
      when state.character_id != nil and state.in_bank == true do
    Arena.Map.MapServer.bank_extract_item(state.map_id, state.character_id, slot, amount, slot_destino)
    {state, []}
  end

  def handle_command(state, {:bank_extract_item, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No estas en un banco.", font_index: 0}}]}
  end

  def handle_command(state, {:bank_deposit_gold, %{amount: amount}})
      when state.character_id != nil and state.in_bank == true do
    Arena.Map.MapServer.bank_deposit_gold(state.map_id, state.character_id, amount)
    {state, []}
  end

  def handle_command(state, {:bank_deposit_gold, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No estas en un banco.", font_index: 0}}]}
  end

  def handle_command(state, {:bank_extract_gold, %{amount: amount}})
      when state.character_id != nil and state.in_bank == true do
    Arena.Map.MapServer.bank_extract_gold(state.map_id, state.character_id, amount)
    {state, []}
  end

  def handle_command(state, {:bank_extract_gold, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No estas en un banco.", font_index: 0}}]}
  end

  def handle_command(state, {:bank_end, _}) when state.character_id != nil do
    Arena.Map.MapServer.bank_end(state.map_id, state.character_id)
    {%{state | in_bank: false}, []}
  end

  def handle_command(state, {:yell, %{message: message}}) when state.character_id != nil do
    Arena.Map.MapServer.yell(state.map_id, state.character_id, message)
    {state, []}
  end

  def handle_command(state, {:whisper, %{target_name: target_name, message: message}})
      when state.character_id != nil do
    # Whisper is cross-map: resolve target via OnlineDirectory, send directly to their session
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, _target_char_id, target_info} ->
        # Look up sender name
        sender_name =
          case AoSession.OnlineDirectory.lookup_by_id(state.character_id) do
            {:ok, info} -> info.name
            :not_found -> "?"
          end

        whisper_msg = "#{sender_name} te dice: #{message}"
        send(target_info.session_pid, {:send_raw,
          AoProtocol.Server.Encoder.encode({:console_msg, %{message: whisper_msg, font_index: 5}})})

        # Confirm to sender
        confirm_msg = "Le dices a #{target_name}: #{message}"
        {state, [{:console_msg, %{message: confirm_msg, font_index: 5}}]}

      :not_found ->
        {state, [{:console_msg, %{message: "Jugador no encontrado.", font_index: 0}}]}
    end
  end

  def handle_command(state, {:rest, _}) when state.character_id != nil do
    Arena.Map.MapServer.rest(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:meditate, _}) when state.character_id != nil do
    Arena.Map.MapServer.meditate(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:heal, _}) when state.character_id != nil do
    Arena.Map.MapServer.heal(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:resucitate, _}) when state.character_id != nil do
    Arena.Map.MapServer.resucitate(state.map_id, state.character_id)
    {%{state | is_dead: false}, []}
  end

  def handle_command(state, {:request_atributes, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_atributes(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:request_skills, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_skills(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:request_mini_stats, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_mini_stats(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:double_click, %{x: x, y: y}}) when state.character_id != nil do
    Arena.Map.MapServer.double_click(state.map_id, state.character_id, x, y)
    {state, []}
  end

  def handle_command(state, {:online, _}) when state.character_id != nil do
    count = AoSession.OnlineDirectory.online_count()
    {state, [{:console_msg, %{message: "Jugadores en linea: #{count}", font_index: 0}}]}
  end

  # ---- User-to-user trade ----

  @trade_not_active_msg {:console_msg, %{message: "No estas en un comercio con otro jugador.", font_index: 0}}

  def handle_command(state, {:user_commerce_offer, _})
      when state.character_id != nil and state.in_trade == false do
    {state, [@trade_not_active_msg]}
  end

  def handle_command(state, {:user_commerce_offer, %{obj_index: obj_index, amount: amount}})
      when state.character_id != nil do
    case Arena.Map.MapServer.user_trade_offer(state.map_id, state.character_id, obj_index, amount) do
      {:error, :not_trading} ->
        {%{state | in_trade: false}, [@trade_not_active_msg]}
      _ ->
        {state, []}
    end
  end

  def handle_command(state, {:user_commerce_ok, _})
      when state.character_id != nil and state.in_trade == false do
    {state, [@trade_not_active_msg]}
  end

  def handle_command(state, {:user_commerce_ok, _}) when state.character_id != nil do
    case Arena.Map.MapServer.user_trade_accept(state.map_id, state.character_id) do
      {:error, :not_trading} ->
        {%{state | in_trade: false}, [@trade_not_active_msg]}
      _ ->
        {state, []}
    end
  end

  def handle_command(state, {:user_commerce_reject, _})
      when state.character_id != nil and state.in_trade == false do
    {state, [@trade_not_active_msg]}
  end

  def handle_command(state, {:user_commerce_reject, _}) when state.character_id != nil do
    Arena.Map.MapServer.user_trade_reject(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:user_commerce_end, _})
      when state.character_id != nil and state.in_trade == false do
    {state, [@trade_not_active_msg]}
  end

  def handle_command(state, {:user_commerce_end, _}) when state.character_id != nil do
    Arena.Map.MapServer.user_trade_end(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:work, %{skill: skill_index}}) when state.character_id != nil do
    Arena.Map.MapServer.train_skill(state.map_id, state.character_id, skill_index)
    {state, []}
  end

  def handle_command(state, {:party_safe_toggle, _}) when state.character_id != nil do
    Arena.PartyServer.safe_toggle(state.character_id)
    {state, []}
  end

  # VB6: use_spell_macro — client-side macro casts via cast_spell;
  # this packet is a no-op on the server (no payload to act on).
  def handle_command(state, {:use_spell_macro, _}) when state.character_id != nil do
    {state, []}
  end

  # --- Guild binary UI packets ---

  def handle_command(state, {:guild_create, %{name: name, alignment: alignment}})
      when state.character_id != nil do
    Arena.GuildServer.create_guild(state.character_id, name, alignment)
    {state, []}
  end

  def handle_command(state, {:guild_leave, _}) when state.character_id != nil do
    Arena.GuildServer.leave(state.character_id)
    {state, []}
  end

  def handle_command(state, {:guild_message, %{message: msg}}) when state.character_id != nil do
    Arena.GuildServer.guild_chat(state.character_id, msg)
    {state, []}
  end

  def handle_command(state, {:guild_online, _}) when state.character_id != nil do
    case Arena.GuildServer.guild_online(state.character_id) do
      {:ok, names} ->
        msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: "Miembros online: #{Enum.join(names, ", ")}", font_index: 0}})
        {state, [{:send_raw, msg}]}
      :not_in_guild ->
        {state, []}
    end
  end

  def handle_command(state, {:guild_declare_war, %{guild: guild_name}}) when state.character_id != nil do
    Arena.GuildServer.declare_war(state.character_id, guild_name)
    {state, []}
  end

  def handle_command(state, {:guild_offer_peace, %{guild: guild_name}}) when state.character_id != nil do
    Arena.GuildServer.propose_peace(state.character_id, guild_name)
    {state, []}
  end

  def handle_command(state, {:guild_offer_alliance, %{guild: guild_name}}) when state.character_id != nil do
    Arena.GuildServer.propose_alliance(state.character_id, guild_name)
    {state, []}
  end

  def handle_command(state, {:guild_kick_member, %{username: target_name}}) when state.character_id != nil do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, target_id, _info} -> Arena.GuildServer.kick(state.character_id, target_id)
      :not_found -> send_console(state, "Jugador no encontrado.")
    end
    {state, []}
  end

  def handle_command(state, {:guild_update_news, %{news: news}}) when state.character_id != nil do
    Arena.GuildServer.set_guild_news(state.character_id, news)
    {state, []}
  end

  def handle_command(state, {:guild_request_membership, %{guild: guild_name, application: desc}})
      when state.character_id != nil do
    Arena.GuildServer.request_membership(state.character_id, guild_name, desc)
    {state, []}
  end

  def handle_command(state, {:guild_accept_new_member, %{username: target_name}}) when state.character_id != nil do
    Arena.GuildServer.accept_request(state.character_id, target_name)
    {state, []}
  end

  def handle_command(state, {:guild_reject_new_member, %{username: target_name}}) when state.character_id != nil do
    Arena.GuildServer.reject_request(state.character_id, target_name)
    {state, []}
  end

  def handle_command(state, {:guild_request_details, %{guild: guild_name}}) when state.character_id != nil do
    # Send guild details UI packet
    case Arena.GuildServer.find_guild_by_name(guild_name) do
      {:ok, _guild_id, guild} ->
        leader_name = resolve_char_name(guild.leader)
        founder_name = resolve_char_name(guild.founder_id)
        date_str = if guild.created_at, do: Calendar.strftime(guild.created_at, "%Y-%m-%d"), else: ""
        msg = AoProtocol.Server.Encoder.encode({:guild_details, %{
          name: guild.name,
          founder: founder_name,
          date: date_str,
          leader: leader_name,
          member_count: length(guild.members),
          alignment: Arena.GuildAlignment.name(guild.alignment),
          description: guild.description || "",
          level: guild.level
        }})
        {state, [{:send_raw, msg}]}
      :not_found ->
        send_console(state, "Clan no encontrado.")
        {state, []}
    end
  end

  def handle_command(state, {:request_guild_leader_info, _}) when state.character_id != nil do
    case Arena.GuildServer.guild_info(state.character_id) do
      {:ok, guild, required} ->
        member_names = for mid <- guild.members do
          resolve_char_name(mid)
        end
        requests = case Arena.GuildServer.list_requests(state.character_id) do
          {:ok, reqs} -> reqs
          _ -> []
        end
        required_int = if required == :max, do: 0, else: required
        msg = AoProtocol.Server.Encoder.encode({:guild_leader_info, %{
          guild_list: "",
          member_list: Enum.join(member_names, "-"),
          news: guild.news || "",
          requests: Enum.join(requests, "-"),
          level: guild.level,
          current_exp: guild.current_exp,
          needed_exp: required_int
        }})
        {state, [{:send_raw, msg}]}
      :not_in_guild ->
        {state, []}
    end
  end

  # ---- Guild relation accept/reject (binary packet handlers) ----

  # Accept peace proposal — our GuildServer applies peace immediately on propose,
  # so accept is a confirmation acknowledgement. Apply peace if still at war.
  def handle_command(state, {:guild_accept_peace, %{guild: guild_name}}) when state.character_id != nil do
    Arena.GuildServer.propose_peace(state.character_id, guild_name)
    {state, []}
  end

  # Reject peace — notify the proposer's guild
  def handle_command(state, {:guild_reject_peace, %{guild: guild_name}}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "Propuesta de paz con '#{guild_name}' rechazada.", font_index: 0}}]}
  end

  # Accept alliance proposal
  def handle_command(state, {:guild_accept_alliance, %{guild: guild_name}}) when state.character_id != nil do
    Arena.GuildServer.propose_alliance(state.character_id, guild_name)
    {state, []}
  end

  # Reject alliance
  def handle_command(state, {:guild_reject_alliance, %{guild: guild_name}}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "Propuesta de alianza con '#{guild_name}' rechazada.", font_index: 0}}]}
  end

  # Alliance/peace details — show guild details for the named guild
  def handle_command(state, {:guild_alliance_details, %{guild: guild_name}}) when state.character_id != nil do
    handle_command(state, {:guild_request_details, %{guild: guild_name}})
  end

  def handle_command(state, {:guild_peace_details, %{guild: guild_name}}) when state.character_id != nil do
    handle_command(state, {:guild_request_details, %{guild: guild_name}})
  end

  # Joiner info — show character info for a membership applicant
  def handle_command(state, {:guild_request_joiner_info, %{username: name}}) when state.character_id != nil do
    handle_command(state, {:guild_member_info, %{username: name}})
  end

  # Alliance/peace proposal lists — list guilds with active relations
  def handle_command(state, {:guild_alliance_prop_list, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No hay propuestas de alianza pendientes.", font_index: 0}}]}
  end

  def handle_command(state, {:guild_peace_prop_list, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No hay propuestas de paz pendientes.", font_index: 0}}]}
  end

  # Update guild website URL
  def handle_command(state, {:guild_new_website, %{website: url}}) when state.character_id != nil do
    case Arena.GuildServer.get_guild(state.character_id) do
      {:ok, guild} ->
        if guild.leader == state.character_id do
          Arena.GuildServer.update_website(state.character_id, url)
          {state, [{:console_msg, %{message: "URL del clan actualizada.", font_index: 0}}]}
        else
          {state, [{:console_msg, %{message: "Solo el lider puede cambiar la URL.", font_index: 0}}]}
        end
      :not_in_guild ->
        {state, []}
    end
  end

  # Member info — look up a guild member's details
  def handle_command(state, {:guild_member_info, %{username: name}}) when state.character_id != nil do
    case AoSession.OnlineDirectory.lookup_by_name(name) do
      {:ok, _target_id, info} ->
        msg = "#{name} - Mapa: #{info.map_id}"
        {state, [{:console_msg, %{message: msg, font_index: 0}}]}
      :not_found ->
        {state, [{:console_msg, %{message: "Jugador '#{name}' no encontrado o desconectado.", font_index: 0}}]}
    end
  end

  # VB6: elections are disabled on the server — exact parity response
  def handle_command(state, {:guild_open_elections, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "Elecciones de clan desactivadas por el momento.", font_index: 0}}]}
  end

  def handle_command(state, {:guild_vote, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "Elecciones de clan desactivadas por el momento.", font_index: 0}}]}
  end

  # ---- Pass 1: route low-risk existing behavior ----

  # Home binary packet (ID 264) → same as /HOGAR text command
  def handle_command(state, {:home, _}) when state.character_id != nil do
    handle_hogar(state)
  end

  # Leave faction binary packet
  def handle_command(state, {:leave_faction, _}) when state.character_id != nil do
    Arena.Map.MapServer.leave_faction(state.map_id, state.character_id)
    {state, []}
  end

  # Faction message binary packet
  def handle_command(state, {:faction_message, %{message: message}}) when state.character_id != nil do
    Arena.Map.MapServer.faction_chat(state.map_id, state.character_id, message)
    {state, []}
  end

  # Group/party chat
  def handle_command(state, {:grupo_msg, %{message: message}}) when state.character_id != nil do
    case Arena.PartyServer.get_party(state.character_id) do
      {:ok, party} ->
        sender_name =
          case AoSession.OnlineDirectory.lookup_by_id(state.character_id) do
            {:ok, info} -> info.name
            :not_found -> "?"
          end

        for member_id <- party.members, member_id != state.character_id do
          case AoSession.OnlineDirectory.lookup_by_id(member_id) do
            {:ok, member_info} ->
              msg = "[Grupo] #{sender_name}: #{message}"
              send(member_info.session_pid, {:send_raw,
                AoProtocol.Server.Encoder.encode({:console_msg, %{message: msg, font_index: 3}})})
            :not_found -> :ok
          end
        end
        {state, [{:console_msg, %{message: "[Grupo] #{sender_name}: #{message}", font_index: 3}}]}

      :not_in_party ->
        {state, [{:console_msg, %{message: "No estas en un grupo.", font_index: 0}}]}
    end
  end

  # Request stats (same as request_mini_stats)
  def handle_command(state, {:request_stats, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_mini_stats(state.map_id, state.character_id)
    {state, []}
  end

  # Help — VB6 sends static help text
  def handle_command(state, {:help, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "Escribe /ONLINE para ver jugadores conectados. Usa /HOGAR para ir a tu ciudad.", font_index: 0}}]}
  end

  # Request MOTD — no server-wide MOTD system yet, return placeholder
  def handle_command(state, {:request_motd, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "Bienvenido a Argentum Online!", font_index: 0}}]}
  end

  # Uptime — compute from VM start
  def handle_command(state, {:uptime, _}) when state.character_id != nil do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    hours = div(uptime_ms, 3_600_000)
    minutes = div(rem(uptime_ms, 3_600_000), 60_000)
    {state, [{:console_msg, %{message: "Uptime: #{hours}h #{minutes}m", font_index: 0}}]}
  end

  # Information — target NPC info (same as double_click on target)
  def handle_command(state, {:information, _}) when state.character_id != nil do
    Arena.Map.MapServer.double_click(state.map_id, state.character_id, state.target_x, state.target_y)
    {state, []}
  end

  # Reward — stub, NPC reward info not implemented
  def handle_command(state, {:reward, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No hay recompensas disponibles.", font_index: 0}}]}
  end

  # Train list — stub, client expects console response
  def handle_command(state, {:train_list, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No hay criaturas disponibles para entrenar.", font_index: 0}}]}
  end

  # Request account state/balance
  def handle_command(state, {:request_account_state, _}) when state.character_id != nil do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} ->
        {state, [{:console_msg, %{message: "Oro: #{entity.gold}", font_index: 0}}]}
      _ ->
        {state, []}
    end
  end

  # Move spell — reorder spell slots in-memory
  def handle_command(state, {:move_spell, %{upwards: upwards, slot: slot}}) when state.character_id != nil do
    Arena.Map.MapServer.move_spell(state.map_id, state.character_id, upwards, slot)
    {state, []}
  end

  # Pet commands — route to MapServer
  def handle_command(state, {:pet_stand, _}) when state.character_id != nil do
    Arena.Map.MapServer.pet_stand(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:pet_follow, _}) when state.character_id != nil do
    Arena.Map.MapServer.pet_follow(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:pet_leave, _}) when state.character_id != nil do
    Arena.Map.MapServer.pet_leave(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:pet_leave_all, _}) when state.character_id != nil do
    Arena.Map.MapServer.pet_leave_all(state.map_id, state.character_id)
    {state, []}
  end

  # Council message — same as faction chat (royal/chaos council)
  def handle_command(state, {:council_message, %{message: message}}) when state.character_id != nil do
    Arena.Map.MapServer.faction_chat(state.map_id, state.character_id, message)
    {state, []}
  end

  # Train — interact with trainer NPC pet (stub for now)
  def handle_command(state, {:train, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No puedes entrenar esa criatura.", font_index: 0}}]}
  end

  # ---- Pass 2: commands needing gameplay semantics ----

  # ModifySkills (ID 7) — distribute skill points from the stats screen
  # VB6 sends 24 bytes, one per skill in NUMSKILLS order, each byte = points to add
  def handle_command(state, {:modify_skills, %{points: points}}) when state.character_id != nil do
    Arena.Map.MapServer.modify_skills(state.map_id, state.character_id, points)
    {state, []}
  end

  # ChangeDescription (ID 64) — set player description
  def handle_command(state, {:change_description, %{description: desc}}) when state.character_id != nil do
    Arena.Map.MapServer.change_description(state.map_id, state.character_id, desc)
    {state, []}
  end

  # SpellInfo (ID 4) — request spell details for a slot
  def handle_command(state, {:spell_info, %{slot: slot}}) when state.character_id != nil do
    Arena.Map.MapServer.spell_info(state.map_id, state.character_id, slot)
    {state, []}
  end

  # CraftBlacksmith (ID 100) — old UI crafting, route to work system
  def handle_command(state, {:craft_blacksmith, _}) when state.character_id != nil do
    Arena.Map.MapServer.train_skill(state.map_id, state.character_id, 20)  # 20 = blacksmithing index
    {state, []}
  end

  # CraftCarpenter (ID 1) — old UI crafting, route to work system
  def handle_command(state, {:craft_carpenter, _}) when state.character_id != nil do
    Arena.Map.MapServer.train_skill(state.map_id, state.character_id, 21)  # 21 = carpentry index
    {state, []}
  end

  # WorkLeftClick (ID 2) — same as work packet but with coordinates
  def handle_command(state, {:work_left_click, %{x: x, y: y, skill: skill}}) when state.character_id != nil do
    state = %{state | target_x: x, target_y: y}
    Arena.Map.MapServer.train_skill(state.map_id, state.character_id, skill)
    {state, []}
  end

  # ClanCodexUpdate (ID 15) — update guild description
  def handle_command(state, {:clan_codex_update, %{description: desc}}) when state.character_id != nil do
    Arena.GuildServer.set_guild_description(state.character_id, desc)
    {state, []}
  end

  # ForumPost (ID 13) — no forum system, stub
  def handle_command(state, {:forum_post, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "El foro no esta disponible.", font_index: 0}}]}
  end

  # Punishments (ID 66) — view player penalties
  def handle_command(state, {:punishments, %{name: name}}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "No hay penas registradas para #{name}.", font_index: 0}}]}
  end

  # Gamble (ID 67) — gambling system not implemented
  def handle_command(state, {:gamble, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: "El sistema de apuestas no esta disponible.", font_index: 0}}]}
  end

  # Denounce (ID 72) — report a player
  def handle_command(state, {:denounce, %{name: name, reason: reason}}) when state.character_id != nil do
    Arena.AuditLog.log_report(state.character_id, name, reason)
    {state, [{:console_msg, %{message: "Denuncia registrada.", font_index: 0}}]}
  end

  # DonateGold (ID 210) — donate gold to faction
  def handle_command(state, {:donate_gold, %{amount: amount}}) when state.character_id != nil do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} ->
        cond do
          entity.faction == :none ->
            {state, [{:console_msg, %{message: "No perteneces a ninguna faccion.", font_index: 0}}]}
          entity.gold < amount or amount <= 0 ->
            {state, [{:console_msg, %{message: "No tienes suficiente oro.", font_index: 0}}]}
          true ->
            # Deduct gold — faction treasury not yet tracked
            Arena.Map.MapServer.modify_gold(state.map_id, state.character_id, -amount)
            {state, [
              {:update_gold, %{gold: entity.gold - amount}},
              {:console_msg, %{message: "Has donado #{amount} monedas de oro a tu faccion.", font_index: 0}}
            ]}
        end
      _ -> {state, []}
    end
  end

  # TransferGold (ID 224) — transfer gold to another player
  def handle_command(state, {:transfer_gold, %{name: name, amount: amount}}) when state.character_id != nil do
    case AoSession.OnlineDirectory.lookup_by_name(name) do
      {:ok, target_id, target_info} when amount > 0 ->
        case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
          {:ok, entity} when entity.gold >= amount ->
            Arena.Map.MapServer.modify_gold(state.map_id, state.character_id, -amount)
            # Target may be on different map
            target_map = target_info.map_id
            Arena.Map.MapServer.modify_gold(target_map, target_id, amount)
            {state, [
              {:update_gold, %{gold: entity.gold - amount}},
              {:console_msg, %{message: "Has transferido #{amount} oro a #{name}.", font_index: 0}}
            ]}
          {:ok, _} ->
            {state, [{:console_msg, %{message: "No tienes suficiente oro.", font_index: 0}}]}
          _ -> {state, []}
        end
      :not_found ->
        {state, [{:console_msg, %{message: "Jugador no encontrado.", font_index: 0}}]}
      _ ->
        {state, [{:console_msg, %{message: "Cantidad invalida.", font_index: 0}}]}
    end
  end

  # MoveItem (ID 225) — swap inventory slots
  def handle_command(state, {:move_item, %{from_slot: from, to_slot: to}}) when state.character_id != nil do
    Arena.Map.MapServer.move_item(state.map_id, state.character_id, from, to)
    {state, []}
  end

  # ---- GM binary packets → route via MapServer.chat as equivalent text commands ----
  # All GM commands require is_gm == true at the session level (defense-in-depth;
  # the MapServer also checks entity.gm before executing).

  @gm_not_authorized_msg {:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}

  def handle_command(state, {:go_to_char, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/GOTO #{name}")
    {state, []}
  end

  def handle_command(state, {:warp_me_to_target, _})
      when state.character_id != nil and state.is_gm == true do
    {state, [{:console_msg, %{message: "Usa /GOTO <nombre> para teletransportarte.", font_index: 0}}]}
  end

  def handle_command(state, {:warp_char, %{name: _name, map: map}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/TELEPORT #{map} 50 50")
    {state, []}
  end

  def handle_command(state, {:invisible, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/INVISIBLE")
    {state, []}
  end

  def handle_command(state, {:silence, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MUTE #{name} 10")
    {state, []}
  end

  def handle_command(state, {:jail, %{name: name, reason: _reason, minutes: minutes}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/JAIL #{name} #{minutes}")
    {state, []}
  end

  def handle_command(state, {:kick, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KICK #{name}")
    {state, []}
  end

  def handle_command(state, {:execute, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KILL #{name}")
    {state, []}
  end

  def handle_command(state, {:ban_char, %{name: name, reason: _reason}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/BAN #{name} 30")
    {state, []}
  end

  def handle_command(state, {:unban_char, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    {state, [{:console_msg, %{message: "Unban no implementado para #{name}.", font_index: 0}}]}
  end

  def handle_command(state, {:revive_char, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    {state, [{:console_msg, %{message: "Revive no implementado para #{name}.", font_index: 0}}]}
  end

  def handle_command(state, {:summon_char, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/LOCATE #{name}")
    {state, []}
  end

  def handle_command(state, {:kill_npc, _})
      when state.character_id != nil and state.is_gm == true do
    {state, [{:console_msg, %{message: "Usa /KILL <nombre> para matar NPCs.", font_index: 0}}]}
  end

  def handle_command(state, {:request_char_info, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/INFO #{name}")
    {state, []}
  end

  def handle_command(state, {:where, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/LOCATE #{name}")
    {state, []}
  end

  def handle_command(state, {:gm_message, %{message: message}})
      when state.character_id != nil and state.is_gm == true do
    broadcast_msg = "Servidor> " <> message
    raw = AoProtocol.Server.Encoder.encode({:console_msg, %{message: broadcast_msg, font_index: 1}})
    AoSession.OnlineDirectory.broadcast_all({:send_raw, raw})
    {state, []}
  end

  def handle_command(state, {:server_message, %{message: message}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, message)
    {state, []}
  end

  def handle_command(state, {:online_gm, _})
      when state.character_id != nil and state.is_gm == true do
    count = AoSession.OnlineDirectory.online_count()
    {state, [{:console_msg, %{message: "GMs en linea: #{count}", font_index: 0}}]}
  end

  def handle_command(state, {:rain_toggle, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.WorldWeather.toggle_rain()
    {state, []}
  end

  # RoleMasterRequest — GM requests the GM panel form (VB6: "Maestro de Roles")
  def handle_command(state, {:role_master_request, _})
      when state.character_id != nil and state.is_gm == true do
    {state, [{:show_gm_panel_form, %{}}]}
  end

  # Catch-all for GM commands attempted without privileges
  @gm_command_types [
    :go_to_char, :warp_me_to_target, :warp_char, :invisible, :silence,
    :jail, :kick, :execute, :ban_char, :unban_char, :revive_char,
    :summon_char, :kill_npc, :request_char_info, :where, :gm_message,
    :server_message, :online_gm, :rain_toggle, :role_master_request
  ]

  def handle_command(state, {cmd_type, _})
      when state.character_id != nil and cmd_type in @gm_command_types do
    {state, [@gm_not_authorized_msg]}
  end

  def handle_command(state, {command_type, _}) do
    Logger.debug("Unhandled command: #{command_type}")
    {state, []}
  end

  # ---- /HOGAR — VB6 home travel (dead-only, delayed with timer bar) ----
  #
  # VB6 Protocol.bas HandleHome exact flow:
  #   1. IsInMapCarcelRestrictedArea → reject
  #   2. Alive (Muerto=0) → reject "Debes estar muerto"
  #   3. NEWBIE zone or CARCEL trigger → reject "No puedes viajar a tu hogar desde este mapa"
  #   4. Penalty > 0 → reject "No puedes usar este comando en prisión"
  #   5. EnReto → reject "No podés regresar desde un reto"
  #   6. If not traveling:
  #      - If not on home map: charge gold, start delayed timer (goHome)
  #      - If on home map: "Ya te encuentras en tu hogar"
  #   7. If already traveling: cancel, "Ya hay un viaje en curso"
  #
  # goHome sets a timer bar; when it expires, HomeArrival teleports the player.

  # VB6 e_Ciudad enum order (reverse of character_creation @home_city_atom)
  @home_city_ids %{
    ullathorpe: 1, nix: 2, banderbill: 3, lindos: 4,
    arghal: 5, arkhein: 6, forgat: 7, eldoria: 8, penthar: 9
  }

  @jail_map_id 66
  @hogar_travel_delay_ms 10_000

  defp handle_hogar(state) do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} ->
        handle_hogar_check(state, entity)

      _ ->
        {state, []}
    end
  end

  # Pure-logic /HOGAR handler, public for unit testing without MapServer.
  # Matches VB6 HandleHome exactly: dead-only, delayed travel with timer bar.
  @doc false
  def handle_hogar_check(state, entity) do
    handle_hogar_check(state, entity, nil)
  end

  @doc false
  def handle_hogar_check(state, entity, map_zone) do
    hogar_ref = Map.get(state, :hogar_timer_ref)

    # Resolve zone lazily — only call MapServer when not passed explicitly (tests pass it)
    zone = map_zone || try_get_map_zone(state.map_id)

    cond do
      # VB6 step 1: IsInMapCarcelRestrictedArea — jail map blocked
      state.map_id == @jail_map_id ->
        {state, [{:console_msg, %{message: "No puedes usar /HOGAR en la cárcel.", font_index: 0}}]}

      # VB6 step 2: must be dead
      not entity.dead ->
        {state, [{:console_msg, %{message: "Debes estar muerto para poder utilizar este comando.", font_index: 0}}]}

      # VB6 step 3: NEWBIE zone restriction
      zone == "NEWBIE" ->
        {state, [{:console_msg, %{message: "No puedes viajar a tu hogar desde este mapa.", font_index: 0}}]}

      # VB6 step 4: penalty (prison sentence)
      (entity.penalty || 0) > 0 ->
        {state, [{:console_msg, %{message: "No puedes usar este comando en prisión.", font_index: 0}}]}

      # VB6 step 7: already traveling — cancel the travel
      hogar_ref != nil ->
        Process.cancel_timer(hogar_ref)
        state = Map.put(state, :hogar_timer_ref, nil)
        {state, [{:console_msg, %{message: "Ya hay un viaje en curso.", font_index: 0}}]}

      # VB6 step 6: not traveling — check home map then start
      true ->
        city_id = Map.get(@home_city_ids, entity.home_city, 1)
        spawn = Arena.Data.GameData.city_spawn(city_id)

        if state.map_id == spawn.map do
          {state, [{:console_msg, %{message: "Ya te encuentras en tu hogar.", font_index: 0}}]}
        else
          cost = hogar_gold_cost(entity.level)

          if entity.gold < cost do
            {state, [{:console_msg, %{message: "Para utilizar este comando necesitas #{cost} monedas de oro.", font_index: 0}}]}
          else
            # Deduct gold (async cast — also sends :update_gold packet to client)
            Arena.Map.MapServer.modify_gold(state.map_id, state.character_id, -cost)

            ref = Process.send_after(self(), :hogar_arrive, @hogar_travel_delay_ms)
            state = Map.put(state, :hogar_timer_ref, ref)

            {state, [
              {:console_msg, %{message: "Volverás a tu hogar en unos segundos.", font_index: 0}}
            ]}
          end
        end
    end
  end

  @doc """
  Cancel an in-progress /HOGAR travel. Returns `{state, packets}`.
  Called when the player walks, attacks, casts, gets hit, or dies.
  """
  def cancel_hogar(state) do
    case Map.get(state, :hogar_timer_ref) do
      nil ->
        {state, []}

      ref ->
        Process.cancel_timer(ref)
        state = Map.put(state, :hogar_timer_ref, nil)
        {state, [{:console_msg, %{message: "Has cancelado el viaje a casa.", font_index: 0}}]}
    end
  end

  @doc """
  Convenience: cancel hogar and return just `{state, cancel_packets}`.
  Used by walk/attack/spell handlers that need to prepend cancel packets.
  """
  def maybe_cancel_hogar(state) do
    cancel_hogar(state)
  end

  @doc """
  Handle the :hogar_arrive timer message. Teleports the player to their
  home city if the timer wasn't cancelled (hogar_timer_ref still set).
  Returns either `{:transfer, map, x, y, entity}` tuple (for handler to process)
  or `{state, []}` if cancelled.
  """
  def handle_hogar_arrive(state, entity) do
    case Map.get(state, :hogar_timer_ref) do
      nil ->
        # Timer was cancelled
        {state, []}

      _ref ->
        city_id = Map.get(@home_city_ids, entity.home_city, 1)
        spawn = Arena.Data.GameData.city_spawn(city_id)

        {:transfer, spawn.map, spawn.x, spawn.y, entity}
    end
  end

  defp hogar_gold_cost(level) when level > 24, do: level * level
  defp hogar_gold_cost(level), do: level * 15 + trunc(:math.pow(level, 1.5))

  defp try_get_map_zone(map_id) do
    Arena.Map.MapServer.map_zone(map_id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # ---- Cleanup & autosave ----

  def cleanup(state) do
    if state.character_id && state.map_id do
      case Arena.Map.MapServer.leave(state.map_id, state.character_id) do
        {:ok, entity} ->
          try do
            attrs = GameBackend.Characters.from_entity(entity)
            inventory = GameBackend.Characters.inventory_from_entity(entity)
            equipment = GameBackend.Characters.equipment_from_entity(entity)
            skills = GameBackend.Characters.skills_from_entity(entity)
            spells = GameBackend.Characters.spells_from_entity(entity)

            case GameBackend.Characters.save_snapshot(entity.char_id, attrs,
                   inventory: inventory,
                   equipment: equipment,
                   skills: skills,
                   spells: spells
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Logger.error("Cleanup save failed for #{entity.char_id}: #{inspect(reason)}")
            end
          rescue
            e -> Logger.error("Cleanup save error for #{entity.char_id}: #{inspect(e)}")
          end

        :not_found ->
          :ok
      end
    end

    if state.character_id do
      Arena.PartyServer.leave(state.character_id)
      AoSession.OnlineDirectory.unregister(state.character_id)
      AoSession.unregister(state.character_id)
    end

    :ok
  end

  def autosave(entity) do
    Task.start(fn ->
      attrs = GameBackend.Characters.from_entity(entity)
      inventory = GameBackend.Characters.inventory_from_entity(entity)
      equipment = GameBackend.Characters.equipment_from_entity(entity)
      skills = GameBackend.Characters.skills_from_entity(entity)
      spells = GameBackend.Characters.spells_from_entity(entity)

      case GameBackend.Characters.save_snapshot(entity.char_id, attrs,
             inventory: inventory,
             equipment: equipment,
             skills: skills,
             spells: spells
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("Autosave failed for #{entity.char_id}: #{inspect(reason)}")
      end
    end)
  end

  # ---- Map readiness ----

  def ensure_map_started(map_id) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(map_id)
    end

    wait_for_map_ready(map_id, 50)
  end

  defp wait_for_map_ready(_map_id, 0), do: {:error, :map_not_ready}

  defp wait_for_map_ready(map_id, retries) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [] ->
        {:error, :map_not_found}

      _ ->
        if Arena.Map.MapServer.ready?(map_id) do
          :ok
        else
          Process.sleep(100)
          wait_for_map_ready(map_id, retries - 1)
        end
    end
  end

  # ---- Packet builders ----

  def inventory_login_packets(entity) do
    entity.inventory
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {nil, _idx} ->
        []

      {%{item_id: item_id, amount: amount, equipped: equipped}, idx} ->
        item_def = Arena.Data.GameData.get_item(item_id)
        valor = if item_def, do: item_def.valor, else: 0

        [
          {:change_inventory_slot,
           %{
             slot: idx + 1,
             obj_index: item_id,
             amount: amount,
             equipped: equipped,
             valor: valor / 1
           }}
        ]
    end)
  end

  def exp_login_packets(entity) do
    level = max(entity.level || 1, 1)
    current_xp = max(entity.xp || 0, 0)

    next_xp =
      case Arena.Data.GameData.exp_for_level(level) do
        value when is_integer(value) and value > current_xp ->
          value

        _ ->
          case Arena.Data.GameData.exp_for_level(level + 1) do
            value when is_integer(value) and value > 0 -> value
            _ -> max(current_xp, 1)
          end
      end

    [
      {:level_up, %{level: level}},
      {:update_exp, %{current_xp: current_xp, next_xp: next_xp}}
    ]
  end

  def spell_login_packets(entity) do
    (entity.spells || [])
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {spell_id, slot} when is_integer(spell_id) and spell_id > 0 ->
        [
          {:change_spell_slot,
           %{
             slot: slot,
             spell_id: spell_id
           }}
        ]

      _ ->
        []
    end)
  end

  def skill_login_packets(entity) do
    [{:send_skills, %{skills: entity.skills || %{}}}]
  end

  # ---- Heading conversion ----

  def int_to_heading(1), do: :north
  def int_to_heading(2), do: :east
  def int_to_heading(3), do: :south
  def int_to_heading(4), do: :west
  def int_to_heading(_), do: :south

  # ---- Creation error messages ----

  defp creation_error_message(:name_too_short), do: "Name too short (min 3 characters)."
  defp creation_error_message(:name_too_long), do: "Name too long (max 30 characters)."
  defp creation_error_message(:name_invalid_chars), do: "Name contains invalid characters."
  defp creation_error_message(:name_invalid), do: "Invalid name."
  defp creation_error_message(:invalid_head), do: "Invalid head selection."
  defp creation_error_message(:name_taken), do: "Character name already taken."
  defp creation_error_message({:invalid_race, _}), do: "Invalid race."
  defp creation_error_message({:invalid_gender, _}), do: "Invalid gender."
  defp creation_error_message({:invalid_class, _}), do: "Invalid class."
  defp creation_error_message({:invalid_home_city, _}), do: "Invalid home city."
  defp creation_error_message(_), do: "Character creation failed."

  # ---- Party chat commands ----

  defp parse_party_command(message) do
    upper = String.upcase(String.trim(message))
    cond do
      String.starts_with?(upper, "/PARTY ") ->
        name = String.trim(String.slice(message, 7..-1//1))
        {:party_invite, name}
      upper == "/SALIRGRUPO" -> :party_leave
      String.starts_with?(upper, "/ECHARGRUPO ") ->
        name = String.trim(String.slice(message, 12..-1//1))
        {:party_kick, name}
      upper == "/ACEPTARGRUPO" -> :party_accept
      true -> :not_party_command
    end
  end

  defp parse_guild_command(message) do
    upper = String.upcase(String.trim(message))
    cond do
      String.starts_with?(upper, "/CREARCLAN ") ->
        name = String.trim(String.slice(message, 11..-1//1))
        {:guild_create, name}

      String.starts_with?(upper, "/INVITARCLAN ") ->
        name = String.trim(String.slice(message, 13..-1//1))
        {:guild_invite, name}

      upper == "/ACEPTARCLAN" ->
        :guild_accept

      upper == "/SALIRCLAN" ->
        :guild_leave

      String.starts_with?(upper, "/ECHARCLAN ") ->
        name = String.trim(String.slice(message, 11..-1//1))
        {:guild_kick, name}

      String.starts_with?(upper, "/CC ") ->
        msg = String.trim(String.slice(message, 4..-1//1))
        {:guild_chat, msg}

      String.starts_with?(upper, "/CLANCHAT ") ->
        msg = String.trim(String.slice(message, 10..-1//1))
        {:guild_chat, msg}

      String.starts_with?(upper, "/CLANNOTICIAS ") ->
        text = String.trim(String.slice(message, 14..-1//1))
        {:guild_news, text}

      upper == "/CLANNOTICIAS" ->
        :guild_news_read

      String.starts_with?(upper, "/CLANDESC ") ->
        text = String.trim(String.slice(message, 10..-1//1))
        {:guild_desc, text}

      upper == "/CLANONLINE" ->
        :guild_online

      upper == "/CLANINFO" ->
        :guild_info

      String.starts_with?(upper, "/DECLARARGUERRA ") ->
        name = String.trim(String.slice(message, 16..-1//1))
        {:guild_war, name}

      String.starts_with?(upper, "/PROPONERPAZ ") ->
        name = String.trim(String.slice(message, 13..-1//1))
        {:guild_peace, name}

      String.starts_with?(upper, "/ALIANZA ") ->
        name = String.trim(String.slice(message, 9..-1//1))
        {:guild_alliance, name}

      String.starts_with?(upper, "/SOLICITAR ") ->
        rest = String.trim(String.slice(message, 11..-1//1))
        # /SOLICITAR clan_name optional_description
        case String.split(rest, " ", parts: 2) do
          [guild_name, desc] -> {:guild_request, guild_name, desc}
          [guild_name] -> {:guild_request, guild_name, ""}
        end

      upper == "/SOLICITUDES" ->
        :guild_list_requests

      String.starts_with?(upper, "/ACEPTARSOLICITUD ") ->
        name = String.trim(String.slice(message, 18..-1//1))
        {:guild_accept_request, name}

      String.starts_with?(upper, "/RECHAZARSOLICITUD ") ->
        name = String.trim(String.slice(message, 19..-1//1))
        {:guild_reject_request, name}

      true ->
        :not_guild_command
    end
  end

  defp parse_faction_command(message) do
    upper = String.upcase(String.trim(message))
    cond do
      upper == "/ENLISTAR REAL" -> {:enlist, :royal_army}
      upper == "/ENLISTAR CAOS" -> {:enlist, :chaos_legion}
      upper == "/RENUNCIAR" -> :leave_faction
      String.starts_with?(upper, "/FACCION ") ->
        msg = String.trim(String.slice(message, 9..-1//1))
        {:faction_chat, msg}
      true -> :not_faction_command
    end
  end

  defp parse_report_command(message) do
    upper = String.upcase(String.trim(message))
    cond do
      String.starts_with?(upper, "/DENUNCIAR ") ->
        # /DENUNCIAR name reason_text
        rest = String.trim(String.slice(message, 11..-1//1))
        case String.split(rest, ~r/\s+/, parts: 2) do
          [target_name, reason] -> {:report, target_name, reason}
          [target_name] -> {:report, target_name, ""}
          _ -> :not_report_command
        end
      true -> :not_report_command
    end
  end

  defp send_console(_state, message) do
    raw = AoProtocol.Server.Encoder.encode({:console_msg, %{message: message, font_index: 0}})
    send(self(), {:send_raw, raw})
  end

  defp resolve_char_name(char_id) when is_integer(char_id) do
    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} -> info.name
      _ ->
        # Offline: look up from DB
        case GameBackend.Repo.get(GameBackend.Characters, char_id) do
          %{name: name} -> name
          _ -> "ID:#{char_id}"
        end
    end
  end

  defp resolve_char_name(_), do: "Unknown"
end
