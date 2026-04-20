defmodule Arena.SpellEffectsParityDriftTest do
  @moduledoc """
  Tests for VB6 parity drifts in spell effects.

  Drift #5: PvP spell damage missing weapon/ring magic bonuses, armor MR,
            penetration, AntiRm, and MagicDamageModifier/Reduction.
  Drift #8: Paralysis/Immobilize missing 0.7x duration for Warrior/Hunter.
  """
  use ExUnit.Case, async: true

  alias Arena.Data.{GameData, SpellDef}
  alias Arena.Map.SpellEffects

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

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
      hp: 500,
      max_hp: 500,
      mana: 500,
      max_mana: 500,
      stamina: 100,
      max_stamina: 100,
      hunger: 100,
      thirst: 100,
      level: 25,
      xp: 0,
      skill_points: 0,
      class: :mago,
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
      skills: %{magic: 80, resistance: 0},
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
      trade_offer_items: [],
      magic_damage_modifier: 0.0,
      magic_damage_reduction: 0.0
    }

    Map.merge(defaults, overrides)
  end

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
  # Drift #8: Paralysis/Immobilize 0.7x for Warrior/Hunter
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift #8: Warrior/Hunter get 0.7x paralysis duration" do
    test "guerrero target gets shorter paralysis than mago target" do
      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1})

      guerrero_target =
        make_entity(%{
          char_id: :guerrero_target,
          x: 51,
          y: 50,
          char_index: 2,
          class: :guerrero,
          criminal: true
        })

      mago_target =
        make_entity(%{
          char_id: :mago_target,
          x: 52,
          y: 50,
          char_index: 3,
          class: :mago,
          criminal: true
        })

      spell = make_spell(%{paraliza: true, duration: 10})

      # Apply paralysis to guerrero
      state_g =
        make_state(
          %{caster: caster, guerrero_target: guerrero_target},
          occupancy: %{{51, 50} => {:player, :guerrero_target}}
        )

      state_g = SpellEffects.apply_spell(state_g, :caster, caster, spell, 51, 50)
      guerrero_after = state_g.players[:guerrero_target]
      assert guerrero_after.paralyzed == true
      guerrero_buff = Enum.find(guerrero_after.buffs, &(&1.type == :paralyzed))
      assert guerrero_buff != nil

      # Apply paralysis to mago
      state_m =
        make_state(
          %{caster: caster, mago_target: mago_target},
          occupancy: %{{52, 50} => {:player, :mago_target}}
        )

      state_m = SpellEffects.apply_spell(state_m, :caster, caster, spell, 52, 50)
      mago_after = state_m.players[:mago_target]
      assert mago_after.paralyzed == true
      mago_buff = Enum.find(mago_after.buffs, &(&1.type == :paralyzed))
      assert mago_buff != nil

      # Guerrero duration should be shorter (0.7x of mago duration)
      guerrero_duration = guerrero_buff.expires_at - System.monotonic_time(:millisecond)
      mago_duration = mago_buff.expires_at - System.monotonic_time(:millisecond)

      # VB6: Warrior gets Duration * 0.7, others get Duration (full).
      ratio = guerrero_duration / mago_duration
      assert ratio < 0.8, "Guerrero should get ~0.7x paralysis duration, got ratio #{ratio}"
    end

    test "non-warrior paralysis duration matches VB6 full duration (no halving)" do
      # VB6: non-warrior/hunter gets full Duration. There is NO halving.
      # Spell duration=10 → duration_ms=10000, min 3000 → 10000ms
      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1})

      target =
        make_entity(%{
          char_id: :target,
          x: 51,
          y: 50,
          char_index: 2,
          class: :mago,
          criminal: true
        })

      spell = make_spell(%{paraliza: true, duration: 10})

      now = System.monotonic_time(:millisecond)

      state =
        make_state(
          %{caster: caster, target: target},
          occupancy: %{{51, 50} => {:player, :target}}
        )

      state = SpellEffects.apply_spell(state, :caster, caster, spell, 51, 50)
      target_after = state.players[:target]
      buff = Enum.find(target_after.buffs, &(&1.type == :paralyzed))

      # VB6: duration should be full 10000ms (not halved to 5000ms)
      actual_duration = buff.expires_at - now
      assert actual_duration > 8_000,
             "VB6: non-warrior paralysis should be ~10000ms, got #{actual_duration}ms (halving bug)"
    end

    test "cazador target gets shorter paralysis than clerigo target" do
      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1})

      cazador_target =
        make_entity(%{
          char_id: :cazador_target,
          x: 51,
          y: 50,
          char_index: 2,
          class: :cazador,
          criminal: true
        })

      clerigo_target =
        make_entity(%{
          char_id: :clerigo_target,
          x: 52,
          y: 50,
          char_index: 3,
          class: :clerigo,
          criminal: true
        })

      spell = make_spell(%{paraliza: true, duration: 10})

      # Apply to cazador
      state_c =
        make_state(
          %{caster: caster, cazador_target: cazador_target},
          occupancy: %{{51, 50} => {:player, :cazador_target}}
        )

      state_c = SpellEffects.apply_spell(state_c, :caster, caster, spell, 51, 50)
      cazador_after = state_c.players[:cazador_target]
      cazador_buff = Enum.find(cazador_after.buffs, &(&1.type == :paralyzed))

      # Apply to clerigo
      state_cl =
        make_state(
          %{caster: caster, clerigo_target: clerigo_target},
          occupancy: %{{52, 50} => {:player, :clerigo_target}}
        )

      state_cl = SpellEffects.apply_spell(state_cl, :caster, caster, spell, 52, 50)
      clerigo_after = state_cl.players[:clerigo_target]
      clerigo_buff = Enum.find(clerigo_after.buffs, &(&1.type == :paralyzed))

      cazador_dur = cazador_buff.expires_at - System.monotonic_time(:millisecond)
      clerigo_dur = clerigo_buff.expires_at - System.monotonic_time(:millisecond)

      ratio = cazador_dur / clerigo_dur
      assert ratio < 0.8, "Cazador should get ~0.7x paralysis duration, got ratio #{ratio}"
    end
  end

  describe "Drift #8: Warrior/Hunter get 0.7x immobilize duration" do
    test "guerrero target gets shorter immobilize than mago target" do
      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1})

      guerrero_target =
        make_entity(%{
          char_id: :guerrero_target,
          x: 51,
          y: 50,
          char_index: 2,
          class: :guerrero,
          criminal: true
        })

      mago_target =
        make_entity(%{
          char_id: :mago_target,
          x: 52,
          y: 50,
          char_index: 3,
          class: :mago,
          criminal: true
        })

      spell = make_spell(%{inmoviliza: true, duration: 10})

      # Apply to guerrero
      state_g =
        make_state(
          %{caster: caster, guerrero_target: guerrero_target},
          occupancy: %{{51, 50} => {:player, :guerrero_target}}
        )

      state_g = SpellEffects.apply_spell(state_g, :caster, caster, spell, 51, 50)
      guerrero_after = state_g.players[:guerrero_target]
      assert guerrero_after.immobilized == true
      guerrero_buff = Enum.find(guerrero_after.buffs, &(&1.type == :immobilized))

      # Apply to mago
      state_m =
        make_state(
          %{caster: caster, mago_target: mago_target},
          occupancy: %{{52, 50} => {:player, :mago_target}}
        )

      state_m = SpellEffects.apply_spell(state_m, :caster, caster, spell, 52, 50)
      mago_after = state_m.players[:mago_target]
      mago_buff = Enum.find(mago_after.buffs, &(&1.type == :immobilized))

      guerrero_dur = guerrero_buff.expires_at - System.monotonic_time(:millisecond)
      mago_dur = mago_buff.expires_at - System.monotonic_time(:millisecond)

      ratio = guerrero_dur / mago_dur
      assert ratio < 0.8, "Guerrero should get ~0.7x immobilize duration, got ratio #{ratio}"
    end

    test "cazador target gets shorter immobilize than bardo target" do
      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1})

      cazador_target =
        make_entity(%{
          char_id: :cazador_target,
          x: 51,
          y: 50,
          char_index: 2,
          class: :cazador,
          criminal: true
        })

      bardo_target =
        make_entity(%{
          char_id: :bardo_target,
          x: 52,
          y: 50,
          char_index: 3,
          class: :bardo,
          criminal: true
        })

      spell = make_spell(%{inmoviliza: true, duration: 10})

      state_c =
        make_state(
          %{caster: caster, cazador_target: cazador_target},
          occupancy: %{{51, 50} => {:player, :cazador_target}}
        )

      state_c = SpellEffects.apply_spell(state_c, :caster, caster, spell, 51, 50)
      cazador_after = state_c.players[:cazador_target]
      cazador_buff = Enum.find(cazador_after.buffs, &(&1.type == :immobilized))

      state_b =
        make_state(
          %{caster: caster, bardo_target: bardo_target},
          occupancy: %{{52, 50} => {:player, :bardo_target}}
        )

      state_b = SpellEffects.apply_spell(state_b, :caster, caster, spell, 52, 50)
      bardo_after = state_b.players[:bardo_target]
      bardo_buff = Enum.find(bardo_after.buffs, &(&1.type == :immobilized))

      cazador_dur = cazador_buff.expires_at - System.monotonic_time(:millisecond)
      bardo_dur = bardo_buff.expires_at - System.monotonic_time(:millisecond)

      ratio = cazador_dur / bardo_dur
      assert ratio < 0.8, "Cazador should get ~0.7x immobilize duration, got ratio #{ratio}"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Drift #5: PvP spell damage formula parity
  # ═══════════════════════════════════════════════════════════════════════════

  describe "Drift #5: weapon magic bonuses apply to PvP spell damage" do
    test "weapon with MagicDamageBonus increases spell damage" do
      # Register a test weapon item with magic_damage_bonus = 50 (50% bonus)
      weapon_id = 9990
      weapon_def = %Arena.Data.ItemDef{
        id: weapon_id,
        name: "Magic Wand",
        obj_type: 2,
        magic_damage_bonus: 50,
        magic_absolute_bonus: 0,
        magic_penetration: 0,
        resistencia_magica: 0
      }
      :ets.insert(:arena_game_data, {{:item, weapon_id}, weapon_def})

      caster =
        make_entity(%{
          char_id: :caster,
          x: 50,
          y: 50,
          char_index: 1,
          class: :guerrero,
          equipment: %{weapon: weapon_id, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil}
        })

      defender =
        make_entity(%{
          char_id: :defender,
          x: 51,
          y: 50,
          char_index: 2,
          hp: 500,
          max_hp: 500,
          criminal: true,
          skills: %{resistance: 0}
        })

      # Deterministic damage (min == max)
      spell = make_spell(%{sube_hp: 2, min_hp: 100, max_hp: 100, anti_rm: 0})

      state_with_weapon =
        make_state(
          %{caster: caster, defender: defender},
          occupancy: %{{51, 50} => {:player, :defender}}
        )

      state_with_weapon = SpellEffects.apply_spell(state_with_weapon, :caster, caster, spell, 51, 50)
      defender_after_w = state_with_weapon.players[:defender]

      # Now without weapon
      caster_no_weapon = %{caster | equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil}}

      state_no_weapon =
        make_state(
          %{caster: caster_no_weapon, defender: defender},
          occupancy: %{{51, 50} => {:player, :defender}}
        )

      state_no_weapon = SpellEffects.apply_spell(state_no_weapon, :caster, caster_no_weapon, spell, 51, 50)
      defender_after_nw = state_no_weapon.players[:defender]

      # With 50% magic bonus weapon, damage should be higher (HP should be lower)
      damage_with = defender.hp - defender_after_w.hp
      damage_without = defender.hp - defender_after_nw.hp

      assert damage_with > damage_without,
             "Weapon magic bonus should increase damage: with=#{damage_with} without=#{damage_without}"
    end

    test "weapon with MagicAbsoluteBonus adds flat damage" do
      weapon_id = 9991
      weapon_def = %Arena.Data.ItemDef{
        id: weapon_id,
        name: "Magic Staff",
        obj_type: 2,
        magic_damage_bonus: 0,
        magic_absolute_bonus: 25,
        magic_penetration: 0,
        resistencia_magica: 0
      }
      :ets.insert(:arena_game_data, {{:item, weapon_id}, weapon_def})

      caster =
        make_entity(%{
          char_id: :caster,
          x: 50,
          y: 50,
          char_index: 1,
          class: :guerrero,
          equipment: %{weapon: weapon_id, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil}
        })

      defender =
        make_entity(%{
          char_id: :defender,
          x: 51,
          y: 50,
          char_index: 2,
          hp: 500,
          max_hp: 500,
          criminal: true,
          skills: %{resistance: 0}
        })

      spell = make_spell(%{sube_hp: 2, min_hp: 100, max_hp: 100, anti_rm: 0})

      state =
        make_state(
          %{caster: caster, defender: defender},
          occupancy: %{{51, 50} => {:player, :defender}}
        )

      state = SpellEffects.apply_spell(state, :caster, caster, spell, 51, 50)
      defender_after = state.players[:defender]
      damage = defender.hp - defender_after.hp

      # Base damage for level 25 non-mage: 100 + floor(100 * 0.03 * 25) = 100 + 75 = 175
      # With +25 absolute bonus: 175 + 25 = 200
      assert damage >= 200, "Should include +25 flat magic bonus, got damage=#{damage}"
    end

    test "ring with MagicPenetration reduces defender MR" do
      ring_id = 9992
      ring_def = %Arena.Data.ItemDef{
        id: ring_id,
        name: "Magic Ring",
        obj_type: 35,
        magic_damage_bonus: 0,
        magic_absolute_bonus: 0,
        magic_penetration: 20,
        resistencia_magica: 0
      }
      :ets.insert(:arena_game_data, {{:item, ring_id}, ring_def})

      # Defender armor with some magic resistance
      armor_id = 9993
      armor_def = %Arena.Data.ItemDef{
        id: armor_id,
        name: "Magic Armor",
        obj_type: 3,
        magic_damage_bonus: 0,
        magic_absolute_bonus: 0,
        magic_penetration: 0,
        resistencia_magica: 30
      }
      :ets.insert(:arena_game_data, {{:item, armor_id}, armor_def})

      caster_with_ring =
        make_entity(%{
          char_id: :caster,
          x: 50,
          y: 50,
          char_index: 1,
          class: :guerrero,
          equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: ring_id, municion: nil}
        })

      caster_no_ring =
        make_entity(%{
          char_id: :caster,
          x: 50,
          y: 50,
          char_index: 1,
          class: :guerrero,
          equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil}
        })

      defender =
        make_entity(%{
          char_id: :defender,
          x: 51,
          y: 50,
          char_index: 2,
          hp: 500,
          max_hp: 500,
          criminal: true,
          skills: %{resistance: 0},
          equipment: %{weapon: nil, armor: armor_id, shield: nil, helmet: nil, ring: nil, municion: nil}
        })

      spell = make_spell(%{sube_hp: 2, min_hp: 100, max_hp: 100, anti_rm: 0})

      # With ring (penetration reduces defender MR by 20)
      state_r =
        make_state(
          %{caster: caster_with_ring, defender: defender},
          occupancy: %{{51, 50} => {:player, :defender}}
        )

      state_r = SpellEffects.apply_spell(state_r, :caster, caster_with_ring, spell, 51, 50)
      damage_with_ring = defender.hp - state_r.players[:defender].hp

      # Without ring (no penetration, full 30% MR applies)
      state_nr =
        make_state(
          %{caster: caster_no_ring, defender: defender},
          occupancy: %{{51, 50} => {:player, :defender}}
        )

      state_nr = SpellEffects.apply_spell(state_nr, :caster, caster_no_ring, spell, 51, 50)
      damage_without_ring = defender.hp - state_nr.players[:defender].hp

      assert damage_with_ring > damage_without_ring,
             "Ring penetration should reduce defender MR, increasing damage: with=#{damage_with_ring} without=#{damage_without_ring}"
    end

    test "anti_rm spell ignores magic resistance entirely" do
      armor_id = 9994
      armor_def = %Arena.Data.ItemDef{
        id: armor_id,
        name: "Heavy Magic Armor",
        obj_type: 3,
        magic_damage_bonus: 0,
        magic_absolute_bonus: 0,
        magic_penetration: 0,
        resistencia_magica: 50
      }
      :ets.insert(:arena_game_data, {{:item, armor_id}, armor_def})

      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1, class: :guerrero})

      defender =
        make_entity(%{
          char_id: :defender,
          x: 51,
          y: 50,
          char_index: 2,
          hp: 500,
          max_hp: 500,
          criminal: true,
          skills: %{resistance: 30},
          equipment: %{weapon: nil, armor: armor_id, shield: nil, helmet: nil, ring: nil, municion: nil}
        })

      spell_no_anti = make_spell(%{sube_hp: 2, min_hp: 100, max_hp: 100, anti_rm: 0})
      spell_anti = make_spell(%{sube_hp: 2, min_hp: 100, max_hp: 100, anti_rm: 1})

      # Without anti_rm: MR reduces damage
      state1 =
        make_state(
          %{caster: caster, defender: defender},
          occupancy: %{{51, 50} => {:player, :defender}}
        )

      state1 = SpellEffects.apply_spell(state1, :caster, caster, spell_no_anti, 51, 50)
      damage_normal = defender.hp - state1.players[:defender].hp

      # With anti_rm: MR is ignored
      state2 =
        make_state(
          %{caster: caster, defender: defender},
          occupancy: %{{51, 50} => {:player, :defender}}
        )

      state2 = SpellEffects.apply_spell(state2, :caster, caster, spell_anti, 51, 50)
      damage_anti = defender.hp - state2.players[:defender].hp

      assert damage_anti > damage_normal,
             "AntiRm spell should ignore MR: anti=#{damage_anti} normal=#{damage_normal}"
    end

    test "defender armor resistencia_magica reduces spell damage" do
      armor_id = 9995
      armor_def = %Arena.Data.ItemDef{
        id: armor_id,
        name: "Magic Plate",
        obj_type: 3,
        magic_damage_bonus: 0,
        magic_absolute_bonus: 0,
        magic_penetration: 0,
        resistencia_magica: 40
      }
      :ets.insert(:arena_game_data, {{:item, armor_id}, armor_def})

      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1, class: :guerrero})

      defender_armored =
        make_entity(%{
          char_id: :defender,
          x: 51,
          y: 50,
          char_index: 2,
          hp: 500,
          max_hp: 500,
          criminal: true,
          skills: %{resistance: 0},
          equipment: %{weapon: nil, armor: armor_id, shield: nil, helmet: nil, ring: nil, municion: nil}
        })

      defender_naked =
        make_entity(%{
          char_id: :defender,
          x: 51,
          y: 50,
          char_index: 2,
          hp: 500,
          max_hp: 500,
          criminal: true,
          skills: %{resistance: 0},
          equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil}
        })

      spell = make_spell(%{sube_hp: 2, min_hp: 100, max_hp: 100, anti_rm: 0})

      # Armored defender
      state_a =
        make_state(
          %{caster: caster, defender: defender_armored},
          occupancy: %{{51, 50} => {:player, :defender}}
        )

      state_a = SpellEffects.apply_spell(state_a, :caster, caster, spell, 51, 50)
      damage_armored = defender_armored.hp - state_a.players[:defender].hp

      # Naked defender
      state_n =
        make_state(
          %{caster: caster, defender: defender_naked},
          occupancy: %{{51, 50} => {:player, :defender}}
        )

      state_n = SpellEffects.apply_spell(state_n, :caster, caster, spell, 51, 50)
      damage_naked = defender_naked.hp - state_n.players[:defender].hp

      assert damage_armored < damage_naked,
             "Armor MR should reduce spell damage: armored=#{damage_armored} naked=#{damage_naked}"
    end
  end
end
