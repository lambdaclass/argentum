defmodule Arena.Data.CraftingRecipes do
  @moduledoc """
  Hardcoded crafting and gathering recipes matching VB6 AO20 obj.dat IDs.

  Gathering skills produce items from the environment (tile/water).
  Production skills consume ingredients near a workstation NPC.
  """

  # ---- Gathering recipes: {min_skill, item_id} ----
  # Player gets the highest-tier product they qualify for.

  def gathering_products(:mining) do
    [
      {0, 192},    # Mineral de Hierro
      {30, 193},   # Mineral de Plata
      {60, 194},   # Mineral de Oro
      {85, 3787}   # Mineral de Blodium
    ]
  end

  def gathering_products(:fishing) do
    [
      {0, 2150},   # Pez Chum
      {20, 2093},  # Bagre de Mar
      {40, 2094},  # Pez Roca
      {60, 2101},  # Salmón
      {80, 2091}   # Pez Raro
    ]
  end

  def gathering_products(:woodcutting) do
    [
      {0, 58},     # Leña
      {80, 2781}   # Leña Élfica
    ]
  end

  def gathering_products(_), do: []

  @doc "Select the best product for a given skill level."
  def select_product(skill_atom, skill_value) do
    products = gathering_products(skill_atom)

    products
    |> Enum.filter(fn {min_skill, _} -> skill_value >= min_skill end)
    |> Enum.max_by(fn {min_skill, _} -> min_skill end, fn -> nil end)
    |> case do
      {_, item_id} -> item_id
      nil -> nil
    end
  end

  # ---- Production recipes: require ingredients ----
  # %{min_skill, result_id, result_amount, ingredients: [{item_id, amount}]}

  def production_recipes(:blacksmithing) do
    [
      %{min_skill: 0,  result_id: 386, result_amount: 1, ingredients: [{192, 2}]},  # 2x Hierro → Lingote de Hierro
      %{min_skill: 30, result_id: 387, result_amount: 1, ingredients: [{193, 2}]},  # 2x Plata → Lingote de Plata
      %{min_skill: 60, result_id: 388, result_amount: 1, ingredients: [{194, 2}]}   # 2x Oro → Lingote de Oro
    ]
  end

  def production_recipes(:carpentry) do
    [
      %{min_skill: 0, result_id: 2719, result_amount: 3, ingredients: [{58, 2}]}    # 2x Leña → 3x Liston de madera
    ]
  end

  def production_recipes(_), do: []

  @doc "Find the best recipe the player can craft with current skill and inventory."
  def find_craftable(skill_atom, skill_value, inventory) do
    production_recipes(skill_atom)
    |> Enum.filter(fn recipe -> skill_value >= recipe.min_skill end)
    |> Enum.filter(fn recipe -> has_ingredients?(inventory, recipe.ingredients) end)
    |> Enum.max_by(fn recipe -> recipe.min_skill end, fn -> nil end)
  end

  defp has_ingredients?(inventory, ingredients) do
    Enum.all?(ingredients, fn {item_id, amount} ->
      count_item(inventory, item_id) >= amount
    end)
  end

  defp count_item(inventory, item_id) do
    inventory
    |> Enum.filter(& &1)
    |> Enum.filter(fn slot -> slot.item_id == item_id end)
    |> Enum.map(& &1.amount)
    |> Enum.sum()
  end
end
