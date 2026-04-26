defmodule Arena.Map.SocialInventorySkillsE2ETest do
  @moduledoc """
  End-to-end tests for the Social inventory/skills mutation flows
  through `Arena.Map.MapServer.handle_cast/2`. Pins the Social
  effects-contract migration (Sub B: move_spell, modify_skills,
  move_item).

  All handlers now return `{:ok, state, effects}` and the MapServer cast
  branch dispatches via `Arena.Map.Effects.run_handler/2`. Outbound
  packets flow through `AoSession.Egress.enqueue/2` and arrive in the
  test pid mailbox as `{:egress, %AoSession.Outbound{payload: <<...>>}}`
  envelopes — never via the legacy `{:send_raw, _}` shim.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.MapServer
  alias Arena.Data.{GameData, SpellDef}
  alias AoEntities.PlayerEntity

  import Arena.Test.MapStateFactory

  @spell_a 88_001
  @spell_b 88_002

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    drain()

    spell_a = %SpellDef{id: @spell_a, name: "TestA", mana_required: 5, sta_required: 0,
                        min_skill: 0, cooldown: 0, sube_hp: 1, min_hp: 1, max_hp: 1}
    spell_b = %SpellDef{id: @spell_b, name: "TestB", mana_required: 5, sta_required: 0,
                        min_skill: 0, cooldown: 0, sube_hp: 1, min_hp: 1, max_hp: 1}

    :ets.insert(:arena_game_data, {{:spell, @spell_a}, spell_a})
    :ets.insert(:arena_game_data, {{:spell, @spell_b}, spell_b})

    on_exit(fn ->
      :ets.delete(:arena_game_data, {:spell, @spell_a})
      :ets.delete(:arena_game_data, {:spell, @spell_b})
    end)

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
      spells: [@spell_a, @spell_b],
      spell_cooldowns: %{},
      skill_points: 10,
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
  # MapServer.handle_cast({:move_spell, ...})
  # ════════════════════════════════════════════════════════════════════════

  describe "move_spell via MapServer cast" do
    test "swap two spells: two change_spell_slot envelopes fanned" do
      state = state_with(make_player())
      slot_id = AoProtocol.PacketIds.Server.change_spell_slot()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:move_spell, :player, false, 1}, state)

      assert new_state.players[:player].spells == [@spell_b, @spell_a]

      assert_receive {:egress, %{payload: <<^slot_id::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<^slot_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
    end

    test "out-of-range slot: no envelopes, state unchanged" do
      player = make_player()
      state = state_with(player)

      assert {:noreply, new_state} =
               MapServer.handle_cast({:move_spell, :player, true, 1}, state)

      assert new_state.players[:player].spells == player.spells
      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:move_spell, :ghost, false, 1}, state)

      refute_receive {:egress, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:modify_skills, ...})
  # ════════════════════════════════════════════════════════════════════════

  describe "modify_skills via MapServer cast" do
    test "valid distribution: send_skills envelope fanned, points consumed" do
      state = state_with(make_player(%{skill_points: 10, skills: %{magic: 50}}))
      points = [5 | List.duplicate(0, 23)]
      skills_id = AoProtocol.PacketIds.Server.send_skills()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:modify_skills, :player, points}, state)

      p = new_state.players[:player]
      assert p.skills.magic == 55
      assert p.skill_points == 5

      assert_receive {:egress, %{payload: <<^skills_id::little-signed-integer-16, _::binary>>}}
      refute_receive {:send_raw, _}, 50
    end

    test "requesting more points than available: rejection console envelope, state unchanged" do
      state = state_with(make_player(%{skill_points: 5, skills: %{magic: 50}}))
      points = [10 | List.duplicate(0, 23)]
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:modify_skills, :player, points}, state)

      assert new_state.players[:player].skill_points == 5

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "puntos") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})
      points = [5 | List.duplicate(0, 23)]

      assert {:noreply, _} = MapServer.handle_cast({:modify_skills, :ghost, points}, state)

      refute_receive {:egress, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:move_item, ...})
  # ════════════════════════════════════════════════════════════════════════

  describe "move_item via MapServer cast" do
    test "swap two slots: two change_inventory_slot envelopes fanned" do
      inv =
        List.duplicate(nil, 24)
        |> List.replace_at(0, %{item_id: 100, amount: 1, equipped: false})
        |> List.replace_at(1, %{item_id: 200, amount: 5, equipped: false})

      state = state_with(make_player(%{inventory: inv}))
      inv_id = AoProtocol.PacketIds.Server.change_inventory_slot()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:move_item, :player, 1, 2}, state)

      slot0 = Enum.at(new_state.players[:player].inventory, 0)
      slot1 = Enum.at(new_state.players[:player].inventory, 1)
      assert slot0.item_id == 200
      assert slot1.item_id == 100

      assert_receive {:egress, %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}}
      assert_receive {:egress, %{payload: <<^inv_id::little-signed-integer-16, _::binary>>}}

      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:move_item, :ghost, 1, 2}, state)

      refute_receive {:egress, _}, 50
    end
  end
end
