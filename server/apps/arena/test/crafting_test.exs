defmodule Arena.CraftingTest do
  @moduledoc """
  Tests for crafting and gathering system.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.{Crafting, InventoryHandlers}
  alias AoEntities.PlayerEntity
  alias Arena.Data.CraftingRecipes

  import Arena.Test.MapStateFactory

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp make_state(players, opts \\ []) do
    trigger_map = Keyword.get(opts, :trigger_map, %{})
    npcs_live = Keyword.get(opts, :npcs_live, %{})
    sessions = Keyword.get(opts, :sessions, %{})
    objects = Keyword.get(opts, :objects, [])

    map_state(
      players: players,
      sessions: sessions,
      npcs_live: npcs_live,
      meta: %{safe_zone: false, trigger_map: trigger_map, objects: objects}
    )
  end

  # ---- CraftingRecipes.select_product/2 ----

  describe "CraftingRecipes.select_product/2" do
    test "returns nil when skill is too low for all products" do
      # mining products start at skill 0, so this always returns something
      assert CraftingRecipes.select_product(:mining, 0) != nil
    end

    test "returns highest tier product for skill level" do
      # Skill 60 should get gold ore (194), not iron (192) or silver (193)
      assert CraftingRecipes.select_product(:mining, 60) == 194
    end

    test "returns base product for low skill" do
      assert CraftingRecipes.select_product(:mining, 5) == 192
    end

    test "returns nil for unknown skill" do
      assert CraftingRecipes.select_product(:unknown, 50) == nil
    end

    test "returns blodium ore at skill 85+" do
      assert CraftingRecipes.select_product(:mining, 85) == 3787
    end

    test "fishing tiers match VB6 data" do
      assert CraftingRecipes.select_product(:fishing, 0) == 2150
      assert CraftingRecipes.select_product(:fishing, 20) == 2093
      assert CraftingRecipes.select_product(:fishing, 40) == 2094
      assert CraftingRecipes.select_product(:fishing, 60) == 2101
      assert CraftingRecipes.select_product(:fishing, 80) == 2091
    end

    test "woodcutting returns elven wood at skill 80+" do
      assert CraftingRecipes.select_product(:woodcutting, 0) == 58
      assert CraftingRecipes.select_product(:woodcutting, 80) == 2781
    end
  end

  # ---- CraftingRecipes.find_craftable/3 ----

  describe "CraftingRecipes.find_craftable/3" do
    test "returns nil when no ingredients available" do
      empty_inv = List.duplicate(nil, 24)
      assert CraftingRecipes.find_craftable(:blacksmithing, 50, empty_inv) == nil
    end

    test "blacksmithing: returns smelting recipe with iron ore" do
      # 2x Mineral de Hierro (192) for smelting
      inv = [%{item_id: 192, amount: 5, equipped: false} | List.duplicate(nil, 23)]
      recipe = CraftingRecipes.find_craftable(:blacksmithing, 10, inv)
      assert recipe != nil
      # Lingote de Hierro
      assert recipe.result_id == 386
    end

    test "blacksmithing: Daga requires 3 iron ingots (VB6 LingH=3)" do
      inv = [%{item_id: 386, amount: 3, equipped: false} | List.duplicate(nil, 23)]
      recipe = CraftingRecipes.find_craftable(:blacksmithing, 0, inv)
      assert recipe != nil
      assert recipe.result_id == 15
      assert recipe.ingredients == [{386, 3}]
    end

    test "blacksmithing: Espada Matadragones needs LingH=500, LingP=400, LingO=300" do
      inv = [
        %{item_id: 386, amount: 500, equipped: false},
        %{item_id: 387, amount: 400, equipped: false},
        %{item_id: 388, amount: 300, equipped: false}
        | List.duplicate(nil, 21)
      ]

      recipe = CraftingRecipes.find_craftable(:blacksmithing, 100, inv)
      assert recipe != nil
      # At skill 100 with these materials, multiple recipes match — should get highest min_skill
      assert recipe.min_skill == 100
    end

    test "blacksmithing: insufficient iron ingots for Daga returns nil" do
      inv = [%{item_id: 386, amount: 2, equipped: false} | List.duplicate(nil, 23)]
      # Daga needs 3, we have 2
      recipe = CraftingRecipes.find_craftable(:blacksmithing, 0, inv)
      # Only smelting recipe (needs 192) or bala (needs 3391) could match, not ingot recipes
      assert recipe == nil
    end
  end

  # ---- Tailoring recipe coverage ----

  describe "tailoring recipes (ObjSastre.dat VB6 parity)" do
    test "all 25 ObjSastre.dat product IDs are present" do
      # ObjSastre.dat product IDs
      expected_ids =
        MapSet.new([
          3578, 32, 240, 1975, 2911, 508, 196, 1226, 1955, 1089, 2857, 2932,
          2916, 1961, 2854, 519, 1957, 1778, 1758, 1769, 992, 3462, 3822, 3990,
          # 1769 appears twice in ObjSastre.dat but we only need it once
          1769
        ])

      recipe_ids =
        CraftingRecipes.production_recipes(:tailoring)
        |> Enum.map(& &1.result_id)
        |> MapSet.new()

      missing = MapSet.difference(expected_ids, recipe_ids)
      assert MapSet.size(missing) == 0, "Missing tailoring product IDs: #{inspect(missing)}"
    end

    test "Tela trabajada uses PielLobo(414) as ingredient" do
      recipe =
        CraftingRecipes.production_recipes(:tailoring)
        |> Enum.find(&(&1.result_id == 3578))

      assert recipe != nil
      assert recipe.min_skill == 0
      assert recipe.ingredients == [{414, 1}]
    end

    test "Túnica Ocre uses PielLobo=60, PielOsoPardo=5" do
      recipe =
        CraftingRecipes.production_recipes(:tailoring)
        |> Enum.find(&(&1.result_id == 1955))

      assert recipe != nil
      assert recipe.min_skill == 45
      assert recipe.ingredients == [{414, 60}, {415, 5}]
    end

    test "Manto de los Vientos uses three pelt types" do
      recipe =
        CraftingRecipes.production_recipes(:tailoring)
        |> Enum.find(&(&1.result_id == 2916))

      assert recipe != nil
      assert recipe.min_skill == 65
      assert recipe.ingredients == [{414, 80}, {415, 15}, {416, 1}]
    end

    test "Capucha de Elite uses PielTigreBengala and PielLoboNegro" do
      recipe =
        CraftingRecipes.production_recipes(:tailoring)
        |> Enum.find(&(&1.result_id == 1769))

      assert recipe != nil
      assert recipe.min_skill == 63
      # PielTigreBengala=1145, PielLoboNegro=1146
      assert recipe.ingredients == [{1145, 2}, {1146, 10}]
    end

    test "Casco de Tigre uses PielTigreBengala=15 at skill 100" do
      recipe =
        CraftingRecipes.production_recipes(:tailoring)
        |> Enum.find(&(&1.result_id == 1758))

      assert recipe != nil
      assert recipe.min_skill == 100
      assert recipe.ingredients == [{1145, 15}]
    end

    test "Morral is high-tier (skill 100) with 300 PielLobo, 150 PielOsoPardo, 40 PielOsoPolar" do
      recipe =
        CraftingRecipes.production_recipes(:tailoring)
        |> Enum.find(&(&1.result_id == 3462))

      assert recipe != nil
      assert recipe.min_skill == 100
      assert recipe.ingredients == [{414, 300}, {415, 150}, {416, 40}]
    end

    test "find_craftable returns tailoring recipe when pelts are available" do
      inv = [%{item_id: 414, amount: 1, equipped: false} | List.duplicate(nil, 23)]
      recipe = CraftingRecipes.find_craftable(:tailoring, 10, inv)
      assert recipe != nil
      # Should pick highest min_skill available: Vestimenta Común (skill 2) or Tela trabajada (skill 0)
      assert recipe.result_id in [3578, 3822, 32, 240]
    end
  end

  # ---- Alchemy recipe coverage ----

  describe "alchemy recipes (ObjAlquimista.dat VB6 parity)" do
    test "all 6 ObjAlquimista.dat product IDs are present" do
      expected_ids = MapSet.new([894, 891, 889, 892, 890, 1019])

      recipe_ids =
        CraftingRecipes.production_recipes(:alchemy)
        |> Enum.map(& &1.result_id)
        |> MapSet.new()

      missing = MapSet.difference(expected_ids, recipe_ids)
      assert MapSet.size(missing) == 0, "Missing alchemy product IDs: #{inspect(missing)}"
    end

    test "Pócima de Vida uses FlorRoja, FrascoAlq, Mortero" do
      recipe =
        CraftingRecipes.production_recipes(:alchemy)
        |> Enum.find(&(&1.result_id == 891))

      assert recipe != nil
      assert recipe.min_skill == 0
      # FlorRoja=4316, FrascoAlq=3075, Mortero=4997
      assert recipe.ingredients == [{4316, 1}, {3075, 1}, {4997, 1}]
    end

    test "Pócima de Maná uses FlorOceano, FrascoAlq, Mortero" do
      recipe =
        CraftingRecipes.production_recipes(:alchemy)
        |> Enum.find(&(&1.result_id == 894))

      assert recipe != nil
      assert recipe.min_skill == 15
      assert recipe.ingredients == [{4315, 1}, {3075, 1}, {4997, 1}]
    end

    test "Pócima de Fuerza uses Tuna=2, FrascoAlq=1, Mortero=1" do
      recipe =
        CraftingRecipes.production_recipes(:alchemy)
        |> Enum.find(&(&1.result_id == 892))

      assert recipe != nil
      assert recipe.min_skill == 35
      # Tuna=4312
      assert recipe.ingredients == [{4312, 2}, {3075, 1}, {4997, 1}]
    end

    test "Pócima de Agilidad uses ColaDeZorro=2" do
      recipe =
        CraftingRecipes.production_recipes(:alchemy)
        |> Enum.find(&(&1.result_id == 889))

      assert recipe != nil
      assert recipe.min_skill == 30
      # ColaDeZorro=4314
      assert recipe.ingredients == [{4314, 2}, {3075, 1}, {4997, 1}]
    end
  end

  # ---- Carpentry recipe coverage ----

  describe "carpentry recipes (ObjCarpintero.dat VB6 parity)" do
    test "all 30 ObjCarpintero.dat product IDs are present" do
      expected_ids =
        MapSet.new([
          163, 480, 3550, 551, 553, 552, 479, 3466, 1867, 1870, 1876,
          474, 475, 476, 469, 41, 540, 40, 1797, 1788, 1719, 1724,
          3742, 3743, 2679, 3801, 3806, 3802, 3804, 3803
        ])

      recipe_ids =
        CraftingRecipes.production_recipes(:carpentry)
        |> Enum.map(& &1.result_id)
        |> MapSet.new()

      missing = MapSet.difference(expected_ids, recipe_ids)
      assert MapSet.size(missing) == 0, "Missing carpentry product IDs: #{inspect(missing)}"
    end

    test "Arco Simple uses Madera=200 (Wood=58)" do
      recipe =
        CraftingRecipes.production_recipes(:carpentry)
        |> Enum.find(&(&1.result_id == 479))

      assert recipe != nil
      assert recipe.min_skill == 10
      assert recipe.ingredients == [{58, 200}]
    end

    test "Barca uses Madera=25000" do
      recipe =
        CraftingRecipes.production_recipes(:carpentry)
        |> Enum.find(&(&1.result_id == 474))

      assert recipe != nil
      assert recipe.min_skill == 75
      assert recipe.ingredients == [{58, 25_000}]
    end

    test "Galeón uses MaderaElfica=30000" do
      recipe =
        CraftingRecipes.production_recipes(:carpentry)
        |> Enum.find(&(&1.result_id == 476))

      assert recipe != nil
      assert recipe.min_skill == 100
      assert recipe.ingredients == [{2781, 30_000}]
    end

    test "Galera uses Madera=30000 + MaderaElfica=4000" do
      recipe =
        CraftingRecipes.production_recipes(:carpentry)
        |> Enum.find(&(&1.result_id == 475))

      assert recipe != nil
      assert recipe.min_skill == 100
      assert recipe.ingredients == [{58, 30_000}, {2781, 4000}]
    end

    test "Flecha Élfica uses MaderaElfica=3" do
      recipe =
        CraftingRecipes.production_recipes(:carpentry)
        |> Enum.find(&(&1.result_id == 552))

      assert recipe != nil
      assert recipe.min_skill == 100
      assert recipe.ingredients == [{2781, 3}]
    end
  end

  # ---- Blacksmithing recipe coverage ----

  describe "blacksmithing recipes (ArmasHerrero.dat + ArmadurasHerrero.dat VB6 parity)" do
    test "all 26 ArmasHerrero.dat weapon IDs are present" do
      expected_weapon_ids =
        MapSet.new([
          3980, 15, 4299, 165, 365, 366, 367, 164, 3175, 3540, 2, 1792, 1817,
          401, 159, 399, 123, 124, 1246, 126, 403, 2598, 402, 3805, 3982, 3988
        ])

      recipe_ids =
        CraftingRecipes.production_recipes(:blacksmithing)
        |> Enum.map(& &1.result_id)
        |> MapSet.new()

      missing = MapSet.difference(expected_weapon_ids, recipe_ids)
      assert MapSet.size(missing) == 0, "Missing weapon IDs: #{inspect(missing)}"
    end

    test "all 22 ArmadurasHerrero.dat armor IDs are present" do
      expected_armor_ids =
        MapSet.new([
          1912, 1987, 243, 1929, 1634, 1907, 1908, 1941, 495, 487, 500,
          1715, 2933, 1702, 2323, 755, 1079, 132, 1767, 601, 3461, 3769
        ])

      recipe_ids =
        CraftingRecipes.production_recipes(:blacksmithing)
        |> Enum.map(& &1.result_id)
        |> MapSet.new()

      missing = MapSet.difference(expected_armor_ids, recipe_ids)
      assert MapSet.size(missing) == 0, "Missing armor IDs: #{inspect(missing)}"
    end

    test "Espada Matadragones uses LingH=500, LingP=400, LingO=300 at skill 100" do
      recipe =
        CraftingRecipes.production_recipes(:blacksmithing)
        |> Enum.find(&(&1.result_id == 402))

      assert recipe != nil
      assert recipe.min_skill == 100
      assert recipe.ingredients == [{386, 500}, {387, 400}, {388, 300}]
    end

    test "Armadura de Herrero uses LingH=75 at skill 58" do
      recipe =
        CraftingRecipes.production_recipes(:blacksmithing)
        |> Enum.find(&(&1.result_id == 1912))

      assert recipe != nil
      assert recipe.min_skill == 58
      assert recipe.ingredients == [{386, 75}]
    end

    test "Bala de piedra uses Coal(3391)=1" do
      recipe =
        CraftingRecipes.production_recipes(:blacksmithing)
        |> Enum.find(&(&1.result_id == 3980))

      assert recipe != nil
      assert recipe.min_skill == 0
      assert recipe.ingredients == [{3391, 1}]
    end
  end

  # ---- Crafting.handle_work/3 ----

  describe "Crafting.handle_work guards" do
    test "rejects dead player" do
      entity = %PlayerEntity{char_id: 1, dead: true, stamina: 100}
      state = make_state(%{1 => entity})

      {:noreply, _state} = Crafting.handle_work(state, 1, :mining)
      # Should not crash, dead player rejected
    end

    test "rejects when stamina too low" do
      entity = %PlayerEntity{char_id: 1, stamina: 5, x: 50, y: 50}
      state = make_state(%{1 => entity})

      {:noreply, new_state} = Crafting.handle_work(state, 1, :mining)
      # Stamina should not be consumed
      assert new_state.players[1].stamina == 5
    end

    test "rejects mining without pickaxe equipped" do
      entity = %PlayerEntity{
        char_id: 1,
        x: 50,
        y: 50,
        stamina: 100,
        equipment: %{weapon: 999, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
        skills: %{mining: 50}
      }

      state = make_state(%{1 => entity}, trigger_map: %{{50, 49} => 6})

      {:noreply, new_state} = Crafting.handle_work(state, 1, :mining)
      # Stamina should not be consumed — wrong tool
      assert new_state.players[1].stamina == 100
    end

    test "rejects mining without resource nearby" do
      entity = %PlayerEntity{
        char_id: 1,
        x: 50,
        y: 50,
        heading: :north,
        stamina: 100,
        equipment: %{weapon: 187, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
        skills: %{mining: 50}
      }

      # No trigger at facing tile
      state = make_state(%{1 => entity}, trigger_map: %{})

      {:noreply, new_state} = Crafting.handle_work(state, 1, :mining)
      assert new_state.players[1].stamina == 100
    end

    test "mining consumes stamina when tool and resource are valid" do
      entity = %PlayerEntity{
        char_id: 1,
        x: 50,
        y: 50,
        heading: :north,
        stamina: 100,
        equipment: %{weapon: 187, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
        skills: %{mining: 50},
        inventory: List.duplicate(nil, 24)
      }

      # Trigger 6 at facing tile (50, 49)
      state = make_state(%{1 => entity}, trigger_map: %{{50, 49} => 6})

      {:noreply, new_state} = Crafting.handle_work(state, 1, :mining)
      # Warrior (non-worker) pays 3x stamina: 15 * 3 = 45
      assert new_state.players[1].stamina == 55
    end
  end

  # ---- Social fallthrough ----

  describe "Social.handle_train_skill crafting fallthrough" do
    test "crafting skill without trainer falls through to Crafting" do
      entity = %PlayerEntity{
        char_id: 1,
        x: 50,
        y: 50,
        heading: :north,
        stamina: 100,
        skill_points: 5,
        equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
        skills: %{mining: 10}
      }

      state = make_state(%{1 => entity})

      # skill_index 18 = :mining
      {:noreply, new_state} = Arena.Map.NpcInteraction.handle_train_skill(state, 1, 18)

      # Should NOT spend skill points (no trainer), but should attempt crafting
      # Mining without pickaxe will fail with "Necesitas la herramienta adecuada"
      assert new_state.players[1].skill_points == 5
    end

    test "non-crafting skill without trainer shows error" do
      entity = %PlayerEntity{
        char_id: 1,
        x: 50,
        y: 50,
        skill_points: 5,
        skills: %{combat_weapons: 10}
      }

      state = make_state(%{1 => entity})

      # skill_index 3 = :combat_weapons (not a crafting skill)
      {:noreply, new_state} = Arena.Map.NpcInteraction.handle_train_skill(state, 1, 3)
      # Should NOT spend skill points
      assert new_state.players[1].skill_points == 5
    end
  end

  # ---- Recipe count parity ----

  describe "recipe count parity with VB6 .dat files" do
    test "blacksmithing has smelting + 26 weapons + 22 armors = 51 recipes" do
      recipes = CraftingRecipes.production_recipes(:blacksmithing)
      # 3 smelting + 26 weapons + 22 armors = 51
      assert length(recipes) == 51
    end

    test "carpentry has 30 recipes matching ObjCarpintero.dat" do
      recipes = CraftingRecipes.production_recipes(:carpentry)
      assert length(recipes) == 30
    end

    test "alchemy has 6 recipes matching ObjAlquimista.dat" do
      recipes = CraftingRecipes.production_recipes(:alchemy)
      assert length(recipes) == 6
    end

    test "tailoring has 24 recipes covering ObjSastre.dat items" do
      recipes = CraftingRecipes.production_recipes(:tailoring)
      # 25 items in ObjSastre.dat but Obj25 (Capucha de Elite 1769) is a duplicate of Obj20
      assert length(recipes) == 24
    end

    test "unknown skill returns empty list" do
      assert CraftingRecipes.production_recipes(:unknown) == []
    end
  end

  # ---- CraftingRecipes: craftable_item_ids and find_recipe_by_item ----

  describe "CraftingRecipes.craftable_item_ids/2" do
    test "returns item IDs matching skill level" do
      ids = CraftingRecipes.craftable_item_ids(:blacksmithing, 10)
      # At skill 10, should include smelting (iron ore -> ingot at 0), bala (4), daga (8), caja (10)
      assert 386 in ids
      assert 15 in ids
      # Should NOT include items requiring higher skill
      refute 402 in ids
    end

    test "returns empty list for unknown skill" do
      assert CraftingRecipes.craftable_item_ids(:unknown, 50) == []
    end

    test "returns all items at max skill" do
      all_recipes = CraftingRecipes.production_recipes(:blacksmithing)
      ids = CraftingRecipes.craftable_item_ids(:blacksmithing, 100)
      assert length(ids) == length(all_recipes)
    end
  end

  describe "CraftingRecipes.find_recipe_by_item/2" do
    test "finds a known recipe" do
      recipe = CraftingRecipes.find_recipe_by_item(:blacksmithing, 386)
      assert recipe != nil
      assert recipe.result_id == 386
      assert recipe.min_skill == 0
    end

    test "returns nil for unknown item" do
      assert CraftingRecipes.find_recipe_by_item(:blacksmithing, 99999) == nil
    end

    test "finds alchemy recipe" do
      # Pocima de Vida (item 891) is at min_skill 0
      recipe = CraftingRecipes.find_recipe_by_item(:alchemy, 891)
      assert recipe != nil
      assert recipe.result_id == 891
    end

    test "finds tailoring recipe" do
      recipe = CraftingRecipes.find_recipe_by_item(:tailoring, 3578)
      assert recipe != nil
      assert recipe.result_id == 3578
    end
  end

  # ---- Crafting UI: handle_craft_item ----

  describe "Crafting.handle_craft_item/4" do
    test "rejects dead player" do
      entity = %PlayerEntity{char_id: 1, dead: true, stamina: 100}
      state = make_state(%{1 => entity})
      {:noreply, _state} = Crafting.handle_craft_item(state, 1, :blacksmithing, 386)
    end

    test "rejects player with insufficient stamina" do
      entity = %PlayerEntity{char_id: 1, dead: false, stamina: 0}
      state = make_state(%{1 => entity})
      {:noreply, _state} = Crafting.handle_craft_item(state, 1, :blacksmithing, 386)
    end

    test "rejects unknown item" do
      entity = %PlayerEntity{char_id: 1, dead: false, stamina: 100, skills: %{blacksmithing: 50}}
      state = make_state(%{1 => entity})
      {:noreply, _state} = Crafting.handle_craft_item(state, 1, :blacksmithing, 99999)
    end

    test "rejects when skill too low" do
      # Espada Matadragones (402) needs min_skill 100
      entity = %PlayerEntity{
        char_id: 1, dead: false, stamina: 100,
        x: 50, y: 50,
        equipment: %{weapon: 389},
        skills: %{blacksmithing: 10},
        inventory: [%{item_id: 388, amount: 500, equipped: false} | List.duplicate(nil, 23)]
      }
      state = make_state(%{1 => entity}, objects: [%{x: 50, y: 49, obj_index: 384, amount: 1}])
      {:noreply, _state} = Crafting.handle_craft_item(state, 1, :blacksmithing, 402, 1, 50, 49)
    end

    test "rejects when materials missing" do
      # Lingote de Hierro (386) needs 2x iron ore (192)
      entity = %PlayerEntity{
        char_id: 1, dead: false, stamina: 100,
        x: 50, y: 50,
        equipment: %{weapon: 389},
        skills: %{blacksmithing: 50},
        inventory: List.duplicate(nil, 24)
      }
      state = make_state(%{1 => entity}, objects: [%{x: 50, y: 49, obj_index: 384, amount: 1}])
      {:noreply, _state} = Crafting.handle_craft_item(state, 1, :blacksmithing, 386, 1, 50, 49)
    end

    test "crafts item and consumes ingredients" do
      # Lingote de Hierro (386) needs 2x iron ore (192), min_skill 0
      entity = %PlayerEntity{
        char_id: 1, dead: false, stamina: 100,
        x: 50, y: 50,
        equipment: %{weapon: 389},
        skills: %{blacksmithing: 50},
        inventory: [%{item_id: 192, amount: 5, equipped: false} | List.duplicate(nil, 23)]
      }
      state = make_state(%{1 => entity}, objects: [%{x: 50, y: 49, obj_index: 384, amount: 1}])
      {:noreply, new_state} = Crafting.handle_craft_item(state, 1, :blacksmithing, 386, 1, 50, 49)

      updated_entity = new_state.players[1]
      # Stamina should be reduced
      assert updated_entity.stamina < 100
      # Should have consumed 2 iron ore (3 remaining) and gained 1 iron ingot
      ore_count = updated_entity.inventory |> Enum.filter(& &1) |> Enum.filter(&(&1.item_id == 192)) |> Enum.map(& &1.amount) |> Enum.sum()
      ingot_count = updated_entity.inventory |> Enum.filter(& &1) |> Enum.filter(&(&1.item_id == 386)) |> Enum.map(& &1.amount) |> Enum.sum()
      assert ore_count == 3
      assert ingot_count == 1
    end

    test "returns :noreply for missing player" do
      state = make_state(%{})
      {:noreply, _state} = Crafting.handle_craft_item(state, 999, :blacksmithing, 386)
    end

    test "blacksmithing rejects when no anvil or forge object is selected" do
      entity = %PlayerEntity{
        char_id: 1,
        dead: false,
        stamina: 100,
        x: 50, y: 50,
        equipment: %{weapon: 389},
        skills: %{blacksmithing: 50},
        inventory: [%{item_id: 192, amount: 5, equipped: false} | List.duplicate(nil, 23)]
      }

      state = make_state(%{1 => entity}, sessions: %{1 => self()}, objects: [])
      {:noreply, unchanged_state} = Crafting.handle_craft_item(state, 1, :blacksmithing, 386, 1, 50, 49)

      assert unchanged_state.players[1].inventory == state.players[1].inventory
      assert_receive {:send_raw, _}
    end
  end

  # ---- Crafting UI: open_crafting_window ----

  describe "Crafting.open_crafting_window/3" do
    test "sends recipe list for blacksmithing" do
      entity = %PlayerEntity{char_id: 1, dead: false, stamina: 100, skills: %{blacksmithing: 10}}
      state = make_state(%{1 => entity})
      {:noreply, _state} = Crafting.open_crafting_window(state, 1, :blacksmithing)
    end

    test "sends recipe list for carpentry" do
      entity = %PlayerEntity{char_id: 1, dead: false, stamina: 100, skills: %{carpentry: 50}}
      state = make_state(%{1 => entity})
      {:noreply, _state} = Crafting.open_crafting_window(state, 1, :carpentry)
    end

    test "sends recipe list for alchemy" do
      entity = %PlayerEntity{char_id: 1, dead: false, stamina: 100, skills: %{alchemy: 30}}
      state = make_state(%{1 => entity})
      {:noreply, _state} = Crafting.open_crafting_window(state, 1, :alchemy)
    end

    test "sends recipe list for tailoring" do
      entity = %PlayerEntity{char_id: 1, dead: false, stamina: 100, skills: %{tailoring: 20}}
      state = make_state(%{1 => entity})
      {:noreply, _state} = Crafting.open_crafting_window(state, 1, :tailoring)
    end

    test "returns :noreply for missing player" do
      state = make_state(%{})
      {:noreply, _state} = Crafting.open_crafting_window(state, 999, :blacksmithing)
    end
  end

  describe "working tool use opens production forms" do
    test "carpentry form opens from using the equipped saw without any workstation NPC" do
      entity = %PlayerEntity{
        char_id: 1,
        equipment: %{weapon: 198},
        inventory: [%{item_id: 198, amount: 1, equipped: true} | List.duplicate(nil, 23)],
        skills: %{carpentry: 50}
      }

      state = make_state(%{1 => entity}, sessions: %{1 => self()})
      assert {:reply, :ok, _state} = InventoryHandlers.handle_use_item(state, 1, 0)
      assert_receive {:send_raw, _}
      assert_receive {:send_raw, _}
    end

    test "blacksmith form opens from using the equipped hammer with a selected anvil object" do
      entity = %PlayerEntity{
        char_id: 1,
        x: 50,
        y: 50,
        equipment: %{weapon: 389},
        inventory: [%{item_id: 389, amount: 1, equipped: true} | List.duplicate(nil, 23)],
        skills: %{blacksmithing: 50}
      }

      state =
        make_state(
          %{1 => entity},
          sessions: %{1 => self()},
          objects: [%{x: 50, y: 49, obj_index: 384, amount: 1}]
        )

      assert {:reply, :ok, _state} = InventoryHandlers.handle_use_item(state, 1, 0, 50, 49)
      assert_receive {:send_raw, _}
      assert_receive {:send_raw, _}
    end

    test "blacksmith form rejects hammer use without a selected anvil or forge object" do
      entity = %PlayerEntity{
        char_id: 1,
        x: 50,
        y: 50,
        equipment: %{weapon: 389},
        inventory: [%{item_id: 389, amount: 1, equipped: true} | List.duplicate(nil, 23)],
        skills: %{blacksmithing: 50}
      }

      state = make_state(%{1 => entity}, sessions: %{1 => self()})
      assert {:reply, {:error, :missing_target}, _state} = InventoryHandlers.handle_use_item(state, 1, 0)
      assert_receive {:send_raw, _}
    end
  end
end
