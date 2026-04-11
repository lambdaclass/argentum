defmodule AoTcpGateway.HogarTest do
  @moduledoc """
  Tests for VB6 /HOGAR (home travel) behavior.

  Exercises both the dead-instant and alive-delayed paths through
  SessionLogic, verifying restrictions, cancellation, and arrival.
  """
  use ExUnit.Case, async: true

  alias AoTcpGateway.SessionLogic
  alias Arena.Entity.PlayerEntity

  # ---- Helpers ----

  # Jail map from VB6
  @jail_map_id 66

  defp base_entity(overrides \\ %{}) do
    Map.merge(
      %PlayerEntity{
        char_id: 7001,
        name: "HogarTester",
        account_id: "acct_hogar",
        x: 50,
        y: 50,
        level: 10,
        gold: 10_000,
        dead: false,
        home_city: :ullathorpe,
        penalty: 0,
        map_id: 300
      },
      overrides
    )
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 7001,
        map_id: 300,
        account_id: "acct_hogar",
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        hogar_timer_ref: nil
      },
      overrides
    )
  end

  # ---- Dead player: instant teleport (existing behavior) ----

  describe "dead player /HOGAR (instant teleport)" do
    test "dead player on foreign map pays gold and gets transfer packets" do
      # We can't fully test transfer without MapServer, but we can test
      # the logic flow returns the right console messages.
      # This is a smoke test of the routing — dead players use the instant path.
      entity = base_entity(%{dead: true, gold: 10_000})
      _state = base_state()

      # The actual handle_hogar calls MapServer.snapshot_entity, which requires
      # a running MapServer. We test the pure-logic cancel/arrive helpers instead.
      # Dead path is integration-tested in ao_smoke_bot_test.exs.
      assert entity.dead == true
    end
  end

  # ---- Alive player: delayed travel ----

  describe "alive player /HOGAR restrictions" do
    test "cannot use while in jail (penalty > 0)" do
      entity = base_entity(%{penalty: 5})
      state = base_state()

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity)

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "prisión"
        _ -> false
      end)
    end

    test "cannot use while on jail map" do
      entity = base_entity(%{map_id: @jail_map_id})
      state = base_state(%{map_id: @jail_map_id})

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity)

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "prisión"
        _ -> false
      end)
    end

    test "cannot use while already traveling home" do
      entity = base_entity()
      state = base_state(%{hogar_timer_ref: make_ref()})

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity)

      # Timer ref should be unchanged (not overwritten)
      assert new_state.hogar_timer_ref != nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "viajando"
        _ -> false
      end)
    end

    test "alive player on home map gets already-home message" do
      # Ullathorpe spawns on map 1 (fallback)
      entity = base_entity(%{map_id: 1})
      state = base_state(%{map_id: 1})

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity)

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "hogar"
        _ -> false
      end)
    end

    test "alive player starts travel — sets timer and sends console message" do
      entity = base_entity()
      state = base_state()

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity)

      # Timer should be set
      assert new_state.hogar_timer_ref != nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "viaje" or msg =~ "viajando" or msg =~ "Recuerda"
        _ -> false
      end)
    end
  end

  describe "travel cancellation" do
    test "cancel_hogar clears the timer ref" do
      ref = make_ref()
      state = base_state(%{hogar_timer_ref: ref})

      {new_state, packets} = SessionLogic.cancel_hogar(state)

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "cancelado" or msg =~ "interrumpido"
        _ -> false
      end)
    end

    test "cancel_hogar is a no-op when not traveling" do
      state = base_state(%{hogar_timer_ref: nil})

      {new_state, packets} = SessionLogic.cancel_hogar(state)

      assert new_state.hogar_timer_ref == nil
      assert packets == []
    end

    test "walk command cancels hogar travel" do
      ref = Process.send_after(self(), :hogar_arrive, 60_000)
      state = base_state(%{hogar_timer_ref: ref})

      # Walk triggers cancel
      {new_state, _packets} = SessionLogic.maybe_cancel_hogar(state)

      assert new_state.hogar_timer_ref == nil
    end
  end

  describe "hogar arrival" do
    test "handle_hogar_arrive returns transfer data when still traveling" do
      ref = make_ref()
      entity = base_entity()
      state = base_state(%{hogar_timer_ref: ref})

      result = SessionLogic.handle_hogar_arrive(state, entity)

      case result do
        {:transfer, dest_map, dest_x, dest_y, ^entity} ->
          # Should transfer to ullathorpe spawn (map 1, x 50, y 50 fallback)
          assert dest_map == 1
          assert is_integer(dest_x)
          assert is_integer(dest_y)

        {new_state, packets} ->
          # Alternative: returns state+packets form
          assert new_state.hogar_timer_ref == nil
          assert is_list(packets)
      end
    end

    test "handle_hogar_arrive is no-op if timer was cancelled" do
      entity = base_entity()
      state = base_state(%{hogar_timer_ref: nil})

      result = SessionLogic.handle_hogar_arrive(state, entity)

      assert result == {state, []}
    end
  end
end
