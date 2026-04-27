defmodule Arena.SmokeBotTest do
  @moduledoc """
  Integration smoke test that exercises the full gameplay loop through a MapServer.
  Verifies that a player can perform all core actions (enter, walk, heading, chat,
  yell, rest, request attributes/skills/mini-stats) and get valid responses without
  crashing the server.
  """
  use ExUnit.Case

  alias Arena.Map.MapServer
  alias AoEntities.PlayerEntity

  @test_map_id 10_006

  # Packet IDs (from AoProtocol.PacketIds.Server)
  @pkt_chat_over_head 35
  @pkt_console_msg 37
  @pkt_character_create 42
  @pkt_character_move 44
  @pkt_character_change 49
  @pkt_mini_stats 79
  @pkt_send_atributes 81
  @pkt_send_skills 87

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
        hp: 80,
        max_hp: 100,
        mana: 80,
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

  defp enter_player(char_id, name, overrides) do
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
      {:egress, %{payload: binary}} -> collect_messages_acc(timeout, [binary | acc])
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

  defp has_packet?(msgs, expected_id) do
    Enum.any?(msgs, fn msg ->
      is_binary(msg) and packet_id(msg) == expected_id
    end)
  end

  describe "smoke bot gameplay loop" do
    test "1. player enters map and receives character_create packet" do
      # Enter a second player first so our player's enter triggers a character_create
      # broadcast to us as an observer.
      _observer_entity = enter_player(50001, "SmokeObserver", %{x: 48, y: 48})
      flush_mailbox()

      # Now enter the main player -- observer (self()) should receive character_create
      _player = enter_player(50002, "SmokePlayer", %{x: 49, y: 49})
      msgs = collect_messages(300)

      assert has_packet?(msgs, @pkt_character_create),
             "Should receive character_create packet when a player enters the map"
    end

    test "2. player walks and receives movement packet" do
      _observer = enter_player(50010, "WalkObserver", %{x: 50, y: 50})
      _walker = enter_player(50011, "WalkPlayer", %{x: 51, y: 50})
      flush_mailbox()

      # Try multiple directions until one succeeds
      move_result =
        Enum.find_value([:south, :north, :east, :west], fn dir ->
          case MapServer.move_character(@test_map_id, 50011, dir) do
            {:ok, _pos} -> dir
            {:error, _} -> nil
          end
        end)

      assert move_result != nil, "At least one direction should be walkable"

      msgs = collect_messages(300)

      assert has_packet?(msgs, @pkt_character_move),
             "Observer should receive character_move packet when a nearby player walks"
    end

    test "3. player changes heading and receives heading packet" do
      _observer = enter_player(50020, "HeadObserver", %{x: 50, y: 50})
      _player = enter_player(50021, "HeadPlayer", %{x: 51, y: 50})
      flush_mailbox()

      MapServer.change_heading(@test_map_id, 50021, :north)
      msgs = collect_messages(300)

      assert has_packet?(msgs, @pkt_character_change),
             "Observer should receive character_change packet on heading change"
    end

    test "4. player sends chat message and receives console_msg or chat_over_head" do
      _player = enter_player(50030, "ChatPlayer", %{x: 50, y: 50})
      flush_mailbox()

      MapServer.chat(@test_map_id, 50030, "Hello world!")
      msgs = collect_messages(300)

      has_chat = has_packet?(msgs, @pkt_chat_over_head) or has_packet?(msgs, @pkt_console_msg)

      assert has_chat,
             "Player should receive a chat_over_head or console_msg packet after chatting"
    end

    test "5. player uses yell and receives broadcast" do
      _player = enter_player(50040, "YellPlayer", %{x: 50, y: 50})
      flush_mailbox()

      MapServer.yell(@test_map_id, 50040, "Hello everyone!")
      msgs = collect_messages(300)

      has_yell = has_packet?(msgs, @pkt_chat_over_head) or has_packet?(msgs, @pkt_console_msg)

      assert has_yell,
             "Player should receive a chat/console packet after yelling"
    end

    test "6. player starts resting and state reflects resting flag" do
      _player = enter_player(50050, "RestPlayer", %{x: 50, y: 50, hp: 50, max_hp: 100})
      flush_mailbox()

      # Get actual position and place a campfire (VB6: resting requires nearby fogata)
      {:ok, ent} = MapServer.snapshot_entity(@test_map_id, 50050)
      MapServer.place_event_item(@test_map_id, ent.x, ent.y, 21, 1)
      MapServer.rest(@test_map_id, 50050)
      Process.sleep(100)

      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 50050)
      assert entity.resting, "Player should be in resting state after requesting rest"
    end

    test "7. player stops resting by moving" do
      _player = enter_player(50060, "RestMovePlayer", %{x: 50, y: 50, hp: 50, max_hp: 100})
      flush_mailbox()

      # Get actual position and place a campfire (VB6: resting requires nearby fogata)
      {:ok, ent} = MapServer.snapshot_entity(@test_map_id, 50060)
      MapServer.place_event_item(@test_map_id, ent.x, ent.y, 21, 1)
      # Start resting
      MapServer.rest(@test_map_id, 50060)
      Process.sleep(100)

      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 50060)
      assert entity.resting, "Player should be resting before move"

      # Move to stop resting -- try multiple directions
      _move_result =
        Enum.find_value([:south, :north, :east, :west], fn dir ->
          case MapServer.move_character(@test_map_id, 50060, dir) do
            {:ok, _pos} -> dir
            {:error, _} -> nil
          end
        end)

      Process.sleep(100)

      {:ok, entity} = MapServer.snapshot_entity(@test_map_id, 50060)
      refute entity.resting, "Player should stop resting after moving"
    end

    test "8. player requests attributes and receives send_atributes packet" do
      _player = enter_player(50070, "AttrPlayer", %{x: 50, y: 50})
      flush_mailbox()

      MapServer.request_atributes(@test_map_id, 50070)
      msgs = collect_messages(300)

      assert has_packet?(msgs, @pkt_send_atributes),
             "Player should receive send_atributes packet after requesting attributes"
    end

    test "9. player requests skills and receives send_skills packet" do
      _player = enter_player(50080, "SkillPlayer", %{x: 50, y: 50})
      flush_mailbox()

      MapServer.request_skills(@test_map_id, 50080)
      msgs = collect_messages(300)

      assert has_packet?(msgs, @pkt_send_skills),
             "Player should receive send_skills packet after requesting skills"
    end

    test "10. player requests mini stats and receives mini_stats packet" do
      _player = enter_player(50090, "MiniStatPlayer", %{x: 50, y: 50})
      flush_mailbox()

      MapServer.request_mini_stats(@test_map_id, 50090)
      msgs = collect_messages(300)

      assert has_packet?(msgs, @pkt_mini_stats),
             "Player should receive mini_stats packet after requesting mini stats"
    end
  end
end
