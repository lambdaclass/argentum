defmodule Arena.Events.SiegeServer do
  @moduledoc """
  GM-triggered castle siege event (VB6: ModInvasion siege extension).

  A siege is an invasion variant where attackers try to destroy a wall/fortification
  while defenders try to eliminate all NPCs before the wall falls or time runs out.

  ## Mechanics

  - **Wall HP**: Central objective with a health pool. Attackers win if it reaches 0.
  - **Spawn boxes**: Multiple spawn areas defined by top-left/bottom-right coordinates,
    each with a heading and wall coordinate. NPCs spawn in waves from these boxes.
  - **Wave spawning**: NPCs are spawned at `spawn_interval_ms` intervals, respecting
    `max_npcs` limit (total alive at once).
  - **Top-10 scoreboard**: Tracks players by kill score, dynamic insertion.
  - **Win conditions**:
    - Defenders win: all NPCs killed (total spawned == total killed, no more waves).
    - Attackers win: wall HP <= 0 OR duration elapses.
  - **Rewards**: 50000 * gold_mult to top-10 players if defenders win.

  ## GM commands

  - `/SIEGE START map_id` -- start a siege with configured parameters
  - `/SIEGE STOP map_id` -- force-stop a running siege
  - `/SIEGE STATUS map_id` -- show siege progress

  Only one siege can be active per map at a time.
  """

  use GenServer

  require Logger

  # ── Types ──────────────────────────────────────────────────────────────

  defmodule SpawnBox do
    @moduledoc "Defines a rectangular area from which NPCs spawn."
    defstruct [:top_left, :bottom_right, :heading, :wall_coord]

    @type t :: %__MODULE__{
            top_left: {non_neg_integer(), non_neg_integer()},
            bottom_right: {non_neg_integer(), non_neg_integer()},
            heading: :north | :south | :east | :west,
            wall_coord: {non_neg_integer(), non_neg_integer()}
          }
  end

  defmodule ScoreEntry do
    @moduledoc "A player's entry in the top-10 scoreboard."
    defstruct [:char_id, :player_name, score: 0]

    @type t :: %__MODULE__{
            char_id: non_neg_integer(),
            player_name: String.t(),
            score: non_neg_integer()
          }
  end

  defmodule Siege do
    @moduledoc "The state of an active siege."
    defstruct [
      :map_id,
      :wall_hp,
      :max_wall_hp,
      :npc_types,
      :spawn_boxes,
      :duration_seconds,
      :spawn_interval_ms,
      :max_npcs,
      :total_waves,
      :started_at,
      :started_by,
      :timer_ref,
      :spawn_timer_ref,
      :gold_mult,
      :spawner_fn,
      :broadcaster_fn,
      waves_spawned: 0,
      alive_npc_ids: MapSet.new(),
      total_spawned: 0,
      total_killed: 0,
      scoreboard: [],
      finished: false
    ]
  end

  @max_scoreboard_size 10
  @default_gold_mult 1
  @base_reward 50_000

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a siege on `map_id`.

  ## Options

    * `:wall_hp` - wall hit points (required)
    * `:npc_types` - list of NPC definition IDs to spawn (required)
    * `:spawn_boxes` - list of `%SpawnBox{}` (required)
    * `:duration_seconds` - siege duration in seconds (required)
    * `:spawn_interval_ms` - ms between spawn waves (default: 30_000)
    * `:max_npcs` - maximum alive NPCs at once (default: 50)
    * `:total_waves` - total number of spawn waves (default: 10)
    * `:gold_mult` - gold reward multiplier (default: 1)
    * `:gm_name` - GM who started the siege (default: "GM")
    * `:spawner_fn` - function for NPC spawning side effects (default: no-op)
    * `:broadcaster_fn` - function for broadcast side effects (default: no-op)

  Returns `{:ok, siege_state}` or `{:error, reason}`.
  """
  def start_siege(server \\ __MODULE__, map_id, opts) do
    GenServer.call(server, {:start_siege, map_id, opts})
  end

  @doc "Stop an active siege. Returns `:ok` or `{:error, :no_siege}`."
  def stop_siege(server \\ __MODULE__, map_id) do
    GenServer.call(server, {:stop_siege, map_id})
  end

  @doc "Get the status of a siege. Returns `{:ok, info}` or `{:error, :no_siege}`."
  def siege_status(server \\ __MODULE__, map_id) do
    GenServer.call(server, {:siege_status, map_id})
  end

  @doc "List all active sieges."
  def list_sieges(server \\ __MODULE__) do
    GenServer.call(server, :list_sieges)
  end

  @doc """
  Apply damage to the wall. Returns `{:ok, remaining_hp}` or triggers attacker victory.
  """
  def damage_wall(server \\ __MODULE__, map_id, amount) do
    GenServer.call(server, {:damage_wall, map_id, amount})
  end

  @doc """
  Record a kill by a player. Updates the top-10 scoreboard.
  `instance_id` is the NPC instance that was killed.
  """
  def record_kill(server \\ __MODULE__, map_id, char_id, player_name, instance_id, score \\ 1) do
    GenServer.call(server, {:record_kill, map_id, char_id, player_name, instance_id, score})
  end

  @doc "Get the current scoreboard for a siege."
  def get_scoreboard(server \\ __MODULE__, map_id) do
    GenServer.call(server, {:get_scoreboard, map_id})
  end

  @doc "Get wall health percentage (0-100)."
  def wall_health_percent(server \\ __MODULE__, map_id) do
    GenServer.call(server, {:wall_health_percent, map_id})
  end

  @doc "Get time elapsed percentage (0-100)."
  def time_percent(server \\ __MODULE__, map_id) do
    GenServer.call(server, {:time_percent, map_id})
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{sieges: %{}}}
  end

  @impl true
  def handle_call({:start_siege, map_id, opts}, _from, state) do
    if Map.has_key?(state.sieges, map_id) do
      {:reply, {:error, :siege_already_active}, state}
    else
      case validate_siege_opts(opts) do
        {:error, _} = err ->
          {:reply, err, state}

        :ok ->
          wall_hp = Keyword.fetch!(opts, :wall_hp)
          now = System.system_time(:second)
          duration = Keyword.fetch!(opts, :duration_seconds)
          spawn_interval = Keyword.get(opts, :spawn_interval_ms, 30_000)

          timer_ref = Process.send_after(self(), {:siege_timeout, map_id}, duration * 1000)
          spawn_timer_ref = Process.send_after(self(), {:spawn_wave, map_id}, spawn_interval)

          siege = %Siege{
            map_id: map_id,
            wall_hp: wall_hp,
            max_wall_hp: wall_hp,
            npc_types: Keyword.fetch!(opts, :npc_types),
            spawn_boxes: Keyword.fetch!(opts, :spawn_boxes),
            duration_seconds: duration,
            spawn_interval_ms: spawn_interval,
            max_npcs: Keyword.get(opts, :max_npcs, 50),
            total_waves: Keyword.get(opts, :total_waves, 10),
            started_at: now,
            started_by: Keyword.get(opts, :gm_name, "GM"),
            timer_ref: timer_ref,
            spawn_timer_ref: spawn_timer_ref,
            gold_mult: Keyword.get(opts, :gold_mult, @default_gold_mult),
            spawner_fn: Keyword.get(opts, :spawner_fn, fn _map_id, _npc_type, _box -> [] end),
            broadcaster_fn: Keyword.get(opts, :broadcaster_fn, fn _msg -> :ok end),
            waves_spawned: 0,
            alive_npc_ids: MapSet.new(),
            total_spawned: 0,
            total_killed: 0,
            scoreboard: [],
            finished: false
          }

          sieges = Map.put(state.sieges, map_id, siege)
          broadcast(siege, "Siege> #{siege.started_by} ha iniciado un asedio en el mapa #{map_id}!")

          {:reply, {:ok, siege_info(siege)}, %{state | sieges: sieges}}
      end
    end
  end

  @impl true
  def handle_call({:stop_siege, map_id}, _from, state) do
    case Map.pop(state.sieges, map_id) do
      {nil, _} ->
        {:reply, {:error, :no_siege}, state}

      {siege, sieges} ->
        cancel_timers(siege)
        broadcast(siege, "Siege> El asedio en el mapa #{map_id} ha sido detenido por un GM.")
        {:reply, :ok, %{state | sieges: sieges}}
    end
  end

  @impl true
  def handle_call({:siege_status, map_id}, _from, state) do
    case Map.fetch(state.sieges, map_id) do
      {:ok, siege} ->
        {:reply, {:ok, siege_info(siege)}, state}

      :error ->
        {:reply, {:error, :no_siege}, state}
    end
  end

  @impl true
  def handle_call(:list_sieges, _from, state) do
    infos = Enum.map(state.sieges, fn {_map_id, siege} -> siege_info(siege) end)
    {:reply, {:ok, infos}, state}
  end

  @impl true
  def handle_call({:damage_wall, map_id, amount}, _from, state) do
    case Map.fetch(state.sieges, map_id) do
      {:ok, siege} ->
        new_hp = max(0, siege.wall_hp - amount)
        siege = %{siege | wall_hp: new_hp}

        if new_hp <= 0 do
          {reply, new_state} = finish_siege(siege, :attackers_win, state)
          {:reply, reply, new_state}
        else
          sieges = Map.put(state.sieges, map_id, siege)
          {:reply, {:ok, new_hp}, %{state | sieges: sieges}}
        end

      :error ->
        {:reply, {:error, :no_siege}, state}
    end
  end

  @impl true
  def handle_call({:record_kill, map_id, char_id, player_name, instance_id, score}, _from, state) do
    case Map.fetch(state.sieges, map_id) do
      {:ok, siege} ->
        if MapSet.member?(siege.alive_npc_ids, instance_id) do
          alive = MapSet.delete(siege.alive_npc_ids, instance_id)
          total_killed = siege.total_killed + 1
          scoreboard = update_scoreboard(siege.scoreboard, char_id, player_name, score)

          siege = %{
            siege
            | alive_npc_ids: alive,
              total_killed: total_killed,
              scoreboard: scoreboard
          }

          # Check defender victory: all waves done AND all NPCs killed
          if siege.waves_spawned >= siege.total_waves and MapSet.size(alive) == 0 do
            {reply, new_state} = finish_siege(siege, :defenders_win, state)
            {:reply, reply, new_state}
          else
            sieges = Map.put(state.sieges, map_id, siege)
            {:reply, {:ok, total_killed}, %{state | sieges: sieges}}
          end
        else
          {:reply, {:error, :npc_not_in_siege}, state}
        end

      :error ->
        {:reply, {:error, :no_siege}, state}
    end
  end

  @impl true
  def handle_call({:get_scoreboard, map_id}, _from, state) do
    case Map.fetch(state.sieges, map_id) do
      {:ok, siege} -> {:reply, {:ok, siege.scoreboard}, state}
      :error -> {:reply, {:error, :no_siege}, state}
    end
  end

  @impl true
  def handle_call({:wall_health_percent, map_id}, _from, state) do
    case Map.fetch(state.sieges, map_id) do
      {:ok, siege} ->
        pct = if siege.max_wall_hp > 0, do: round(siege.wall_hp / siege.max_wall_hp * 100), else: 0
        {:reply, {:ok, pct}, state}

      :error ->
        {:reply, {:error, :no_siege}, state}
    end
  end

  @impl true
  def handle_call({:time_percent, map_id}, _from, state) do
    case Map.fetch(state.sieges, map_id) do
      {:ok, siege} ->
        now = System.system_time(:second)
        elapsed = now - siege.started_at
        pct = min(100, round(elapsed / siege.duration_seconds * 100))
        {:reply, {:ok, pct}, state}

      :error ->
        {:reply, {:error, :no_siege}, state}
    end
  end

  # ── Handle Info (timers) ───────────────────────────────────────────────

  @impl true
  def handle_info({:siege_timeout, map_id}, state) do
    case Map.fetch(state.sieges, map_id) do
      {:ok, siege} ->
        {_reply, new_state} = finish_siege(siege, :attackers_win, state)
        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:spawn_wave, map_id}, state) do
    case Map.fetch(state.sieges, map_id) do
      {:ok, siege} ->
        if siege.waves_spawned >= siege.total_waves do
          # No more waves to spawn
          {:noreply, state}
        else
          alive_count = MapSet.size(siege.alive_npc_ids)

          siege =
            if alive_count < siege.max_npcs do
              do_spawn_wave(siege)
            else
              siege
            end

          # Schedule next wave if we haven't exhausted waves
          spawn_timer_ref =
            if siege.waves_spawned < siege.total_waves do
              Process.send_after(self(), {:spawn_wave, map_id}, siege.spawn_interval_ms)
            else
              nil
            end

          siege = %{siege | spawn_timer_ref: spawn_timer_ref}
          sieges = Map.put(state.sieges, map_id, siege)
          {:noreply, %{state | sieges: sieges}}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp validate_siege_opts(opts) do
    required = [:wall_hp, :npc_types, :spawn_boxes, :duration_seconds]

    missing = Enum.filter(required, fn key -> not Keyword.has_key?(opts, key) end)

    cond do
      missing != [] ->
        {:error, {:missing_options, missing}}

      Keyword.fetch!(opts, :wall_hp) <= 0 ->
        {:error, :invalid_wall_hp}

      Keyword.fetch!(opts, :duration_seconds) <= 0 ->
        {:error, :invalid_duration}

      Keyword.fetch!(opts, :npc_types) == [] ->
        {:error, :no_npc_types}

      Keyword.fetch!(opts, :spawn_boxes) == [] ->
        {:error, :no_spawn_boxes}

      true ->
        :ok
    end
  end

  defp do_spawn_wave(siege) do
    npc_type = Enum.random(siege.npc_types)
    box = Enum.random(siege.spawn_boxes)

    # Call the spawner function — returns a list of spawned instance IDs
    new_ids = siege.spawner_fn.(siege.map_id, npc_type, box)

    new_alive =
      Enum.reduce(new_ids, siege.alive_npc_ids, fn id, acc -> MapSet.put(acc, id) end)

    %{
      siege
      | waves_spawned: siege.waves_spawned + 1,
        alive_npc_ids: new_alive,
        total_spawned: siege.total_spawned + length(new_ids)
    }
  end

  defp finish_siege(siege, outcome, state) do
    cancel_timers(siege)

    {message, rewards} =
      case outcome do
        :defenders_win ->
          rewards = calculate_rewards(siege.scoreboard, siege.gold_mult)

          msg =
            "Siege> Los defensores han ganado el asedio en el mapa #{siege.map_id}! " <>
              "Muro: #{wall_pct(siege)}% HP. " <>
              "#{siege.total_killed} NPCs eliminados."

          {msg, rewards}

        :attackers_win ->
          msg =
            "Siege> Los atacantes han destruido las defensas del mapa #{siege.map_id}! " <>
              "Muro: #{wall_pct(siege)}% HP. " <>
              "#{siege.total_killed} NPCs eliminados."

          {msg, []}
      end

    broadcast(siege, message)

    sieges = Map.delete(state.sieges, siege.map_id)

    reply =
      {:siege_ended,
       %{
         outcome: outcome,
         map_id: siege.map_id,
         wall_hp: siege.wall_hp,
         max_wall_hp: siege.max_wall_hp,
         total_killed: siege.total_killed,
         total_spawned: siege.total_spawned,
         scoreboard: siege.scoreboard,
         rewards: rewards
       }}

    {reply, %{state | sieges: sieges}}
  end

  defp calculate_rewards(scoreboard, gold_mult) do
    Enum.map(scoreboard, fn entry ->
      %{char_id: entry.char_id, player_name: entry.player_name, gold: @base_reward * gold_mult}
    end)
  end

  defp update_scoreboard(scoreboard, char_id, player_name, score) do
    case Enum.find_index(scoreboard, fn e -> e.char_id == char_id end) do
      nil ->
        entry = %ScoreEntry{char_id: char_id, player_name: player_name, score: score}
        insert_sorted(scoreboard, entry)

      idx ->
        entry = Enum.at(scoreboard, idx)
        updated = %{entry | score: entry.score + score, player_name: player_name}

        scoreboard
        |> List.delete_at(idx)
        |> insert_sorted(updated)
    end
  end

  defp insert_sorted(scoreboard, entry) do
    # Insert in descending score order, then trim to max size
    pos = Enum.find_index(scoreboard, fn e -> e.score < entry.score end) || length(scoreboard)

    scoreboard
    |> List.insert_at(pos, entry)
    |> Enum.take(@max_scoreboard_size)
  end

  defp wall_pct(%{max_wall_hp: 0}), do: 0

  defp wall_pct(siege) do
    round(siege.wall_hp / siege.max_wall_hp * 100)
  end

  defp cancel_timers(siege) do
    if siege.timer_ref, do: Process.cancel_timer(siege.timer_ref)
    if siege.spawn_timer_ref, do: Process.cancel_timer(siege.spawn_timer_ref)
  end

  defp broadcast(siege, message) do
    siege.broadcaster_fn.(message)
  end

  defp siege_info(siege) do
    %{
      map_id: siege.map_id,
      wall_hp: siege.wall_hp,
      max_wall_hp: siege.max_wall_hp,
      wall_health_percent: wall_pct(siege),
      total_spawned: siege.total_spawned,
      total_killed: siege.total_killed,
      alive_npcs: MapSet.size(siege.alive_npc_ids),
      waves_spawned: siege.waves_spawned,
      total_waves: siege.total_waves,
      started_by: siege.started_by,
      scoreboard: siege.scoreboard,
      duration_seconds: siege.duration_seconds,
      started_at: siege.started_at
    }
  end
end
