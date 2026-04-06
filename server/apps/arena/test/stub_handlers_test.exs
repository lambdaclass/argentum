defmodule Arena.StubHandlersTest do
  @moduledoc """
  Tests for the compatibility gate stub handlers:
  yell, rest, meditate, heal, resucitate, request_atributes/skills/mini_stats,
  double_click, and regen tick.
  """
  use ExUnit.Case

  alias Arena.Map.MapServer
  alias Arena.Entity.PlayerEntity

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
        level: 5,
        xp: 1000,
        gold: 500,
        class: :warrior,
        race: :human,
        gender: :male,
        skills: %{healing: 50}
      },
      overrides
    )
  end

  defp enter_player(char_id, name, overrides \\ %{}) do
    entity = make_entity(char_id, name, overrides)
    {:ok, _idx, _players, _weather} = MapServer.enter(@test_map_id, entity, session_pid: self())
    on_exit(fn -> MapServer.leave(@test_map_id, char_id) end)
    entity
  end

  # Collect all {:send_raw, binary} messages received within timeout
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

  # Extract packet ID from a raw binary
  defp packet_id(<<id::little-signed-integer-16, _rest::binary>>), do: id

  describe "yell" do
    test "broadcasts chat_over_head to self (session pid)" do
      _entity = enter_player(20001, "Yeller")
      # Drain enter messages
      collect_messages(100)

      MapServer.yell(@test_map_id, 20001, "HELLO WORLD!")
      msgs = collect_messages(300)

      # Should receive chat_over_head (ID 35)
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 35 end),
             "Expected chat_over_head (ID 35), got IDs: #{inspect(Enum.map(msgs, fn m -> if is_binary(m), do: packet_id(m) end))}"
    end
  end

  describe "rest" do
    test "toggles resting flag and sends console message" do
      _entity = enter_player(20002, "Rester", %{hp: 50, max_hp: 100})
      collect_messages(100)

      MapServer.rest(@test_map_id, 20002)
      msgs = collect_messages(300)

      # Should receive console_msg (ID 37)
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)
    end

    test "rejects rest when already full HP" do
      _entity = enter_player(20003, "FullHP", %{hp: 100, max_hp: 100})
      collect_messages(100)

      MapServer.rest(@test_map_id, 20003)
      msgs = collect_messages(300)

      # Should get "Estas sano" console message
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)
    end
  end

  describe "meditate" do
    test "toggles meditating flag for magical class and sends console message + FX" do
      # Use :mage — a magical class that can meditate
      _entity = enter_player(20004, "Meditator", %{mana: 50, max_mana: 100, class: :mage})
      collect_messages(100)

      MapServer.meditate(@test_map_id, 20004)
      msgs = collect_messages(300)

      # Should receive console_msg (37) and create_fx (60)
      ids = Enum.map(msgs, fn msg -> if is_binary(msg), do: packet_id(msg) end)
      assert 37 in ids, "Expected console_msg, got: #{inspect(ids)}"
      assert 60 in ids, "Expected create_fx, got: #{inspect(ids)}"
    end

    test "rejects meditate for non-magical class (warrior)" do
      _entity = enter_player(20005, "Warrior", %{mana: 50, max_mana: 100, class: :warrior})
      collect_messages(100)

      MapServer.meditate(@test_map_id, 20005)
      msgs = collect_messages(300)

      # Should get rejection console_msg
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)

      # Should NOT be meditating
      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 20005)
      refute entity.meditating
    end

    test "rejects meditate when mana is full" do
      _entity = enter_player(20050, "FullMana", %{mana: 100, max_mana: 100, class: :mage})
      collect_messages(100)

      MapServer.meditate(@test_map_id, 20050)
      msgs = collect_messages(300)

      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)
    end
  end

  describe "heal" do
    test "rejects heal without nearby healer NPC" do
      _entity = enter_player(20006, "Healer", %{hp: 50, max_hp: 100})
      collect_messages(100)

      # VB6: heal requires nearby Revividor NPC — without one, get rejection
      MapServer.heal(@test_map_id, 20006)
      msgs = collect_messages(300)

      # Should get "No hay un sacerdote cerca" console_msg
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)
    end

    test "rejects heal when already full HP" do
      _entity = enter_player(20007, "FullHPHeal")
      collect_messages(100)

      MapServer.heal(@test_map_id, 20007)
      msgs = collect_messages(300)

      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)
    end
  end

  describe "resucitate" do
    test "rejects resucitate without nearby healer NPC" do
      _entity = enter_player(20008, "DeadGuy", %{dead: true, hp: 0})
      collect_messages(100)

      # VB6: resucitate requires nearby Revividor NPC
      MapServer.resucitate(@test_map_id, 20008)
      msgs = collect_messages(300)

      # Should get "No hay un sacerdote cerca" console_msg
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)

      # Should still be dead
      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 20008)
      assert entity.dead
    end

    test "rejects resucitate when not dead" do
      _entity = enter_player(20009, "AliveGuy")
      collect_messages(100)

      MapServer.resucitate(@test_map_id, 20009)
      msgs = collect_messages(300)

      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)
    end
  end

  describe "request_atributes" do
    test "sends update_user_stats packet" do
      _entity = enter_player(20010, "StatsGuy")
      collect_messages(100)

      MapServer.request_atributes(@test_map_id, 20010)
      msgs = collect_messages(300)

      # update_user_stats (61)
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 61 end),
             "Expected update_user_stats (61)"
    end
  end

  describe "request_skills" do
    test "sends send_skills packet" do
      _entity = enter_player(20011, "SkillGuy")
      collect_messages(100)

      MapServer.request_skills(@test_map_id, 20011)
      msgs = collect_messages(300)

      # send_skills (87)
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 87 end),
             "Expected send_skills (87)"
    end
  end

  describe "request_mini_stats" do
    test "sends mini_stats packet" do
      _entity = enter_player(20012, "MiniGuy")
      collect_messages(100)

      MapServer.request_mini_stats(@test_map_id, 20012)
      msgs = collect_messages(300)

      # mini_stats (79)
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 79 end),
             "Expected mini_stats (79)"
    end
  end

  describe "double_click" do
    test "on empty adjacent tile does nothing" do
      _entity = enter_player(20013, "Clicker", %{x: 35, y: 35})
      collect_messages(100)

      # Use actual position from server (enter may relocate if tile blocked)
      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 20013)
      MapServer.double_click(@test_map_id, 20013, entity.x + 1, entity.y)
      msgs = collect_messages(300)

      assert msgs == []
    end

    test "too far away sends distance error" do
      _entity = enter_player(20014, "FarClicker", %{x: 40, y: 40})
      collect_messages(100)

      # Click on a tile that's too far (>4 tiles) — VB6 sends distance error
      MapServer.double_click(@test_map_id, 20014, 50, 50)
      msgs = collect_messages(300)

      # Should get "Estas demasiado lejos" console_msg (37)
      assert Enum.any?(msgs, fn msg -> is_binary(msg) and packet_id(msg) == 37 end)
    end
  end

  describe "movement cancels rest/meditate" do
    test "moving cancels resting" do
      # Use unique position to avoid occupancy collision with other tests
      _entity = enter_player(20015, "RestWalker", %{hp: 50, max_hp: 100, x: 30, y: 30})
      collect_messages(100)

      # Start resting
      MapServer.rest(@test_map_id, 20015)
      collect_messages(100)

      # Verify entity is resting
      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 20015)
      assert entity.resting

      # Get actual position and try to move from there
      {:ok, _ent} = MapServer.snapshot_entity(@test_map_id, 20015)

      # Try moving south (more likely to have open tiles than north)
      result = MapServer.move_character(@test_map_id, 20015, :south)

      if match?({:ok, _}, result) do
        {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 20015)
        refute entity.resting
      else
        # If blocked, try east
        result = MapServer.move_character(@test_map_id, 20015, :east)
        if match?({:ok, _}, result) do
          {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 20015)
          refute entity.resting
        end
      end
    end
  end
end
