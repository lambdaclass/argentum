defmodule Arena.SpellSelectionParityTest do
  @moduledoc """
  Edge-case parity tests for spell selection/targeting (ROADMAP #8).

  VB6 Hechizos.dat documents these target types:
    Target=1 -> user/self only (heals, buffs, cure poison, resurrect)
    Target=2 -> NPC only (stun, petrify)
    Target=3 -> user + NPC (damage spells, etc.)
    Target=4 -> terrain/self (summons)

  The server must enforce these target restrictions and also break
  meditation/rest when casting, matching VB6 behavior.
  """

  use ExUnit.Case, async: true

  alias Arena.Data.{GameData, SpellDef}
  alias Arena.Map.CombatHandlers

  import Arena.Test.MapStateFactory

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

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
      spells: [],
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

  defp insert_spell(spell_id, overrides) do
    defaults = %SpellDef{
      id: spell_id,
      name: "Test Spell #{spell_id}",
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
      remove_invisibility: false,
      is_elemental_tags_only: false
    }

    spell_def = struct!(defaults, Map.to_list(overrides))
    :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})
    spell_def
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 1. VB6 Target field: target=1 (user-only) rejects NPC targets
  # ═══════════════════════════════════════════════════════════════════════════

  describe "VB6 Target=1 (user-only spells) -- NPC target rejection" do
    test "user-only heal spell (target=1) cast on NPC tile is rejected" do
      spell_id = 80_001
      insert_spell(spell_id, %{target: 1, sube_hp: 1, min_hp: 30, max_hp: 30})

      caster = make_entity(%{mana: 200, hp: 50, spells: [spell_id]})

      npc = %{
        npc_id: 1, instance_id: 1, x: 51, y: 50, hp: 50, max_hp: 100,
        alive: true, char_index: 2, target_id: nil, owner_id: nil, exp_count: 100
      }

      occupancy = %{{51, 50} => {:npc, 1}}
      state = make_state(%{caster: caster}, occupancy: occupancy, npcs_live: %{1 => npc})

      {:reply, result, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, 51, 50)

      # VB6: user-only spell on an NPC target should be rejected
      assert result == {:error, :invalid_target}
      # Mana must not be consumed
      assert new_state.players.caster.mana == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 2. VB6 Target field: target=2 (NPC-only) rejects player targets
  # ═══════════════════════════════════════════════════════════════════════════

  describe "VB6 Target=2 (NPC-only spells) -- player target rejection" do
    test "NPC-only spell (target=2) cast on player tile is rejected" do
      spell_id = 80_002
      # Petrify-like spell: target=2, paraliza
      insert_spell(spell_id, %{target: 2, paraliza: true})

      caster = make_entity(%{mana: 200, spells: [spell_id]})
      target = make_entity(%{char_id: :target, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      {:reply, result, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, 51, 50)

      # VB6: NPC-only spell on a player should be rejected
      assert result == {:error, :invalid_target}
      # Mana must not be consumed
      assert new_state.players.caster.mana == 200
    end

    test "NPC-only spell (target=2) cast on empty tile is rejected" do
      spell_id = 80_003
      insert_spell(spell_id, %{target: 2, sube_hp: 2, min_hp: 20, max_hp: 20})

      caster = make_entity(%{mana: 200, spells: [spell_id]})
      state = make_state(%{caster: caster})

      {:reply, result, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, 51, 50)

      assert result == {:error, :invalid_target}
      assert new_state.players.caster.mana == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 3. VB6 Target field: target=1 still allows player targets
  # ═══════════════════════════════════════════════════════════════════════════

  describe "VB6 Target=1 (user-only spells) -- player targets allowed" do
    test "user-only heal spell (target=1) cast on player tile succeeds" do
      spell_id = 80_004
      insert_spell(spell_id, %{target: 1, sube_hp: 1, min_hp: 30, max_hp: 30})

      caster = make_entity(%{mana: 200, hp: 100, spells: [spell_id]})
      target = make_entity(%{char_id: :target, hp: 50, max_hp: 100, x: 51, y: 50, char_index: 2})

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      {:reply, result, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, 51, 50)

      assert result == :ok
      # Target was healed
      assert new_state.players.target.hp == 80
      # Mana consumed
      assert new_state.players.caster.mana == 190
    end

    test "user-only spell (target=1) with no target casts on self" do
      spell_id = 80_005
      insert_spell(spell_id, %{target: 1, sube_hp: 1, min_hp: 20, max_hp: 20})

      caster = make_entity(%{mana: 200, hp: 60, max_hp: 100, spells: [spell_id]})
      state = make_state(%{caster: caster})

      {:reply, result, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      assert result == :ok
      assert new_state.players.caster.hp == 80
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 4. VB6: Casting breaks meditation
  # ═══════════════════════════════════════════════════════════════════════════

  describe "casting breaks meditation" do
    test "meditating caster has meditation broken on successful cast" do
      spell_id = 80_006
      insert_spell(spell_id, %{target: 1, sube_hp: 1, min_hp: 10, max_hp: 10})

      caster = make_entity(%{
        mana: 200,
        hp: 50,
        max_hp: 100,
        meditating: true,
        spells: [spell_id]
      })

      state = make_state(%{caster: caster})

      {:reply, :ok, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      updated = new_state.players.caster
      # VB6: meditation is broken when casting a spell
      assert updated.meditating == false
      # Spell still applied (HP healed)
      assert updated.hp == 60
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 5. VB6: Casting breaks resting
  # ═══════════════════════════════════════════════════════════════════════════

  describe "casting breaks resting" do
    test "resting caster has rest broken on successful cast" do
      spell_id = 80_007
      insert_spell(spell_id, %{target: 1, sube_hp: 1, min_hp: 10, max_hp: 10})

      caster = make_entity(%{
        mana: 200,
        hp: 50,
        max_hp: 100,
        resting: true,
        spells: [spell_id]
      })

      state = make_state(%{caster: caster})

      {:reply, :ok, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      updated = new_state.players.caster
      # VB6: resting is broken when casting a spell
      assert updated.resting == false
      # Spell still applied
      assert updated.hp == 60
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 6. VB6 Target=3 (user+NPC) allows both player and NPC targets
  # ═══════════════════════════════════════════════════════════════════════════

  describe "VB6 Target=3 (user+NPC spells) -- both targets allowed" do
    test "damage spell (target=3) cast on player tile succeeds" do
      spell_id = 80_008
      insert_spell(spell_id, %{
        target: 3, sube_hp: 2, min_hp: 20, max_hp: 20,
        target_effect_type: 2
      })

      caster = make_entity(%{mana: 200, spells: [spell_id]})
      target = make_entity(%{
        char_id: :target, hp: 100, max_hp: 100, x: 51, y: 50,
        char_index: 2, criminal: true
      })

      occupancy = %{{51, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      {:reply, result, _new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, 51, 50)

      assert result == :ok
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 7. VB6 Target=4 (terrain) with no target succeeds
  # ═══════════════════════════════════════════════════════════════════════════

  describe "VB6 Target=4 (terrain spells)" do
    test "terrain spell (target=4) ignores occupancy, treats as self-cast" do
      spell_id = 80_009
      # Summon-like spell: target=4, tipo=4, invoca NPC
      insert_spell(spell_id, %{target: 4, tipo: 4, invoca: 1})

      caster = make_entity(%{mana: 200, spells: [spell_id]})
      state = make_state(%{caster: caster})

      # VB6: target=4 spells don't require target coordinates
      {:reply, result, _new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      # Should not fail with :invalid_target
      assert result == :ok
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # 8. Cleanup
  # ═══════════════════════════════════════════════════════════════════════════

  setup do
    on_exit(fn ->
      for id <- 80_001..80_009 do
        :ets.delete(:arena_game_data, {:spell, id})
      end
    end)

    :ok
  end
end
