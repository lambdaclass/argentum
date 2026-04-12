defmodule Arena.CharacterCreation do
  @moduledoc """
  Character creation logic: validates inputs and builds a new PlayerEntity.

  All stat formulas match VB6 ConnectNewUser (TCP.bas:427-581).
  """

  alias Arena.Data.GameData
  alias Arena.Entity.PlayerEntity

  @max_name_length 30
  @min_name_length 3
  @valid_races 1..6
  @valid_genders 1..2
  @valid_classes 1..12
  @valid_cities 1..9

  @gender_names %{1 => :male, 2 => :female}
  @gender_labels %{1 => "Hombre", 2 => "Mujer"}
  @race_labels %{
    1 => "Humano",
    2 => "Elfo",
    3 => "Elfo Oscuro",
    4 => "Enano",
    5 => "Gnomo",
    6 => "Orco"
  }
  @class_labels %{
    1 => "Mago",
    2 => "Clérigo",
    3 => "Paladín",
    4 => "Cazador",
    5 => "Trabajador",
    6 => "Guerrero",
    7 => "Ladrón",
    8 => "Bandido",
    9 => "Asesino",
    10 => "Druida",
    11 => "Bardo",
    12 => "Pirata"
  }
  # VB6 e_Ciudad enum order
  @home_city_atom %{
    1 => :ullathorpe,
    2 => :nix,
    3 => :banderbill,
    4 => :lindos,
    5 => :arghal,
    6 => :arkhein,
    7 => :forgat,
    8 => :eldoria,
    9 => :penthar
  }
  @home_city_labels %{
    1 => "Ullathorpe",
    2 => "Nix",
    3 => "Banderbill",
    4 => "Lindos",
    5 => "Arghal",
    6 => "Arkhein",
    7 => "Forgat",
    8 => "Eldoria",
    9 => "Penthar"
  }

  # Body IDs per {race_id, gender_id} — from VB6 DarCuerpo
  @body_ids %{
    # Humano
    {1, 1} => 1,
    {1, 2} => 1,
    # Elfo
    {2, 1} => 2,
    {2, 2} => 2,
    # Drow
    {3, 1} => 3,
    {3, 2} => 3,
    # Enano
    {4, 1} => 300,
    {4, 2} => 300,
    # Gnomo
    {5, 1} => 300,
    {5, 2} => 300,
    # Orco
    {6, 1} => 582,
    {6, 2} => 581
  }

  # Valid head ranges per {race_id, gender_id} — from VB6 ValidarCabeza
  @head_ranges %{
    {1, 1} => [{1, 41}, {778, 791}],
    {2, 1} => [{101, 132}, {531, 545}],
    {3, 1} => [{200, 229}, {792, 810}],
    {4, 1} => [{300, 344}],
    {5, 1} => [{400, 429}],
    {6, 1} => [{500, 529}],
    {1, 2} => [{50, 80}, {187, 190}, {230, 246}],
    {2, 2} => [{150, 179}, {758, 777}],
    {3, 2} => [{250, 279}],
    {4, 2} => [{350, 379}],
    {5, 2} => [{450, 479}],
    {6, 2} => [{550, 579}]
  }

  @doc """
  Create a new character from validated params.

  Params:
    - name: string
    - race: integer 1-6
    - gender: integer 1-2
    - class: integer 1-12
    - head: integer (graphic ID)
    - home_city: integer 1-9
    - account_id: string

  Returns `{:ok, %PlayerEntity{}}` or `{:error, reason}`.
  """
  def create(params) do
    with :ok <- validate_name(params.name),
         :ok <- validate_range(:race, params.race, @valid_races),
         :ok <- validate_range(:gender, params.gender, @valid_genders),
         :ok <- validate_range(:class, params.class, @valid_classes),
         :ok <- validate_range(:home_city, params.home_city, @valid_cities),
         :ok <- validate_head(params.race, params.gender, params.head) do
      {:ok, build_entity(params)}
    end
  end

  @doc "Expose browser-friendly character creation options from the canonical VB6 rules."
  def browser_options do
    %{
      races: enum_options(@valid_races, @race_labels),
      genders: enum_options(@valid_genders, @gender_labels),
      classes: enum_options(@valid_classes, @class_labels),
      home_cities: enum_options(@valid_cities, @home_city_labels),
      head_ranges:
        for {{race_id, gender_id}, ranges} <- @head_ranges, into: %{} do
          {"#{race_id}:#{gender_id}", Enum.map(ranges, fn {min, max} -> %{min: min, max: max} end)}
        end,
      body_ids:
        for {{race_id, gender_id}, body_id} <- @body_ids, into: %{} do
          {"#{race_id}:#{gender_id}", body_id}
        end,
      defaults: %{
        race: 1,
        gender: 1,
        class: 6,
        home_city: 1,
        head: default_head(1, 1)
      }
    }
  end

  # ---- Validation ----

  defp validate_name(name) when is_binary(name) do
    name = String.trim(name)
    len = String.length(name)

    cond do
      len < @min_name_length -> {:error, :name_too_short}
      len > @max_name_length -> {:error, :name_too_long}
      not Regex.match?(~r/^[a-zA-Z0-9 _]+$/, name) -> {:error, :name_invalid_chars}
      true -> :ok
    end
  end

  defp validate_name(_), do: {:error, :name_invalid}

  defp enum_options(range, labels) do
    Enum.map(range, fn id ->
      %{id: id, label: Map.fetch!(labels, id)}
    end)
  end

  defp default_head(race, gender) do
    case Map.get(@head_ranges, {race, gender}, []) do
      [{min, _max} | _] -> min
      [] -> 1
    end
  end

  defp validate_range(field, value, range) do
    if value in range, do: :ok, else: {:error, {:"invalid_#{field}", value}}
  end

  defp validate_head(race, gender, head) do
    ranges = Map.get(@head_ranges, {race, gender}, [])

    if Enum.any?(ranges, fn {lo, hi} -> head >= lo and head <= hi end) do
      :ok
    else
      {:error, :invalid_head}
    end
  end

  # ---- Entity builder ----

  defp build_entity(params) do
    race = params.race
    class = params.class
    gender = params.gender

    # Attributes: 18 + race modifier
    str = 18 + GameData.race_mod(race, :str)
    agi = 18 + GameData.race_mod(race, :agi)
    int = 18 + GameData.race_mod(race, :int)
    con = 18 + GameData.race_mod(race, :con)
    cha = 18 + GameData.race_mod(race, :cha)

    # HP = constitution (VB6: MaxHp = Constitution)
    hp = con

    # Mana = intelligence × class mana initial multiplier
    mana_mult = GameData.class_mana_initial(class)
    mana = trunc(int * mana_mult)

    # Stamina = 20 × random(1..agility/6, min 2)
    sta_roll = max(div(agi, 6), 2)
    stamina = 20 * Enum.random(1..sta_roll)

    # Spawn point from home city
    spawn = GameData.city_spawn(params.home_city)

    # Starting inventory and spells
    inventory = build_starting_inventory(class)
    spells = build_starting_spells(class)

    body_id = Map.get(@body_ids, {race, gender}, 1)
    race_name = GameData.race_name(race)
    class_name = GameData.class_name(class)
    gender_name = Map.get(@gender_names, gender, :male)
    home_city = Map.get(@home_city_atom, params.home_city, :ullathorpe)

    %PlayerEntity{
      char_id: nil,
      name: String.trim(params.name),
      account_id: params.account_id,
      race: race_name && Atom.to_string(race_name),
      class: class_name && Atom.to_string(class_name),
      gender: gender_name && Atom.to_string(gender_name),
      home_city: home_city && Atom.to_string(home_city),
      level: 1,
      xp: 0,
      skill_points: 10,
      map_id: spawn.map,
      x: spawn.x,
      y: spawn.y,
      heading: :south,
      body_id: body_id,
      base_body_id: body_id,
      head_id: params.head,
      hp: hp,
      max_hp: hp,
      mana: mana,
      max_mana: mana,
      stamina: stamina,
      max_stamina: stamina,
      hunger: 100,
      thirst: 100,
      str: str,
      agi: agi,
      int: int,
      con: con,
      cha: cha,
      gold: 0,
      inventory: inventory,
      spells: spells,
      speeding: 1.0
    }
  end

  # ---- Starting inventory (from VB6 RellenarInventario) ----

  defp build_starting_inventory(class) do
    items = []

    # Everyone: 500 red potions
    items = [{4335, 500} | items]

    # Blue potions by class
    items =
      case class do
        # Mago, Druida
        c when c in [1, 10] -> [{4336, 850} | items]
        # Bardo, Clerigo
        c when c in [11, 2] -> [{4336, 650} | items]
        # Paladin, Asesino, Bandido
        c when c in [3, 9, 8] -> [{4336, 450} | items]
        _ -> items
      end

    # Yellow/green potions
    items =
      case class do
        c when c in [1, 10] ->
          [{4337, 80} | items]

        c when c in [2, 3, 4, 5, 6, 7, 8, 9, 11, 12] ->
          [{4338, 120}, {4337, 100} | items]

        _ ->
          items
      end

    # Purple potion + travel pass
    items = [{3791, 4}, {4334, 35} | items]

    # Class weapons/equipment
    items = items ++ class_equipment(class)

    # Armor (last item, before food)
    items =
      case class do
        # Tunica del Principiante
        c when c in [1, 10, 11] -> [{3502, 1} | items]
        # Armadura de Principiante
        _ -> [{3500, 1} | items]
      end

    # Food and drink
    items = [{3685, 50}, {3684, 100} | items]

    # Convert to inventory slot format (24 slots, pad with nil)
    items
    |> Enum.reverse()
    |> Enum.take(24)
    |> Enum.map(fn {item_id, amount} -> %{item_id: item_id, amount: amount, equipped: false} end)
    |> pad_inventory()
  end

  # Mago: baston, sombrero
  defp class_equipment(1), do: [{3495, 1}, {3493, 1}]
  # Clerigo
  defp class_equipment(2), do: [{3686, 1}, {3487, 1}, {3488, 1}, {3489, 1}, {3490, 1}]
  # Paladin
  defp class_equipment(3), do: [{3487, 1}, {3686, 1}, {3488, 1}, {3489, 1}, {3490, 1}]
  # Cazador
  defp class_equipment(4), do: [{3686, 1}, {3491, 1}, {3492, 1050}, {3489, 1}, {3490, 1}, {3488, 1}]
  # Trabajador
  defp class_equipment(5), do: [{3487, 1}, {3488, 1}, {3489, 1}, {3491, 1}, {3492, 850}]
  # Guerrero
  defp class_equipment(6), do: [{3487, 1}, {3488, 1}, {3489, 1}, {3490, 1}, {3491, 1}, {3492, 650}, {3686, 1}]
  # Ladron
  defp class_equipment(7), do: [{3686, 1}, {1353, 1}, {3488, 1}, {3489, 1}]
  # Bandido
  defp class_equipment(8), do: [{1353, 1}, {3487, 1}, {3488, 1}, {3489, 1}, {3490, 1}]
  # Asesino
  defp class_equipment(9), do: [{3686, 1}, {3488, 1}, {3489, 1}, {3490, 1}, {3487, 1}]
  # Druida
  defp class_equipment(10), do: [{3487, 1}, {3494, 1}, {1778, 1}]
  # Bardo
  defp class_equipment(11), do: [{3686, 1}, {3488, 1}, {3489, 1}, {3490, 1}, {3496, 1}]
  # Pirata
  defp class_equipment(12), do: [{3487, 1}, {3488, 1}, {3489, 1}, {3490, 1}, {3497, 1}, {3498, 350}]
  defp class_equipment(_), do: []

  defp pad_inventory(items) do
    padding = List.duplicate(nil, max(0, 24 - length(items)))
    items ++ padding
  end

  # ---- Starting spells (from VB6 RellenarInventario) ----

  defp build_starting_spells(class) do
    case class do
      # Dardo magico, Invocar lobo
      c when c in [1, 2, 10, 11] -> [1, 7]
      # Onda magica, Curar heridas leves
      c when c in [3, 8, 9] -> [291, 12]
      _ -> []
    end
  end
end
