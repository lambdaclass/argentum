defmodule Arena.Test.Scenario do
  @moduledoc """
  Deterministic scenario harness for map-layer tests.

  Slice 1 surface: handlers run directly on the test process (no
  MapServer.start_link). Each `attack/cast_spell/etc.` call invokes the
  handler synchronously, captures its effects via `Effects.run/2`, and
  records them on the scenario for assertion. Slice 2 adds typed
  ergonomic drivers (`attack/3`, `cast_spell/4`) plus `last_reply/1`;
  slice 3 adds tick / clock / seed control.
  """

  alias Arena.Entity.NpcEntity
  alias Arena.Map.{Effects, Helpers, State}
  alias Arena.Test.PlayerFactory

  import Arena.Test.MapStateFactory, only: [map_state: 1]

  @type t :: %__MODULE__{
          state: State.t(),
          effects: [Arena.Map.Effect.t()],
          last_reply: term() | nil,
          clock_ms: integer()
        }
  defstruct [:state, effects: [], last_reply: nil, clock_ms: 0]

  @doc """
  Build a fresh scenario. Defaults:
    * `:map_id` — random unique id ≥ 10_000 (synthetic test map; bypasses
      production map load + background ticks).
    * `:visibility_mode` — `:global`.
    * `:meta` — `%{safe_zone: false}`.
  """
  @spec new(keyword()) :: t
  def new(opts \\ []) do
    map_id = Keyword.get(opts, :map_id, 10_000 + :erlang.unique_integer([:positive]))
    meta = Keyword.get(opts, :meta, %{safe_zone: false})

    state =
      map_state(
        map_id: map_id,
        meta: meta,
        visibility_mode: Keyword.get(opts, :visibility_mode, :global),
        sessions: %{},
        players: %{}
      )

    scenario = %__MODULE__{state: state, effects: []}
    set_clock(scenario, Keyword.get(opts, :clock, 0))
  end

  @doc """
  Add a player to the scenario. `id` is the char_id used as a map key in
  `state.players` and `state.sessions`. Session pid is the test process
  by default — effects routed to that char_id will land in the test
  mailbox via `Effects.run/2`. The recorded effects buffer on the
  scenario captures them synchronously via the handler's return value
  (see `run/2`).

  Also writes `{:player, id}` into `state.occupancy` at the player's
  `(x, y)` so handlers that query `Helpers.get_occupancy/3` (e.g. melee
  facing-tile lookups) find the player. MapServer does the same write
  on entry/movement.
  """
  @spec with_player(t, term(), keyword()) :: t
  def with_player(scenario, id, overrides \\ []) do
    overrides = Keyword.put_new(overrides, :char_id, id)
    entity = PlayerFactory.player(overrides)

    new_state = %{
      scenario.state
      | players: Map.put(scenario.state.players, id, entity),
        sessions: Map.put(scenario.state.sessions, id, self()),
        occupancy:
          Helpers.set_occupancy(scenario.state.occupancy, entity.x, entity.y, {:player, id})
    }

    %{scenario | state: new_state}
  end

  @doc """
  Add an NPC to the scenario. `instance_id` is the key into
  `state.npcs_live` (matching the live map). Mirrors `with_player/3`:

    * Builds an `%Arena.Entity.NpcEntity{}` with sensible defaults.
    * Writes the NPC into `state.npcs_live[instance_id]`.
    * Mirrors `char_index -> instance_id` into
      `state.npc_char_indices` so `char_index`-based lookups (e.g. AO20
      packet routing) resolve.
    * Marks the NPC's `(x, y)` tile as `{:npc, instance_id}` in
      `state.occupancy` so adjacency / facing-tile lookups succeed.

  Override keys must exist on the `NpcEntity` struct.
  """
  @spec with_npc(t, term(), keyword()) :: t
  def with_npc(scenario, instance_id, overrides \\ []) do
    overrides =
      overrides
      |> Keyword.put_new(:instance_id, instance_id)
      |> Keyword.put_new(:char_index, 100 + :erlang.phash2(instance_id, 1_000))
      |> Keyword.put_new(:x, 50)
      |> Keyword.put_new(:y, 50)

    {x, y} = {Keyword.fetch!(overrides, :x), Keyword.fetch!(overrides, :y)}
    char_index = Keyword.fetch!(overrides, :char_index)

    overrides =
      overrides
      |> Keyword.put_new(:spawn_x, x)
      |> Keyword.put_new(:spawn_y, y)

    npc = struct!(NpcEntity, overrides)

    new_state = %{
      scenario.state
      | npcs_live: Map.put(scenario.state.npcs_live, instance_id, npc),
        npc_char_indices: Map.put(scenario.state.npc_char_indices, char_index, instance_id),
        occupancy:
          Helpers.set_occupancy(scenario.state.occupancy, npc.x, npc.y, {:npc, instance_id})
    }

    %{scenario | state: new_state}
  end

  @doc """
  Stamp `value` into `state.occupancy` at `(x, y)`. Escape hatch for
  tests that need to set an occupancy slot without going through
  `with_player`/`with_npc` (e.g. ground items, blocked tiles, or NPCs
  placed at a different tile than the entity record).
  """
  @spec with_occupancy(t, pos_integer(), pos_integer(), term()) :: t
  def with_occupancy(scenario, x, y, value) do
    new_state = %{
      scenario.state
      | occupancy: Helpers.set_occupancy(scenario.state.occupancy, x, y, value)
    }

    %{scenario | state: new_state}
  end

  @doc """
  Apply a closure that mutates `scenario.state` directly without
  capturing effects. Use for tests that drive a handler returning a
  non-effect-shaped value (e.g. `{:noreply, state}` or
  `{:ok, state}` from synchronous handlers that don't yet thread
  through `Arena.Map.Effects`). Closures must return `State.t()`.

      scenario
      |> update_state(fn s ->
        {:ok, new_state, _effects} = Crafting.handle_work(s, 7, :taming)
        new_state
      end)
  """
  @spec update_state(t, (State.t() -> State.t())) :: t
  def update_state(scenario, fun) when is_function(fun, 1) do
    %{scenario | state: fun.(scenario.state)}
  end

  @doc """
  Drive an arbitrary handler that returns `{state, effects}` (no reply
  tuple), capturing effects through `Effects.run/2` so they land in
  `emitted_effects/1`.

  Use when calling a handler outside the typed surface of `attack/3` or
  `cast_spell/4` (e.g. `CombatHandlers.handle_attack_target/4`,
  `SpellEffects.apply_spell_status/6`, `NpcAi.despawn_pet/3`). The
  closure receives `state` and returns `{state, effects}`.

      scenario
      |> run_effects(fn state ->
        CombatHandlers.handle_attack_target(state, char_id, entity, {:npc, 1})
      end)
  """
  @spec run_effects(t, (State.t() -> {State.t(), [Arena.Map.Effect.t()]})) :: t
  def run_effects(scenario, fun) when is_function(fun, 1) do
    drive_run(scenario, fun)
  end

  @doc """
  Run an arbitrary handler closure that returns `{:ok, state, effects}`,
  capture the effects into the scenario, and return the updated
  scenario. The closure receives `scenario.state`.

  Use this for ergonomically driving any handler from a test:

      scenario
      |> run(fn s -> CombatHandlers.handle_attack(s, :atk, nil, nil) end)

  Two paths capture effects:

    1. **Closure-returned effects.** When the closure returns
       `{:ok, state, effects}` directly (e.g. handlers migrated to the
       pure `{:ok, state, effects}` contract), those effects are run
       through `Effects.run/2` here and recorded by the recorder hook.

    2. **Effects.run/2 recorder.** Some handlers (notably
       `CombatHandlers.handle_attack/4`) call `Effects.run/2`
       internally and return `{:reply, reply, state}` — the closure
       receives the post-dispatch state but never sees the effect
       list. To capture those, `Effects.run/2` checks
       `:arena_effects_recorder` in the process dictionary; when it
       points to the test process, the runner forwards each effect
       list as `{:arena_effects_recorded, effects}`. We set the key
       for the duration of `fun.(state)` and drain the mailbox
       afterward.

  For combat handlers that return `{:reply, reply, state}` (e.g.
  `CombatHandlers.handle_attack/4`), prefer `attack/3` / `cast_spell/4`
  — they wrap the same recorder pattern with a typed surface.
  """
  @spec run(t, (State.t() -> {:ok, State.t(), [Arena.Map.Effect.t()]})) :: t
  def run(scenario, fun) when is_function(fun, 1) do
    Process.put(:arena_effects_recorder, self())

    try do
      {:ok, new_state, returned_effects} = fun.(scenario.state)
      Effects.run(new_state, returned_effects)
      captured = drain_recorded_effects()
      %{scenario | state: new_state, effects: scenario.effects ++ captured}
    after
      Process.delete(:arena_effects_recorder)
    end
  end

  @doc """
  Drive `CombatHandlers.handle_attack/4` against the scenario state.
  Captures effects via the runner recorder. Returns the updated scenario;
  the underlying reply (`:ok` or `{:error, reason}`) is recorded under
  `:last_reply` for tests that need it.

      scenario
      |> attack(:atk, target_x: 50, target_y: 51)
      |> assert_effect(:send, to: :def, packet: :user_hitted_by_user)
  """
  @spec attack(t, term(), keyword()) :: t
  def attack(scenario, char_id, opts \\ []) do
    target_x = Keyword.get(opts, :target_x)
    target_y = Keyword.get(opts, :target_y)

    drive_call(scenario, fn state ->
      Arena.Map.CombatHandlers.handle_attack(state, char_id, target_x, target_y)
    end)
  end

  @doc """
  Drive `CombatHandlers.handle_cast_spell/5` against the scenario state.
  """
  @spec cast_spell(t, term(), pos_integer(), keyword()) :: t
  def cast_spell(scenario, char_id, spell_slot, opts \\ []) do
    target_x = Keyword.get(opts, :target_x)
    target_y = Keyword.get(opts, :target_y)

    drive_call(scenario, fn state ->
      Arena.Map.CombatHandlers.handle_cast_spell(state, char_id, spell_slot, target_x, target_y)
    end)
  end

  @doc "Last reply term from a `:reply, _, _` handler (attack / cast_spell). Nil if the last action was a cast."
  @spec last_reply(t) :: term() | nil
  def last_reply(%__MODULE__{last_reply: r}), do: r

  # Drive a handler that returns `{:reply, reply, state}` (synchronous).
  # Captures effects via the recorder hook in `Effects.run/2`. The handler
  # already runs effects internally, so the closure return doesn't carry
  # them — we drain the recorder mailbox after the call returns.
  defp drive_call(scenario, fun) when is_function(fun, 1) do
    Process.put(:arena_effects_recorder, self())

    try do
      {:reply, reply, new_state} = fun.(scenario.state)
      captured = drain_recorded_effects()

      %{
        scenario
        | state: new_state,
          effects: scenario.effects ++ captured,
          last_reply: reply
      }
    after
      Process.delete(:arena_effects_recorder)
    end
  end

  defp drain_recorded_effects do
    drain_recorded_effects([])
  end

  defp drain_recorded_effects(acc) do
    receive do
      {:arena_effects_recorded, effects} -> drain_recorded_effects(acc ++ effects)
    after
      0 -> acc
    end
  end

  @doc "Return the current `%Arena.Map.State{}`."
  @spec state(t) :: State.t()
  def state(%__MODULE__{state: s}), do: s

  @doc "Look up a player by id."
  @spec entity(t, term()) :: AoEntities.PlayerEntity.t() | nil
  def entity(%__MODULE__{state: s}, id), do: Map.get(s.players, id)

  @doc "All effects recorded since scenario creation (or last `clear_effects/1`)."
  @spec emitted_effects(t) :: [Arena.Map.Effect.t()]
  def emitted_effects(%__MODULE__{effects: e}), do: e

  @doc "Clear the recorded effects buffer (e.g. between two actions)."
  @spec clear_effects(t) :: t
  def clear_effects(scenario), do: %{scenario | effects: []}

  @doc """
  Freeze the test clock at `ms` (a `monotonic_time(:millisecond)`-shaped
  integer). All subsequent `Arena.Clock.now_ms/0` calls in this test
  process return `ms` until `advance_clock/2` or another `set_clock/2`.
  """
  @spec set_clock(t, integer()) :: t
  def set_clock(scenario, ms) when is_integer(ms) do
    Process.put(:arena_clock_ms, ms)
    %{scenario | clock_ms: ms}
  end

  @doc """
  Advance the frozen test clock by `delta` milliseconds. Reads the
  scenario's `clock_ms` and forwards to `set_clock/2`.
  """
  @spec advance_clock(t, non_neg_integer()) :: t
  def advance_clock(scenario, delta) when is_integer(delta) and delta >= 0 do
    set_clock(scenario, scenario.clock_ms + delta)
  end

  @doc """
  Install a deterministic RNG strategy. `seed` can be a function (used
  directly), a list (consumed in order via `Arena.Test.Rng.list/1`), or
  a constant integer/float (returned for every `Arena.Rng.uniform/0,1`
  call via `Arena.Test.Rng.constant/1`).

  Production code reading `Arena.Rng.uniform/0,1` will now get
  deterministic values. `:rand`-direct calls are unaffected — those
  sites need migration to `Arena.Rng` first.
  """
  @spec set_seed(t, function() | list() | number()) :: t
  def set_seed(scenario, fun) when is_function(fun, 1) do
    Process.put(:arena_test_rng, fun)
    scenario
  end

  def set_seed(scenario, list) when is_list(list) do
    set_seed(scenario, Arena.Test.Rng.list(list))
  end

  def set_seed(scenario, value) when is_number(value) do
    set_seed(scenario, Arena.Test.Rng.constant(value))
  end

  @doc """
  Run one tick of the named subsystem inline. The synthetic test map
  already has the periodic timers disabled, so ticks are opt-in:

    * `:regen`  — hunger/thirst drain, regen HP/mana, penalty decrement
    * `:buff`   — buff expiry, poison damage, blind/dumb/paralyzed timers
    * `:npc_ai` — respawn checks, NPC movement, NPC combat decisions
  """
  @spec tick(t, :regen | :buff | :npc_ai) :: t
  def tick(scenario, :regen) do
    drive_run(scenario, fn state ->
      Arena.Map.StatusTicks.process_regen_tick(state)
    end)
  end

  def tick(scenario, :buff) do
    drive_run(scenario, fn state ->
      now = Arena.Clock.now_ms()

      Enum.reduce(state.players, {state, []}, fn {char_id, entity}, {acc, eacc} ->
        {acc, effects} = Arena.Map.StatusTicks.process_player_buffs(acc, char_id, entity, now)
        {acc, eacc ++ effects}
      end)
    end)
  end

  def tick(scenario, :npc_ai) do
    drive_run(scenario, fn state ->
      Arena.NpcAi.tick(state)
    end)
  end

  # Drive a handler that returns `{state, effects}` (no reply tuple).
  # Mirrors `drive_call/2`: sets the recorder pid, runs the handler,
  # dispatches the returned effects through `Effects.run/2` so the
  # recorder hook captures them, and drains the mailbox.
  defp drive_run(scenario, fun) when is_function(fun, 1) do
    Process.put(:arena_effects_recorder, self())

    try do
      {new_state, returned_effects} = fun.(scenario.state)
      Effects.run(new_state, returned_effects)
      captured = drain_recorded_effects()
      %{scenario | state: new_state, effects: scenario.effects ++ captured}
    after
      Process.delete(:arena_effects_recorder)
    end
  end
end
