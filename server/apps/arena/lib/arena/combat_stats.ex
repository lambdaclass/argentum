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

  @doc """
  Get shield defense percentage from equipped shield.
  Returns integer percentage or 0 if no shield.
  """
  def shield_defense_pct(equipment) do
    case Map.get(equipment, :shield) do
      nil ->
        0

      item_id ->
        case GameData.get_item(item_id) do
          nil -> 0
          item_def -> item_def.porcentaje
        end
    end
  end

  @doc """
  Compute equipment hit bonus (Drift #2).

  VB6 ref: Modulo_UsUaRiOs.bas GetHitBonus (line 3061-3062)
  GetHitBonus = User.Modifiers.HitBonus + GetWeaponHitBonus(WeaponIndex, UserClass)

  For now, sums hit_bonus from all equipped items that have it.
  User.Modifiers.HitBonus comes from buff effects (not equipment),
  so equipment_hit_bonus only covers the item-based bonuses.
  Returns integer.
  """
  def equipment_hit_bonus(equipment) do
    sum_item_field(equipment, [:weapon, :armor, :shield, :helmet, :ring], :hit_bonus)
  end

  @doc """
  Compute equipment evasion bonus (Drift #2).

  VB6 ref: Modulo_UsUaRiOs.bas GetEvasionBonus (line 3057-3058)
  GetEvasionBonus = User.Modifiers.EvasionBonus

  Sums evasion_bonus from all equipped items that have it.
  Returns integer.
  """
  def equipment_evasion_bonus(equipment) do
    sum_item_field(equipment, [:weapon, :armor, :shield, :helmet, :ring], :evasion_bonus)
  end

  @doc """
  Compute equipment defense bonus (Drift #7).

  VB6 ref: Modulo_UsUaRiOs.bas GetDefenseBonus (line 3141-3142)
  GetDefenseBonus = UserList(UserIndex).Modifiers.DefenseBonus

  Sums defense_bonus from all equipped items.
  Returns integer.
  """
  def equipment_defense_bonus(equipment) do
    sum_item_field(equipment, [:weapon, :armor, :shield, :helmet, :ring], :defense_bonus)
  end

  @doc """
  Get weapon's ImprovedMeleeHitChance or ImprovedRangedHitChance (Drift #2).

  VB6 ref: SistemaCombate.bas UsuarioImpacto (line 996-1003)
  Returns integer bonus to hit chance.
  """
  def weapon_hit_modifier(equipment, attack_type) do
    case Map.get(equipment, :weapon) do
      nil ->
        0

      item_id ->
        case GameData.get_item(item_id) do
          nil ->
            0

          item_def ->
            case attack_type do
              :melee -> Map.get(item_def, :improved_melee_hit_chance, 0)
              :ranged -> Map.get(item_def, :improved_ranged_hit_chance, 0)
              _ -> 0
            end
        end
    end
  end

  @doc """
  Get weapon's ExtraCritAndStabChance (Drift #4).
  Returns integer extra chance.
  """
  def weapon_extra_crit_chance(equipment) do
    case Map.get(equipment, :weapon) do
      nil ->
        0

      item_id ->
        case GameData.get_item(item_id) do
          nil -> 0
          item_def -> Map.get(item_def, :extra_crit_and_stab_chance, 0)
        end
    end
  end

  @doc """
  Get weapon type atom from equipped weapon (Drift #4).
  Returns weapon_type integer or 0 if unarmed.
  """
  def weapon_type(equipment) do
    case Map.get(equipment, :weapon) do
      nil ->
        0

      item_id ->
        case GameData.get_item(item_id) do
          nil -> 0
          item_def -> item_def.weapon_type
        end
    end
  end

  # Sum a field across multiple equipment slots
  defp sum_item_field(equipment, slots, field) do
    Enum.reduce(slots, 0, fn slot, acc ->
      case Map.get(equipment, slot) do
        nil ->
          acc

        item_id ->
          case GameData.get_item(item_id) do
            nil -> acc
            item_def -> acc + Map.get(item_def, field, 0)
          end
      end
    end)
  end

  @doc """
  VB6: Compute magic damage bonus, absolute bonus, and penetration from
  an equipment slot. Returns {damage_bonus_pct, absolute_bonus, penetration}.
  """
  def magic_bonuses_for_slot(equipment, slot) do
    case Map.get(equipment, slot) do
      nil ->
        {0, 0, 0}

      item_id ->
        case GameData.get_item(item_id) do
          nil ->
            {0, 0, 0}

          item_def ->
            {item_def.magic_damage_bonus, item_def.magic_absolute_bonus, item_def.magic_penetration}
        end
    end
  end

  @doc """
  VB6: Compute total magic bonuses from attacker equipment (weapon + ring).
  Returns {total_damage_bonus_pct, total_absolute_bonus, total_penetration}.
  """
  def total_magic_bonuses(equipment) do
    {w_pct, w_abs, w_pen} = magic_bonuses_for_slot(equipment, :weapon)
    {r_pct, r_abs, r_pen} = magic_bonuses_for_slot(equipment, :ring)
    {w_pct + r_pct, w_abs + r_abs, w_pen + r_pen}
  end

  @doc """
  VB6: GetUserMR — compute equipment-based magic resistance for a player.
  Sums ResistenciaMagica from armor, ring, shield, and helmet, then adds
  100 * class magic resistance modifier.
  """
  def get_user_mr(equipment, class_id) do
    armor_mr = item_magic_resistance(equipment, :armor)
    ring_mr = item_magic_resistance(equipment, :ring)
    shield_mr = item_magic_resistance(equipment, :shield)
    helmet_mr = item_magic_resistance(equipment, :helmet)

    class_mr = trunc(100 * GameData.class_magic_resistance_mod(class_id))

    armor_mr + ring_mr + shield_mr + helmet_mr + class_mr
  end

  defp item_magic_resistance(equipment, slot) do
    case Map.get(equipment, slot) do
      nil ->
        0

      item_id ->
        case GameData.get_item(item_id) do
          nil -> 0
          item_def -> item_def.resistencia_magica
        end
    end
  end
end
