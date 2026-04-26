defmodule Arena.Map.SocialStatRequestsE2ETest do
  @moduledoc """
  End-to-end tests for the Social stat-request flows through
  `Arena.Map.MapServer.handle_cast/2`. Pins the Social effects-contract
  migration (Sub A: request_atributes, request_skills, request_mini_stats,
  spell_info, request_account_state, request_reward).

  All handlers now return `{:ok, state, effects}` and the MapServer cast
  branch dispatches via `Arena.Map.Effects.run_handler/2`. Outbound packets
  flow through `AoSession.Egress.enqueue/2` and arrive in the test pid
  mailbox as `{:egress, %AoSession.Outbound{payload: <<...>>}}` envelopes —
  never via the legacy `{:send_raw, _}` shim.
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

  defp make_player(overrides \\ %{}) do
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
      mana: 200,
      max_mana: 200,
      stamina: 100,
      max_stamina: 100,
      gold: 1_000,
      level: 25,
      xp: 0,
      class: :warrior,
      race: :human,
      gender: :male,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      skills: %{magic: 50},
      spells: [],
      inventory: List.duplicate(nil, 24),
      faction: :none,
      criminal: false,
      dead: false,
      citizens_killed: 0,
      criminals_killed: 0,
      npcs_killed: 0,
      penalty: 0,
      deaths: 0,
      fishing_points: 0,
      bank_gold: 0,
      gamble_wins: 0,
      gamble_losses: 0,
      gamble_plays: 0,
      faction_score: 0,
      faction_rank_armada: 0,
      faction_rank_chaos: 0
    }

    struct!(PlayerEntity, Map.merge(defaults, overrides))
  end

  defp state_with(player, opts \\ []) do
    map_state(
      players: %{player.char_id => player},
      sessions: Keyword.get(opts, :sessions, %{player.char_id => self()}),
      npcs_live: Keyword.get(opts, :npcs_live, %{}),
      occupancy: Keyword.get(opts, :occupancy, %{})
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:request_atributes, _}) — emits stats packets
  # ════════════════════════════════════════════════════════════════════════

  describe "request_atributes via MapServer cast" do
    test "alive player: update_user_stats and send_atributes envelopes fanned" do
      state = state_with(make_player())
      stats_id = AoProtocol.PacketIds.Server.update_user_stats()
      atrib_id = AoProtocol.PacketIds.Server.send_atributes()

      assert {:noreply, _} = MapServer.handle_cast({:request_atributes, :player}, state)

      assert_receive {:egress, %{payload: <<^stats_id::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<^atrib_id::little-signed-integer-16, _::binary>>}}
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op, no envelopes" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:request_atributes, :ghost}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "stale session (sessions map missing pid): no envelopes land" do
      player = make_player()
      state = state_with(player, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:request_atributes, :player}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:request_skills, _})
  # ════════════════════════════════════════════════════════════════════════

  describe "request_skills via MapServer cast" do
    test "alive player: send_skills envelope fanned" do
      state = state_with(make_player())
      skills_id = AoProtocol.PacketIds.Server.send_skills()

      assert {:noreply, _} = MapServer.handle_cast({:request_skills, :player}, state)

      assert_receive {:egress, %{payload: <<^skills_id::little-signed-integer-16, _::binary>>}}
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:request_skills, :ghost}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:request_mini_stats, _}) — two envelopes, ordered
  # ════════════════════════════════════════════════════════════════════════

  describe "request_mini_stats via MapServer cast" do
    test "alive player: update_user_stats THEN mini_stats, in that order" do
      state = state_with(make_player())
      stats_id = AoProtocol.PacketIds.Server.update_user_stats()
      mini_id = AoProtocol.PacketIds.Server.mini_stats()

      assert {:noreply, _} = MapServer.handle_cast({:request_mini_stats, :player}, state)

      assert_receive {:egress, %{payload: <<id1::little-signed-integer-16, _::binary>>}}
      assert id1 == stats_id, "first envelope must be update_user_stats"

      assert_receive {:egress, %{payload: <<id2::little-signed-integer-16, _::binary>>}}
      assert id2 == mini_id, "second envelope must be mini_stats"

      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:request_mini_stats, :ghost}, state)

      refute_receive {:egress, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:spell_info, _, slot})
  # ════════════════════════════════════════════════════════════════════════

  describe "spell_info via MapServer cast" do
    test "empty slot: no-spell console envelope" do
      state = state_with(make_player(%{spells: []}))
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, _} = MapServer.handle_cast({:spell_info, :player, 1}, state)

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "hechizo") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:spell_info, :ghost, 1}, state)

      refute_receive {:egress, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:request_account_state, _})
  # ════════════════════════════════════════════════════════════════════════

  describe "request_account_state via MapServer cast" do
    test "dead player: dead-message console envelope, no other side effects" do
      state = state_with(make_player(%{dead: true}))
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, _} = MapServer.handle_cast({:request_account_state, :player}, state)

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "muerto") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "no selected NPC: must-select console envelope" do
      state = state_with(make_player())
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, _} = MapServer.handle_cast({:request_account_state, :player}, state)

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "seleccionar") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:request_account_state, :ghost}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:request_reward, _})
  # ════════════════════════════════════════════════════════════════════════

  describe "request_reward via MapServer cast" do
    test "dead player: dead-message console envelope" do
      state = state_with(make_player(%{dead: true}))
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, _} = MapServer.handle_cast({:request_reward, :player}, state)

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "muerto") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "no selected NPC: must-select console envelope" do
      state = state_with(make_player(%{faction: :royal_army}))
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, _} = MapServer.handle_cast({:request_reward, :player}, state)

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "seleccionar") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:request_reward, :ghost}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end
end
