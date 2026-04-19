defmodule Arena.HogarDriftTest do
  @moduledoc """
  Drift #27: /HOGAR duel-block and GM timer parity.

  VB6 HandleHome (Protocol.bas:7414-7480):
    - Blocks /HOGAR when player is EnReto (in duel) with specific message
    - GM players get 5-second travel delay
    - Non-GM user types have configurable timers (HomeTimerAdventurer, etc.)
      We only distinguish GM vs non-GM for now.

  VB6 goHome (Hogar.bas:37-50):
    - EsGM → TimerBarra = 5  (5 seconds)
    - Otherwise → per-type timers (Adventurer, Hero, Legend, default)
  """
  use ExUnit.Case, async: true

  alias AoTcpGateway.SessionTransfer
  alias AoEntities.PlayerEntity

  # ---- Helpers (same pattern as hogar_test.exs) ----

  defp base_entity(overrides \\ %{}) do
    Map.merge(
      %PlayerEntity{
        char_id: 8001,
        name: "DriftTester",
        account_id: "acct_drift27",
        x: 50,
        y: 50,
        level: 10,
        gold: 10_000,
        dead: true,
        home_city: :ullathorpe,
        penalty: 0,
        map_id: 300,
        in_duel: false,
        gm: false
      },
      overrides
    )
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 8001,
        map_id: 300,
        account_id: "acct_drift27",
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        hogar_timer_ref: nil
      },
      overrides
    )
  end

  # ---- Drift: Duel (EnReto) blocks /HOGAR ----

  describe "duel (EnReto) blocks /HOGAR (VB6 Protocol.bas:7439)" do
    test "dead player in duel is rejected with duel-specific message" do
      entity = base_entity(%{dead: true, in_duel: true})
      state = base_state()

      {new_state, packets} = SessionTransfer.handle_hogar_check(state, entity, "CAMPO")

      # Must NOT start a timer
      assert new_state.hogar_timer_ref == nil

      # Must get the duel rejection message (VB6: MSG_NO_PODES_REGRESAR_DESDE_RETO...)
      assert Enum.any?(packets, fn
        {:console_msg, %{message: msg}} -> msg =~ "reto" or msg =~ "ABANDONAR"
        _ -> false
      end)
    end

    test "dead player NOT in duel can still use /HOGAR" do
      entity = base_entity(%{dead: true, in_duel: false})
      state = base_state()

      {new_state, _packets} = SessionTransfer.handle_hogar_check(state, entity, "CAMPO")

      # Timer should be set (travel started)
      assert new_state.hogar_timer_ref != nil
    end
  end

  # ---- Drift: GM gets 5s timer, non-GM gets 10s ----

  describe "GM travel delay (VB6 Hogar.bas:37-50)" do
    test "hogar_travel_delay returns 5_000 for GM" do
      entity = base_entity(%{gm: true})
      assert SessionTransfer.hogar_travel_delay(entity) == 5_000
    end

    test "hogar_travel_delay returns 10_000 for non-GM" do
      entity = base_entity(%{gm: false})
      # VB6 has per-type timers (Adventurer/Hero/Legend) but we default to 10s
      assert SessionTransfer.hogar_travel_delay(entity) == 10_000
    end
  end
end
