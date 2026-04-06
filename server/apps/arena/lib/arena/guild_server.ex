defmodule Arena.GuildServer do
  @moduledoc """
  Global guild/clan system. GenServer serializes mutations; ETS provides O(1) reads.
  Guilds are session-only (not persisted to DB for now).
  """

  use GenServer

  require Logger

  alias AoSession.OnlineDirectory

  @table :ao_guilds
  @max_members 50
  @invite_ttl_ms 60_000

  # ---- Public API (reads go straight to ETS) ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Create a new guild. The creator becomes the leader."
  def create_guild(char_id, name) do
    GenServer.call(__MODULE__, {:create, char_id, name})
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
                {:console_msg,
                 %{message: "[Clan] #{sender_name}: #{message}", font_index: 3}}
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

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Process.send_after(self(), :cleanup_invites, @invite_ttl_ms)
    {:ok, %{next_guild_id: 1}}
  end

  @impl true
  def handle_call({:create, char_id, name}, _from, state) do
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
        guild_id = state.next_guild_id

        guild = %{
          id: guild_id,
          name: name,
          leader: char_id,
          members: [char_id]
        }

        :ets.insert(@table, {{:guild, guild_id}, guild})
        :ets.insert(@table, {{:member, char_id}, guild_id})

        notify(char_id, "Clan '#{name}' creado exitosamente.")
        {:reply, :ok, %{state | next_guild_id: guild_id + 1}}
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
                if length(guild.members) >= @max_members do
                  notify(char_id, "El clan esta lleno.")
                  {:reply, {:error, :full}, state}
                else
                  new_members = guild.members ++ [char_id]
                  :ets.insert(@table, {{:guild, guild_id}, %{guild | members: new_members}})
                  :ets.insert(@table, {{:member, char_id}, guild_id})

                  broadcast_guild(
                    new_members,
                    "Un jugador se ha unido al clan. Miembros: #{length(new_members)}"
                  )

                  {:reply, :ok, state}
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
            # Leader left -- dissolve guild
            for mid <- guild.members, mid != char_id do
              :ets.delete(@table, {:member, mid})
              notify(mid, "El clan se ha disuelto.")
            end

            :ets.delete(@table, {:guild, guild_id})

          [{_, guild}] ->
            new_members = List.delete(guild.members, char_id)

            if new_members == [] do
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
end
