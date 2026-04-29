defmodule Arena.Test.PlayerFactory do
  @moduledoc """
  Canonical `%AoEntities.PlayerEntity{}` factory for tests. Returns a
  real struct (not a plain map), so missing-key bugs raise. Replaces the
  ad-hoc `make_entity` / `make_player` helpers scattered across 50+
  test files (those will be migrated in slice 6).
  """

  alias AoEntities.PlayerEntity

  @doc """
  Build a `%PlayerEntity{}` from the struct's defaults plus `overrides`.
  Override keys MUST exist on the struct — `Map.replace!/3` raises
  otherwise.
  """
  @spec player(keyword()) :: PlayerEntity.t()
  def player(overrides \\ []) do
    base = %PlayerEntity{
      char_id: Keyword.get(overrides, :char_id, :p1),
      char_index: Keyword.get(overrides, :char_index, 1),
      name: "Tester",
      account_id: "acc_test",
      x: 50,
      y: 50,
      heading: :south,
      next_move_at: -1_000_000_000_000,
      next_attack_at: -1_000_000_000_000,
      next_spell_at: -1_000_000_000_000,
      next_item_use_at: -1_000_000_000_000
    }

    overrides
    |> Keyword.drop([:char_id, :char_index])
    |> Enum.reduce(base, fn {k, v}, acc -> Map.replace!(acc, k, v) end)
  end
end
