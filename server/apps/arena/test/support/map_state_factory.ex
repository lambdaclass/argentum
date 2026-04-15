defmodule Arena.Test.MapStateFactory do
  @moduledoc """
  Builds `%Arena.Map.State{}` structs for tests.

  Replaces raw maps that tests were building by hand — every state
  produced here has all struct fields with sane defaults, so handlers
  that access tick counters, gm_blocked_tiles, triggers, etc. never
  hit a missing-key error.
  """

  alias Arena.Map.State

  @doc """
  Returns a `%Arena.Map.State{}` with sensible defaults.

  Pass keyword overrides for any field.  The `:occupancy` key accepts
  either a raw `:array` value or a map of `%{{x, y} => value}` that
  gets merged into a 100×100 nil-initialized array.

      map_state(players: %{1 => entity}, meta: %{safe_zone: true})
  """
  def map_state(overrides \\ []) do
    occupancy =
      case Keyword.get(overrides, :occupancy) do
        nil ->
          :array.new(100 * 100, default: nil)

        %{} = occ_map ->
          Enum.reduce(occ_map, :array.new(100 * 100, default: nil), fn {{x, y}, value}, acc ->
            :array.set((y - 1) * 100 + (x - 1), value, acc)
          end)

        raw ->
          raw
      end

    overrides = Keyword.put(overrides, :occupancy, occupancy)

    struct!(State, Keyword.put_new(overrides, :map_id, 1))
  end
end
