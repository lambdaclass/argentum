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
    GenServer.cast(__MODULE__, {:leave, char_id})
  end

  @doc "Leader kicks a member."
  def kick(leader_id, target_id) do
    GenServer.cast(__MODULE__, {:kick, leader_id, target_id})
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
              AoProtocol.Server.Encoder.encode(
                {:guild_chat,
                 %{status: 0, message: "#{sender_name}: #{message}"}}
              )

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

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Process.send_after(self(), :cleanup_invites, @invite_ttl_ms)

    # Load persisted guilds from DB into ETS
    next_id = load_guilds_from_db()

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
        case Guilds.create_guild(char_id, name, alignment) do
          {:ok, db_guild} ->
            guild_id = db_guild.id

            guild = %{
              id: guild_id,
              name: name,
              leader: char_id,
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
                  {{:invite, target_id},
                   %{from: leader_id, guild_id: guild_id, expires_at: now + @invite_ttl_ms}}
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
      [{_, %{guild_id: guild_id}}] ->
        :ets.delete(@table, {:invite, char_id})

        cond do
          :ets.lookup(@table, {:member, char_id}) != [] ->
            notify(char_id, "Ya perteneces a un clan.")
            {:reply, {:error, :already_in_guild}, state}

          true ->
            case :ets.lookup(@table, {:guild, guild_id}) do
              [{_, guild}] ->
                cond do
                  length(guild.members) >= @max_members ->
                    notify(char_id, "El clan esta lleno.")
                    {:reply, {:error, :full}, state}

                  guild.alignment != GuildAlignment.neutral() and
                      not alignment_compatible?(char_id, guild.alignment) ->
                    notify(char_id, "Tu alineacion no es compatible con este clan (#{GuildAlignment.name(guild.alignment)}).")
                    {:reply, {:error, :alignment_mismatch}, state}

                  true ->
                    case Guilds.add_member(guild_id, char_id) do
                      {:ok, _member} ->
                        new_members = guild.members ++ [char_id]
                        :ets.insert(@table, {{:guild, guild_id}, %{guild | members: new_members}})
                        :ets.insert(@table, {{:member, char_id}, guild_id})

                        broadcast_guild(
                          new_members,
                          "Un jugador se ha unido al clan. Miembros: #{length(new_members)}"
                        )

                        {:reply, :ok, state}

                      {:error, _reason} ->
                        Logger.error("Failed to persist guild join for char #{char_id}")
                        notify(char_id, "Error al unirse al clan. Intenta de nuevo.")
                        {:reply, {:error, :db_error}, state}
                    end
                end

              [] ->
                notify(char_id, "El clan ya no existe.")
                {:reply, {:error, :guild_gone}, state}
            end
        end

      [] ->
        notify(char_id, "No tienes invitaciones de clan pendientes.")
        {:reply, {:error, :no_invite}, state}
    end
  end

  @impl true
  def handle_cast({:leave, char_id}, state) do
    do_leave(char_id)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:kick, leader_id, target_id}, state) do
    case :ets.lookup(@table, {:member, leader_id}) do
      [{_, guild_id}] ->
        case :ets.lookup(@table, {:guild, guild_id}) do
          [{_, %{leader: ^leader_id} = guild}] ->
            if target_id in guild.members and target_id != leader_id do
              Guilds.remove_member(guild_id, target_id)
              new_members = List.delete(guild.members, target_id)
              :ets.insert(@table, {{:guild, guild_id}, %{guild | members: new_members}})
              :ets.delete(@table, {:member, target_id})
              notify(target_id, "Has sido expulsado del clan.")
              broadcast_guild(new_members, "Un jugador fue expulsado del clan.")
            end

          _ ->
            :ok
        end

      [] ->
        :ok
    end

    {:noreply, state}
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

          guild = %{guild | level: new_level, current_exp: final_exp}
          :ets.insert(@table, {{:guild, guild_id}, guild})

          if new_level > old_level do
            broadcast_guild(
              guild.members,
              "El clan ha subido al nivel #{new_level}!"
            )
          end

          # Async DB persist
          Task.start(fn ->
            Guilds.update_guild(guild_id, %{level: new_level, current_exp: final_exp})
          end)

          {:noreply, state}
        end

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:set_news, char_id, news}, _from, state) do
    case lookup_guild_as_leader(char_id) do
      {:ok, guild_id, guild} ->
        news = String.slice(news, 0..1023)
        guild = %{guild | news: news}
        :ets.insert(@table, {{:guild, guild_id}, guild})
        Task.start(fn -> Guilds.update_guild(guild_id, %{news: news}) end)
        notify(char_id, "Noticias del clan actualizadas.")
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_description, char_id, description}, _from, state) do
    case lookup_guild_as_leader(char_id) do
      {:ok, guild_id, guild} ->
        description = String.slice(description, 0..255)
        guild = %{guild | description: description}
        :ets.insert(@table, {{:guild, guild_id}, guild})
        Task.start(fn -> Guilds.update_guild(guild_id, %{description: description}) end)
        notify(char_id, "Descripcion del clan actualizada.")
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
        :ets.delete(@table, {:member, char_id})

        case :ets.lookup(@table, {:guild, guild_id}) do
          [{_, %{leader: ^char_id} = guild}] ->
            # Leader left -- dissolve guild (DB + ETS)
            Guilds.delete_guild(guild_id)

            for mid <- guild.members, mid != char_id do
              :ets.delete(@table, {:member, mid})
              notify(mid, "El clan se ha disuelto.")
            end

            :ets.delete(@table, {:guild, guild_id})

          [{_, guild}] ->
            Guilds.remove_member(guild_id, char_id)
            new_members = List.delete(guild.members, char_id)

            if new_members == [] do
              Guilds.delete_guild(guild_id)
              :ets.delete(@table, {:guild, guild_id})
            else
              :ets.insert(@table, {{:guild, guild_id}, %{guild | members: new_members}})
              broadcast_guild(new_members, "Un jugador abandono el clan.")
            end

          [] ->
            :ok
        end

      [] ->
        :ok
    end
  end

  defp level_up_loop(level, exp, max_level) when level >= max_level, do: {max_level, 0}

  defp level_up_loop(level, exp, max_level) do
    required = GuildConstants.required_exp(level)

    case required do
      :max -> {level, exp}
      req when exp >= req -> level_up_loop(level + 1, exp - req, max_level)
      _req -> {level, exp}
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
          [{_, %{leader: ^char_id} = guild}] -> {:ok, guild_id, guild}
          [{_, _guild}] ->
            notify(char_id, "Solo el lider del clan puede hacer eso.")
            {:error, :not_leader}
          [] -> {:error, :no_guild}
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
          AoProtocol.Server.Encoder.encode(
            {:console_msg, %{message: message, font_index: 0}}
          )

        send(pid, {:send_raw, raw})

      _ ->
        :ok
    end
  end

  defp broadcast_guild(member_ids, message) do
    for mid <- member_ids, do: notify(mid, message)
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
end
