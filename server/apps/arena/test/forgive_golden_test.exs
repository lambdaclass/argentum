defmodule Arena.ForgiveGoldenTest do
  @moduledoc """
  Golden fixture for the /PERDON criminal-forgive flow
  (`Arena.Map.NpcInteraction.handle_forgive/3`), written against the
  deterministic scenario harness.

  Phase 1 / Item 5 of `ROADMAP.md`. Pins VB6 parity for:
    * Required donation tied to `citizens_killed` (HandleDonateGold).
    * Faction-member rejection (armada/caos cannot use /PERDON).
    * Priest range (3 tiles, VB6 `Distancia`).
    * ResucitadorNewbie level gating (level <= 12 only).

  VB6 anchors (confirmed against `Arena.Map.NpcInteraction` port comments;
  no VB6 source tree is vendored, so Protocol.bas lines are pending):
    * `handle_forgive/3`  — Protocol.bas `HandleDonateGold` + `HandleForgive`;
                            donation threshold scales on `ciudadanosMatados`
                            (npc_interaction.ex:334).
    * Priest range        — `Distancia <= 3` (npc_interaction.ex:304,378).
    * Faction gate        — armada/caos members cannot use /PERDON
                            (npc_interaction.ex:317).
    * Newbie path         — `ResucitadorNewbie` serves `EsNewbie` only
                            (level <= 12; npc_interaction.ex:329).

  Constants below are VB6-sourced: `@npc_type_revividor 1`,
  `@npc_type_resucitador_newbie 9`,
  `@costo_perdon_por_ciudadano 5000` (per-citizen donation cost).
  """
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, NpcDef}
  alias Arena.Map.NpcInteraction

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  @npc_type_revividor 1
  @npc_type_resucitador_newbie 9
  @costo_perdon_por_ciudadano 5000
  @half_costo div(@costo_perdon_por_ciudadano, 2)

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

  defp with_revividor(scenario, opts \\ []) do
    with_npc(scenario, :rev1, Keyword.merge([npc_id: 500, x: 51, y: 50], opts))
  end

  defp with_resucitador_newbie(scenario, opts \\ []) do
    with_npc(scenario, :newbie_rev1, Keyword.merge([npc_id: 501, x: 51, y: 50], opts))
  end

  defp run_forgive(scenario, char_id, gold) do
    run(scenario, fn state -> NpcInteraction.handle_forgive(state, char_id, gold) end)
  end

  defp criminal(opts) do
    Keyword.merge(
      [
        criminal: true,
        gold: 100_000,
        citizens_killed: 0,
        faction: :none,
        last_clicked_npc_instance_id: :rev1,
        last_clicked_npc_type: @npc_type_revividor
      ],
      opts
    )
  end

  # ────────────────────────────────────────────────────────────────────
  # Happy paths
  # ────────────────────────────────────────────────────────────────────

  describe "successful pardon" do
    test "no citizens killed: half-base donation pardons the player" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal(citizens_killed: 0))
        |> with_revividor()
        |> run_forgive(:p, @half_costo)

      e = entity(s, :p)
      refute e.criminal, "VB6: pardon clears criminal flag"
      assert e.gold == 100_000 - @half_costo
      assert_effect(s, :send, to: :p, packet: :update_gold)
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end

    test "citizens killed: donation scales by citizens_killed * 5000" do
      # 3 citizens killed → 3 * 5000 = 15_000 required
      required = 3 * @costo_perdon_por_ciudadano

      s =
        new(map_id: 1)
        |> with_player(:p, criminal(citizens_killed: 3, gold: required + 100))
        |> with_revividor()
        |> run_forgive(:p, required)

      e = entity(s, :p)
      refute e.criminal
      assert e.gold == 100
    end

    test "ResucitadorNewbie pardons newbie (level <= 12)" do
      s =
        new(map_id: 1)
        |> with_player(
          :p,
          criminal(
            level: 12,
            last_clicked_npc_instance_id: :newbie_rev1,
            last_clicked_npc_type: @npc_type_resucitador_newbie
          )
        )
        |> with_resucitador_newbie()
        |> run_forgive(:p, @half_costo)

      refute entity(s, :p).criminal
    end

    test "donation above required is accepted as-is (no refund)" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal(gold: 100_000))
        |> with_revividor()
        |> run_forgive(:p, 50_000)

      e = entity(s, :p)
      refute e.criminal
      assert e.gold == 50_000, "VB6: gold_amount is fully consumed, no refund"
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Player-state rejections
  # ────────────────────────────────────────────────────────────────────

  describe "player-state rejections" do
    test "dead player: rejected, no state change" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal(dead: true, hp: 0, max_hp: 100))
        |> with_revividor()
        |> run_forgive(:p, @half_costo)

      e = entity(s, :p)
      assert e.criminal
      assert e.gold == 100_000
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "non-criminal player: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal(criminal: false))
        |> with_revividor()
        |> run_forgive(:p, @half_costo)

      assert entity(s, :p).gold == 100_000
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "royal_army faction member: rejected (cannot use /PERDON)" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal(faction: :royal_army))
        |> with_revividor()
        |> run_forgive(:p, @half_costo)

      e = entity(s, :p)
      assert e.criminal, "faction member retains criminal flag"
      assert e.gold == 100_000
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "chaos_legion faction member: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal(faction: :chaos_legion))
        |> with_revividor()
        |> run_forgive(:p, @half_costo)

      assert entity(s, :p).criminal
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Priest selection / range
  # ────────────────────────────────────────────────────────────────────

  describe "priest selection and range" do
    test "no NPC selected: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p,
          criminal: true,
          gold: 100_000,
          citizens_killed: 0,
          faction: :none,
          last_clicked_npc_instance_id: nil,
          last_clicked_npc_type: nil
        )
        |> with_revividor()
        |> run_forgive(:p, @half_costo)

      assert entity(s, :p).criminal
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "priest beyond 3 tiles: rejected (VB6 Distancia <= 3)" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal([]))
        |> with_revividor(x: 55, y: 50)
        |> run_forgive(:p, @half_costo)

      assert entity(s, :p).criminal
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "priest at exactly 3 tiles: accepted" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal([]))
        |> with_revividor(x: 53, y: 50)
        |> run_forgive(:p, @half_costo)

      refute entity(s, :p).criminal
    end

    test "ResucitadorNewbie + non-newbie (level > 12): rejected" do
      s =
        new(map_id: 1)
        |> with_player(
          :p,
          criminal(
            level: 25,
            last_clicked_npc_instance_id: :newbie_rev1,
            last_clicked_npc_type: @npc_type_resucitador_newbie
          )
        )
        |> with_resucitador_newbie()
        |> run_forgive(:p, @half_costo)

      assert entity(s, :p).criminal
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Donation amount validation
  # ────────────────────────────────────────────────────────────────────

  describe "donation amount validation" do
    test "donation less than required: 'avara' rejection, no charge" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal([]))
        |> with_revividor()
        |> run_forgive(:p, @half_costo - 1)

      e = entity(s, :p)
      assert e.criminal
      assert e.gold == 100_000, "rejected donation must not deduct gold"
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "donation exceeds player gold: 'no tienes suficiente' rejection" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal(gold: 100))
        |> with_revividor()
        |> run_forgive(:p, 10_000)

      e = entity(s, :p)
      assert e.criminal
      assert e.gold == 100
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "boundary: donation == required is accepted" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal([]))
        |> with_revividor()
        |> run_forgive(:p, @half_costo)

      refute entity(s, :p).criminal
    end

    test "boundary: donation == required - 1 is rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, criminal([]))
        |> with_revividor()
        |> run_forgive(:p, @half_costo - 1)

      assert entity(s, :p).criminal
    end
  end
end
