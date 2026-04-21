defmodule Arena.ChatColorHandlerTest do
  @moduledoc """
  VB6 parity test for HandleChatColor (Protocol.bas:5548-5561).

    Public Sub HandleChatColor(ByVal UserIndex As Integer)
        With UserList(UserIndex)
            Color = RGB(reader.ReadInt8(), reader.ReadInt8(), reader.ReadInt8())
            If EsGM(UserIndex) Then
                .flags.ChatColor = Color
            End If
        End With
    End Sub

  Non-GMs are silently ignored; GMs persist the color to their entity.
  """
  use ExUnit.Case, async: true

  alias AoEntities.PlayerEntity
  alias Arena.Map.MapServer
  alias AoTcpGateway.SessionLogic

  import Arena.Test.MapStateFactory

  # ── Direct handle_cast unit test (avoids needing a running GenServer) ──────

  describe "MapServer.handle_cast({:set_chat_color, ...}) — VB6 ChatColor mutation" do
    test "GM entity gets chat_color updated" do
      gm =
        %PlayerEntity{
          char_id: 1,
          name: "GMChatter",
          account_id: "a",
          x: 50,
          y: 50,
          gm: true,
          gm_level: :admin,
          chat_color: {255, 255, 255}
        }

      state = map_state(players: %{1 => gm})

      assert {:noreply, new_state} =
               MapServer.handle_cast({:set_chat_color, 1, {252, 195, 0}}, state)

      assert Map.fetch!(new_state.players, 1).chat_color == {252, 195, 0}
    end

    test "unknown char_id leaves state unchanged" do
      state = map_state(players: %{})

      assert {:noreply, ^state} =
               MapServer.handle_cast({:set_chat_color, 999, {10, 20, 30}}, state)
    end
  end

  # ── Session-layer GM gate (VB6 HandleChatColor's EsGM check) ───────────────

  describe "SessionLogic.handle_command :chat_color — GM gate" do
    test "non-GM receives insufficient-privilege console message" do
      non_gm = %PlayerEntity{
        char_id: 42,
        name: "Peasant",
        account_id: "a",
        x: 50,
        y: 50,
        gm: false,
        gm_level: nil,
        chat_color: {255, 255, 255}
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

      {_state, packets} =
        SessionLogic.handle_command(state, {:chat_color, %{r: 252, g: 195, b: 0}})

      assert packets == [
               {:console_msg, %{message: "No tienes privilegios de GM.", font_index: 0}}
             ]
    end
  end

  # ── PlayerEntity struct default ─────────────────────────────────────────────

  describe "PlayerEntity.chat_color default" do
    test "is {255, 255, 255} (vbWhite) by default" do
      assert %PlayerEntity{}.chat_color == {255, 255, 255}
    end
  end
end
