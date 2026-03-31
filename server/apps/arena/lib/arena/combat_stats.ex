defmodule Arena.CombatStats do
  @moduledoc """
  Computes effective combat stats from base attributes + equipped items.
  Pure functions, no side effects.
  """

  alias Arena.Data.GameData

  @doc """
  Compute effective defense from equipment.
  Returns {min_def, max_def} summing armor, shield, and helmet.
  """
  def effective_defense(equipment) do
    [:armor, :shield, :helmet]
    |> Enum.reduce({0, 0}, fn slot, {min_acc, max_acc} ->
      case Map.get(equipment, slot) do
        nil ->
          {min_acc, max_acc}

        item_id ->
          case GameData.get_item(item_id) do
            nil -> {min_acc, max_acc}
            item_def -> {min_acc + item_def.min_def, max_acc + item_def.max_def}
          end
      end
    end)
  end

  @doc """
  Compute effective weapon damage.
  Returns {min_hit, max_hit} from equipped weapon, or {1, 1} for unarmed.
  """
  def effective_damage(equipment) do
    case Map.get(equipment, :weapon) do
      nil ->
        {1, 1}

      item_id ->
        case GameData.get_item(item_id) do
          nil -> {1, 1}
          item_def -> {max(item_def.min_hit, 1), max(item_def.max_hit, 1)}
        end
    end
  end
end
