defmodule AoTcpGateway.SessionCommands.Guild do
  @moduledoc """
  Guild command handlers — both binary UI packets and text commands parsed from /talk.

  Handles guild creation, invites, kicks, news, wars, membership requests,
  clan codex, guild details UI, and disabled relation stubs.
  """

  import AoTcpGateway.SessionHelpers, only: [send_console: 1, resolve_char_name: 1]

  @guild_relations_disabled "Relaciones de clan desactivadas por el momento."

  # ---- Text-based guild commands (dispatched from Chat module's talk parser) ----

  def handle_talk_guild(state, {:guild_create, name}) do
    alignment =
      case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
        {:ok, entity} -> Arena.GuildAlignment.from_character(entity)
        _ -> 0
      end

    Arena.GuildServer.create_guild(state.character_id, name, alignment)
    {state, []}
  end

  def handle_talk_guild(state, {:guild_invite, target_name}) do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, target_id, _info} ->
        Arena.GuildServer.invite(state.character_id, target_id)
      :not_found ->
        send_console("Jugador no encontrado.")
    end
    {state, []}
  end

  def handle_talk_guild(state, :guild_accept) do
    case Arena.GuildServer.accept_invite(state.character_id) do
      :ok ->
        case Arena.GuildServer.get_guild(state.character_id) do
          {:ok, guild} ->
            Arena.Map.MapServer.update_guild_cache(state.map_id, state.character_id, guild.id, guild.level)
          _ -> :ok
        end
      _ -> :ok
    end
    {state, []}
  end

  def handle_talk_guild(state, :guild_leave) do
    case Arena.GuildServer.leave(state.character_id) do
      :ok -> Arena.Map.MapServer.update_guild_cache(state.map_id, state.character_id, 0, 0)
      _ -> :ok
    end
    {state, []}
  end

  def handle_talk_guild(state, {:guild_kick, target_name}) do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, target_id, _info} ->
        case Arena.GuildServer.kick(state.character_id, target_id) do
          :ok ->
            case AoSession.OnlineDirectory.lookup_by_id(target_id) do
              {:ok, info} ->
                Arena.Map.MapServer.update_guild_cache(info.map_id, target_id, 0, 0)
              _ -> :ok
            end
          _ -> :ok
        end
      :not_found ->
        send_console("Jugador no encontrado.")
    end
    {state, []}
  end

  def handle_talk_guild(state, {:guild_chat, guild_message}) do
    Arena.GuildServer.guild_chat(state.character_id, guild_message)
    {state, []}
  end

  def handle_talk_guild(state, {:guild_news, text}) do
    Arena.GuildServer.set_guild_news(state.character_id, text)
    {state, []}
  end

  def handle_talk_guild(state, :guild_news_read) do
    case Arena.GuildServer.get_guild(state.character_id) do
      {:ok, guild} ->
        Arena.GuildServer.send_guild_news(state.character_id, guild)
        {state, []}
      :not_in_guild ->
        {state, []}
    end
  end

  def handle_talk_guild(state, {:guild_desc, text}) do
    Arena.GuildServer.set_guild_description(state.character_id, text)
    {state, []}
  end

  def handle_talk_guild(state, :guild_online) do
    case Arena.GuildServer.guild_online(state.character_id) do
      {:ok, names} ->
        msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: "Miembros online: #{Enum.join(names, ", ")}", font_index: 0}})
        {state, [{:send_raw, msg}]}
      :not_in_guild ->
        {state, []}
    end
  end

  def handle_talk_guild(state, :guild_info) do
    case Arena.GuildServer.guild_info(state.character_id) do
      {:ok, guild, _required} ->
        Arena.GuildServer.send_guild_details(state.character_id, guild)
        {state, []}
      :not_in_guild ->
        {state, []}
    end
  end

  def handle_talk_guild(state, {:guild_war, target_name}) do
    Arena.GuildServer.declare_war(state.character_id, target_name)
    {state, []}
  end

  def handle_talk_guild(state, {:guild_peace, _target_name}) do
    msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: @guild_relations_disabled, font_index: 0}})
    {state, [{:send_raw, msg}]}
  end

  def handle_talk_guild(state, {:guild_alliance, _target_name}) do
    msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: @guild_relations_disabled, font_index: 0}})
    {state, [{:send_raw, msg}]}
  end

  def handle_talk_guild(state, {:guild_request, guild_name, desc}) do
    Arena.GuildServer.request_membership(state.character_id, guild_name, desc)
    {state, []}
  end

  def handle_talk_guild(state, :guild_list_requests) do
    Arena.GuildServer.list_requests(state.character_id)
    {state, []}
  end

  def handle_talk_guild(state, {:guild_accept_request, target_name}) do
    Arena.GuildServer.accept_request(state.character_id, target_name)
    {state, []}
  end

  def handle_talk_guild(state, {:guild_reject_request, target_name}) do
    Arena.GuildServer.reject_request(state.character_id, target_name)
    {state, []}
  end

  # ---- Binary UI guild packets (handle_command/2) ----

  def handle_command(state, {:guild_create, %{name: name, alignment: alignment}}) do
    case Arena.GuildServer.create_guild(state.character_id, name, alignment) do
      :ok ->
        case Arena.GuildServer.get_guild(state.character_id) do
          {:ok, guild} ->
            Arena.Map.MapServer.update_guild_cache(state.map_id, state.character_id, guild.id, guild.level)
          _ -> :ok
        end
      _ -> :ok
    end
    {state, []}
  end

  def handle_command(state, {:guild_leave, _}) do
    case Arena.GuildServer.leave(state.character_id) do
      :ok -> Arena.Map.MapServer.update_guild_cache(state.map_id, state.character_id, 0, 0)
      _ -> :ok
    end
    {state, []}
  end

  def handle_command(state, {:guild_message, %{message: msg}}) do
    if state.is_dead == true do
      {state, []}
    else
      Arena.GuildServer.guild_chat(state.character_id, msg)
      {state, []}
    end
  end

  def handle_command(state, {:guild_online, _}) do
    case Arena.GuildServer.guild_online(state.character_id) do
      {:ok, names} ->
        msg = AoProtocol.Server.Encoder.encode({:console_msg, %{message: "Miembros online: #{Enum.join(names, ", ")}", font_index: 0}})
        {state, [{:send_raw, msg}]}
      :not_in_guild ->
        {state, []}
    end
  end

  def handle_command(state, {:guild_declare_war, %{guild: guild_name}}) do
    Arena.GuildServer.declare_war(state.character_id, guild_name)
    {state, []}
  end

  def handle_command(state, {:guild_kick_member, %{username: target_name}}) do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, target_id, _info} ->
        case Arena.GuildServer.kick(state.character_id, target_id) do
          :ok ->
            case AoSession.OnlineDirectory.lookup_by_id(target_id) do
              {:ok, info} ->
                Arena.Map.MapServer.update_guild_cache(info.map_id, target_id, 0, 0)
              _ -> :ok
            end
          _ -> :ok
        end
      :not_found -> send_console("Jugador no encontrado.")
    end
    {state, []}
  end

  def handle_command(state, {:guild_update_news, %{news: news}}) do
    Arena.GuildServer.set_guild_news(state.character_id, news)
    {state, []}
  end

  def handle_command(state, {:guild_request_membership, %{guild: guild_name, application: desc}}) do
    Arena.GuildServer.request_membership(state.character_id, guild_name, desc)
    {state, []}
  end

  def handle_command(state, {:guild_accept_new_member, %{username: target_name}}) do
    case Arena.GuildServer.accept_request(state.character_id, target_name) do
      :ok ->
        case AoSession.OnlineDirectory.lookup_by_name(target_name) do
          {:ok, target_id, _info} ->
            case Arena.GuildServer.get_guild(target_id) do
              {:ok, guild} ->
                case AoSession.OnlineDirectory.lookup_by_id(target_id) do
                  {:ok, info} ->
                    Arena.Map.MapServer.update_guild_cache(info.map_id, target_id, guild.id, guild.level)
                  _ -> :ok
                end
              _ -> :ok
            end
          _ -> :ok
        end
      _ -> :ok
    end
    {state, []}
  end

  def handle_command(state, {:guild_reject_new_member, %{username: target_name}}) do
    Arena.GuildServer.reject_request(state.character_id, target_name)
    {state, []}
  end

  def handle_command(state, {:guild_request_details, %{guild: guild_name}}) do
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
        send_console("Clan no encontrado.")
        {state, []}
    end
  end

  def handle_command(state, {:request_guild_leader_info, _}) do
    case Arena.GuildServer.guild_info(state.character_id) do
      {:ok, guild, required} ->
        member_names = for mid <- guild.members, do: resolve_char_name(mid)
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

  # ---- Guild relation stubs ----

  def handle_command(state, {:guild_accept_peace, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_reject_peace, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_accept_alliance, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_reject_alliance, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_offer_peace, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_offer_alliance, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_alliance_details, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_peace_details, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_alliance_prop_list, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_peace_prop_list, _}), do: {state, [{:console_msg, %{message: @guild_relations_disabled, font_index: 0}}]}
  def handle_command(state, {:guild_open_elections, _}), do: {state, [{:console_msg, %{message: "Elecciones de clan desactivadas por el momento.", font_index: 0}}]}
  def handle_command(state, {:guild_vote, _}), do: {state, [{:console_msg, %{message: "Elecciones de clan desactivadas por el momento.", font_index: 0}}]}

  def handle_command(state, {:guild_request_joiner_info, %{username: name}}) do
    handle_command(state, {:guild_member_info, %{username: name}})
  end

  def handle_command(state, {:guild_new_website, %{website: url}}) do
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

  def handle_command(state, {:guild_member_info, %{username: name}}) do
    case AoSession.OnlineDirectory.lookup_by_name(name) do
      {:ok, _target_id, info} ->
        msg = "#{name} - Mapa: #{info.map_id}"
        {state, [{:console_msg, %{message: msg, font_index: 0}}]}
      :not_found ->
        {state, [{:console_msg, %{message: "Jugador '#{name}' no encontrado o desconectado.", font_index: 0}}]}
    end
  end

  # Clan codex update — same as guild description
  def handle_command(state, {:clan_codex_update, %{description: desc}}) do
    Arena.GuildServer.set_guild_description(state.character_id, desc)
    {state, []}
  end

  # ---- Text command parser (used by Chat module) ----

  def parse_guild_command(message) do
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
end
