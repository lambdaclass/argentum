defmodule Arena.PotionDriftTest do
  @moduledoc """
  Regression tests for VB6 drifts in `Arena.Map.InventoryHandlers.apply_potion`.

  Drift #17 — mana potion restore uses the item's Porcentaje (percentage of
    max mana), not a flat Min/Max modificador roll.
    VB6: `InvUsuario.bas:1946-1956`
  """
  use ExUnit.Case, async: true

  alias Arena.Map.InventoryHandlers
  alias Arena.Data.ItemDef

  defp base_entity do
    %{
      hp: 10,
      max_hp: 100,
      mana: 100,
      max_mana: 1000,
      stamina: 10,
      max_stamina: 100,
      str_buff: 0,
      agi_buff: 0,
      buffs: [],
      poisoned: false,
      paralyzed: false
    }
  end

  describe "Drift #17 — mana potion uses Porcentaje of max mana (VB6 parity)" do
    test "mana potion restores porcentaje % of max_mana, not min/max modificador" do
      entity = base_entity()

      # VB6: Porcentaje is the percentage of MaxMAN to restore.
      # A potion with porcentaje=20 on a 1000-max-mana character should restore 200 mana.
      # The min/max modificador fields should NOT be used for mana potions.
      item = %ItemDef{
        tipo_pocion: 2,
        porcentaje: 20,
        # Bogus min/max to prove the formula ignores them:
        min_modificador: 1,
        max_modificador: 1
      }

      result = InventoryHandlers.apply_potion(entity, item)

      # Starting mana 100 + 20% of 1000 (=200) = 300.
      assert result.mana == 300,
             "Expected mana to go 100 -> 300 (20% of 1000 max), got #{result.mana}"
    end

    test "mana potion is clamped at max_mana" do
      entity = %{base_entity() | mana: 900, max_mana: 1000}

      item = %ItemDef{tipo_pocion: 2, porcentaje: 50, min_modificador: 0, max_modificador: 0}

      result = InventoryHandlers.apply_potion(entity, item)

      # 900 + 500 = 1400, clamped to max_mana 1000.
      assert result.mana == 1000
    end
  end
end
