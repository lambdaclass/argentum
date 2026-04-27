defmodule Arena.WorkRequestTargetDriftTest do
  @moduledoc """
  Drift #19c: Wire `:work_request_target` (eWorkRequestTarget = 62) for the
  spell flow. Closes the parity gap with VB6's UseSpellSlot path.

  VB6 reference: old/server/Codigo/modHechizos.bas:4150-4156

      If Hechizos(spell).AutoLanzar = 1 Then
          Call LanzarHechizo(spell, UserIndex)            ' self
      Else
          If Hechizos(spell).AreaAfecta > 0 Then
              Call WriteWorkRequestTarget(UserIndex, e_Skill.Magia, True, AreaRadio)
          Else
              Call WriteWorkRequestTarget(UserIndex, e_Skill.Magia)
          End If
      End If

  `e_Skill.Magia = 1` (Declares.bas:1392).

  In the modern client the cast_spell packet always carries a target_x/y
  because the client picks the target locally. This branch is defensive parity
  for VB6-style clients (and an integration crutch the protocol drift line
  19c calls out).

  We only exercise the call site here -- the encoder + the protocol drift 19
  binary parity tests live in apps/ao_protocol/test/encoder_drift_19_test.exs.
  """
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, SpellDef}
  alias Arena.Map.CombatHandlers
  alias AoProtocol.Server.Encoder

  import Arena.Test.MapStateFactory

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
      class: :mage,
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
      spells: [9100],
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

  defp make_state(players, opts \\ []) do
    occupancy_map = Keyword.get(opts, :occupancy, %{})

    sessions =
      Keyword.get(opts, :sessions) ||
        Map.new(players, fn {id, _e} -> {id, self()} end)

    map_state(
      players: players,
      sessions: sessions,
      occupancy: occupancy_map,
      meta: %{safe_zone: false, sin_invi_ocul: false}
    )
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      10 -> :ok
    end
  end

  defp put_spell(spell_id, attrs) do
    spell_def =
      struct!(
        %SpellDef{
          id: spell_id,
          name: "TestSpell #{spell_id}",
          mana_required: 10,
          min_skill: 0,
          cooldown: 2
        },
        attrs
      )

    :ets.insert(:arena_game_data, {{:spell, spell_id}, spell_def})
    spell_def
  end

  setup do
    drain_mailbox()
    :ok
  end

  # ── Expected packet bytes ──────────────────────────────────────────────────

  @prompt_point Encoder.encode(
                  {:work_request_target, %{skill: 1, castea_area: false, radio: 0}}
                )
  @prompt_aoe_radio_3 Encoder.encode(
                       {:work_request_target, %{skill: 1, castea_area: true, radio: 3}}
                     )

  # ── 1. Point target (no AOE), no target click → prompt ────────────────────

  describe "no-target non-auto spell, point target" do
    test "emits eWorkRequestTarget with skill=1 castea_area=false radio=0 and no side effects" do
      spell_id = 9_100
      put_spell(spell_id, %{auto_lanzar: false, area_afecta: 0, area_radio: 0})

      caster =
        make_entity(%{
          mana: 200,
          spells: [spell_id],
          spell_cooldowns: %{}
        })

      state = make_state(%{caster: caster})

      {:reply, reply, new_state} =
        CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      assert reply == :ok
      prompt = @prompt_point
      assert_receive {:egress, %{payload: ^prompt}}, 200

      # No mana drained, no cooldown set -- the spell hasn't actually run.
      updated = new_state.players[:caster]
      assert updated.mana == 200
      assert Map.get(updated.spell_cooldowns, 1, nil) == nil

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ── 2. AOE spell, no target click → prompt with castea_area + radio ───────

  describe "no-target non-auto AOE spell" do
    test "emits prompt with castea_area=true and radio set" do
      spell_id = 9_101
      put_spell(spell_id, %{auto_lanzar: false, area_afecta: 1, area_radio: 3})

      caster =
        make_entity(%{
          mana: 200,
          spells: [spell_id],
          spell_cooldowns: %{}
        })

      state = make_state(%{caster: caster})

      {:reply, :ok, _new} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      prompt = @prompt_aoe_radio_3
      assert_receive {:egress, %{payload: ^prompt}}, 200

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ── 3. Auto-cast spell with no target → no prompt ─────────────────────────

  describe "auto-cast spell, no target" do
    test "auto_lanzar spell does NOT emit :work_request_target" do
      spell_id = 9_102
      # Trivial self-buff style spell so it can pass the inner branches.
      put_spell(spell_id, %{
        auto_lanzar: true,
        area_afecta: 0,
        sube_hp: 1,
        min_hp: 1,
        max_hp: 1,
        target: 4
      })

      caster =
        make_entity(%{
          mana: 200,
          hp: 50,
          max_hp: 100,
          spells: [spell_id],
          spell_cooldowns: %{}
        })

      state = make_state(%{caster: caster})

      _ = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      prompt_point = @prompt_point
      prompt_aoe = @prompt_aoe_radio_3
      refute_receive {:egress, %{payload: ^prompt_point}}, 100
      refute_receive {:egress, %{payload: ^prompt_aoe}}, 50

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ── 4. With target, non-auto → no prompt ──────────────────────────────────

  describe "with target, non-auto spell" do
    test "no prompt emitted when target_x/y supplied" do
      spell_id = 9_103
      put_spell(spell_id, %{
        auto_lanzar: false,
        area_afecta: 0,
        sube_hp: 1,
        min_hp: 1,
        max_hp: 1,
        target: 4
      })

      caster =
        make_entity(%{
          mana: 200,
          hp: 50,
          max_hp: 100,
          spells: [spell_id],
          spell_cooldowns: %{}
        })

      state = make_state(%{caster: caster})

      {:reply, :ok, new} = CombatHandlers.handle_cast_spell(state, :caster, 1, 50, 50)

      prompt = @prompt_point
      refute_receive {:egress, %{payload: ^prompt}}, 50

      # Spell DID run -- mana drained.
      assert new.players[:caster].mana < 200

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ── 5. Adversarial: invalid spell slot (spell_def == nil) ─────────────────

  describe "adversarial: invalid spell slot" do
    test "prompt branch gated on spell_def != nil" do
      # No spell at slot 1 -- entity has spells: [].
      caster =
        make_entity(%{
          mana: 200,
          spells: [],
          spell_cooldowns: %{}
        })

      state = make_state(%{caster: caster})

      {:reply, reply, _new} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      assert reply == {:error, :invalid_slot}
      prompt = @prompt_point
      refute_receive {:egress, %{payload: ^prompt}}, 50
    end
  end

  # ── 6. Adversarial: dead caster ───────────────────────────────────────────

  describe "adversarial: dead caster" do
    test "dead guard fires before prompt branch" do
      spell_id = 9_104
      put_spell(spell_id, %{auto_lanzar: false, area_afecta: 0})

      caster =
        make_entity(%{
          dead: true,
          mana: 200,
          spells: [spell_id],
          spell_cooldowns: %{}
        })

      state = make_state(%{caster: caster})

      {:reply, reply, _new} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      assert reply == {:error, :dead}
      prompt = @prompt_point
      refute_receive {:egress, %{payload: ^prompt}}, 50

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ── 7. Adversarial: paralyzed caster ──────────────────────────────────────

  describe "adversarial: paralyzed caster" do
    test "paralyzed guard fires before prompt branch" do
      spell_id = 9_105
      put_spell(spell_id, %{auto_lanzar: false, area_afecta: 0})

      caster =
        make_entity(%{
          paralyzed: true,
          mana: 200,
          spells: [spell_id],
          spell_cooldowns: %{}
        })

      state = make_state(%{caster: caster})

      {:reply, reply, _new} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      assert reply == {:error, :paralyzed}
      prompt = @prompt_point
      refute_receive {:egress, %{payload: ^prompt}}, 50

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ── 8. Adversarial: cooldown ──────────────────────────────────────────────

  describe "adversarial: cooldown" do
    test "cooldown guard fires before prompt branch" do
      spell_id = 9_106
      put_spell(spell_id, %{auto_lanzar: false, area_afecta: 0, cooldown: 5})

      future = System.monotonic_time(:millisecond) + 999_999_999

      caster =
        make_entity(%{
          mana: 200,
          spells: [spell_id],
          spell_cooldowns: %{1 => future}
        })

      state = make_state(%{caster: caster})

      {:reply, reply, _new} = CombatHandlers.handle_cast_spell(state, :caster, 1, nil, nil)

      assert reply == {:error, :cooldown}
      prompt = @prompt_point
      refute_receive {:egress, %{payload: ^prompt}}, 50

      :ets.delete(:arena_game_data, {:spell, spell_id})
    end
  end

  # ── 9. SpellDef.from_section parses autolanzar ────────────────────────────

  describe "SpellDef.from_section parses autolanzar" do
    test "autolanzar=1 → auto_lanzar: true" do
      def_ = SpellDef.from_section(123, %{"autolanzar" => "1"})
      assert def_.auto_lanzar == true
    end

    test "autolanzar=0 → auto_lanzar: false" do
      def_ = SpellDef.from_section(123, %{"autolanzar" => "0"})
      assert def_.auto_lanzar == false
    end

    test "missing autolanzar → auto_lanzar: false" do
      def_ = SpellDef.from_section(123, %{})
      assert def_.auto_lanzar == false
    end
  end

  # ── 10. Shipped data parity: HECHIZO101 (Heroismo) has autolanzar=1 ───────

  describe "shipped Hechizos.dat parity" do
    test "HECHIZO101 (Heroismo) parses to auto_lanzar: true" do
      # Mirrors the literal section captured from
      # /Users/.../resources/raw/Dat/Hechizos.dat lines 1177-1207.
      # Keys are downcased per Arena.Data.GameData's INI loader.
      section = %{
        "nombre" => "Heroismo",
        "tipo" => "8",
        "wav" => "230",
        "subeag" => "1",
        "minag" => "36",
        "maxag" => "37",
        "duration" => "54",
        "subefu" => "1",
        "minfu" => "36",
        "maxfu" => "37",
        "minskill" => "100",
        "manarequerido" => "350",
        "starequerido" => "250",
        "iconoindex" => "35708",
        "cooldown" => "15",
        "target" => "1",
        "autolanzar" => "1"
      }

      parsed = SpellDef.from_section(101, section)
      assert parsed.auto_lanzar == true
      assert parsed.id == 101
    end
  end
end
