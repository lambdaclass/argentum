defmodule Arena.HealingGoldenTest do
  @moduledoc """
  Golden fixture for the heal/rest/meditate/resurrect flow, written against
  the deterministic scenario harness (`Arena.Test.Scenario`).

  Covers `Arena.Map.Healing` end-to-end: every reachable branch of every
  handler is asserted via the gameplay-shaped effect DSL, not raw mailbox
  shape. Counterpart to `healing_drift_test.exs`, which pins specific
  drift items in the legacy mailbox style.

  Phase 1 / Item 5 of `ROADMAP.md` — "per-flow golden fixtures for
  high-drift gameplay flows", starting with heal because `Arena.Map.Healing`
  was the first effects-migrated module.

  VB6 anchors (confirmed against `Arena.Map.Healing` port comments; no VB6
  source tree is vendored in this repo, so procedure entry points the port
  does not cite are marked pending rather than guessed):
    * `handle_rest`       — Protocol.bas:1693 `WriteRestOK` flips client-side
                            resting; rest requires a nearby campfire
                            (`OBJ_INDEX_FOGATA = 21`, `HayOBJarea` within 8 tiles).
    * `handle_meditate`   — Montado guard ("No podes meditar estando montado");
                            meditate FX varies by level/faction.
                            (Protocol.bas entry point pending VB6 source.)
    * `handle_heal`       — Revividor NPC full heal; jail short-circuit
                            `If .pos.Map = MAP_HOME_IN_JAIL (66) And npcType = Revividor Then Exit Sub`.
    * `handle_resucitate` — Revividor NPC required nearby; `ResucitadorNewbie`
                            serves newbies only (level <= 12); NPC revive does
                            NOT zero mana (only spell-based revive does).

  Constants below are VB6-sourced: `@npc_type_revividor 1`,
  `@npc_type_resucitador_newbie 9`, `@fogata_obj_index 21` (OBJ_INDEX_FOGATA),
  `@jail_map_id 66` (MAP_HOME_IN_JAIL).
  """
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, NpcDef}
  alias Arena.Map.Healing

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  @npc_type_revividor 1
  @npc_type_resucitador_newbie 9
  @fogata_obj_index 21
  @jail_map_id 66

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    :ets.insert(:arena_game_data, {{:npc, 500}, npc_def(500, @npc_type_revividor)})
    :ets.insert(:arena_game_data, {{:npc, 501}, npc_def(501, @npc_type_resucitador_newbie)})
    :ok
  end

  defp npc_def(id, npc_type) do
    %NpcDef{
      id: id,
      npc_type: npc_type,
      name: "Sacerdote",
      faccion: 0,
      body: 1,
      head: 0,
      heading: 3,
      comercia: false,
      quest_numbers: [],
      creatures: []
    }
  end

  defp with_revividor(scenario, instance_id \\ :rev1, opts \\ []) do
    with_npc(
      scenario,
      instance_id,
      Keyword.merge([npc_id: 500, x: 51, y: 50], opts)
    )
  end

  defp with_resucitador_newbie(scenario, instance_id \\ :newbie_rev1, opts \\ []) do
    with_npc(
      scenario,
      instance_id,
      Keyword.merge([npc_id: 501, x: 51, y: 50], opts)
    )
  end

  defp with_fogata(scenario, x, y) do
    update_state(scenario, fn state ->
      item = %{item_id: @fogata_obj_index, amount: 1, elemental_tags: 0}
      %{state | ground_items: Map.put(state.ground_items, {x, y}, item)}
    end)
  end

  defp run_heal(scenario, char_id) do
    run(scenario, fn state -> Healing.handle_heal(state, char_id) end)
  end

  defp run_rest(scenario, char_id) do
    run(scenario, fn state -> Healing.handle_rest(state, char_id) end)
  end

  defp run_meditate(scenario, char_id) do
    run(scenario, fn state -> Healing.handle_meditate(state, char_id) end)
  end

  defp run_resucitate(scenario, char_id) do
    run(scenario, fn state -> Healing.handle_resucitate(state, char_id) end)
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_rest
  # ────────────────────────────────────────────────────────────────────

  describe "handle_rest" do
    test "fogata in range: toggles resting on, emits console + rest_ok" do
      s =
        new()
        |> with_player(:p, hp: 50, max_hp: 100)
        |> with_fogata(50, 51)
        |> run_rest(:p)

      assert entity(s, :p).resting
      assert_effect(s, :send, to: :p, packet: :console_msg)
      assert_effect(s, :send, to: :p, packet: :rest_ok)

      # Byte-level fixture: eRestOK (72) toggles the resting animation with an
      # empty payload — exactly the 2-byte id, no trailing bytes.
      assert <<72::little-signed-16>> == assert_payload(s, :send, to: :p, packet: :rest_ok)
    end

    test "second call toggles resting off, still emits rest_ok" do
      s =
        new()
        |> with_player(:p, hp: 50, max_hp: 100, resting: true)
        |> with_fogata(50, 51)
        |> run_rest(:p)

      refute entity(s, :p).resting
      assert_effect(s, :send, to: :p, packet: :rest_ok)
    end

    test "starting to rest also clears meditating" do
      s =
        new()
        |> with_player(:p, hp: 50, max_hp: 100, meditating: true)
        |> with_fogata(50, 51)
        |> run_rest(:p)

      assert entity(s, :p).resting
      refute entity(s, :p).meditating
    end

    test "no fogata: rejected with console message, no rest_ok" do
      s =
        new()
        |> with_player(:p, hp: 50, max_hp: 100)
        |> run_rest(:p)

      refute entity(s, :p).resting
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :rest_ok)
    end

    test "fogata too far away: rejected" do
      s =
        new()
        |> with_player(:p, hp: 50, max_hp: 100)
        |> with_fogata(60, 60)
        |> run_rest(:p)

      refute entity(s, :p).resting
      refute_effect(s, :send, to: :p, packet: :rest_ok)
    end

    test "fogata at radius edge (8 tiles) succeeds, 9 tiles fails" do
      s_edge =
        new()
        |> with_player(:p, hp: 50, max_hp: 100)
        |> with_fogata(58, 50)
        |> run_rest(:p)

      assert entity(s_edge, :p).resting

      s_just_out =
        new()
        |> with_player(:p, hp: 50, max_hp: 100)
        |> with_fogata(59, 50)
        |> run_rest(:p)

      refute entity(s_just_out, :p).resting
    end

    test "dead player: rejected with 'Estas muerto'" do
      s =
        new()
        |> with_player(:p, dead: true, hp: 0, max_hp: 100)
        |> with_fogata(50, 51)
        |> run_rest(:p)

      refute entity(s, :p).resting
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :rest_ok)
    end

    test "full HP: rejected with 'Estas sano'" do
      s =
        new()
        |> with_player(:p, hp: 100, max_hp: 100)
        |> with_fogata(50, 51)
        |> run_rest(:p)

      refute entity(s, :p).resting
      refute_effect(s, :send, to: :p, packet: :rest_ok)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_meditate
  # ────────────────────────────────────────────────────────────────────

  describe "handle_meditate" do
    test "magical class with mana below max: toggles on, emits FX broadcast" do
      s =
        new()
        |> with_player(:p, class: :mage, mana: 50, max_mana: 200)
        |> run_meditate(:p)

      assert entity(s, :p).meditating
      assert_effect(s, :send, to: :p, packet: :console_msg)
      assert_effect(s, :broadcast_visible_all, at: {50, 50}, packet: :create_fx)
    end

    test "stopping meditate: toggles off, no FX broadcast" do
      s =
        new()
        |> with_player(:p, class: :mage, mana: 50, max_mana: 200, meditating: true)
        |> run_meditate(:p)

      refute entity(s, :p).meditating
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :broadcast_visible_all, at: {50, 50}, packet: :create_fx)
    end

    test "starting to meditate also clears resting" do
      s =
        new()
        |> with_player(:p, class: :mage, mana: 50, max_mana: 200, resting: true)
        |> run_meditate(:p)

      assert entity(s, :p).meditating
      refute entity(s, :p).resting
    end

    test "mounted player: rejected (drift #19)" do
      s =
        new()
        |> with_player(:p, class: :mage, mana: 50, max_mana: 200, mounted: true)
        |> run_meditate(:p)

      refute entity(s, :p).meditating
      refute_effect(s, :broadcast_visible_all, packet: :create_fx)
    end

    test "non-magical class: rejected" do
      s =
        new()
        |> with_player(:p, class: :warrior, mana: 50, max_mana: 200)
        |> run_meditate(:p)

      refute entity(s, :p).meditating
      refute_effect(s, :broadcast_visible_all, packet: :create_fx)
    end

    test "dead player: rejected" do
      s =
        new()
        |> with_player(:p, class: :mage, dead: true, mana: 0, max_mana: 200)
        |> run_meditate(:p)

      refute entity(s, :p).meditating
    end

    test "full mana: rejected" do
      s =
        new()
        |> with_player(:p, class: :mage, mana: 200, max_mana: 200)
        |> run_meditate(:p)

      refute entity(s, :p).meditating
    end

    test "every magical class can meditate" do
      for cls <- [:mage, :cleric, :druid, :bard, :paladin] do
        s =
          new()
          |> with_player(:p, class: cls, mana: 50, max_mana: 200)
          |> run_meditate(:p)

        assert entity(s, :p).meditating, "class #{inspect(cls)} should be allowed to meditate"
      end
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_heal
  # ────────────────────────────────────────────────────────────────────

  describe "handle_heal" do
    test "selected revividor in range: HP restored to max, update_hp + console emitted" do
      s =
        new(map_id: 1)
        |> with_player(:p,
          hp: 50,
          max_hp: 100,
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: @npc_type_revividor
        )
        |> with_revividor()
        |> run_heal(:p)

      assert entity(s, :p).hp == 100
      assert_effect(s, :send, to: :p, packet: :console_msg)
      assert_effect(s, :send, to: :p, packet: :update_hp)

      # Byte-level fixture: eUpdateHP (27) — MinHp(Int16) + shield(Int32).
      # The NPC heal restores to max (100); the encoded field must say so.
      assert <<27::little-signed-16, 100::little-signed-16, _shield::little-signed-32>> =
               assert_payload(s, :send, to: :p, packet: :update_hp)
    end

    test "ResucitadorNewbie heals non-newbie player (VB6: no level check on heal)" do
      s =
        new(map_id: 1)
        |> with_player(:p,
          hp: 50,
          max_hp: 100,
          level: 25,
          last_clicked_npc_instance_id: :newbie_rev1,
          last_clicked_npc_type: @npc_type_resucitador_newbie
        )
        |> with_resucitador_newbie()
        |> run_heal(:p)

      assert entity(s, :p).hp == 100
    end

    test "jail map + revividor: blocked (drift #22)" do
      s =
        new(map_id: @jail_map_id)
        |> with_player(:p,
          hp: 50,
          max_hp: 100,
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: @npc_type_revividor
        )
        |> with_revividor()
        |> run_heal(:p)

      assert entity(s, :p).hp == 50
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end

    test "no NPC selected: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, hp: 50, max_hp: 100)
        |> with_revividor()
        |> run_heal(:p)

      assert entity(s, :p).hp == 50
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end

    test "selected NPC out of range: rejected" do
      # max_distance=10 in handle_heal; place revividor 12 tiles away
      s =
        new(map_id: 1)
        |> with_player(:p,
          x: 50,
          y: 50,
          hp: 50,
          max_hp: 100,
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: @npc_type_revividor
        )
        |> with_revividor(:rev1, x: 62, y: 50)
        |> run_heal(:p)

      assert entity(s, :p).hp == 50
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end

    test "dead player: rejected with 'Estas muerto'" do
      s =
        new(map_id: 1)
        |> with_player(:p,
          dead: true,
          hp: 0,
          max_hp: 100,
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: @npc_type_revividor
        )
        |> with_revividor()
        |> run_heal(:p)

      assert entity(s, :p).hp == 0
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end

    test "full HP: rejected with 'Estas sano'" do
      s =
        new(map_id: 1)
        |> with_player(:p,
          hp: 100,
          max_hp: 100,
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: @npc_type_revividor
        )
        |> with_revividor()
        |> run_heal(:p)

      refute_effect(s, :send, to: :p, packet: :update_hp)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # handle_resucitate
  # ────────────────────────────────────────────────────────────────────

  describe "handle_resucitate" do
    test "dead + revividor selected: revives, restores HP, preserves mana, broadcasts FX (drift #23)" do
      s =
        new()
        |> with_player(:p,
          dead: true,
          hp: 0,
          max_hp: 100,
          mana: 150,
          max_mana: 200,
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: @npc_type_revividor
        )
        |> with_revividor()
        |> run_resucitate(:p)

      e = entity(s, :p)
      refute e.dead
      assert e.hp == 100
      assert e.mana == 150, "VB6: NPC resurrect preserves mana, only spell revive zeroes it"

      assert_effect(s, :send, to: :p, packet: :update_hp)
      assert_effect(s, :send, to: :p, packet: :update_mana)
      assert_effect(s, :send, to: :p, packet: :console_msg)
      assert_effect(s, :broadcast_character_change, char_id: :p)
      assert_effect(s, :broadcast_visible_all, at: {50, 50}, packet: :create_fx)

      # Byte-level fixture: resurrect restores HP to max (100) and preserves
      # mana (150) — the encoded eUpdateHP (27) / eUpdateMana (26) fields must
      # carry those exact post-revive values, pinning drift #23.
      assert <<27::little-signed-16, 100::little-signed-16, _shield::little-signed-32>> =
               assert_payload(s, :send, to: :p, packet: :update_hp)

      assert <<26::little-signed-16, 150::little-signed-16>> =
               assert_payload(s, :send, to: :p, packet: :update_mana)
    end

    test "resurrection clears all status effects" do
      s =
        new()
        |> with_player(:p,
          dead: true,
          hp: 0,
          max_hp: 100,
          paralyzed: true,
          blind: true,
          dumb: true,
          poisoned: true,
          invisible: true,
          buffs: [%{type: :paralyzed, expires_at: 99_999_999}],
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: @npc_type_revividor
        )
        |> with_revividor()
        |> run_resucitate(:p)

      e = entity(s, :p)
      refute e.dead
      refute e.paralyzed
      refute e.blind
      refute e.dumb
      refute e.poisoned
      refute e.invisible
      assert e.buffs == []
    end

    test "ResucitadorNewbie + non-newbie (level > 12): rejected" do
      s =
        new()
        |> with_player(:p,
          dead: true,
          hp: 0,
          max_hp: 100,
          level: 25,
          last_clicked_npc_instance_id: :newbie_rev1,
          last_clicked_npc_type: @npc_type_resucitador_newbie
        )
        |> with_resucitador_newbie()
        |> run_resucitate(:p)

      assert entity(s, :p).dead
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end

    test "ResucitadorNewbie + newbie (level <= 12): allowed" do
      s =
        new()
        |> with_player(:p,
          dead: true,
          hp: 0,
          max_hp: 100,
          level: 12,
          last_clicked_npc_instance_id: :newbie_rev1,
          last_clicked_npc_type: @npc_type_resucitador_newbie
        )
        |> with_resucitador_newbie()
        |> run_resucitate(:p)

      refute entity(s, :p).dead
      assert entity(s, :p).hp == 100
    end

    test "alive player: rejected with 'No estas muerto'" do
      s =
        new()
        |> with_player(:p,
          dead: false,
          hp: 100,
          max_hp: 100,
          last_clicked_npc_instance_id: :rev1,
          last_clicked_npc_type: @npc_type_revividor
        )
        |> with_revividor()
        |> run_resucitate(:p)

      refute_effect(s, :send, to: :p, packet: :update_hp)
      refute_effect(s, :broadcast_character_change, char_id: :p)
    end

    test "no NPC selected: rejected" do
      s =
        new()
        |> with_player(:p, dead: true, hp: 0, max_hp: 100)
        |> with_revividor()
        |> run_resucitate(:p)

      assert entity(s, :p).dead
      refute_effect(s, :send, to: :p, packet: :update_hp)
    end
  end
end
