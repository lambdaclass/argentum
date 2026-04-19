defmodule Arena.DuelServer do
  @moduledoc """
  Manages the duel (reto) lifecycle faithful to VB6 ModRetos.bas.

  ## VB6 lifecycle

  1. Challenger creates a challenge via `/RETAR <target> <bet>`.
  2. Target accepts with `/ACEPTAR <challenger_name>`.
  3. Both players are charged the bet, warped to their positions, and flagged
     as in-duel.  Best-of-3 rounds begin.
  4. When all members of a team die, the round goes to the opposing team.
  5. After 3 rounds (or 2-0 early win), the duel finalizes:
     - Winner(s) receive the pot minus tax.
     - Losers get nothing.
     - On tie (0-0 is impossible in best-of-3, but timeout can cause it),
       gold is refunded evenly.
  6. `/ABANDONAR` forfeits the duel immediately.
  7. `/CANCELAR` cancels a pending (not yet started) challenge.

  ## Room allocation (VB6: Salas)

  Like the VB6 server, this implementation manages dedicated duel rooms
  ("salas").  Each room has a map_id, left spawn position (PosIzquierda),
  and right spawn position (PosDerecha).  Rooms are loaded at startup
  via the `:rooms` option and tracked as free/occupied.  When a duel
  starts, a free room is allocated (VB6: BuscarSala); when it ends, the
  room is freed (VB6: SalaLiberada).  If no rooms are available, the
  duel is rejected with `{:error, :no_rooms_available}`.

  When no rooms are configured (`:rooms` option omitted), the server
  operates in legacy mode — duels proceed without room allocation.

  This GenServer is a singleton that holds *all* pending challenges and
  active duels in an ETS-free map structure for simplicity and testability.
  """

  use GenServer

  require Logger

  # ── Types ──────────────────────────────────────────────────────────────

  @type char_id :: non_neg_integer()

  defmodule Challenge do
    @moduledoc false
    defstruct [:challenger_id, :target_id, :bet, :created_at]
  end

  defmodule Room do
    @moduledoc """
    A duel room (VB6: t_SalaReto).

    * `id`        — 1-based room index (VB6: Sala)
    * `map_id`    — map number (VB6: Salas(Sala).PosIzquierda.Map)
    * `left_pos`  — {x, y} spawn for left team (VB6: PosIzquierda)
    * `right_pos` — {x, y} spawn for right team (VB6: PosDerecha)
    * `in_use`    — whether the room is currently occupied (VB6: EnUso)
    """
    defstruct [:id, :map_id, :left_pos, :right_pos, in_use: false]
  end

  defmodule Duel do
    @moduledoc false
    @doc """
    An active duel between two players.

    * `score` — positive means player_b is winning, negative means player_a.
      VB6: Puntaje works the same way (positive = right team, negative = left).
    * `round` — current round number (1-based).
    * `bet` — gold each player put in.
    * `room_id` — allocated room index (VB6: SalaReto), nil when no rooms configured.
    * `map_id` — map number of the duel room.
    * `left_pos` — {x, y} left team spawn position.
    * `right_pos` — {x, y} right team spawn position.
    * `original_positions` — %{char_id => saved_pos} for warp-back (VB6: LastPos).
    """
    defstruct [
      :player_a,
      :player_b,
      :bet,
      :room_id,
      :map_id,
      :left_pos,
      :right_pos,
      original_positions: %{},
      round: 1,
      score: 0
    ]
  end

  @best_of 3
  @tax_rate 0.10

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    rooms = Keyword.get(opts, :rooms, [])
    GenServer.start_link(__MODULE__, %{rooms: rooms}, name: name)
  end

  @doc """
  Create a challenge (VB6: CrearReto).
  Returns :ok | {:error, reason}.
  """
  def create_challenge(challenger_id, target_id, bet, server \\ __MODULE__) do
    GenServer.call(server, {:create_challenge, challenger_id, target_id, bet})
  end

  @doc """
  Accept a pending challenge (VB6: AceptarReto).
  Returns {:ok, duel} | {:error, reason}.
  """
  def accept_challenge(acceptor_id, challenger_name, server \\ __MODULE__) do
    GenServer.call(server, {:accept_challenge, acceptor_id, challenger_name})
  end

  @doc """
  Cancel a pending challenge (VB6: CancelarSolicitudReto).
  """
  def cancel_challenge(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:cancel_challenge, char_id})
  end

  @doc """
  Abandon / surrender an active duel (VB6: AbandonarReto).
  """
  def abandon_duel(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:abandon_duel, char_id})
  end

  @doc """
  Notify that a player died during a duel (VB6: MuereEnReto).
  Called by combat handlers after a duel participant dies.
  Returns {:duel_round_result, result} | :not_in_duel.
  """
  def player_died(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:player_died, char_id})
  end

  @doc """
  Notify that a player disconnected during a duel (VB6: desconexion en reto).
  The disconnecting player forfeits and the opponent wins.
  Returns {:ok, result} | {:error, :not_in_duel}.
  """
  def player_disconnected(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:player_disconnected, char_id})
  end

  @doc "Query the active duel for a given player, or nil."
  def get_duel(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_duel, char_id})
  end

  @doc "Query pending challenge where char_id is challenger."
  def get_challenge(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:get_challenge, char_id})
  end

  @doc "Check if a player is currently in an active duel."
  def in_duel?(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:in_duel?, char_id})
  end

  @doc "Get the duel opponent for a player, or nil."
  def duel_opponent(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:duel_opponent, char_id})
  end

  @doc "Return the number of free duel rooms (VB6: SalasLibres)."
  def free_rooms_count(server \\ __MODULE__) do
    GenServer.call(server, :free_rooms_count)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # challenges: %{challenger_id => %Challenge{}}
    # duels: %{duel_key => %Duel{}}  where duel_key = {min_id, max_id}
    # player_to_duel: %{char_id => duel_key}
    # player_to_challenge: %{target_id => challenger_id}  (reverse index)
    # rooms: %{room_id => %Room{}}  (VB6: Salas array)

    rooms_config = Map.get(opts, :rooms, [])

    rooms =
      rooms_config
      |> Enum.with_index(1)
      |> Map.new(fn {cfg, idx} ->
        {idx,
         %Room{
           id: idx,
           map_id: cfg.map_id,
           left_pos: cfg.left_pos,
           right_pos: cfg.right_pos,
           in_use: false
         }}
      end)

    {:ok,
     %{
       challenges: %{},
       duels: %{},
       player_to_duel: %{},
       player_to_challenge: %{},
       rooms: rooms
     }}
  end

  @impl true
  def handle_call({:create_challenge, challenger_id, target_id, bet}, _from, state) do
    cond do
      challenger_id == target_id ->
        {:reply, {:error, :cannot_challenge_self}, state}

      bet <= 0 ->
        {:reply, {:error, :invalid_bet}, state}

      Map.has_key?(state.player_to_duel, challenger_id) ->
        {:reply, {:error, :already_in_duel}, state}

      Map.has_key?(state.player_to_duel, target_id) ->
        {:reply, {:error, :target_in_duel}, state}

      Map.has_key?(state.challenges, challenger_id) ->
        {:reply, {:error, :already_has_challenge}, state}

      true ->
        challenge = %Challenge{
          challenger_id: challenger_id,
          target_id: target_id,
          bet: bet,
          created_at: System.monotonic_time(:millisecond)
        }

        state = %{
          state
          | challenges: Map.put(state.challenges, challenger_id, challenge),
            player_to_challenge: Map.put(state.player_to_challenge, target_id, challenger_id)
        }

        {:reply, :ok, state}
    end
  end

  def handle_call({:accept_challenge, acceptor_id, _challenger_name}, _from, state) do
    # The caller resolves the challenger name to an id before calling.
    # We look up the pending challenge by target (acceptor) id.
    challenger_id =
      case state.player_to_challenge do
        %{^acceptor_id => cid} -> cid
        _ -> nil
      end

    cond do
      challenger_id == nil ->
        {:reply, {:error, :no_pending_challenge}, state}

      Map.has_key?(state.player_to_duel, acceptor_id) ->
        {:reply, {:error, :already_in_duel}, state}

      true ->
        challenge = Map.get(state.challenges, challenger_id)

        if challenge == nil or challenge.target_id != acceptor_id do
          {:reply, {:error, :no_pending_challenge}, state}
        else
          # Verify challenger is still free
          if Map.has_key?(state.player_to_duel, challenger_id) do
            state = remove_challenge(state, challenger_id)
            {:reply, {:error, :challenger_in_duel}, state}
          else
            # VB6: BuscarSala — allocate a free room if rooms are configured
            case allocate_room(state) do
              {:error, :no_rooms_available} ->
                {:reply, {:error, :no_rooms_available}, state}

              {:ok, room, state} ->
                # Start the duel (VB6: IniciarReto)
                duel = %Duel{
                  player_a: challenger_id,
                  player_b: acceptor_id,
                  bet: challenge.bet,
                  round: 1,
                  score: 0,
                  room_id: room && room.id,
                  map_id: room && room.map_id,
                  left_pos: room && room.left_pos,
                  right_pos: room && room.right_pos,
                  original_positions: %{
                    challenger_id => nil,
                    acceptor_id => nil
                  }
                }

                duel_key = duel_key(challenger_id, acceptor_id)

                state =
                  state
                  |> remove_challenge(challenger_id)
                  |> put_in(:duels, duel_key, duel)
                  |> put_in(:player_to_duel, challenger_id, duel_key)
                  |> put_in(:player_to_duel, acceptor_id, duel_key)

                {:reply, {:ok, duel}, state}
            end
          end
        end
    end
  end

  def handle_call({:cancel_challenge, char_id}, _from, state) do
    cond do
      # Challenger cancels their own challenge
      Map.has_key?(state.challenges, char_id) ->
        state = remove_challenge(state, char_id)
        {:reply, :ok, state}

      # Target cancels (rejects) a challenge aimed at them
      Map.has_key?(state.player_to_challenge, char_id) ->
        challenger_id = Map.get(state.player_to_challenge, char_id)
        state = remove_challenge(state, challenger_id)
        {:reply, :ok, state}

      true ->
        {:reply, {:error, :no_challenge}, state}
    end
  end

  def handle_call({:abandon_duel, char_id}, _from, state) do
    case Map.get(state.player_to_duel, char_id) do
      nil ->
        {:reply, {:error, :not_in_duel}, state}

      duel_key ->
        duel = Map.fetch!(state.duels, duel_key)
        # The abandoning player loses — opponent wins
        winner_id = opponent_id(duel, char_id)
        result = finalize_duel(duel, winner_id)
        state = remove_duel(state, duel_key, duel)
        {:reply, {:ok, result}, state}
    end
  end

  def handle_call({:player_disconnected, char_id}, _from, state) do
    case Map.get(state.player_to_duel, char_id) do
      nil ->
        {:reply, {:error, :not_in_duel}, state}

      duel_key ->
        duel = Map.fetch!(state.duels, duel_key)
        # The disconnecting player forfeits — opponent wins
        winner_id = opponent_id(duel, char_id)
        result = finalize_duel(duel, winner_id)
        state = remove_duel(state, duel_key, duel)
        {:reply, {:ok, result}, state}
    end
  end

  def handle_call({:player_died, char_id}, _from, state) do
    case Map.get(state.player_to_duel, char_id) do
      nil ->
        {:reply, :not_in_duel, state}

      duel_key ->
        duel = Map.fetch!(state.duels, duel_key)
        # The dying player loses this round
        winner_of_round = opponent_id(duel, char_id)

        # Update score: positive = player_b winning, negative = player_a winning
        score_delta = if winner_of_round == duel.player_b, do: 1, else: -1
        new_score = duel.score + score_delta
        new_round = duel.round + 1

        # Check if duel is over: 3 rounds played, or 2-0 sweep
        duel_over = new_round > @best_of or abs(new_score) >= 2

        if duel_over do
          overall_winner =
            cond do
              new_score > 0 -> duel.player_b
              new_score < 0 -> duel.player_a
              true -> :tie
            end

          result = finalize_duel(%{duel | score: new_score, round: new_round}, overall_winner)
          state = remove_duel(state, duel_key, duel)
          {:reply, {:duel_round_result, result}, state}
        else
          # Next round
          duel = %{duel | score: new_score, round: new_round}
          state = put_in(state, [:duels, duel_key], duel)

          {:reply,
           {:duel_round_result,
            %{
              type: :round_won,
              round: duel.round - 1,
              round_winner: winner_of_round,
              duel: duel
            }}, state}
        end
    end
  end

  def handle_call({:get_duel, char_id}, _from, state) do
    case Map.get(state.player_to_duel, char_id) do
      nil -> {:reply, nil, state}
      duel_key -> {:reply, Map.get(state.duels, duel_key), state}
    end
  end

  def handle_call({:get_challenge, char_id}, _from, state) do
    {:reply, Map.get(state.challenges, char_id), state}
  end

  def handle_call({:in_duel?, char_id}, _from, state) do
    {:reply, Map.has_key?(state.player_to_duel, char_id), state}
  end

  def handle_call({:duel_opponent, char_id}, _from, state) do
    case Map.get(state.player_to_duel, char_id) do
      nil ->
        {:reply, nil, state}

      duel_key ->
        duel = Map.fetch!(state.duels, duel_key)
        {:reply, opponent_id(duel, char_id), state}
    end
  end

  def handle_call(:free_rooms_count, _from, state) do
    count =
      state.rooms
      |> Map.values()
      |> Enum.count(fn room -> not room.in_use end)

    {:reply, count, state}
  end

  # ── Internal helpers ───────────────────────────────────────────────────

  defp duel_key(a, b), do: {min(a, b), max(a, b)}

  defp opponent_id(%Duel{player_a: a, player_b: b}, char_id) do
    if char_id == a, do: b, else: a
  end

  defp remove_challenge(state, challenger_id) do
    case Map.get(state.challenges, challenger_id) do
      nil ->
        state

      challenge ->
        %{
          state
          | challenges: Map.delete(state.challenges, challenger_id),
            player_to_challenge: Map.delete(state.player_to_challenge, challenge.target_id)
        }
    end
  end

  defp remove_duel(state, duel_key, duel) do
    state = %{
      state
      | duels: Map.delete(state.duels, duel_key),
        player_to_duel:
          state.player_to_duel
          |> Map.delete(duel.player_a)
          |> Map.delete(duel.player_b)
    }

    # VB6: SalaLiberada — free the room
    free_room(state, duel.room_id)
  end

  defp finalize_duel(duel, :tie) do
    # Refund each player their bet
    refund = duel.bet

    %{
      type: :tie,
      player_a: duel.player_a,
      player_b: duel.player_b,
      refund: refund,
      duel: duel,
      original_positions: duel.original_positions
    }
  end

  defp finalize_duel(duel, winner_id) do
    loser_id = opponent_id(duel, winner_id)
    total_pot = duel.bet * 2
    tax = trunc(total_pot * @tax_rate)
    prize = total_pot - tax

    %{
      type: :winner,
      winner: winner_id,
      loser: loser_id,
      prize: prize,
      tax: tax,
      duel: duel,
      original_positions: duel.original_positions
    }
  end

  # ── Room management helpers (VB6: BuscarSala / SalaLiberada) ──────────

  # When no rooms are configured, allocation always succeeds with nil room.
  defp allocate_room(%{rooms: rooms} = state) when map_size(rooms) == 0 do
    {:ok, nil, state}
  end

  # Find a free room and mark it in_use (VB6: BuscarSala).
  defp allocate_room(state) do
    free_room =
      state.rooms
      |> Map.values()
      |> Enum.find(fn room -> not room.in_use end)

    case free_room do
      nil ->
        {:error, :no_rooms_available}

      room ->
        updated_room = %{room | in_use: true}
        rooms = Map.put(state.rooms, room.id, updated_room)
        {:ok, room, %{state | rooms: rooms}}
    end
  end

  # Free a room after a duel ends (VB6: SalaLiberada).
  defp free_room(state, nil), do: state

  defp free_room(state, room_id) do
    case Map.get(state.rooms, room_id) do
      nil ->
        state

      room ->
        updated_room = %{room | in_use: false}
        %{state | rooms: Map.put(state.rooms, room_id, updated_room)}
    end
  end

  # Helper for nested map puts
  defp put_in(state, key, sub_key, value) when is_atom(key) do
    Map.update!(state, key, fn m -> Map.put(m, sub_key, value) end)
  end
end
