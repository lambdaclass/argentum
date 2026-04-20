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

  setup do
    previous = Application.get_env(:ao_tcp_gateway, :hogar_travel_delay_ms)

    Application.put_env(:ao_tcp_gateway, :hogar_travel_delay_ms, %{
      gm: 5_000,
      normal: 10_000,
      adventurer: 9_000,
      hero: 8_000,
      legend: 7_000
    })

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:ao_tcp_gateway, :hogar_travel_delay_ms)
      else
        Application.put_env(:ao_tcp_gateway, :hogar_travel_delay_ms, previous)
      end
    end)

    :ok
  end

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

    test "hogar_travel_delay returns normal bucket for non-GM default tier" do
      entity = base_entity(%{gm: false, user_tier: :normal})
      # Setup overrides config to 10_000 for this describe block
      assert SessionTransfer.hogar_travel_delay(entity) == 10_000
    end

    test "hogar_travel_delay returns adventurer bucket" do
      entity = base_entity(%{gm: false, user_tier: :adventurer})
      assert SessionTransfer.hogar_travel_delay(entity) == 9_000
    end

    test "hogar_travel_delay returns hero bucket" do
      entity = base_entity(%{gm: false, user_tier: :hero})
      assert SessionTransfer.hogar_travel_delay(entity) == 8_000
    end

    test "hogar_travel_delay returns legend bucket" do
      entity = base_entity(%{gm: false, user_tier: :legend})
      assert SessionTransfer.hogar_travel_delay(entity) == 7_000
    end
  end

  # ---- VB6 default timer values from Balance.dat ----
  # VB6 Balance.dat has HomeTimer=105 (seconds). Per-tier keys are absent,
  # so VB6 val("") returns 0 → patrons get instant teleport.

  describe "VB6 default hogar timer values (Balance.dat parity)" do
    setup do
      # Remove custom config to test the module defaults
      previous = Application.get_env(:ao_tcp_gateway, :hogar_travel_delay_ms)
      Application.delete_env(:ao_tcp_gateway, :hogar_travel_delay_ms)

      on_exit(fn ->
        if previous do
          Application.put_env(:ao_tcp_gateway, :hogar_travel_delay_ms, previous)
        end
      end)

      :ok
    end

    test "default normal timer is 105 seconds (VB6 HomeTimer=105)" do
      entity = base_entity(%{gm: false, user_tier: :normal})
      assert SessionTransfer.hogar_travel_delay(entity) == 105_000
    end

    test "default GM timer is 5 seconds" do
      entity = base_entity(%{gm: true})
      assert SessionTransfer.hogar_travel_delay(entity) == 5_000
    end

    test "default adventurer timer is 0 (instant, VB6 HomeTimerAdventurer missing)" do
      entity = base_entity(%{gm: false, user_tier: :adventurer})
      assert SessionTransfer.hogar_travel_delay(entity) == 0
    end

    test "default hero timer is 0 (instant, VB6 HomeTimerHero missing)" do
      entity = base_entity(%{gm: false, user_tier: :hero})
      assert SessionTransfer.hogar_travel_delay(entity) == 0
    end

    test "default legend timer is 0 (instant, VB6 HomeTimerLegend missing)" do
      entity = base_entity(%{gm: false, user_tier: :legend})
      assert SessionTransfer.hogar_travel_delay(entity) == 0
    end
  end
end
