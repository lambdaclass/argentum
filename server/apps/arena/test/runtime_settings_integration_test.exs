defmodule Arena.RuntimeSettingsIntegrationTest do
  @moduledoc """
  Adversarial integration tests for runtime-tunable settings.

  These assertions prove the settings registry is wired into live handlers,
  not just storing values in ETS.
  """

  use ExUnit.Case, async: false

  import Arena.Test.MapStateFactory

  alias Arena.Data.GameData
  alias AoEntities.PlayerEntity
  alias Arena.Map.{Chat, CombatHandlers, Effects, Faction, InventoryHandlers, MapServer, Movement}

  setup do
    case Arena.Settings.start_link() do
      {:ok, pid} ->
        on_exit(fn -> GenServer.stop(pid) end)

      {:error, {:already_started, _pid}} ->
        :ok
    end

    Arena.Settings.reset_all()
    on_exit(fn -> Arena.Settings.reset_all() end)
    :ok
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
      skills: %{combat_weapons: 75, combat_tactics: 75, combat_defense: 75, magic: 75}
    }

    struct!(PlayerEntity, Map.merge(defaults, overrides))
  end

  defp make_state(players, opts \\ []) do
    map_state(
      players: players,
      sessions: Keyword.get(opts, :sessions, %{}),
      visibility_mode: Keyword.get(opts, :visibility_mode, :global),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      grid: Keyword.get(opts, :grid),
      meta: Map.merge(%{rain: false, snow: false, sin_invi_ocul: false}, Keyword.get(opts, :meta, %{}))
    )
  end

  defp start_session(label) do
    parent = self()

    spawn_link(fn ->
      session_loop(parent, label)
    end)
  end

  defp session_loop(parent, label) do
    receive do
      msg ->
        send(parent, {:session, label, msg})
        session_loop(parent, label)
    end
  end

  defp collect_session_messages(timeout, acc \\ []) do
    receive do
      {:session, _label, _msg} = entry ->
        collect_session_messages(timeout, [entry | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp decode_chat_over_head(
         <<35::little-signed-integer-16, len::little-signed-integer-16, message::binary-size(len),
           char_index::little-signed-integer-16, color::little-signed-integer-32, es_spell::unsigned-integer-8,
           x::unsigned-integer-8, y::unsigned-integer-8, min_time::little-signed-integer-16,
           max_time::little-signed-integer-16>>
       ) do
    %{
      message: message,
      char_index: char_index,
      color: color,
      es_spell: es_spell,
      x: x,
      y: y,
      min_time: min_time,
      max_time: max_time
    }
  end

  defp decode_faction_message(
         <<38::little-signed-integer-16, msg_len::little-signed-integer-16, message::binary-size(msg_len),
           font_index::unsigned-integer-8, label_len::little-signed-integer-16, label::binary-size(label_len)>>
       ) do
    %{message: message, font_index: font_index, label: label}
  end

  defp find_consumable_item do
    Enum.find_value(1..10_000, fn item_id ->
      case GameData.get_item(item_id) do
        %{obj_type: type} = item when type in [1, 8, 9] -> {item_id, item}
        _ -> nil
      end
    end) || flunk("expected at least one consumable item in GameData")
  end

  describe "chat cooldown settings" do
    test "chat_cooldown_ms=0 allows immediate consecutive chat packets" do
      Arena.Settings.set(:chat_cooldown_ms, 0)

      sender_pid = start_session(:sender)
      near_pid = start_session(:near)

      sender = make_player()
      near = make_player(%{char_id: :near, name: "Nearby", x: 51, y: 50, char_index: 2})

      state =
        make_state(
          %{sender.char_id => sender, near.char_id => near},
          sessions: %{sender.char_id => sender_pid, near.char_id => near_pid},
          visibility_mode: :aoi_scan
        )

      {:ok, state, eff1} = Chat.handle_chat(state, sender.char_id, "first")
      Effects.run(state, eff1)
      {:ok, state, eff2} = Chat.handle_chat(state, sender.char_id, "second")
      Effects.run(state, eff2)

      messages = collect_session_messages(100)

      sender_msgs =
        for {:session, :sender, {:egress, %{payload: raw}}} <- messages, do: decode_chat_over_head(raw)

      near_msgs =
        for {:session, :near, {:egress, %{payload: raw}}} <- messages, do: decode_chat_over_head(raw)

      assert Enum.map(sender_msgs, & &1.message) == ["first", "second"]
      assert Enum.map(near_msgs, & &1.message) == ["first", "second"]
      assert state.players[sender.char_id].last_chat_at > sender.last_chat_at
    end

    test "chat_cooldown_ms=0 also unlocks immediate consecutive faction chat" do
      Arena.Settings.set(:chat_cooldown_ms, 0)

      sender_pid = start_session(:sender)
      ally_pid = start_session(:ally)

      sender = make_player(%{faction: :royal_army})
      ally = make_player(%{char_id: :ally, name: "Ally", x: 52, y: 50, char_index: 2, faction: :royal_army})

      state =
        make_state(
          %{sender.char_id => sender, ally.char_id => ally},
          sessions: %{sender.char_id => sender_pid, ally.char_id => ally_pid}
        )

      {:ok, state, eff1} = Faction.handle_faction_chat(state, sender.char_id, "primero")
      Effects.run(state, eff1)
      {:ok, state, eff2} = Faction.handle_faction_chat(state, sender.char_id, "segundo")
      Effects.run(state, eff2)

      messages = collect_session_messages(100)

      ally_msgs =
        for {:session, :ally, {:egress, %{payload: raw}}} <- messages, do: decode_faction_message(raw)

      assert Enum.map(ally_msgs, & &1.message) == ["Tester: primero", "Tester: segundo"]
      assert Enum.all?(ally_msgs, &(&1.label == "MENSAJE_ARMADA"))
      assert state.players[sender.char_id].last_chat_at > sender.last_chat_at
    end
  end

  describe "movement settings" do
    test "speed_hack_threshold is read from runtime settings" do
      Arena.Settings.set(:speed_hack_threshold, 0.0)

      now = System.monotonic_time(:millisecond)
      player = make_player(%{last_step_at: now})
      state = make_state(%{player.char_id => player}, sessions: %{player.char_id => self()})

      {:reply, result, new_state} = Movement.handle_move(state, player.char_id, :north)

      assert result == {:error, :speed_hack}
      assert new_state.players[player.char_id].speed_hack_counter == 0.0
      # Movement now emits the position-correction snap-back through
      # the egress queue (Effects.send/2) instead of a bare
      # {:send_raw, _} envelope.
      assert_receive {:egress, _}
    end

    test "base_walk_interval_ms changes the applied speed-hack penalty window" do
      Arena.Settings.set(:speed_hack_threshold, 0.0)
      Arena.Settings.set(:base_walk_interval_ms, 400)

      now = System.monotonic_time(:millisecond)
      player = make_player(%{last_step_at: now})
      state = make_state(%{player.char_id => player}, sessions: %{player.char_id => self()})
      before = System.monotonic_time(:millisecond)

      {:reply, {:error, :speed_hack}, new_state} = Movement.handle_move(state, player.char_id, :north)

      penalty_ms = new_state.players[player.char_id].next_move_at - before
      assert penalty_ms >= 700
      assert_receive {:egress, _}
    end
  end

  describe "combat and item timing settings" do
    test "attack_cooldown_ms updates next_attack_at on successful attack" do
      Arena.Settings.set(:attack_cooldown_ms, 2500)

      player = make_player()
      state = make_state(%{player.char_id => player}, sessions: %{player.char_id => self()})
      before = System.monotonic_time(:millisecond)

      {:reply, :ok, new_state} = CombatHandlers.handle_attack(state, player.char_id, nil, nil)

      assert new_state.players[player.char_id].next_attack_at - before >= 2400
    end

    test "item_use_cooldown_ms updates next_item_use_at on successful use" do
      Arena.Settings.set(:item_use_cooldown_ms, 1234)

      {item_id, _item_def} = find_consumable_item()
      inventory = List.replace_at(List.duplicate(nil, 24), 0, %{item_id: item_id, amount: 2, equipped: false})
      player = make_player(%{inventory: inventory, hp: 50, mana: 50, stamina: 50, hunger: 50, thirst: 50})
      state = make_state(%{player.char_id => player}, sessions: %{player.char_id => self()})
      before = System.monotonic_time(:millisecond)

      {:ok, new_state, _effects} = InventoryHandlers.handle_use_item(state, player.char_id, 0)

      assert new_state.players[player.char_id].next_item_use_at - before >= 1150
    end
  end

  describe "map timers" do
    test "regen_tick_ms changes the reschedule interval for regen" do
      Arena.Settings.set(:regen_tick_ms, 5)

      # A populated map on a live chain: an empty map deliberately stops rearming, and a
      # tick carries the generation that armed it so a leftover from a previous chain can
      # be told apart from the current one.
      state = %{make_state(%{1 => make_player()}) | fast_timer_gen: 1, fast_timers_armed: true}

      assert {:noreply, _state} = MapServer.handle_info({:regen_tick, 1}, state)
      assert_receive {:regen_tick, 1}, 50
    end
  end
end
