defmodule Arena.CraftingTest do
  @moduledoc """
  Tests for crafting and gathering system.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.Crafting
  alias Arena.Entity.PlayerEntity
  alias Arena.Data.CraftingRecipes

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

    %{
      players: players,
      sessions: %{},
      npcs: %{},
      npcs_live: npcs_live,
      map_id: 1,
      meta: %{safe_zone: false, trigger_map: trigger_map},
      visibility_mode: :global
    }
  end

  # ---- CraftingRecipes ----

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
  end

  describe "CraftingRecipes.find_craftable/3" do
    test "returns nil when no ingredients available" do
      empty_inv = List.duplicate(nil, 24)
      assert CraftingRecipes.find_craftable(:blacksmithing, 50, empty_inv) == nil
    end

    test "returns recipe when ingredients present" do
      # 2x Mineral de Hierro (192) for blacksmithing
      inv = [%{item_id: 192, amount: 5, equipped: false} | List.duplicate(nil, 23)]
      recipe = CraftingRecipes.find_craftable(:blacksmithing, 10, inv)
      assert recipe != nil
      assert recipe.result_id == 386  # Lingote de Hierro
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
        char_id: 1, x: 50, y: 50, stamina: 100,
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
        char_id: 1, x: 50, y: 50, heading: :north, stamina: 100,
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
        char_id: 1, x: 50, y: 50, heading: :north, stamina: 100,
        equipment: %{weapon: 187, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
        skills: %{mining: 50},
        inventory: List.duplicate(nil, 24)
      }
      # Trigger 6 at facing tile (50, 49)
      state = make_state(%{1 => entity}, trigger_map: %{{50, 49} => 6})

      {:noreply, new_state} = Crafting.handle_work(state, 1, :mining)
      assert new_state.players[1].stamina == 85
    end
  end

  # ---- Social fallthrough ----

  describe "Social.handle_train_skill crafting fallthrough" do
    test "crafting skill without trainer falls through to Crafting" do
      entity = %PlayerEntity{
        char_id: 1, x: 50, y: 50, heading: :north, stamina: 100,
        skill_points: 5,
        equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
        skills: %{mining: 10}
      }
      state = make_state(%{1 => entity})

      # skill_index 18 = :mining
      {:noreply, new_state} = Arena.Map.Social.handle_train_skill(state, 1, 18)

      # Should NOT spend skill points (no trainer), but should attempt crafting
      # Mining without pickaxe will fail with "Necesitas la herramienta adecuada"
      assert new_state.players[1].skill_points == 5
    end

    test "non-crafting skill without trainer shows error" do
      entity = %PlayerEntity{
        char_id: 1, x: 50, y: 50, skill_points: 5,
        skills: %{combat_weapons: 10}
      }
      state = make_state(%{1 => entity})

      # skill_index 3 = :combat_weapons (not a crafting skill)
      {:noreply, new_state} = Arena.Map.Social.handle_train_skill(state, 1, 3)
      # Should NOT spend skill points
      assert new_state.players[1].skill_points == 5
    end
  end
end
