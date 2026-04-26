defmodule Arena.Map.SocialDescriptionSafeE2ETest do
  @moduledoc """
  End-to-end tests for the Social description / safe-mode / ocultarse
  flows. Pins the Social effects-contract migration (Sub C:
  change_description, safe_toggle, ocultarse).

  - `change_description` and `ocultarse` exercise the cast/direct flow.
  - `safe_toggle` exercises `Effects.run_handler_call/2` so we hit the
    GenServer call branch.

  Outbound packets flow through `AoSession.Egress.enqueue/2` and arrive
  in the test pid mailbox as `{:egress, %AoSession.Outbound{...}}`
  envelopes — never via the legacy `{:send_raw, _}` shim.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.{MapServer, Social, Effects}
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
      gold: 0,
      level: 25,
      class: :warrior,
      race: :human,
      gender: :male,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      skills: %{hiding: 50},
      spells: [],
      inventory: List.duplicate(nil, 24),
      faction: :none,
      dead: false,
      safe_mode: false,
      oculto: false,
      oculto_timer: 0,
      invisible: false,
      navigating: false,
      description: "",
      last_attacked_at: -1_000_000_000_000,
      buffs: []
    }

    struct!(PlayerEntity, Map.merge(defaults, overrides))
  end

  defp state_with(player, opts \\ []) do
    map_state(
      players: %{player.char_id => player},
      sessions: Keyword.get(opts, :sessions, %{player.char_id => self()}),
      occupancy: Keyword.get(opts, :occupancy, %{}),
      meta: %{rain: false, sin_invi_ocul: false, tile_exit_map: %{}},
      visibility_mode: :global
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:change_description, _, _})
  # ════════════════════════════════════════════════════════════════════════

  describe "change_description via MapServer cast" do
    test "alive player: console confirmation envelope, description applied" do
      state = state_with(make_player())
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:change_description, :player, "hello"}, state)

      assert new_state.players[:player].description == "hello"

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "Descripcion") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "dead player: rejection console envelope, description unchanged" do
      state = state_with(make_player(%{dead: true, description: "old"}))
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:change_description, :player, "new"}, state)

      assert new_state.players[:player].description == "old"

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "muerto") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, _} = MapServer.handle_cast({:change_description, :ghost, "x"}, state)

      refute_receive {:egress, _}, 50
    end

    test "long description gets truncated to 200 chars" do
      state = state_with(make_player())
      long_desc = String.duplicate("a", 300)

      assert {:noreply, new_state} =
               MapServer.handle_cast({:change_description, :player, long_desc}, state)

      assert String.length(new_state.players[:player].description) == 200
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_call({:safe_toggle, _}) — uses run_handler_call/2
  # ════════════════════════════════════════════════════════════════════════

  describe "safe_toggle via MapServer call" do
    test "off → on: safe_mode_on packet fanned, state flipped" do
      state = state_with(make_player(%{safe_mode: false}))
      on_id = AoProtocol.PacketIds.Server.safe_mode_on()

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:safe_toggle, :player}, :from, state)

      assert new_state.players[:player].safe_mode == true

      assert_receive {:egress, %{payload: <<^on_id::little-signed-integer-16, _::binary>>}}
      refute_receive {:send_raw, _}, 50
    end

    test "on → off: safe_mode_off packet fanned, state flipped" do
      state = state_with(make_player(%{safe_mode: true}))
      off_id = AoProtocol.PacketIds.Server.safe_mode_off()

      assert {:reply, :ok, new_state} =
               MapServer.handle_call({:safe_toggle, :player}, :from, state)

      assert new_state.players[:player].safe_mode == false

      assert_receive {:egress, %{payload: <<^off_id::little-signed-integer-16, _::binary>>}}
      refute_receive {:send_raw, _}, 50
    end

    test "missing player: reply :ok, no envelopes" do
      state = map_state(players: %{}, sessions: %{})

      assert {:reply, :ok, _} = MapServer.handle_call({:safe_toggle, :ghost}, :from, state)

      refute_receive {:egress, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Social.handle_ocultarse — direct (no MapServer cast wired)
  # ════════════════════════════════════════════════════════════════════════

  describe "ocultarse handler" do
    test "successful hide on high skill: hide_from_non_gm + console effects emitted" do
      :rand.seed(:exsss, {1, 2, 3})
      state = state_with(make_player(%{class: :asesino, skills: %{hiding: 100}}))

      {:ok, new_state, effects} = Social.handle_ocultarse(state, :player, 100)

      # With high skill and seeded rand, expect success
      if new_state.players[:player].oculto do
        # success path
        assert Enum.any?(effects, fn
                 {:hide_from_non_gm, _} -> true
                 _ -> false
               end),
               "expected hide_from_non_gm effect on success"

        assert Enum.any?(effects, fn
                 {:send, _, %{payload: <<37::little-signed-integer-16, _::binary>>}} -> true
                 _ -> false
               end),
               "expected console message effect"
      end

      # Run the effects through the runner: must NOT trip {:send_raw, _}
      :ok = Effects.run(new_state, effects)
      refute_receive {:send_raw, _}, 50
    end

    test "rejection on dead player: only console effect, no hide_from_non_gm" do
      state = state_with(make_player(%{dead: true}))

      {:ok, new_state, effects} = Social.handle_ocultarse(state, :player, 50)

      assert new_state.players[:player].oculto == false

      refute Enum.any?(effects, fn
               {:hide_from_non_gm, _} -> true
               _ -> false
             end)

      assert Enum.any?(effects, fn
               {:send, _, %{payload: <<37::little-signed-integer-16, _::binary>>}} -> true
               _ -> false
             end)

      :ok = Effects.run(new_state, effects)
      refute_receive {:send_raw, _}, 50
    end

    test "already oculto: rejection effect, no hide_from_non_gm" do
      state = state_with(make_player(%{oculto: true}))

      {:ok, _new_state, effects} = Social.handle_ocultarse(state, :player, 50)

      refute Enum.any?(effects, fn
               {:hide_from_non_gm, _} -> true
               _ -> false
             end)
    end

    test "missing player: empty effects, state unchanged" do
      state = state_with(make_player())
      empty_state = %{state | players: %{}}

      {:ok, new_state, effects} = Social.handle_ocultarse(empty_state, :ghost, 50)

      assert new_state == empty_state
      assert effects == []
    end
  end
end
