defmodule Arena.Data.CraftingRecipes do
  @moduledoc """
  Hardcoded crafting and gathering recipes matching VB6 AO20 obj.dat IDs.

  Gathering skills produce items from the environment (tile/water).
  Production skills consume ingredients once the corresponding tool/object
  trigger has opened the crafting form.

  All product IDs, skill requirements, and ingredient amounts are sourced
  directly from the VB6 obj.dat fields (SkHerreria, LingH/LingP/LingO,
  SkCarpinteria, Madera/MaderaElfica, SkSastreria, PielLobo/PielOsoPardo/
  PielOsoPolar/PielLoboNegro/PielTigreBengala, SkPociones, Mortero/
  FrascoAlq/FlorRoja/FlorOceano/HongoDeLuz/ColaDeZorro/Tuna).

  Recipe lists verified against:
  - ArmasHerrero.dat (26 weapons)
  - ArmadurasHerrero.dat (22 armors/shields/helmets/rings)
  - ObjCarpintero.dat (30 items)
  - ObjSastre.dat (25 items)
  - ObjAlquimista.dat (6 potions)
  """

  # ---- Material item IDs (from VB6 Declares.bas) ----
  # Blacksmithing minerals
  @hierro_crudo 192
  @plata_cruda 193
  @oro_crudo 194
  @lingote_hierro 386
  @lingote_plata 387
  @lingote_oro 388
  @coal 3391

  # Carpentry wood
  @wood 58
  @elven_wood 2781
  # @pino_wood 3788  # Reserved — no current recipes use pine

  # Tailoring pelts
  @piel_lobo 414
  @piel_oso_pardo 415
  @piel_oso_polar 416
  @piel_lobo_negro 1146
  @piel_tigre_bengala 1145

  # Alchemy reagents
  @mortero 4997
  @frasco_alq 3075
  @flor_roja 4316
  @flor_oceano 4315
  @hongo_de_luz 4310
  @cola_de_zorro 4314
  @tuna 4312

  # ---- Gathering recipes: {min_skill, item_id} ----
  # Player gets the highest-tier product they qualify for.

  def gathering_products(:mining) do
    [
      # Mineral de Hierro
      {0, @hierro_crudo},
      # Mineral de Plata
      {30, @plata_cruda},
      # Mineral de Oro
      {60, @oro_crudo},
      # Mineral de Blodium
      {85, 3787}
    ]
  end

  def gathering_products(:fishing) do
    [
      # Pez Chum
      {0, 2150},
      # Bagre de Mar
      {20, 2093},
      # Pez Roca
      {40, 2094},
      # Salmón
      {60, 2101},
      # Pez Raro
      {80, 2091}
    ]
  end

  def gathering_products(:woodcutting) do
    [
      # Leña
      {0, @wood},
      # Leña Élfica
      {80, @elven_wood}
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
  # All skill requirements and ingredient amounts match VB6 obj.dat exactly.
  # Ingredients reference the real item IDs from Declares.bas e_Minerales,
  # Wood/ElvenWood, PieldeLobo/PieldeOsoPardo/PieldeOsoPolar/PielLoboNegro/
  # PielTigreBengala, Mortero/FrascoAlq/etc.

  def production_recipes(:blacksmithing) do
    [
      # --- Smelting (ore → ingot) ---
      # 2x Hierro ore → Lingote Hierro
      %{min_skill: 0, result_id: @lingote_hierro, result_amount: 1, ingredients: [{@hierro_crudo, 2}]},
      # 2x Plata ore → Lingote Plata
      %{min_skill: 30, result_id: @lingote_plata, result_amount: 1, ingredients: [{@plata_cruda, 2}]},
      # 2x Oro ore → Lingote Oro
      %{min_skill: 60, result_id: @lingote_oro, result_amount: 1, ingredients: [{@oro_crudo, 2}]},

      # --- Weapons (ArmasHerrero.dat, VB6 obj.dat fields) ---
      # Bala de piedra — Coal=1
      %{min_skill: 0, result_id: 3980, result_amount: 1, ingredients: [{@coal, 1}]},
      # Daga — LingH=3
      %{min_skill: 0, result_id: 15, result_amount: 1, ingredients: [{@lingote_hierro, 3}]},
      # Caja de balas de piedra — Coal=1000
      %{min_skill: 10, result_id: 4299, result_amount: 1, ingredients: [{@coal, 1000}]},
      # Bala de Hierro — LingH=1
      %{min_skill: 5, result_id: 3540, result_amount: 1, ingredients: [{@lingote_hierro, 1}]},
      # Daga +1 — LingH=10
      %{min_skill: 15, result_id: 165, result_amount: 1, ingredients: [{@lingote_hierro, 10}]},
      # Espada corta — LingH=50
      %{min_skill: 25, result_id: 164, result_amount: 1, ingredients: [{@lingote_hierro, 50}]},
      # Espada larga — LingH=20
      %{min_skill: 25, result_id: 2, result_amount: 1, ingredients: [{@lingote_hierro, 20}]},
      # Sable — LingH=30
      %{min_skill: 30, result_id: 1792, result_amount: 1, ingredients: [{@lingote_hierro, 30}]},
      # Espada Celta — LingH=80
      %{min_skill: 30, result_id: 3988, result_amount: 1, ingredients: [{@lingote_hierro, 80}]},
      # Maza de Guerra — LingH=40
      %{min_skill: 30, result_id: 401, result_amount: 1, ingredients: [{@lingote_hierro, 40}]},
      # Daga +2 — LingH=50
      %{min_skill: 35, result_id: 365, result_amount: 1, ingredients: [{@lingote_hierro, 50}]},
      # Mandoble (Espada Dos Manos) — LingH=35
      %{min_skill: 35, result_id: 1817, result_amount: 1, ingredients: [{@lingote_hierro, 35}]},
      # Caja de balas de hierro — LingH=100
      %{min_skill: 35, result_id: 3805, result_amount: 1, ingredients: [{@lingote_hierro, 100}]},
      # Cimitarra — LingH=100
      %{min_skill: 55, result_id: 399, result_amount: 1, ingredients: [{@lingote_hierro, 100}]},
      # Daga +3 — LingH=100
      %{min_skill: 60, result_id: 366, result_amount: 1, ingredients: [{@lingote_hierro, 100}]},
      # Hacha de Bárbaro — LingH=55
      %{min_skill: 70, result_id: 159, result_amount: 1, ingredients: [{@lingote_hierro, 55}]},
      # Espada Vikinga — LingH=50
      %{min_skill: 70, result_id: 123, result_amount: 1, ingredients: [{@lingote_hierro, 50}]},
      # Trabuco — LingH=75, LingP=50
      %{
        min_skill: 75,
        result_id: 3175,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 75}, {@lingote_plata, 50}]
      },
      # Katana — LingH=90
      %{min_skill: 75, result_id: 124, result_amount: 1, ingredients: [{@lingote_hierro, 90}]},
      # Hacha de Guerra Dos filos — LingH=105
      %{min_skill: 80, result_id: 1246, result_amount: 1, ingredients: [{@lingote_hierro, 105}]},
      # Guantes de Lucha — LingH=105
      %{min_skill: 80, result_id: 2598, result_amount: 1, ingredients: [{@lingote_hierro, 105}]},
      # Caja de balas de plata — LingP=100
      %{min_skill: 80, result_id: 3982, result_amount: 1, ingredients: [{@lingote_plata, 100}]},
      # Espada de Plata — LingP=105
      %{min_skill: 90, result_id: 126, result_amount: 1, ingredients: [{@lingote_plata, 105}]},
      # Daga +4 — LingH=100, LingP=100
      %{
        min_skill: 100,
        result_id: 367,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 100}, {@lingote_plata, 100}]
      },
      # Espada de Héroes — LingH=85, LingP=210
      %{
        min_skill: 100,
        result_id: 403,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 85}, {@lingote_plata, 210}]
      },
      # Espada Matadragones — LingH=500, LingP=400, LingO=300
      %{
        min_skill: 100,
        result_id: 402,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 500}, {@lingote_plata, 400}, {@lingote_oro, 300}]
      },

      # --- Armors, Shields, Helmets, Rings (ArmadurasHerrero.dat) ---
      # Escudo de Hierro — LingH=30
      %{min_skill: 55, result_id: 1715, result_amount: 1, ingredients: [{@lingote_hierro, 30}]},
      # Armadura de Herrero — LingH=75
      %{min_skill: 58, result_id: 1912, result_amount: 1, ingredients: [{@lingote_hierro, 75}]},
      # Casco Vikingo — LingH=70
      %{min_skill: 60, result_id: 1079, result_amount: 1, ingredients: [{@lingote_hierro, 70}]},
      # Casco de Hierro Completo — LingH=105
      %{min_skill: 65, result_id: 132, result_amount: 1, ingredients: [{@lingote_hierro, 105}]},
      # Escudo de Bronce — LingH=70, LingP=15
      %{
        min_skill: 75,
        result_id: 2933,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 70}, {@lingote_plata, 15}]
      },
      # Anillo de Disolución Mágica — LingP=75
      %{min_skill: 75, result_id: 2323, result_amount: 1, ingredients: [{@lingote_plata, 75}]},
      # Casco de Cazador — LingH=105
      %{min_skill: 75, result_id: 1767, result_amount: 1, ingredients: [{@lingote_hierro, 105}]},
      # Casco de Plata — LingH=180, LingP=210, LingO=60
      %{
        min_skill: 75,
        result_id: 601,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 180}, {@lingote_plata, 210}, {@lingote_oro, 60}]
      },
      # Armadura de Placas Completas (1987) — LingH=210
      %{min_skill: 76, result_id: 1987, result_amount: 1, ingredients: [{@lingote_hierro, 210}]},
      # Armadura de Placas Completas (243) — LingH=210
      %{min_skill: 76, result_id: 243, result_amount: 1, ingredients: [{@lingote_hierro, 210}]},
      # Escudo Imperial — LingP=100
      %{min_skill: 90, result_id: 1702, result_amount: 1, ingredients: [{@lingote_plata, 100}]},
      # Armadura de las Sombras (Bajos) — LingH=300, LingP=200, LingO=30
      %{
        min_skill: 100,
        result_id: 1634,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 300}, {@lingote_plata, 200}, {@lingote_oro, 30}]
      },
      # Armadura de las Sombras — LingH=300, LingP=200, LingO=30
      %{
        min_skill: 100,
        result_id: 1929,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 300}, {@lingote_plata, 200}, {@lingote_oro, 30}]
      },
      # Cota del Gran Cazador (Bajos) — LingH=350, LingP=250, LingO=50
      %{
        min_skill: 100,
        result_id: 1908,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 350}, {@lingote_plata, 250}, {@lingote_oro, 50}]
      },
      # Cota del Gran Cazador — LingH=350, LingP=250, LingO=50
      %{
        min_skill: 100,
        result_id: 1907,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 350}, {@lingote_plata, 250}, {@lingote_oro, 50}]
      },
      # Armadura de la Ciénaga — LingH=550, LingP=350, LingO=150
      %{
        min_skill: 100,
        result_id: 1941,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 550}, {@lingote_plata, 350}, {@lingote_oro, 150}]
      },
      # Armadura Escarlata — LingH=550, LingP=350, LingO=150
      %{
        min_skill: 100,
        result_id: 495,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 550}, {@lingote_plata, 350}, {@lingote_oro, 150}]
      },
      # Dama de las Tinieblas — LingH=550, LingP=350, LingO=150
      %{
        min_skill: 100,
        result_id: 487,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 550}, {@lingote_plata, 350}, {@lingote_oro, 150}]
      },
      # Armadura Bruñida (Bajos) — LingH=550, LingP=350, LingO=150
      %{
        min_skill: 100,
        result_id: 500,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 550}, {@lingote_plata, 350}, {@lingote_oro, 150}]
      },
      # Anillo del Silencio — LingH=45, LingP=30, LingO=15
      %{
        min_skill: 100,
        result_id: 755,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 45}, {@lingote_plata, 30}, {@lingote_oro, 15}]
      },
      # Hebilla Mochila — LingH=500, LingP=400, LingO=300
      %{
        min_skill: 100,
        result_id: 3461,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 500}, {@lingote_plata, 400}, {@lingote_oro, 300}]
      },
      # Relicario — LingH=5, LingP=5
      %{
        min_skill: 100,
        result_id: 3769,
        result_amount: 1,
        ingredients: [{@lingote_hierro, 5}, {@lingote_plata, 5}]
      }
    ]
  end

  def production_recipes(:carpentry) do
    [
      # --- ObjCarpintero.dat items (VB6 obj.dat Madera/MaderaElfica fields) ---
      # Cuchara — Madera=3
      %{min_skill: 0, result_id: 163, result_amount: 1, ingredients: [{@wood, 3}]},
      # Flecha — Madera=1
      %{min_skill: 5, result_id: 480, result_amount: 1, ingredients: [{@wood, 1}]},
      # Arco Simple — Madera=200
      %{min_skill: 10, result_id: 479, result_amount: 1, ingredients: [{@wood, 200}]},
      # Arco Simple Reforzado — Madera=500
      %{min_skill: 25, result_id: 3466, result_amount: 1, ingredients: [{@wood, 500}]},
      # Tablones — Madera=9
      %{min_skill: 37, result_id: 3742, result_amount: 1, ingredients: [{@wood, 9}]},
      # Rueda de carro — Madera=100
      %{min_skill: 37, result_id: 2679, result_amount: 1, ingredients: [{@wood, 100}]},
      # Flecha +1 — Madera=2
      %{min_skill: 45, result_id: 3550, result_amount: 1, ingredients: [{@wood, 2}]},
      # Bastón Nudoso — Madera=1200
      %{min_skill: 60, result_id: 1797, result_amount: 1, ingredients: [{@wood, 1200}]},
      # Arco Compuesto — Madera=900
      %{min_skill: 63, result_id: 1867, result_amount: 1, ingredients: [{@wood, 900}]},
      # Flecha +2 — Madera=3
      %{min_skill: 63, result_id: 551, result_amount: 1, ingredients: [{@wood, 3}]},
      # Rodela — Madera=200
      %{min_skill: 63, result_id: 1719, result_amount: 1, ingredients: [{@wood, 200}]},
      # Arco de Roble — Madera=2000
      %{min_skill: 70, result_id: 1870, result_amount: 1, ingredients: [{@wood, 2000}]},
      # Barca — Madera=25000
      %{min_skill: 75, result_id: 474, result_amount: 1, ingredients: [{@wood, 25000}]},
      # Laúd Mágico — Madera=800
      %{min_skill: 75, result_id: 469, result_amount: 1, ingredients: [{@wood, 800}]},
      # Flauta Mágica — Madera=1200
      %{min_skill: 75, result_id: 540, result_amount: 1, ingredients: [{@wood, 1200}]},
      # Escudo de Roble — Madera=4200
      %{min_skill: 75, result_id: 1724, result_amount: 1, ingredients: [{@wood, 4200}]},
      # Tablones Élficos — MaderaElfica=9
      %{min_skill: 75, result_id: 3743, result_amount: 1, ingredients: [{@elven_wood, 9}]},
      # Flecha +3 — Madera=6
      %{min_skill: 75, result_id: 553, result_amount: 1, ingredients: [{@wood, 6}]},
      # Arco de Cazador — MaderaElfica=1000
      %{min_skill: 100, result_id: 1876, result_amount: 1, ingredients: [{@elven_wood, 1000}]},
      # Flecha Élfica — MaderaElfica=3
      %{min_skill: 100, result_id: 552, result_amount: 1, ingredients: [{@elven_wood, 3}]},
      # Laúd Élfico — MaderaElfica=600
      %{min_skill: 100, result_id: 41, result_amount: 1, ingredients: [{@elven_wood, 600}]},
      # Flauta Élfica — MaderaElfica=900
      %{min_skill: 100, result_id: 40, result_amount: 1, ingredients: [{@elven_wood, 900}]},
      # Báculo Engarzado — MaderaElfica=900
      %{min_skill: 100, result_id: 1788, result_amount: 1, ingredients: [{@elven_wood, 900}]},
      # Galera — Madera=30000, MaderaElfica=4000
      %{
        min_skill: 100,
        result_id: 475,
        result_amount: 1,
        ingredients: [{@wood, 30_000}, {@elven_wood, 4000}]
      },
      # Galeón — MaderaElfica=30000
      %{min_skill: 100, result_id: 476, result_amount: 1, ingredients: [{@elven_wood, 30_000}]},
      # Carcaj de Flechas — Madera=525
      %{min_skill: 100, result_id: 3801, result_amount: 1, ingredients: [{@wood, 525}]},
      # Carcaj de Flechas +1 — Madera=1050
      %{min_skill: 100, result_id: 3806, result_amount: 1, ingredients: [{@wood, 1050}]},
      # Carcaj de Flechas +2 — Madera=1575
      %{min_skill: 100, result_id: 3802, result_amount: 1, ingredients: [{@wood, 1575}]},
      # Carcaj de Flechas +3 — Madera=3150
      %{min_skill: 100, result_id: 3804, result_amount: 1, ingredients: [{@wood, 3150}]},
      # Carcaj de Flechas Élficas — MaderaElfica=2625
      %{min_skill: 100, result_id: 3803, result_amount: 1, ingredients: [{@elven_wood, 2625}]}
    ]
  end

  def production_recipes(:alchemy) do
    [
      # --- Potions (ObjAlquimista.dat, VB6 obj.dat fields) ---
      # Pócima de Vida — FlorRoja=1, FrascoAlq=1, Mortero=1
      %{
        min_skill: 0,
        result_id: 891,
        result_amount: 1,
        ingredients: [{@flor_roja, 1}, {@frasco_alq, 1}, {@mortero, 1}]
      },
      # Pócima de Maná — FlorOceano=1, FrascoAlq=1, Mortero=1
      %{
        min_skill: 15,
        result_id: 894,
        result_amount: 1,
        ingredients: [{@flor_oceano, 1}, {@frasco_alq, 1}, {@mortero, 1}]
      },
      # Pócima de Antídoto — HongoDeLuz=1, FrascoAlq=1, Mortero=1
      %{
        min_skill: 20,
        result_id: 890,
        result_amount: 1,
        ingredients: [{@hongo_de_luz, 1}, {@frasco_alq, 1}, {@mortero, 1}]
      },
      # Pócima de Energía — FrascoAlq=1, Mortero=1
      %{
        min_skill: 25,
        result_id: 1019,
        result_amount: 1,
        ingredients: [{@frasco_alq, 1}, {@mortero, 1}]
      },
      # Pócima de Agilidad — ColaDeZorro=2, FrascoAlq=1, Mortero=1
      %{
        min_skill: 30,
        result_id: 889,
        result_amount: 1,
        ingredients: [{@cola_de_zorro, 2}, {@frasco_alq, 1}, {@mortero, 1}]
      },
      # Pócima de Fuerza — Tuna=2, FrascoAlq=1, Mortero=1
      %{
        min_skill: 35,
        result_id: 892,
        result_amount: 1,
        ingredients: [{@tuna, 2}, {@frasco_alq, 1}, {@mortero, 1}]
      }
    ]
  end

  def production_recipes(:tailoring) do
    [
      # --- ObjSastre.dat items (VB6 obj.dat PielLobo/PielOsoPardo/PielOsoPolar/
      #     PielLoboNegro/PielTigreBengala fields) ---
      # Tela trabajada — PielLobo=1
      %{min_skill: 0, result_id: 3578, result_amount: 1, ingredients: [{@piel_lobo, 1}]},
      # Cuerdas — PielLobo=1
      %{min_skill: 0, result_id: 3822, result_amount: 1, ingredients: [{@piel_lobo, 1}]},
      # Vestimenta Común — PielLobo=1
      %{min_skill: 2, result_id: 32, result_amount: 1, ingredients: [{@piel_lobo, 1}]},
      # Vestimenta de Enano — PielLobo=7
      %{min_skill: 0, result_id: 240, result_amount: 1, ingredients: [{@piel_lobo, 7}]},
      # Ropa de Clan — PielLobo=20
      %{min_skill: 10, result_id: 1975, result_amount: 1, ingredients: [{@piel_lobo, 20}]},
      # Casco de Lobo — PielLobo=15
      %{min_skill: 10, result_id: 1778, result_amount: 1, ingredients: [{@piel_lobo, 15}]},
      # Ropa de Burgués Turquesa — PielLobo=20
      %{min_skill: 10, result_id: 2911, result_amount: 1, ingredients: [{@piel_lobo, 20}]},
      # Ropa Estuaria (M) — PielLobo=30
      %{min_skill: 25, result_id: 508, result_amount: 1, ingredients: [{@piel_lobo, 30}]},
      # Túnica de Mago — PielLobo=50
      %{min_skill: 35, result_id: 196, result_amount: 1, ingredients: [{@piel_lobo, 50}]},
      # Túnica Aventurera (Bajos) — PielLobo=50
      %{min_skill: 35, result_id: 1226, result_amount: 1, ingredients: [{@piel_lobo, 50}]},
      # Túnica Ocre — PielLobo=60, PielOsoPardo=5
      %{
        min_skill: 45,
        result_id: 1955,
        result_amount: 1,
        ingredients: [{@piel_lobo, 60}, {@piel_oso_pardo, 5}]
      },
      # Túnica de Nigromante — PielLobo=70, PielOsoPardo=10
      %{
        min_skill: 55,
        result_id: 1089,
        result_amount: 1,
        ingredients: [{@piel_lobo, 70}, {@piel_oso_pardo, 10}]
      },
      # Túnica Dorada de Gala — PielLobo=70, PielOsoPardo=10
      %{
        min_skill: 55,
        result_id: 2857,
        result_amount: 1,
        ingredients: [{@piel_lobo, 70}, {@piel_oso_pardo, 10}]
      },
      # Vestido Indulgente Rojo — PielLobo=70, PielOsoPardo=10
      %{
        min_skill: 55,
        result_id: 2932,
        result_amount: 1,
        ingredients: [{@piel_lobo, 70}, {@piel_oso_pardo, 10}]
      },
      # Capucha de Elite — PielTigreBengala=2, PielLoboNegro=10
      %{
        min_skill: 63,
        result_id: 1769,
        result_amount: 1,
        ingredients: [{@piel_tigre_bengala, 2}, {@piel_lobo_negro, 10}]
      },
      # Manto de los Vientos — PielLobo=80, PielOsoPardo=15, PielOsoPolar=1
      %{
        min_skill: 65,
        result_id: 2916,
        result_amount: 1,
        ingredients: [{@piel_lobo, 80}, {@piel_oso_pardo, 15}, {@piel_oso_polar, 1}]
      },
      # Túnica Natural Mujer — PielLobo=80, PielOsoPardo=15, PielOsoPolar=1
      %{
        min_skill: 65,
        result_id: 1961,
        result_amount: 1,
        ingredients: [{@piel_lobo, 80}, {@piel_oso_pardo, 15}, {@piel_oso_polar, 1}]
      },
      # Sotana de Gran Hechicero — PielLobo=80, PielOsoPardo=15, PielOsoPolar=1
      %{
        min_skill: 65,
        result_id: 2854,
        result_amount: 1,
        ingredients: [{@piel_lobo, 80}, {@piel_oso_pardo, 15}, {@piel_oso_polar, 1}]
      },
      # Sombrero de Mago — PielLoboNegro=28, PielTigreBengala=3
      %{
        min_skill: 65,
        result_id: 992,
        result_amount: 1,
        ingredients: [{@piel_lobo_negro, 28}, {@piel_tigre_bengala, 3}]
      },
      # Sombrero de Mago Superior — PielOsoPolar=6
      %{min_skill: 75, result_id: 3990, result_amount: 1, ingredients: [{@piel_oso_polar, 6}]},
      # Túnica Legendaria — PielLobo=45, PielOsoPardo=25, PielOsoPolar=3
      %{
        min_skill: 100,
        result_id: 519,
        result_amount: 1,
        ingredients: [{@piel_lobo, 45}, {@piel_oso_pardo, 25}, {@piel_oso_polar, 3}]
      },
      # Túnica Legendaria (E/G) — PielLobo=45, PielOsoPardo=25, PielOsoPolar=3
      %{
        min_skill: 100,
        result_id: 1957,
        result_amount: 1,
        ingredients: [{@piel_lobo, 45}, {@piel_oso_pardo, 25}, {@piel_oso_polar, 3}]
      },
      # Casco de Tigre — PielTigreBengala=15
      %{min_skill: 100, result_id: 1758, result_amount: 1, ingredients: [{@piel_tigre_bengala, 15}]},
      # Morral — PielLobo=300, PielOsoPardo=150, PielOsoPolar=40
      %{
        min_skill: 100,
        result_id: 3462,
        result_amount: 1,
        ingredients: [{@piel_lobo, 300}, {@piel_oso_pardo, 150}, {@piel_oso_polar, 40}]
      }
    ]
  end

  def production_recipes(_), do: []

  @doc "Return the list of result_ids that the player's skill level qualifies for."
  def craftable_item_ids(skill_atom, skill_value) do
    production_recipes(skill_atom)
    |> Enum.filter(fn recipe -> skill_value >= recipe.min_skill end)
    |> Enum.map(fn recipe -> recipe.result_id end)
  end

  @doc "Find a specific recipe by its result item_id."
  def find_recipe_by_item(skill_atom, item_id) do
    production_recipes(skill_atom)
    |> Enum.find(fn recipe -> recipe.result_id == item_id end)
  end

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
