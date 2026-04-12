defmodule Arena.PartyServer do
  @moduledoc """
  Global party system. GenServer serializes mutations; ETS provides O(1) reads.
  Parties are session-only (not persisted to DB).
  """

  use GenServer

  require Logger

  alias AoSession.OnlineDirectory

  @table :ao_parties
  @max_members 5
  @invite_ttl_ms 30_000

  # ---- Public API (reads go straight to ETS) ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Invite a player. Creates party if leader doesn't have one."
  def invite(leader_id, target_id) do
    GenServer.call(__MODULE__, {:invite, leader_id, target_id})
  end

  @doc "Accept a pending invite."
  def accept_invite(char_id) do
    GenServer.call(__MODULE__, {:accept, char_id})
  end

  @doc "Leave current party. Dissolves if leader."
  def leave(char_id) do
    GenServer.cast(__MODULE__, {:leave, char_id})
  end

  @doc "Leader kicks a member."
  def kick(leader_id, target_id) do
    GenServer.cast(__MODULE__, {:kick, leader_id, target_id})
  end

  @doc "Toggle party safe mode (prevents party members from damaging each other)."
  def safe_toggle(char_id) do
    GenServer.cast(__MODULE__, {:safe_toggle, char_id})
  end

  @doc "Check if party safe mode is on for a player's party. Pure ETS read."
  def party_safe?(char_id) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, party_id}] ->
        case :ets.lookup(@table, {:party, party_id}) do
          [{_, party}] -> Map.get(party, :safe, false)
          [] -> false
        end

      [] ->
        false
    end
  end

  @doc "Get party info for a player. Pure ETS read."
  def get_party(char_id) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, party_id}] ->
        case :ets.lookup(@table, {:party, party_id}) do
          [{_, party}] -> {:ok, party}
          [] -> :not_in_party
        end

      [] ->
        :not_in_party
    end
  end

  @doc "Check if two players are in the same party. Pure ETS read."
  def same_party?(a, b) do
    case {:ets.lookup(@table, {:member, a}), :ets.lookup(@table, {:member, b})} do
      {[{_, pa}], [{_, pb}]} -> pa == pb
      _ -> false
    end
  end

  @doc "Get party member char_ids on the same map. Pure ETS read + players map filter."
  def nearby_members(char_id, players_map, range \\ 20) do
    case get_party(char_id) do
      {:ok, %{members: members}} ->
        case Map.get(players_map, char_id) do
          nil ->
            []

          entity ->
            Enum.filter(members, fn mid ->
              mid != char_id and
                case Map.get(players_map, mid) do
                  nil -> false
                  m -> not m.dead and abs(m.x - entity.x) <= range and abs(m.y - entity.y) <= range
                end
            end)
        end

      _ ->
        []
    end
  end

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Process.send_after(self(), :cleanup_invites, @invite_ttl_ms)
    {:ok, %{next_party_id: 1}}
  end

  @impl true
  def handle_call({:invite, leader_id, target_id}, _from, state) do
    if leader_id == target_id do
      {:reply, {:error, :self_invite}, state}
    else
      # Create party if leader doesn't have one
      {state, party_id} = ensure_party(state, leader_id)

      case :ets.lookup(@table, {:party, party_id}) do
        [{_, party}] ->
          if length(party.members) >= @max_members do
            notify(leader_id, "El grupo esta lleno.")
            {:reply, {:error, :full}, state}
          else
            # Check target not already in a party
            case :ets.lookup(@table, {:member, target_id}) do
              [{_, _}] ->
                notify(leader_id, "Ese jugador ya esta en un grupo.")
                {:reply, {:error, :already_in_party}, state}

              [] ->
                now = System.monotonic_time(:millisecond)

                :ets.insert(
                  @table,
                  {{:invite, target_id}, %{from: leader_id, party_id: party_id, expires_at: now + @invite_ttl_ms}}
                )

                notify(target_id, "Has sido invitado a un grupo. Escribe /ACEPTARGRUPO para unirte.")
                notify(leader_id, "Invitacion enviada.")
                {:reply, :ok, state}
            end
          end

        [] ->
          {:reply, {:error, :no_party}, state}
      end
    end
  end

  @impl true
  def handle_call({:accept, char_id}, _from, state) do
    case :ets.lookup(@table, {:invite, char_id}) do
      [{_, %{party_id: party_id}}] ->
        :ets.delete(@table, {:invite, char_id})

        case :ets.lookup(@table, {:party, party_id}) do
          [{_, party}] ->
            if length(party.members) >= @max_members do
              notify(char_id, "El grupo esta lleno.")
              {:reply, {:error, :full}, state}
            else
              new_members = party.members ++ [char_id]
              updated_party = %{party | members: new_members}
              :ets.insert(@table, {{:party, party_id}, updated_party})
              :ets.insert(@table, {{:member, char_id}, party_id})
              broadcast_party(new_members, "Un jugador se ha unido al grupo. Miembros: #{length(new_members)}")
              broadcast_datos_grupo(updated_party)
              {:reply, :ok, state}
            end

          [] ->
            notify(char_id, "El grupo ya no existe.")
            {:reply, {:error, :party_gone}, state}
        end

      [] ->
        notify(char_id, "No tienes invitaciones pendientes.")
        {:reply, {:error, :no_invite}, state}
    end
  end

  @impl true
  def handle_cast({:leave, char_id}, state) do
    do_leave(char_id)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:safe_toggle, char_id}, state) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, party_id}] ->
        case :ets.lookup(@table, {:party, party_id}) do
          [{_, party}] ->
            new_safe = not Map.get(party, :safe, false)
            :ets.insert(@table, {{:party, party_id}, Map.put(party, :safe, new_safe)})
            msg = if new_safe, do: "Seguro de grupo activado.", else: "Seguro de grupo desactivado."
            broadcast_party(party.members, msg)

            # Send party safe confirmation packet to the toggling player
            packet = if new_safe, do: :party_safe_mode_on, else: :party_safe_mode_off

            case OnlineDirectory.lookup_by_id(char_id) do
              {:ok, %{session_pid: pid}} ->
                raw = AoProtocol.Server.Encoder.encode({packet, %{}})
                send(pid, {:send_raw, raw})

              _ ->
                :ok
            end

          [] ->
            :ok
        end

      [] ->
        notify(char_id, "No perteneces a un grupo.")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:kick, leader_id, target_id}, state) do
    case :ets.lookup(@table, {:member, leader_id}) do
      [{_, party_id}] ->
        case :ets.lookup(@table, {:party, party_id}) do
          [{_, %{leader: ^leader_id} = party}] ->
            if target_id in party.members and target_id != leader_id do
              new_members = List.delete(party.members, target_id)
              updated_party = %{party | members: new_members}
              :ets.insert(@table, {{:party, party_id}, updated_party})
              :ets.delete(@table, {:member, target_id})
              notify(target_id, "Has sido expulsado del grupo.")
              send_not_in_party(target_id)
              broadcast_party(new_members, "Un jugador fue expulsado del grupo.")
              broadcast_datos_grupo(updated_party)
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
    # Delete expired invites
    :ets.select_delete(@table, [
      {{{:invite, :_}, %{expires_at: :"$1"}}, [{:<, :"$1", now}], [true]}
    ])

    Process.send_after(self(), :cleanup_invites, @invite_ttl_ms)
    {:noreply, state}
  end

  # ---- Internal ----

  defp ensure_party(state, char_id) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, party_id}] ->
        {state, party_id}

      [] ->
        party_id = state.next_party_id
        :ets.insert(@table, {{:party, party_id}, %{leader: char_id, members: [char_id], safe: false}})
        :ets.insert(@table, {{:member, char_id}, party_id})
        {%{state | next_party_id: party_id + 1}, party_id}
    end
  end

  defp do_leave(char_id) do
    case :ets.lookup(@table, {:member, char_id}) do
      [{_, party_id}] ->
        :ets.delete(@table, {:member, char_id})

        case :ets.lookup(@table, {:party, party_id}) do
          [{_, %{leader: ^char_id} = party}] ->
            # Leader left — dissolve party
            for mid <- party.members, mid != char_id do
              :ets.delete(@table, {:member, mid})
              notify(mid, "El grupo se ha disuelto.")
              send_not_in_party(mid)
            end

            send_not_in_party(char_id)
            :ets.delete(@table, {:party, party_id})

          [{_, party}] ->
            new_members = List.delete(party.members, char_id)

            if new_members == [] do
              :ets.delete(@table, {:party, party_id})
            else
              updated_party = %{party | members: new_members}
              :ets.insert(@table, {{:party, party_id}, updated_party})
              broadcast_party(new_members, "Un jugador abandono el grupo.")
              broadcast_datos_grupo(updated_party)
            end

            send_not_in_party(char_id)

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
        raw = AoProtocol.Server.Encoder.encode({:console_msg, %{message: message, font_index: 0}})
        send(pid, {:send_raw, raw})

      _ ->
        :ok
    end
  end

  defp broadcast_party(member_ids, message) do
    for mid <- member_ids, do: notify(mid, message)
  end

  @doc false
  def send_datos_grupo(char_id, party) do
    # Resolve member names, with leader first (index 0) per VB6 convention
    leader_id = party.leader
    ordered = [leader_id | Enum.filter(party.members, &(&1 != leader_id))]

    names =
      Enum.map(ordered, fn mid ->
        case OnlineDirectory.lookup_by_id(mid) do
          {:ok, info} -> info.name
          :not_found -> "ID:#{mid}"
        end
      end)

    raw =
      AoProtocol.Server.Encoder.encode(
        {:datos_grupo, %{en_grupo: true, members: names, leader_index: 0}}
      )

    case OnlineDirectory.lookup_by_id(char_id) do
      {:ok, %{session_pid: pid}} -> send(pid, {:send_raw, raw})
      _ -> :ok
    end
  end

  defp send_not_in_party(char_id) do
    raw = AoProtocol.Server.Encoder.encode({:datos_grupo, %{en_grupo: false, members: []}})

    case OnlineDirectory.lookup_by_id(char_id) do
      {:ok, %{session_pid: pid}} -> send(pid, {:send_raw, raw})
      _ -> :ok
    end
  end

  defp broadcast_datos_grupo(party) do
    for mid <- party.members, do: send_datos_grupo(mid, party)
  end
end
