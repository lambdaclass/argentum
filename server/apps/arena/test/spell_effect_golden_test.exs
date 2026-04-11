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
  alias Arena.Map.CombatHandlers

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
      paralyzed: false,
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
  # Occupancy uses :array (100x100 grid) matching production MapServer.
  defp make_state(players, opts \\ []) do
    occupancy_map = Keyword.get(opts, :occupancy, %{})
    npcs_live = Keyword.get(opts, :npcs_live, %{})

    # Build a real :array occupancy grid (100x100)
    base_occ = :array.new(100 * 100, default: nil)

    occupancy =
      Enum.reduce(occupancy_map, base_occ, fn {{x, y}, value}, acc ->
        idx = (y - 1) * 100 + (x - 1)
        :array.set(idx, value, acc)
      end)

    %{
      players: players,
      sessions: %{},
      occupancy: occupancy,
      npcs_live: npcs_live,
      map_id: 1,
      floor_items: %{},
      next_floor_id: 1,
      visibility_mode: :global
    }
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
      new_state = CombatHandlers.apply_spell_heal(state, :caster, caster, 50, spell, nil, nil)

      updated = new_state.players[:caster]
      # 80 + 50 = 130, capped at max_hp = 100
      assert updated.hp == 100
    end

    test "heal below max_hp adds exact amount" do
      caster = make_entity(%{hp: 40, max_hp: 100, mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 30, max_hp: 30, mana_required: 20})
      new_state = CombatHandlers.apply_spell_heal(state, :caster, caster, 30, spell, nil, nil)

      updated = new_state.players[:caster]
      # 40 + 30 = 70
      assert updated.hp == 70
    end

    test "heal at full HP stays at max" do
      caster = make_entity(%{hp: 100, max_hp: 100, mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 50, max_hp: 50, mana_required: 20})
      new_state = CombatHandlers.apply_spell_heal(state, :caster, caster, 50, spell, nil, nil)

      updated = new_state.players[:caster]
      assert updated.hp == 100
    end

    test "zero heal leaves HP unchanged" do
      caster = make_entity(%{hp: 50, max_hp: 100, mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 0, max_hp: 0, mana_required: 20})
      new_state = CombatHandlers.apply_spell_heal(state, :caster, caster, 0, spell, nil, nil)

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
      new_state = CombatHandlers.apply_spell_heal(state, :caster, caster, 40, spell, 51, 50)

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
      new_state = CombatHandlers.apply_spell_heal(state, :caster, caster, 40, spell, 51, 50)

      # Dead target HP not changed
      assert new_state.players[:target].hp == 0
      assert new_state.players[:target].dead == true
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 4. Status effects: paralysis, poison, invis, immobilize, cure poison
  # ═══════════════════════════════════════════════════════════════════════════

  describe "apply_spell_status -- paralysis" do
    test "applies paralyzed flag and buff with halved duration" do
      caster = make_entity(%{mana: 180})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: []})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{paraliza: true, duration: 10, mana_required: 20})
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, 51, 50)

      updated_target = new_state.players[:target]
      assert updated_target.paralyzed == true

      [buff] = Enum.filter(updated_target.buffs, &(&1.type == :paralyzed))
      # VB6: paralysis duration is halved. duration=10 -> 10000ms, halved -> 5000ms
      # expires_at = now + 5000
      assert buff.type == :paralyzed
      # Verify the buff exists; exact expires_at depends on monotonic time
      assert is_integer(buff.expires_at)
    end
  end

  describe "apply_spell_status -- poison" do
    test "applies poisoned flag with full duration" do
      caster = make_entity(%{mana: 180})
      state = make_state(%{caster: caster})

      spell = make_spell(%{envenena: true, duration: 10, mana_required: 20})
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, nil, nil)

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
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      assert updated.poisoned == false
      assert Enum.filter(updated.buffs, &(&1.type == :poisoned)) == []
    end

    test "cure poison on non-poisoned player is a no-op" do
      caster = make_entity(%{mana: 180, poisoned: false, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{cura_veneno: true, mana_required: 20})
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, nil, nil)

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
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, nil, nil)

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
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      invis_buffs = Enum.filter(updated.buffs, &(&1.type == :invisible))
      # Only one invisibility buff (replaced, not stacked)
      assert length(invis_buffs) == 1
    end
  end

  describe "apply_spell_status -- immobilize" do
    test "applies immobilized flag with halved duration" do
      caster = make_entity(%{mana: 180, immobilized: false, buffs: []})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: []})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{inmoviliza: true, duration: 10, mana_required: 20})
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, 51, 50)

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
      new_state = CombatHandlers.apply_spell_attribute_buff(state, :caster, caster, spell, :str, nil, nil)

      updated = new_state.players[:caster]
      assert updated.str_buff == 10

      [buff] = Enum.filter(updated.buffs, &(&1.type == :str_buff))
      assert buff.value == 10
    end

    test "strength debuff (sube_fu=2) decreases str_buff" do
      caster = make_entity(%{mana: 180, str_buff: 0, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_fu: 2, min_fu: 5, max_fu: 5, duration: 20, mana_required: 20})
      new_state = CombatHandlers.apply_spell_attribute_buff(state, :caster, caster, spell, :str, nil, nil)

      updated = new_state.players[:caster]
      assert updated.str_buff == -5

      [buff] = Enum.filter(updated.buffs, &(&1.type == :str_buff))
      assert buff.value == -5
    end

    test "multiple str buffs stack additively" do
      caster = make_entity(%{mana: 180, str_buff: 5, buffs: [%{type: :str_buff, expires_at: 999_999_999_999, value: 5}]})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_fu: 1, min_fu: 7, max_fu: 7, duration: 20, mana_required: 20})
      new_state = CombatHandlers.apply_spell_attribute_buff(state, :caster, caster, spell, :str, nil, nil)

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
      new_state = CombatHandlers.apply_spell_attribute_buff(state, :caster, caster, spell, :agi, nil, nil)

      updated = new_state.players[:caster]
      assert updated.agi_buff == 8

      [buff] = Enum.filter(updated.buffs, &(&1.type == :agi_buff))
      assert buff.value == 8
    end

    test "agility debuff (sube_ag=2) decreases agi_buff" do
      caster = make_entity(%{mana: 180, agi_buff: 0, buffs: []})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_ag: 2, min_ag: 6, max_ag: 6, duration: 20, mana_required: 20})
      new_state = CombatHandlers.apply_spell_attribute_buff(state, :caster, caster, spell, :agi, nil, nil)

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
      new_state = CombatHandlers.apply_spell_mana(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      # 180 + 50 = 230, capped at 200
      assert updated.mana == 200
    end

    test "mana drain (sube_mana=2) decreases target mana, floors at 0" do
      caster = make_entity(%{mana: 30, max_mana: 200})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_mana: 2, min_mana: 50, max_mana: 50, mana_required: 0})
      new_state = CombatHandlers.apply_spell_mana(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      # 30 - 50 = -20, floored at 0
      assert updated.mana == 0
    end

    test "mana restore below cap adds exact amount" do
      caster = make_entity(%{mana: 100, max_mana: 200})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_mana: 1, min_mana: 30, max_mana: 30, mana_required: 0})
      new_state = CombatHandlers.apply_spell_mana(state, :caster, caster, spell, nil, nil)

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
      new_state = CombatHandlers.apply_spell_stamina(state, :caster, caster, spell, nil, nil)

      updated = new_state.players[:caster]
      # 80 + 30 = 110, capped at 100
      assert updated.stamina == 100
    end

    test "stamina drain (sube_sta=2) decreases stamina, floors at 0" do
      caster = make_entity(%{mana: 180, stamina: 10, max_stamina: 100})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_sta: 2, min_sta: 25, max_sta: 25, mana_required: 20})
      new_state = CombatHandlers.apply_spell_stamina(state, :caster, caster, spell, nil, nil)

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
      new_state = CombatHandlers.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

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
      new_state = CombatHandlers.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

      assert new_state.players[:target].hp == 250
      assert new_state.players[:target].dead == false
    end

    test "resurrect on living target does nothing" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{char_id: :target, hp: 50, max_hp: 100, dead: false, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{revivir: true, min_hp: 10, mana_required: 20, work_on_dead: true})
      new_state = CombatHandlers.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

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
      new_state = CombatHandlers.apply_spell_resurrect(state, :caster, caster, spell, 51, 50)

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
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
      assert result == {:error, :not_enough_mana}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end

    test "sufficient mana deducts cost" do
      spell_id = 9998
      spell_def = make_spell(%{id: spell_id, mana_required: 20, min_skill: 0, sube_hp: 1, min_hp: 10, max_hp: 10})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 100, hp: 50, max_hp: 100, spells: [spell_id], spell_cooldowns: %{}})
      state = make_state(%{caster: caster})

      {:reply, :ok, new_state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

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
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
      assert result == {:error, :skill_too_low}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end

    test "exact minimum skill allows casting" do
      spell_id = 9996
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 50, sube_hp: 1, min_hp: 5, max_hp: 5})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, hp: 50, max_hp: 100, skills: %{magic: 50}, spells: [spell_id], spell_cooldowns: %{}})
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
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
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
      assert result == {:error, :level_too_high}

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end

    test "caster at exactly max level can cast" do
      spell_id = 9990
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 0, max_level_casteable: 25, sube_hp: 1, min_hp: 5, max_hp: 5})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, level: 25, hp: 50, max_hp: 100, spells: [spell_id], spell_cooldowns: %{}})
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
      assert result == :ok

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end

    test "max_level_casteable 0 means no limit" do
      spell_id = 9989
      spell_def = make_spell(%{id: spell_id, mana_required: 10, min_skill: 0, max_level_casteable: 0, sube_hp: 1, min_hp: 5, max_hp: 5})
      :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})

      caster = make_entity(%{mana: 200, level: 99, hp: 50, max_hp: 100, spells: [spell_id], spell_cooldowns: %{}})
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
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
      state = make_state(%{caster: caster})

      {:reply, result, _state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)
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
      new_state = CombatHandlers.apply_spell_single(state, :caster, caster, spell, nil, nil)

      # State updated (caster stored)
      assert Map.has_key?(new_state.players, :caster)
    end

    test "sube_hp=1 routes to heal path" do
      caster = make_entity(%{mana: 180, hp: 50, max_hp: 100})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sube_hp: 1, min_hp: 20, max_hp: 20, mana_required: 20})
      new_state = CombatHandlers.apply_spell_single(state, :caster, caster, spell, nil, nil)

      assert new_state.players[:caster].hp == 70
    end

    test "sanacion routes to heal path" do
      caster = make_entity(%{mana: 180, hp: 50, max_hp: 100})
      state = make_state(%{caster: caster})

      spell = make_spell(%{sanacion: true, min_hp: 15, max_hp: 15, mana_required: 20})
      new_state = CombatHandlers.apply_spell_single(state, :caster, caster, spell, nil, nil)

      assert new_state.players[:caster].hp == 65
    end

    test "revivir routes to resurrect path" do
      caster = make_entity(%{char_id: :caster, mana: 180})
      target = make_entity(%{char_id: :target, hp: 0, max_hp: 100, dead: true, buffs: [], x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{revivir: true, min_hp: 10, mana_required: 20, work_on_dead: true})
      new_state = CombatHandlers.apply_spell_single(state, :caster, caster, spell, 51, 50)

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
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, nil, nil)

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
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, nil, nil)

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
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, nil, nil)

      now_after = System.monotonic_time(:millisecond)

      updated = new_state.players[:caster]
      [buff] = Enum.filter(updated.buffs, &(&1.type == :invisible))

      # max(10 * 1000, 3000) = 10000
      assert buff.expires_at >= now_before + 10_000
      assert buff.expires_at <= now_after + 10_000 + 10
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 22. Paralysis and immobilize use halved duration
  # ═══════════════════════════════════════════════════════════════════════════

  describe "paralysis/immobilize halved duration" do
    test "paralysis duration is halved compared to full duration" do
      caster = make_entity(%{mana: 180, buffs: []})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: []})
      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)
      now_before = System.monotonic_time(:millisecond)

      spell = make_spell(%{paraliza: true, duration: 20, mana_required: 20})
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, 51, 50)

      now_after = System.monotonic_time(:millisecond)

      updated_target = new_state.players[:target]
      [buff] = Enum.filter(updated_target.buffs, &(&1.type == :paralyzed))

      # VB6: paralysis uses div(duration_ms, 2)
      # duration_ms = max(20 * 1000, 3000) = 20000
      # halved = 10000
      assert buff.expires_at >= now_before + 10_000
      assert buff.expires_at <= now_after + 10_000 + 10
    end

    test "immobilize duration is halved" do
      caster = make_entity(%{mana: 180, buffs: []})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2, buffs: []})
      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)
      now_before = System.monotonic_time(:millisecond)

      spell = make_spell(%{inmoviliza: true, duration: 20, mana_required: 20})
      new_state = CombatHandlers.apply_spell_status(state, :caster, caster, spell, 51, 50)

      now_after = System.monotonic_time(:millisecond)

      updated_target = new_state.players[:target]
      [buff] = Enum.filter(updated_target.buffs, &(&1.type == :immobilized))

      assert buff.expires_at >= now_before + 10_000
      assert buff.expires_at <= now_after + 10_000 + 10
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
      state = make_state(%{caster: caster})

      {:reply, :ok, new_state} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

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
end
