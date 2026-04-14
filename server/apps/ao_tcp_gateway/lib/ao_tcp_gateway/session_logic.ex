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
      global_snow = try do Arena.WorldWeather.snowing?() rescue _ -> weather.snow catch :exit, _ -> weather.snow end
      weather_packets =
        (if global_rain, do: [{:rain_toggle, %{raining: true}}], else: []) ++
        (if global_snow, do: [{:snow_toggle, %{snowing: true}}], else: [])

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

      AoSession.OnlineDirectory.register(entity.char_id, entity.name, map_id, self(),
        is_gm: state.is_gm,
        faction: entity.faction
      )

      # Send party snapshot if player is in a party
      party_snapshot_packets =
        case Arena.PartyServer.get_party(entity.char_id) do
          {:ok, party} ->
            leader_id = party.leader
            ordered = [leader_id | Enum.filter(party.members, &(&1 != leader_id))]

            names =
              Enum.map(ordered, fn mid ->
                case AoSession.OnlineDirectory.lookup_by_id(mid) do
                  {:ok, info} -> info.name
                  :not_found -> "ID:#{mid}"
                end
              end)

            [{:datos_grupo, %{en_grupo: true, members: names, leader_index: 0}}]

          :not_in_party ->
            [{:datos_grupo, %{en_grupo: false, members: []}}]
        end

      {state, packets ++ party_snapshot_packets}
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
      global_snow = try do Arena.WorldWeather.snowing?() rescue _ -> weather.snow catch :exit, _ -> weather.snow end
      weather_packets =
        (if global_rain, do: [{:rain_toggle, %{raining: true}}], else: [{:rain_toggle, %{raining: false}}]) ++
        (if global_snow, do: [{:snow_toggle, %{snowing: true}}], else: [{:snow_toggle, %{snowing: false}}])

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
                Arena.GuildServer.send_guild_news(state.character_id, guild)
                {state, []}
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
              {:ok, guild, _required} ->
                Arena.GuildServer.send_guild_details(state.character_id, guild)
                {state, []}
              :not_in_guild ->
                {state, []}
            end

          {:guild_war, target_name} ->
            Arena.GuildServer.declare_war(state.character_id, target_name)
            {state, []}

          {:guild_peace, _target_name} ->
            msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: "Relaciones de clan desactivadas por el momento.", font_index: 0}})
            {state, [{:send_raw, msg}]}

          {:guild_alliance, _target_name} ->
            msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: "Relaciones de clan desactivadas por el momento.", font_index: 0}})
            {state, [{:send_raw, msg}]}

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
                case parse_marriage_command(message) do
                  {:propose, target_name} ->
                    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
                      {:ok, target_id, _info} ->
                        Arena.Map.MapServer.propose_marriage(state.map_id, state.character_id, target_id)
                      :not_found ->
                        send_console(state, "Usuario offline.")
                    end
                    {state, []}

                  :divorce ->
                    Arena.Map.MapServer.divorce(state.map_id, state.character_id)
                    {state, []}

                  :not_marriage_command ->
                    case parse_report_command(message) do
                      {:report, target_name, reason} ->
                        Arena.AuditLog.log_report(state.character_id, target_name, reason)
                        {state, [{:console_msg, %{message: "Denuncia registrada.", font_index: 0}}]}

                      :not_report_command ->
                        case parse_duel_command(message) do
                          {:retar, target_name, bet} ->
                            handle_duel_challenge(state, target_name, bet)

                          {:aceptar, challenger_name} ->
                            handle_duel_accept(state, challenger_name)

                          :cancelar_reto ->
                            handle_duel_cancel(state)

                          :abandonar_reto ->
                            handle_duel_abandon(state)

                          :not_duel_command ->
                            upper = String.upcase(String.trim(message))
                            cond do
                              upper == "/HOGAR" ->
                                handle_hogar(state)

                              upper == "/TOURNAMENT JOIN" ->
                                name = state.entity.name
                                case Arena.Events.TournamentServer.join(state.character_id, name) do
                                  :ok -> {state, [{:console_msg, %{message: "Te has registrado en el torneo.", font_index: 0}}]}
                                  {:error, :no_tournament} -> {state, [{:console_msg, %{message: "No hay torneo activo.", font_index: 0}}]}
                                  {:error, :already_registered} -> {state, [{:console_msg, %{message: "Ya estas registrado.", font_index: 0}}]}
                                  {:error, :tournament_full} -> {state, [{:console_msg, %{message: "El torneo esta lleno.", font_index: 0}}]}
                                  {:error, _} -> {state, [{:console_msg, %{message: "No se pudo registrar.", font_index: 0}}]}
                                end

                              upper == "/TOURNAMENT LEAVE" ->
                                case Arena.Events.TournamentServer.leave(state.character_id) do
                                  :ok -> {state, [{:console_msg, %{message: "Te has retirado del torneo.", font_index: 0}}]}
                                  {:error, _} -> {state, [{:console_msg, %{message: "No estas en un torneo.", font_index: 0}}]}
                                end

                              true ->
                                Arena.Map.MapServer.chat(state.map_id, state.character_id, message)
                                {state, []}
                            end
                        end
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

  # ---- Auction ----

  def handle_command(state, {:oferta_inicial, %{amount: amount}}) when state.character_id != nil do
    case Arena.Auction.set_initial_offer(state.character_id, amount) do
      :ok ->
        {state, []}

      {:error, :not_initiating} ->
        {state,
         [{:console_msg,
           %{message: "Primero tenes que hacer click sobre el subastador.", font_index: 0}}]}

      {:error, :not_seller} ->
        {state,
         [{:console_msg,
           %{
             message: "Oye amigo, tu no podes decirme cual es la oferta inicial.",
             font_index: 0
           }}]}

      {:error, :auction_in_progress} ->
        {state,
         [{:console_msg, %{message: "Ya hay una subasta en curso.", font_index: 0}}]}

      {:error, _reason} ->
        {state,
         [{:console_msg, %{message: "No se pudo iniciar la subasta.", font_index: 0}}]}
    end
  end

  def handle_command(state, {:oferta_de_subasta, %{amount: amount}})
      when state.character_id != nil do
    case Arena.Auction.place_bid(state.character_id, amount) do
      {:ok, _result} ->
        {state, []}

      {:error, :no_auction} ->
        {state,
         [{:console_msg, %{message: "No hay ninguna subasta en curso.", font_index: 0}}]}

      {:error, :self_bid} ->
        {state,
         [{:console_msg,
           %{message: "No podes auto ofertar en tus subastas.", font_index: 0}}]}

      {:error, :bid_too_low, _min} ->
        {state,
         [{:console_msg,
           %{
             message:
               "Debe haber almenos una diferencia de 100 monedas a la ultima oferta!",
             font_index: 0
           }}]}

      {:error, :bid_too_low} ->
        {state,
         [{:console_msg,
           %{
             message:
               "Debe haber almenos una diferencia de 100 monedas a la ultima oferta!",
             font_index: 0
           }}]}

      {:error, _reason} ->
        {state,
         [{:console_msg, %{message: "No se pudo realizar la oferta.", font_index: 0}}]}
    end
  end

  def handle_command(state, {:subasta_info, _}) when state.character_id != nil do
    case Arena.Auction.get_info(state.character_id) do
      {:ok, info} ->
        msgs = build_auction_info_messages(info)
        {state, msgs}

      {:error, :no_auction} ->
        {state,
         [{:console_msg,
           %{
             message: "No hay ninguna subasta activa en este momento.",
             font_index: 0
           }}]}
    end
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

  # ---- Faction online lists (VB6: HandleOnlineRoyalArmy / HandleOnlineChaosLegion) ----

  def handle_command(state, {:online_royal_army, _}) when state.character_id != nil do
    members = AoSession.OnlineDirectory.list_by_faction(:royal_army)
    name_list = Enum.map_join(members, ", ", & &1.name)

    msg =
      if name_list == "",
        do: "No hay miembros de la Armada Real en linea.",
        else: "Armada Real en linea: #{name_list}"

    {state, [{:console_msg, %{message: msg, font_index: 0}}]}
  end

  def handle_command(state, {:online_chaos_legion, _}) when state.character_id != nil do
    members = AoSession.OnlineDirectory.list_by_faction(:chaos_legion)
    name_list = Enum.map_join(members, ", ", & &1.name)

    msg =
      if name_list == "",
        do: "No hay miembros de la Legion del Caos en linea.",
        else: "Legion del Caos en linea: #{name_list}"

    {state, [{:console_msg, %{message: msg, font_index: 0}}]}
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
    if state.is_dead == true do
      {state, []}
    else
      # NOTE: mute check requires entity state which session_logic doesn't have for guild chat
      Arena.GuildServer.guild_chat(state.character_id, msg)
      {state, []}
    end
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

  # ---- Guild relation packets: VB6 disabled stubs (Tasks 20) ----
  # Alliance/peace systems are deferred; return VB6-parity disabled messages.

  @guild_relations_disabled "Relaciones de clan desactivadas por el momento."

  def handle_command(state, {:guild_accept_peace, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  def handle_command(state, {:guild_reject_peace, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  def handle_command(state, {:guild_accept_alliance, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  def handle_command(state, {:guild_reject_alliance, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  def handle_command(state, {:guild_offer_peace, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  def handle_command(state, {:guild_offer_alliance, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  def handle_command(state, {:guild_alliance_details, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  def handle_command(state, {:guild_peace_details, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  def handle_command(state, {:guild_alliance_prop_list, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  def handle_command(state, {:guild_peace_prop_list, _}) when state.character_id != nil do
    {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  end

  # Joiner info — show character info for a membership applicant
  def handle_command(state, {:guild_request_joiner_info, %{username: name}}) when state.character_id != nil do
    handle_command(state, {:guild_member_info, %{username: name}})
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
    if state.is_dead == true do
      {state, []}
    else
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
  end

  # Request stats (same as request_mini_stats)
  def handle_command(state, {:request_stats, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_mini_stats(state.map_id, state.character_id)
    {state, []}
  end

  # Help — VB6 loads from Help.dat and sends each line (FONTTYPE_INFO = 0)
  @help_lines [
    "* Reglamento del juego: usa /REGLAMENTO para mas informacion.",
    "* Si estas muerto, dirigete a una ciudad y busca un sacerdote, el te resucitara dandole click derecho. Tambien puedes tipear /Hogar.",
    "* Para realizar una consulta a un GAME MASTER, debes utilizar el comando /GM y ellos acudiran a ti.",
    "* Para denunciar insultos de otro usuario utiliza el comando /DENUNCIAR 'nombre'.",
    "* Escribe /ONLINE para ver jugadores conectados. Usa /HOGAR para ir a tu ciudad."
  ]
  def handle_command(state, {:help, _}) when state.character_id != nil do
    msgs = Enum.map(@help_lines, fn line -> {:console_msg, %{message: line, font_index: 0}} end)
    {state, msgs}
  end

  # Request MOTD — VB6 loads from Motd.ini, sends each line (FONTTYPE_EXP),
  # then appends server uptime. We use Application config for the lines.
  def handle_command(state, {:request_motd, _}) when state.character_id != nil do
    motd_lines = Application.get_env(:ao_tcp_gateway, :motd_lines, ["Bienvenido a Argentum Online!"])

    motd_msgs =
      Enum.map(motd_lines, fn line ->
        {:console_msg, %{message: line, font_index: 0}}
      end)

    # Append uptime like VB6's SendWelcomeUptime
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    hours = div(uptime_ms, 3_600_000)
    minutes = div(rem(uptime_ms, 3_600_000), 60_000)
    uptime_msg = {:console_msg, %{message: "Uptime del servidor: #{hours}h #{minutes}m", font_index: 0}}

    {state, motd_msgs ++ [uptime_msg]}
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

  # Reward — VB6: requires targeting an enlistador NPC of matching faction.
  # Checks faction score and level requirements for rank advancement.
  def handle_command(state, {:reward, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_reward(state.map_id, state.character_id)
    {state, []}
  end

  # Train list — delegate to MapServer
  def handle_command(state, {:train_list, _}) when state.character_id != nil do
    Arena.Map.MapServer.train_list(state.map_id, state.character_id)
    {state, []}
  end

  # Request account state/balance — VB6: NPC-dependent.
  # Banker shows bank gold, Timbero shows gambling stats.
  def handle_command(state, {:request_account_state, _}) when state.character_id != nil do
    Arena.Map.MapServer.request_account_state(state.map_id, state.character_id)
    {state, []}
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

  # Council message — restricted to council members (VB6: eCouncilMessage).
  # In VB6, council members are high-rank faction members. We check faction membership
  # and delegate to faction_chat which broadcasts to same-faction players.
  # Future: add explicit council rank threshold check (e.g. faction_rank >= max_rank).
  def handle_command(state, {:council_message, %{message: message}}) when state.character_id != nil do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} when entity.faction != :none ->
        Arena.Map.MapServer.faction_chat(state.map_id, state.character_id, message)
        {state, []}

      {:ok, _entity} ->
        {state, [{:console_msg, %{message: "No perteneces a ninguna faccion.", font_index: 0}}]}

      _ ->
        {state, []}
    end
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

  # CraftBlacksmith (ID 100) — old UI crafting, craft specific item
  def handle_command(state, {:craft_blacksmith, %{item: item}}) when state.character_id != nil do
    Arena.Map.MapServer.craft_item(state.map_id, state.character_id, :blacksmithing, item)
    {state, []}
  end

  # CraftCarpenter (ID 1) — old UI crafting, craft specific item
  def handle_command(state, {:craft_carpenter, %{item: item}}) when state.character_id != nil do
    Arena.Map.MapServer.craft_item(state.map_id, state.character_id, :carpentry, item)
    {state, []}
  end

  # CraftAlchemy (ID 228) — old UI crafting, craft specific item
  def handle_command(state, {:craft_alchemy, %{item: item}}) when state.character_id != nil do
    Arena.Map.MapServer.craft_item(state.map_id, state.character_id, :alchemy, item)
    {state, []}
  end

  # CraftTailor (ID 230) — old UI crafting, craft specific item
  def handle_command(state, {:craft_tailor, %{item: item}}) when state.character_id != nil do
    Arena.Map.MapServer.craft_item(state.map_id, state.character_id, :tailoring, item)
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

  # ForumPost (ID 13) — post to currently viewed forum
  def handle_command(state, {:forum_post, %{title: title, message: body}}) when state.character_id != nil do
    forum_id = Map.get(state, :viewing_forum_id)

    if forum_id != nil and forum_id > 0 do
      author =
        case AoSession.OnlineDirectory.lookup_by_id(state.character_id) do
          {:ok, info} -> info.name
          _ -> "Unknown"
        end

      Arena.Forum.post_message(forum_id, author, title, body)
      {state, [{:console_msg, %{message: "Mensaje publicado.", font_index: 0}}]}
    else
      {state, [{:console_msg, %{message: "El foro no esta disponible.", font_index: 0}}]}
    end
  end

  # Punishments (ID 66) — VB6: players can only view their own record,
  # GMs can view anyone's. No punishment DB table yet, so always "sin prontuario".
  def handle_command(state, {:punishments, %{name: name}}) when state.character_id != nil do
    # VB6: non-GMs can only check their own name
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} ->
        if not entity.gm and entity.name != name do
          {state, [{:console_msg, %{message: "Servidor: Comando deshabilitado para tu cargo.", font_index: 0}}]}
        else
          # TODO: Query punishment table when implemented
          {state, [{:console_msg, %{message: "Sin prontuario.", font_index: 0}}]}
        end

      _ ->
        {state, []}
    end
  end

  # Gamble (ID 67) — delegate to MapServer
  def handle_command(state, {:gamble, %{amount: amount}}) when state.character_id != nil do
    Arena.Map.MapServer.gamble(state.map_id, state.character_id, amount)
    {state, []}
  end

  # Forgive (ID 68) — delegate to MapServer
  def handle_command(state, {:forgive, _}) when state.character_id != nil do
    Arena.Map.MapServer.forgive(state.map_id, state.character_id)
    {state, []}
  end

  # Arena entry (ID 259) — delegate to MapServer
  def handle_command(state, {:arena_entry, _}) when state.character_id != nil do
    Arena.Map.MapServer.arena_entry(state.map_id, state.character_id)
    {state, []}
  end

  # Denounce (ID 72) — report a player
  def handle_command(state, {:denounce, %{name: name, reason: reason}}) when state.character_id != nil do
    Arena.AuditLog.log_report(state.character_id, name, reason)
    {state, [{:console_msg, %{message: "Denuncia registrada.", font_index: 0}}]}
  end

  # DonateGold (ID 210) — donate gold to faction
  def handle_command(state, {:donate_gold, %{amount: amount}}) when state.character_id != nil do
    if amount <= 0 do
      {state, [{:console_msg, %{message: "Cantidad invalida.", font_index: 0}}]}
    else
      case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
        {:ok, entity} when entity.faction == :none ->
          {state, [{:console_msg, %{message: "No perteneces a ninguna faccion.", font_index: 0}}]}

        {:ok, _entity} ->
          # Atomic deduct — prevents TOCTOU race with snapshot
          case Arena.Map.MapServer.deduct_gold(state.map_id, state.character_id, amount) do
            {:ok, new_gold} ->
              {state, [
                {:update_gold, %{gold: new_gold}},
                {:console_msg, %{message: "Has donado #{amount} monedas de oro a tu faccion.", font_index: 0}}
              ]}

            {:error, _reason} ->
              {state, [{:console_msg, %{message: "No tienes suficiente oro.", font_index: 0}}]}
          end

        _ -> {state, []}
      end
    end
  end

  # TransferGold (ID 224) — transfer gold to another player
  def handle_command(state, {:transfer_gold, %{name: name, amount: amount}}) when state.character_id != nil do
    if amount <= 0 do
      {state, [{:console_msg, %{message: "Cantidad invalida.", font_index: 0}}]}
    else
      case AoSession.OnlineDirectory.lookup_by_name(name) do
        {:ok, target_id, target_info} ->
          # Atomic deduct — prevents TOCTOU race with snapshot
          case Arena.Map.MapServer.deduct_gold(state.map_id, state.character_id, amount) do
            {:ok, new_gold} ->
              # Credit target (async is fine — we already atomically deducted from sender)
              target_map = target_info.map_id
              Arena.Map.MapServer.modify_gold(target_map, target_id, amount)
              {state, [
                {:update_gold, %{gold: new_gold}},
                {:console_msg, %{message: "Has transferido #{amount} oro a #{name}.", font_index: 0}}
              ]}

            {:error, _reason} ->
              {state, [{:console_msg, %{message: "No tienes suficiente oro.", font_index: 0}}]}
          end

        :not_found ->
          {state, [{:console_msg, %{message: "Jugador no encontrado.", font_index: 0}}]}

        _ ->
          {state, [{:console_msg, %{message: "Cantidad invalida.", font_index: 0}}]}
      end
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
    case GameBackend.Characters.get_by_name(name) do
      nil ->
        {state, [{:console_msg, %{message: "Personaje '#{name}' no encontrado.", font_index: 0}}]}

      character ->
        case GameBackend.Account.unban(character.account_id) do
          {:ok, _} ->
            {state, [{:console_msg, %{message: "#{name} ha sido desbaneado.", font_index: 0}}]}

          {:error, reason} ->
            {state, [{:console_msg, %{message: "Error al desbanear: #{inspect(reason)}", font_index: 0}}]}
        end
    end
  end

  def handle_command(state, {:revive_char, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/REVIVE #{name}")
    {state, []}
  end

  def handle_command(state, {:summon_char, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/LOCATE #{name}")
    {state, []}
  end

  # ---- Batch 2: NPC Management ----

  # Kill NPC (ID 121) — route to /KILLNPC
  def handle_command(state, {:kill_npc, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KILLNPC")
    {state, []}
  end

  # KillNPCTargeted (ID 339) — kill NPC at target position (with respawn)
  def handle_command(state, {:kill_npc_targeted, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KILLNPC")
    {state, []}
  end

  # KillNPCNoRespawn (ID 394)
  def handle_command(state, {:kill_npc_no_respawn, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/KILLNPCPERM")
    {state, []}
  end

  # KillAllNearbyNPCs (ID 395)
  def handle_command(state, {:kill_all_nearby_npcs, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MASSKILL")
    {state, []}
  end

  # CreateNPC (ID 399) — spawn NPC without respawn
  def handle_command(state, {:create_npc, %{npc_id: npc_id}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNNPC #{npc_id}")
    {state, []}
  end

  # CreateNPCWithRespawn (ID 400)
  def handle_command(state, {:create_npc_with_respawn, %{npc_id: npc_id}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNNPCR #{npc_id}")
    {state, []}
  end

  # SpawnCreature (ID 359)
  def handle_command(state, {:spawn_creature, %{creature_id: creature_id}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNNPC #{creature_id}")
    {state, []}
  end

  # SpawnListRequest (ID 358) — list all spawnable NPC IDs
  def handle_command(state, {:spawn_list_request, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNLIST")
    {state, []}
  end

  # CreaturesInMap (ID 326)
  def handle_command(state, {:creatures_in_map, %{map: map}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CREATURES #{map}")
    {state, []}
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

  # FONTTYPE_GMMSG = 16 in the VB6 e_FontTypeNames enum (0-based).
  @fonttype_gmmsg 16

  def handle_command(state, {:gm_message, %{message: message}})
      when state.character_id != nil and state.is_gm == true do
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

  # ---- Batch 3: Character Management ----

  def handle_command(state, {:create_item, %{item_id: item_id, amount: amount}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SPAWNITEM #{item_id} #{amount}")
    {state, []}
  end

  def handle_command(state, {:give_item, %{name: name, item_id: item_id, amount: amount, reason: _reason}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/GIVEITEM #{name} #{item_id} #{amount}")
    {state, []}
  end

  def handle_command(state, {:request_char_stats, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARSTATS #{name}")
    {state, []}
  end

  def handle_command(state, {:request_char_gold, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARGOLD #{name}")
    {state, []}
  end

  def handle_command(state, {:request_char_inventory, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARINV #{name}")
    {state, []}
  end

  def handle_command(state, {:request_char_bank, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARBANK #{name}")
    {state, []}
  end

  def handle_command(state, {:request_char_skills, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHARSKILLS #{name}")
    {state, []}
  end

  def handle_command(state, {:edit_char, %{name: name, option: option, arg1: arg1, arg2: _arg2}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/EDITCHAR #{name} #{option} #{arg1}")
    {state, []}
  end

  def handle_command(state, {:alter_name, %{name: name, new_name: new_name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ALTERNAME #{name} #{new_name}")
    {state, []}
  end

  # ---- Batch 4: Punishment & Communication ----

  def handle_command(state, {:ban_cuenta, %{name: name, reason: reason}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/BANCUENTA #{name} #{reason}")
    {state, []}
  end

  def handle_command(state, {:unban_cuenta, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/UNBANCUENTA #{name}")
    {state, []}
  end

  def handle_command(state, {:ban_temporal, %{name: name, reason: reason, days: days}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/BANTEMPORAL #{name} #{days} #{reason}")
    {state, []}
  end

  def handle_command(state, {:remove_punishment, %{name: name, num: num, text: text}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/REMOVEPUNISHMENT #{name} #{num} #{text}")
    {state, []}
  end

  def handle_command(state, {:royal_army_message, %{message: message}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/RMSG #{message}")
    {state, []}
  end

  def handle_command(state, {:chaos_legion_message, %{message: message}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CMSG #{message}")
    {state, []}
  end

  def handle_command(state, {:talk_as_npc, %{message: message}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/TALKASNPC #{message}")
    {state, []}
  end

  # ---- Batch 5: Map & Environment ----

  def handle_command(state, {:nieve_toggle, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/NIEVE")
    {state, []}
  end

  def handle_command(state, {:niebla_toggle, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/NIEBLA")
    {state, []}
  end

  def handle_command(state, {:change_map_pk, %{value: value}})
      when state.character_id != nil and state.is_gm == true do
    flag = if value, do: "1", else: "0"
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MAPPK #{flag}")
    {state, []}
  end

  def handle_command(state, {:change_map_no_magic, %{value: value}})
      when state.character_id != nil and state.is_gm == true do
    flag = if value, do: "1", else: "0"
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MAPNOMAGIC #{flag}")
    {state, []}
  end

  def handle_command(state, {:change_map_no_invi, %{value: value}})
      when state.character_id != nil and state.is_gm == true do
    flag = if value, do: "1", else: "0"
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MAPNOINVI #{flag}")
    {state, []}
  end

  def handle_command(state, {:change_map_no_resu, %{value: value}})
      when state.character_id != nil and state.is_gm == true do
    flag = if value, do: "1", else: "0"
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/MAPNORESU #{flag}")
    {state, []}
  end

  def handle_command(state, {:tile_blocked_toggle, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/TILEBLOCK")
    {state, []}
  end

  def handle_command(state, {:set_trigger, %{trigger: trigger}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SETTRIGGER #{trigger}")
    {state, []}
  end

  def handle_command(state, {:ask_trigger, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ASKTRIGGER")
    {state, []}
  end

  # ---- Batch 6: Audio & Utility ----

  def handle_command(state, {:force_midi_all, %{midi: midi}})
      when state.character_id != nil and state.is_gm == true do
    raw = AoProtocol.Server.Encoder.encode({:play_midi, %{midi: midi, loops: -1}})
    AoSession.OnlineDirectory.broadcast_all({:send_raw, raw})
    {state, [{:console_msg, %{message: "MIDI #{midi} enviado a todos.", font_index: 0}}]}
  end

  def handle_command(state, {:force_wave_all, %{wave: wave}})
      when state.character_id != nil and state.is_gm == true do
    raw = AoProtocol.Server.Encoder.encode({:play_wave, %{wave: wave, x: 0, y: 0}})
    AoSession.OnlineDirectory.broadcast_all({:send_raw, raw})
    {state, [{:console_msg, %{message: "Wave #{wave} enviado a todos.", font_index: 0}}]}
  end

  def handle_command(state, {:force_midi_map, %{midi: midi, map: map}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/FORCEMIDIMAP #{midi} #{map}")
    {state, []}
  end

  def handle_command(state, {:force_wave_map, %{wave: wave, x: x, y: y, map: map}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/FORCEWAVEMAP #{wave} #{x} #{y} #{map}")
    {state, []}
  end

  def handle_command(state, {:items_in_floor, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ITEMSFLOOR")
    {state, []}
  end

  def handle_command(state, {:destroy_items, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/DESTROYITEMS")
    {state, []}
  end

  def handle_command(state, {:destroy_all_area, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/DESTROYALLAREA")
    {state, []}
  end

  def handle_command(state, {:clean_world, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CLEANWORLD")
    {state, []}
  end

  def handle_command(state, {:show_name, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SHOWNAME")
    {state, []}
  end

  def handle_command(state, {:set_description, %{desc: desc}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SETDESC #{desc}")
    {state, []}
  end

  def handle_command(state, {:set_speed, %{speed: speed}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/SETSPEED #{speed}")
    {state, []}
  end

  def handle_command(state, {:nick_to_ip, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    case AoSession.OnlineDirectory.lookup_by_name(name) do
      {:ok, session} ->
        ip = Map.get(session, :ip, "desconocida")
        {state, [{:console_msg, %{message: "IP de #{name}: #{ip}", font_index: 0}}]}

      :not_found ->
        {state, [{:console_msg, %{message: "Jugador #{name} no encontrado.", font_index: 0}}]}
    end
  end

  def handle_command(state, {:ip_to_nick, %{ip: ip}})
      when state.character_id != nil and state.is_gm == true do
    names = AoSession.OnlineDirectory.list_all_names()
    {state, [{:console_msg, %{message: "Busqueda IP #{ip}: #{Enum.join(names, ", ")}", font_index: 0}}]}
  end

  def handle_command(state, {:check_slot, %{name: name, slot: slot}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHECKSLOT #{name} #{slot}")
    {state, []}
  end

  # ---- Batch 7: Faction/Council + SOS ----

  def handle_command(state, {:council_kick, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/COUNCILKICK #{name}")
    {state, []}
  end

  def handle_command(state, {:accept_royal_council, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ROYALCOUNCIL #{name}")
    {state, []}
  end

  def handle_command(state, {:accept_chaos_council, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHAOSCOUNCIL #{name}")
    {state, []}
  end

  def handle_command(state, {:royal_army_kick, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ROYALKICK #{name}")
    {state, []}
  end

  def handle_command(state, {:chaos_legion_kick, %{name: name}})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/CHAOSKICK #{name}")
    {state, []}
  end

  def handle_command(state, {:sos_show_list, _})
      when state.character_id != nil and state.is_gm == true do
    {state, [{:console_msg, %{message: "Lista de SOS: (vacia)", font_index: 0}}]}
  end

  def handle_command(state, {:sos_remove, %{name: _name}})
      when state.character_id != nil and state.is_gm == true do
    {state, [{:console_msg, %{message: "SOS removido.", font_index: 0}}]}
  end

  def handle_command(state, {:clean_sos, _})
      when state.character_id != nil and state.is_gm == true do
    {state, [{:console_msg, %{message: "Lista de SOS limpiada.", font_index: 0}}]}
  end

  # ---- Batch 1: Essential Server Admin ----

  def handle_command(state, {:online, _})
      when state.character_id != nil and state.is_gm == true do
    names = AoSession.OnlineDirectory.list_all_names()
    count = length(names)
    name_list = Enum.join(names, ", ")
    {state, [{:console_msg, %{message: "Jugadores online (#{count}): #{name_list}", font_index: 0}}]}
  end

  def handle_command(state, {:online_map, _})
      when state.character_id != nil and state.is_gm == true do
    Arena.Map.MapServer.chat(state.map_id, state.character_id, "/ONLINEMAP")
    {state, []}
  end

  def handle_command(state, {:kick_all_chars, _})
      when state.character_id != nil and state.is_gm == true do
    AoSession.OnlineDirectory.broadcast_all(:disconnect)
    {state, [{:console_msg, %{message: "Todos los jugadores han sido expulsados.", font_index: 0}}]}
  end

  def handle_command(state, {:server_open_toggle, _})
      when state.character_id != nil and state.is_gm == true do
    # Toggle server open state - for now just acknowledge
    {state, [{:console_msg, %{message: "Server open/close toggle recibido.", font_index: 0}}]}
  end

  def handle_command(state, {:save_chars, _})
      when state.character_id != nil and state.is_gm == true do
    # Trigger save for all online characters
    AoSession.OnlineDirectory.broadcast_all(:force_save)
    {state, [{:console_msg, %{message: "Guardado de personajes iniciado.", font_index: 0}}]}
  end

  def handle_command(state, {:global_message, %{message: message}})
      when state.character_id != nil and state.is_gm == true do
    if byte_size(message) > 0 do
      raw =
        AoProtocol.Server.Encoder.encode(
          {:console_msg, %{message: "Servidor> #{message}", font_index: 0}}
        )

      AoSession.OnlineDirectory.broadcast_all({:send_raw, raw})
    end

    {state, []}
  end

  # RoleMasterRequest (ID 63) — any player sends a question to RoleMasters.
  # VB6: reads request string, forwards to online RoleMasters, confirms to player.
  def handle_command(state, {:role_master_request, %{request: request}})
      when state.character_id != nil do
    if request != "" do
      player_name = resolve_char_name(state.character_id)

      raw =
        AoProtocol.Server.Encoder.encode(
          {:console_msg, %{message: "#{player_name} PREGUNTA ROL: #{request}", font_index: 3}}
        )

      AoSession.OnlineDirectory.broadcast_to_gms({:send_raw, raw})
      {state, [{:console_msg, %{message: "Su solicitud ha sido enviada.", font_index: 0}}]}
    else
      {state, []}
    end
  end

  # QuestionGM (ID 215) — player sends a support question to online admins.
  # VB6: reads consulta + tipo, pushes to Ayuda queue, notifies admins, confirms.
  def handle_command(state, {:question_gm, %{consulta: consulta, tipo: tipo}})
      when state.character_id != nil do
    if consulta != "" do
      player_name = resolve_char_name(state.character_id)

      raw =
        AoProtocol.Server.Encoder.encode(
          {:console_msg,
           %{
             message: "Se ha recibido un nuevo mensaje de soporte de #{player_name}.",
             font_index: 1
           }}
        )

      AoSession.OnlineDirectory.broadcast_to_gms({:send_raw, raw})
      Logger.info("QuestionGM from #{player_name} (#{tipo}): #{consulta}")

      {state,
       [{:console_msg, %{message: "Tu mensaje fue recibido por el equipo de soporte.", font_index: 0}}]}
    else
      {state, []}
    end
  end

  # Catch-all for GM commands attempted without privileges
  @gm_command_types [
    :go_to_char, :warp_me_to_target, :warp_char, :invisible, :silence,
    :jail, :kick, :execute, :ban_char, :unban_char, :revive_char,
    :summon_char, :kill_npc, :request_char_info, :where, :gm_message,
    :server_message, :online_gm, :rain_toggle,
    :online, :online_map, :kick_all_chars, :server_open_toggle, :save_chars, :global_message,
    :kill_npc_targeted, :kill_npc_no_respawn, :kill_all_nearby_npcs,
    :create_npc, :create_npc_with_respawn, :spawn_creature, :spawn_list_request, :creatures_in_map,
    :create_item, :give_item, :request_char_stats, :request_char_gold,
    :request_char_inventory, :request_char_bank, :request_char_skills, :edit_char, :alter_name,
    # Batch 4: Punishment & Communication
    :ban_cuenta, :unban_cuenta, :ban_temporal, :remove_punishment,
    :royal_army_message, :chaos_legion_message, :talk_as_npc,
    # Batch 5: Map & Environment
    :nieve_toggle, :niebla_toggle, :change_map_pk, :change_map_no_magic,
    :change_map_no_invi, :change_map_no_resu, :tile_blocked_toggle, :set_trigger, :ask_trigger,
    # Batch 6: Audio & Utility
    :force_midi_all, :force_wave_all, :force_midi_map, :force_wave_map,
    :items_in_floor, :destroy_items, :destroy_all_area, :clean_world,
    :show_name, :set_description, :set_speed, :nick_to_ip, :ip_to_nick, :check_slot,
    # Batch 7: Faction/Council + SOS
    :council_kick, :accept_royal_council, :accept_chaos_council,
    :royal_army_kick, :chaos_legion_kick, :sos_show_list, :sos_remove, :clean_sos
  ]

  def handle_command(state, {cmd_type, _})
      when state.character_id != nil and cmd_type in @gm_command_types do
    {state, [@gm_not_authorized_msg]}
  end

  # ---- Quest commands ----

  def handle_command(state, {:quest, _}) when state.character_id != nil do
    Arena.Map.MapServer.quest(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:quest_list_request, _}) when state.character_id != nil do
    Arena.Map.MapServer.quest_list_request(state.map_id, state.character_id)
    {state, []}
  end

  def handle_command(state, {:quest_details_request, %{quest_slot: slot}})
      when state.character_id != nil do
    Arena.Map.MapServer.quest_details_request(state.map_id, state.character_id, slot)
    {state, []}
  end

  def handle_command(state, {:quest_accept, %{list_index: index}})
      when state.character_id != nil do
    Arena.Map.MapServer.quest_accept(state.map_id, state.character_id, index)
    {state, []}
  end

  def handle_command(state, {:quest_abandon, %{quest_slot: slot}})
      when state.character_id != nil do
    Arena.Map.MapServer.quest_abandon(state.map_id, state.character_id, slot)
    {state, []}
  end

  def handle_command(state, {command_type, _}) do
    Logger.debug("Unhandled command: #{command_type}")
    {state, []}
  end

  # ---- Auction info helper (must be after all handle_command clauses) ----

  defp build_auction_info_messages(info) do
    seller_name =
      case AoSession.OnlineDirectory.lookup_by_id(info.seller_id) do
        {:ok, s} -> s.name
        _ -> "?"
      end

    base = [
      {:console_msg, %{message: "Subastador: #{seller_name}", font_index: 0}},
      {:console_msg,
       %{message: "Objeto: item ##{info.item_id} (x#{info.item_amount})", font_index: 0}}
    ]

    offer_msgs =
      if info.had_bid do
        min_next = info.best_offer + 100

        [
          {:console_msg, %{message: "Mejor oferta: #{info.best_offer}", font_index: 0}},
          {:console_msg,
           %{
             message: "Podes realizar una oferta escribiendo /OFERTAR #{min_next}",
             font_index: 0
           }}
        ]
      else
        min_next = info.initial_offer + 100

        [
          {:console_msg, %{message: "Oferta inicial: #{info.initial_offer}", font_index: 0}},
          {:console_msg,
           %{
             message: "Podes realizar una oferta escribiendo /OFERTAR #{min_next}",
             font_index: 0
           }}
        ]
      end

    time_msg =
      {:console_msg,
       %{message: "Tiempo restante de subasta: #{info.time_remaining}s", font_index: 0}}

    base ++ offer_msgs ++ [time_msg]
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

  @doc false
  def parse_marriage_command(message) do
    upper = String.upcase(String.trim(message))

    cond do
      String.starts_with?(upper, "/PROPONER ") ->
        name = String.trim(String.slice(message, 10..-1//1))
        {:propose, name}

      upper == "/DIVORCIAR" ->
        :divorce

      true ->
        :not_marriage_command
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

  # ── Duel (reto) command parser ─────────────────────────────────────────

  @doc false
  def parse_duel_command(message) do
    upper = String.upcase(String.trim(message))

    cond do
      String.starts_with?(upper, "/RETAR ") ->
        rest = String.trim(String.slice(message, 7..-1//1))

        case String.split(rest, ~r/\s+/, parts: 2) do
          [target_name, bet_str] ->
            case Integer.parse(bet_str) do
              {bet, _} when bet > 0 -> {:retar, target_name, bet}
              _ -> :not_duel_command
            end

          _ ->
            :not_duel_command
        end

      String.starts_with?(upper, "/ACEPTAR ") ->
        name = String.trim(String.slice(message, 9..-1//1))
        if String.length(name) > 0, do: {:aceptar, name}, else: :not_duel_command

      upper == "/CANCELAR" ->
        :cancelar_reto

      upper == "/ABANDONAR" ->
        :abandonar_reto

      true ->
        :not_duel_command
    end
  end

  defp handle_duel_challenge(state, target_name, bet) do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, target_id, _info} ->
        case Arena.DuelServer.create_challenge(state.character_id, target_id, bet) do
          :ok ->
            # Notify target
            notify_duel_target(target_id, state.character_id, bet)
            send_console(state, "Has enviado una solicitud de reto a #{target_name}. Apuesta: #{bet} monedas de oro.")
            send_console(state, "Escribe /CANCELAR para anular la solicitud.")

          {:error, :cannot_challenge_self} ->
            send_console(state, "No puedes retarte a ti mismo.")

          {:error, :invalid_bet} ->
            send_console(state, "La apuesta debe ser mayor a 0.")

          {:error, :already_in_duel} ->
            send_console(state, "Ya te encuentras en un reto.")

          {:error, :target_in_duel} ->
            send_console(state, "El jugador ya se encuentra en un reto.")

          {:error, :already_has_challenge} ->
            send_console(state, "Ya tienes una solicitud de reto pendiente. Escribe /CANCELAR para cancelarla.")

          {:error, _} ->
            send_console(state, "No se pudo crear el reto.")
        end

        {state, []}

      :not_found ->
        send_console(state, "Jugador no encontrado.")
        {state, []}
    end
  end

  defp handle_duel_accept(state, challenger_name) do
    case Arena.DuelServer.accept_challenge(state.character_id, challenger_name) do
      {:ok, duel} ->
        # Notify both players and set duel flags on their entities
        start_duel_on_map(state, duel)
        {state, []}

      {:error, :no_pending_challenge} ->
        send_console(state, "No tienes ninguna invitacion de reto pendiente.")
        {state, []}

      {:error, :already_in_duel} ->
        send_console(state, "Ya te encuentras en un reto.")
        {state, []}

      {:error, _} ->
        send_console(state, "No se pudo aceptar el reto.")
        {state, []}
    end
  end

  defp handle_duel_cancel(state) do
    case Arena.DuelServer.cancel_challenge(state.character_id) do
      :ok ->
        send_console(state, "Has cancelado la solicitud de reto.")

      {:error, :no_challenge} ->
        send_console(state, "No tienes ninguna solicitud de reto.")
    end

    {state, []}
  end

  defp handle_duel_abandon(state) do
    case Arena.DuelServer.abandon_duel(state.character_id) do
      {:ok, result} ->
        handle_duel_result(state, result)

      {:error, :not_in_duel} ->
        send_console(state, "No te encuentras en un reto.")
    end

    {state, []}
  end

  defp notify_duel_target(target_id, challenger_id, bet) do
    challenger_name =
      case AoSession.OnlineDirectory.lookup_by_id(challenger_id) do
        {:ok, info} -> info.name
        _ -> "Unknown"
      end

    msg =
      AoProtocol.Server.Encoder.encode(
        {:console_msg,
         %{
           message:
             "#{challenger_name} te invita a un reto. Apuesta: #{bet} monedas de oro. " <>
               "Escribe /ACEPTAR #{challenger_name} para participar.",
           font_index: 0
         }}
      )

    case AoSession.OnlineDirectory.lookup_by_id(target_id) do
      {:ok, info} -> send(info.session_pid, {:send_raw, msg})
      _ -> :ok
    end
  end

  defp start_duel_on_map(state, duel) do
    # Set duel flags on both players' entities via their map servers
    # Player A
    set_duel_flags(duel.player_a, duel.player_b)
    # Player B
    set_duel_flags(duel.player_b, duel.player_a)

    # Notify both
    player_a_name = resolve_char_name(duel.player_a)
    player_b_name = resolve_char_name(duel.player_b)

    notify_duel_start(duel.player_a, player_b_name, duel.bet)
    notify_duel_start(duel.player_b, player_a_name, duel.bet)
    _ = state
  end

  defp set_duel_flags(char_id, opponent_id) do
    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} ->
        Arena.Map.MapServer.set_duel_state(info.map_id, char_id, true, opponent_id)

      _ ->
        :ok
    end
  end

  defp clear_duel_flags(char_id) do
    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} ->
        Arena.Map.MapServer.set_duel_state(info.map_id, char_id, false, nil)

      _ ->
        :ok
    end
  end

  defp notify_duel_start(char_id, opponent_name, bet) do
    msg =
      AoProtocol.Server.Encoder.encode(
        {:console_msg,
         %{
           message:
             "Ha comenzado el reto contra #{opponent_name}! Apuesta: #{bet} monedas de oro. " <>
               "Escribe /ABANDONAR para admitir la derrota.",
           font_index: 5
         }}
      )

    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} -> send(info.session_pid, {:send_raw, msg})
      _ -> :ok
    end
  end

  defp handle_duel_result(_state, %{type: :winner, winner: winner_id, loser: loser_id, prize: prize}) do
    winner_name = resolve_char_name(winner_id)
    loser_name = resolve_char_name(loser_id)

    # Award gold to winner via map server
    case AoSession.OnlineDirectory.lookup_by_id(winner_id) do
      {:ok, info} ->
        Arena.Map.MapServer.modify_gold(info.map_id, winner_id, prize)

      _ ->
        :ok
    end

    # Notify winner
    notify_duel_end(winner_id, "Has ganado el reto contra #{loser_name}! Ganas #{prize} monedas de oro.")
    # Notify loser
    notify_duel_end(loser_id, "Has perdido el reto contra #{winner_name}.")
    # Clear duel flags
    clear_duel_flags(winner_id)
    clear_duel_flags(loser_id)
  end

  defp handle_duel_result(_state, %{type: :tie, player_a: a, player_b: b, refund: refund}) do
    # Refund both
    for id <- [a, b] do
      case AoSession.OnlineDirectory.lookup_by_id(id) do
        {:ok, info} -> Arena.Map.MapServer.modify_gold(info.map_id, id, refund)
        _ -> :ok
      end

      notify_duel_end(id, "El reto ha terminado en empate. Se devuelven #{refund} monedas de oro.")
      clear_duel_flags(id)
    end
  end

  defp notify_duel_end(char_id, message) do
    msg =
      AoProtocol.Server.Encoder.encode(
        {:console_msg, %{message: message, font_index: 5}}
      )

    case AoSession.OnlineDirectory.lookup_by_id(char_id) do
      {:ok, info} -> send(info.session_pid, {:send_raw, msg})
      _ -> :ok
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
