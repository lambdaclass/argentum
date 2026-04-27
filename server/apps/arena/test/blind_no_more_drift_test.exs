defmodule Arena.BlindNoMoreDriftTest do
  @moduledoc """
  Drift #19a: VB6 ceguera (blind) buff system.

  Mirrors the existing paralyzed buff wiring 1:1. The encoder for
  `:blind_no_more` (eBlindNoMore = 85, no payload) is already in place;
  this exercises the buff mechanic + emission at clear sites:

    * On tick-expiry (`StatusTicks.process_player_buffs/4`) — VB6
      Modulo_UsUaRiOs.bas:2475 analogue (the WriteParalizeOK path, but
      for ceguera).
    * On `cura_ceguera`-spell clear — VB6 modHechizos.bas:1601 / 3465 /
      4083, guarded by `If .flags.Ceguera > 0`.

  No-op assertions cover the adversarial paths: clear-while-not-blind
  must NOT emit a `:blind_no_more` packet (matching the VB6 guard).
  """
  use ExUnit.Case, async: false

  alias Arena.Data.SpellDef
  alias Arena.Map.{SpellEffects, StatusTicks}
  alias AoProtocol.Server.Encoder

  import Arena.Test.MapStateFactory

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp make_entity(overrides) do
    defaults = %{
      char_id: :target,
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
      trade_offer_items: [],
      trade_accepted: false,
      in_duel: false,
      duel_opponent_id: nil
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

  defp make_spell(overrides) do
    defaults = %SpellDef{
      id: 1,
      name: "Test Spell",
      mana_required: 10,
      duration: 10,
      cooldown: 2
    }

    struct!(defaults, Map.to_list(overrides))
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      10 -> :ok
    end
  end

  setup do
    drain_mailbox()
    :ok
  end

  # The encoded eBlindNoMore packet — packet id 85, no payload.
  @blind_no_more_packet Encoder.encode({:blind_no_more, %{}})

  # ── Tick-expiry path ─────────────────────────────────────────────────────

  describe "tick-expiry emits :blind_no_more" do
    test "expired :blind buff clears flag and emits packet" do
      caster = make_entity(%{char_id: :caster, mana: 200, x: 49, y: 50, char_index: 1})

      target =
        make_entity(%{
          char_id: :target,
          x: 50,
          y: 50,
          char_index: 2,
          buffs: [],
          blind: false
        })

      occupancy = %{{50, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      # Use a synthetic spell with very short duration. apply_spell_status
      # floors duration to 3000ms internally, but we'll fast-forward past
      # that with a future `now` value.
      spell = make_spell(%{ciega: true, duration: 1, mana_required: 20})

      {state, _effects} =
        SpellEffects.apply_spell_status(state, :caster, caster, spell, 50, 50)

      assert state.players[:target].blind == true,
             "synthetic ciega spell must set blind: true"

      # Drain the update_mana side-effect from the cast
      drain_mailbox()

      # Fast-forward past the duration floor (3000ms)
      future = System.monotonic_time(:millisecond) + 5_000

      target_after_cast = state.players[:target]

      _new_state =
        StatusTicks.process_player_buffs(state, :target, target_after_cast, future)

      assert_receive {:send_raw, @blind_no_more_packet}, 200
    end
  end

  # ── cura_ceguera spell-clear path ────────────────────────────────────────

  describe "cura_ceguera spell clears blind and emits packet" do
    test "blind target receives :blind_no_more when cura_ceguera lands" do
      caster = make_entity(%{char_id: :caster, mana: 200, x: 49, y: 50, char_index: 1})

      target =
        make_entity(%{
          char_id: :target,
          x: 50,
          y: 50,
          char_index: 2,
          blind: true,
          buffs: [
            %{type: :blind, expires_at: System.monotonic_time(:millisecond) + 60_000}
          ]
        })

      occupancy = %{{50, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{cura_ceguera: true, mana_required: 20, duration: 0})

      drain_mailbox()

      {new_state, effects} = SpellEffects.apply_spell_status(state, :caster, caster, spell, 50, 50)

      cleared = new_state.players[:target]
      assert cleared.blind == false, "cura_ceguera must clear the blind flag"

      refute Enum.any?(cleared.buffs, &(&1.type == :blind)),
             "cura_ceguera must drop the :blind buff entry"

      blind_no_more_packet = @blind_no_more_packet

      assert Enum.any?(effects, fn
               {:send, :target, %{payload: ^blind_no_more_packet}} -> true
               _ -> false
             end),
             "cura_ceguera must emit a blind_no_more :send effect to the target"
    end
  end

  # ── Adversarial: cura_ceguera on a non-blind target ──────────────────────

  describe "cura_ceguera on non-blind target is a no-op (VB6 guard)" do
    test "no :blind_no_more emitted when target was not blind" do
      caster = make_entity(%{char_id: :caster, mana: 200, x: 49, y: 50, char_index: 1})

      target =
        make_entity(%{
          char_id: :target,
          x: 50,
          y: 50,
          char_index: 2,
          blind: false,
          buffs: []
        })

      occupancy = %{{50, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{cura_ceguera: true, mana_required: 20, duration: 0})

      drain_mailbox()

      {_new_state, _effects} = SpellEffects.apply_spell_status(state, :caster, caster, spell, 50, 50)

      refute_receive {:send_raw, @blind_no_more_packet}, 100
    end
  end

  # ── Adversarial: tick on a non-blind target ──────────────────────────────

  describe "tick with no :blind buff emits no packet" do
    test "no :blind_no_more emitted when there's no :blind buff" do
      target =
        make_entity(%{
          char_id: :target,
          x: 50,
          y: 50,
          char_index: 1,
          blind: false,
          buffs: []
        })

      state = make_state(%{target: target})

      drain_mailbox()
      now = System.monotonic_time(:millisecond)

      _new_state = StatusTicks.process_player_buffs(state, :target, target, now)

      refute_receive {:send_raw, @blind_no_more_packet}, 100
    end
  end

  # ── Warrior 0.7x duration parity ────────────────────────────────────────

  describe "warrior gets 0.7x blind duration (VB6 parity)" do
    test "warrior class blind buff has 0.7x duration offset" do
      caster = make_entity(%{char_id: :caster, mana: 200, x: 49, y: 50, char_index: 1})

      target =
        make_entity(%{
          char_id: :target,
          class: :guerrero,
          x: 50,
          y: 50,
          char_index: 2,
          blind: false,
          buffs: []
        })

      occupancy = %{{50, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      # duration 10 → 10000ms; warrior gets 0.7x → 7000ms
      spell = make_spell(%{ciega: true, duration: 10, mana_required: 20})

      now_before = System.monotonic_time(:millisecond)
      {new_state, _effects} = SpellEffects.apply_spell_status(state, :caster, caster, spell, 50, 50)
      now_after = System.monotonic_time(:millisecond)

      updated = new_state.players[:target]
      [buff] = Enum.filter(updated.buffs, &(&1.type == :blind))

      # 10000ms * 0.7 = 7000ms
      assert buff.expires_at >= now_before + 7000
      assert buff.expires_at <= now_after + 7000 + 50
    end

    test "mage gets full duration (no halving)" do
      caster = make_entity(%{char_id: :caster, mana: 200, x: 49, y: 50, char_index: 1})

      target =
        make_entity(%{
          char_id: :target,
          class: :mage,
          x: 50,
          y: 50,
          char_index: 2,
          blind: false,
          buffs: []
        })

      occupancy = %{{50, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{ciega: true, duration: 10, mana_required: 20})

      now_before = System.monotonic_time(:millisecond)
      {new_state, _effects} = SpellEffects.apply_spell_status(state, :caster, caster, spell, 50, 50)
      now_after = System.monotonic_time(:millisecond)

      updated = new_state.players[:target]
      [buff] = Enum.filter(updated.buffs, &(&1.type == :blind))

      assert buff.expires_at >= now_before + 10_000
      assert buff.expires_at <= now_after + 10_000 + 50
    end
  end

  # ── Resurrect / death / resucitate clear the blind flag ──────────────────

  describe "death/resurrect/resucitate clear blind flag" do
    test "PlayerDeath.handle_player_death clears blind: true" do
      target =
        make_entity(%{
          char_id: :target,
          blind: true,
          buffs: [%{type: :blind, expires_at: System.monotonic_time(:millisecond) + 60_000}]
        })

      state = make_state(%{target: target})

      {dead_entity, _new_state} =
        Arena.Map.PlayerDeath.handle_player_death(state, :target, target)

      assert dead_entity.blind == false, "death must clear blind flag"
    end

    test "spell_effects resurrect clears blind: true" do
      caster =
        make_entity(%{
          char_id: :caster,
          mana: 200,
          x: 49,
          y: 50,
          char_index: 1,
          spells: [99]
        })

      target =
        make_entity(%{
          char_id: :target,
          dead: true,
          hp: 0,
          max_hp: 100,
          x: 50,
          y: 50,
          char_index: 2,
          blind: true,
          buffs: [%{type: :blind, expires_at: System.monotonic_time(:millisecond) + 60_000}]
        })

      occupancy = %{{50, 50} => {:player, :target}}
      state = make_state(%{caster: caster, target: target}, occupancy: occupancy)

      spell = make_spell(%{revivir: true, min_hp: 10, mana_required: 20, work_on_dead: true})

      {new_state, _effects} = SpellEffects.apply_spell_resurrect(state, :caster, caster, spell, 50, 50)

      revived = new_state.players[:target]
      assert revived.dead == false
      assert revived.blind == false, "spell-revive must clear blind flag"
    end

    test "Healing.handle_resucitate clears blind: true" do
      # Set up a Revividor NPC and a dead, blind player.
      npc_def = %Arena.Data.NpcDef{
        id: 600,
        npc_type: 1,
        name: "Revividor",
        faccion: 0,
        body: 1,
        head: 0,
        heading: 3,
        comercia: false,
        quest_numbers: [],
        creatures: []
      }

      unless Process.whereis(Arena.Data.GameData) do
        {:ok, _} = Arena.Data.GameData.start_link([])
      end

      :ets.insert(:arena_game_data, {{:npc, 600}, npc_def})

      target =
        make_entity(%{
          char_id: :player,
          dead: true,
          hp: 0,
          max_hp: 100,
          mana: 50,
          max_mana: 200,
          blind: true,
          buffs: [%{type: :blind, expires_at: System.monotonic_time(:millisecond) + 60_000}],
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: 1
        })

      npcs_live = %{rev1: %{npc_id: 600, x: 51, y: 50, instance_id: :rev1}}

      state = make_state(%{player: target}, sessions: %{player: self()})
      state = %{state | npcs_live: npcs_live}

      {:ok, new_state, _effects} = Arena.Map.Healing.handle_resucitate(state, :player)

      revived = new_state.players[:player]
      assert revived.dead == false
      assert revived.blind == false, "NPC resucitate must clear blind flag"
    end
  end
end
