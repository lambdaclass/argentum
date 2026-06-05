defmodule Arena.RecipeDatParityTest do
  @moduledoc """
  Verifies `Arena.Data.CraftingRecipes` matches the canonical VB6 recipe
  source `.dat` files shipped under `resources/raw/Dat/`.

  Unlike a hardcoded ID list, this test parses each `.dat` at runtime via
  `Arena.Data.IniParser.parse_file/1` (the same loader `GameData` uses for
  `Balance.dat`, `obj.dat`, etc.) and asserts the loader exposes a recipe
  for every product `Index` declared in the source file.

  Source `.dat` files:
    - ArmasHerrero.dat        (NumArmas — blacksmith weapons + ammo)
    - ArmadurasHerrero.dat    (NumArmaduras — armors / shields / helmets / rings)
    - ObjCarpintero.dat       (NumObjs — carpentry products)
    - ObjSastre.dat           (NumObjs — tailoring products)
    - ObjAlquimista.dat       (NumObjs — alchemy potions)

  Encoding: the parser splits on `\n` after stripping `\r`. Files use
  CP-1252 / ISO-8859-1 for Spanish accents inside the trailing VB6
  comments (`Index=403 ' Espada de Héroes`), but the parser strips
  inline comments after `'`, so the non-UTF-8 bytes never reach the
  value side. We only consume `Index=` integers from each section.
  """
  use ExUnit.Case, async: true

  alias Arena.Data.{CraftingRecipes, IniParser}

  @dat_dir Application.compile_env(:arena, :dat_dir, "../resources/raw/Dat")

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Parse `.dat`, return ordered list of {section_name, index_int} for every
  # section whose normalized name starts with `prefix` (excluding "INIT").
  defp dat_entries(file, prefix) do
    path = Path.join(@dat_dir, file)
    {:ok, sections} = IniParser.parse_file(path)

    sections
    |> Enum.filter(fn {name, _fields} ->
      up = String.upcase(name)
      up != "INIT" and String.starts_with?(up, prefix)
    end)
    |> Enum.map(fn {name, fields} ->
      idx_str =
        fields
        |> Map.get("index", "0")
        |> String.trim()

      case Integer.parse(idx_str) do
        {n, _} -> {name, n}
        :error -> flunk("#{file}: section [#{name}] has unparseable Index=#{inspect(idx_str)}")
      end
    end)
  end

  defp dat_declared_count(file, count_key) do
    path = Path.join(@dat_dir, file)
    {:ok, sections} = IniParser.parse_file(path)
    init = Map.get(sections, "INIT", %{})
    {n, _} = init |> Map.get(count_key, "0") |> Integer.parse()
    n
  end

  defp dat_unique_ids(file, prefix) do
    file
    |> dat_entries(prefix)
    |> Enum.map(fn {_, id} -> id end)
    |> MapSet.new()
  end

  defp loader_ids(skill_atom) do
    skill_atom
    |> CraftingRecipes.production_recipes()
    |> Enum.map(& &1.result_id)
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # Declared count parity — the `[INIT]` Num* counter is the file's own claim
  # ---------------------------------------------------------------------------

  describe "[INIT] declared counts match section counts" do
    @cases [
      {"ArmasHerrero.dat", "numarmas", "ARMA", 26},
      {"ArmadurasHerrero.dat", "numarmaduras", "ARMADURA", 22},
      {"ObjCarpintero.dat", "numobjs", "OBJ", 30},
      {"ObjSastre.dat", "numobjs", "OBJ", 25},
      {"ObjAlquimista.dat", "numobjs", "OBJ", 6}
    ]

    for {file, count_key, prefix, expected} <- @cases do
      test "#{file} declares #{expected} sections" do
        declared = dat_declared_count(unquote(file), unquote(count_key))
        actual = unquote(file) |> dat_entries(unquote(prefix)) |> length()

        assert declared == unquote(expected),
               "#{unquote(file)} [INIT] #{unquote(count_key)}=#{declared}, " <>
                 "expected #{unquote(expected)} — source file drift"

        assert actual == declared,
               "#{unquote(file)} declares #{declared} but #{actual} sections found"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Blacksmithing — ArmasHerrero.dat + ArmadurasHerrero.dat
  # ---------------------------------------------------------------------------

  describe "blacksmithing recipes vs ArmasHerrero.dat + ArmadurasHerrero.dat" do
    test "every weapon Index in ArmasHerrero.dat has a recipe" do
      dat_ids = dat_unique_ids("ArmasHerrero.dat", "ARMA")
      missing = MapSet.difference(dat_ids, loader_ids(:blacksmithing))

      assert MapSet.size(missing) == 0,
             "ArmasHerrero.dat product IDs without a recipe: #{inspect(MapSet.to_list(missing))}"
    end

    test "every armor Index in ArmadurasHerrero.dat has a recipe" do
      dat_ids = dat_unique_ids("ArmadurasHerrero.dat", "ARMADURA")
      missing = MapSet.difference(dat_ids, loader_ids(:blacksmithing))

      assert MapSet.size(missing) == 0,
             "ArmadurasHerrero.dat product IDs without a recipe: #{inspect(MapSet.to_list(missing))}"
    end

    test "loader has no extra blacksmithing recipes beyond .dat + smelting" do
      weapons = dat_unique_ids("ArmasHerrero.dat", "ARMA")
      armors = dat_unique_ids("ArmadurasHerrero.dat", "ARMADURA")
      # Smelting produces ingots from raw ore — VB6 Trabajo.bas, not in
      # ArmasHerrero/ArmadurasHerrero. Allowlist them explicitly.
      smelting = MapSet.new([386, 387, 388])
      allowed = weapons |> MapSet.union(armors) |> MapSet.union(smelting)

      extra = MapSet.difference(loader_ids(:blacksmithing), allowed)

      assert MapSet.size(extra) == 0,
             "Loader has recipes not present in .dat or smelting allowlist: " <>
               "#{inspect(MapSet.to_list(extra))}"
    end

    test "recipe count = 3 smelting + 26 weapons + 22 armors = 51" do
      recipes = CraftingRecipes.production_recipes(:blacksmithing)
      assert length(recipes) == 51
    end
  end

  # ---------------------------------------------------------------------------
  # Carpentry — ObjCarpintero.dat
  # ---------------------------------------------------------------------------

  describe "carpentry recipes vs ObjCarpintero.dat" do
    test "every Index in ObjCarpintero.dat has a recipe" do
      dat_ids = dat_unique_ids("ObjCarpintero.dat", "OBJ")
      missing = MapSet.difference(dat_ids, loader_ids(:carpentry))

      assert MapSet.size(missing) == 0,
             "ObjCarpintero.dat IDs without a recipe: #{inspect(MapSet.to_list(missing))}"
    end

    test "loader has no extra carpentry recipes" do
      dat_ids = dat_unique_ids("ObjCarpintero.dat", "OBJ")
      extra = MapSet.difference(loader_ids(:carpentry), dat_ids)

      assert MapSet.size(extra) == 0,
             "Loader has carpentry recipes not in ObjCarpintero.dat: " <>
               "#{inspect(MapSet.to_list(extra))}"
    end

    test "recipe count matches ObjCarpintero.dat (30)" do
      assert length(CraftingRecipes.production_recipes(:carpentry)) == 30
    end
  end

  # ---------------------------------------------------------------------------
  # Tailoring — ObjSastre.dat
  # ---------------------------------------------------------------------------

  describe "tailoring recipes vs ObjSastre.dat" do
    test "every Index in ObjSastre.dat has a recipe (unique IDs)" do
      dat_ids = dat_unique_ids("ObjSastre.dat", "OBJ")
      missing = MapSet.difference(dat_ids, loader_ids(:tailoring))

      assert MapSet.size(missing) == 0,
             "ObjSastre.dat IDs without a recipe: #{inspect(MapSet.to_list(missing))}"
    end

    test "ObjSastre.dat has 25 sections but only 24 unique IDs (Capucha de Elite dup)" do
      entries = dat_entries("ObjSastre.dat", "OBJ")
      assert length(entries) == 25

      ids = Enum.map(entries, fn {_, id} -> id end)
      unique = ids |> MapSet.new() |> MapSet.size()
      assert unique == 24

      # Pin the duplicate so the test fails loudly if the .dat changes.
      duplicates = ids -- Enum.uniq(ids)
      assert duplicates == [1769], "Expected only Capucha de Elite (1769) duplicated"
    end

    test "loader has no extra tailoring recipes" do
      dat_ids = dat_unique_ids("ObjSastre.dat", "OBJ")
      extra = MapSet.difference(loader_ids(:tailoring), dat_ids)

      assert MapSet.size(extra) == 0,
             "Loader has tailoring recipes not in ObjSastre.dat: " <>
               "#{inspect(MapSet.to_list(extra))}"
    end

    test "recipe count matches ObjSastre.dat unique IDs (24)" do
      assert length(CraftingRecipes.production_recipes(:tailoring)) == 24
    end
  end

  # ---------------------------------------------------------------------------
  # Alchemy — ObjAlquimista.dat
  # ---------------------------------------------------------------------------

  describe "alchemy recipes vs ObjAlquimista.dat" do
    test "every Index in ObjAlquimista.dat has a recipe" do
      dat_ids = dat_unique_ids("ObjAlquimista.dat", "OBJ")
      missing = MapSet.difference(dat_ids, loader_ids(:alchemy))

      assert MapSet.size(missing) == 0,
             "ObjAlquimista.dat IDs without a recipe: #{inspect(MapSet.to_list(missing))}"
    end

    test "loader has no extra alchemy recipes" do
      dat_ids = dat_unique_ids("ObjAlquimista.dat", "OBJ")
      extra = MapSet.difference(loader_ids(:alchemy), dat_ids)

      assert MapSet.size(extra) == 0,
             "Loader has alchemy recipes not in ObjAlquimista.dat: " <>
               "#{inspect(MapSet.to_list(extra))}"
    end

    test "recipe count matches ObjAlquimista.dat (6)" do
      assert length(CraftingRecipes.production_recipes(:alchemy)) == 6
    end
  end

  # ---------------------------------------------------------------------------
  # Spot-checks: known recipes are present with expected min_skill + result_id
  # ---------------------------------------------------------------------------

  describe "known-recipe spot checks (result_id matches .dat Index)" do
    # {skill, dat_section, dat_file, expected_id, expected_min_skill, label}
    @spot_checks [
      # Blacksmithing — smelting + iconic weapons + armor
      {:blacksmithing, nil, nil, 386, 0, "Lingote Hierro (smelting)"},
      {:blacksmithing, "Arma2", "ArmasHerrero.dat", 15, 0, "Daga"},
      {:blacksmithing, "Arma23", "ArmasHerrero.dat", 402, 100, "Espada Matadragones"},
      {:blacksmithing, "Armadura1", "ArmadurasHerrero.dat", 1912, 58, "Armadura de Herrero"},
      {:blacksmithing, "Armadura18", "ArmadurasHerrero.dat", 132, 65, "Casco de Hierro Completo"},

      # Carpentry
      {:carpentry, "OBJ2", "ObjCarpintero.dat", 480, 5, "Flecha"},
      {:carpentry, "OBJ7", "ObjCarpintero.dat", 479, 10, "Arco Simple"},
      {:carpentry, "OBJ12", "ObjCarpintero.dat", 474, 75, "Barca"},

      # Tailoring
      {:tailoring, "Obj1", "ObjSastre.dat", 3578, 0, "Tela trabajada"},
      {:tailoring, "Obj7", "ObjSastre.dat", 196, 35, "Túnica de Mago"},
      {:tailoring, "Obj22", "ObjSastre.dat", 3462, 100, "Morral"},

      # Alchemy
      {:alchemy, "OBJ2", "ObjAlquimista.dat", 891, 0, "Pócima de Vida"},
      {:alchemy, "OBJ4", "ObjAlquimista.dat", 892, 35, "Pócima de Fuerza"}
    ]

    for {skill, section, file, expected_id, expected_min_skill, label} <- @spot_checks do
      test "#{label} — recipe present with min_skill=#{expected_min_skill}" do
        recipe = CraftingRecipes.find_recipe_by_item(unquote(skill), unquote(expected_id))

        assert recipe != nil,
               "No recipe found for #{unquote(label)} (id=#{unquote(expected_id)}) " <>
                 "under #{inspect(unquote(skill))}"

        assert recipe.result_id == unquote(expected_id)
        assert recipe.min_skill == unquote(expected_min_skill)

        # When the spot check is anchored to a specific .dat row, verify the
        # `.dat` Index matches the loader's result_id — this is the parity
        # claim the test enforces.
        if unquote(file) do
          {:ok, sections} = IniParser.parse_file(Path.join(@dat_dir, unquote(file)))
          fields = Map.get(sections, unquote(section)) || %{}
          {dat_index, _} = fields |> Map.get("index", "") |> String.trim() |> Integer.parse()
          assert dat_index == unquote(expected_id),
                 "#{unquote(file)} [#{unquote(section)}] Index=#{dat_index} but loader has #{unquote(expected_id)}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Behavior pin: min_skill gate — find_craftable rejects below threshold
  # ---------------------------------------------------------------------------

  describe "min_skill rejection — craftable list filters by skill" do
    test "Espada Matadragones (min_skill=100) is rejected below skill 100" do
      # Behavior pin: result_id 402 must not appear in the craftable list
      # until the player hits skill 100. craftable_item_ids/2 is the exact
      # gate the server applies via filter on `skill_value >= recipe.min_skill`.
      refute 402 in CraftingRecipes.craftable_item_ids(:blacksmithing, 99)
      assert 402 in CraftingRecipes.craftable_item_ids(:blacksmithing, 100)
    end

    test "Barca (min_skill=75) is not in craftable list at skill 74" do
      refute 474 in CraftingRecipes.craftable_item_ids(:carpentry, 74)
      assert 474 in CraftingRecipes.craftable_item_ids(:carpentry, 75)
    end

    test "Pócima de Fuerza (min_skill=35) is not in craftable list at skill 34" do
      refute 892 in CraftingRecipes.craftable_item_ids(:alchemy, 34)
      assert 892 in CraftingRecipes.craftable_item_ids(:alchemy, 35)
    end

    test "Túnica de Mago (min_skill=35) is not in craftable list at skill 34" do
      refute 196 in CraftingRecipes.craftable_item_ids(:tailoring, 34)
      assert 196 in CraftingRecipes.craftable_item_ids(:tailoring, 35)
    end

    test "Daga (min_skill=0) is craftable at skill 0" do
      assert 15 in CraftingRecipes.craftable_item_ids(:blacksmithing, 0)
    end

    test "skill 0 grants exactly the min_skill=0 blacksmithing recipes" do
      ids = CraftingRecipes.craftable_item_ids(:blacksmithing, 0) |> MapSet.new()

      expected =
        CraftingRecipes.production_recipes(:blacksmithing)
        |> Enum.filter(&(&1.min_skill == 0))
        |> Enum.map(& &1.result_id)
        |> MapSet.new()

      assert ids == expected,
             "Below threshold ids leaked: missing=#{inspect(MapSet.difference(expected, ids))} " <>
               "extra=#{inspect(MapSet.difference(ids, expected))}"
    end

    test "find_recipe_by_item returns the recipe regardless of skill (skill checked by caller)" do
      # find_recipe_by_item is purely a lookup — the skill gate is applied by
      # do_craft_item before consuming ingredients. Pin that contract so
      # callers can't accidentally bypass the gate by walking around the
      # lookup.
      recipe = CraftingRecipes.find_recipe_by_item(:blacksmithing, 402)
      assert recipe != nil
      assert recipe.min_skill == 100
    end

    test "find_craftable never returns a recipe above the player's skill" do
      # Use minimal inventory — even if a high-tier recipe shared low-tier
      # ingredients, the skill filter must still hold.
      inv = make_inv([{386, 9_999}, {387, 9_999}, {388, 9_999}])

      for skill_value <- [0, 25, 50, 74, 99] do
        case CraftingRecipes.find_craftable(:blacksmithing, skill_value, inv) do
          nil -> :ok
          recipe -> assert recipe.min_skill <= skill_value,
                           "find_craftable returned #{recipe.result_id} (min_skill=#{recipe.min_skill}) " <>
                             "at skill_value=#{skill_value}"
        end
      end
    end
  end

  defp make_inv(items) do
    slots =
      items
      |> Enum.map(fn {item_id, amount} ->
        %{item_id: item_id, amount: amount, equipped: false}
      end)

    slots ++ List.duplicate(nil, max(24 - length(slots), 0))
  end
end
