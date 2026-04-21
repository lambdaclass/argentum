defmodule Arena.DivineBloodPotionTest do
  @moduledoc """
  Drift #16 — HP potion (tipo_pocion == 1) must:

  1. Reject the heal if the user has `DivineBlood` flag > 0 (no HP gain,
     divine-blood console message). VB6: `InvUsuario.bas:1923-1945`,
     message `MSG_DIVINE_BLOOD_CANNOT_MIX_WITH_MORTAL_BLOOD` (modMessageIDs.bas:1195).

  2. Multiply the rolled heal amount by `UserMod.GetSelfHealingBonus(U)`,
     which VB6 computes as `max(1 + User.Modifiers.SelfHealingBonus, 0)`
     (Modulo_UsUaRiOs.bas:3066). Default bonus is 0 -> multiplier 1.0.

  Because `apply_item_use` (the caller) must skip consumption when the gate
  fires, the divine-blood check lives there via
  `hp_potion_blocked_by_divine_blood?/2`; `apply_potion/2` still mutates HP
  and must only be invoked after that gate passes.
  """
  use ExUnit.Case, async: true

  alias Arena.Map.InventoryHandlers
  alias Arena.Data.ItemDef

  defp base_entity(overrides) do
    %{
      hp: 10,
      max_hp: 1000,
      mana: 100,
      max_mana: 1000,
      stamina: 10,
      max_stamina: 100,
      str_buff: 0,
      agi_buff: 0,
      buffs: [],
      poisoned: false,
      paralyzed: false,
      divine_blood: 0,
      self_healing_bonus: 0.0
    }
    |> Map.merge(overrides)
  end

  describe "Drift #16 — DivineBlood gate blocks HP potions" do
    test "hp_potion_blocked_by_divine_blood? returns true when flag > 0" do
      entity = base_entity(%{divine_blood: 1})
      hp_item = %ItemDef{tipo_pocion: 1, min_modificador: 10, max_modificador: 10}

      assert InventoryHandlers.hp_potion_blocked_by_divine_blood?(entity, hp_item)
    end

    test "hp_potion_blocked_by_divine_blood? is false for non-HP potion even with flag" do
      entity = base_entity(%{divine_blood: 1})
      mana_item = %ItemDef{tipo_pocion: 2, porcentaje: 10}

      refute InventoryHandlers.hp_potion_blocked_by_divine_blood?(entity, mana_item)
    end

    test "hp_potion_blocked_by_divine_blood? is false for non-divine entity" do
      entity = base_entity(%{divine_blood: 0})
      hp_item = %ItemDef{tipo_pocion: 1, min_modificador: 10, max_modificador: 10}

      refute InventoryHandlers.hp_potion_blocked_by_divine_blood?(entity, hp_item)
    end
  end

  describe "Drift #16 — SelfHealingBonus multiplier" do
    test "default entity (bonus 0.0) heals by the raw rolled amount (multiplier 1.0)" do
      entity = base_entity(%{hp: 50})
      item = %ItemDef{tipo_pocion: 1, min_modificador: 40, max_modificador: 40}

      healed = InventoryHandlers.apply_potion(entity, item)
      assert healed.hp == 90
    end

    test "bonus 0.5 multiplies the roll by 1.5" do
      entity = base_entity(%{hp: 100, self_healing_bonus: 0.5})
      item = %ItemDef{tipo_pocion: 1, min_modificador: 40, max_modificador: 40}

      healed = InventoryHandlers.apply_potion(entity, item)
      assert healed.hp == 160, "Expected 100 + round(40 * 1.5) = 160, got #{healed.hp}"
    end

    test "bonus < -1 clamps multiplier to 0 (VB6 max(1 + b, 0))" do
      entity = base_entity(%{hp: 200, self_healing_bonus: -2.0})
      item = %ItemDef{tipo_pocion: 1, min_modificador: 40, max_modificador: 40}

      healed = InventoryHandlers.apply_potion(entity, item)
      assert healed.hp == 200
    end

    test "healed hp is clamped at max_hp" do
      entity = base_entity(%{hp: 990, max_hp: 1000, self_healing_bonus: 0.0})
      item = %ItemDef{tipo_pocion: 1, min_modificador: 500, max_modificador: 500}

      healed = InventoryHandlers.apply_potion(entity, item)
      assert healed.hp == 1000
    end

    test "get_self_healing_bonus returns max(1 + bonus, 0)" do
      assert InventoryHandlers.get_self_healing_bonus(base_entity(%{self_healing_bonus: 0.0})) ==
               1

      assert InventoryHandlers.get_self_healing_bonus(base_entity(%{self_healing_bonus: 0.5})) ==
               1.5

      assert InventoryHandlers.get_self_healing_bonus(base_entity(%{self_healing_bonus: -2.0})) ==
               0
    end
  end
end
