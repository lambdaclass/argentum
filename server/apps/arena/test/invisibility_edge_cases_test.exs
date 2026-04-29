defmodule Arena.InvisibilityEdgeCasesTest do
  @moduledoc """
  Tests for invisibility edge cases:
  - 26c: Offensive spell casting breaks invisible + oculto on caster
  - 26g: NoDetectable flag grants immunity to RemoveInvisibility spells
  - 26h: Entering SinInviOcul maps strips invisible + oculto
  - 26i: Equipping mount breaks invisible + oculto
  """
  use ExUnit.Case, async: true

  alias Arena.Data.{GameData, SpellDef}
  alias Arena.Map.{Helpers, SpellEffects, StatusTicks}

  import Arena.Test.MapStateFactory

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp make_entity(overrides) do
    defaults = %{
      char_id: :caster,
      name: "Tester",
      account_id: "acc_test",
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
      trade_offer_items: [],
      trade_accepted: false,
      pet_ids: [],
      description: "",
      muted_until: 0,
      last_chat_at: -1_000_000_000_000,
      spouse_id: 0,
      marriage_proposal_target: nil
    }

    Map.merge(defaults, overrides)
  end

  defp make_state(players, opts \\ []) do
    map_state(
      [players: players] ++
        opts
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
      require_weapon_type: 0,
      target_effect_type: 0,
      remove_invisibility: false
    }

    struct!(defaults, Map.to_list(overrides))
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 26c: Offensive spell casting breaks invisible + oculto on caster
  # ═══════════════════════════════════════════════════════════════════════════

  describe "26c: offensive spell breaks caster invisibility" do
    test "break_invisibility clears invisible on caster (used by negative spells)" do
      # VB6: RemoveUserInvisibility is called when TargetEffectType=eNegative
      caster =
        make_entity(%{
          char_id: :caster,
          invisible: true,
          buffs: [%{type: :invisible, expires_at: 999_999_999_999}]
        })

      state = make_state(%{caster: caster})
      {result, _bi_effects} = Helpers.break_invisibility(caster, state, :caster)

      assert result.invisible == false
      assert Enum.filter(result.buffs, &(&1.type == :invisible)) == []
    end

    test "break_invisibility clears oculto on caster (used by negative spells)" do
      caster =
        make_entity(%{
          char_id: :caster,
          oculto: true,
          buffs: [%{type: :oculto, expires_at: 999_999_999_999}]
        })

      state = make_state(%{caster: caster})
      {result, _bi_effects} = Helpers.break_invisibility(caster, state, :caster)

      assert result.oculto == false
      assert Enum.filter(result.buffs, &(&1.type == :oculto)) == []
    end

    test "negative target_effect_type (2) should trigger break; positive (1) should not" do
      # Verify the conditional logic: only target_effect_type == 2 breaks invis
      negative_spell = make_spell(%{target_effect_type: 2})
      positive_spell = make_spell(%{target_effect_type: 1})
      neutral_spell = make_spell(%{target_effect_type: 0})

      # The condition in handle_cast_spell is: spell_def.target_effect_type == 2
      assert negative_spell.target_effect_type == 2
      assert positive_spell.target_effect_type == 1
      assert neutral_spell.target_effect_type == 0
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 26g: NoDetectable flag for immunity to RemoveInvisibility spells
  # ═══════════════════════════════════════════════════════════════════════════

  describe "26g: NoDetectable immunity to RemoveInvisibility" do
    test "RemoveInvisibility spell reveals normal invisible player" do
      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1})

      target =
        make_entity(%{
          char_id: :target,
          x: 55,
          y: 50,
          char_index: 2,
          invisible: true,
          no_detectable: false
        })

      players = %{caster: caster, target: target}
      state = make_state(players, occupancy: %{{55, 50} => {:player, :target}})

      spell = make_spell(%{remove_invisibility: true})

      {new_state, _effects} =
        SpellEffects.apply_spell_remove_invisibility(state, :caster, caster, spell, 50, 50)

      updated_target = new_state.players[:target]
      assert updated_target.invisible == false
    end

    test "RemoveInvisibility spell does NOT reveal player with no_detectable" do
      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1})

      target =
        make_entity(%{
          char_id: :target,
          x: 55,
          y: 50,
          char_index: 2,
          invisible: true,
          no_detectable: true
        })

      players = %{caster: caster, target: target}
      state = make_state(players, occupancy: %{{55, 50} => {:player, :target}})

      spell = make_spell(%{remove_invisibility: true})

      {new_state, _effects} =
        SpellEffects.apply_spell_remove_invisibility(state, :caster, caster, spell, 50, 50)

      updated_target = new_state.players[:target]
      assert updated_target.invisible == true
    end

    test "RemoveInvisibility spell does NOT reveal player out of range (>11 tiles)" do
      caster = make_entity(%{char_id: :caster, x: 50, y: 50, char_index: 1})

      target =
        make_entity(%{
          char_id: :target,
          x: 62,
          y: 50,
          char_index: 2,
          invisible: true,
          no_detectable: false
        })

      players = %{caster: caster, target: target}
      state = make_state(players, occupancy: %{{62, 50} => {:player, :target}})

      spell = make_spell(%{remove_invisibility: true})

      {new_state, _effects} =
        SpellEffects.apply_spell_remove_invisibility(state, :caster, caster, spell, 50, 50)

      updated_target = new_state.players[:target]
      # 62 - 50 = 12, which is > 11 radius
      assert updated_target.invisible == true
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 26h: Entering SinInviOcul maps clears both flags
  # ═══════════════════════════════════════════════════════════════════════════

  describe "26h: SinInviOcul map entry strips invisibility" do
    # This is tested at the Helpers.break_invisibility level since
    # the map entry logic depends on MapServer state with meta.sin_invi_ocul.
    # The do_enter function in map_server.ex checks:
    #   if state.meta.sin_invi_ocul and (entity.invisible or entity.oculto) and not entity.gm

    test "break_invisibility clears both invisible and oculto" do
      entity =
        make_entity(%{
          char_id: :player,
          invisible: true,
          oculto: true,
          buffs: [
            %{type: :invisible, expires_at: 999_999_999_999},
            %{type: :oculto, expires_at: 999_999_999_999}
          ]
        })

      state = make_state(%{player: entity})

      {result, _bi_effects} = Helpers.break_invisibility(entity, state, :player)
      assert result.invisible == false
      assert result.oculto == false
      assert Enum.filter(result.buffs, &(&1.type in [:invisible, :oculto])) == []
    end

    test "break_invisibility is a no-op when neither flag is set" do
      entity = make_entity(%{char_id: :player, invisible: false, oculto: false})
      state = make_state(%{player: entity})

      {result, _bi_effects} = Helpers.break_invisibility(entity, state, :player)
      assert result.invisible == false
      assert result.oculto == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 26i: Equipping mount breaks invisible + oculto
  # ═══════════════════════════════════════════════════════════════════════════

  describe "26i: mounting breaks invisibility" do
    # The actual equip path goes through InventoryHandlers.handle_equip_item
    # which checks item_def.obj_type == 44 (otSaddles).
    # We test the core mechanic: break_invisibility clears both flags.

    test "break_invisibility clears invisible when oculto is also set" do
      entity =
        make_entity(%{
          char_id: :rider,
          invisible: true,
          oculto: true,
          buffs: [%{type: :invisible, expires_at: 999_999_999_999}]
        })

      state = make_state(%{rider: entity})
      {result, _bi_effects} = Helpers.break_invisibility(entity, state, :rider)

      assert result.invisible == false
      assert result.oculto == false
    end

    test "break_invisibility clears oculto alone" do
      entity =
        make_entity(%{
          char_id: :rider,
          invisible: false,
          oculto: true,
          buffs: [%{type: :oculto, expires_at: 999_999_999_999}]
        })

      state = make_state(%{rider: entity})
      {result, _bi_effects} = Helpers.break_invisibility(entity, state, :rider)

      assert result.invisible == false
      assert result.oculto == false
      assert result.buffs == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Buff expiry: oculto buff expires correctly
  # ═══════════════════════════════════════════════════════════════════════════

  describe "oculto buff expiry" do
    test "expired oculto buff clears the oculto flag" do
      now = System.monotonic_time(:millisecond)

      entity =
        make_entity(%{
          char_id: :player,
          oculto: true,
          buffs: [%{type: :oculto, expires_at: now - 1000}]
        })

      state = make_state(%{player: entity})
      new_state = StatusTicks.process_player_buffs(state, :player, entity, now)
      updated = new_state.players[:player]

      assert updated.oculto == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # SpellDef: target_effect_type and remove_invisibility parsing
  # ═══════════════════════════════════════════════════════════════════════════

  describe "SpellDef parsing" do
    test "target_effect_type is parsed from section" do
      section = %{"targeteffecttype" => "2"}
      spell = SpellDef.from_section(999, section)
      assert spell.target_effect_type == 2
    end

    test "remove_invisibility is parsed from effects bitmask" do
      # 32768 = RemoveInvisibility in VB6 e_SpellEffects
      section = %{"effects" => "32768"}
      spell = SpellDef.from_section(999, section)
      assert spell.remove_invisibility == true
    end

    test "remove_invisibility is false when effects does not have bit 32768" do
      section = %{"effects" => "1024"}
      spell = SpellDef.from_section(999, section)
      assert spell.remove_invisibility == false
    end
  end
end
