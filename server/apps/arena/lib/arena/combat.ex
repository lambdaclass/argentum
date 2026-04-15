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
  def hit_chance(atk_skill, atk_agi, atk_level, atk_class_id, def_tactics, def_agi, def_level, def_class_id) do
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
  VB6 critical hit check. Chance based on weapon skill, ~10-15% at high skill.
  Returns true if the attack is a critical hit.
  """
  @crit_divisor 100
  def critical_hit?(weapon_skill) do
    chance = div(weapon_skill, @crit_divisor) * 10 + 5
    :rand.uniform(100) <= min(chance, 15)
  end

  @crit_multiplier 1.5
  def apply_critical(damage), do: round(damage * @crit_multiplier)

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

  import Bitwise

  @doc """
  Apply elemental damage modifiers (VB6: CalculateElementalTagsModifiers).

  Both attacker_tags and defender_tags are integer bitmasks where bit 0 = Fire,
  bit 1 = Water, bit 2 = Earth, bit 3 = Wind.  When both are non-zero, every
  set attacker-element / defender-element pair multiplies the accumulated damage
  by the corresponding entry in `ElementalMatrixForNpcs`.

  Returns the (possibly modified) damage as an integer >= 0.
  Inert (returns damage unchanged) when either mask is 0.
  """
  def apply_elemental_modifiers(damage, attacker_tags, defender_tags)
      when attacker_tags == 0 or defender_tags == 0 do
    damage
  end

  def apply_elemental_modifiers(damage, attacker_tags, defender_tags) do
    max_tags = GameData.max_element_tags()

    result =
      Enum.reduce(0..(max_tags - 1), damage / 1, fn atk_idx, acc ->
        atk_bit = 1 <<< atk_idx

        if (attacker_tags &&& atk_bit) != 0 do
          Enum.reduce(0..(max_tags - 1), acc, fn def_idx, inner_acc ->
            def_bit = 1 <<< def_idx

            if (defender_tags &&& def_bit) != 0 do
              # Matrix is 1-based
              inner_acc * GameData.elemental_matrix(atk_idx + 1, def_idx + 1)
            else
              inner_acc
            end
          end)
        else
          acc
        end
      end)

    max(round(result), 0)
  end

  # ==================================================================
  # Level-up stat gains
  # ==================================================================

  @doc """
  Compute all stat gains for a level-up, given the *current* entity stats and
  a random HP factor (0.0..1.0 exclusive, typically from `:rand.uniform()`).

  Returns a map with keys: `:new_level`, `:hp_gain`, `:mana_gain`, `:sta_gain`,
  `:skill_points`, `:min_hit`, `:max_hit`, `:remaining_xp`.

  VB6 formulas:
    hp_gain  = max(trunc(class_hp_mod * (0.8 + rand_factor * 0.4)), 1)
    mana_gain = trunc(int * class_mana_mult)
    sta_gain  = max(trunc(class_stamina_growth * agi / 33), 1)
  """
  def level_up_gains(level, class_id, int, agi, current_xp, rand_hp_factor) do
    next_xp = GameData.exp_for_level(level + 1)

    if next_xp && current_xp >= next_xp do
      new_level = level + 1

      hp_mod = GameData.class_hp_mod(class_id)
      hp_gain = max(trunc(hp_mod * (0.8 + rand_hp_factor * 0.4)), 1)

      mana_mult = GameData.class_mana_mult(class_id)
      mana_gain = trunc(int * mana_mult)

      sta_growth = GameData.class_stamina_growth(class_id)
      sta_gain = max(trunc(sta_growth * agi / 33), 1)

      skill_pts = GameData.class_skill_points(class_id)

      {new_min_hit, new_max_hit} = base_user_damage(new_level, class_id)

      {:level_up,
       %{
         new_level: new_level,
         hp_gain: hp_gain,
         mana_gain: mana_gain,
         sta_gain: sta_gain,
         skill_points: skill_pts,
         min_hit: new_min_hit,
         max_hit: new_max_hit,
         remaining_xp: current_xp - next_xp
       }}
    else
      :no_level_up
    end
  end

  # ==================================================================
  # Skill gain
  # ==================================================================

  @skill_gain_chance 35
  @max_skill 100

  @doc """
  Return the probability (0..100) that a skill at the given level gains a point.
  Returns 0 when the skill is already at max.

  This is the pure half of the VB6 skill-gain check; the caller rolls
  `:rand.uniform(100)` and compares against this value.
  """
  def skill_gain_probability(current_skill) do
    if current_skill < @max_skill, do: @skill_gain_chance, else: 0
  end

  @doc """
  Cap earned XP against the NPC's remaining experience pool.
  Returns `{capped_xp, new_pool}`.

  VB6: ExpCount tracks how much XP an NPC instance can still award.
  """
  def cap_xp_to_pool(xp_gained, available_pool) when xp_gained > 0 and available_pool >= 0 do
    capped = min(xp_gained, available_pool)
    {capped, available_pool - capped}
  end

  def cap_xp_to_pool(xp_gained, available_pool), do: {xp_gained, available_pool}

  defp clamp(val, min_val, max_val), do: min(max(val, min_val), max_val)
end
