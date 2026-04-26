defmodule Arena.Map.SocialGoldE2ETest do
  @moduledoc """
  End-to-end tests for the Social gold flows. Pins the Social
  effects-contract migration (Sub D: modify_gold, deduct_gold).

  - `modify_gold` is a cast: dispatched through `Effects.run_handler/2`.
  - `deduct_gold` is a call: dispatched through
    `Effects.run_handler_call_reply/2`. The handler returns
    `{:ok, state, reply, effects}` so the MapServer surfaces the
    `{:ok, new_gold}` / `{:error, reason}` reply unchanged.

  Outbound packets flow through `AoSession.Egress.enqueue/2` and arrive
  in the test pid mailbox as `{:egress, %AoSession.Outbound{...}}`
  envelopes — never via the legacy `{:send_raw, _}` shim.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.MapServer
  alias Arena.Data.GameData
  alias AoEntities.PlayerEntity

  import Arena.Test.MapStateFactory

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    drain()
    :ok
  end

  defp drain do
    receive do
      _ -> drain()
    after
      10 -> :ok
    end
  end

  defp make_player(overrides) do
    defaults = %{
      char_id: :player,
      name: "Tester",
      account_id: "acc_test",
      x: 50,
      y: 50,
      char_index: 1,
      map_id: 1,
      hp: 100,
      max_hp: 100,
      gold: 1_000,
      level: 25,
      class: :warrior,
      race: :human,
      gender: :male,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      skills: %{magic: 50},
      inventory: List.duplicate(nil, 24),
      faction: :none,
      dead: false
    }

    struct!(PlayerEntity, Map.merge(defaults, overrides))
  end

  defp state_with(player, opts \\ []) do
    map_state(
      players: %{player.char_id => player},
      sessions: Keyword.get(opts, :sessions, %{player.char_id => self()}),
      occupancy: Keyword.get(opts, :occupancy, %{})
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:modify_gold, ...})
  # ════════════════════════════════════════════════════════════════════════

  describe "modify_gold via MapServer cast" do
    test "positive amount: gold added, update_gold envelope fanned" do
      state = state_with(make_player(%{gold: 100}))
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:modify_gold, :player, 50}, state)

      assert new_state.players[:player].gold == 150

      assert_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}
      refute_receive {:send_raw, _}, 50
    end

    test "negative amount that does not underflow: gold reduced" do
      state = state_with(make_player(%{gold: 100}))
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:modify_gold, :player, -30}, state)

      assert new_state.players[:player].gold == 70

      assert_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}
    end

    test "negative amount that underflows: gold clamped to 0" do
      state = state_with(make_player(%{gold: 50}))

      assert {:noreply, new_state} =
               MapServer.handle_cast({:modify_gold, :player, -1_000}, state)

      assert new_state.players[:player].gold == 0
    end

    test "dead player: silent no-op, no envelopes" do
      state = state_with(make_player(%{dead: true, gold: 100}))

      assert {:noreply, new_state} =
               MapServer.handle_cast({:modify_gold, :player, 50}, state)

      assert new_state.players[:player].gold == 100
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:modify_gold, :ghost, 50}, state)

      refute_receive {:egress, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:deduct_gold, _, _}) — uses run_handler_call_reply/2
  # ════════════════════════════════════════════════════════════════════════

  describe "deduct_gold via MapServer call" do
    test "sufficient gold: reply {:ok, new_gold}, gold decreased, update_gold envelope" do
      state = state_with(make_player(%{gold: 500}))
      gold_id = AoProtocol.PacketIds.Server.update_gold()

      assert {:reply, {:ok, 300}, new_state} =
               MapServer.handle_call({:deduct_gold, :player, 200}, :from, state)

      assert new_state.players[:player].gold == 300

      assert_receive {:egress, %{payload: <<^gold_id::little-signed-integer-16, _::binary>>}}
      refute_receive {:send_raw, _}, 50
    end

    test "insufficient gold: reply {:error, :not_enough_gold}, no envelopes, state unchanged" do
      state = state_with(make_player(%{gold: 100}))

      assert {:reply, {:error, :not_enough_gold}, new_state} =
               MapServer.handle_call({:deduct_gold, :player, 200}, :from, state)

      assert new_state.players[:player].gold == 100
      refute_receive {:egress, _}, 50
    end

    test "dead player: reply {:error, :dead}, no envelopes" do
      state = state_with(make_player(%{dead: true, gold: 1_000}))

      assert {:reply, {:error, :dead}, new_state} =
               MapServer.handle_call({:deduct_gold, :player, 100}, :from, state)

      assert new_state.players[:player].gold == 1_000
      refute_receive {:egress, _}, 50
    end

    test "missing player: reply {:error, :not_on_map}" do
      state = map_state(players: %{}, sessions: %{})

      assert {:reply, {:error, :not_on_map}, _} =
               MapServer.handle_call({:deduct_gold, :ghost, 100}, :from, state)

      refute_receive {:egress, _}, 50
    end

    test "zero amount: reply {:error, :invalid_amount}, no envelopes" do
      state = state_with(make_player(%{gold: 100}))

      assert {:reply, {:error, :invalid_amount}, new_state} =
               MapServer.handle_call({:deduct_gold, :player, 0}, :from, state)

      assert new_state.players[:player].gold == 100
      refute_receive {:egress, _}, 50
    end

    test "negative amount: reply {:error, :invalid_amount}" do
      state = state_with(make_player(%{gold: 100}))

      assert {:reply, {:error, :invalid_amount}, _} =
               MapServer.handle_call({:deduct_gold, :player, -50}, :from, state)

      refute_receive {:egress, _}, 50
    end
  end
end
