defmodule Arena.Combat do
  @moduledoc """
  Pure combat formula functions. No side effects.
  Implements AO20 combat mechanics from SistemaCombate.bas.
  """

  alias Arena.Data.GameData

  @doc """
  Compute hit chance for PvP player melee attack.
  Returns integer 5..95.

  VB6 ref: SistemaCombate.bas UsuarioImpacto (line 945)
  attack_power = (skill + 3 * skill / 100 * agi) * class_mod + 2.5 * max(level - 12, 0) + hit_bonus
  evasion = (tactics + 3 * tactics / 100 * agi) * class_mod + 2.5 * max(level - 12, 0) + evasion_bonus
  hit_chance = clamp(50 + (attack_power - evasion) * 0.4, 5, 95)

  hit_bonus and evasion_bonus come from equipment/modifier bonuses (Drift #2).
  """
  def hit_chance(
        atk_skill, atk_agi, atk_level, atk_class_id,
        def_tactics, def_agi, def_level, def_class_id,
        hit_bonus \\ 0, evasion_bonus \\ 0
      ) do
    atk_mod = GameData.class_attack_mod(atk_class_id)
    def_mod = GameData.class_evasion_mod(def_class_id)

    attack_power =
      (atk_skill + 3 * atk_skill / 100 * atk_agi) * atk_mod +
        2.5 * max(atk_level - 12, 0) + hit_bonus

    evasion =
      (def_tactics + 3 * def_tactics / 100 * def_agi) * def_mod +
        2.5 * max(def_level - 12, 0) + evasion_bonus

    round(50 + (attack_power - evasion) * 0.4) |> clamp(5, 95)
  end

  @doc """
  Compute hit chance for player vs NPC attack (Drift #1).
  Returns integer 5..95.

  VB6 ref: SistemaCombate.bas UserImpactoNpc (line 242)
  VB6 uses NPC's PoderEvasion directly — no class_evasion_mod or level bonus applied
  to the NPC's evasion. The player attack_power is still computed using the player formula.

  Formula: clamp(50 + (attack_power - npc_evasion) * 0.4, 5, 95)
  """
  def hit_chance_vs_npc(atk_skill, atk_agi, atk_level, atk_class_id, npc_evasion, hit_bonus \\ 0) do
    atk_mod = GameData.class_attack_mod(atk_class_id)

    attack_power =
      (atk_skill + 3 * atk_skill / 100 * atk_agi) * atk_mod +
        2.5 * max(atk_level - 12, 0) + hit_bonus

    round(50 + (attack_power - npc_evasion) * 0.4) |> clamp(5, 95)
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
  VB6 critical hit check (Drift #4: class-gated).

  VB6 ref: SistemaCombate.bas PuedeGolpeCritico (line 2003-2013)
  Only Bandit class with Knuckle weapon (weapon_type == :knuckle) can crit.

  VB6 ref: SistemaCombate.bas GetCriticalHitChanceBase (line 2374-2385)
  Chance = wrestling_skill * BanditCriticalHitChance + weapon ExtraCritAndStabChance
  Clamped to 0..100 by ClampChance.

  Returns true if the attack is a critical hit.
  """
  # VB6: BanditCriticalHitChance from Balance.dat [BACKSTAB] section.
  # Default to 0.1 (10% at skill 100) as a reasonable value when not in data file.
  @bandit_crit_chance 0.1

  def critical_hit?(class, weapon_type, wrestling_skill, extra_crit_chance \\ 0) do
    if class == :bandido and weapon_type == :knuckle do
      chance = trunc(min(max(wrestling_skill * @bandit_crit_chance + extra_crit_chance, 0), 100))
      :rand.uniform(100) <= chance
    else
      false
    end
  end

  # VB6: CriticalHitDmgModifier from Balance.dat [EXTRA] section = 0.33
  # The critical hit adds bonus damage = base_damage * 0.33
  @crit_damage_modifier 0.33
  def apply_critical(damage), do: round(damage + damage * @crit_damage_modifier)

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
  Check if attack is blocked by shield (Drift #3: uses defender's skills).

  VB6 ref: SistemaCombate.bas UsuarioImpacto (line 985-986)
  Formula: clamp(shield_pct * def_defense_skill / max(def_defense_skill + def_tactics, 1), 10, 90)
  Uses DEFENDER's defense skill and DEFENDER's tactics (not attacker's).
  Shield block is checked AFTER a miss (second chance to block), not after a hit.

  Returns boolean.
  """
  def shield_block?(shield_pct, def_defense_skill, def_tactics) when shield_pct > 0 do
    chance = round(shield_pct * def_defense_skill / max(def_defense_skill + def_tactics, 1))
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
  Compute all stat gains for a level-up (Drift #6: constitution-aware HP).

  VB6 ref: Modulo_UsUaRiOs.bas (line 1057-1101)

  HP gain uses biased random with constitution awareness:
    PromClaseRaza = ModClase.Vida - (21 - con) * 0.5
    PromPersonaje = (max_hp - con) / (level - 1) [or PromClaseRaza at level 1]
    PromBias = PromClaseRaza + (PromClaseRaza - PromPersonaje) * DesbalancePromedioVidas
    AumentoHP = RandomIntBiased(PromClaseRaza - RangoVidas, PromClaseRaza + RangoVidas, PromBias, InfluenciaPromedioVidas)
    Plus GetMaxHp capping with CapVidaMax/CapVidaMin

  Mana is recalculated (delta of GetMaxMana between levels):
    GetMaxMana = int * ManaInicial + (MultMana * int) * (level - 1)

  Stamina is recalculated (delta of GetMaxStamina between levels):
    GetMaxStamina = 60 + (level - 1) * AumentoSta

  Accepts con and max_hp as optional params for backward compatibility.
  Old callers passing 6 args still work (con defaults to 18, max_hp to 0).
  """
  # VB6 Balance.dat [EXTRA] section constants
  @desbalance_promedio_vidas 0.0
  @rango_vidas 2.0
  @influencia_promedio_vidas 0.0
  @cap_vida_max 10.0
  @cap_vida_min -10.0

  def level_up_gains(level, class_id, int, _agi, current_xp, _rand_hp_factor, con \\ 18, max_hp \\ 0) do
    next_xp = GameData.exp_for_level(level + 1)

    if next_xp && current_xp >= next_xp do
      new_level = level + 1

      # --- HP gain (VB6 biased random) ---
      hp_mod = GameData.class_hp_mod(class_id)
      prom_clase_raza = hp_mod - (21 - con) * 0.5

      prom_personaje =
        if level <= 1 do
          prom_clase_raza
        else
          (max_hp - con) / (level - 1)
        end

      prom_bias = prom_clase_raza + (prom_clase_raza - prom_personaje) * @desbalance_promedio_vidas

      hp_gain =
        round(
          random_int_biased(
            prom_clase_raza - @rango_vidas,
            prom_clase_raza + @rango_vidas,
            prom_bias,
            @influencia_promedio_vidas
          )
        )

      # VB6: GetMaxHp = (Vida - (21 - con) * 0.5) * (level - 1) + con
      # Capping against GetMaxHp at the new level
      get_max_hp_new = trunc(prom_clase_raza * (new_level - 1) + con)
      current_max_hp = if max_hp > 0, do: max_hp, else: trunc(prom_clase_raza * (level - 1) + con)

      hp_gain =
        if current_max_hp + hp_gain > get_max_hp_new + @cap_vida_max do
          trunc(get_max_hp_new + @cap_vida_max - current_max_hp)
        else
          hp_gain
        end

      hp_gain =
        if current_max_hp + hp_gain < get_max_hp_new + @cap_vida_min do
          trunc(get_max_hp_new + @cap_vida_min - current_max_hp)
        else
          hp_gain
        end

      hp_gain = max(hp_gain, 1)

      # --- Mana gain (VB6: delta of GetMaxMana) ---
      # GetMaxMana = int * ManaInicial + (MultMana * int) * (level - 1)
      mana_initial = GameData.class_mana_initial(class_id)
      mana_mult = GameData.class_mana_mult(class_id)
      max_mana_old = trunc(int * mana_initial + mana_mult * int * (level - 1))
      max_mana_new = trunc(int * mana_initial + mana_mult * int * (new_level - 1))
      mana_gain = max_mana_new - max_mana_old

      # --- Stamina gain (VB6: delta of GetMaxStamina) ---
      # GetMaxStamina = 60 + (level - 1) * AumentoSta
      sta_growth = GameData.class_stamina_growth(class_id)
      max_sta_old = trunc(60 + (level - 1) * sta_growth)
      max_sta_new = trunc(60 + (new_level - 1) * sta_growth)
      sta_gain = max_sta_new - max_sta_old

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

  @doc """
  VB6 RandomIntBiased (General.bas:1744-1762).

  Generates a biased random value in [min, max]:
    random_range = :rand.uniform() * (max - min) + min
    mix = :rand.uniform() * influence
    result = random_range * (1 - mix) + bias * mix

  When influence is 0, result is purely random in [min, max].
  """
  def random_int_biased(min_val, max_val, bias, influence) do
    random_range = :rand.uniform() * (max_val - min_val) + min_val
    mix = :rand.uniform() * influence
    random_range * (1 - mix) + bias * mix
  end

  # ==================================================================
  # Skill gain
  # ==================================================================

  # Drift #11: VB6 SubirSkill (Modulo_UsUaRiOs.bas:1617-1670).
  # MAXSKILLPOINTS from Declares.bas:1355.
  @max_skill 100
  # Balance.dat:328 — EXTRA/DificultadSubirSkill.
  @skill_difficulty 2
  # Declares.bas:1083-1084.
  @expert_skill_cutoff 17
  @nonexpert_skill_cutoff 10

  @doc """
  VB6 SubirSkill (Modulo_UsUaRiOs.bas:1617-1670).

  Rolls a practice-based skill-up attempt. Returns `{:gain, bonus_exp}`
  on success or `:no_gain`. The caller bumps the skill value and adds
  the bonus XP.

    * `level` — actor's character level (Stats.ELV).
    * `current_skill` — current skill value (Stats.UserSkills(Skill)).
    * `expert?` — `flags.PendienteDelExperto = 1` (uses 17 cutoff; else 10).
    * `hunger`, `thirst` — Stats.MinHam / Stats.MinAGU; both must be > 0.
    * `xp_mult` — SvrConfig "ExpMult" (Arena.Settings :xp_multiplier).

  VB6 pipeline:
    1. Return if current_skill >= MAXSKILLPOINTS.
    2. Compute maxPermitido per level; return if current_skill >= maxPermitido.
    3. Return if hunger <= 0 or thirst <= 0.
    4. Prob = Int(0.1 * Lvl^2 + 15); Aumenta = rand(1, Prob * DificultadSubirSkill).
    5. Gain iff Aumenta < cutoff (17 expert / 10 non-expert).
    6. On gain, BonusExp = 5 * ExpMult.
  """
  def roll_skill_gain(level, current_skill, expert?, hunger, thirst, xp_mult) do
    cond do
      current_skill >= @max_skill -> :no_gain
      current_skill >= max_skill_for_level(level) -> :no_gain
      hunger <= 0 or thirst <= 0 -> :no_gain
      true -> do_roll_skill_gain(level, expert?, xp_mult)
    end
  end

  # VB6: maxPermitido = (Lvl \\ 2) * 5 on even levels; on odd levels
  # add (3 or 2) depending on whether the previous even-level cap ended in 0 or 5.
  defp max_skill_for_level(level) do
    if rem(level, 2) == 0 do
      div(level, 2) * 5
    else
      div(level, 2) * 5 + 3 - div(rem(div(level - 1, 2) * 5, 10), 5)
    end
  end

  defp do_roll_skill_gain(level, expert?, xp_mult) do
    prob = trunc(0.1 * level * level + 15)
    aumenta = :rand.uniform(prob * @skill_difficulty)
    cutoff = if expert?, do: @expert_skill_cutoff, else: @nonexpert_skill_cutoff

    if aumenta < cutoff do
      {:gain, trunc(5 * xp_mult)}
    else
      :no_gain
    end
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

  @doc """
  Apply full physical damage pipeline (Drift #7).

  VB6 ref: SistemaCombate.bas UserDamageToUser (line 1154-1166)
  and SistemaCombate.bas UserDamageToNpc (line 391-402)

  Pipeline:
    1. defense_total = defense + defense_bonus
    2. defense_total = max(0, defense_total - armor_penetration)
    3. damage = raw_damage - defense_total
    4. damage = damage * physical_damage_modifier (attacker)
    5. damage = damage * physical_damage_reduction (defender)
    6. damage = max(damage, 0)
  """
  def apply_physical_damage_modifiers(
        raw_damage,
        defense,
        defense_bonus,
        armor_penetration,
        damage_modifier,
        damage_reduction
      ) do
    defense_total = max(0, defense + defense_bonus - armor_penetration)
    damage = (raw_damage - defense_total) * damage_modifier * damage_reduction

    if damage < 0, do: 0, else: round(damage)
  end

  defp clamp(val, min_val, max_val), do: min(max(val, min_val), max_val)
end
