defmodule AoTcpGateway.RoleMasterRequestTest do
  @moduledoc """
  Tests for the role_master_request packet handler.

  In VB6 Argentum Online, RoleMasterRequest (opcode 63) is sent by a GM
  to open the GM panel ("Maestro de Roles"). The server responds with
  ShowGMPanelForm. Non-GM users are denied access.
  """
  use ExUnit.Case, async: true

  alias AoTcpGateway.SessionLogic

  defp gm_state do
    %{
      character_id: 70001,
      map_id: 1,
      account_id: "acct_gm_role",
      entity: nil,
      char_index: 1,
      target_x: nil,
      target_y: nil,
      is_gm: true
    }
  end

  defp non_gm_state do
    %{gm_state() | character_id: 70002, is_gm: false}
  end

  describe "role_master_request" do
    test "GM receives show_gm_panel_form response" do
      {_state, packets} =
        SessionLogic.handle_command(gm_state(), {:role_master_request, %{}})

      assert packets == [{:show_gm_panel_form, %{}}]
    end

    test "non-GM receives not-authorized message" do
      {_state, packets} =
        SessionLogic.handle_command(non_gm_state(), {:role_master_request, %{}})

      assert packets == [{:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}]
    end

    test "unauthenticated session (nil character_id) is silently ignored" do
      state = %{gm_state() | character_id: nil}

      {_state, packets} =
        SessionLogic.handle_command(state, {:role_master_request, %{}})

      assert packets == []
    end

    test "show_gm_panel_form encodes to packet ID 84 with no payload" do
      encoded = AoProtocol.Server.Encoder.encode({:show_gm_panel_form, %{}})
      assert <<84::little-16>> = encoded
    end
  end
end
