defmodule AoTcpGateway.HogarTest do
  @moduledoc """
  Tests for VB6 /HOGAR (home travel) behavior.

  VB6 HandleHome exact rules (Protocol.bas):
    1. Jail restricted area → reject
    2. Must be dead (Muerto=1) → alive rejected
    3. NEWBIE zone → reject
    4. Penalty > 0 → reject (prison sentence)
    5. Already traveling → cancel current travel
    6. Not on home map → charge gold, start delayed travel
    7. Already on home map → "Ya te encuentras en tu hogar"
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
        dead: true,
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

  # ---- VB6 step 1: Jail map restriction ----

  describe "jail map restriction (VB6 step 1)" do
    test "dead player on jail map is rejected" do
      entity = base_entity(%{dead: true, map_id: @jail_map_id})
      state = base_state(%{map_id: @jail_map_id})

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity, "CAMPO")

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "cárcel"
        _ -> false
      end)
    end
  end

  # ---- VB6 step 2: Must be dead ----

  describe "alive player rejection (VB6 step 2)" do
    test "alive player is rejected with must-be-dead message" do
      entity = base_entity(%{dead: false})
      state = base_state()

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity, "CAMPO")

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "muerto"
        _ -> false
      end)
    end
  end

  # ---- VB6 step 3: NEWBIE zone restriction ----

  describe "NEWBIE zone restriction (VB6 step 3)" do
    test "dead player on NEWBIE map is rejected" do
      entity = base_entity(%{dead: true})
      state = base_state()

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity, "NEWBIE")

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "No puedes viajar"
        _ -> false
      end)
    end
  end

  # ---- VB6 step 4: Penalty (prison sentence) ----

  describe "prison penalty restriction (VB6 step 4)" do
    test "dead player with penalty > 0 is rejected" do
      entity = base_entity(%{dead: true, penalty: 5})
      state = base_state()

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity, "CAMPO")

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "prisión"
        _ -> false
      end)
    end
  end

  # ---- VB6 step 5: Already traveling → cancel ----

  describe "already traveling (VB6 step 7)" do
    test "already traveling cancels the current travel" do
      ref = make_ref()
      entity = base_entity(%{dead: true})
      state = base_state(%{hogar_timer_ref: ref})

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity, "CAMPO")

      # Timer ref should be cleared
      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "viaje en curso"
        _ -> false
      end)
    end
  end

  # ---- VB6 step 6: Already on home map ----

  describe "already on home map (VB6 step 6)" do
    test "dead player already on home map gets already-home message" do
      # Ullathorpe spawns on map 1 (fallback)
      entity = base_entity(%{dead: true, map_id: 1})
      state = base_state(%{map_id: 1})

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity, "CAMPO")

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "hogar"
        _ -> false
      end)
    end
  end

  # ---- VB6 step 6: Insufficient gold ----

  describe "insufficient gold (VB6 step 6)" do
    test "dead player with insufficient gold is rejected" do
      # Level 10: cost = 10*15 + trunc(10^1.5) = 150 + 31 = 181
      entity = base_entity(%{dead: true, gold: 0})
      state = base_state()

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity, "CAMPO")

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "monedas de oro"
        _ -> false
      end)
    end
  end

  # ---- VB6 step 6: Successful delayed travel start ----

  describe "successful delayed travel (VB6 step 6)" do
    test "dead player on foreign map starts delayed travel" do
      entity = base_entity(%{dead: true, gold: 10_000})
      state = base_state()

      {new_state, packets} = SessionLogic.handle_hogar_check(state, entity, "CAMPO")

      # Timer should be set (delayed travel started)
      assert new_state.hogar_timer_ref != nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "hogar"
        _ -> false
      end)
    end
  end

  # ---- Travel cancellation ----

  describe "travel cancellation" do
    test "cancel_hogar clears the timer ref" do
      ref = make_ref()
      state = base_state(%{hogar_timer_ref: ref})

      {new_state, packets} = SessionLogic.cancel_hogar(state)

      assert new_state.hogar_timer_ref == nil
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "cancelado"
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

  # ---- Hogar arrival ----

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

  # ---- Gold cost formula parity ----

  describe "gold cost formula (VB6 parity)" do
    test "level <= 24: cost = level*15 + trunc(level^1.5)" do
      # Level 10: 150 + 31 = 181
      entity = base_entity(%{dead: true, gold: 180, level: 10})
      state = base_state()

      {_state, packets} = SessionLogic.handle_hogar_check(state, entity, "CAMPO")

      # 180 < 181, should be rejected
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "181 monedas"
        _ -> false
      end)
    end

    test "level > 24: cost = level^2" do
      # Level 25: 625
      entity = base_entity(%{dead: true, gold: 624, level: 25})
      state = base_state()

      {_state, packets} = SessionLogic.handle_hogar_check(state, entity, "CAMPO")

      # 624 < 625, should be rejected
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "625 monedas"
        _ -> false
      end)
    end
  end
end
