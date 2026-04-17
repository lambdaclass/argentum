defmodule Arena.GuildServer do
  @moduledoc """
  Global guild/clan system. GenServer serializes mutations; ETS provides O(1) reads.
  Guilds are persisted to DB via write-through (GameBackend.Guilds).
  ETS is the fast-read path; DB is loaded into ETS on init.
  """

  use GenServer

  require Logger

  alias AoSession.OnlineDirectory
  alias GameBackend.Guilds
  alias Arena.GuildConstants
  alias Arena.GuildAlignment

  @table :ao_guilds
  @max_members 50
  @invite_ttl_ms 60_000

  # ---- Public API (reads go straight to ETS) ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create a new guild. The creator becomes the leader. Alignment is set from founder."
  def create_guild(char_id, name, alignment \\ 0) do
    GenServer.call(__MODULE__, {:create, char_id, name, alignment})
  end

  @doc "Invite a player to the guild."
  def invite(leader_id, target_id) do
    GenServer.call(__MODULE__, {:invite, leader_id, target_id})
  end

  @doc "Accept a pending guild invite."
  def accept_invite(char_id) do
    GenServer.call(__MODULE__, {:accept, char_id})
  end

  @doc "Leave current guild. Dissolves if leader and no members remain."
  def leave(char_id) do
    GenServer.call(__MODULE__, {:leave, char_id})
  end

  @doc "Leader kicks a member."
  def kick(leader_id, target_id) do
    GenServer.call(__MODULE__, {:kick, leader_id, target_id})
  end

  @doc "Get guild info for a player. Pure ETS read."
  def get_guild(char_id) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, guild_id}] ->
        case :ets.lookup(@table, {:guild, guild_id}) do
          [{_, guild}] -> {:ok, guild}
          [] -> :not_in_guild
        end

      [] ->
        :not_in_guild
    end
  end

  @doc "Check if two players are in the same guild. Pure ETS read."
  def same_guild?(a, b) do
    case {:ets.lookup(@table, {:member, a}), :ets.lookup(@table, {:member, b})} do
      {[{_, ga}], [{_, gb}]} -> ga == gb
      _ -> false
    end
  end

  @doc """
  Send a chat message to all guild members.
  Returns `{:ok, member_ids}` so the caller can deliver packets,
  or `{:error, reason}`.
  """
  def guild_chat(char_id, message) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, guild_id}] ->
        case :ets.lookup(@table, {:guild, guild_id}) do
          [{_, guild}] ->
            sender_name =
              case OnlineDirectory.lookup_by_id(char_id) do
                {:ok, info} -> info.name
                :not_found -> "?"
              end

            raw =
              AoProtocol.Server.Encoder.encode({:guild_chat, %{status: 0, message: "#{sender_name}: #{message}"}})

            for mid <- guild.members do
              case OnlineDirectory.lookup_by_id(mid) do
                {:ok, %{session_pid: pid}} -> send(pid, {:send_raw, raw})
                _ -> :ok
              end
            end

            {:ok, guild.members}

          [] ->
            {:error, :not_in_guild}
        end

      [] ->
        {:error, :not_in_guild}
    end
  end

  @doc "Award guild XP (async). Triggers level-up if threshold is met."
  def add_guild_exp(guild_id, amount) when amount > 0 do
    GenServer.cast(__MODULE__, {:add_exp, guild_id, amount})
  end

  def add_guild_exp(_guild_id, _amount), do: :ok

  @doc "Set guild news (leader only)."
  def set_guild_news(char_id, news) do
    GenServer.call(__MODULE__, {:set_news, char_id, news})
  end

  @doc "Set guild description (leader only)."
  def set_guild_description(char_id, description) do
    GenServer.call(__MODULE__, {:set_description, char_id, description})
  end

  @doc "Set guild website URL (leader only)."
  def update_website(char_id, url) do
    GenServer.call(__MODULE__, {:set_website, char_id, url})
  end

  @doc "Get guild info for display. Pure ETS read."
  def guild_info(char_id) do
    case get_guild(char_id) do
      {:ok, guild} ->
        required = GuildConstants.required_exp(guild.level)
        {:ok, guild, required}

      :not_in_guild ->
        :not_in_guild
    end
  end

  @doc "Get list of online guild member names. Pure ETS + OnlineDirectory read."
  def guild_online(char_id) do
    case get_guild(char_id) do
      {:ok, guild} ->
        names =
          for mid <- guild.members,
              {:ok, info} <- [OnlineDirectory.lookup_by_id(mid)] do
            info.name
          end

        {:ok, names}

      :not_in_guild ->
        :not_in_guild
    end
  end

  @doc "Look up guild_id for a char_id from ETS. Returns nil if not in a guild."
  def guild_id_for(char_id) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, guild_id}] -> guild_id
      [] -> nil
    end
  end

  @doc "Check if two guilds are at war. Pure ETS read."
  def at_war?(guild_a, guild_b) when is_integer(guild_a) and is_integer(guild_b) do
    {a, b} = if guild_a <= guild_b, do: {guild_a, guild_b}, else: {guild_b, guild_a}

    case :ets.lookup(@table, {:relation, a, b}) do
      [{_, "war"}] -> true
      _ -> false
    end
  end

  def at_war?(_, _), do: false

  @doc "Check if two players are in guilds at war."
  def players_at_war?(char_a, char_b) do
    case {guild_id_for(char_a), guild_id_for(char_b)} do
      {nil, _} -> false
      {_, nil} -> false
      {ga, gb} when ga == gb -> false
      {ga, gb} -> at_war?(ga, gb)
    end
  end

  @doc "Get relation between two guilds. Pure ETS read."
  def get_relation(guild_a, guild_b) do
    {a, b} = if guild_a <= guild_b, do: {guild_a, guild_b}, else: {guild_b, guild_a}

    case :ets.lookup(@table, {:relation, a, b}) do
      [{_, type}] -> type
      [] -> "peace"
    end
  end

  @doc "Declare war on another guild (leader only)."
  def declare_war(char_id, target_guild_name) do
    GenServer.call(__MODULE__, {:declare_war, char_id, target_guild_name})
  end

  @doc "Propose peace to a guild at war (leader only)."
  def propose_peace(char_id, target_guild_name) do
    GenServer.call(__MODULE__, {:propose_peace, char_id, target_guild_name})
  end

  @doc "Propose alliance with another guild (leader only)."
  def propose_alliance(char_id, target_guild_name) do
    GenServer.call(__MODULE__, {:propose_alliance, char_id, target_guild_name})
  end

  @doc "Request membership in a guild."
  def request_membership(char_id, guild_name, description \\ "") do
    GenServer.call(__MODULE__, {:request_membership, char_id, guild_name, description})
  end

  @doc "List pending requests (leader only)."
  def list_requests(char_id) do
    GenServer.call(__MODULE__, {:list_requests, char_id})
  end

  @doc "Accept a membership request (leader only)."
  def accept_request(leader_id, target_name) do
    GenServer.call(__MODULE__, {:accept_request, leader_id, target_name})
  end

  @doc "Reject a membership request (leader only)."
  def reject_request(leader_id, target_name) do
    GenServer.call(__MODULE__, {:reject_request, leader_id, target_name})
  end

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Process.send_after(self(), :cleanup_invites, @invite_ttl_ms)

    # Load persisted guilds from DB into ETS
    next_id = load_guilds_from_db()
    load_relations_from_db()

    {:ok, %{next_guild_id: next_id}}
  end

  @impl true
  def handle_call({:create, char_id, name, alignment}, _from, state) do
    name = String.trim(name)

    cond do
      String.length(name) < 3 ->
        notify(char_id, "El nombre del clan es muy corto (minimo 3 caracteres).")
        {:reply, {:error, :name_too_short}, state}

      String.length(name) > 30 ->
        notify(char_id, "El nombre del clan es muy largo (maximo 30 caracteres).")
        {:reply, {:error, :name_too_long}, state}

      :ets.lookup(@table, {:member, char_id}) != [] ->
        notify(char_id, "Ya perteneces a un clan.")
        {:reply, {:error, :already_in_guild}, state}

      true ->
        result =
          try do
            Guilds.create_guild(char_id, name, alignment)
          rescue
            e ->
              Logger.error("Guild create_guild raised for char #{char_id}: #{inspect(e)}")
              {:error, :exception}
          end

        case result do
          {:ok, db_guild} ->
            guild_id = db_guild.id

            guild = %{
              id: guild_id,
              name: name,
              leader: char_id,
              founder_id: char_id,
              created_at: db_guild.inserted_at,
              members: [char_id],
              level: 1,
              current_exp: 0,
              description: "",
              news: "",
              url: "",
              alignment: alignment
            }

            :ets.insert(@table, {{:guild, guild_id}, guild})
            :ets.insert(@table, {{:member, char_id}, guild_id})

            next_id = max(state.next_guild_id, guild_id + 1)
            notify(char_id, "Clan '#{name}' creado exitosamente.")
            {:reply, :ok, %{state | next_guild_id: next_id}}

          {:error, _reason} ->
            Logger.error("Failed to persist guild creation for char #{char_id}")
            notify(char_id, "Error al crear el clan. Intenta de nuevo.")
            {:reply, {:error, :db_error}, state}
        end
    end
  end

  @impl true
  def handle_call({:invite, leader_id, target_id}, _from, state) do
    cond do
      leader_id == target_id ->
        {:reply, {:error, :self_invite}, state}

      :ets.lookup(@table, {:member, leader_id}) == [] ->
        notify(leader_id, "No perteneces a ningun clan.")
        {:reply, {:error, :not_in_guild}, state}

      true ->
        [{_, guild_id}] = :ets.lookup(@table, {:member, leader_id})

        case :ets.lookup(@table, {:guild, guild_id}) do
          [{_, %{leader: ^leader_id} = guild}] ->
            cond do
              length(guild.members) >= @max_members ->
                notify(leader_id, "El clan esta lleno.")
                {:reply, {:error, :full}, state}

              :ets.lookup(@table, {:member, target_id}) != [] ->
                notify(leader_id, "Ese jugador ya pertenece a un clan.")
                {:reply, {:error, :already_in_guild}, state}

              true ->
                now = System.monotonic_time(:millisecond)

                :ets.insert(
                  @table,
                  {{:invite, target_id}, %{from: leader_id, guild_id: guild_id, expires_at: now + @invite_ttl_ms}}
                )

                notify(
                  target_id,
                  "Has sido invitado al clan '#{guild.name}'. Escribe /ACEPTARCLAN para unirte."
                )

                notify(leader_id, "Invitacion enviada.")
                {:reply, :ok, state}
            end

          [{_, _guild}] ->
            notify(leader_id, "Solo el lider del clan puede invitar.")
            {:reply, {:error, :not_leader}, state}

          [] ->
            {:reply, {:error, :no_guild}, state}
        end
    end
  end

  @impl true
  def handle_call({:accept, char_id}, _from, state) do
    case :ets.lookup(@table, {:invite, char_id}) do
      [{_, %{guild_id: guild_id, from: from_id, expires_at: expires_at}}] ->
        now = System.monotonic_time(:millisecond)

        cond do
          now > expires_at ->
            # Invite expired -- clean it up and reject
            :ets.delete(@table, {:invite, char_id})
            notify(char_id, "La invitacion ha expirado.")
            {:reply, {:error, :invite_invalid}, state}

          true ->
            # Check guild existence and verify the inviter still leads it
            case :ets.lookup(@table, {:guild, guild_id}) do
              [] ->
                # Guild was deleted
                :ets.delete(@table, {:invite, char_id})
                notify(char_id, "El clan ya no existe.")
                {:reply, {:error, :guild_gone}, state}

              [{_, %{leader: leader}}] when leader != from_id ->
                # Leader changed since invite was issued
                :ets.delete(@table, {:invite, char_id})
                notify(char_id, "La invitacion ya no es valida (el lider cambio).")
                {:reply, {:error, :invite_invalid}, state}

              [{_, guild}] ->
                cond do
                  :ets.lookup(@table, {:member, char_id}) != [] ->
                    notify(char_id, "Ya perteneces a un clan.")
                    {:reply, {:error, :already_in_guild}, state}

                  length(guild.members) >= @max_members ->
                    notify(char_id, "El clan esta lleno.")
                    {:reply, {:error, :full}, state}

                  guild.alignment != GuildAlignment.neutral() and
                      not alignment_compatible?(char_id, guild.alignment) ->
                    notify(
                      char_id,
                      "Tu alineacion no es compatible con este clan (#{GuildAlignment.name(guild.alignment)})."
                    )

                    {:reply, {:error, :alignment_mismatch}, state}

                  true ->
                    result =
                      try do
                        Guilds.add_member(guild_id, char_id)
                      rescue
                        e ->
                          Logger.error("Guild add_member raised for char #{char_id}: #{inspect(e)}")
                          {:error, :exception}
                      end

                    case result do
                      {:ok, _member} ->
                        # DB succeeded -- now update ETS and delete invite
                        :ets.delete(@table, {:invite, char_id})
                        new_members = guild.members ++ [char_id]
                        :ets.insert(@table, {{:guild, guild_id}, %{guild | members: new_members}})
                        :ets.insert(@table, {{:member, char_id}, guild_id})

                        broadcast_guild(
                          new_members,
                          "Un jugador se ha unido al clan. Miembros: #{length(new_members)}"
                        )

                        {:reply, :ok, state}

                      {:error, _reason} ->
                        # DB failed -- keep the invite so player can retry
                        Logger.error("Failed to persist guild join for char #{char_id}")
                        notify(char_id, "Error al unirse al clan. Intenta de nuevo.")
                        {:reply, {:error, :db_error}, state}
                    end
                end
            end
        end

      [] ->
        notify(char_id, "No tienes invitaciones de clan pendientes.")
        {:reply, {:error, :no_invite}, state}
    end
  end

  @impl true
  def handle_call({:set_news, char_id, news}, _from, state) do
    case lookup_guild_as_leader(char_id) do
      {:ok, guild_id, guild} ->
        news = String.slice(news, 0..1023)

        case persist_guild_update(guild_id, %{news: news}) do
          :ok ->
            guild = %{guild | news: news}
            :ets.insert(@table, {{:guild, guild_id}, guild})
            notify(char_id, "Noticias del clan actualizadas.")
            {:reply, :ok, state}

          :error ->
            notify(char_id, "Error al actualizar noticias. Intenta de nuevo.")
            {:reply, {:error, :db_error}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_description, char_id, description}, _from, state) do
    case lookup_guild_as_leader(char_id) do
      {:ok, guild_id, guild} ->
        description = String.slice(description, 0..255)

        case persist_guild_update(guild_id, %{description: description}) do
          :ok ->
            guild = %{guild | description: description}
            :ets.insert(@table, {{:guild, guild_id}, guild})
            notify(char_id, "Descripcion del clan actualizada.")
            {:reply, :ok, state}

          :error ->
            notify(char_id, "Error al actualizar descripcion. Intenta de nuevo.")
            {:reply, {:error, :db_error}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_website, char_id, url}, _from, state) do
    case lookup_guild_as_leader(char_id) do
      {:ok, guild_id, guild} ->
        url = String.slice(url, 0..255)

        case persist_guild_update(guild_id, %{url: url}) do
          :ok ->
            guild = %{guild | url: url}
            :ets.insert(@table, {{:guild, guild_id}, guild})
            {:reply, :ok, state}

          :error ->
            {:reply, {:error, :db_error}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:declare_war, char_id, target_name}, _from, state) do
    case lookup_guild_as_leader(char_id) do
      {:ok, my_guild_id, my_guild} ->
        case find_guild_by_name(target_name) do
          {:ok, target_guild_id, _target_guild} when target_guild_id == my_guild_id ->
            notify(char_id, "No puedes declarar guerra a tu propio clan.")
            {:reply, {:error, :same_guild}, state}

          {:ok, target_guild_id, target_guild} ->
            case persist_relation(my_guild_id, target_guild_id, :set, "war") do
              :ok ->
                set_relation_ets(my_guild_id, target_guild_id, "war")
                broadcast_guild(my_guild.members, "Se ha declarado la guerra contra '#{target_guild.name}'!")
                broadcast_guild(target_guild.members, "El clan '#{my_guild.name}' les ha declarado la guerra!")
                {:reply, :ok, state}

              :error ->
                notify(char_id, "Error al declarar la guerra. Intenta de nuevo.")
                {:reply, {:error, :db_error}, state}
            end

          :not_found ->
            notify(char_id, "No se encontro el clan '#{target_name}'.")
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:propose_peace, char_id, target_name}, _from, state) do
    case lookup_guild_as_leader(char_id) do
      {:ok, my_guild_id, my_guild} ->
        case find_guild_by_name(target_name) do
          {:ok, target_guild_id, target_guild} ->
            if at_war?(my_guild_id, target_guild_id) do
              case persist_relation(my_guild_id, target_guild_id, :delete, nil) do
                :ok ->
                  delete_relation_ets(my_guild_id, target_guild_id)
                  broadcast_guild(my_guild.members, "Se ha establecido la paz con '#{target_guild.name}'.")
                  broadcast_guild(target_guild.members, "El clan '#{my_guild.name}' ha propuesto la paz.")
                  {:reply, :ok, state}

                :error ->
                  notify(char_id, "Error al proponer la paz. Intenta de nuevo.")
                  {:reply, {:error, :db_error}, state}
              end
            else
              notify(char_id, "No estan en guerra con '#{target_name}'.")
              {:reply, {:error, :not_at_war}, state}
            end

          :not_found ->
            notify(char_id, "No se encontro el clan '#{target_name}'.")
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:propose_alliance, char_id, target_name}, _from, state) do
    case lookup_guild_as_leader(char_id) do
      {:ok, my_guild_id, my_guild} ->
        case find_guild_by_name(target_name) do
          {:ok, target_guild_id, _target_guild} when target_guild_id == my_guild_id ->
            notify(char_id, "No puedes aliarte con tu propio clan.")
            {:reply, {:error, :same_guild}, state}

          {:ok, target_guild_id, target_guild} ->
            case persist_relation(my_guild_id, target_guild_id, :set, "alliance") do
              :ok ->
                set_relation_ets(my_guild_id, target_guild_id, "alliance")
                broadcast_guild(my_guild.members, "Se ha formado una alianza con '#{target_guild.name}'.")
                broadcast_guild(target_guild.members, "El clan '#{my_guild.name}' les ha propuesto una alianza.")
                {:reply, :ok, state}

              :error ->
                notify(char_id, "Error al proponer la alianza. Intenta de nuevo.")
                {:reply, {:error, :db_error}, state}
            end

          :not_found ->
            notify(char_id, "No se encontro el clan '#{target_name}'.")
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:request_membership, char_id, guild_name, description}, _from, state) do
    cond do
      :ets.lookup(@table, {:member, char_id}) != [] ->
        notify(char_id, "Ya perteneces a un clan.")
        {:reply, {:error, :already_in_guild}, state}

      true ->
        case find_guild_by_name(guild_name) do
          {:ok, guild_id, guild} ->
            result =
              try do
                Guilds.create_request(guild_id, char_id, description)
              rescue
                e ->
                  Logger.error("Guild create_request raised: #{inspect(e)}")
                  {:error, :exception}
              end

            case result do
              {:ok, _} ->
                notify(char_id, "Solicitud enviada al clan '#{guild.name}'.")
                # Notify leader
                notify(guild.leader, "Hay una nueva solicitud de ingreso al clan. Usa /SOLICITUDES para verlas.")
                {:reply, :ok, state}

              {:error, _} ->
                notify(char_id, "Ya tienes una solicitud pendiente en ese clan.")
                {:reply, {:error, :already_requested}, state}
            end

          :not_found ->
            notify(char_id, "No se encontro el clan '#{guild_name}'.")
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:list_requests, char_id}, _from, state) do
    case lookup_guild_as_leader(char_id) do
      {:ok, guild_id, _guild} ->
        requests =
          try do
            Guilds.list_requests(guild_id)
          rescue
            e ->
              Logger.error("Guild list_requests raised: #{inspect(e)}")
              []
          end

        request_names =
          for req <- requests do
            case OnlineDirectory.lookup_by_id(req.char_id) do
              {:ok, info} -> info.name
              :not_found -> "ID:#{req.char_id}"
            end
          end

        if requests == [] do
          notify(char_id, "No hay solicitudes pendientes.")
        else
          for {req, name} <- Enum.zip(requests, request_names) do
            desc = if req.description != "", do: " - #{req.description}", else: ""
            notify(char_id, "Solicitud: #{name}#{desc}")
          end
        end

        {:reply, {:ok, request_names}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:accept_request, leader_id, target_name}, _from, state) do
    case lookup_guild_as_leader(leader_id) do
      {:ok, guild_id, guild} ->
        case resolve_char_id(target_name) do
          {:ok, target_id} ->
            # Verify a pending request exists before proceeding
            request_exists? =
              try do
                Guilds.request_exists?(guild_id, target_id)
              rescue
                e ->
                  Logger.error("Guild request_exists? raised: #{inspect(e)}")
                  false
              end

            if not request_exists? do
              notify(leader_id, "No hay solicitud pendiente de ese jugador.")
              {:reply, {:error, :no_request}, state}
            else
              cond do
                :ets.lookup(@table, {:member, target_id}) != [] ->
                  try do
                    Guilds.delete_request(guild_id, target_id)
                  rescue
                    e -> Logger.error("Guild delete_request raised: #{inspect(e)}")
                  end

                  notify(leader_id, "Ese jugador ya pertenece a un clan.")
                  {:reply, {:error, :already_in_guild}, state}

                length(guild.members) >= @max_members ->
                  notify(leader_id, "El clan esta lleno.")
                  {:reply, {:error, :full}, state}

                true ->
                  result =
                    try do
                      Guilds.add_member(guild_id, target_id)
                    rescue
                      e ->
                        Logger.error("Guild add_member raised for char #{target_id}: #{inspect(e)}")
                        {:error, :exception}
                    end

                  case result do
                    {:ok, _} ->
                      try do
                        Guilds.delete_request(guild_id, target_id)
                      rescue
                        e -> Logger.error("Guild delete_request raised: #{inspect(e)}")
                      end

                      new_members = guild.members ++ [target_id]
                      :ets.insert(@table, {{:guild, guild_id}, %{guild | members: new_members}})
                      :ets.insert(@table, {{:member, target_id}, guild_id})
                      notify(target_id, "Tu solicitud al clan '#{guild.name}' fue aceptada!")
                      broadcast_guild(new_members, "Un jugador se ha unido al clan. Miembros: #{length(new_members)}")
                      {:reply, :ok, state}

                    {:error, _} ->
                      notify(leader_id, "Error al aceptar la solicitud.")
                      {:reply, {:error, :db_error}, state}
                  end
              end
            end

          :not_found ->
            notify(leader_id, "No se encontro al jugador '#{target_name}'.")
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:reject_request, leader_id, target_name}, _from, state) do
    case lookup_guild_as_leader(leader_id) do
      {:ok, guild_id, _guild} ->
        case resolve_char_id(target_name) do
          {:ok, target_id} ->
            try do
              Guilds.delete_request(guild_id, target_id)
            rescue
              e ->
                Logger.error("Guild delete_request raised: #{inspect(e)}")
            end

            notify(leader_id, "Solicitud rechazada.")
            notify(target_id, "Tu solicitud de clan fue rechazada.")
            {:reply, :ok, state}

          :not_found ->
            notify(leader_id, "No se encontro al jugador '#{target_name}'.")
            {:reply, {:error, :not_found}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:leave, char_id}, _from, state) do
    result = do_leave(char_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:kick, leader_id, target_id}, _from, state) do
    case :ets.lookup(@table, {:member, leader_id}) do
      [{_, guild_id}] ->
        case :ets.lookup(@table, {:guild, guild_id}) do
          [{_, %{leader: ^leader_id} = guild}] ->
            if target_id in guild.members and target_id != leader_id do
              result =
                try do
                  Guilds.remove_member(guild_id, target_id)
                rescue
                  e ->
                    Logger.error("Guild remove_member raised for char #{target_id}: #{inspect(e)}")
                    {:error, :exception}
                end

              case result do
                {:error, _} ->
                  Logger.error("Failed to persist kick for char #{target_id}")
                  {:reply, {:error, :db_error}, state}

                {0, _} ->
                  Logger.error("Failed to persist kick for char #{target_id}")
                  {:reply, {:error, :db_error}, state}

                {_count, _} ->
                  new_members = List.delete(guild.members, target_id)
                  :ets.insert(@table, {{:guild, guild_id}, %{guild | members: new_members}})
                  :ets.delete(@table, {:member, target_id})
                  notify(target_id, "Has sido expulsado del clan.")
                  broadcast_guild(new_members, "Un jugador fue expulsado del clan.")
                  {:reply, :ok, state}
              end
            else
              {:reply, {:error, :invalid_target}, state}
            end

          _ ->
            {:reply, {:error, :not_leader}, state}
        end

      [] ->
        {:reply, {:error, :not_in_guild}, state}
    end
  end

  @impl true
  def handle_cast({:add_exp, guild_id, amount}, state) do
    case :ets.lookup(@table, {:guild, guild_id}) do
      [{_, guild}] ->
        max_level = GuildConstants.max_level()

        if guild.level >= max_level do
          {:noreply, state}
        else
          old_level = guild.level
          new_exp = guild.current_exp + amount

          {new_level, final_exp} =
            level_up_loop(old_level, new_exp, max_level)

          case persist_guild_update(guild_id, %{level: new_level, current_exp: final_exp}) do
            :ok ->
              guild = %{guild | level: new_level, current_exp: final_exp}
              :ets.insert(@table, {{:guild, guild_id}, guild})

              if new_level > old_level do
                broadcast_guild(
                  guild.members,
                  "El clan ha subido al nivel #{new_level}!"
                )
              end

            :error ->
              :ok
          end

          {:noreply, state}
        end

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup_invites, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{{:invite, :_}, %{expires_at: :"$1"}}, [{:<, :"$1", now}], [true]}
    ])

    Process.send_after(self(), :cleanup_invites, @invite_ttl_ms)
    {:noreply, state}
  end

  # ---- Internal ----

  defp do_leave(char_id) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, guild_id}] ->
        case :ets.lookup(@table, {:guild, guild_id}) do
          [{_, %{leader: ^char_id} = guild}] ->
            remaining = List.delete(guild.members, char_id)

            if remaining == [] do
              # Last member left -- dissolve guild
              result =
                try do
                  Guilds.delete_guild(guild_id)
                rescue
                  e ->
                    Logger.error("Guild delete_guild raised for guild #{guild_id}: #{inspect(e)}")
                    {:error, :exception}
                end

              case result do
                {:ok, _} ->
                  :ets.delete(@table, {:member, char_id})
                  :ets.delete(@table, {:guild, guild_id})
                  :ok

                {:error, _} ->
                  {:error, :db_error}
              end
            else
              # Promote the next member to leader (VB6: auto-succession)
              # Issue 9: use transactional remove_member + set_leader
              new_leader = hd(remaining)

              result =
                try do
                  Guilds.remove_member_and_set_leader(guild_id, char_id, new_leader)
                rescue
                  e ->
                    Logger.error("Guild remove_member_and_set_leader raised: #{inspect(e)}")
                    {:error, :exception}
                end

              case result do
                {:ok, _} ->
                  # DB succeeded -- now update ETS
                  :ets.delete(@table, {:member, char_id})
                  guild = %{guild | leader: new_leader, members: remaining}
                  :ets.insert(@table, {{:guild, guild_id}, guild})

                  leader_name =
                    case OnlineDirectory.lookup_by_id(new_leader) do
                      {:ok, info} -> info.name
                      :not_found -> "ID:#{new_leader}"
                    end

                  broadcast_guild(remaining, "El lider abandono el clan. #{leader_name} es el nuevo lider.")
                  :ok

                {:error, _} ->
                  {:error, :db_error}
              end
            end

          [{_, guild}] ->
            result =
              try do
                Guilds.remove_member(guild_id, char_id)
              rescue
                e ->
                  Logger.error("Guild remove_member raised for char #{char_id}: #{inspect(e)}")
                  {:error, :exception}
              end

            case result do
              {:error, _} ->
                {:error, :db_error}

              {0, _} ->
                Logger.error("Guild remove_member raised for char #{char_id}: no rows deleted")
                {:error, :db_error}

              {_count, _} ->
                :ets.delete(@table, {:member, char_id})
                new_members = List.delete(guild.members, char_id)

                if new_members == [] do
                  try do
                    Guilds.delete_guild(guild_id)
                  rescue
                    e -> Logger.error("Guild delete_guild raised for guild #{guild_id}: #{inspect(e)}")
                  end

                  :ets.delete(@table, {:guild, guild_id})
                else
                  :ets.insert(@table, {{:guild, guild_id}, %{guild | members: new_members}})
                  broadcast_guild(new_members, "Un jugador abandono el clan.")
                end

                :ok
            end

          [] ->
            # Guild doesn't exist in ETS, just clean up membership
            :ets.delete(@table, {:member, char_id})
            :ok
        end

      [] ->
        :ok
    end
  end

  defp level_up_loop(level, _exp, max_level) when level >= max_level, do: {max_level, 0}

  defp level_up_loop(level, exp, max_level) do
    required = GuildConstants.required_exp(level)

    case required do
      :max -> {level, exp}
      req when exp >= req -> level_up_loop(level + 1, exp - req, max_level)
      _req -> {level, exp}
    end
  end

  defp set_relation_ets(guild_a, guild_b, type) do
    {a, b} = if guild_a <= guild_b, do: {guild_a, guild_b}, else: {guild_b, guild_a}
    :ets.insert(@table, {{:relation, a, b}, type})
  end

  defp delete_relation_ets(guild_a, guild_b) do
    {a, b} = if guild_a <= guild_b, do: {guild_a, guild_b}, else: {guild_b, guild_a}
    :ets.delete(@table, {:relation, a, b})
  end

  def find_guild_by_name(name) do
    normalized = String.downcase(String.trim(name))

    # Scan ETS for guild with matching name (guild count is small)
    result =
      :ets.foldl(
        fn
          {{:guild, _id}, guild}, nil ->
            if String.downcase(guild.name) == normalized, do: guild, else: nil

          _, acc ->
            acc
        end,
        nil,
        @table
      )

    case result do
      nil -> :not_found
      guild -> {:ok, guild.id, guild}
    end
  end

  defp resolve_char_id(name) do
    case OnlineDirectory.lookup_by_name(name) do
      {:ok, char_id, _info} -> {:ok, char_id}
      :not_found -> :not_found
    end
  end

  defp alignment_compatible?(char_id, guild_alignment) do
    case OnlineDirectory.lookup_by_id(char_id) do
      {:ok, %{map_id: map_id}} ->
        case Arena.Map.MapServer.snapshot_entity(map_id, char_id) do
          {:ok, entity} ->
            player_align = GuildAlignment.player_alignment(entity)
            GuildAlignment.compatible?(guild_alignment, player_align)

          _ ->
            true
        end

      _ ->
        true
    end
  end

  defp lookup_guild_as_leader(char_id) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, guild_id}] ->
        case :ets.lookup(@table, {:guild, guild_id}) do
          [{_, %{leader: ^char_id} = guild}] ->
            {:ok, guild_id, guild}

          [{_, _guild}] ->
            notify(char_id, "Solo el lider del clan puede hacer eso.")
            {:error, :not_leader}

          [] ->
            {:error, :no_guild}
        end

      [] ->
        notify(char_id, "No perteneces a ningun clan.")
        {:error, :not_in_guild}
    end
  end

  defp notify(char_id, message) do
    case OnlineDirectory.lookup_by_id(char_id) do
      {:ok, %{session_pid: pid}} ->
        raw =
          AoProtocol.Server.Encoder.encode({:console_msg, %{message: message, font_index: 0}})

        send(pid, {:send_raw, raw})

      _ ->
        :ok
    end
  end

  defp broadcast_guild(member_ids, message) do
    for mid <- member_ids, do: notify(mid, message)
  end

  @doc """
  Send a guild_details snapshot packet to a specific player.
  Used when a player requests guild details or logs in while in a guild.
  """
  def send_guild_details(char_id, guild) do
    leader_name =
      case OnlineDirectory.lookup_by_id(guild.leader) do
        {:ok, info} -> info.name
        :not_found -> "ID:#{guild.leader}"
      end

    founder_name =
      case OnlineDirectory.lookup_by_id(guild.founder_id) do
        {:ok, info} -> info.name
        :not_found -> "ID:#{guild.founder_id}"
      end

    date =
      case guild[:created_at] do
        %DateTime{} = dt -> Calendar.strftime(dt, "%Y-%m-%d")
        %NaiveDateTime{} = dt -> Calendar.strftime(dt, "%Y-%m-%d")
        nil -> ""
        other -> to_string(other)
      end

    alignment_name = GuildAlignment.name(guild.alignment)

    raw =
      AoProtocol.Server.Encoder.encode(
        {:guild_details,
         %{
           name: guild.name,
           founder: founder_name,
           date: date,
           leader: leader_name,
           member_count: length(guild.members),
           alignment: alignment_name,
           description: guild.description,
           level: guild.level
         }}
      )

    case OnlineDirectory.lookup_by_id(char_id) do
      {:ok, %{session_pid: pid}} -> send(pid, {:send_raw, raw})
      _ -> :ok
    end
  end

  @doc """
  Send a guild_news snapshot packet to a specific player.
  Used when a player requests guild news or logs in while in a guild.
  """
  def send_guild_news(char_id, guild) do
    member_names =
      guild.members
      |> Enum.map(fn mid ->
        case OnlineDirectory.lookup_by_id(mid) do
          {:ok, info} -> info.name
          :not_found -> "ID:#{mid}"
        end
      end)
      |> Enum.join(",")

    required =
      case GuildConstants.required_exp(guild.level) do
        :max -> 0
        req -> req
      end

    raw =
      AoProtocol.Server.Encoder.encode(
        {:guild_news,
         %{
           news: guild.news,
           guild_list: guild.name,
           member_list: member_names,
           level: guild.level,
           current_exp: guild.current_exp,
           needed_exp: required
         }}
      )

    case OnlineDirectory.lookup_by_id(char_id) do
      {:ok, %{session_pid: pid}} -> send(pid, {:send_raw, raw})
      _ -> :ok
    end
  end

  # ---- Sync persistence helpers ----

  defp persist_guild_update(guild_id, attrs) do
    try do
      case Guilds.update_guild(guild_id, attrs) do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.error("Guild DB update failed for guild #{guild_id}: #{inspect(reason)}")
          :error
      end
    rescue
      e ->
        Logger.error("Guild DB update failed for guild #{guild_id}: #{inspect(e)}")
        :error
    end
  end

  defp persist_relation(guild_a, guild_b, :set, type) do
    try do
      case Guilds.set_relation(guild_a, guild_b, type) do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.error("Guild relation set failed (#{guild_a}↔#{guild_b} #{type}): #{inspect(reason)}")
          :error
      end
    rescue
      e ->
        Logger.error("Guild relation set failed (#{guild_a}↔#{guild_b} #{type}): #{inspect(e)}")
        :error
    end
  end

  defp persist_relation(guild_a, guild_b, :delete, _type) do
    try do
      Guilds.delete_relation(guild_a, guild_b)
      :ok
    rescue
      e ->
        Logger.error("Guild relation delete failed (#{guild_a}↔#{guild_b}): #{inspect(e)}")
        :error
    end
  end

  # Load all guilds from DB into ETS. Returns the next available guild_id.
  # Gracefully handles missing DB (e.g. test environment without Repo).
  defp load_guilds_from_db do
    guilds = Guilds.list_all()

    next_id =
      Enum.reduce(guilds, 1, fn db_guild, acc ->
        member_ids = Enum.map(db_guild.members, & &1.char_id)

        guild = %{
          id: db_guild.id,
          name: db_guild.name,
          leader: db_guild.leader_id,
          founder_id: db_guild.founder_id || db_guild.leader_id,
          created_at: db_guild.inserted_at,
          members: member_ids,
          level: db_guild.level || 1,
          current_exp: db_guild.current_exp || 0,
          description: db_guild.description || "",
          news: db_guild.news || "",
          url: db_guild.url || "",
          alignment: db_guild.alignment || 0
        }

        :ets.insert(@table, {{:guild, db_guild.id}, guild})

        for mid <- member_ids do
          :ets.insert(@table, {{:member, mid}, db_guild.id})
        end

        max(acc, db_guild.id + 1)
      end)

    Logger.info("GuildServer loaded #{length(guilds)} guild(s) from DB")
    next_id
  rescue
    e ->
      Logger.warning("GuildServer: DB not available, starting with empty state: #{inspect(e)}")
      1
  end

  defp load_relations_from_db do
    relations = Guilds.list_relations()

    for rel <- relations do
      {a, b} =
        if rel.guild_a_id <= rel.guild_b_id,
          do: {rel.guild_a_id, rel.guild_b_id},
          else: {rel.guild_b_id, rel.guild_a_id}

      :ets.insert(@table, {{:relation, a, b}, rel.relation_type})
    end

    Logger.info("GuildServer loaded #{length(relations)} guild relation(s) from DB")
  rescue
    _ -> :ok
  end
end
