defmodule Arena.GambleGoldenTest do
  @moduledoc """
  Golden fixture for the /APUESTAS gamble flow
  (`Arena.Map.NpcInteraction.handle_gamble/4`), written against the
  deterministic scenario harness.

  Phase 1 / Item 5 of `ROADMAP.md`. Pins VB6 parity for:
    * Player-state rejections (dead).
    * Bet validation (>0, <=5000, gold sufficiency).
    * Timbero NPC selection + range (10 tiles).
    * Win/loss accounting (gold, gamble_wins/losses/plays counters).
    * Outcome packets (`update_gold` + `console_msg`).

  VB6 anchors (confirmed against `Arena.Map.NpcInteraction` port comments;
  no VB6 source tree is vendored, so the line within Comercio.bas is pending):
    * `handle_gamble/4`   — Comercio.bas `HandleGambleGold` / `RandomNumber(1, 100) <= 10`
                            (10% win rate; npc_interaction.ex:261).
    * Timbero NPC         — shipped Apostador (NPC301) is `NpcType = 10`, NOT the
                            VB6 enum `Timbero = 7` (npc_interaction.ex:12); 10-tile range.
    * `@max_bet 5000`     — VB6 max bet cap.

  RNG: `handle_gamble/4` rolls via `Arena.Rng.uniform(100)`. This test does
  not install an `Arena.Test.Rng` strategy; with no strategy in the process
  dictionary `Arena.Rng` delegates straight to `:rand.uniform/1`, so seeding
  `:rand.seed(:exsss, _)` immediately before invoking the handler still pins
  the roll. Probed seeds:
    * `{1, 1, 1}` → first roll 8  (win,  roll <= 10)
    * `{1, 2, 3}` → first roll 27 (loss, roll  > 10)
  """
  use ExUnit.Case, async: false

  alias Arena.Data.{GameData, NpcDef}
  alias Arena.Map.NpcInteraction

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  @npc_type_timbero 10
  @max_bet 5000
  @win_seed {1, 1, 1}
  @loss_seed {1, 2, 3}

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  setup do
    :ets.insert(:arena_game_data, {{:npc, 600}, npc_def(600, @npc_type_timbero)})
    :ok
  end

  defp npc_def(id, npc_type) do
    %NpcDef{
      id: id,
      npc_type: npc_type,
      name: "Apostador",
      faccion: 0,
      body: 1,
      head: 0,
      heading: 3,
      comercia: false,
      quest_numbers: [],
      creatures: []
    }
  end

  defp with_timbero(scenario, opts \\ []) do
    with_npc(scenario, :timb1, Keyword.merge([npc_id: 600, x: 51, y: 50], opts))
  end

  defp run_gamble(scenario, char_id, amount, npc_instance_id \\ :timb1) do
    run(scenario, fn state ->
      NpcInteraction.handle_gamble(state, char_id, amount, npc_instance_id)
    end)
  end

  defp gambler(opts) do
    Keyword.merge(
      [
        gold: 100_000,
        gamble_wins: 0,
        gamble_losses: 0,
        gamble_plays: 0,
        last_clicked_npc_instance_id: :timb1,
        last_clicked_npc_type: @npc_type_timbero
      ],
      opts
    )
  end

  # ────────────────────────────────────────────────────────────────────
  # Player-state rejections
  # ────────────────────────────────────────────────────────────────────

  describe "player-state rejections" do
    test "dead player: rejected, no state change" do
      s =
        new(map_id: 1)
        |> with_player(:p, gambler(dead: true, hp: 0, max_hp: 100))
        |> with_timbero()
        |> run_gamble(:p, 100)

      e = entity(s, :p)
      assert e.gold == 100_000
      assert e.gamble_plays == 0
      assert e.gamble_wins == 0
      assert e.gamble_losses == 0
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Bet amount validation
  # ────────────────────────────────────────────────────────────────────

  describe "bet amount validation" do
    test "amount == 0: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, gambler([]))
        |> with_timbero()
        |> run_gamble(:p, 0)

      e = entity(s, :p)
      assert e.gold == 100_000
      assert e.gamble_plays == 0
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "negative amount: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, gambler([]))
        |> with_timbero()
        |> run_gamble(:p, -50)

      e = entity(s, :p)
      assert e.gold == 100_000
      assert e.gamble_plays == 0
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "amount > 5000: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p, gambler([]))
        |> with_timbero()
        |> run_gamble(:p, 5001)

      e = entity(s, :p)
      assert e.gold == 100_000
      assert e.gamble_plays == 0
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "insufficient gold: rejected, gold unchanged" do
      s =
        new(map_id: 1)
        |> with_player(:p, gambler(gold: 100))
        |> with_timbero()
        |> run_gamble(:p, 500)

      e = entity(s, :p)
      assert e.gold == 100
      assert e.gamble_plays == 0
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Timbero selection and range
  # ────────────────────────────────────────────────────────────────────

  describe "timbero selection and range" do
    test "no NPC selected: rejected" do
      s =
        new(map_id: 1)
        |> with_player(:p,
          gold: 100_000,
          gamble_wins: 0,
          gamble_losses: 0,
          gamble_plays: 0,
          last_clicked_npc_instance_id: nil,
          last_clicked_npc_type: nil
        )
        |> with_timbero()
        |> run_gamble(:p, 100)

      e = entity(s, :p)
      assert e.gold == 100_000
      assert e.gamble_plays == 0
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "selected timbero out of range (>10 tiles): rejected" do
      # max_distance=10 in handle_gamble; place timbero 12 tiles away.
      s =
        new(map_id: 1)
        |> with_player(:p, gambler([]))
        |> with_timbero(x: 62, y: 50)
        |> run_gamble(:p, 100)

      e = entity(s, :p)
      assert e.gold == 100_000
      assert e.gamble_plays == 0
      assert_effect(s, :send, to: :p, packet: :console_msg)
      refute_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "selected timbero at exactly 10 tiles: accepted" do
      :rand.seed(:exsss, @loss_seed)

      s =
        new(map_id: 1)
        |> with_player(:p, gambler([]))
        |> with_timbero(x: 60, y: 50)
        |> run_gamble(:p, 100)

      assert entity(s, :p).gamble_plays == 1
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Win path
  # ────────────────────────────────────────────────────────────────────

  describe "win path" do
    test "wins: gold increases by amount, wins+plays increment, packets emitted" do
      :rand.seed(:exsss, @win_seed)

      s =
        new(map_id: 1)
        |> with_player(:p, gambler(gold: 1_000))
        |> with_timbero()
        |> run_gamble(:p, 250)

      e = entity(s, :p)
      assert e.gold == 1_250
      assert e.gamble_wins == 1
      assert e.gamble_losses == 0
      assert e.gamble_plays == 1
      assert_effect(s, :send, to: :p, packet: :update_gold)
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Loss path
  # ────────────────────────────────────────────────────────────────────

  describe "loss path" do
    test "loses: gold decreases by amount, losses+plays increment, packets emitted" do
      :rand.seed(:exsss, @loss_seed)

      s =
        new(map_id: 1)
        |> with_player(:p, gambler(gold: 1_000))
        |> with_timbero()
        |> run_gamble(:p, 250)

      e = entity(s, :p)
      assert e.gold == 750
      assert e.gamble_wins == 0
      assert e.gamble_losses == 1
      assert e.gamble_plays == 1
      assert_effect(s, :send, to: :p, packet: :update_gold)
      assert_effect(s, :send, to: :p, packet: :console_msg)
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Boundary cases
  # ────────────────────────────────────────────────────────────────────

  describe "boundary cases" do
    test "amount == 5000 (max valid bet): accepted" do
      :rand.seed(:exsss, @loss_seed)

      s =
        new(map_id: 1)
        |> with_player(:p, gambler(gold: 10_000))
        |> with_timbero()
        |> run_gamble(:p, @max_bet)

      e = entity(s, :p)
      assert e.gold == 10_000 - @max_bet
      assert e.gamble_plays == 1
      assert e.gamble_losses == 1
      assert_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "amount == entity.gold exactly (loss): drains gold to 0" do
      :rand.seed(:exsss, @loss_seed)

      s =
        new(map_id: 1)
        |> with_player(:p, gambler(gold: 500))
        |> with_timbero()
        |> run_gamble(:p, 500)

      e = entity(s, :p)
      assert e.gold == 0
      assert e.gamble_losses == 1
      assert e.gamble_plays == 1
      assert_effect(s, :send, to: :p, packet: :update_gold)
    end

    test "amount == entity.gold exactly (win): doubles gold" do
      :rand.seed(:exsss, @win_seed)

      s =
        new(map_id: 1)
        |> with_player(:p, gambler(gold: 500))
        |> with_timbero()
        |> run_gamble(:p, 500)

      e = entity(s, :p)
      assert e.gold == 1_000
      assert e.gamble_wins == 1
      assert e.gamble_plays == 1
      assert_effect(s, :send, to: :p, packet: :update_gold)
    end
  end
end
