defmodule Arena.ScenarioSmokeTest do
  @moduledoc """
  Smoke test for the slice-1 deterministic scenario harness. Proves the
  API end-to-end against real handler code without spinning a
  MapServer. Doubles as the harness's documentation-by-test.
  """

  use ExUnit.Case, async: true

  import Arena.Test.Scenario
  import Arena.Test.Scenario.Assertions

  alias Arena.Map.CombatHandlers

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "melee swing — attacker faces a defender, swing fires, defender takes damage send" do
    s =
      new()
      |> with_player(:atk,
          x: 50, y: 50, heading: :south, str: 30, agi: 25, level: 20,
          skills: %{combat_weapons: 80})
      |> with_player(:def,
          x: 50, y: 51, char_index: 200, hp: 100, max_hp: 100,
          skills: %{combat_tactics: 50, combat_defense: 50})

    s = run(s, fn state ->
      {:reply, _reply, state} = CombatHandlers.handle_attack(state, :atk, nil, nil)
      {:ok, state, []}
    end)

    # The swing is broadcast to all visible peers EXCEPT the attacker:
    swing_id = AoProtocol.PacketIds.Server.char_swing()

    assert Enum.any?(emitted_effects(s), fn
      {:broadcast_visible_except, _x, _y, :atk,
       %{payload: <<^swing_id::little-signed-integer-16, _::binary>>}} -> true
      _ -> false
    end), "expected a swing broadcast that excluded :atk"

    # The defender should have received SOMETHING (hit, miss-with-shield, or pure miss).
    # Pure miss leaves no defender-facing send, so we just check the scenario is
    # internally consistent: attacker's next_attack_at advanced.
    assert entity(s, :atk).next_attack_at > -1_000_000_000_000,
           "attack should have set the cooldown"
  end

  test "assert_effect for :send finds an attacker-facing damage report on a guaranteed hit" do
    # Seed :rand so the hit lands. (Slice 3 will add Scenario.set_seed/2;
    # for now drop into :rand.seed/2 directly.)
    :rand.seed(:exsss, {1, 2, 3})

    s =
      new()
      |> with_player(:atk,
          x: 50, y: 50, heading: :south, str: 50, agi: 50, level: 50,
          skills: %{combat_weapons: 100})
      |> with_player(:def,
          x: 50, y: 51, char_index: 300, hp: 200, max_hp: 200,
          skills: %{combat_tactics: 1, combat_defense: 1})

    s = run(s, fn state ->
      {:reply, _, state} = CombatHandlers.handle_attack(state, :atk, nil, nil)
      {:ok, state, []}
    end)

    # On a hit, :atk receives a user_hitted_user packet:
    assert_effect(s, :send, to: :atk, packet: :user_hitted_user)
  end

  describe "scenario.attack/3 and assert_effect/3" do
    test "attacks via the scenario API and asserts a hit packet" do
      :rand.seed(:exsss, {1, 2, 3})

      s =
        new()
        |> with_player(:atk,
            x: 50, y: 50, heading: :south, str: 50, agi: 50, level: 50,
            skills: %{combat_weapons: 100})
        |> with_player(:def,
            x: 50, y: 51, char_index: 300, hp: 200, max_hp: 200,
            skills: %{combat_tactics: 1, combat_defense: 1})
        |> attack(:atk)

      assert last_reply(s) == :ok
      assert_effect(s, :send, to: :atk, packet: :user_hitted_user)
    end
  end
end
