defmodule Arena.Events.CaptureServer do
  @moduledoc """
  Team-based flag capture event (VB6: clsCaptura.cls + ModCaptura.bas).

  Two teams (blue/red) fight on dedicated maps. Each team must capture the
  enemy flag and return it to their base. Best-of-N rounds, with escalating
  respawn timers on death.

  ## Lifecycle

  1. `:registration` -- 90s window for players to join (GM-initiated).
  2. `:round_warmup` -- 60s countdown before a round begins.
  3. `:in_game` -- teams fight; flag pickup + capture logic runs per tick.
  4. `:finished` -- winner announced, rewards distributed.
  5. `:idle` -- no active capture event.

  ## GM commands

  - `/CAPTURA START [entry_fee] [best_of] [min_level] [max_level]`
  - `/CAPTURA STOP`
  - `/CAPTURA STATUS`

  Only one capture event can be active at a time (server-wide singleton).
  """

  use GenServer

  require Logger

  # ── Constants (VB6 parity) ──────────────────────────────────────────

  @registration_time 90
  @registration_retry_time 30
  @max_registration_retries 2
  @round_warmup_time 60
  @flag_hold_time 7
  @base_death_timer 5
  @death_timer_increment 2
  @min_participants 2

  @flag_capture_range_x 8
  @flag_capture_range_y 5

  # ── Types ──────────────────────────────────────────────────────────

  defmodule Participant do
    @moduledoc false
    defstruct [
      :char_id,
      :name,
      :level,
      :team,
      :save_map_id,
      :save_x,
      :save_y,
      deaths: 0,
      alive: true,
      respawn_timer: 0
    ]
  end

  defmodule FlagState do
    @moduledoc false
    defstruct [
      :carrier_id,
      :base_x,
      :base_y,
      at_base: true,
      hold_timer: 0
    ]
  end

  defmodule Capture do
    @moduledoc false
    defstruct [
      phase: :registration,
      entry_fee: 0,
      best_of: 3,
      min_level: 1,
      max_level: 50,
      started_by: "GM",
      started_at: 0,
      timer: 0,
      registration_retries: 0,
      participants: %{},
      current_round: 0,
      round_scores: %{blue: 0, red: 0},
      wins_needed: 2,
      flags: %{},
      blue_base: {50, 50},
      red_base: {50, 50},
      winner_team: nil
    ]
  end

  # ── Public API ─────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Start a new capture event. Only GMs should call this."
  def start_capture(entry_fee \\ 100, best_of \\ 3, min_level \\ 1, max_level \\ 50, gm_name \\ "GM", server \\ __MODULE__) do
    GenServer.call(server, {:start_capture, entry_fee, best_of, min_level, max_level, gm_name})
  end

  @doc "Register a player for the current capture event."
  def join(char_id, player_info, server \\ __MODULE__) do
    GenServer.call(server, {:join, char_id, player_info})
  end

  @doc "Process a per-second tick (countdown, flag detection, respawn timers)."
  def tick(server \\ __MODULE__) do
    GenServer.call(server, :tick)
  end

  @doc "Notify that a participant died."
  def player_died(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:player_died, char_id})
  end

  @doc "Notify that a participant moved (for flag pickup/capture checks)."
  def player_moved(char_id, x, y, server \\ __MODULE__) do
    GenServer.call(server, {:player_moved, char_id, x, y})
  end

  @doc "Stop (cancel) the current capture event."
  def stop(server \\ __MODULE__) do
    GenServer.call(server, :stop)
  end

  @doc "Get the current event status."
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "Notify that a participant disconnected."
  def player_disconnected(char_id, server \\ __MODULE__) do
    GenServer.call(server, {:player_disconnected, char_id})
  end

  # ── GenServer Callbacks ────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{capture: nil}}
  end

  @impl true
  def handle_call({:start_capture, entry_fee, best_of, min_level, max_level, gm_name}, _from, state) do
    if state.capture != nil and state.capture.phase not in [:finished, nil] do
      {:reply, {:error, :capture_already_active}, state}
    else
      wins_needed = div(best_of, 2) + 1

      capture = %Capture{
        phase: :registration,
        entry_fee: entry_fee,
        best_of: best_of,
        min_level: min_level,
        max_level: max_level,
        started_by: gm_name,
        started_at: System.system_time(:second),
        timer: @registration_time,
        registration_retries: 0,
        participants: %{},
        current_round: 0,
        round_scores: %{blue: 0, red: 0},
        wins_needed: wins_needed,
        flags: %{
          blue: %FlagState{base_x: 20, base_y: 20, at_base: true},
          red: %FlagState{base_x: 80, base_y: 80, at_base: true}
        },
        blue_base: {20, 20},
        red_base: {80, 80},
        winner_team: nil
      }

      {:reply, :ok, %{state | capture: capture}}
    end
  end

  @impl true
  def handle_call({:join, char_id, player_info}, _from, state) do
    case state.capture do
      nil ->
        {:reply, {:error, :no_capture_event}, state}

      %{phase: :registration} = c ->
        case validate_registration(c, char_id, player_info) do
          :ok ->
            team = assign_team(c)

            participant = %Participant{
              char_id: char_id,
              name: Map.get(player_info, :name, "Player"),
              level: Map.get(player_info, :level, 1),
              team: team,
              save_map_id: Map.get(player_info, :map_id),
              save_x: Map.get(player_info, :x),
              save_y: Map.get(player_info, :y)
            }

            c = %{c | participants: Map.put(c.participants, char_id, participant)}
            {:reply, {:ok, team}, %{state | capture: c}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :registration_closed}, state}
    end
  end

  @impl true
  def handle_call(:tick, _from, state) do
    case state.capture do
      nil ->
        {:reply, {:ok, :idle}, state}

      c ->
        {c, events} = process_tick(c)

        new_state =
          if c.phase == :finished do
            %{state | capture: c}
          else
            %{state | capture: c}
          end

        {:reply, {:ok, c.phase, events}, new_state}
    end
  end

  @impl true
  def handle_call({:player_died, char_id}, _from, state) do
    case state.capture do
      %{phase: :in_game} = c ->
        case Map.fetch(c.participants, char_id) do
          {:ok, participant} ->
            deaths = participant.deaths + 1
            respawn_time = @base_death_timer + @death_timer_increment * participant.deaths

            participant = %{participant | deaths: deaths, alive: false, respawn_timer: respawn_time}

            # If player was carrying a flag, drop it (return to base)
            c = drop_flag_if_carrying(c, char_id)

            c = %{c | participants: Map.put(c.participants, char_id, participant)}
            {:reply, {:ok, :died, respawn_time}, %{state | capture: c}}

          :error ->
            {:reply, {:error, :not_in_event}, state}
        end

      _ ->
        {:reply, {:error, :not_in_game}, state}
    end
  end

  @impl true
  def handle_call({:player_moved, char_id, x, y}, _from, state) do
    case state.capture do
      %{phase: :in_game} = c ->
        case Map.fetch(c.participants, char_id) do
          {:ok, participant} ->
            {c, events} = check_flag_interaction(c, participant, x, y)
            {:reply, {:ok, events}, %{state | capture: c}}

          :error ->
            {:reply, {:error, :not_in_event}, state}
        end

      _ ->
        {:reply, {:error, :not_in_game}, state}
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    case state.capture do
      nil ->
        {:reply, {:error, :no_capture_event}, state}

      _c ->
        {:reply, :ok, %{state | capture: nil}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    case state.capture do
      nil ->
        {:reply, {:ok, :idle, %{}}, state}

      c ->
        info = %{
          phase: c.phase,
          timer: c.timer,
          participant_count: map_size(c.participants),
          round_scores: c.round_scores,
          current_round: c.current_round,
          best_of: c.best_of,
          entry_fee: c.entry_fee,
          winner_team: c.winner_team
        }

        {:reply, {:ok, c.phase, info}, state}
    end
  end

  @impl true
  def handle_call({:player_disconnected, char_id}, _from, state) do
    case state.capture do
      nil ->
        {:reply, {:error, :no_capture_event}, state}

      c ->
        case Map.fetch(c.participants, char_id) do
          {:ok, _participant} ->
            c = drop_flag_if_carrying(c, char_id)
            c = %{c | participants: Map.delete(c.participants, char_id)}

            # Check if a team is now empty during in_game
            c =
              if c.phase == :in_game do
                check_team_forfeit(c)
              else
                c
              end

            {:reply, :ok, %{state | capture: c}}

          :error ->
            {:reply, {:error, :not_in_event}, state}
        end
    end
  end

  # ── Pure State Logic ───────────────────────────────────────────────

  @doc false
  def validate_registration(capture, char_id, player_info) do
    cond do
      Map.has_key?(capture.participants, char_id) ->
        {:error, :already_registered}

      Map.get(player_info, :gold, 0) < capture.entry_fee ->
        {:error, :insufficient_gold}

      Map.get(player_info, :level, 1) < capture.min_level ->
        {:error, :level_too_low}

      Map.get(player_info, :level, 1) > capture.max_level ->
        {:error, :level_too_high}

      Map.get(player_info, :dead, false) ->
        {:error, :player_dead}

      Map.get(player_info, :jailed, false) ->
        {:error, :player_jailed}

      Map.get(player_info, :trade_partner_id) != nil ->
        {:error, :player_trading}

      Map.get(player_info, :mounted, false) ->
        {:error, :player_mounted}

      Map.get(player_info, :navigating, false) ->
        {:error, :player_navigating}

      true ->
        :ok
    end
  end

  @doc false
  def assign_team(capture) do
    blue_count = count_team(capture, :blue)
    red_count = count_team(capture, :red)

    if blue_count <= red_count, do: :blue, else: :red
  end

  @doc false
  def count_team(capture, team) do
    capture.participants
    |> Map.values()
    |> Enum.count(fn p -> p.team == team end)
  end

  @doc false
  def process_tick(capture) do
    case capture.phase do
      :registration ->
        tick_registration(capture)

      :round_warmup ->
        tick_round_warmup(capture)

      :in_game ->
        tick_in_game(capture)

      :finished ->
        {capture, []}
    end
  end

  defp tick_registration(c) do
    new_timer = c.timer - 1

    if new_timer <= 0 do
      if map_size(c.participants) >= @min_participants do
        # Enough participants, move to round warmup
        c = %{c | phase: :round_warmup, timer: @round_warmup_time, current_round: 1}
        {c, [:registration_closed]}
      else
        # Not enough participants, retry
        if c.registration_retries < @max_registration_retries do
          c = %{c | timer: @registration_retry_time, registration_retries: c.registration_retries + 1}
          {c, [:registration_extended]}
        else
          c = %{c | phase: :finished, winner_team: nil}
          {c, [:event_cancelled_insufficient_players]}
        end
      end
    else
      {%{c | timer: new_timer}, []}
    end
  end

  defp tick_round_warmup(c) do
    new_timer = c.timer - 1

    if new_timer <= 0 do
      # Start the round — reset flags, respawn all players
      c = start_round(c)
      {c, [:round_started]}
    else
      {%{c | timer: new_timer}, []}
    end
  end

  defp tick_in_game(c) do
    # Process respawn timers
    c = process_respawn_timers(c)

    # Process flag hold timers
    {c, events} = process_flag_hold_timers(c)

    {c, events}
  end

  defp start_round(c) do
    # Reset all participants to alive
    participants =
      Map.new(c.participants, fn {id, p} ->
        {id, %{p | alive: true, respawn_timer: 0}}
      end)

    # Reset flags to base
    flags = %{
      blue: %FlagState{base_x: elem(c.blue_base, 0), base_y: elem(c.blue_base, 1), at_base: true},
      red: %FlagState{base_x: elem(c.red_base, 0), base_y: elem(c.red_base, 1), at_base: true}
    }

    %{c | phase: :in_game, participants: participants, flags: flags}
  end

  defp process_respawn_timers(c) do
    participants =
      Map.new(c.participants, fn {id, p} ->
        if not p.alive and p.respawn_timer > 0 do
          new_timer = p.respawn_timer - 1

          if new_timer <= 0 do
            {id, %{p | alive: true, respawn_timer: 0}}
          else
            {id, %{p | respawn_timer: new_timer}}
          end
        else
          {id, p}
        end
      end)

    %{c | participants: participants}
  end

  defp process_flag_hold_timers(c) do
    Enum.reduce([:blue, :red], {c, []}, fn team, {c_acc, events_acc} ->
      flag = Map.fetch!(c_acc.flags, team)

      if flag.carrier_id != nil and flag.hold_timer > 0 do
        new_hold = flag.hold_timer - 1

        if new_hold <= 0 do
          # Flag captured! The carrier's team wins the round
          carrier = Map.get(c_acc.participants, flag.carrier_id)
          capturing_team = if carrier, do: carrier.team, else: nil

          if capturing_team do
            c_acc = score_round(c_acc, capturing_team)
            {c_acc, events_acc ++ [{:flag_captured, capturing_team}]}
          else
            flag = %{flag | hold_timer: 0, carrier_id: nil, at_base: true}
            c_acc = %{c_acc | flags: Map.put(c_acc.flags, team, flag)}
            {c_acc, events_acc}
          end
        else
          flag = %{flag | hold_timer: new_hold}
          c_acc = %{c_acc | flags: Map.put(c_acc.flags, team, flag)}
          {c_acc, events_acc}
        end
      else
        {c_acc, events_acc}
      end
    end)
  end

  defp score_round(c, winning_team) do
    scores = Map.update!(c.round_scores, winning_team, &(&1 + 1))
    c = %{c | round_scores: scores}

    if scores[winning_team] >= c.wins_needed do
      # Event over, this team wins
      rewards = compute_rewards(c, winning_team)
      %{c | phase: :finished, winner_team: winning_team, round_scores: scores}
      |> Map.put(:rewards, rewards)
    else
      # Next round warmup
      %{c | phase: :round_warmup, timer: @round_warmup_time, current_round: c.current_round + 1, round_scores: scores}
    end
  end

  @doc false
  def compute_rewards(capture, winning_team) do
    fee = capture.entry_fee
    total_participants = map_size(capture.participants)
    total_pot = fee * total_participants

    winners =
      capture.participants
      |> Map.values()
      |> Enum.filter(fn p -> p.team == winning_team end)

    winner_count = length(winners)

    reward_per_winner =
      if winner_count > 0 do
        div(total_pot, winner_count)
      else
        0
      end

    %{
      winning_team: winning_team,
      reward_per_winner: reward_per_winner,
      total_pot: total_pot,
      winners: Enum.map(winners, fn p -> p.char_id end)
    }
  end

  @doc false
  def check_flag_interaction(c, participant, x, y) do
    if not participant.alive do
      {c, []}
    else
      enemy_team = if participant.team == :blue, do: :red, else: :blue
      own_team = participant.team

      enemy_flag = Map.fetch!(c.flags, enemy_team)

      # Check 1: Pick up enemy flag at their base
      {c, events} =
        if enemy_flag.at_base and enemy_flag.carrier_id == nil and
             in_base_range?(x, y, enemy_flag.base_x, enemy_flag.base_y) do
          flag = %{enemy_flag | at_base: false, carrier_id: participant.char_id, hold_timer: 0}
          c = %{c | flags: Map.put(c.flags, enemy_team, flag)}
          {c, [{:flag_picked_up, participant.char_id, enemy_team}]}
        else
          {c, []}
        end

      # Check 2: Carrier bringing enemy flag to own base
      {c, events} =
        if enemy_flag.carrier_id == participant.char_id and not enemy_flag.at_base do
          own_base = if own_team == :blue, do: c.blue_base, else: c.red_base
          own_base_x = elem(own_base, 0)
          own_base_y = elem(own_base, 1)

          if in_base_range?(x, y, own_base_x, own_base_y) do
            # Start the hold timer for capture
            updated_enemy_flag = Map.fetch!(c.flags, enemy_team)

            if updated_enemy_flag.hold_timer == 0 do
              flag = %{updated_enemy_flag | hold_timer: @flag_hold_time}
              c = %{c | flags: Map.put(c.flags, enemy_team, flag)}
              {c, events ++ [{:flag_hold_started, participant.char_id}]}
            else
              {c, events}
            end
          else
            # Moved away from base, reset hold timer if active
            updated_enemy_flag = Map.fetch!(c.flags, enemy_team)

            if updated_enemy_flag.hold_timer > 0 do
              flag = %{updated_enemy_flag | hold_timer: 0}
              c = %{c | flags: Map.put(c.flags, enemy_team, flag)}
              {c, events ++ [{:flag_hold_cancelled, participant.char_id}]}
            else
              {c, events}
            end
          end
        else
          {c, events}
        end

      # Check 3: Touching own flag (recapture check is not part of base VB6 spec)
      # Omitted — not in VB6 baseline

      {c, events}
    end
  end

  defp in_base_range?(x, y, base_x, base_y) do
    abs(x - base_x) <= @flag_capture_range_x and
      abs(y - base_y) <= @flag_capture_range_y
  end

  defp drop_flag_if_carrying(c, char_id) do
    Enum.reduce([:blue, :red], c, fn team, c_acc ->
      flag = Map.fetch!(c_acc.flags, team)

      if flag.carrier_id == char_id do
        flag = %{flag | carrier_id: nil, at_base: true, hold_timer: 0}
        %{c_acc | flags: Map.put(c_acc.flags, team, flag)}
      else
        c_acc
      end
    end)
  end

  defp check_team_forfeit(c) do
    blue_count = count_team(c, :blue)
    red_count = count_team(c, :red)

    cond do
      blue_count == 0 and red_count > 0 ->
        %{c | phase: :finished, winner_team: :red}

      red_count == 0 and blue_count > 0 ->
        %{c | phase: :finished, winner_team: :blue}

      blue_count == 0 and red_count == 0 ->
        %{c | phase: :finished, winner_team: nil}

      true ->
        c
    end
  end

  # ── Accessors for testing ──────────────────────────────────────────

  @doc false
  def registration_time, do: @registration_time
  @doc false
  def registration_retry_time, do: @registration_retry_time
  @doc false
  def max_registration_retries, do: @max_registration_retries
  @doc false
  def round_warmup_time, do: @round_warmup_time
  @doc false
  def flag_hold_time, do: @flag_hold_time
  @doc false
  def base_death_timer, do: @base_death_timer
  @doc false
  def death_timer_increment, do: @death_timer_increment
  @doc false
  def flag_capture_range_x, do: @flag_capture_range_x
  @doc false
  def flag_capture_range_y, do: @flag_capture_range_y
end
