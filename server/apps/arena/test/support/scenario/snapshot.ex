defmodule Arena.Test.Scenario.Snapshot do
  @moduledoc """
  Stable serializers and structured diff helpers for the deterministic
  scenario harness.

  When a parity assertion fails, dumping the entire `%Arena.Map.State{}`
  produces an unreadable wall of struct output. The serializers in this
  module project the load-bearing subset of an entity (vitals, flags,
  inventory, buffs, visibility window) into plain Elixir terms that
  diff cleanly and can be embedded in tests as expected literals.

  The "stable" contract: the same scenario state produces the same
  snapshot every run. Ephemeral fields (`next_*_at` cooldowns,
  `last_*_at` monotonic timestamps) are dropped. Effect payloads are
  reduced to a `{class, packet_id, payload_size}` summary because raw
  binaries don't diff usefully.

  Public entry points are re-exported from `Arena.Test.Scenario`:
  prefer `Scenario.snapshot/2,3`, `Scenario.diff_snapshots/2`,
  `Scenario.format_diff/1`, and `Scenario.assert_state_equal/2,3` in
  tests.
  """

  alias Arena.Map.{Helpers, State}
  alias Arena.Test.Scenario

  # ──────────────────────────────────────────────────────────────────────
  # Snapshot keys
  # ──────────────────────────────────────────────────────────────────────

  @player_fields ~w(
    x y hp max_hp mana max_mana stamina max_stamina gold
    hunger thirst level xp
    dead paralyzed blind dumb poisoned invisible oculto criminal
    faction class race gender heading
  )a

  @doc """
  Build a snapshot of the given `key`. `:effects` takes no extra arg.
  Entity-keyed snapshots (`:player`, `:inventory`, `:buffs`, `:visible`)
  take a `char_id`.
  """
  @spec take(Scenario.t(), atom(), term()) :: term()
  def take(scenario, key, target \\ nil)

  def take(%Scenario{state: state}, :player, char_id) do
    case Map.get(state.players, char_id) do
      nil ->
        nil

      entity ->
        @player_fields
        |> Enum.map(fn k -> {k, Map.get(entity, k)} end)
        |> Enum.into(%{})
    end
  end

  def take(%Scenario{state: state}, :inventory, char_id) do
    case Map.get(state.players, char_id) do
      nil ->
        []

      entity ->
        entity
        |> Map.get(:inventory, [])
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {nil, _idx} ->
            []

          {%{} = item, idx} ->
            [
              %{
                slot: idx,
                item_id: Map.get(item, :item_id),
                amount: Map.get(item, :amount),
                equipped: Map.get(item, :equipped, false)
              }
            ]
        end)
    end
  end

  def take(%Scenario{state: state}, :buffs, char_id) do
    case Map.get(state.players, char_id) do
      nil ->
        []

      entity ->
        entity
        |> Map.get(:buffs, [])
        |> Enum.map(&normalize_buff/1)
        |> Enum.sort_by(&{Map.get(&1, :type) |> inspect(), Map.get(&1, :expires_at, 0)})
    end
  end

  def take(%Scenario{state: state}, :visible, char_id) do
    case Map.get(state.players, char_id) do
      nil -> []
      entity -> visible_entries(state, entity)
    end
  end

  def take(%Scenario{effects: effects}, :effects, _ignored) do
    Enum.map(effects, &normalize_effect/1)
  end

  # ──────────────────────────────────────────────────────────────────────
  # Diff
  # ──────────────────────────────────────────────────────────────────────

  @typedoc """
  A path of keys/indices pointing at the first divergence between two
  snapshots. Empty list means the divergence is at the root (e.g. two
  different leaf values).
  """
  @type diff_path :: [term()]

  @doc """
  Walk `actual` and `expected` in parallel, returning either `:ok` or
  `{:divergence, path, actual_v, expected_v}` where `path` is the
  sequence of keys/indices leading to the first mismatch.

  Maps are compared on the union of keys: a key on either side that
  is absent from the other surfaces as a `:__missing__` sentinel.
  Lists are compared positionally; a length mismatch surfaces at the
  first missing/extra index. Tuples are treated like positional
  lists (with the tag at index 0).

  This is intentionally narrow: it is not a deep semantic differ. It
  serves a single use case — point the tester at the first
  parity-breaking field without re-implementing `ExUnit`'s structural
  diff.

  `mode: :subset` relaxes the map rule so that keys present in
  `actual` but not in `expected` are ignored — useful for partial
  assertions where the test only specifies the fields it cares about.
  Lists and tuples are unaffected: their length must still match.
  """
  @spec diff(term(), term()) ::
          :ok | {:divergence, diff_path(), term(), term()}
  def diff(actual, expected), do: do_diff(actual, expected, [], :strict)

  @spec diff(term(), term(), keyword()) ::
          :ok | {:divergence, diff_path(), term(), term()}
  def diff(actual, expected, opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :strict)
    do_diff(actual, expected, [], mode)
  end

  defp do_diff(same, same, _path, _mode), do: :ok

  defp do_diff(%{} = a, %{} = b, path, mode) when not is_struct(a) and not is_struct(b) do
    keys =
      case mode do
        :subset -> Map.keys(b)
        _ -> Map.keys(a) ++ Map.keys(b)
      end
      |> Enum.uniq()
      # Stable order so the first surfaced divergence is deterministic.
      |> Enum.sort_by(&inspect/1)

    Enum.reduce_while(keys, :ok, fn key, _acc ->
      case {Map.fetch(a, key), Map.fetch(b, key)} do
        {{:ok, av}, {:ok, bv}} ->
          case do_diff(av, bv, path ++ [key], mode) do
            :ok -> {:cont, :ok}
            divergence -> {:halt, divergence}
          end

        {{:ok, av}, :error} ->
          {:halt, {:divergence, path ++ [key], av, :__missing__}}

        {:error, {:ok, bv}} ->
          {:halt, {:divergence, path ++ [key], :__missing__, bv}}
      end
    end)
  end

  defp do_diff(a, b, path, mode) when is_list(a) and is_list(b) do
    diff_indexed(a, b, 0, path, mode)
  end

  defp do_diff(a, b, path, mode) when is_tuple(a) and is_tuple(b) do
    diff_indexed(Tuple.to_list(a), Tuple.to_list(b), 0, path, mode)
  end

  defp do_diff(a, b, path, _mode), do: {:divergence, path, a, b}

  defp diff_indexed([], [], _idx, _path, _mode), do: :ok

  defp diff_indexed([], [bh | _], idx, path, _mode),
    do: {:divergence, path ++ [idx], :__missing__, bh}

  defp diff_indexed([ah | _], [], idx, path, _mode),
    do: {:divergence, path ++ [idx], ah, :__missing__}

  defp diff_indexed([ah | at], [bh | bt], idx, path, mode) do
    case do_diff(ah, bh, path ++ [idx], mode) do
      :ok -> diff_indexed(at, bt, idx + 1, path, mode)
      divergence -> divergence
    end
  end

  @doc """
  Format a `:divergence` result into a single human-readable line.
  Returns the empty string for `:ok` (caller decides what to do with
  that, but `format_diff(:ok)` is safe to splice into messages).
  """
  @spec format(:ok | {:divergence, diff_path(), term(), term()}) :: String.t()
  def format(:ok), do: ""

  def format({:divergence, path, actual, expected}) do
    "snapshot divergence at #{format_path(path)}: actual=#{inspect(actual, pretty: true, limit: :infinity)} expected=#{inspect(expected, pretty: true, limit: :infinity)}"
  end

  defp format_path([]), do: "<root>"

  defp format_path(path) do
    path
    |> Enum.map(&inspect/1)
    |> Enum.join(" -> ")
  end

  # ──────────────────────────────────────────────────────────────────────
  # assert_state_equal
  # ──────────────────────────────────────────────────────────────────────

  @doc """
  Compare `expected` (a plain map keyed by snapshot kind) against
  fresh snapshots taken from `scenario`. The top-level keys of
  `expected` decide which snapshot to take:

      %{
        player: %{...}                              # take(:player, char_id)
        inventory: [...]                            # take(:inventory, char_id)
        buffs: [...]                                # take(:buffs, char_id)
        visible: [...]                              # take(:visible, char_id)
        effects: [...]                              # take(:effects)
      }

  Entity-scoped snapshots need a `char_id` — pass it as the third
  argument. (`:effects` ignores it.) Raises an `ExUnit.AssertionError`
  on the first divergence, with the formatted path.
  """
  @spec assert_equal(Scenario.t(), map(), term()) :: Scenario.t() | no_return()
  def assert_equal(scenario, expected, char_id \\ nil)

  def assert_equal(%Scenario{} = scenario, expected, char_id) when is_map(expected) do
    Enum.each(expected, fn {key, expected_value} ->
      actual = take(scenario, key, char_id)

      # Subset mode: tests typically specify only the fields they
      # care about (e.g. `%{hp: 50}` against a 60+ field player
      # snapshot). Lists and tuples still demand exact length match.
      case diff(actual, expected_value, mode: :subset) do
        :ok ->
          :ok

        {:divergence, _, _, _} = d ->
          full_path = [key | divergence_path(d)]
          raise ExUnit.AssertionError, message: format_top(full_path, d, scenario)
      end
    end)

    scenario
  end

  defp divergence_path({:divergence, path, _, _}), do: path

  defp format_top(full_path, {:divergence, _, av, ev}, _scenario) do
    "Scenario.assert_state_equal failed at #{format_path(full_path)}\n" <>
      "  actual:   #{inspect(av, pretty: true, limit: :infinity)}\n" <>
      "  expected: #{inspect(ev, pretty: true, limit: :infinity)}"
  end

  # ──────────────────────────────────────────────────────────────────────
  # Internal: buff / effect / visibility normalisation
  # ──────────────────────────────────────────────────────────────────────

  # Keep `:type` and `:expires_at` (always), plus `:value` if present.
  # Drop other fields (e.g. `:next_tick` on poison) — they shift
  # mid-flow and aren't load-bearing for parity tests.
  defp normalize_buff(%{} = buff) do
    base = %{type: Map.get(buff, :type), expires_at: Map.get(buff, :expires_at)}
    case Map.fetch(buff, :value) do
      {:ok, v} -> Map.put(base, :value, v)
      :error -> base
    end
  end

  # Envelope-bearing kinds: replace the binary payload with a stable
  # `{class, packet_id, payload_size}` summary so diffs surface the
  # interesting bit (which packet was sent) without dumping raw bytes.
  defp normalize_effect({:send, to, envelope}) do
    {:send, to, summarize_envelope(envelope)}
  end

  defp normalize_effect({:broadcast_visible, x, y, envelope}) do
    {:broadcast_visible, x, y, summarize_envelope(envelope)}
  end

  defp normalize_effect({:broadcast_visible_all, x, y, envelope}) do
    {:broadcast_visible_all, x, y, summarize_envelope(envelope)}
  end

  defp normalize_effect({:broadcast_visible_except, x, y, exclude, envelope}) do
    {:broadcast_visible_except, x, y, exclude, summarize_envelope(envelope)}
  end

  defp normalize_effect({:broadcast_visible_gm_only, x, y, exclude, envelope}) do
    {:broadcast_visible_gm_only, x, y, exclude, summarize_envelope(envelope)}
  end

  defp normalize_effect({:broadcast_map, envelope}) do
    {:broadcast_map, summarize_envelope(envelope)}
  end

  defp normalize_effect({:broadcast_character_change, entity}) do
    {:broadcast_character_change, Map.get(entity, :char_id)}
  end

  defp normalize_effect({:hide_from_non_gm, entity}) do
    {:hide_from_non_gm, Map.get(entity, :char_id)}
  end

  defp normalize_effect({:reveal_to_non_gm, entity}) do
    {:reveal_to_non_gm, Map.get(entity, :char_id)}
  end

  defp normalize_effect({:transfer, char_id, dest_map, dest_x, dest_y, _entity}) do
    {:transfer, char_id, dest_map, dest_x, dest_y}
  end

  defp normalize_effect(other), do: other

  defp summarize_envelope(%{payload: <<id::little-signed-integer-16, _::binary>>} = env) do
    %{
      class: Map.get(env, :class),
      packet_id: id,
      payload_size: Map.get(env, :bytes, byte_size(env.payload))
    }
  end

  defp summarize_envelope(%{payload: payload} = env) when is_binary(payload) do
    %{
      class: Map.get(env, :class),
      packet_id: nil,
      payload_size: Map.get(env, :bytes, byte_size(payload))
    }
  end

  defp summarize_envelope(other) do
    # Unrecognised envelope shape: keep it visible to the diff so the
    # mismatch surfaces explicitly rather than getting silently
    # collapsed.
    %{class: nil, packet_id: nil, payload_size: nil, raw: other}
  end

  # AoI window around the player's tile. Sorted by `{kind, key}` so
  # the output is deterministic regardless of map traversal order.
  defp visible_entries(%State{} = state, entity) do
    rx = Helpers.aoi_range_x()
    ry = Helpers.aoi_range_y()
    {x, y} = {entity.x, entity.y}
    self_char_id = Map.get(entity, :char_id)

    players =
      for {cid, p} <- state.players,
          cid != self_char_id,
          in_box?(p.x, p.y, x, y, rx, ry) do
        {:player, cid}
      end

    npcs =
      for {iid, npc} <- state.npcs_live,
          in_box?(npc.x, npc.y, x, y, rx, ry) do
        {:npc, iid}
      end

    ground =
      for {{gx, gy}, _item} <- state.ground_items,
          in_box?(gx, gy, x, y, rx, ry) do
        {:ground_item, {gx, gy}}
      end

    (players ++ npcs ++ ground)
    |> Enum.sort_by(fn
      {kind, key} -> {Atom.to_string(kind), inspect(key)}
    end)
  end

  defp in_box?(ex, ey, cx, cy, rx, ry) do
    abs(ex - cx) <= rx and abs(ey - cy) <= ry
  end
end
