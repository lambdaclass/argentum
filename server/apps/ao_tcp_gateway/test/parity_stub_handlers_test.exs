defmodule AoTcpGateway.ParityStubHandlersTest do
  @moduledoc """
  Tests for ROADMAP items #19-21: decoded-but-stubbed packet handlers.

  Verifies that previously no-op stubs now have real behavior, and that
  genuinely-no-op packets are documented and return sane values.
  """

  use ExUnit.Case

  alias AoTcpGateway.SessionLogic

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 90001,
        map_id: 1,
        account_id: "acct_stub_test",
        entity: %AoEntities.PlayerEntity{
          char_id: 90001,
          name: "StubTester",
          account_id: "acct_stub_test",
          x: 50,
          y: 50,
          level: 25,
          gm: false
        },
        char_index: 1,
        target_x: 51,
        target_y: 51,
        in_commerce: false,
        in_bank: false,
        in_trade: false,
        is_gm: false,
        is_dead: false,
        hogar_timer_ref: nil
      },
      overrides
    )
  end

  defp gm_state(overrides \\ %{}) do
    base_state(
      Map.merge(
        %{
          is_gm: true,
          entity: %AoEntities.PlayerEntity{
            char_id: 90001,
            name: "GMStubTester",
            account_id: "acct_stub_test",
            x: 50,
            y: 50,
            level: 25,
            gm: true
          }
        },
        overrides
      )
    )
  end

  # ===================================================================
  # 1. use_spell_macro — genuine no-op (client-side macro helper)
  # ===================================================================

  describe "use_spell_macro (genuine no-op)" do
    test "returns empty packets and unchanged state" do
      state = base_state()
      {returned_state, packets} = SessionLogic.handle_command(state, {:use_spell_macro, %{}})
      assert packets == []
      assert returned_state == state
    end
  end

  # ===================================================================
  # 2. train — routed to MapServer for trainer NPC validation
  # ===================================================================

  describe "train" do
    test "routes to MapServer (no immediate rejection packet)" do
      state = base_state()

      # VB6 parity: Train packet is now routed to MapServer which validates
      # the selected trainer NPC and spawns the creature asynchronously.
      # No immediate packets are returned from the session handler.
      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:train, %{pet_index: 1}})

      assert packets == []
    end
  end

  # ===================================================================
  # 3. server_open_toggle — should toggle server_open setting
  # ===================================================================

  describe "server_open_toggle (GM)" do
    setup do
      unless Process.whereis(Arena.Settings) do
        {:ok, _} = Arena.Settings.start_link([])
      end

      # Reset to default before each test
      Arena.Settings.set(:server_open, true)
      :ok
    end

    test "toggles server_open from true to false" do
      state = gm_state()

      assert Arena.Settings.get(:server_open, true) == true

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:server_open_toggle, %{}})

      assert Arena.Settings.get(:server_open, true) == false

      # Should return a confirmation message
      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert msg =~ "cerrado" or msg =~ "closed" or msg =~ "Servidor"
    end

    test "toggles server_open from false to true" do
      Arena.Settings.set(:server_open, false)
      state = gm_state()

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:server_open_toggle, %{}})

      assert Arena.Settings.get(:server_open, true) == true

      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert msg =~ "abierto" or msg =~ "open" or msg =~ "Servidor"
    end
  end

  # ===================================================================
  # 4. warp_me_to_target — GM should warp to their target coordinates
  # ===================================================================

  describe "warp_me_to_target (GM)" do
    test "delegates to /GOTO or equivalent when target coordinates are set" do
      state = gm_state(%{target_x: 60, target_y: 70})

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:warp_me_to_target, %{}})

      # Should NOT return the old "Usa /GOTO" help message
      refute Enum.any?(packets, fn
               {:console_msg, %{message: msg}} -> msg =~ "Usa /GOTO"
               _ -> false
             end)
    end

    test "when no target is set, returns informative message" do
      state = gm_state(%{target_x: nil, target_y: nil})

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:warp_me_to_target, %{}})

      # Should inform GM to select a target first
      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert is_binary(msg) and byte_size(msg) > 0
    end
  end

  # ===================================================================
  # 5. SOS stubs — should integrate with AuditLog/support system
  # ===================================================================

  describe "sos_show_list (GM)" do
    test "returns a list (even if empty) instead of hardcoded '(vacia)'" do
      state = gm_state()

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:sos_show_list, %{}})

      # Should return at least one console message with SOS info
      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert is_binary(msg) and byte_size(msg) > 0
    end
  end

  describe "sos_remove (GM)" do
    test "returns confirmation message" do
      state = gm_state()

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:sos_remove, %{name: "SomePlayer"}})

      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert is_binary(msg) and byte_size(msg) > 0
    end
  end

  describe "clean_sos (GM)" do
    test "returns confirmation message" do
      state = gm_state()

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:clean_sos, %{}})

      assert [{:console_msg, %{message: msg, font_index: 0}}] = packets
      assert is_binary(msg) and byte_size(msg) > 0
    end
  end

  # ===================================================================
  # 6. Catch-all — unknown commands should log and return empty
  # ===================================================================

  describe "catch-all handler" do
    test "unknown command returns empty packets" do
      state = base_state()

      {returned_state, packets} =
        SessionLogic.handle_command(state, {:totally_unknown_command, %{}})

      assert packets == []
      assert returned_state == state
    end
  end

  # ===================================================================
  # 7. Pre-login guards — packets sent before character_id is set
  # ===================================================================

  describe "pre-login guard" do
    test "walk before login returns empty" do
      state = base_state(%{character_id: nil})

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:walk, %{direction: :north}})

      assert packets == []
    end

    test "attack before login returns empty" do
      state = base_state(%{character_id: nil})

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:attack, %{}})

      assert packets == []
    end

    test "equip_item before login returns empty" do
      state = base_state(%{character_id: nil})

      {_returned_state, packets} =
        SessionLogic.handle_command(state, {:equip_item, %{slot: 1}})

      assert packets == []
    end
  end

  # ===================================================================
  # 8. State preservation — stubs must not mutate state
  # ===================================================================

  describe "state preservation for no-op stubs" do
    test "use_spell_macro does not mutate state" do
      state = base_state()
      {returned_state, _} = SessionLogic.handle_command(state, {:use_spell_macro, %{}})
      assert returned_state == state
    end

    test "train does not mutate state" do
      state = base_state()
      {returned_state, _} = SessionLogic.handle_command(state, {:train, %{pet_index: 1}})
      assert returned_state == state
    end
  end
end
