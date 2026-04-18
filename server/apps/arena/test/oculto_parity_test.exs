defmodule Arena.OcultoParityTest do
  @moduledoc """
  VB6 oculto/stealth parity tests.

  Covers:
  1. Per-class stealth break on movement
  2. Oculto activation skill check and roll
  3. Attack breaks oculto
  4. Spell cast breaks oculto
  """
  use ExUnit.Case, async: true

  import Arena.Test.MapStateFactory

  alias Arena.Map.{Movement, Social, CombatHandlers, Helpers}
  alias AoEntities.PlayerEntity

  # Ensure Metrics atomics ref is available (do_move calls inc_move)
  setup_all do
    Arena.Metrics.setup()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp start_receiver(label) do
    parent = self()
    spawn_link(fn -> receiver_loop(parent, label) end)
  end

  defp receiver_loop(parent, label) do
    receive do
      msg ->
        send(parent, {:receiver, label, msg})
        receiver_loop(parent, label)
    end
  end

  defp make_player(id, overrides \\ %{}) do
    Map.merge(
      %PlayerEntity{
        char_id: id,
        char_index: id,
        x: 50,
        y: 50,
        heading: :south,
        name: "Player#{id}",
        body_id: 1,
        head_id: 1,
        invisible: false,
        oculto: false,
        gm: false,
        dead: false,
        speeding: 1.0,
        equipment: %{weapon: nil, armor: nil, shield: nil, helmet: nil, ring: nil, municion: nil, saddle: nil},
        hp: 100,
        max_hp: 100,
        mana: 100,
        max_mana: 100,
        guild_id: 0,
        guild_level: 0,
        skills: %{},
        class: :guerrero,
        buffs: []
      },
      overrides
    )
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 1. Oculto breaks on movement for non-stealth classes
  # ═══════════════════════════════════════════════════════════════════════

  describe "oculto breaks on movement for non-stealth classes" do
    test "guerrero (warrior) class breaks oculto when moving" do
      sess = start_receiver(:sess)

      entity =
        make_player(1, %{
          x: 50,
          y: 50,
          class: :guerrero,
          oculto: true,
          invisible: true,
          skills: %{hiding: 50},
          buffs: [%{type: :oculto}]
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => sess},
          occupancy: %{{51, 50} => nil},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      now = System.monotonic_time(:millisecond)
      state = Movement.do_move(state, 1, entity, 51, 50, :east, now, 200)
      moved = state.players[1]

      assert moved.oculto == false
      assert moved.invisible == false
    end

    test "mago (caster) class breaks oculto when moving" do
      sess = start_receiver(:sess)

      entity =
        make_player(1, %{
          x: 50,
          y: 50,
          class: :mago,
          oculto: true,
          invisible: true,
          skills: %{hiding: 100},
          buffs: [%{type: :oculto}]
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => sess},
          occupancy: %{{51, 50} => nil},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      now = System.monotonic_time(:millisecond)
      state = Movement.do_move(state, 1, entity, 51, 50, :east, now, 200)
      moved = state.players[1]

      assert moved.oculto == false
      assert moved.invisible == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 2. Stealth classes stay hidden on movement
  # ═══════════════════════════════════════════════════════════════════════

  describe "stealth classes stay hidden on movement" do
    test "asesino always stays hidden on movement" do
      sess = start_receiver(:sess)

      entity =
        make_player(1, %{
          x: 50,
          y: 50,
          class: :asesino,
          oculto: true,
          invisible: true,
          skills: %{hiding: 10},
          buffs: [%{type: :oculto}]
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => sess},
          occupancy: %{{51, 50} => nil},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      now = System.monotonic_time(:millisecond)
      state = Movement.do_move(state, 1, entity, 51, 50, :east, now, 200)
      moved = state.players[1]

      assert moved.oculto == true
      assert moved.invisible == true
    end

    test "ladron with hiding >= 50 stays hidden on movement" do
      sess = start_receiver(:sess)

      entity =
        make_player(1, %{
          x: 50,
          y: 50,
          class: :ladron,
          oculto: true,
          invisible: true,
          skills: %{hiding: 50},
          buffs: [%{type: :oculto}]
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => sess},
          occupancy: %{{51, 50} => nil},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      now = System.monotonic_time(:millisecond)
      state = Movement.do_move(state, 1, entity, 51, 50, :east, now, 200)
      moved = state.players[1]

      assert moved.oculto == true
      assert moved.invisible == true
    end

    test "ladron with hiding < 50 breaks oculto on movement" do
      sess = start_receiver(:sess)

      entity =
        make_player(1, %{
          x: 50,
          y: 50,
          class: :ladron,
          oculto: true,
          invisible: true,
          skills: %{hiding: 49},
          buffs: [%{type: :oculto}]
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => sess},
          occupancy: %{{51, 50} => nil},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      now = System.monotonic_time(:millisecond)
      state = Movement.do_move(state, 1, entity, 51, 50, :east, now, 200)
      moved = state.players[1]

      assert moved.oculto == false
      assert moved.invisible == false
    end

    test "bandido with hiding >= 50 stays hidden on movement" do
      sess = start_receiver(:sess)

      entity =
        make_player(1, %{
          x: 50,
          y: 50,
          class: :bandido,
          oculto: true,
          invisible: true,
          skills: %{hiding: 50},
          buffs: [%{type: :oculto}]
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => sess},
          occupancy: %{{51, 50} => nil},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      now = System.monotonic_time(:millisecond)
      state = Movement.do_move(state, 1, entity, 51, 50, :east, now, 200)
      moved = state.players[1]

      assert moved.oculto == true
      assert moved.invisible == true
    end

    test "cazador needs hiding >= 75 to stay hidden on movement" do
      sess = start_receiver(:sess)

      entity_enough =
        make_player(1, %{
          x: 50,
          y: 50,
          class: :cazador,
          oculto: true,
          invisible: true,
          skills: %{hiding: 75},
          buffs: [%{type: :oculto}]
        })

      state =
        map_state(
          players: %{1 => entity_enough},
          sessions: %{1 => sess},
          occupancy: %{{51, 50} => nil},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      now = System.monotonic_time(:millisecond)
      state = Movement.do_move(state, 1, entity_enough, 51, 50, :east, now, 200)
      moved = state.players[1]

      assert moved.oculto == true,
        "cazador with hiding=75 should stay hidden"

      assert moved.invisible == true

      # Now test cazador with hiding < 75 breaks
      sess2 = start_receiver(:sess2)

      entity_not_enough =
        make_player(2, %{
          x: 50,
          y: 50,
          class: :cazador,
          oculto: true,
          invisible: true,
          skills: %{hiding: 74},
          buffs: [%{type: :oculto}]
        })

      state2 =
        map_state(
          players: %{2 => entity_not_enough},
          sessions: %{2 => sess2},
          occupancy: %{{51, 50} => nil},
          visibility_mode: :global,
          meta: %{tile_exit_map: %{}}
        )

      state2 = Movement.do_move(state2, 2, entity_not_enough, 51, 50, :east, now, 200)
      moved2 = state2.players[2]

      assert moved2.oculto == false,
        "cazador with hiding=74 should break stealth"

      assert moved2.invisible == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 3. Oculto activation requires hiding skill > 0 and can fail
  # ═══════════════════════════════════════════════════════════════════════

  describe "oculto activation skill check" do
    test "hiding skill 0 prevents activation" do
      sess = start_receiver(:sess)
      entity = make_player(1, %{skills: %{hiding: 0}})

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => sess},
          visibility_mode: :global
        )

      {:noreply, state} = Social.handle_ocultarse(state, 1, 0)
      assert state.players[1].oculto == false
    end

    test "oculto activation can fail on skill roll" do
      # With skill_level = 1, the success chance is 1/100.
      # We seed :rand so we can guarantee a failure.
      # We'll run 100 attempts; with skill=1, most should fail.
      # But really, we need a deterministic test. We'll use skill_level = 1 and
      # check that the implementation does a random roll, meaning sometimes it fails.
      # Strategy: call handle_ocultarse many times with skill=1, at least one should fail.
      results =
        for _ <- 1..200 do
          sess = start_receiver(:sess)
          entity = make_player(1, %{skills: %{hiding: 1}, oculto: false})

          state =
            map_state(
              players: %{1 => entity},
              sessions: %{1 => sess},
              visibility_mode: :global
            )

          {:noreply, new_state} = Social.handle_ocultarse(state, 1, 1)
          new_state.players[1].oculto
        end

      successes = Enum.count(results, & &1)
      failures = Enum.count(results, &(not &1))

      # With skill=1, success chance is 1%. We expect most to fail.
      # At least some should fail (with overwhelming probability).
      assert failures > 0, "With skill=1, at least some attempts should fail"
      # Also verify that the mechanism doesn't just always succeed
      assert failures > successes, "With skill=1, failures should outnumber successes"
    end

    test "high skill almost always succeeds" do
      results =
        for _ <- 1..50 do
          sess = start_receiver(:sess)
          entity = make_player(1, %{skills: %{hiding: 100}, oculto: false})

          state =
            map_state(
              players: %{1 => entity},
              sessions: %{1 => sess},
              visibility_mode: :global
            )

          {:noreply, new_state} = Social.handle_ocultarse(state, 1, 100)
          new_state.players[1].oculto
        end

      successes = Enum.count(results, & &1)

      # With skill=100, should always succeed (100% chance)
      assert successes == 50
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 4. Attack breaks oculto
  # ═══════════════════════════════════════════════════════════════════════

  describe "attack breaks oculto" do
    test "melee attack breaks attacker oculto" do
      sess = start_receiver(:sess)

      attacker =
        make_player(1, %{
          x: 50,
          y: 50,
          heading: :south,
          oculto: true,
          invisible: true,
          skills: %{hiding: 100, combat_weapons: 50},
          buffs: [%{type: :oculto}],
          class: :asesino,
          next_attack_at: -1_000_000_000_000
        })

      state =
        map_state(
          players: %{1 => attacker},
          sessions: %{1 => sess},
          occupancy: %{},
          visibility_mode: :global,
          meta: %{safe_zone: false, tile_exit_map: %{}}
        )

      {:reply, :ok, new_state} = CombatHandlers.handle_attack(state, 1, nil, nil)
      a = new_state.players[1]

      assert a.oculto == false
      assert a.invisible == false
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # 5. Spell cast breaks oculto
  # ═══════════════════════════════════════════════════════════════════════

  describe "spell cast breaks oculto" do
    test "offensive spell breaks caster oculto" do
      # We test via Helpers.break_invisibility directly since the full
      # spell handler requires GameData and spell definitions loaded.
      sess = start_receiver(:sess)

      entity =
        make_player(1, %{
          oculto: true,
          invisible: true,
          buffs: [%{type: :oculto}]
        })

      state =
        map_state(
          players: %{1 => entity},
          sessions: %{1 => sess},
          visibility_mode: :global
        )

      result = Helpers.break_invisibility(entity, state, 1)

      assert result.oculto == false
      assert result.invisible == false
    end
  end
end
