defmodule Arena.MidTransferDisconnectTest do
  @moduledoc """
  Tests for mid-transfer disconnect behavior.

  Verifies that the MapServer monitor system correctly cleans up players
  when sessions die at various points during map transfers:

  1. Session dies after enter(dest) but before leave(source) — player on BOTH maps
  2. Session dies after a completed transfer — player only on dest map
  3. Transfer to a non-existent/unavailable map — player stays on source
  """

  use ExUnit.Case

  alias Arena.Map.MapServer
  alias AoEntities.PlayerEntity

  @map_a 1
  @map_b 2

  setup_all do
    Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(Arena.MapRegistry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Arena.MapRegistry)
    end

    unless Process.whereis(Arena.PubSub) do
      {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end

    unless Process.whereis(Arena.Data.GameData) do
      {:ok, _} = Arena.Data.GameData.start_link([])
    end

    unless Process.whereis(Arena.Map.MapSupervisor) do
      {:ok, _} = Arena.Map.MapSupervisor.start_link([])
    end

    ensure_map_started(@map_a)
    ensure_map_started(@map_b)

    :ok
  end

  # ---- Helpers ----

  defp unique_id, do: System.unique_integer([:positive]) + 200_000

  defp make_entity(char_id, name) do
    %PlayerEntity{
      char_id: char_id,
      name: name,
      account_id: unique_id(),
      x: 50,
      y: 50,
      hp: 100,
      max_hp: 100,
      mana: 100,
      max_mana: 100,
      stamina: 100,
      max_stamina: 100,
      hunger: 100,
      thirst: 100,
      level: 1,
      gold: 100,
      class: :warrior,
      race: :humano,
      gender: :male,
      home_city: :ullathorpe,
      map_id: @map_a
    }
  end

  defp ensure_map_started(map_id) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(map_id)
    end

    wait_map_ready(map_id, 50)
  end

  defp wait_map_ready(_map_id, 0), do: :ok

  defp wait_map_ready(map_id, retries) do
    if MapServer.ready?(map_id) do
      :ok
    else
      Process.sleep(100)
      wait_map_ready(map_id, retries - 1)
    end
  rescue
    _ ->
      Process.sleep(100)
      wait_map_ready(map_id, retries - 1)
  catch
    :exit, _ ->
      Process.sleep(100)
      wait_map_ready(map_id, retries - 1)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
  end

  # Enter a player on a map from a spawned proxy process.
  # Returns {:ok, proxy_pid} where proxy_pid is the process MapServer monitors.
  # The proxy stays alive until you send it :die or kill it.
  defp enter_from_proxy(map_id, entity, position) do
    parent = self()
    ref = make_ref()

    proxy =
      spawn(fn ->
        result = MapServer.enter(map_id, entity, position: position)
        send(parent, {ref, result})

        receive do
          :die -> :ok
        end
      end)

    receive do
      {^ref, {:ok, _idx, _players, _weather} = result} ->
        {:ok, proxy, result}

      {^ref, {:error, _reason} = err} ->
        {:error, err}
    after
      5_000 ->
        Process.exit(proxy, :kill)
        {:error, :timeout}
    end
  end

  # ---- Tests ----

  describe "scenario A: session dies after enter(dest) but before leave(source)" do
    test "player is cleaned up from BOTH maps via :DOWN monitors" do
      char_id = unique_id()
      entity = make_entity(char_id, "MidTransferCrash_#{char_id}")

      # Step 1: Enter map A from a proxy process (simulates the session)
      {:ok, proxy, {:ok, _idx, _players, _weather}} =
        enter_from_proxy(@map_a, entity, {50, 50})

      # Verify player is on map A
      assert {:ok, _} = MapServer.snapshot_entity(@map_a, char_id)

      # Step 2: Enter map B from the SAME proxy process.
      # In the real transfer flow, the session process calls enter(dest_map)
      # which means the same caller_pid is used — MapServer monitors it.
      # We need the proxy to do the second enter too.
      parent = self()
      ref2 = make_ref()

      # Ask the proxy to enter map B (we replace the proxy's :die handler with work)
      # Actually, we can't send work to the proxy after it's waiting on :die.
      # So instead, we kill the proxy and use a new approach:
      # We'll use a single proxy that does both enters.
      Process.exit(proxy, :kill)
      Process.sleep(200)

      # Use a fresh proxy that enters BOTH maps before waiting
      proxy2 =
        spawn(fn ->
          result_a = MapServer.enter(@map_a, entity, position: {50, 50})
          send(parent, {ref2, :entered_a, result_a})

          dest_entity = %{entity | x: 30, y: 30, map_id: @map_b}
          result_b = MapServer.enter(@map_b, dest_entity, position: {30, 30})
          send(parent, {ref2, :entered_b, result_b})

          # Now wait — simulating the session being alive but hasn't called leave yet
          receive do
            :die -> :ok
          end
        end)

      # Wait for both enters to complete
      assert_receive {^ref2, :entered_a, {:ok, _, _, _}}, 5_000
      assert_receive {^ref2, :entered_b, {:ok, _, _, _}}, 5_000

      # Verify player is on BOTH maps (the dangerous mid-transfer state)
      assert {:ok, _} = MapServer.snapshot_entity(@map_a, char_id)
      assert {:ok, _} = MapServer.snapshot_entity(@map_b, char_id)

      # Step 3: Kill the session (simulate crash before leave(source) is called)
      Process.exit(proxy2, :kill)

      # Give the :DOWN handlers time to fire on both MapServers
      Process.sleep(500)

      # Step 4: Verify player is cleaned up from BOTH maps
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_a, char_id),
             "Player should be cleaned up from source map (A) via :DOWN handler"

      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_b, char_id),
             "Player should be cleaned up from destination map (B) via :DOWN handler"
    end
  end

  describe "scenario B: session dies after completed transfer" do
    test "player is cleaned up from dest map only, not lingering on source" do
      char_id = unique_id()
      entity = make_entity(char_id, "PostTransferCrash_#{char_id}")
      parent = self()
      ref = make_ref()

      # Use a proxy that does the full transfer flow: enter A, enter B, leave A
      proxy =
        spawn(fn ->
          # Enter source map A
          {:ok, _, _, _} = MapServer.enter(@map_a, entity, position: {50, 50})
          send(parent, {ref, :entered_a})

          # Enter destination map B
          dest_entity = %{entity | x: 30, y: 30, map_id: @map_b}
          {:ok, _, _, _} = MapServer.enter(@map_b, dest_entity, position: {30, 30})
          send(parent, {ref, :entered_b})

          # Complete the transfer: leave source map A
          MapServer.leave(@map_a, char_id)
          send(parent, {ref, :left_a})

          # Session stays alive until killed
          receive do
            :die -> :ok
          end
        end)

      assert_receive {^ref, :entered_a}, 5_000
      assert_receive {^ref, :entered_b}, 5_000
      assert_receive {^ref, :left_a}, 5_000

      # After completed transfer: player should be on B, not on A
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_a, char_id),
             "Player should have been removed from source map A by leave()"

      assert {:ok, _} = MapServer.snapshot_entity(@map_b, char_id),
             "Player should still be on destination map B"

      # Now kill the session (simulate crash after transfer completed)
      Process.exit(proxy, :kill)
      Process.sleep(500)

      # Player should be cleaned from map B via :DOWN
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_b, char_id),
             "Player should be cleaned from dest map B via :DOWN handler"

      # And still not on map A (no ghost entity)
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@map_a, char_id),
             "Player should not reappear on source map A"
    end
  end

  describe "scenario C: destination map unavailable during transfer" do
    test "player stays on source map when dest map does not exist" do
      char_id = unique_id()
      entity = make_entity(char_id, "FailedTransfer_#{char_id}")

      # Enter source map normally (from test process)
      {:ok, _idx, _players, _weather} = MapServer.enter(@map_a, entity, position: {50, 50})
      flush_mailbox()

      # Verify player is on source map
      assert {:ok, _} = MapServer.snapshot_entity(@map_a, char_id)

      # Try to enter a non-existent map (map 99999)
      nonexistent_map = 99999
      dest_entity = %{entity | x: 30, y: 30, map_id: nonexistent_map}

      result =
        try do
          MapServer.enter(nonexistent_map, dest_entity, position: {30, 30})
        catch
          :exit, _ -> {:error, :map_not_running}
        end

      # The enter should fail (either {:error, _} or exit)
      assert match?({:error, _}, result),
             "Entering a non-existent map should return an error, got: #{inspect(result)}"

      # Player should still be on the source map, unaffected
      assert {:ok, snapshot} = MapServer.snapshot_entity(@map_a, char_id),
             "Player should still be on source map A after failed transfer"

      assert snapshot.char_id == char_id
      assert snapshot.gold == 100

      # Clean up
      MapServer.leave(@map_a, char_id)
    end

    test "player can continue to interact on source map after failed transfer" do
      char_id = unique_id()
      entity = make_entity(char_id, "StillActive_#{char_id}")

      # Enter source map
      {:ok, _idx, _players, _weather} = MapServer.enter(@map_a, entity, position: {50, 50})
      flush_mailbox()

      # Fail a transfer to non-existent map
      nonexistent_map = 99998

      try do
        MapServer.enter(nonexistent_map, entity, position: {30, 30})
      catch
        :exit, _ -> :ok
      end

      # Verify player can still interact: move on source map
      # Try multiple directions to find a walkable one
      move_result =
        Enum.find_value([:south, :north, :east, :west], fn dir ->
          case MapServer.move_character(@map_a, char_id, dir) do
            {:ok, _pos} -> dir
            {:error, _} -> nil
          end
        end)

      assert move_result != nil,
             "Player should still be able to move on source map after failed transfer"

      # Clean up
      MapServer.leave(@map_a, char_id)
    end
  end
end
