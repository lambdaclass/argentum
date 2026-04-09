defmodule Arena.Data.CraftingRecipes do
  @moduledoc """
  Hardcoded crafting and gathering recipes matching VB6 AO20 obj.dat IDs.

  Gathering skills produce items from the environment (tile/water).
  Production skills consume ingredients near a workstation NPC.

  Product IDs verified against:
  - ArmasHerrero.dat (26 weapons)
  - ArmadurasHerrero.dat (22 armors/shields/helmets/rings)
  - ObjCarpintero.dat (30 items)
  - ObjSastre.dat (25 items)
  - ObjAlquimista.dat (6 potions)
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
  #
  # Intermediate materials:
  #   192 = Mineral de Hierro,  386 = Lingote de Hierro
  #   193 = Mineral de Plata,   387 = Lingote de Plata
  #   194 = Mineral de Oro,     388 = Lingote de Oro
  #   58  = Leña,              2781 = Leña Élfica
  #   2719 = Listón de Madera, 3742 = Tablones, 3743 = Tablones Élficos
  #   568 = Tela,  473 = Cuero de Lobo,  474 = Cuero de Oso,  886 = Hilo
  #   38  = Flor,  691 = Mandrágora,     529 = Frasco

  def production_recipes(:blacksmithing) do
    [
      # --- Smelting (ore → ingot) ---
      %{min_skill: 0,  result_id: 386, result_amount: 1, ingredients: [{192, 2}]},   # 2x Hierro ore → Lingote Hierro
      %{min_skill: 30, result_id: 387, result_amount: 1, ingredients: [{193, 2}]},   # 2x Plata ore → Lingote Plata
      %{min_skill: 60, result_id: 388, result_amount: 1, ingredients: [{194, 2}]},   # 2x Oro ore → Lingote Oro

      # --- Weapons (ArmasHerrero.dat) ---
      %{min_skill: 4,  result_id: 3980, result_amount: 5, ingredients: [{386, 1}]},                # Bala de piedra x5
      %{min_skill: 8,  result_id: 15,   result_amount: 1, ingredients: [{386, 1}]},                # Daga
      %{min_skill: 10, result_id: 4299, result_amount: 1, ingredients: [{386, 2}]},                # Caja de balas de piedra
      %{min_skill: 14, result_id: 165,  result_amount: 1, ingredients: [{386, 2}]},                # Daga +1
      %{min_skill: 18, result_id: 164,  result_amount: 1, ingredients: [{386, 3}]},                # Espada corta
      %{min_skill: 30, result_id: 365,  result_amount: 1, ingredients: [{386, 3}, {387, 1}]},     # Daga +2
      %{min_skill: 35, result_id: 3175, result_amount: 1, ingredients: [{386, 4}]},                # Trabuco
      %{min_skill: 38, result_id: 3540, result_amount: 5, ingredients: [{386, 2}]},                # Bala de Hierro x5
      %{min_skill: 40, result_id: 2,    result_amount: 1, ingredients: [{386, 4}, {387, 1}]},     # Espada larga
      %{min_skill: 45, result_id: 1792, result_amount: 1, ingredients: [{386, 4}, {387, 2}]},     # Sable
      %{min_skill: 50, result_id: 366,  result_amount: 1, ingredients: [{387, 3}]},                # Daga +3
      %{min_skill: 55, result_id: 1817, result_amount: 1, ingredients: [{386, 5}, {387, 3}]},     # Espada Dos Manos
      %{min_skill: 58, result_id: 401,  result_amount: 1, ingredients: [{386, 6}, {387, 2}]},     # Maza de Dos Manos
      %{min_skill: 60, result_id: 399,  result_amount: 1, ingredients: [{387, 4}]},                # Cimitarra
      %{min_skill: 62, result_id: 159,  result_amount: 1, ingredients: [{386, 5}, {387, 3}]},     # Hacha de Bárbaro
      %{min_skill: 65, result_id: 367,  result_amount: 1, ingredients: [{387, 4}]},                # Daga +4
      %{min_skill: 68, result_id: 123,  result_amount: 1, ingredients: [{387, 4}, {388, 1}]},     # Espada Vikinga
      %{min_skill: 72, result_id: 124,  result_amount: 1, ingredients: [{387, 4}, {388, 2}]},     # Katana
      %{min_skill: 75, result_id: 3805, result_amount: 1, ingredients: [{386, 3}, {387, 2}]},     # Caja de balas de hierro
      %{min_skill: 78, result_id: 1246, result_amount: 1, ingredients: [{387, 5}, {388, 2}]},     # Hacha de Guerra Dos filos
      %{min_skill: 80, result_id: 126,  result_amount: 1, ingredients: [{387, 5}, {388, 3}]},     # Espada de Plata
      %{min_skill: 83, result_id: 3982, result_amount: 1, ingredients: [{387, 3}, {388, 1}]},     # Caja de balas de plata
      %{min_skill: 85, result_id: 2598, result_amount: 1, ingredients: [{388, 3}]},                # Guantes de Lucha
      %{min_skill: 88, result_id: 403,  result_amount: 1, ingredients: [{387, 5}, {388, 4}]},     # Espada de Héroes
      %{min_skill: 90, result_id: 402,  result_amount: 1, ingredients: [{388, 5}]},                # Espada Matadragones
      %{min_skill: 93, result_id: 3988, result_amount: 1, ingredients: [{387, 5}, {388, 5}]},     # Espada Celta

      # --- Armors, Shields, Helmets, Rings (ArmadurasHerrero.dat) ---
      %{min_skill: 15, result_id: 1912, result_amount: 1, ingredients: [{386, 4}]},                # Armadura de Herrero
      %{min_skill: 25, result_id: 1715, result_amount: 1, ingredients: [{386, 3}]},                # Escudo de Hierro
      %{min_skill: 30, result_id: 1079, result_amount: 1, ingredients: [{386, 3}]},                # Casco Vikingo
      %{min_skill: 35, result_id: 132,  result_amount: 1, ingredients: [{386, 4}]},                # Casco de Hierro Completo
      %{min_skill: 40, result_id: 2933, result_amount: 1, ingredients: [{386, 3}, {387, 1}]},     # Escudo de Bronce
      %{min_skill: 45, result_id: 1987, result_amount: 1, ingredients: [{386, 5}, {387, 2}]},     # Armadura de Placas Completas
      %{min_skill: 50, result_id: 243,  result_amount: 1, ingredients: [{386, 5}, {387, 3}]},     # Armadura de Placas Completas (alt)
      %{min_skill: 55, result_id: 1634, result_amount: 1, ingredients: [{387, 4}]},                # Armadura de las Sombras (Bajos)
      %{min_skill: 58, result_id: 1929, result_amount: 1, ingredients: [{387, 5}]},                # Armadura de las Sombras
      %{min_skill: 60, result_id: 1767, result_amount: 1, ingredients: [{387, 3}]},                # Casco de Cazador
      %{min_skill: 62, result_id: 1908, result_amount: 1, ingredients: [{387, 4}]},                # Cota del Gran Cazador (Bajos)
      %{min_skill: 65, result_id: 1907, result_amount: 1, ingredients: [{387, 5}]},                # Cota del Gran Cazador
      %{min_skill: 70, result_id: 1702, result_amount: 1, ingredients: [{387, 4}, {388, 1}]},     # Escudo Imperial
      %{min_skill: 72, result_id: 1941, result_amount: 1, ingredients: [{387, 4}, {388, 2}]},     # Armadura de la Ciénaga
      %{min_skill: 75, result_id: 601,  result_amount: 1, ingredients: [{387, 3}, {388, 2}]},     # Casco de Plata
      %{min_skill: 78, result_id: 500,  result_amount: 1, ingredients: [{387, 4}, {388, 2}]},     # Armadura Bruñida (Bajos)
      %{min_skill: 80, result_id: 495,  result_amount: 1, ingredients: [{387, 5}, {388, 3}]},     # Armadura Escarlata
      %{min_skill: 83, result_id: 487,  result_amount: 1, ingredients: [{387, 5}, {388, 4}]},     # Dama de las Tinieblas
      %{min_skill: 85, result_id: 2323, result_amount: 1, ingredients: [{388, 2}]},                # Anillo de Disolución Mágica
      %{min_skill: 88, result_id: 755,  result_amount: 1, ingredients: [{388, 3}]},                # Anillo del Silencio
      %{min_skill: 90, result_id: 3461, result_amount: 1, ingredients: [{387, 3}, {388, 2}]},     # Hebilla Mochila
      %{min_skill: 95, result_id: 3769, result_amount: 1, ingredients: [{388, 5}]}                 # Relicario
    ]
  end

  def production_recipes(:carpentry) do
    [
      # --- Intermediate: wood → planks ---
      %{min_skill: 0,  result_id: 2719, result_amount: 3, ingredients: [{58, 2}]},                 # 2x Leña → 3x Listón de Madera
      %{min_skill: 40, result_id: 3742, result_amount: 2, ingredients: [{2719, 3}]},               # 3x Listón → 2x Tablones
      %{min_skill: 80, result_id: 3743, result_amount: 2, ingredients: [{2781, 3}]},               # 3x Leña Élfica → 2x Tablones Élficos

      # --- Arrows & Ammunition (ObjCarpintero.dat) ---
      %{min_skill: 3,  result_id: 480,  result_amount: 20, ingredients: [{2719, 1}]},              # Flecha x20
      %{min_skill: 5,  result_id: 163,  result_amount: 1,  ingredients: [{2719, 1}]},              # Cuchara
      %{min_skill: 30, result_id: 3550, result_amount: 20, ingredients: [{2719, 2}]},              # Flecha +1 x20
      %{min_skill: 45, result_id: 551,  result_amount: 20, ingredients: [{2719, 3}, {387, 1}]},   # Flecha +2 x20
      %{min_skill: 60, result_id: 553,  result_amount: 20, ingredients: [{3742, 1}, {388, 1}]},   # Flecha +3 x20
      %{min_skill: 80, result_id: 552,  result_amount: 20, ingredients: [{3743, 1}]},              # Flecha Élfica x20
      %{min_skill: 35, result_id: 3801, result_amount: 1,  ingredients: [{480, 50}]},              # Carcaj de Flechas
      %{min_skill: 45, result_id: 3806, result_amount: 1,  ingredients: [{3550, 50}]},             # Carcaj de Flechas +1
      %{min_skill: 55, result_id: 3802, result_amount: 1,  ingredients: [{551, 50}]},              # Carcaj de Flechas +2
      %{min_skill: 70, result_id: 3804, result_amount: 1,  ingredients: [{553, 50}]},              # Carcaj de Flechas +3
      %{min_skill: 85, result_id: 3803, result_amount: 1,  ingredients: [{552, 50}]},              # Carcaj de Flechas Élficas

      # --- Bows ---
      %{min_skill: 10, result_id: 479,  result_amount: 1, ingredients: [{2719, 3}]},               # Arco Simple
      %{min_skill: 25, result_id: 3466, result_amount: 1, ingredients: [{2719, 4}]},               # Arco Simple Reforzado
      %{min_skill: 40, result_id: 1867, result_amount: 1, ingredients: [{3742, 2}]},               # Arco Compuesto
      %{min_skill: 55, result_id: 1870, result_amount: 1, ingredients: [{3742, 3}]},               # Arco de Roble
      %{min_skill: 75, result_id: 1876, result_amount: 1, ingredients: [{3742, 3}, {3743, 1}]},   # Arco de Cazador

      # --- Instruments ---
      %{min_skill: 15, result_id: 469,  result_amount: 1, ingredients: [{2719, 4}]},               # Laúd
      %{min_skill: 35, result_id: 540,  result_amount: 1, ingredients: [{2719, 3}]},               # Flauta
      %{min_skill: 60, result_id: 41,   result_amount: 1, ingredients: [{3742, 2}, {388, 1}]},    # Laúd Mágico
      %{min_skill: 70, result_id: 40,   result_amount: 1, ingredients: [{3743, 2}]},               # Flauta Élfica

      # --- Staves & Shields ---
      %{min_skill: 20, result_id: 1797, result_amount: 1, ingredients: [{2719, 5}]},               # Bastón Nudoso
      %{min_skill: 50, result_id: 1788, result_amount: 1, ingredients: [{3742, 3}]},               # Báculo Engarzado
      %{min_skill: 25, result_id: 1719, result_amount: 1, ingredients: [{2719, 4}]},               # Rodela
      %{min_skill: 45, result_id: 1724, result_amount: 1, ingredients: [{3742, 2}]},               # Escudo de Roble

      # --- Boats ---
      %{min_skill: 50, result_id: 474,  result_amount: 1, ingredients: [{3742, 5}]},               # Barca
      %{min_skill: 70, result_id: 475,  result_amount: 1, ingredients: [{3742, 8}]},               # Galera
      %{min_skill: 90, result_id: 476,  result_amount: 1, ingredients: [{3742, 5}, {3743, 5}]},   # Galeón

      # --- Misc ---
      %{min_skill: 65, result_id: 2679, result_amount: 1, ingredients: [{3742, 2}]}                # Rueda de carro
    ]
  end

  def production_recipes(:alchemy) do
    [
      # --- Basic potions (existing) ---
      %{min_skill: 0,  result_id: 37,   result_amount: 1, ingredients: [{38, 1}, {529, 1}]},      # Poción HP roja: flor + frasco
      %{min_skill: 30, result_id: 38,   result_amount: 1, ingredients: [{529, 2}, {691, 1}]},     # Poción Mana azul: 2x frasco + mandrágora
      %{min_skill: 50, result_id: 166,  result_amount: 1, ingredients: [{529, 1}, {691, 2}]},     # Poción Envenenar: frasco + 2x mandrágora

      # --- Advanced potions (ObjAlquimista.dat) ---
      %{min_skill: 60, result_id: 891,  result_amount: 1, ingredients: [{529, 2}, {38, 2}, {691, 1}]},   # Pócima de Vida
      %{min_skill: 65, result_id: 894,  result_amount: 1, ingredients: [{529, 2}, {691, 2}]},            # Pócima de Maná
      %{min_skill: 70, result_id: 890,  result_amount: 1, ingredients: [{529, 2}, {38, 1}, {691, 2}]},   # Pócima de Antídoto
      %{min_skill: 75, result_id: 889,  result_amount: 1, ingredients: [{529, 3}, {691, 2}]},            # Pócima de Agilidad
      %{min_skill: 80, result_id: 892,  result_amount: 1, ingredients: [{529, 3}, {691, 3}]},            # Pócima de Fuerza
      %{min_skill: 85, result_id: 1019, result_amount: 1, ingredients: [{529, 3}, {38, 2}, {691, 2}]}    # Pócima de Energía
    ]
  end

  def production_recipes(:tailoring) do
    [
      # --- Basic garments (existing + expanded) ---
      %{min_skill: 0,  result_id: 3578, result_amount: 1, ingredients: [{568, 2}]},                # Tela trabajada
      %{min_skill: 5,  result_id: 32,   result_amount: 1, ingredients: [{568, 3}]},                # Vestimenta Común
      %{min_skill: 10, result_id: 184,  result_amount: 1, ingredients: [{568, 3}]},                # Ropa Común
      %{min_skill: 15, result_id: 240,  result_amount: 1, ingredients: [{568, 4}]},                # Vestimenta de Enano
      %{min_skill: 20, result_id: 261,  result_amount: 1, ingredients: [{568, 4}]},                # Túnica
      %{min_skill: 25, result_id: 1975, result_amount: 1, ingredients: [{568, 4}, {473, 1}]},     # Ropa de Clan
      %{min_skill: 30, result_id: 2911, result_amount: 1, ingredients: [{568, 5}]},                # Ropa de Burgués Turquesa
      %{min_skill: 35, result_id: 508,  result_amount: 1, ingredients: [{568, 4}, {473, 2}]},     # Ropa Estuaria
      %{min_skill: 40, result_id: 196,  result_amount: 1, ingredients: [{568, 5}, {473, 1}]},     # Túnica de Mago
      %{min_skill: 45, result_id: 1226, result_amount: 1, ingredients: [{568, 4}, {473, 2}]},     # Túnica Aventurera (Bajos)
      %{min_skill: 50, result_id: 1955, result_amount: 1, ingredients: [{568, 5}, {473, 2}]},     # Túnica Ocre
      %{min_skill: 55, result_id: 1089, result_amount: 1, ingredients: [{568, 5}, {473, 3}]},     # Túnica de Nigromante
      %{min_skill: 60, result_id: 2857, result_amount: 1, ingredients: [{568, 6}, {473, 2}]},     # Túnica Dorada de Gala
      %{min_skill: 63, result_id: 2932, result_amount: 1, ingredients: [{568, 5}, {473, 3}]},     # Vestido Indulgente Rojo
      %{min_skill: 65, result_id: 2916, result_amount: 1, ingredients: [{568, 6}, {473, 3}]},     # Manto de los Vientos
      %{min_skill: 68, result_id: 1961, result_amount: 1, ingredients: [{568, 5}, {473, 2}, {474, 1}]},  # Túnica Natural Mujer
      %{min_skill: 72, result_id: 2854, result_amount: 1, ingredients: [{568, 6}, {473, 3}, {474, 1}]},  # Sotana de Gran Hechicero
      %{min_skill: 78, result_id: 519,  result_amount: 1, ingredients: [{568, 6}, {473, 4}, {474, 2}]},  # Túnica Legendaria
      %{min_skill: 80, result_id: 1957, result_amount: 1, ingredients: [{568, 6}, {473, 4}, {474, 2}]},  # Túnica Legendaria (E/G)

      # --- Helmets ---
      %{min_skill: 50, result_id: 1778, result_amount: 1, ingredients: [{473, 3}]},                # Casco de Lobo
      %{min_skill: 60, result_id: 1758, result_amount: 1, ingredients: [{473, 4}]},                # Casco de Tigre
      %{min_skill: 70, result_id: 1769, result_amount: 1, ingredients: [{473, 4}, {474, 1}]},     # Capucha de Elite
      %{min_skill: 55, result_id: 992,  result_amount: 1, ingredients: [{568, 4}]},                # Sombrero de Mago
      %{min_skill: 85, result_id: 3990, result_amount: 1, ingredients: [{568, 5}, {473, 3}]},     # Sombrero de Mago Superior

      # --- Misc ---
      %{min_skill: 40, result_id: 3462, result_amount: 1, ingredients: [{473, 3}, {886, 2}]},     # Morral
      %{min_skill: 45, result_id: 3822, result_amount: 1, ingredients: [{473, 2}, {886, 3}]}      # Cuerdas
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
