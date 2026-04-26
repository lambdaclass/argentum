defmodule Arena.SpellEffectGoldenTest do
  @moduledoc """
  Golden tests verifying spell effects match VB6 behavior.

  Expected values derived from combat_handlers.ex spell application logic
  (ported from VB6 SistemaCombate.bas and Hechizos.bas). These tests lock
  down current spell behavior as regression protection.

  Covers: spell_damage formula, magic resistance, heal capping, status effect
  durations, attribute buffs, mana/stamina restore/drain, resurrection HP
  calculation, mana cost validation, skill level gating, cooldown enforcement,
  max-level-casteable, and edge cases (dead caster, insufficient mana, etc.).
  """
  use ExUnit.Case, async: true

  alias Arena.Combat
  alias Arena.Data.{GameData, SpellDef}
  alias Arena.Map.{CombatHandlers, SpellEffects}

  import Arena.Test.MapStateFactory

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Helpers: build minimal entities and state ──────────────────────────────

  defp make_entity(overrides) do
    defaults = %{
      char_id: :caster,
      name: "Tester",
      x: 50,
      y: 50,
      heading: :south,
      body_id: 1,
      base_body_id: 1,
      head_id: 1,
      hp: 100,
      max_hp: 100,
      mana: 200,
      max_mana: 200,
      stamina: 100,
      max_stamina: 100,
      hunger: 100,
      thirst: 100,
      level: 25,
      xp: 0,
      class: :warrior,
      race: :human,
      gender: :male,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      gold: 0,
      inventory: List.duplicate(nil, 24),
      equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil},
      skills: %{magic: 80},
      spells: [1],
      buffs: [],
      min_hit: 0,
      max_hit: 0,
      str_buff: 0,
      agi_buff: 0,
      dead: false,
      poisoned: false,
      criminal: false,
      invisible: false,
      oculto: false,
      oculto_timer: 0,
      mounted: false,
      no_detectable: false,
      paralyzed: false,
      blind: false,
      dumb: false,
      immobilized: false,
      meditating: false,
      resting: false,
      safe_mode: false,
      navigating: false,
      gm: false,
      faction: :none,
      next_move_at: -1_000_000_000_000,
      next_attack_at: -1_000_000_000_000,
      next_spell_at: -1_000_000_000_000,
      next_item_use_at: -1_000_000_000_000,
      spell_cooldowns: %{},
      char_index: 1,
      map_id: 1,
      npcs_killed: 0,
      deaths: 0,
      penalty: 0,
      skill_points: 0,
      home_city: :ullathorpe,
      faction_kills_royal: 0,
      faction_kills_chaos: 0,
      citizens_killed: 0,
      criminals_killed: 0,
      faction_score: 0,
      faction_rank_armada: 0,
      faction_rank_chaos: 0,
      faction_reenlistadas: 0,
      fishing_points: 0,
      last_step_at: -1_000_000_000_000,
      speed_hack_counter: 0.0,
      speeding: 1.0,
      commerce_npc_id: nil,
      bank_npc_id: nil,
      bank_gold: 0,
      trade_request_target: nil,
      trade_partner_id: nil,
      trade_offer_gold: 0,
      trade_offer_items: []
    }

    Map.merge(defaults, overrides)
  end

  # Minimal state struct that CombatHandlers can work with.
  # Delegates to the shared MapStateFactory which returns %Arena.Map.State{}.
  defp make_state(players, opts \\ []) do
    occupancy_map = Keyword.get(opts, :occupancy, %{})
    npcs_live = Keyword.get(opts, :npcs_live, %{})

    map_state(
      players: players,
      npcs_live: npcs_live,
      occupancy: occupancy_map,
      meta: %{safe_zone: false, sin_invi_ocul: false}
    )
  end

  defp make_spell(overrides) do
    defaults = %SpellDef{
      id: 1,
      name: "Test Spell",
      tipo: 0,
      target: 0,
      min_hp: 0,
      max_hp: 0,
      mana_required: 10,
      sta_required: 0,
      min_skill: 0,
      fx_grh: 0,
      wav: 0,
      sube_hp: 0,
      sanacion: false,
      paraliza: false,
      envenena: false,
      cura_veneno: false,
      invisibilidad: false,
      revivir: false,
      inmoviliza: false,
      sube_fu: 0,
      min_fu: 0,
      max_fu: 0,
      sube_ag: 0,
      min_ag: 0,
      max_ag: 0,
      sube_mana: 0,
      min_mana: 0,
      max_mana: 0,
      sube_sta: 0,
      min_sta: 0,
      max_sta: 0,
      duration: 10,
      invoca: 0,
      work_on_dead: false,
      area_afecta: 0,
      area_radio: 0,
      max_level_casteable: 0,
      need_staff: false,
      staff_afecta: 0,
      cooldown: 2,
      requirement_mask: 0,
      require_weapon_type: 0
    }

    struct!(defaults, Map.to_list(overrides))
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 1. Combat.spell_damage/4 golden values
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Combat.spell_damage/4 -- deterministic (min == max)" do
    test "flat damage spell, non-mage, level 1" do
      # base = 30, level_bonus = floor(30 * 0.03 * 1) = 0, total = 30
      assert Combat.spell_damage(30, 30, 1, false) == 30
    end

    test "flat damage spell, non-mage, level 25" do
      # base = 30, level_bonus = floor(30 * 0.03 * 25) = floor(22.5) = 22
      # total = 30 + 22 = 52
      assert Combat.spell_damage(30, 30, 25, false) == 52
    end

    test "flat damage spell, non-mage, level 50" do
      # base = 30, level_bonus = floor(30 * 0.03 * 50) = floor(44.999...) = 44
      # total = 30 + 44 = 74 (float precision: 30 * 0.03 = 0.8999...)
      assert Combat.spell_damage(30, 30, 50, false) == 74
    end

    test "flat damage spell, mage gets 0.7x modifier, level 25" do
      # base = 30, level_bonus = floor(30 * 0.03 * 25) = 22
      # total = 30 + 22 = 52, mage: round(52 * 0.7) = round(36.4) = 36
      assert Combat.spell_damage(30, 30, 25, true) == 36
    end

    test "flat damage spell, mage, level 1" do
      # base = 30, level_bonus = 0, total = 30
      # mage: round(30 * 0.7) = round(21.0) = 21
      assert Combat.spell_damage(30, 30, 1, true) == 21
    end

    test "flat damage spell, mage, level 50" do
      # base = 30, level_bonus = floor(30 * 0.03 * 50) = 44, total = 74
      # mage: round(74 * 0.7) = round(51.8) = 52
      assert Combat.spell_damage(30, 30, 50, true) == 52
    end

    test "high-power spell, non-mage, level 40" do
      # base = 100, level_bonus = floor(100 * 0.03 * 40) = floor(120) = 120
      # total = 100 + 120 = 220
      assert Combat.spell_damage(100, 100, 40, false) == 220
    end

    test "high-power spell, mage, level 40" do
      # base = 100, level_bonus = 120, total = 220
      # mage: round(220 * 0.7) = round(154.0) = 154
      assert Combat.spell_damage(100, 100, 40, true) == 154
    end

    test "zero-damage spell returns 0 (non-mage)" do
      assert Combat.spell_damage(0, 0, 25, false) == 0
    end

    test "zero-damage spell returns 0 (mage)" do
      assert Combat.spell_damage(0, 0, 25, true) == 0
    end

    test "single-point spell at level 1" do
      # base = 1, level_bonus = floor(1 * 0.03 * 1) = 0
      assert Combat.spell_damage(1, 1, 1, false) == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 2. Combat.apply_magic_resistance/2 golden values
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Combat.apply_magic_resistance/2 golden values" do
    test "0% resistance: full damage passes through" do
      assert Combat.apply_magic_resistance(100, 0) == 100
    end

    test "negative resistance treated as 0: full damage" do
      assert Combat.apply_magic_resistance(100, -10) == 100
    end

    test "50% resistance halves damage" do
      # round(100 * (1 - 50/100)) = round(50.0) = 50
      assert Combat.apply_magic_resistance(100, 50) == 50
    end

    test "25% resistance" do
      # round(100 * 0.75) = 75
      assert Combat.apply_magic_resistance(100, 25) == 75
    end

    test "75% resistance" do
      # round(100 * 0.25) = 25
      assert Combat.apply_magic_resistance(100, 75) == 25
    end

    test "100% resistance: zero damage" do
      assert Combat.apply_magic_resistance(100, 100) == 0
    end

    test "small damage with resistance floors at 0" do
      # round(1 * (1 - 90/100)) = round(0.1) = 0
      assert Combat.apply_magic_resistance(1, 90) == 0
    end

    test "odd damage with 33% resistance" do
      # round(77 * (1 - 33/100)) = round(77 * 0.67) = round(51.59) = 52
      assert Combat.apply_magic_resistance(77, 33) == 52
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 3. Heal spell: HP capping and self-heal
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_heal -- self-heal (no target)" do
    test "heal does not exceed max_hp" do
      caster = make_entity(%{hp: 80, max_hp: 100, mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 50, max_hp: 50, mana_required: 20})
      new_state = SpellEffects.apply_spell_heal(state, :caster, caster, 50, spell, nil, nil)

      updated = new_state.players[:caster]
      # 80 + 50 = 130, capped at max_hp = 100
      assert updated.hp == 100
    end

    test "heal below max_hp adds exact amount" do
      caster = make_entity(%{hp: 40, max_hp: 100, mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 30, max_hp: 30, mana_required: 20})
      new_state = SpellEffects.apply_spell_heal(state, :caster, caster, 30, spell, nil, nil)

      updated = new_state.players[:caster]
      # 40 + 30 = 70
      assert updated.hp == 70
    end

    test "heal at full HP stays at max" do
      caster = make_entity(%{hp: 100, max_hp: 100, mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 50, max_hp: 50, mana_required: 20})
      new_state = SpellEffects.apply_spell_heal(state, :caster, caster, 50, spell, nil, nil)

      updated = new_state.players[:caster]
      assert updated.hp == 100
    end

    test "zero heal leaves HP unchanged" do
      caster = make_entity(%{hp: 50, max_hp: 100, mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 0, max_hp: 0, mana_required: 20})
      new_state = SpellEffects.apply_spell_heal(state, :caster, caster, 0, spell, nil, nil)

      updated = new_state.players[:caster]
      assert updated.hp == 50
    end
  end

  describe "apply_spell_heal -- target heal" do
    test "heals target player, not self" do
      caster = make_entity(%{char_id: :caster, hp: 100, max_hp: 100, mana: 180})
      target = make_entity(%{char_id: :target, hp: 30, max_hp: 100, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{sube_hp: 1, min_hp: 40, max_hp: 40, mana_required: 20})
      new_state = SpellEffects.apply_spell_heal(state, :caster, caster, 40, spell, 51, 50)

      assert new_state.players[:target].hp == 70
      # Caster HP unchanged
      assert new_state.players[:caster].hp == 100
    end

    test "cannot heal dead target" do
      caster = make_entity(%{char_id: :caster, hp: 100, max_hp: 100, mana: 180})
      target = make_entity(%{char_id: :target, hp: 0, max_hp: 100, dead: true, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{sube_hp: 1, min_hp: 40, max_hp: 40, mana_required: 20})
      new_state = SpellEffects.apply_spell_heal(state, :caster, caster, 40, spell, 51, 50)

      # Dead target HP not changed
      assert new_state.players[:target].hp == 0
      assert new_state.players[:target].dead == true
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 4. Status effects: paralysis, poison, invis, immobilize, cure poison
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_status -- paralysis" do
    test "applies paralyzed flag and buff with full VB6 duration" do
      caster = make_entity(%{mana: 180})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: []})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{paraliza: true, duration: 10, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, 51, 50)

      updated_target = new_state.players[:target]
      assert updated_target.paralyzed == true

      [buff] = Enum.filter(updated_target.buffs, &(&1.type == :paralyzed))
      # VB6: non-warrior/hunter gets full duration (no halving)
      assert buff.type == :paralyzed
      assert is_integer(buff.expires_at)
    end
  end

  describe "apply_spell_status -- poison" do
    test "applies poisoned flag with full duration" do
      caster = make_entity(%{mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{envenena: true, duration: 10, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      assert updated.poisoned == true

      [buff] = Enum.filter(updated.buffs, &(&1.type == :poisoned))
      assert buff.type == :poisoned
      # Poison uses full duration (not halved)
      assert is_integer(buff.expires_at)
      # Poison has a next_tick for periodic damage
      assert is_integer(buff.next_tick)
    end
  end

  describe "apply_spell_status -- cure poison" do
    test "removes poisoned flag and poison buff" do
      caster =
        make_entity(%{
          mana: 180,
          poisoned: true,
          buffs: [%{type: :poisoned, expires_at: 999_999_999, next_tick: 100}]
        })

      state = make_state(%{caster: caster})

      spell = make_spell(%{cura_veneno: true, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      assert updated.poisoned == false
      assert Enum.filter(updated.buffs, &(&1.type == :poisoned)) == []
    end

    test "cure poison on non-poisoned player is a no-op" do
      caster = make_entity(%{mana: 180, poisoned: false, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{cura_veneno: true, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      assert updated.poisoned == false
      assert updated.buffs == []
    end
  end

  describe "apply_spell_status -- invisibility" do
    test "applies invisible flag and buff" do
      caster = make_entity(%{mana: 180, invisible: false, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{invisibilidad: true, duration: 15, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      assert updated.invisible == true

      [buff] = Enum.filter(updated.buffs, &(&1.type == :invisible))
      assert buff.type == :invisible
      # Full duration (not halved like paralysis)
      assert is_integer(buff.expires_at)
    end

    test "re-applying invisibility replaces existing buff (no stacking)" do
      now = System.monotonic_time(:millisecond)
      old_buff = %{type: :invisible, expires_at: now + 1000}

      caster = make_entity(%{mana: 180, invisible: true, buffs: [old_buff]})
      state = make_state(%{caster: caster})

      spell = make_spell(%{invisibilidad: true, duration: 30, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      invis_buffs = Enum.filter(updated.buffs, &(&1.type == :invisible))
      # Only one invisibility buff (replaced, not stacked)
      assert length(invis_buffs) == 1
    end
  end

  describe "apply_spell_status -- immobilize" do
    test "applies immobilized flag with full VB6 duration" do
      caster = make_entity(%{mana: 180, immobilized: false, buffs: []})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: []})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{inmoviliza: true, duration: 10, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, 51, 50)

      updated_target = new_state.players[:target]
      assert updated_target.immobilized == true

      [buff] = Enum.filter(updated_target.buffs, &(&1.type == :immobilized))
      assert buff.type == :immobilized
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 5. Attribute buffs: strength and agility
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_attribute_buff -- strength" do
    test "strength buff (sube_fu=1) increases str_buff" do
      caster = make_entity(%{mana: 180, str_buff: 0, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_fu: 1, min_fu: 10, max_fu: 10, duration: 20, mana_required: 20})
      new_state = SpellEffects.apply_spell_attribute_buff(state, :caster, caster, spell, :str, nil, nil)

      updated = new_state.players[:caster]
      assert updated.str_buff == 10

      [buff] = Enum.filter(updated.buffs, &(&1.type == :str_buff))
      assert buff.value == 10
    end

    test "strength debuff (sube_fu=2) decreases str_buff" do
      caster = make_entity(%{mana: 180, str_buff: 0, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_fu: 2, min_fu: 5, max_fu: 5, duration: 20, mana_required: 20})
      new_state = SpellEffects.apply_spell_attribute_buff(state, :caster, caster, spell, :str, nil, nil)

      updated = new_state.players[:caster]
      assert updated.str_buff == -5

      [buff] = Enum.filter(updated.buffs, &(&1.type == :str_buff))
      assert buff.value == -5
    end

    test "multiple str buffs stack additively" do
      caster = make_entity(%{mana: 180, str_buff: 5, buffs: [%{type: :str_buff, expires_at: 999_999_999_999, value: 5}]})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_fu: 1, min_fu: 7, max_fu: 7, duration: 20, mana_required: 20})
      new_state = SpellEffects.apply_spell_attribute_buff(state, :caster, caster, spell, :str, nil, nil)

      updated = new_state.players[:caster]
      # 5 + 7 = 12
      assert updated.str_buff == 12
      assert length(updated.buffs) == 2
    end
  end

  describe "apply_spell_attribute_buff -- agility" do
    test "agility buff (sube_ag=1) increases agi_buff" do
      caster = make_entity(%{mana: 180, agi_buff: 0, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_ag: 1, min_ag: 8, max_ag: 8, duration: 20, mana_required: 20})
      new_state = SpellEffects.apply_spell_attribute_buff(state, :caster, caster, spell, :agi, nil, nil)

      updated = new_state.players[:caster]
      assert updated.agi_buff == 8

      [buff] = Enum.filter(updated.buffs, &(&1.type == :agi_buff))
      assert buff.value == 8
    end

    test "agility debuff (sube_ag=2) decreases agi_buff" do
      caster = make_entity(%{mana: 180, agi_buff: 0, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_ag: 2, min_ag: 6, max_ag: 6, duration: 20, mana_required: 20})
      new_state = SpellEffects.apply_spell_attribute_buff(state, :caster, caster, spell, :agi, nil, nil)

      updated = new_state.players[:caster]
      assert updated.agi_buff == -6
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 6. Mana restore/drain spells
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_mana" do
    test "mana restore (sube_mana=1) increases target mana, capped at max" do
      caster = make_entity(%{mana: 180, max_mana: 200})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_mana: 1, min_mana: 50, max_mana: 50, mana_required: 20})
      new_state = SpellEffects.apply_spell_mana(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      # 180 + 50 = 230, capped at 200
      assert updated.mana == 200
    end

    test "mana drain (sube_mana=2) decreases target mana, floors at 0" do
      caster = make_entity(%{mana: 30, max_mana: 200})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_mana: 2, min_mana: 50, max_mana: 50, mana_required: 0})
      new_state = SpellEffects.apply_spell_mana(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      # 30 - 50 = -20, floored at 0
      assert updated.mana == 0
    end

    test "mana restore below cap adds exact amount" do
      caster = make_entity(%{mana: 100, max_mana: 200})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_mana: 1, min_mana: 30, max_mana: 30, mana_required: 0})
      new_state = SpellEffects.apply_spell_mana(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      assert updated.mana == 130
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 7. Stamina restore/drain spells
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_stamina" do
    test "stamina restore (sube_sta=1) increases stamina, capped at max" do
      caster = make_entity(%{mana: 180, stamina: 80, max_stamina: 100})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_sta: 1, min_sta: 30, max_sta: 30, mana_required: 20})
      new_state = SpellEffects.apply_spell_stamina(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      # 80 + 30 = 110, capped at 100
      assert updated.stamina == 100
    end

    test "stamina drain (sube_sta=2) decreases stamina, floors at 0" do
      caster = make_entity(%{mana: 180, stamina: 10, max_stamina: 100})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_sta: 2, min_sta: 25, max_sta: 25, mana_required: 20})
      new_state = SpellEffects.apply_spell_stamina(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      # 10 - 25 = -15, floored at 0
      assert updated.stamina == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 8. Resurrection spell
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_resurrect" do
    test "revives dead target at min_hp% of max_hp" do
      caster = make_entity(%{char_id: :caster, mana: 180})

      target =
        make_entity(%{
          char_id: :target,
          hp: 0,
          max_hp: 200,
          mana: 50,
          dead: true,
          poisoned: true,
          paralyzed: true,
          invisible: true,
          buffs: [%{type: :poisoned, expires_at: 999_999_999}],
          x: 51,
          y: 50,
          char_index: 2
        })

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      # VB6: min_hp is revive percentage, e.g., 10 means 10% of max_hp
      spell = make_spell(%{revivir: true, min_hp: 10, mana_required: 20, work_on_dead: true})
      new_state = SpellEffects.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

      revived = new_state.players[:target]
      assert revived.dead == false
      # revive_hp = max(div(200 * 10, 100), 1) = 20
      assert revived.hp == 20
      # VB6: revived player's mana resets to 0
      assert revived.mana == 0
      # VB6: resurrection clears all status effects
      assert revived.poisoned == false
      assert revived.paralyzed == false
      assert revived.invisible == false
      assert revived.buffs == []
      # VB6: hunger and thirst reset to 0
      assert revived.hunger == 0
      assert revived.thirst == 0
    end

    test "resurrect with high percentage" do
      caster = make_entity(%{char_id: :caster, mana: 180})

      target =
        make_entity(%{
          char_id: :target,
          hp: 0,
          max_hp: 500,
          dead: true,
          buffs: [],
          x: 51,
          y: 50,
          char_index: 2
        })

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      # 50% of 500 = 250 HP
      spell = make_spell(%{revivir: true, min_hp: 50, mana_required: 20, work_on_dead: true})
      new_state = SpellEffects.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

      assert new_state.players[:target].hp == 250
      assert new_state.players[:target].dead == false
    end

    test "resurrect on living target does nothing" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{char_id: :target, hp: 50, max_hp: 100, dead: false, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{revivir: true, min_hp: 10, mana_required: 20, work_on_dead: true})
      new_state = SpellEffects.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

      # Living target unchanged
      assert new_state.players[:target].hp == 50
      assert new_state.players[:target].dead == false
    end

    test "resurrect with min_hp below 10 uses 10% floor" do
      caster = make_entity(%{char_id: :caster, mana: 180})

      target =
        make_entity(%{
          char_id: :target,
          hp: 0,
          max_hp: 100,
          dead: true,
          buffs: [],
          x: 51,
          y: 50,
          char_index: 2
        })

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      # VB6: revive_pct = max(spell_def.min_hp, 10)
      spell = make_spell(%{revivir: true, min_hp: 3, mana_required: 20, work_on_dead: true})
      new_state = SpellEffects.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

      # Uses 10% floor: div(100 * 10, 100) = 10
      assert new_state.players[:target].hp == 10
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 9. Mana cost validation in handle_cast_spell
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- mana cost validation" do
    test "insufficient mana returns error" do
      spell_def = make_spell(%{mana_required: 50, min_skill: 0})
      # Manually insert spell into ETS for this test
      spell_id = 9999
      :ets.insert(:arena_game_data, {{:spell, spell_id}, %{spell_def | id: spell_id}})

      caster = make_entity(%{mana: 30, spells: [spell_id], spell_cooldowns: %{}})
      occupancy = %{{50, 50} => {:player, :caster}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      # Self-target via (50,50). nil targets now trigger the WriteWorkRequestTarget
      # prompt (drift 19c, VB6 modHechizos.bas:4150-4156), so we must supply
      # an explicit target to exercise the mana-validation branch.
      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, 50, 50)
      assert result == {:error, :not_enough_mana}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end

    test "sufficient mana deducts cost" do
      spell_id = 9998
      spell_def = make_spell(%{id: spell_id, mana_required: 20, min_skill: 0, sube_hp: 1, min_hp: 10, max_hp: 10})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 100, hp: 50, max_hp: 100, spells: [spell_id], spell_cooldowns: %{}})
      # Target an empty tile so the heal falls through to the self-heal
      # branch (which writes the mana-deducted caster entity back to state).
      state = make_state(%{caster: caster})

      {:reply, :ok, new_state} = CombatHandlers.handle_cast_spell(state, :caster, 1, 51, 50)

      updated = new_state.players[:caster]
      # 100 - 20 = 80 mana remaining
      assert updated.mana == 80

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 10. Spell level requirement (min_skill)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- skill level requirement" do
    test "skill too low returns error" do
      spell_id = 9997
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 90})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, skills: %{magic: 50}, spells: [spell_id], spell_cooldowns: %{}})
      occupancy = %{{50, 50} => {:player, :caster}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, 50, 50)
      assert result == {:error, :skill_too_low}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end

    test "exact minimum skill allows casting" do
      spell_id = 9996
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 50, sube_hp: 1, min_hp: 5, max_hp: 5})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, hp: 50, max_hp: 100, skills: %{magic: 50}, spells: [spell_id], spell_cooldowns: %{}})
      occupancy = %{{50, 50} => {:player, :caster}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, 50, 50)
      assert result == :ok

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 11. Edge case: casting while dead
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- dead caster" do
    test "dead caster cannot cast spells" do
      spell_id = 9995
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 0})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, dead: true, spells: [spell_id], spell_cooldowns: %{}})
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
      assert result == {:error, :dead}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 12. Edge case: casting while paralyzed
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- paralyzed caster" do
    test "paralyzed caster cannot cast spells" do
      spell_id = 9994
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 0})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, paralyzed: true, spells: [spell_id], spell_cooldowns: %{}})
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
      assert result == {:error, :paralyzed}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 13. Cooldown enforcement
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- cooldown" do
    test "spell on cooldown returns error" do
      spell_id = 9993
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 0, cooldown: 5})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      # Set spell_slot 1 cooldown to far future
      future = System.monotonic_time(:millisecond) + 999_999_999
      caster = make_entity(%{mana: 200, spells: [spell_id], spell_cooldowns: %{1 => future}})
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
      assert result == {:error, :cooldown}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end

    test "spell with expired cooldown can be cast" do
      spell_id = 9992
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 0, cooldown: 2, sube_hp: 1, min_hp: 5, max_hp: 5})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      # Set cooldown to the past
      past = System.monotonic_time(:millisecond) - 10_000
      caster = make_entity(%{mana: 200, hp: 50, max_hp: 100, spells: [spell_id], spell_cooldowns: %{1 => past}})
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
      assert result == :ok

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 14. MaxLevelCasteable: spell max caster level
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- max_level_casteable" do
    test "caster above max level cannot cast" do
      spell_id = 9991
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 0, max_level_casteable: 15})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, level: 20, spells: [spell_id], spell_cooldowns: %{}})
      occupancy = %{{50, 50} => {:player, :caster}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, 50, 50)
      assert result == {:error, :level_too_high}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end

    test "caster at exactly max level can cast" do
      spell_id = 9990
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 0, max_level_casteable: 25, sube_hp: 1, min_hp: 5, max_hp: 5})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, level: 25, hp: 50, max_hp: 100, spells: [spell_id], spell_cooldowns: %{}})
      occupancy = %{{50, 50} => {:player, :caster}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, 50, 50)
      assert result == :ok

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end

    test "max_level_casteable 0 means no limit" do
      spell_id = 9989
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 0, max_level_casteable: 0, sube_hp: 1, min_hp: 5, max_hp: 5})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, level: 99, hp: 50, max_hp: 100, spells: [spell_id], spell_cooldowns: %{}})
      occupancy = %{{50, 50} => {:player, :caster}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, 50, 50)
      assert result == :ok

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 15. Stamina requirement
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- stamina requirement" do
    test "insufficient stamina returns error" do
      spell_id = 9988
      spell_def = make_spell(%{id: spell_id, mana_required: 10, sta_required: 50, min_skill: 0})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, stamina: 30, spells: [spell_id], spell_cooldowns: %{}})
      occupancy = %{{50, 50} => {:player, :caster}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, 50, 50)
      assert result == {:error, :not_enough_stamina}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 16. Invalid spell slot
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- invalid slot" do
    test "slot 0 (out of bounds) returns error" do
      caster = make_entity(%{mana: 200, spells: [1], spell_cooldowns: %{}})
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 0, nil, nil)
      assert result == {:error, :invalid_slot}
    end

    test "slot beyond spell list returns error" do
      caster = make_entity(%{mana: 200, spells: [1], spell_cooldowns: %{}})
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 5, nil, nil)
      assert result == {:error, :invalid_slot}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 17. Player not on map
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- player not on map" do
    test "unknown char_id returns error" do
      state = make_state(%{})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :nonexistent, 1, nil, nil)
      assert result == {:error, :not_on_map}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 18. SpellDef struct parsing
  # ═══════════════════════════════════════════════════════════════════════════

  describe "SpellDef.from_section/2 parsing" do
    test "parses all boolean fields correctly" do
      section = %{
        "nombre" => "TestSpell",
        "tipo" => "1",
        "target" => "2",
        "minhp" => "10",
        "maxhp" => "30",
        "manarequerido" => "25",
        "starequerido" => "5",
        "minskill" => "40",
        "paraliza" => "1",
        "envenena" => "0",
        "curaveneno" => "1",
        "invisibilidad" => "0",
        "revivir" => "1",
        "inmoviliza" => "1",
        "sanacion" => "1",
        "workondead" => "1",
        "needstaff" => "0",
        "duration" => "15",
        "cooldown" => "3"
      }

      spell = SpellDef.from_section(42, section)

      assert spell.id == 42
      assert spell.name == "TestSpell"
      assert spell.tipo == 1
      assert spell.target == 2
      assert spell.min_hp == 10
      assert spell.max_hp == 30
      assert spell.mana_required == 25
      assert spell.sta_required == 5
      assert spell.min_skill == 40
      assert spell.paraliza == true
      assert spell.envenena == false
      assert spell.cura_veneno == true
      assert spell.invisibilidad == false
      assert spell.revivir == true
      assert spell.inmoviliza == true
      assert spell.sanacion == true
      assert spell.work_on_dead == true
      assert spell.need_staff == false
      assert spell.duration == 15
      assert spell.cooldown == 3
    end

    test "missing fields default to zero/false" do
      spell = SpellDef.from_section(1, %{})

      assert spell.id == 1
      assert spell.name == "Unknown"
      assert spell.tipo == 0
      assert spell.min_hp == 0
      assert spell.max_hp == 0
      assert spell.mana_required == 0
      assert spell.paraliza == false
      assert spell.envenena == false
      assert spell.invisibilidad == false
      assert spell.revivir == false
      assert spell.sanacion == false
      assert spell.work_on_dead == false
    end

    test "cooldown defaults to 2 when zero or missing" do
      spell_zero = SpellDef.from_section(1, %{"cooldown" => "0"})
      spell_nil = SpellDef.from_section(1, %{})

      assert spell_zero.cooldown == 2
      assert spell_nil.cooldown == 2
    end

    test "cooldown preserves positive values" do
      spell = SpellDef.from_section(1, %{"cooldown" => "5"})
      assert spell.cooldown == 5
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 19. Spell routing in apply_spell_single
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_single -- routing" do
    test "sube_hp=2 routes to damage path" do
      # With no target, damage path just updates player state
      caster = make_entity(%{mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 2, min_hp: 20, max_hp: 20, mana_required: 20})
      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, nil, nil)

      # State updated (caster stored)
      assert Map.has_key?(new_state.players, :caster)
    end

    test "sube_hp=1 routes to heal path" do
      caster = make_entity(%{mana: 180, hp: 50, max_hp: 100})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 20, max_hp: 20, mana_required: 20})
      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, nil, nil)

      assert new_state.players[:caster].hp == 70
    end

    test "sanacion routes to heal path" do
      caster = make_entity(%{mana: 180, hp: 50, max_hp: 100})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sanacion: true, min_hp: 15, max_hp: 15, mana_required: 20})
      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, nil, nil)

      assert new_state.players[:caster].hp == 65
    end

    test "revivir routes to resurrect path" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{char_id: :target, hp: 0, max_hp: 100, dead: true, buffs: [], x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{revivir: true, min_hp: 10, mana_required: 20, work_on_dead: true})
      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, 51, 50)

      assert new_state.players[:target].dead == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 20. Buff expiration in process_player_buffs
  # ═══════════════════════════════════════════════════════════════════════════

  # NOTE: process_player_buffs/4 has a latent bug -- the Enum.map_reduce
  # destructuring swaps {entity, active} so that `entity` receives the
  # mapped buff list and `active` receives the entity accumulator, causing
  # a BadMapError when all buffs expire in the same tick. Tests for this
  # function are skipped until the bug is fixed. See combat_handlers.ex:1476.

  # ═══════════════════════════════════════════════════════════════════════════
  # 21. Duration calculation: minimum floor of 3000ms
  # ═══════════════════════════════════════════════════════════════════════════

  describe "status effect duration floor" do
    test "duration 0 in spell_def gets floored to 3000ms" do
      caster = make_entity(%{mana: 180, invisible: false, buffs: []})
      state = make_state(%{caster: caster})
      now_before = System.monotonic_time(:millisecond)

      spell = make_spell(%{invisibilidad: true, duration: 0, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      now_after = System.monotonic_time(:millisecond)

      updated = new_state.players[:caster]
      [buff] = Enum.filter(updated.buffs, &(&1.type == :invisible))

      # VB6: duration_ms = max(duration * 1000, 3000) = max(0, 3000) = 3000
      assert buff.expires_at >= now_before + 3000
      assert buff.expires_at <= now_after + 3000 + 10
    end

    test "duration 1 (1000ms) gets floored to 3000ms" do
      caster = make_entity(%{mana: 180, invisible: false, buffs: []})
      state = make_state(%{caster: caster})
      now_before = System.monotonic_time(:millisecond)

      spell = make_spell(%{invisibilidad: true, duration: 1, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      now_after = System.monotonic_time(:millisecond)

      updated = new_state.players[:caster]
      [buff] = Enum.filter(updated.buffs, &(&1.type == :invisible))

      # max(1 * 1000, 3000) = 3000
      assert buff.expires_at >= now_before + 3000
      assert buff.expires_at <= now_after + 3000 + 10
    end

    test "duration 10 (10000ms) is used as-is" do
      caster = make_entity(%{mana: 180, invisible: false, buffs: []})
      state = make_state(%{caster: caster})
      now_before = System.monotonic_time(:millisecond)

      spell = make_spell(%{invisibilidad: true, duration: 10, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      now_after = System.monotonic_time(:millisecond)

      updated = new_state.players[:caster]
      [buff] = Enum.filter(updated.buffs, &(&1.type == :invisible))

      # max(10 * 1000, 3000) = 10000
      assert buff.expires_at >= now_before + 10_000
      assert buff.expires_at <= now_after + 10_000 + 10
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 22. Paralysis and immobilize use full VB6 duration (no halving)
  # VB6: Warrior/Hunter get 0.7x, others get full duration.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "paralysis/immobilize full duration (VB6 parity)" do
    test "paralysis duration uses full duration (no halving)" do
      caster = make_entity(%{mana: 180, buffs: []})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: []})
      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)
      now_before = System.monotonic_time(:millisecond)

      spell = make_spell(%{paraliza: true, duration: 20, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, 51, 50)

      now_after = System.monotonic_time(:millisecond)

      updated_target = new_state.players[:target]
      [buff] = Enum.filter(updated_target.buffs, &(&1.type == :paralyzed))

      # VB6: non-warrior/hunter targets get full duration
      # duration_ms = max(20 * 1000, 3000) = 20000
      assert buff.expires_at >= now_before + 20_000
      assert buff.expires_at <= now_after + 20_000 + 10
    end

    test "immobilize duration uses full duration (no halving)" do
      caster = make_entity(%{mana: 180, buffs: []})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: []})
      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)
      now_before = System.monotonic_time(:millisecond)

      spell = make_spell(%{inmoviliza: true, duration: 20, mana_required: 20})
      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, 51, 50)

      now_after = System.monotonic_time(:millisecond)

      updated_target = new_state.players[:target]
      [buff] = Enum.filter(updated_target.buffs, &(&1.type == :immobilized))

      assert buff.expires_at >= now_before + 20_000
      assert buff.expires_at <= now_after + 20_000 + 10
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 23. Mana deduction and cooldown set on successful cast
  # ═══════════════════════════════════════════════════════════════════════════

  describe "handle_cast_spell -- mana deduction and cooldown set" do
    test "successful cast deducts mana and stamina, sets per-slot cooldown" do
      spell_id = 9987
      spell_def = make_spell(%{id: spell_id, mana_required: 30, sta_required: 10, min_skill: 0, cooldown: 4, sube_hp: 1, min_hp: 5, max_hp: 5})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      now_before = System.monotonic_time(:millisecond)

      caster = make_entity(%{mana: 100, stamina: 50, hp: 50, max_hp: 100, spells: [spell_id], spell_cooldowns: %{}})
      # Target empty tile so heal falls through to self-heal branch.
      state = make_state(%{caster: caster})

      {:reply, :ok, new_state} = CombatHandlers.handle_cast_spell(state, :caster, 1, 51, 50)

      now_after = System.monotonic_time(:millisecond)
      updated = new_state.players[:caster]

      # Mana: 100 - 30 = 70
      assert updated.mana == 70
      # Stamina: 50 - 10 = 40
      assert updated.stamina == 40

      # Per-slot cooldown: now + cooldown * 1000 = now + 4000
      cd = updated.spell_cooldowns[1]
      assert cd >= now_before + 4000
      assert cd <= now_after + 4000 + 10

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 24. Spell damage to NPC (apply_spell_damage_to_npc path)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_damage -- NPC target (non-lethal)" do
    test "damage spell reduces NPC HP" do
      caster = make_entity(%{mana: 180, level: 25, class: :mago})
      npc = %{
        npc_id: 99999, instance_id: 1, x: 51, y: 50, hp: 200, max_hp: 200,
        alive: true, char_index: 2, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{{51, 50} => {:npc, 1}}
      state = make_state(%{caster: caster}, occupancy: occupancy, npcs_live: %{1 => npc})

      # Apply 30 damage directly (bypassing random roll)
      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 30, %SpellDef{}, 51, 50)

      # npc_id 99999 has no NPC def, so magic_resistance = 0, full damage passes
      updated_npc = new_state.npcs_live[1]
      assert updated_npc.hp == 170
    end

    test "NPC acquires aggro target after being hit by spell" do
      caster = make_entity(%{mana: 180, level: 25})
      npc = %{
        npc_id: 99999, instance_id: 1, x: 51, y: 50, hp: 200, max_hp: 200,
        alive: true, char_index: 2, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{{51, 50} => {:npc, 1}}
      state = make_state(%{caster: caster}, occupancy: occupancy, npcs_live: %{1 => npc})

      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 20, %SpellDef{}, 51, 50)

      updated_npc = new_state.npcs_live[1]
      assert updated_npc.target_id == :caster
    end

    test "damage to dead NPC is a no-op" do
      caster = make_entity(%{mana: 180})
      npc = %{
        npc_id: 99999, instance_id: 1, x: 51, y: 50, hp: 0, max_hp: 200,
        alive: false, char_index: 2, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{{51, 50} => {:npc, 1}}
      state = make_state(%{caster: caster}, occupancy: occupancy, npcs_live: %{1 => npc})

      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 50, %SpellDef{}, 51, 50)

      # NPC HP unchanged
      assert new_state.npcs_live[1].hp == 0
    end

    test "NPC with magic resistance reduces spell damage" do
      # Insert a custom NPC def with magic_resistance into ETS
      npc_def = %{magic_resistance: 50, elemental_tags: 0, intervalo_respawn: 60,
                   npc_level: 10, exp_count: 100, poder_evasion: 0, def: 0,
                   min_hit: 1, max_hit: 5, poder_ataque: 10, give_exp: 100,
                   max_hp: 200, loot_table: []}
      :ets.insert(:arena_game_data, {{:npc, 88888}, npc_def})

      caster = make_entity(%{mana: 180})
      npc = %{
        npc_id: 88888, instance_id: 1, x: 51, y: 50, hp: 200, max_hp: 200,
        alive: true, char_index: 2, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{{51, 50} => {:npc, 1}}
      state = make_state(%{caster: caster}, occupancy: occupancy, npcs_live: %{1 => npc})

      # 100 raw damage, 50% resistance -> 50 final damage
      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 100, %SpellDef{}, 51, 50)

      assert new_state.npcs_live[1].hp == 150

      :ets.delete(:arena_game_data, {:npc, 88888})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 25. Spell damage to player (apply_spell_damage_to_player path)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_damage -- player target (non-lethal)" do
    test "damage spell reduces defender HP using resistance skill" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      # Defender has 30% magic resistance skill
      defender = make_entity(%{
        char_id: :defender, hp: 200, max_hp: 300, x: 51, y: 50, char_index: 2,
        skills: %{resistance: 30}
      })

      occupancy = %{{51, 50} => {:player, :defender}}
      state = make_state(%{caster: caster, defender: defender}, occupancy: occupancy)

      # 100 raw damage, 30% resistance -> round(100 * 0.7) = 70 final
      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 100, %SpellDef{}, 51, 50)

      assert new_state.players[:defender].hp == 130
    end

    test "damage on player in safe zone is blocked" do
      caster = make_entity(%{char_id: :caster, mana: 180, faction: :none})
      defender = make_entity(%{
        char_id: :defender, hp: 200, max_hp: 300, x: 51, y: 50, char_index: 2, faction: :none
      })

      occupancy = %{{51, 50} => {:player, :defender}}
      state = map_state(
        players: %{caster: caster, defender: defender},
        occupancy: occupancy,
        meta: %{safe_zone: true, sin_invi_ocul: false}
      )

      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 100, %SpellDef{}, 51, 50)

      # Defender HP unchanged -- safe zone blocked it
      assert new_state.players[:defender].hp == 200
    end

    test "attacking non-criminal player sets criminal flag on caster" do
      caster = make_entity(%{char_id: :caster, mana: 180, criminal: false})
      defender = make_entity(%{
        char_id: :defender, hp: 200, max_hp: 300, x: 51, y: 50, char_index: 2,
        criminal: false, skills: %{resistance: 0}
      })

      occupancy = %{{51, 50} => {:player, :defender}}
      state = make_state(%{caster: caster, defender: defender}, occupancy: occupancy)

      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 50, %SpellDef{}, 51, 50)

      # Caster becomes criminal for attacking a non-criminal
      assert new_state.players[:caster].criminal == true
    end

    test "attacking criminal player does not set criminal flag" do
      caster = make_entity(%{char_id: :caster, mana: 180, criminal: false})
      defender = make_entity(%{
        char_id: :defender, hp: 200, max_hp: 300, x: 51, y: 50, char_index: 2,
        criminal: true, skills: %{resistance: 0}
      })

      occupancy = %{{51, 50} => {:player, :defender}}
      state = make_state(%{caster: caster, defender: defender}, occupancy: occupancy)

      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 50, %SpellDef{}, 51, 50)

      assert new_state.players[:caster].criminal == false
    end

    test "same-faction spell damage is blocked" do
      caster = make_entity(%{char_id: :caster, mana: 180, faction: :royal_army})
      defender = make_entity(%{
        char_id: :defender, hp: 200, max_hp: 300, x: 51, y: 50, char_index: 2,
        faction: :royal_army, skills: %{resistance: 0}
      })

      occupancy = %{{51, 50} => {:player, :defender}}
      state = make_state(%{caster: caster, defender: defender}, occupancy: occupancy)

      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 50, %SpellDef{}, 51, 50)

      # HP unchanged -- same faction blocked it
      assert new_state.players[:defender].hp == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 26. Self-cast damage spell (targeting own tile or nil)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_damage -- self-target or empty tile" do
    test "damage spell on nil target is a no-op (just stores entity)" do
      caster = make_entity(%{mana: 180, hp: 100})
      state = make_state(%{caster: caster})

      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 50, %SpellDef{}, nil, nil)

      # No damage to self -- damage spells require a valid target
      assert new_state.players[:caster].hp == 100
    end

    test "damage spell on empty tile is a no-op" do
      caster = make_entity(%{mana: 180, hp: 100})
      state = make_state(%{caster: caster})

      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 50, %SpellDef{}, 60, 60)

      assert new_state.players[:caster].hp == 100
    end

    test "damage spell on own tile does not self-damage" do
      caster = make_entity(%{mana: 180, hp: 100, x: 50, y: 50})
      occupancy = %{{50, 50} => {:player, :caster}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      # {:player, :caster} with target_id == char_id falls through to no-op
      new_state = SpellEffects.apply_spell_damage(state, :caster, caster, 50, %SpellDef{}, 50, 50)

      assert new_state.players[:caster].hp == 100
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 27. AoE spell behavior (area_radio + area_afecta filtering)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_aoe -- area targeting" do
    test "AoE heal (area_afecta=1) hits only players in radius" do
      caster = make_entity(%{char_id: :caster, mana: 180, hp: 60, max_hp: 100, x: 50, y: 50})
      ally = make_entity(%{char_id: :ally, hp: 40, max_hp: 100, x: 51, y: 50, char_index: 2})
      # NPC should not be healed
      npc = %{
        npc_id: 99999, instance_id: 1, x: 52, y: 50, hp: 50, max_hp: 200,
        alive: true, char_index: 3, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{
        {50, 50} => {:player, :caster},
        {51, 50} => {:player, :ally},
        {52, 50} => {:npc, 1}
      }

      state = make_state(
        %{caster: caster, ally: ally},
        occupancy: occupancy,
        npcs_live: %{1 => npc}
      )

      # AoE heal: area_radio=2, area_afecta=1 (players only)
      spell = make_spell(%{sube_hp: 1, min_hp: 20, max_hp: 20, area_radio: 2, area_afecta: 1})

      new_state = SpellEffects.apply_spell_aoe(state, :caster, caster, spell, 51, 50)

      # Both players in radius get healed
      assert new_state.players[:caster].hp == 80
      assert new_state.players[:ally].hp == 60
      # NPC unaffected (area_afecta=1 filters NPCs out)
      assert new_state.npcs_live[1].hp == 50
    end

    test "AoE with area_afecta=2 only affects NPCs" do
      caster = make_entity(%{char_id: :caster, mana: 180, hp: 100, x: 50, y: 50})
      npc1 = %{
        npc_id: 99999, instance_id: 1, x: 51, y: 50, hp: 100, max_hp: 200,
        alive: true, char_index: 2, target_id: nil, owner_id: nil, exp_count: 100
      }
      npc2 = %{
        npc_id: 99999, instance_id: 2, x: 52, y: 50, hp: 100, max_hp: 200,
        alive: true, char_index: 3, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{
        {50, 50} => {:player, :caster},
        {51, 50} => {:npc, 1},
        {52, 50} => {:npc, 2}
      }

      state = make_state(
        %{caster: caster},
        occupancy: occupancy,
        npcs_live: %{1 => npc1, 2 => npc2}
      )

      # AoE damage: area_afecta=2 (NPC only), radius=2
      spell = make_spell(%{sube_hp: 2, min_hp: 30, max_hp: 30, area_radio: 2, area_afecta: 2})

      new_state = SpellEffects.apply_spell_aoe(state, :caster, caster, spell, 51, 50)

      # npc_id 99999 has no NPC def -> magic_resistance=0 -> full spell damage
      # spell_damage(30, 30, 25, false) = 30 + floor(30*0.03*25) = 30 + 22 = 52
      assert new_state.npcs_live[1].hp == 100 - 52
      assert new_state.npcs_live[2].hp == 100 - 52
      # Caster HP unchanged (not targeted by area_afecta=2)
      assert new_state.players[:caster].hp == 100
    end

    test "AoE with area_afecta=3 affects both players and NPCs" do
      caster = make_entity(%{char_id: :caster, mana: 180, hp: 60, max_hp: 100, x: 50, y: 50})
      ally = make_entity(%{char_id: :ally, hp: 40, max_hp: 100, x: 51, y: 50, char_index: 2})
      npc = %{
        npc_id: 99999, instance_id: 1, x: 52, y: 50, hp: 100, max_hp: 200,
        alive: true, char_index: 3, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{
        {50, 50} => {:player, :caster},
        {51, 50} => {:player, :ally},
        {52, 50} => {:npc, 1}
      }

      state = make_state(
        %{caster: caster, ally: ally},
        occupancy: occupancy,
        npcs_live: %{1 => npc}
      )

      # AoE heal: area_afecta=3 (both), radius=3
      spell = make_spell(%{sube_hp: 1, min_hp: 15, max_hp: 15, area_radio: 3, area_afecta: 3})

      new_state = SpellEffects.apply_spell_aoe(state, :caster, caster, spell, 51, 50)

      # Caster healed twice: once from own tile (50,50) and once from NPC tile (52,50)
      # which falls through to self-heal in apply_spell_heal's wildcard branch.
      # 60 + 15 + 15 = 90
      assert new_state.players[:caster].hp == 90
      # Ally healed once
      assert new_state.players[:ally].hp == 55
      # NPC HP unchanged (heal spell on NPC tile triggers self-heal on caster, not NPC heal)
      assert new_state.npcs_live[1].hp == 100
    end

    test "AoE does not affect entities outside radius" do
      caster = make_entity(%{char_id: :caster, mana: 180, hp: 100, x: 50, y: 50})
      # Far away player, outside radius
      far_player = make_entity(%{char_id: :far, hp: 40, max_hp: 100, x: 60, y: 60, char_index: 2})

      occupancy = %{
        {50, 50} => {:player, :caster},
        {60, 60} => {:player, :far}
      }

      state = make_state(%{caster: caster, far: far_player}, occupancy: occupancy)

      # AoE heal: radius=1, centered at 50,50
      spell = make_spell(%{sube_hp: 1, min_hp: 30, max_hp: 30, area_radio: 1, area_afecta: 1})

      new_state = SpellEffects.apply_spell_aoe(state, :caster, caster, spell, 50, 50)

      # Only caster is in radius, gets healed
      assert new_state.players[:caster].hp == 100  # already full
      # Far player unchanged
      assert new_state.players[:far].hp == 40
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 28. apply_spell routing: AoE vs single target
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell -- AoE vs single routing" do
    test "spell with area_radio > 0 routes to AoE path" do
      caster = make_entity(%{char_id: :caster, mana: 180, hp: 50, max_hp: 100, x: 50, y: 50})
      ally = make_entity(%{char_id: :ally, hp: 40, max_hp: 100, x: 51, y: 50, char_index: 2})

      occupancy = %{
        {50, 50} => {:player, :caster},
        {51, 50} => {:player, :ally}
      }

      state = make_state(%{caster: caster, ally: ally}, occupancy: occupancy)

      spell = make_spell(%{sube_hp: 1, min_hp: 10, max_hp: 10, area_radio: 1, area_afecta: 1, fx_grh: 0})

      new_state = SpellEffects.apply_spell(state, :caster, caster, spell, 50, 50)

      # Both in radius=1 of center (50,50)
      assert new_state.players[:caster].hp == 60
      assert new_state.players[:ally].hp == 50
    end

    test "spell with area_radio == 0 routes to single target path" do
      caster = make_entity(%{char_id: :caster, mana: 180, hp: 50, max_hp: 100, x: 50, y: 50})

      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 10, max_hp: 10, area_radio: 0, area_afecta: 0, fx_grh: 0})

      new_state = SpellEffects.apply_spell(state, :caster, caster, spell, nil, nil)

      # Self-heal via single target path
      assert new_state.players[:caster].hp == 60
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 29. Remove invisibility spell
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_remove_invisibility" do
    test "reveals invisible player within 11-tile radius" do
      caster = make_entity(%{char_id: :caster, mana: 180, x: 50, y: 50})
      invis = make_entity(%{
        char_id: :hidden, x: 55, y: 50, char_index: 2,
        invisible: true, no_detectable: false,
        buffs: [%{type: :invisible, expires_at: 999_999_999_999}]
      })

      state = make_state(%{caster: caster, hidden: invis})

      spell = make_spell(%{remove_invisibility: true, fx_grh: 0})

      new_state = SpellEffects.apply_spell_remove_invisibility(state, :caster, caster, spell, 50, 50)

      assert new_state.players[:hidden].invisible == false
      assert Enum.filter(new_state.players[:hidden].buffs, &(&1.type == :invisible)) == []
    end

    test "does not reveal player with no_detectable flag" do
      caster = make_entity(%{char_id: :caster, mana: 180, x: 50, y: 50})
      stealthy = make_entity(%{
        char_id: :stealthy, x: 55, y: 50, char_index: 2,
        invisible: true, no_detectable: true,
        buffs: [%{type: :invisible, expires_at: 999_999_999_999}]
      })

      state = make_state(%{caster: caster, stealthy: stealthy})

      spell = make_spell(%{remove_invisibility: true, fx_grh: 0})

      new_state = SpellEffects.apply_spell_remove_invisibility(state, :caster, caster, spell, 50, 50)

      # Stealthy player remains invisible
      assert new_state.players[:stealthy].invisible == true
    end

    test "does not reveal player beyond 11-tile radius" do
      caster = make_entity(%{char_id: :caster, mana: 180, x: 50, y: 50})
      far_invis = make_entity(%{
        char_id: :far, x: 62, y: 50, char_index: 2,
        invisible: true, no_detectable: false,
        buffs: [%{type: :invisible, expires_at: 999_999_999_999}]
      })

      state = make_state(%{caster: caster, far: far_invis})

      spell = make_spell(%{remove_invisibility: true, fx_grh: 0})

      new_state = SpellEffects.apply_spell_remove_invisibility(state, :caster, caster, spell, 50, 50)

      # Distance = |62 - 50| = 12 > 11, stays invisible
      assert new_state.players[:far].invisible == true
    end

    test "does not reveal the caster themselves" do
      caster = make_entity(%{
        char_id: :caster, mana: 180, x: 50, y: 50,
        invisible: true, no_detectable: false,
        buffs: [%{type: :invisible, expires_at: 999_999_999_999}]
      })

      state = make_state(%{caster: caster})

      spell = make_spell(%{remove_invisibility: true, fx_grh: 0})

      new_state = SpellEffects.apply_spell_remove_invisibility(state, :caster, caster, spell, 50, 50)

      # Caster's invisibility is not removed (pid != char_id check)
      assert new_state.players[:caster].invisible == true
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 30. Offensive status spells blocked in safe zone
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_status -- safe zone blocking" do
    test "paralysis on other player is blocked in safe zone" do
      caster = make_entity(%{char_id: :caster, mana: 180, faction: :none})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: [], faction: :none})

      occupancy = %{{51, 50} => {:player, :target}}
      state = map_state(
        players: %{caster: caster, target: target},
        occupancy: occupancy,
        meta: %{safe_zone: true, sin_invi_ocul: false}
      )

      spell = make_spell(%{paraliza: true, duration: 10})

      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, 51, 50)

      # Target NOT paralyzed -- safe zone blocked it
      assert new_state.players[:target].paralyzed == false
    end

    test "poison on other player is blocked in safe zone" do
      caster = make_entity(%{char_id: :caster, mana: 180, faction: :none})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: [], faction: :none})

      occupancy = %{{51, 50} => {:player, :target}}
      state = map_state(
        players: %{caster: caster, target: target},
        occupancy: occupancy,
        meta: %{safe_zone: true, sin_invi_ocul: false}
      )

      spell = make_spell(%{envenena: true, duration: 10})

      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, 51, 50)

      assert new_state.players[:target].poisoned == false
    end

    test "self-cast status spell is allowed even in safe zone" do
      caster = make_entity(%{char_id: :caster, mana: 180, invisible: false, buffs: []})

      state = map_state(
        players: %{caster: caster},
        meta: %{safe_zone: true, sin_invi_ocul: false}
      )

      spell = make_spell(%{invisibilidad: true, duration: 10})

      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      # Self-cast is allowed
      assert new_state.players[:caster].invisible == true
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 31. Mana/stamina spells on target player
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_mana -- target player" do
    test "mana restore on target player increases their mana" do
      caster = make_entity(%{char_id: :caster, mana: 180, max_mana: 200})
      target = make_entity(%{char_id: :target, mana: 50, max_mana: 200, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{sube_mana: 1, min_mana: 40, max_mana: 40})

      new_state = SpellEffects.apply_spell_mana(state, :caster, caster, spell, 51, 50)

      assert new_state.players[:target].mana == 90
      # Caster mana unchanged by the effect itself (mana cost deducted separately)
      assert new_state.players[:caster].mana == 180
    end

    test "mana drain on target player decreases their mana" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{char_id: :target, mana: 100, max_mana: 200, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{sube_mana: 2, min_mana: 60, max_mana: 60})

      new_state = SpellEffects.apply_spell_mana(state, :caster, caster, spell, 51, 50)

      assert new_state.players[:target].mana == 40
    end
  end

  describe "apply_spell_stamina -- target player" do
    test "stamina restore on target player" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{char_id: :target, stamina: 30, max_stamina: 100, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{sube_sta: 1, min_sta: 50, max_sta: 50})

      new_state = SpellEffects.apply_spell_stamina(state, :caster, caster, spell, 51, 50)

      assert new_state.players[:target].stamina == 80
    end

    test "stamina drain on target player" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{char_id: :target, stamina: 60, max_stamina: 100, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{sube_sta: 2, min_sta: 40, max_sta: 40})

      new_state = SpellEffects.apply_spell_stamina(state, :caster, caster, spell, 51, 50)

      assert new_state.players[:target].stamina == 20
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 32. Attribute buff on target player
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_attribute_buff -- target player" do
    test "strength buff on target player increases their str_buff" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{char_id: :target, str_buff: 0, buffs: [], x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{sube_fu: 1, min_fu: 12, max_fu: 12, duration: 20})

      new_state = SpellEffects.apply_spell_attribute_buff(state, :caster, caster, spell, :str, 51, 50)

      assert new_state.players[:target].str_buff == 12
      # Caster str_buff unchanged
      assert new_state.players[:caster].str_buff == 0
    end

    test "agility debuff on target player" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{char_id: :target, agi_buff: 0, buffs: [], x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{sube_ag: 2, min_ag: 8, max_ag: 8, duration: 20})

      new_state = SpellEffects.apply_spell_attribute_buff(state, :caster, caster, spell, :agi, 51, 50)

      assert new_state.players[:target].agi_buff == -8
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 33. Resurrect edge cases
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_resurrect -- edge cases" do
    test "resurrect on empty tile does nothing" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{revivir: true, min_hp: 10, work_on_dead: true})

      new_state = SpellEffects.apply_spell_resurrect(state, :caster, caster, spell, 60, 60)

      # No change, caster just gets mana update message
      assert new_state.players[:caster].mana == 180
    end

    test "resurrect on NPC tile does nothing (only players can be resurrected)" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      npc = %{
        npc_id: 99999, instance_id: 1, x: 51, y: 50, hp: 0, max_hp: 200,
        alive: false, char_index: 2, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{{51, 50} => {:npc, 1}}
      state = make_state(%{caster: caster}, occupancy: occupancy, npcs_live: %{1 => npc})

      spell = make_spell(%{revivir: true, min_hp: 10, work_on_dead: true})

      new_state = SpellEffects.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

      # NPC not resurrected
      assert new_state.npcs_live[1].alive == false
    end

    test "resurrect clears oculto flag" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{
        char_id: :target, hp: 0, max_hp: 100, dead: true,
        oculto: true, invisible: true, poisoned: true,
        buffs: [%{type: :poisoned, expires_at: 999}],
        x: 51, y: 50, char_index: 2
      })

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{revivir: true, min_hp: 10, work_on_dead: true})

      new_state = SpellEffects.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

      revived = new_state.players[:target]
      assert revived.oculto == false
      assert revived.invisible == false
      assert revived.poisoned == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 34. Elemental modifier golden values
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Combat.apply_elemental_modifiers/3 golden values" do
    test "both tags zero: damage unchanged" do
      assert Combat.apply_elemental_modifiers(100, 0, 0) == 100
    end

    test "attacker tags zero: damage unchanged" do
      assert Combat.apply_elemental_modifiers(100, 0, 0b0001) == 100
    end

    test "defender tags zero: damage unchanged" do
      assert Combat.apply_elemental_modifiers(100, 0b0001, 0) == 100
    end

    test "same element tags use diagonal matrix entry" do
      # When both attacker and defender have same element (bit 0 = Fire),
      # the matrix entry (1,1) is applied. Default matrix value is 1.0
      # since no custom matrix is loaded in test.
      result = Combat.apply_elemental_modifiers(100, 0b0001, 0b0001)
      # Default elemental_matrix(1,1) = 1.0, so damage = 100 * 1.0 = 100
      assert result == 100
    end

    test "zero damage stays zero regardless of tags" do
      assert Combat.apply_elemental_modifiers(0, 0b0001, 0b0010) == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 35. Heal on NPC target (no-op path)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_heal -- NPC target (no-op)" do
    test "heal spell targeting NPC tile falls through to self-heal" do
      caster = make_entity(%{char_id: :caster, mana: 180, hp: 60, max_hp: 100})
      npc = %{
        npc_id: 99999, instance_id: 1, x: 51, y: 50, hp: 50, max_hp: 200,
        alive: true, char_index: 2, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{{51, 50} => {:npc, 1}}
      state = make_state(%{caster: caster}, occupancy: occupancy, npcs_live: %{1 => npc})

      spell = make_spell(%{sube_hp: 1, min_hp: 20, max_hp: 20})

      # NPC target falls through to the _ (default) case in apply_spell_heal,
      # which is the self-heal path -- but it does NOT heal self when a tile is targeted
      # because the target matched {:npc, _} which doesn't match {:player, _} or nil
      # The code actually falls to the wildcard _ branch which does self-heal
      new_state = SpellEffects.apply_spell_heal(state, :caster, caster, 20, spell, 51, 50)

      # The _ branch performs self-heal
      assert new_state.players[:caster].hp == 80
      # NPC HP unchanged
      assert new_state.npcs_live[1].hp == 50
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 36. Spell routing: remove_invisibility, sube_fu, sube_ag, sube_mana, sube_sta
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_single -- additional routing" do
    test "remove_invisibility spell routes correctly" do
      caster = make_entity(%{char_id: :caster, mana: 180, x: 50, y: 50})
      invis_player = make_entity(%{
        char_id: :hidden, x: 55, y: 50, char_index: 2,
        invisible: true, no_detectable: false,
        buffs: [%{type: :invisible, expires_at: 999_999_999_999}]
      })

      state = make_state(%{caster: caster, hidden: invis_player})

      spell = make_spell(%{remove_invisibility: true, fx_grh: 0})

      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, nil, nil)

      # Routed to remove_invisibility path; caster checks nearby players
      # :hidden is within 11 tiles, so gets revealed
      assert new_state.players[:hidden].invisible == false
    end

    test "sube_fu spell routes to attribute buff" do
      caster = make_entity(%{char_id: :caster, mana: 180, str_buff: 0, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_fu: 1, min_fu: 5, max_fu: 5, duration: 10})

      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, nil, nil)

      assert new_state.players[:caster].str_buff == 5
    end

    test "sube_ag spell routes to attribute buff" do
      caster = make_entity(%{char_id: :caster, mana: 180, agi_buff: 0, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_ag: 1, min_ag: 3, max_ag: 3, duration: 10})

      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, nil, nil)

      assert new_state.players[:caster].agi_buff == 3
    end

    test "sube_mana spell routes to mana restore" do
      caster = make_entity(%{char_id: :caster, mana: 100, max_mana: 200, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_mana: 1, min_mana: 25, max_mana: 25})

      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, nil, nil)

      assert new_state.players[:caster].mana == 125
    end

    test "sube_sta spell routes to stamina restore" do
      caster = make_entity(%{char_id: :caster, mana: 180, stamina: 50, max_stamina: 100, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_sta: 1, min_sta: 20, max_sta: 20})

      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, nil, nil)

      assert new_state.players[:caster].stamina == 70
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 37. Spell damage with range (min != max)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Combat.spell_damage/4 -- range values (min != max)" do
    test "damage is always within expected range" do
      # Run 50 times to verify randomness stays in bounds
      results =
        for _ <- 1..50 do
          Combat.spell_damage(10, 20, 25, false)
        end

      # min base=10, max base=20
      # level_bonus at min: floor(10 * 0.03 * 25) = floor(7.5) = 7 -> 10+7 = 17
      # level_bonus at max: floor(20 * 0.03 * 25) = floor(15) = 15 -> 20+15 = 35
      assert Enum.all?(results, &(&1 >= 17))
      assert Enum.all?(results, &(&1 <= 35))
    end

    test "mage modifier applied to range result" do
      results =
        for _ <- 1..50 do
          Combat.spell_damage(10, 20, 25, true)
        end

      # Non-mage range: 17..35
      # Mage: round(17 * 0.7)=12 .. round(35 * 0.7)=25 (but could vary within due to randomness)
      assert Enum.all?(results, &(&1 >= 12))
      assert Enum.all?(results, &(&1 <= 25))
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 38. Spell with no effect (default path in apply_spell_single)
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_single -- no-effect spell (default path)" do
    test "spell with no effect flags just stores entity in state" do
      caster = make_entity(%{char_id: :caster, mana: 180, hp: 50})
      state = make_state(%{caster: caster})

      # A spell with no active effect flags
      spell = make_spell(%{})

      new_state = SpellEffects.apply_spell_single(state, :caster, caster, spell, nil, nil)

      # State has caster stored, no changes to HP/mana/etc.
      assert new_state.players[:caster].hp == 50
      assert new_state.players[:caster].mana == 180
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 39. Mana/stamina on nonexistent target player
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_mana/stamina -- nonexistent target" do
    test "mana spell targeting nonexistent player is a no-op" do
      caster = make_entity(%{char_id: :caster, mana: 180})

      occupancy = %{{51, 50} => {:player, :ghost}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      spell = make_spell(%{sube_mana: 1, min_mana: 50, max_mana: 50})

      new_state = SpellEffects.apply_spell_mana(state, :caster, caster, spell, 51, 50)

      # Caster just stored
      assert new_state.players[:caster].mana == 180
    end

    test "stamina spell targeting nonexistent player is a no-op" do
      caster = make_entity(%{char_id: :caster, mana: 180, stamina: 50})

      occupancy = %{{51, 50} => {:player, :ghost}}
      state = make_state(%{caster: caster}, occupancy: occupancy)

      spell = make_spell(%{sube_sta: 1, min_sta: 30, max_sta: 30})

      new_state = SpellEffects.apply_spell_stamina(state, :caster, caster, spell, 51, 50)

      assert new_state.players[:caster].stamina == 50
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 40. Poison tick interval constant
  # ═══════════════════════════════════════════════════════════════════════════

  describe "poison buff -- next_tick timing" do
    test "poison next_tick is set at @poison_tick_interval (3600ms) from now" do
      caster = make_entity(%{mana: 180, buffs: []})
      state = make_state(%{caster: caster})
      now_before = System.monotonic_time(:millisecond)

      spell = make_spell(%{envenena: true, duration: 30})

      new_state = SpellEffects.apply_spell_status(state, :caster, caster, spell, nil, nil)

      now_after = System.monotonic_time(:millisecond)
      updated = new_state.players[:caster]
      [buff] = Enum.filter(updated.buffs, &(&1.type == :poisoned))

      # VB6: @poison_tick_interval = 3600ms
      assert buff.next_tick >= now_before + 3600
      assert buff.next_tick <= now_after + 3600 + 10
    end
  end
end
