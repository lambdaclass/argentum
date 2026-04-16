defmodule Arena.GmCommandsTest do
  @moduledoc """
  Tests for GM rain_toggle via MapServer.
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
        skills: %{combat: 80},
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

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      50 -> :ok
    end
  end

  defp collect_all_messages do
    collect_all_messages([])
  end

  defp collect_all_messages(acc) do
    receive do
      msg -> collect_all_messages([msg | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # ---- rain_toggle tests ----

  describe "GM rain_toggle" do
    test "GM player toggles rain on the map and all players receive rain_toggle packet" do
      test_pid = self()

      # Enter GM player (session = self())
      _gm = enter_player(40001, "RainGM", %{gm: true, x: 48, y: 48})

      # Enter regular player from a spawned process so it gets its own session pid.
      # The spawned process calls MapServer.enter (which uses caller_pid as session),
      # then forwards all received messages to the test process.
      regular_entity = make_entity(40002, "RainRegular", %{gm: false, x: 49, y: 49})

      regular_pid =
        spawn(fn ->
          {:ok, _, _, _} = MapServer.enter(@test_map_id, regular_entity)

          forward_loop = fn forward_loop ->
            receive do
              :stop ->
                :ok

              msg ->
                send(test_pid, {:regular_msg, msg})
                forward_loop.(forward_loop)
            end
          end

          forward_loop.(forward_loop)
        end)

      on_exit(fn ->
        send(regular_pid, :stop)

        try do
          MapServer.leave(@test_map_id, 40002)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      # Wait for both enters to complete and drain enter messages
      Process.sleep(200)
      drain_mailbox()

      # Toggle rain
      MapServer.gm_rain_toggle(@test_map_id, 40001)

      # Give time for cast to process and forwarding to happen
      Process.sleep(200)

      # Collect all messages (direct + forwarded from regular player)
      all_msgs = collect_all_messages()

      gm_rain =
        Enum.filter(all_msgs, fn
          {:send_raw, <<59::little-16, _rest::binary>>} -> true
          _ -> false
        end)

      regular_rain =
        Enum.filter(all_msgs, fn
          {:regular_msg, {:send_raw, <<59::little-16, _rest::binary>>}} -> true
          _ -> false
        end)

      assert length(gm_rain) >= 1, "GM should receive rain_toggle packet"
      assert length(regular_rain) >= 1, "Regular player should receive rain_toggle packet"
    end

    test "non-GM player cannot toggle rain" do
      _player = enter_player(40003, "NotGM", %{gm: false, x: 48, y: 48})
      drain_mailbox()

      # Get the initial rain state
      info = MapServer.get_info(@test_map_id)
      initial_rain = info.rain

      MapServer.gm_rain_toggle(@test_map_id, 40003)
      Process.sleep(100)

      # Rain state should not change
      info = MapServer.get_info(@test_map_id)
      assert info.rain == initial_rain, "Non-GM should not be able to toggle rain"
    end

    test "rain toggle actually changes map meta state" do
      _gm = enter_player(40005, "RainGM2", %{gm: true, x: 48, y: 48})
      drain_mailbox()

      info_before = MapServer.get_info(@test_map_id)

      MapServer.gm_rain_toggle(@test_map_id, 40005)
      Process.sleep(100)

      info_after = MapServer.get_info(@test_map_id)
      assert info_after.rain != info_before.rain, "Rain state should flip after GM toggle"

      drain_mailbox()

      # Toggle again to restore
      MapServer.gm_rain_toggle(@test_map_id, 40005)
      Process.sleep(100)

      info_restored = MapServer.get_info(@test_map_id)
      assert info_restored.rain == info_before.rain, "Rain state should flip back on second toggle"
    end
  end
end
