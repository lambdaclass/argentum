defmodule Arena.Combat do
  @moduledoc """
  Pure combat formula functions. No side effects.
  Implements AO20 combat mechanics from SistemaCombate.bas.
  """

  alias Arena.Data.GameData

  @doc """
  Compute hit chance for player melee attack.
  Returns integer 5..95.

  attack_power = (skill + 3 * skill / 100 * agi) * class_mod + 2.5 * max(level - 12, 0)
  evasion = (tactics + 3 * tactics / 100 * agi) * class_mod + 2.5 * max(level - 12, 0)
  hit_chance = clamp(50 + (attack_power - evasion) * 0.4, 5, 95)
  """
  def hit_chance(atk_skill, atk_agi, atk_level, atk_class_id,
                 def_tactics, def_agi, def_level, def_class_id) do
    atk_mod = GameData.class_attack_mod(atk_class_id)
    def_mod = GameData.class_evasion_mod(def_class_id)

    attack_power = (atk_skill + 3 * atk_skill / 100 * atk_agi) * atk_mod + 2.5 * max(atk_level - 12, 0)
    evasion = (def_tactics + 3 * def_tactics / 100 * def_agi) * def_mod + 2.5 * max(def_level - 12, 0)

    round(50 + (attack_power - evasion) * 0.4) |> clamp(5, 95)
  end

  @doc """
  Compute melee weapon damage.
  damage = (3 * random(weapon_min, weapon_max) + weapon_max * 0.2 * max(0, str - 15)) * class_mod
  Returns integer >= 1.
  """
  def melee_damage(weapon_min, weapon_max, str, class_id) do
    dmg_mod = GameData.class_damage_mod(class_id)
    weapon_dmg = if weapon_max > weapon_min, do: Enum.random(weapon_min..weapon_max), else: weapon_min
    raw = (3 * weapon_dmg + weapon_max * 0.2 * max(0, str - 15)) * dmg_mod
    max(round(raw), 1)
  end

  @doc """
  Apply defense reduction. Random hit location: 1/6 head (helmet only), 5/6 body (armor + shield).
  Returns {reduced_damage, hit_location}.
  """
  def apply_defense(raw_damage, {min_def, max_def}) do
    defense = if max_def > min_def, do: Enum.random(min_def..max_def), else: min_def
    location = if Enum.random(1..6) == 1, do: :head, else: :body
    {max(raw_damage - defense, 0), location}
  end

  @doc """
  Check if attack is blocked by shield.
  block_chance = clamp(shield_pct * def_skill / max(def_skill + tactics, 1), 10, 90)
  Returns boolean.
  """
  def shield_block?(shield_pct, defense_skill, attacker_tactics) when shield_pct > 0 do
    chance = round(shield_pct * defense_skill / max(defense_skill + attacker_tactics, 1))
    chance = clamp(chance, 10, 90)
    Enum.random(1..100) <= chance
  end
  def shield_block?(_shield_pct, _defense_skill, _tactics), do: false

  @doc """
  XP gained from dealing damage to an NPC.
  xp = (damage * npc_give_exp) / max(npc_max_hp, 1)
  Level delta penalty: if player_level - npc_level > 4, XP halved per extra level.
  """
  def xp_gain(damage, npc_give_exp, npc_max_hp, player_level, npc_level) do
    base = div(damage * npc_give_exp, max(npc_max_hp, 1))
    level_diff = player_level - npc_level

    if level_diff > 4 do
      penalty = :math.pow(0.5, level_diff - 4)
      max(round(base * penalty), 0)
    else
      max(base, 0)
    end
  end

  @doc """
  Spell damage calculation.
  damage = random(min_hp, max_hp) + floor(random(min_hp, max_hp) * 0.03 * caster_level)
  Mages get 0.7x modifier.
  """
  def spell_damage(min_hp, max_hp, caster_level, is_mage) do
    base = if max_hp > min_hp, do: Enum.random(min_hp..max_hp), else: min_hp
    level_bonus = floor(base * 0.03 * caster_level)
    total = base + level_bonus
    if is_mage, do: round(total * 0.7), else: total
  end

  @doc """
  Apply magic resistance to spell damage.
  reduced = damage - damage * (resistance_pct / 100)
  """
  def apply_magic_resistance(damage, resistance_pct) when resistance_pct > 0 do
    max(round(damage * (1 - resistance_pct / 100)), 0)
  end
  def apply_magic_resistance(damage, _), do: damage

  @doc """
  NPC melee hit chance. NPCs use PoderAtaque directly.
  hit_chance = clamp(50 + (poder_ataque - evasion) * 0.4, 5, 95)
  """
  def npc_hit_chance(poder_ataque, def_tactics, def_agi, def_level, def_class_id) do
    def_mod = GameData.class_evasion_mod(def_class_id)
    evasion = (def_tactics + 3 * def_tactics / 100 * def_agi) * def_mod + 2.5 * max(def_level - 12, 0)
    round(50 + (poder_ataque - evasion) * 0.4) |> clamp(5, 95)
  end

  @doc "NPC damage roll between min and max hit."
  def npc_damage(min_hit, max_hit) do
    if max_hit > min_hit, do: Enum.random(min_hit..max_hit), else: max(min_hit, 1)
  end

  defp clamp(val, min_val, max_val), do: min(max(val, min_val), max_val)
end
