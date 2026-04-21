defmodule Arena.CombatLifecycleTest do
  @moduledoc """
  Integration tests for the full combat lifecycle:
  enter → fight → die → verify death state → snapshot verification.

  Tests run against a real MapServer instance to validate that combat,
  death cleanup, and state transitions work end-to-end.
  Uses GM /KILL via chat to trigger death deterministically.
  """
  use ExUnit.Case

  alias Arena.Map.MapServer
  alias AoEntities.PlayerEntity

  @test_map_id 1

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

    :ok
  end

  setup do
    case Registry.lookup(Arena.MapRegistry, @test_map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(@test_map_id)
    end

    :ok
  end

  defp make_entity(char_id, name, overrides) do
    Map.merge(
      %PlayerEntity{
        char_id: char_id,
        name: name,
        account_id: "account_#{char_id}",
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
        level: 10,
        xp: 5000,
        gold: 500,
        class: :warrior,
        race: :human,
        gender: :male,
        skills: %{combat: 80, tactics: 50, weapons: 60},
        min_hit: 5,
        max_hit: 15
      },
      overrides
    )
  end

  defp enter_player(char_id, name, overrides \\ %{}) do
    entity = make_entity(char_id, name, overrides)
    {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity, session_pid: self())

    on_exit(fn ->
      try do
        MapServer.leave(@test_map_id, char_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    entity
  end

  defp collect_messages(timeout) do
    collect_messages_acc(timeout, [])
  end

  defp collect_messages_acc(timeout, acc) do
    receive do
      {:send_raw, binary} -> collect_messages_acc(timeout, [binary | acc])
      {:send_packet, _} = msg -> collect_messages_acc(timeout, [msg | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      50 -> :ok
    end
  end

  defp packet_id(<<id::little-signed-integer-16, _rest::binary>>), do: id
  defp packet_id(_), do: nil

  # Kill a player using GM /KILL command via chat.
  # The GM player must have gm: true.
  defp gm_kill_player(gm_char_id, target_name) do
    MapServer.chat(@test_map_id, gm_char_id, "/KILL #{target_name}")
    # chat is a cast, give it time to process
    Process.sleep(150)
  end

  # ---- Tests ----

  describe "player enters map" do
    test "snapshot shows alive player with correct stats" do
      enter_player(30001, "EnterTest", %{hp: 75, max_hp: 100})
      flush_mailbox()

      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 30001)
      assert entity.hp == 75
      assert entity.max_hp == 100
      refute entity.dead
      assert entity.name == "EnterTest"
    end

    test "snapshot returns error for non-existent player" do
      assert {:error, :not_on_map} = MapServer.snapshot_entity(@test_map_id, 99999)
    end
  end

  describe "melee attack" do
    test "attack sends packets to nearby observer" do
      _attacker = enter_player(30010, "Attacker", %{x: 50, y: 50, heading: :south})
      _observer = enter_player(30011, "Observer", %{x: 51, y: 50})
      flush_mailbox()

      # Attack facing tile — no target there, but swing animation is broadcast to
      # other players on the map (the attacker itself is excluded from the broadcast).
      MapServer.attack(@test_map_id, 30010)
      msgs = collect_messages(300)

      # The observer (whose session_pid is also self()) should receive the swing packet
      assert length(msgs) > 0
    end
  end

  describe "GM kill → death state" do
    test "GM /KILL sets dead flag and clears all status" do
      # GM player
      _gm = enter_player(30100, "GMPlayer", %{gm: true, x: 48, y: 48})
      # Target player with status effects
      _target =
        enter_player(30101, "VictimPlayer", %{
          x: 50,
          y: 50,
          poisoned: true,
          invisible: true,
          paralyzed: true,
          meditating: true,
          resting: true,
          buffs: [%{type: :str, expires_at: System.monotonic_time(:millisecond) + 5000, value: 10}],
          commerce_npc_id: 42,
          trade_partner_id: 99
        })

      flush_mailbox()

      # Verify pre-death state
      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 30101)
      assert entity.poisoned
      refute entity.dead

      # GM kills target
      gm_kill_player(30100, "VictimPlayer")

      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 30101)
      assert entity.dead
      assert entity.hp == 0
      assert entity.stamina == 0
      refute entity.poisoned
      refute entity.invisible
      refute entity.paralyzed
      refute entity.meditating
      refute entity.resting
      assert entity.buffs == []
      assert entity.commerce_npc_id == nil
      assert entity.trade_partner_id == nil
    end

    test "death increments death counter" do
      _gm = enter_player(30102, "GM2", %{gm: true, x: 48, y: 48})
      _target = enter_player(30103, "Counter", %{x: 50, y: 50, deaths: 5})
      flush_mailbox()

      gm_kill_player(30102, "Counter")

      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 30103)
      assert entity.dead
      assert entity.deaths == 6
    end

    test "death unequips all items" do
      _gm = enter_player(30104, "GM3", %{gm: true, x: 48, y: 48})

      _target =
        enter_player(30105, "Unequipper", %{
          x: 50,
          y: 50,
          inventory:
            [
              %{item_id: 100, amount: 1, equipped: true},
              %{item_id: 200, amount: 1, equipped: true},
              %{item_id: 300, amount: 5, equipped: false}
            ] ++ List.duplicate(nil, 21),
          equipment: %{weapon: 100, armor: 200, shield: nil, helmet: nil, ring: nil}
        })

      flush_mailbox()

      gm_kill_player(30104, "Unequipper")

      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 30105)
      assert entity.dead

      # All equipment slots should be nil
      assert entity.equipment.weapon == nil
      assert entity.equipment.armor == nil

      # All inventory items should have equipped: false
      entity.inventory
      |> Enum.reject(&is_nil/1)
      |> Enum.each(fn item -> refute item.equipped end)
    end

    test "death sends packets to victim" do
      _gm = enter_player(30106, "GM4", %{gm: true, x: 48, y: 48})
      _target = enter_player(30107, "PacketVictim", %{x: 50, y: 50})
      flush_mailbox()

      gm_kill_player(30106, "PacketVictim")
      msgs = collect_messages(300)

      # Should receive multiple packets (character_change for ghost, console messages, etc.)
      binary_msgs = Enum.filter(msgs, &is_binary/1)
      ids = Enum.map(binary_msgs, &packet_id/1) |> Enum.filter(& &1)
      assert length(ids) > 0
    end
  end

  describe "dead player restrictions" do
    test "dead player cannot attack" do
      _gm = enter_player(30110, "GM5", %{gm: true, x: 48, y: 48})
      _target = enter_player(30111, "DeadAttacker", %{x: 50, y: 50})
      flush_mailbox()

      gm_kill_player(30110, "DeadAttacker")
      flush_mailbox()

      result = MapServer.attack(@test_map_id, 30111)
      assert result == {:error, :dead}
    end

    test "dead player cannot rest" do
      _gm = enter_player(30112, "GM6", %{gm: true, x: 48, y: 48})
      _target = enter_player(30113, "DeadRester", %{x: 50, y: 50, hp: 50, max_hp: 100})
      flush_mailbox()

      gm_kill_player(30112, "DeadRester")
      flush_mailbox()

      MapServer.rest(@test_map_id, 30113)
      msgs = collect_messages(300)

      # Should get "Estas muerto" console message (ID 37)
      has_console = Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)
      assert has_console
    end

    test "dead player cannot meditate" do
      _gm = enter_player(30114, "GM7", %{gm: true, x: 48, y: 48})
      _target = enter_player(30115, "DeadMed", %{x: 50, y: 50, class: :mage, mana: 50, max_mana: 100})
      flush_mailbox()

      gm_kill_player(30114, "DeadMed")
      flush_mailbox()

      MapServer.meditate(@test_map_id, 30115)
      msgs = collect_messages(300)

      has_console = Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)
      assert has_console
    end
  end

  describe "snapshot after leave" do
    test "snapshot returns error after player leaves" do
      enter_player(30050, "Leaver")
      flush_mailbox()

      MapServer.leave(@test_map_id, 30050)

      assert {:error, :not_on_map} = MapServer.snapshot_entity(@test_map_id, 30050)
    end
  end
end
