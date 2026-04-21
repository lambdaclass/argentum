defmodule Arena.GmPanelHandlerTest do
  @moduledoc """
  VB6 parity test for HandleGMPanel (Protocol_GmCommands.bas:764).

    Public Sub HandleGMPanel(ByVal UserIndex As Integer)
        With UserList(UserIndex)
            If .flags.Privilegios And e_PlayerType.User Then Exit Sub
            Call WriteShowGMPanelForm(UserIndex)
        End With
    End Sub

  Non-GMs are silently ignored (the session-layer GM gate returns the
  standard rejection console message for this port). GMs get the
  eShowGMPanelForm packet (VB6 Protocol_Writes.bas:2605) with:
    head(Int16) + body(Int16) + casco_anim(Int16) + weapon_anim(Int16) + shield_anim(Int16)
  """
  use ExUnit.Case, async: true

  alias AoEntities.PlayerEntity
  alias AoProtocol.PacketIds
  alias Arena.Map.MapServer
  alias AoTcpGateway.SessionLogic

  import Arena.Test.MapStateFactory

  # ── Direct handle_cast unit test (avoids needing a running GenServer) ──────

  describe "MapServer.handle_cast({:gm_panel_request, char_id}, state)" do
    test "GM entity receives eShowGMPanelForm with appearance fields populated" do
      gm =
        %PlayerEntity{
          char_id: 1,
          name: "GMPanelUser",
          account_id: "a",
          x: 50,
          y: 50,
          gm: true,
          gm_level: :admin,
          head_id: 100,
          body_id: 200,
          equipment: %{
            weapon: 301,
            shield: 302,
            helmet: 303,
            armor: nil,
            ring: nil,
            municion: nil,
            saddle: nil
          }
        }

      state = map_state(players: %{1 => gm}, sessions: %{1 => self()})

      assert {:noreply, ^state} = MapServer.handle_cast({:gm_panel_request, 1}, state)

      assert_receive {:send_raw, raw}

      # Verify the packet header matches eShowGMPanelForm (ID 84) and payload
      # contains head(200=0xC8), body(100... wait VB6 order is head then body).
      # VB6 Protocol_Writes.bas:2605: head, body, casco_anim, weapon_anim, shield_anim.
      expected =
        <<PacketIds.Server.show_gm_panel_form()::little-signed-16,
          100::little-signed-16,
          200::little-signed-16,
          303::little-signed-16,
          301::little-signed-16,
          302::little-signed-16>>

      assert raw == expected
    end

    test "missing equipment slots default to 0" do
      gm =
        %PlayerEntity{
          char_id: 1,
          name: "BareGM",
          account_id: "a",
          x: 50,
          y: 50,
          gm: true,
          gm_level: :dios,
          head_id: 5,
          body_id: 7,
          equipment: %{weapon: nil, shield: nil, helmet: nil}
        }

      state = map_state(players: %{1 => gm}, sessions: %{1 => self()})

      assert {:noreply, ^state} = MapServer.handle_cast({:gm_panel_request, 1}, state)
      assert_receive {:send_raw, raw}

      expected =
        <<PacketIds.Server.show_gm_panel_form()::little-signed-16,
          5::little-signed-16,
          7::little-signed-16,
          0::little-signed-16,
          0::little-signed-16,
          0::little-signed-16>>

      assert raw == expected
    end

    test "unknown char_id leaves state unchanged and sends nothing" do
      state = map_state(players: %{}, sessions: %{})

      assert {:noreply, ^state} = MapServer.handle_cast({:gm_panel_request, 999}, state)
      refute_receive {:send_raw, _}, 50
    end
  end

  # ── Session-layer GM gate (VB6 HandleGMPanel's User-privilege check) ──────

  describe "SessionLogic.handle_command :gm_panel_request — GM gate" do
    test "non-GM receives insufficient-privilege console message" do
      non_gm = %PlayerEntity{
        char_id: 42,
        name: "Peasant",
        account_id: "a",
        x: 50,
        y: 50,
        gm: false,
        gm_level: nil
      }

      state = %{
        character_id: 42,
        map_id: 1,
        account_id: "a",
        entity: non_gm,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        is_gm: false
      }

      {_state, packets} = SessionLogic.handle_command(state, {:gm_panel_request, %{}})

      assert packets == [
               {:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}
             ]
    end
  end
end
