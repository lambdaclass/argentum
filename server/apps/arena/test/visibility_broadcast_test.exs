defmodule Arena.VisibilityBroadcastTest do
  @moduledoc "Tests for Visibility.broadcast_to_map and broadcast recipient selection."
  use ExUnit.Case, async: true

  import Arena.Test.MapStateFactory

  alias Arena.Map.Visibility

  defp start_receiver(label) do
    parent = self()

    spawn_link(fn ->
      receiver_loop(parent, label)
    end)
  end

  defp receiver_loop(parent, label) do
    receive do
      message ->
        send(parent, {:receiver, label, message})
        receiver_loop(parent, label)
    end
  end

  describe "broadcast_to_map/2" do
    test "sends to every mapped session exactly once regardless of position" do
      one = start_receiver(:one)
      two = start_receiver(:two)
      three = start_receiver(:three)

      state =
        map_state(
          sessions: %{1 => one, 2 => two, 3 => three},
          visibility_mode: :aoi_grid,
          grid: %{}
        )

      count = Visibility.broadcast_to_map(state, fn pid ->
        send(pid, :got_broadcast)
      end)

      assert length(count) == 3
      assert_receive {:receiver, :one, :got_broadcast}
      assert_receive {:receiver, :two, :got_broadcast}
      assert_receive {:receiver, :three, :got_broadcast}
      refute_receive {:receiver, _, :got_broadcast}, 50
    end

    test "works with empty sessions" do
      state = map_state(sessions: %{})

      count = Visibility.broadcast_to_map(state, fn pid ->
        send(pid, :got_broadcast)
      end)

      assert count == []
      refute_receive {:receiver, _, _}, 50
    end
  end

  describe "broadcast_visible_all vs broadcast_to_map" do
    test "broadcast_to_map ignores AoI while broadcast_visible_all reaches only the visible player" do
      near = start_receiver(:near)
      far = start_receiver(:far)

      state =
        map_state(
          players: %{
            1 => %{char_id: 1, x: 1, y: 1, char_index: 1},
            2 => %{char_id: 2, x: 99, y: 99, char_index: 2}
          },
          sessions: %{1 => near, 2 => far},
          visibility_mode: :aoi_scan
        )

      map_results = Visibility.broadcast_to_map(state, fn pid ->
        send(pid, :map_msg)
      end)

      assert length(map_results) == 2
      assert_receive {:receiver, :near, :map_msg}
      assert_receive {:receiver, :far, :map_msg}
      refute_receive {:receiver, _, :map_msg}, 50

      vis_count = Visibility.broadcast_visible_all(state, 1, 1, fn pid ->
        send(pid, :vis_msg)
      end)

      assert vis_count == 1
      assert_receive {:receiver, :near, :vis_msg}
      refute_receive {:receiver, :far, :vis_msg}, 50
    end
  end

  describe "adversarial visibility" do
    test "broadcast_to_map handles the default empty sessions map gracefully" do
      state = map_state(sessions: %{})
      results = Visibility.broadcast_to_map(state, fn _pid -> :ok end)
      assert results == []
    end

    test "broadcast_visible_all with no players produces no recipients" do
      state =
        map_state(
          players: %{},
          sessions: %{},
          visibility_mode: :aoi_scan
        )

      count = Visibility.broadcast_visible_all(state, 50, 50, fn _pid -> :ok end)
      assert count == 0
    end
  end
end
