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

  Migrated to `Arena.Test.Scenario` in slice 4b. The cura_ceguera
  spell-clear paths drive `SpellEffects.apply_spell_status/6` through
  `run_effects/2` and assert via `assert_effect`/`refute_effect` (the
  spell handler emits effects via `Arena.Map.Effects`). The
  tick-expiry paths still rely on `assert_receive`/`refute_receive`
  because `StatusTicks.process_player_buffs/4` calls
  `Helpers.send_to_session/3` directly — those packets land in the
  test mailbox but are NOT yet on the effects contract. Migrating
  buff-tick to the contract is slice 5.
  """
  use ExUnit.Case, async: false

  alias Arena.Data.SpellDef
  alias Arena.Map.SpellEffects
  alias AoProtocol.Server.Encoder

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

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
      # Cast the synthetic ciega spell with a frozen clock, then advance
      # past its `expires_at` and run a buff tick. NOTE:
      # `StatusTicks.process_player_buffs/4` uses `Helpers.send_to_session/3`
      # directly, so the :blind_no_more packet lands in the test mailbox
      # but NOT in `scenario.effects`. We assert via `assert_receive`
      # until the tick path is migrated to the effects contract (slice 5).
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:caster, char_index: 1, x: 49, y: 50, mana: 200, max_mana: 200)
        |> with_player(:target,
          char_index: 2,
          x: 50,
          y: 50,
          buffs: [],
          blind: false,
          mana: 200,
          max_mana: 200
        )

      caster = entity(s, :caster)
      spell = make_spell(%{ciega: true, duration: 1, mana_required: 20})

      s =
        run_effects(s, fn st ->
          SpellEffects.apply_spell_status(st, :caster, caster, spell, 50, 50)
        end)

      assert entity(s, :target).blind == true,
             "synthetic ciega spell must set blind: true"

      # Drain the update_mana side-effect from the cast (it goes through
      # `Effects.run/2` to the target session = test pid).
      drain_mailbox()

      # apply_spell_status floors the duration to 3000ms; advance past it.
      s = advance_clock(s, 5_000)

      _s = tick(s, :buff)

      assert_receive {:send_raw, @blind_no_more_packet}, 200
    end
  end

  # ── cura_ceguera spell-clear path ────────────────────────────────────────

  describe "cura_ceguera spell clears blind and emits packet" do
    test "blind target receives :blind_no_more when cura_ceguera lands" do
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:caster, char_index: 1, x: 49, y: 50, mana: 200, max_mana: 200)
        |> with_player(:target,
          char_index: 2,
          x: 50,
          y: 50,
          blind: true,
          buffs: [%{type: :blind, expires_at: now + 60_000}],
          mana: 200,
          max_mana: 200
        )

      caster = entity(s, :caster)
      spell = make_spell(%{cura_ceguera: true, mana_required: 20, duration: 0})

      s =
        run_effects(s, fn st ->
          SpellEffects.apply_spell_status(st, :caster, caster, spell, 50, 50)
        end)

      cleared = entity(s, :target)
      assert cleared.blind == false, "cura_ceguera must clear the blind flag"

      refute Enum.any?(cleared.buffs, &(&1.type == :blind)),
             "cura_ceguera must drop the :blind buff entry"

      assert_effect(s, :send, to: :target, packet: :blind_no_more)
    end
  end

  # ── Adversarial: cura_ceguera on a non-blind target ──────────────────────

  describe "cura_ceguera on non-blind target is a no-op (VB6 guard)" do
    test "no :blind_no_more emitted when target was not blind" do
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:caster, char_index: 1, x: 49, y: 50, mana: 200, max_mana: 200)
        |> with_player(:target,
          char_index: 2,
          x: 50,
          y: 50,
          blind: false,
          buffs: [],
          mana: 200,
          max_mana: 200
        )

      caster = entity(s, :caster)
      spell = make_spell(%{cura_ceguera: true, mana_required: 20, duration: 0})

      s =
        run_effects(s, fn st ->
          SpellEffects.apply_spell_status(st, :caster, caster, spell, 50, 50)
        end)

      refute_effect(s, :send, to: :target, packet: :blind_no_more)
    end
  end

  # ── Adversarial: tick on a non-blind target ──────────────────────────────

  describe "tick with no :blind buff emits no packet" do
    test "no :blind_no_more emitted when there's no :blind buff" do
      # NOTE: tick path emits via `Helpers.send_to_session/3`; packets
      # land in the test mailbox, not `scenario.effects`. Assertion stays
      # on `refute_receive` until the tick is migrated to the contract.
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:target, char_index: 1, x: 50, y: 50, blind: false, buffs: [])

      drain_mailbox()
      _s = tick(s, :buff)

      refute_receive {:send_raw, @blind_no_more_packet}, 100
    end
  end

  # ── Warrior 0.7x duration parity ────────────────────────────────────────

  describe "warrior gets 0.7x blind duration (VB6 parity)" do
    test "warrior class blind buff has 0.7x duration offset" do
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:caster, char_index: 1, x: 49, y: 50, mana: 200, max_mana: 200)
        |> with_player(:target,
          char_index: 2,
          x: 50,
          y: 50,
          class: :guerrero,
          blind: false,
          buffs: []
        )

      caster = entity(s, :caster)

      # duration 10 → 10000ms; warrior gets 0.7x → 7000ms
      spell = make_spell(%{ciega: true, duration: 10, mana_required: 20})

      s =
        run_effects(s, fn st ->
          SpellEffects.apply_spell_status(st, :caster, caster, spell, 50, 50)
        end)

      [buff] = Enum.filter(entity(s, :target).buffs, &(&1.type == :blind))

      # Frozen clock — exact arithmetic, no jitter window needed.
      assert buff.expires_at == now + 7000
    end

    test "mage gets full duration (no halving)" do
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:caster, char_index: 1, x: 49, y: 50, mana: 200, max_mana: 200)
        |> with_player(:target,
          char_index: 2,
          x: 50,
          y: 50,
          class: :mage,
          blind: false,
          buffs: []
        )

      caster = entity(s, :caster)
      spell = make_spell(%{ciega: true, duration: 10, mana_required: 20})

      s =
        run_effects(s, fn st ->
          SpellEffects.apply_spell_status(st, :caster, caster, spell, 50, 50)
        end)

      [buff] = Enum.filter(entity(s, :target).buffs, &(&1.type == :blind))

      assert buff.expires_at == now + 10_000
    end
  end

  # ── Resurrect / death / resucitate clear the blind flag ──────────────────

  describe "death/resurrect/resucitate clear blind flag" do
    test "PlayerDeath.handle_player_death clears blind: true" do
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:target,
          char_index: 1,
          x: 50,
          y: 50,
          blind: true,
          buffs: [%{type: :blind, expires_at: now + 60_000}]
        )

      # `handle_player_death/3` returns `{player, state, effects}` — adapt
      # to `run_effects/2`'s `{state, effects}` shape by re-inserting the
      # dead player into the state map ourselves (the production caller
      # in StatusTicks does the same).
      s =
        run_effects(s, fn st ->
          target = st.players[:target]

          {dead_player, new_state, effects} =
            Arena.Map.PlayerDeath.handle_player_death(st, :target, target)

          new_state = %{new_state | players: Map.put(new_state.players, :target, dead_player)}
          {new_state, effects}
        end)

      assert entity(s, :target).blind == false, "death must clear blind flag"
    end

    test "spell_effects resurrect clears blind: true" do
      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:caster,
          char_index: 1,
          x: 49,
          y: 50,
          mana: 200,
          max_mana: 200,
          spells: [99]
        )
        |> with_player(:target,
          char_index: 2,
          x: 50,
          y: 50,
          dead: true,
          hp: 0,
          max_hp: 100,
          blind: true,
          buffs: [%{type: :blind, expires_at: now + 60_000}]
        )

      caster = entity(s, :caster)
      spell = make_spell(%{revivir: true, min_hp: 10, mana_required: 20, work_on_dead: true})

      s =
        run_effects(s, fn st ->
          SpellEffects.apply_spell_resurrect(st, :caster, caster, spell, 50, 50)
        end)

      revived = entity(s, :target)
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

      now = 1_000_000

      s =
        new()
        |> set_clock(now)
        |> with_player(:player,
          char_index: 1,
          x: 50,
          y: 50,
          dead: true,
          hp: 0,
          max_hp: 100,
          mana: 50,
          max_mana: 200,
          blind: true,
          buffs: [%{type: :blind, expires_at: now + 60_000}],
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: 1
        )

      # Healing.handle_resucitate looks up the NPC in `state.npcs_live`
      # via `Helpers.resolve_selected_npc`. Place a synthetic Revividor
      # adjacent to the player. `with_npc/3` would build a full
      # %NpcEntity{}; this handler only reads `npc_id`, `x`, `y`,
      # `instance_id`, so we patch `npcs_live` directly.
      s = update_state(s, fn st ->
        %{st | npcs_live: %{rev1: %{npc_id: 600, x: 51, y: 50, instance_id: :rev1}}}
      end)

      s =
        run(s, fn st ->
          Arena.Map.Healing.handle_resucitate(st, :player)
        end)

      revived = entity(s, :player)
      assert revived.dead == false
      assert revived.blind == false, "NPC resucitate must clear blind flag"
    end
  end
end
