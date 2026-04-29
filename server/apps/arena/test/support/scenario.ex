defmodule Arena.Test.Scenario do
  @moduledoc """
  Deterministic scenario harness for map-layer tests.

  Slice 1 surface: handlers run directly on the test process (no
  MapServer.start_link). Each `attack/cast_spell/etc.` call invokes the
  handler synchronously, captures its effects via `Effects.run/2`, and
  records them on the scenario for assertion. Slice 2 adds MapServer
  integration; slice 3 adds tick / clock / seed control.
  """

  alias Arena.Map.{Effects, Helpers, State}
  alias Arena.Test.PlayerFactory

  import Arena.Test.MapStateFactory, only: [map_state: 1]

  @type t :: %__MODULE__{state: State.t(), effects: [Arena.Map.Effect.t()]}
  defstruct [:state, effects: []]

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

    %__MODULE__{state: state, effects: []}
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
  Run an arbitrary handler closure that returns `{:ok, state, effects}`,
  capture the effects into the scenario, and return the updated
  scenario. The closure receives `scenario.state`.

  Use this for ergonomically driving any handler from a test:

      scenario
      |> run(fn s -> CombatHandlers.handle_attack(s, :atk, nil, nil) end)

  Two paths capture effects:

    1. **Closure-returned effects.** When the closure returns
       `{:ok, state, effects}` directly (e.g. handlers migrated to the
       pure `{:ok, state, effects}` contract), those effects are
       recorded as-is.

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

  For combat handlers that return `{:reply, reply, state}`, use
  `run_call/2`. (Added in slice 2; not in this commit.)
  """
  @spec run(t, (State.t() -> {:ok, State.t(), [Arena.Map.Effect.t()]})) :: t
  def run(scenario, fun) when is_function(fun, 1) do
    parent = self()
    Process.put(:arena_effects_recorder, parent)

    try do
      {:ok, new_state, effects} = fun.(scenario.state)
      Effects.run(new_state, effects)
      recorded = drain_recorded_effects()
      %{scenario | state: new_state, effects: scenario.effects ++ recorded ++ effects}
    after
      Process.delete(:arena_effects_recorder)
    end
  end

  defp drain_recorded_effects(acc \\ []) do
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
end
