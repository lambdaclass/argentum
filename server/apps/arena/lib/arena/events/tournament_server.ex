defmodule Arena.Events.TournamentServer do
  @moduledoc """
  Arena-style PvP tournament system.

  Supports registration, bracket generation, match progression, and rewards.
  A GM starts a tournament with `/TOURNAMENT START [max_players]`.
  Players register via `/TOURNAMENT JOIN` (or NPC interaction).
  The GM closes registration and begins matches with `/TOURNAMENT BEGIN`.

  ## Lifecycle

  1. `:registration` -- players sign up, GM can see who registered.
  2. `:in_progress` -- bracket matches are resolved one at a time.
  3. `:finished` -- winner is announced, rewards distributed.
  4. `:idle` -- no active tournament.

  Only one tournament can be active at a time (server-wide singleton).
  """

  use GenServer

  require Logger

  alias AoSession.OnlineDirectory
  alias AoProtocol.Server.Encoder

  # ── Types ──────────────────────────────────────────────────────────────

  defmodule Match do
    @moduledoc false
    defstruct [:player_a, :player_b, :winner, :round]
  end

  defmodule Tournament do
    @moduledoc false
    defstruct [
      :max_players,
      :started_by,
      :started_at,
      phase: :registration,
      participants: [],
      bracket: [],
      current_match_index: 0,
      current_round: 1,
      winner: nil
    ]
  end

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start a new tournament. Only GMs should call this."
  def start_tournament(max_players \\ 16, gm_name \\ "GM") do
    GenServer.call(__MODULE__, {:start_tournament, max_players, gm_name})
  end

  @doc "Register a player for the current tournament."
  def join(char_id, player_name) do
    GenServer.call(__MODULE__, {:join, char_id, player_name})
  end

  @doc "Remove a player from registration."
  def leave(char_id) do
    GenServer.call(__MODULE__, {:leave, char_id})
  end

  @doc "Close registration and begin bracket matches."
  def begin_matches do
    GenServer.call(__MODULE__, :begin_matches)
  end

  @doc """
  Report a match result. Called when a player dies in a tournament match.
  `loser_id` is the char_id of the player who lost.
  """
  def report_match_result(loser_id) do
    GenServer.call(__MODULE__, {:report_result, loser_id})
  end

  @doc "Get the current tournament state."
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Cancel the current tournament."
  def cancel do
    GenServer.call(__MODULE__, :cancel)
  end

  @doc "Get the current match (if tournament is in progress)."
  def current_match do
    GenServer.call(__MODULE__, :current_match)
  end

  @doc "Check if a player is currently in an active tournament match."
  def in_tournament_match?(char_id) do
    GenServer.call(__MODULE__, {:in_match?, char_id})
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{tournament: nil}}
  end

  @impl true
  def handle_call({:start_tournament, max_players, gm_name}, _from, state) do
    if state.tournament != nil and state.tournament.phase != :finished do
      {:reply, {:error, :tournament_already_active}, state}
    else
      tournament = %Tournament{
        max_players: max_players,
        started_by: gm_name,
        started_at: System.system_time(:second),
        phase: :registration,
        participants: [],
        bracket: [],
        current_match_index: 0,
        current_round: 1,
        winner: nil
      }

      broadcast_console_all(
        "Torneo> #{gm_name} ha iniciado un torneo PvP! " <>
          "Maximo #{max_players} participantes. Usa /TOURNAMENT JOIN para registrarte."
      )

      {:reply, :ok, %{state | tournament: tournament}}
    end
  end

  @impl true
  def handle_call({:join, char_id, player_name}, _from, state) do
    case state.tournament do
      nil ->
        {:reply, {:error, :no_tournament}, state}

      %{phase: :registration} = t ->
        cond do
          Enum.any?(t.participants, fn {id, _} -> id == char_id end) ->
            {:reply, {:error, :already_registered}, state}

          length(t.participants) >= t.max_players ->
            {:reply, {:error, :tournament_full}, state}

          true ->
            t = %{t | participants: t.participants ++ [{char_id, player_name}]}

            broadcast_console_all(
              "Torneo> #{player_name} se ha registrado. " <>
                "#{length(t.participants)}/#{t.max_players} participantes."
            )

            {:reply, :ok, %{state | tournament: t}}
        end

      _ ->
        {:reply, {:error, :registration_closed}, state}
    end
  end

  @impl true
  def handle_call({:leave, char_id}, _from, state) do
    case state.tournament do
      nil ->
        {:reply, {:error, :no_tournament}, state}

      %{phase: :registration} = t ->
        case Enum.find(t.participants, fn {id, _} -> id == char_id end) do
          nil ->
            {:reply, {:error, :not_registered}, state}

          {_, player_name} ->
            participants = Enum.reject(t.participants, fn {id, _} -> id == char_id end)
            t = %{t | participants: participants}

            broadcast_console_all("Torneo> #{player_name} se ha retirado del torneo.")
            {:reply, :ok, %{state | tournament: t}}
        end

      _ ->
        {:reply, {:error, :cannot_leave_in_progress}, state}
    end
  end

  @impl true
  def handle_call(:begin_matches, _from, state) do
    case state.tournament do
      nil ->
        {:reply, {:error, :no_tournament}, state}

      %{phase: :registration} = t ->
        if length(t.participants) < 2 do
          {:reply, {:error, :not_enough_players}, state}
        else
          shuffled = Enum.shuffle(t.participants)
          bracket = build_bracket(shuffled, 1)

          t = %{
            t
            | phase: :in_progress,
              participants: shuffled,
              bracket: bracket,
              current_match_index: 0
          }

          participant_names = Enum.map(shuffled, fn {_, name} -> name end)

          broadcast_console_all(
            "Torneo> El torneo ha comenzado con #{length(shuffled)} participantes! " <>
              "Participantes: #{Enum.join(participant_names, ", ")}"
          )

          announce_current_match(t)
          {:reply, :ok, %{state | tournament: t}}
        end

      _ ->
        {:reply, {:error, :already_in_progress}, state}
    end
  end

  @impl true
  def handle_call({:report_result, loser_id}, _from, state) do
    case state.tournament do
      %{phase: :in_progress} = t ->
        case get_current_match(t) do
          nil ->
            {:reply, {:error, :no_current_match}, state}

          match ->
            if loser_id == match.player_a or loser_id == match.player_b do
              winner_id =
                if loser_id == match.player_a, do: match.player_b, else: match.player_a

              winner_name = find_participant_name(t.participants, winner_id)
              loser_name = find_participant_name(t.participants, loser_id)

              broadcast_console_all(
                "Torneo> #{winner_name} ha derrotado a #{loser_name}!"
              )

              updated_match = %{match | winner: winner_id}

              bracket =
                List.update_at(t.bracket, t.current_match_index, fn _ -> updated_match end)

              t = %{t | bracket: bracket}
              t = advance_tournament(t)
              {:reply, :ok, %{state | tournament: t}}
            else
              {:reply, {:error, :not_in_current_match}, state}
            end
        end

      _ ->
        {:reply, {:error, :no_active_tournament}, state}
    end
  end

  @impl true
  def handle_call(:current_match, _from, state) do
    case state.tournament do
      %{phase: :in_progress} = t ->
        {:reply, {:ok, get_current_match(t)}, state}

      _ ->
        {:reply, {:error, :no_active_tournament}, state}
    end
  end

  @impl true
  def handle_call({:in_match?, char_id}, _from, state) do
    case state.tournament do
      %{phase: :in_progress} = t ->
        case get_current_match(t) do
          %{player_a: ^char_id} -> {:reply, true, state}
          %{player_b: ^char_id} -> {:reply, true, state}
          _ -> {:reply, false, state}
        end

      _ ->
        {:reply, false, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.tournament, state}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    case state.tournament do
      nil ->
        {:reply, {:error, :no_tournament}, state}

      _t ->
        broadcast_console_all("Torneo> El torneo ha sido cancelado.")
        {:reply, :ok, %{state | tournament: nil}}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp build_bracket(participants, round) do
    participants
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [{id_a, _name_a}, {id_b, _name_b}] ->
        %Match{player_a: id_a, player_b: id_b, winner: nil, round: round}

      [{id_a, _name_a}] ->
        # Bye: auto-win
        %Match{player_a: id_a, player_b: nil, winner: id_a, round: round}
    end)
  end

  defp get_current_match(%{bracket: bracket, current_match_index: idx}) do
    Enum.at(bracket, idx)
  end

  defp advance_tournament(t) do
    next_idx = t.current_match_index + 1
    {next_idx, t} = skip_byes(t, next_idx)

    if next_idx >= length(t.bracket) do
      winners =
        t.bracket
        |> Enum.filter(fn m -> m.round == t.current_round end)
        |> Enum.map(fn m -> m.winner end)
        |> Enum.reject(&is_nil/1)

      if length(winners) <= 1 do
        winner_id = List.first(winners)
        winner_name = find_participant_name(t.participants, winner_id)

        broadcast_console_all(
          "Torneo> #{winner_name} ha ganado el torneo! Felicitaciones!"
        )

        %{t | phase: :finished, winner: winner_id}
      else
        next_round = t.current_round + 1

        winner_participants =
          Enum.map(winners, fn id -> {id, find_participant_name(t.participants, id)} end)

        new_matches = build_bracket(winner_participants, next_round)

        broadcast_console_all(
          "Torneo> Ronda #{next_round}! #{length(winner_participants)} participantes restantes."
        )

        t = %{
          t
          | bracket: t.bracket ++ new_matches,
            current_match_index: length(t.bracket),
            current_round: next_round
        }

        {final_idx, t} = skip_byes(t, t.current_match_index)
        t = %{t | current_match_index: final_idx}
        announce_current_match(t)
        t
      end
    else
      t = %{t | current_match_index: next_idx}
      announce_current_match(t)
      t
    end
  end

  defp skip_byes(t, idx) do
    case Enum.at(t.bracket, idx) do
      %{winner: winner} when not is_nil(winner) and idx < length(t.bracket) ->
        skip_byes(t, idx + 1)

      _ ->
        {idx, t}
    end
  end

  defp announce_current_match(t) do
    case get_current_match(t) do
      %{player_a: a, player_b: b} when not is_nil(b) ->
        name_a = find_participant_name(t.participants, a)
        name_b = find_participant_name(t.participants, b)

        broadcast_console_all(
          "Torneo> Siguiente combate (Ronda #{t.current_round}): #{name_a} vs #{name_b}"
        )

      _ ->
        :ok
    end
  end

  defp find_participant_name(participants, char_id) do
    case Enum.find(participants, fn {id, _} -> id == char_id end) do
      {_, name} -> name
      nil -> "Desconocido"
    end
  end

  defp broadcast_console_all(message) do
    raw = Encoder.encode({:console_msg, %{message: message, font_index: 0}})
    OnlineDirectory.broadcast_all({:send_raw, raw})
  end
end
