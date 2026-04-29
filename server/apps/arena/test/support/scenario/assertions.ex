defmodule Arena.Test.Scenario.Assertions do
  @moduledoc """
  Gameplay-shape assertions over `Arena.Map.Effect.t()` lists captured
  by a scenario.

  Slice 3 surface covers every effect kind produced by `Arena.Map.Effects`:
  `:send`, `:broadcast_visible`, `:broadcast_visible_all`,
  `:broadcast_visible_except`, `:broadcast_map`,
  `:broadcast_character_change`, `:hide_from_non_gm`,
  `:reveal_to_non_gm`, and `:transfer`. All matchers honour the same
  keyword surface — `:to`, `:exclude`, `:at`, `:char_id`, `:dest_map`,
  `:dest_xy`, `:packet` — passing `nil`/omitted means "any".

  Use `assert_effect/3` for "must be present", `refute_effect/3` for
  "must be absent", and `effects_for/3` to grab the matching effects
  for ad-hoc assertions.
  """

  alias Arena.Test.Scenario

  import ExUnit.Assertions

  @doc """
  Assert that the scenario emitted an effect of `kind` matching `opts`.

  Examples:

      assert_effect(s, :send, to: :defender, packet: :user_hitted_by_user)
      assert_effect(s, :broadcast_visible_all, at: {50, 50}, packet: :create_fx)
      assert_effect(s, :broadcast_visible_except, exclude: :atk, at: {50, 50}, packet: :char_swing)
      assert_effect(s, :broadcast_map, packet: :console_msg)
      assert_effect(s, :broadcast_character_change, char_id: :defender)
      assert_effect(s, :hide_from_non_gm, char_id: :hider)
      assert_effect(s, :reveal_to_non_gm, char_id: :revealed)
      assert_effect(s, :transfer, to: :p, dest_map: 5, dest_xy: {60, 70})
  """
  defmacro assert_effect(scenario, kind, opts \\ []) do
    quote do
      Arena.Test.Scenario.Assertions.__assert_effect__(
        unquote(scenario),
        unquote(kind),
        unquote(opts)
      )
    end
  end

  @doc "Assert NO effect of `kind` matching `opts` was emitted."
  defmacro refute_effect(scenario, kind, opts \\ []) do
    quote do
      Arena.Test.Scenario.Assertions.__refute_effect__(
        unquote(scenario),
        unquote(kind),
        unquote(opts)
      )
    end
  end

  @doc false
  def __assert_effect__(%Scenario{} = scenario, kind, opts) do
    matches = effects_for(scenario, kind, opts)

    assert matches != [],
           "expected an effect #{format_kind(kind, opts)}; got: #{inspect(Scenario.emitted_effects(scenario), pretty: true, limit: :infinity)}"

    scenario
  end

  @doc false
  def __refute_effect__(%Scenario{} = scenario, kind, opts) do
    matches = effects_for(scenario, kind, opts)

    assert matches == [],
           "expected NO effect #{format_kind(kind, opts)}; got matches: #{inspect(matches, pretty: true, limit: :infinity)}"

    scenario
  end

  @doc "Return all effects of `kind` matching `opts` (for ad-hoc assertions)."
  @spec effects_for(Scenario.t(), atom(), keyword()) :: [Arena.Map.Effect.t()]
  def effects_for(%Scenario{} = scenario, kind, opts \\ []) do
    Enum.filter(Scenario.emitted_effects(scenario), &match_effect(&1, kind, opts))
  end

  # ──────────────────────────────────────────────────────────────────────
  # Per-kind match clauses
  # ──────────────────────────────────────────────────────────────────────

  defp match_effect({:send, to, %{payload: payload}}, :send, opts) do
    to_matches?(to, opts) and packet_id_matches?(payload, opts)
  end

  defp match_effect({:broadcast_visible, x, y, %{payload: payload}}, :broadcast_visible, opts) do
    xy_matches?({x, y}, opts) and packet_id_matches?(payload, opts)
  end

  defp match_effect(
         {:broadcast_visible_all, x, y, %{payload: payload}},
         :broadcast_visible_all,
         opts
       ) do
    xy_matches?({x, y}, opts) and packet_id_matches?(payload, opts)
  end

  defp match_effect(
         {:broadcast_visible_except, x, y, exclude, %{payload: payload}},
         :broadcast_visible_except,
         opts
       ) do
    xy_matches?({x, y}, opts) and exclude_matches?(exclude, opts) and
      packet_id_matches?(payload, opts)
  end

  defp match_effect({:broadcast_map, %{payload: payload}}, :broadcast_map, opts) do
    packet_id_matches?(payload, opts)
  end

  defp match_effect({:broadcast_character_change, entity}, :broadcast_character_change, opts) do
    entity_char_id_matches?(entity, opts)
  end

  defp match_effect({:hide_from_non_gm, entity}, :hide_from_non_gm, opts) do
    entity_char_id_matches?(entity, opts)
  end

  defp match_effect({:reveal_to_non_gm, entity}, :reveal_to_non_gm, opts) do
    entity_char_id_matches?(entity, opts)
  end

  defp match_effect(
         {:transfer, char_id, dest_map, dest_x, dest_y, _entity},
         :transfer,
         opts
       ) do
    to_matches?(char_id, opts) and
      dest_map_matches?(dest_map, opts) and
      dest_xy_matches?({dest_x, dest_y}, opts)
  end

  defp match_effect(_, _, _), do: false

  # ──────────────────────────────────────────────────────────────────────
  # Match helpers
  # ──────────────────────────────────────────────────────────────────────

  defp to_matches?(to, opts) do
    case Keyword.fetch(opts, :to) do
      :error -> true
      {:ok, expected} -> expected == to
    end
  end

  defp exclude_matches?(exclude, opts) do
    case Keyword.fetch(opts, :exclude) do
      :error -> true
      {:ok, expected} -> expected == exclude
    end
  end

  defp xy_matches?(xy, opts) do
    case Keyword.fetch(opts, :at) do
      :error -> true
      {:ok, expected} -> expected == xy
    end
  end

  defp entity_char_id_matches?(entity, opts) do
    case Keyword.fetch(opts, :char_id) do
      :error -> true
      {:ok, expected} -> Map.get(entity, :char_id) == expected
    end
  end

  defp dest_map_matches?(dest_map, opts) do
    case Keyword.fetch(opts, :dest_map) do
      :error -> true
      {:ok, expected} -> expected == dest_map
    end
  end

  defp dest_xy_matches?(xy, opts) do
    case Keyword.fetch(opts, :dest_xy) do
      :error -> true
      {:ok, expected} -> expected == xy
    end
  end

  defp packet_id_matches?(<<id::little-signed-integer-16, _::binary>>, opts) do
    case Keyword.fetch(opts, :packet) do
      :error -> true
      {:ok, name} -> apply(AoProtocol.PacketIds.Server, name, []) == id
    end
  end

  defp packet_id_matches?(_payload, opts) do
    not Keyword.has_key?(opts, :packet)
  end

  # ──────────────────────────────────────────────────────────────────────
  # Failure formatting
  # ──────────────────────────────────────────────────────────────────────

  defp format_kind(kind, opts) do
    interesting =
      [:to, :exclude, :at, :char_id, :dest_map, :dest_xy, :packet]
      |> Enum.flat_map(fn key ->
        case Keyword.fetch(opts, key) do
          :error -> []
          {:ok, value} -> ["#{key}: #{inspect(value)}"]
        end
      end)

    case interesting do
      [] -> "of kind #{inspect(kind)}"
      pairs -> "of kind #{inspect(kind)} (#{Enum.join(pairs, ", ")})"
    end
  end
end
