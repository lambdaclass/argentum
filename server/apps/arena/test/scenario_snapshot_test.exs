defmodule Arena.ScenarioSnapshotTest do
  @moduledoc """
  Smoke test for the slice-3 snapshot/diff helpers on the deterministic
  scenario harness. Exercises every public snapshot key plus
  `diff_snapshots/2`, `format_diff/1`, and `assert_state_equal/2,3`.
  """

  use ExUnit.Case, async: true

  import Arena.Test.Scenario

  alias Arena.Test.Scenario
  alias Arena.Test.Scenario.Snapshot

  setup_all do
    case Arena.Data.GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  # ──────────────────────────────────────────────────────────────────────
  # Per-key snapshots
  # ──────────────────────────────────────────────────────────────────────

  describe "snapshot(:player, char_id)" do
    test "projects the load-bearing subset and drops ephemeral cooldowns" do
      s =
        new()
        |> with_player(:hero,
            x: 50, y: 60, hp: 75, max_hp: 200, mana: 30, max_mana: 90,
            gold: 1234, dead: false, paralyzed: false, faction: :armada)

      snap = snapshot(s, :player, :hero)

      assert snap.x == 50
      assert snap.y == 60
      assert snap.hp == 75
      assert snap.max_hp == 200
      assert snap.mana == 30
      assert snap.gold == 1234
      assert snap.faction == :armada
      assert snap.dead == false

      # Cooldowns (next_*_at, last_*_at) MUST NOT appear — they're
      # monotonic, change every run, and would poison diffs.
      refute Map.has_key?(snap, :next_attack_at)
      refute Map.has_key?(snap, :last_attacked_at)
      refute Map.has_key?(snap, :last_step_at)
    end

    test "returns nil for an unknown player" do
      s = new()
      assert snapshot(s, :player, :ghost) == nil
    end
  end

  describe "snapshot(:inventory, char_id)" do
    test "lists non-nil slots in order with slot indices preserved" do
      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{item_id: 9_500, amount: 5, equipped: false})
        |> List.replace_at(3, %{item_id: 7_001, amount: 1, equipped: true})

      s =
        new()
        |> with_player(:hero, inventory: inv)

      assert snapshot(s, :inventory, :hero) == [
               %{slot: 0, item_id: 9_500, amount: 5, equipped: false},
               %{slot: 3, item_id: 7_001, amount: 1, equipped: true}
             ]
    end

    test "empty inventory yields []" do
      s = new() |> with_player(:hero)
      assert snapshot(s, :inventory, :hero) == []
    end
  end

  describe "snapshot(:buffs, char_id)" do
    test "normalises and sorts by type" do
      now = 1_000_000

      buffs = [
        %{type: :poisoned, expires_at: now + 5_000, next_tick: now + 1_000},
        %{type: :paralyzed, expires_at: now + 3_000},
        %{type: :blind, expires_at: now + 4_000}
      ]

      s = new() |> with_player(:hero, buffs: buffs)

      result = snapshot(s, :buffs, :hero)

      # Sorted alphabetically by type (:blind, :paralyzed, :poisoned).
      assert result == [
               %{type: :blind, expires_at: now + 4_000},
               %{type: :paralyzed, expires_at: now + 3_000},
               %{type: :poisoned, expires_at: now + 5_000}
             ]

      # `:next_tick` was dropped — only `:type` / `:expires_at` (and
      # `:value` when present) are load-bearing.
      Enum.each(result, fn buff ->
        refute Map.has_key?(buff, :next_tick)
      end)
    end
  end

  describe "snapshot(:visible, char_id)" do
    test "returns players, npcs, and ground items within the AoI box, sorted" do
      s =
        new()
        |> with_player(:viewer, x: 50, y: 50)
        # Inside AoI box (rx=11, ry=9 by default)
        |> with_player(:near_friend, x: 55, y: 52, char_index: 11)
        # Outside AoI box (dx=20 > rx=11)
        |> with_player(:far_friend, x: 70, y: 50, char_index: 12)
        |> with_npc(:nearby_npc, x: 49, y: 51, char_index: 101)
        |> with_npc(:far_npc, x: 80, y: 80, char_index: 102)

      # Drop a ground item nearby. ground_items is keyed by {x, y}.
      s = update_state(s, fn st ->
        %{st | ground_items: Map.put(st.ground_items, {52, 50}, %{item_id: 100, amount: 1})}
      end)

      result = snapshot(s, :visible, :viewer)

      assert {:player, :near_friend} in result
      refute {:player, :far_friend} in result
      assert {:npc, :nearby_npc} in result
      refute {:npc, :far_npc} in result
      assert {:ground_item, {52, 50}} in result

      # Viewer should NOT see themselves.
      refute {:player, :viewer} in result

      # Stable order: re-running on the same scenario yields the same list.
      assert snapshot(s, :visible, :viewer) == result
    end
  end

  describe "snapshot(:effects)" do
    test "summarises envelope payloads to {class, packet_id, payload_size}" do
      payload = <<42::little-signed-integer-16, 0x01, 0x02, 0x03>>

      effect =
        {:send, :hero,
         %{class: :critical, payload: payload, bytes: byte_size(payload), coalesce_key: nil}}

      s = %{new() | effects: [effect]}

      [normalised] = snapshot(s, :effects)
      assert {:send, :hero, summary} = normalised
      assert summary.class == :critical
      assert summary.packet_id == 42
      assert summary.payload_size == byte_size(payload)
    end

    test "strips entity blobs from envelope-free effect kinds" do
      entity = %{char_id: :hero, x: 50, y: 50}

      s = %{
        new()
        | effects: [
            {:broadcast_character_change, entity},
            {:hide_from_non_gm, entity},
            {:reveal_to_non_gm, entity},
            {:transfer, :hero, 5, 60, 70, entity}
          ]
      }

      assert snapshot(s, :effects) == [
               {:broadcast_character_change, :hero},
               {:hide_from_non_gm, :hero},
               {:reveal_to_non_gm, :hero},
               {:transfer, :hero, 5, 60, 70}
             ]
    end

    test "preserves emission order" do
      env1 =
        %{class: :critical, payload: <<1::little-signed-integer-16>>, bytes: 2, coalesce_key: nil}

      env2 =
        %{class: :critical, payload: <<2::little-signed-integer-16>>, bytes: 2, coalesce_key: nil}

      s = %{new() | effects: [{:send, :a, env1}, {:send, :b, env2}]}

      assert [{:send, :a, %{packet_id: 1}}, {:send, :b, %{packet_id: 2}}] =
               snapshot(s, :effects)
    end
  end

  # ──────────────────────────────────────────────────────────────────────
  # diff / format / assert
  # ──────────────────────────────────────────────────────────────────────

  describe "diff_snapshots/2" do
    test "identical snapshot diffs against itself as :ok" do
      s = new() |> with_player(:hero, hp: 50)
      snap = snapshot(s, :player, :hero)
      assert diff_snapshots(snap, snap) == :ok
    end

    test "surfaces the first map-key divergence" do
      a = %{hp: 50, mana: 30}
      b = %{hp: 60, mana: 30}

      assert {:divergence, [:hp], 50, 60} = diff_snapshots(a, b)
    end

    test "surfaces the first list-index divergence" do
      a = [%{slot: 0, item_id: 1, amount: 1}, %{slot: 1, item_id: 2, amount: 1}]
      b = [%{slot: 0, item_id: 1, amount: 1}, %{slot: 1, item_id: 2, amount: 5}]

      assert {:divergence, [1, :amount], 1, 5} = diff_snapshots(a, b)
    end

    test "missing key on the expected side surfaces with :__missing__" do
      assert {:divergence, [:extra], "x", :__missing__} =
               diff_snapshots(%{extra: "x"}, %{})
    end

    test "missing key on the actual side surfaces with :__missing__" do
      assert {:divergence, [:extra], :__missing__, "y"} =
               diff_snapshots(%{}, %{extra: "y"})
    end

    test "length mismatch surfaces at the first missing index" do
      assert {:divergence, [1], :__missing__, 2} =
               diff_snapshots([1], [1, 2])

      assert {:divergence, [1], 2, :__missing__} =
               diff_snapshots([1, 2], [1])
    end

    test "tuple divergence surfaces at the offending index" do
      assert {:divergence, [1], :a, :b} =
               diff_snapshots({:send, :a}, {:send, :b})
    end

    test "diffs full snapshots from the same scenario as :ok" do
      s =
        new()
        |> with_player(:hero, hp: 50, gold: 100)

      assert diff_snapshots(snapshot(s, :player, :hero), snapshot(s, :player, :hero)) == :ok
    end

    test "diffs a snapshot against a mutated copy surfacing the right path" do
      s = new() |> with_player(:hero, hp: 50)
      base = snapshot(s, :player, :hero)
      mutated = %{base | hp: 1}

      assert {:divergence, [:hp], 50, 1} = diff_snapshots(base, mutated)
    end
  end

  describe "format_diff/1" do
    test ":ok yields the empty string" do
      assert format_diff(:ok) == ""
    end

    test "divergence renders the path and both values" do
      msg = format_diff({:divergence, [:player, :hp], 50, 1})
      assert msg =~ "snapshot divergence at :player -> :hp"
      assert msg =~ "actual=50"
      assert msg =~ "expected=1"
    end

    test "root-level divergence renders <root>" do
      msg = format_diff({:divergence, [], 1, 2})
      assert msg =~ "<root>"
    end
  end

  describe "assert_state_equal/2,3" do
    test "passes when fresh snapshots match the expected literals" do
      s =
        new()
        |> with_player(:hero, hp: 50, max_hp: 100, gold: 7,
                              inventory: List.replace_at(List.duplicate(nil, 24), 0,
                                %{item_id: 9_500, amount: 5, equipped: false}))

      result =
        Scenario.assert_state_equal(s, %{
          player: %{hp: 50, max_hp: 100, gold: 7},
          inventory: [%{slot: 0, item_id: 9_500, amount: 5, equipped: false}]
        }, :hero)

      # Returns the scenario for pipe-friendly chaining.
      assert %Scenario{} = result
    end

    test "raises an AssertionError with a readable message on divergence" do
      s = new() |> with_player(:hero, hp: 50)

      err =
        assert_raise ExUnit.AssertionError, fn ->
          Scenario.assert_state_equal(s, %{player: %{hp: 1}}, :hero)
        end

      assert err.message =~ "Scenario.assert_state_equal failed"
      assert err.message =~ ":player"
      assert err.message =~ ":hp"
      assert err.message =~ "actual:"
      assert err.message =~ "expected:"
    end

    test "works for the :effects key (no char_id needed)" do
      payload = <<42::little-signed-integer-16, 1, 2, 3>>

      effect =
        {:send, :hero,
         %{class: :critical, payload: payload, bytes: byte_size(payload), coalesce_key: nil}}

      s = %{new() | effects: [effect]}

      Scenario.assert_state_equal(s, %{
        effects: [
          {:send, :hero,
           %{class: :critical, packet_id: 42, payload_size: byte_size(payload)}}
        ]
      })
    end
  end

  describe "Snapshot module is reachable directly" do
    test "Arena.Test.Scenario.Snapshot.take/3 mirrors snapshot/2,3" do
      s = new() |> with_player(:hero, hp: 50)
      assert Snapshot.take(s, :player, :hero) == snapshot(s, :player, :hero)
      assert Snapshot.take(s, :effects, nil) == snapshot(s, :effects)
    end
  end
end
