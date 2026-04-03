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
  VB6: damage = (3 * WeaponDamage + MaxWeaponDamage * 0.2 * max(0, Fuerza - 15) + UserDamage) * ClassModifier
  user_min/user_max are the character's base MinHIT/MaxHit from level/class.
  Returns integer >= 1.
  """
  def melee_damage(weapon_min, weapon_max, str, class_id, user_min \\ 0, user_max \\ 0) do
    dmg_mod = GameData.class_damage_mod(class_id)
    weapon_dmg = if weapon_max > weapon_min, do: Enum.random(weapon_min..weapon_max), else: weapon_min
    user_dmg = if user_max > user_min, do: Enum.random(user_min..user_max), else: user_min
    raw = (3 * weapon_dmg + weapon_max * 0.2 * max(0, str - 15) + user_dmg) * dmg_mod
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
  @xp_penalty_per_level 0.1

  def xp_gain(damage, npc_give_exp, npc_max_hp, player_level, npc_level) do
    base = div(damage * npc_give_exp, max(npc_max_hp, 1))
    level_diff = player_level - npc_level

    if level_diff > 4 do
      # VB6: linear penalty = 1 - (PenaltyExpUserPerLevel * extra_levels)
      penalty = max(1.0 - @xp_penalty_per_level * (level_diff - 4), 0.0)
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
    # VB6 clamps NPC hit chance to 10-90
    round(50 + (poder_ataque - evasion) * 0.4) |> clamp(10, 90)
  end

  @doc "NPC damage roll between min and max hit."
  def npc_damage(min_hit, max_hit) do
    if max_hit > min_hit, do: Enum.random(min_hit..max_hit), else: max(min_hit, 1)
  end

  @doc """
  VB6: meditating reduces evasion by 25%.
  Adjusts hit_chance upward when defender is meditating.
  """
  def adjust_hit_for_meditate(hit_chance, true) do
    miss_chance = (100 - hit_chance) * 0.75
    clamp(round(100 - miss_chance), 10, 90)
  end
  def adjust_hit_for_meditate(hit_chance, _false), do: hit_chance

  @doc """
  VB6-exact base character damage from level and class.

  GetHitModifier formula (Modulo_UsUaRiOs.bas:3152):
    level <= 36 → modifier = (level - 1) * HitPre36
    level >  36 → modifier = 35 * HitPre36 + (level - 36) * HitPost36
  MinHIT = modifier + 1, MaxHIT = modifier + 2
  """
  def base_user_damage(level, class_id) do
    pre36 = GameData.class_hit_pre36(class_id)
    post36 = GameData.class_hit_post36(class_id)

    modifier =
      if level <= 36 do
        (level - 1) * pre36
      else
        35 * pre36 + (level - 36) * post36
      end

    min_hit = modifier + 1
    max_hit = modifier + 2
    {max(min_hit, 1), max(max_hit, 2)}
  end

  defp clamp(val, min_val, max_val), do: min(max(val, min_val), max_val)
end
