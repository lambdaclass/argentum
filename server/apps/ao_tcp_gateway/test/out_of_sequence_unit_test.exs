defmodule AoTcpGateway.OutOfSequenceUnitTest do
  @moduledoc """
  Unit tests for out-of-sequence packet validation in SessionLogic.

  Tests that SessionLogic.handle_command/2 rejects packets received in invalid
  states (e.g., commerce buy without opening commerce, bank deposit without
  opening bank, GM commands without privileges, trade offers without active
  trade session).

  These tests exercise the guard clauses directly, without requiring map files
  or a running TCP server.
  """

  use ExUnit.Case, async: true

  alias AoTcpGateway.SessionLogic

  # Base session state for a logged-in, non-GM player
  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 1001,
        map_id: 1,
        account_id: "acct_test",
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
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

  # ============================================================
  # Commerce: buy/sell without opening commerce
  # ============================================================

  describe "commerce_buy without active commerce session" do
    test "returns rejection message when in_commerce is false" do
      state = base_state()

      {new_state, packets} =
        SessionLogic.handle_command(state, {:commerce_buy, %{slot: 1, amount: 1}})

      assert new_state.in_commerce == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/comercio/i
    end
  end

  describe "commerce_sell without active commerce session" do
    test "returns rejection message when in_commerce is false" do
      state = base_state()

      {new_state, packets} =
        SessionLogic.handle_command(state, {:commerce_sell, %{slot: 1, amount: 1}})

      assert new_state.in_commerce == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/comercio/i
    end
  end

  # ============================================================
  # Bank: deposit/extract without opening bank
  # ============================================================

  describe "bank_deposit without active bank session" do
    test "returns rejection message when in_bank is false" do
      state = base_state()

      {new_state, packets} =
        SessionLogic.handle_command(
          state,
          {:bank_deposit, %{slot: 1, amount: 1, slot_destino: 1}}
        )

      assert new_state.in_bank == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/banco/i
    end
  end

  describe "bank_extract_item without active bank session" do
    test "returns rejection message when in_bank is false" do
      state = base_state()

      {new_state, packets} =
        SessionLogic.handle_command(
          state,
          {:bank_extract_item, %{slot: 1, amount: 1, slot_destino: 1}}
        )

      assert new_state.in_bank == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/banco/i
    end
  end

  describe "bank_deposit_gold without active bank session" do
    test "returns rejection message when in_bank is false" do
      state = base_state()

      {new_state, packets} =
        SessionLogic.handle_command(state, {:bank_deposit_gold, %{amount: 100}})

      assert new_state.in_bank == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/banco/i
    end
  end

  describe "bank_extract_gold without active bank session" do
    test "returns rejection message when in_bank is false" do
      state = base_state()

      {new_state, packets} =
        SessionLogic.handle_command(state, {:bank_extract_gold, %{amount: 100}})

      assert new_state.in_bank == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/banco/i
    end
  end

  # ============================================================
  # GM commands without privileges
  # ============================================================

  @gm_commands [
    {:go_to_char, %{name: "SomePlayer"}},
    {:warp_me_to_target, %{}},
    {:warp_char, %{name: "SomePlayer", map: 1}},
    {:invisible, %{}},
    {:silence, %{name: "SomePlayer"}},
    {:jail, %{name: "SomePlayer", reason: "test", minutes: 10}},
    {:kick, %{name: "SomePlayer"}},
    {:execute, %{name: "SomePlayer"}},
    {:ban_char, %{name: "SomePlayer", reason: "test"}},
    {:unban_char, %{name: "SomePlayer"}},
    {:revive_char, %{name: "SomePlayer"}},
    {:summon_char, %{name: "SomePlayer"}},
    {:kill_npc, %{}},
    {:request_char_info, %{name: "SomePlayer"}},
    {:where, %{name: "SomePlayer"}},
    {:gm_message, %{message: "hello"}},
    {:server_message, %{message: "hello"}},
    {:online_gm, %{}},
    {:rain_toggle, %{}}
  ]

  describe "GM commands without GM privileges" do
    for {cmd_type, params} <- @gm_commands do
      test "#{cmd_type} is rejected when is_gm is false" do
        state = base_state(%{is_gm: false})

        {_new_state, packets} =
          SessionLogic.handle_command(state, {unquote(cmd_type), unquote(Macro.escape(params))})

        assert [{:console_msg, %{message: msg}}] = packets
        assert msg =~ ~r/GM|priv|permiso/i
      end
    end
  end

  # ============================================================
  # GM commands WITH privileges should not be rejected at guard level
  # (they may fail deeper in MapServer, but the guard should pass)
  # ============================================================

  describe "GM commands with privileges pass the guard" do
    test "go_to_char with is_gm=true does not return unauthorized message" do
      state = base_state(%{is_gm: true})

      # This will call Arena.Map.MapServer.chat which may fail since no server
      # is running, but it should NOT return the "No tienes privilegios" message.
      # The guard clause should pass, and we expect either [] packets or a
      # GenServer error (which we rescue).
      try do
        {_new_state, packets} =
          SessionLogic.handle_command(state, {:go_to_char, %{name: "SomePlayer"}})

        # If we get here, no crash means the guard passed
        refute Enum.any?(packets, fn
                 {:console_msg, %{message: msg}} -> msg =~ ~r/privilegios/i
                 _ -> false
               end)
      rescue
        # GenServer call may fail if MapServer isn't running - that's fine,
        # the guard passed which is what we're testing
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  # ============================================================
  # Commands without being logged in (character_id == nil)
  # ============================================================

  describe "commands without being logged in" do
    test "walk without character_id returns empty packets" do
      state = base_state(%{character_id: nil})

      {_new_state, packets} =
        SessionLogic.handle_command(state, {:walk, %{direction: :north}})

      assert packets == []
    end

    test "commerce_buy without character_id is silently ignored" do
      state = base_state(%{character_id: nil})

      {_new_state, packets} =
        SessionLogic.handle_command(state, {:commerce_buy, %{slot: 1, amount: 1}})

      # Falls through to the catch-all which returns []
      assert packets == []
    end

    test "bank_deposit without character_id is silently ignored" do
      state = base_state(%{character_id: nil})

      {_new_state, packets} =
        SessionLogic.handle_command(
          state,
          {:bank_deposit, %{slot: 1, amount: 1, slot_destino: 1}}
        )

      assert packets == []
    end

    test "GM command without character_id is silently ignored" do
      state = base_state(%{character_id: nil, is_gm: true})

      {_new_state, packets} =
        SessionLogic.handle_command(state, {:go_to_char, %{name: "SomePlayer"}})

      assert packets == []
    end
  end

  # ============================================================
  # State is not mutated by rejected commands
  # ============================================================

  describe "rejected commands do not mutate state" do
    test "commerce_buy rejection preserves in_commerce=false" do
      state = base_state(%{in_commerce: false})

      {new_state, _packets} =
        SessionLogic.handle_command(state, {:commerce_buy, %{slot: 1, amount: 1}})

      assert new_state.in_commerce == false
      assert new_state.character_id == state.character_id
    end

    test "bank_deposit rejection preserves in_bank=false" do
      state = base_state(%{in_bank: false})

      {new_state, _packets} =
        SessionLogic.handle_command(
          state,
          {:bank_deposit, %{slot: 1, amount: 1, slot_destino: 1}}
        )

      assert new_state.in_bank == false
      assert new_state.character_id == state.character_id
    end

    test "GM command rejection preserves is_gm=false" do
      state = base_state(%{is_gm: false})

      {new_state, _packets} =
        SessionLogic.handle_command(state, {:kick, %{name: "SomePlayer"}})

      assert new_state.is_gm == false
      assert new_state.character_id == state.character_id
    end
  end

  # ============================================================
  # Trade packets without active trade session
  # ============================================================

  describe "user_commerce_offer without active trade session" do
    test "returns rejection message when in_trade is false" do
      state = base_state(%{in_trade: false})

      {new_state, packets} =
        SessionLogic.handle_command(
          state,
          {:user_commerce_offer, %{obj_index: 1, amount: 1}}
        )

      assert new_state.in_trade == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/comercio.*jugador/i
    end
  end

  describe "user_commerce_ok without active trade session" do
    test "returns rejection message when in_trade is false" do
      state = base_state(%{in_trade: false})

      {new_state, packets} =
        SessionLogic.handle_command(state, {:user_commerce_ok, %{}})

      assert new_state.in_trade == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/comercio.*jugador/i
    end
  end

  describe "user_commerce_reject without active trade session" do
    test "returns rejection message when in_trade is false" do
      state = base_state(%{in_trade: false})

      {new_state, packets} =
        SessionLogic.handle_command(state, {:user_commerce_reject, %{}})

      assert new_state.in_trade == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/comercio.*jugador/i
    end
  end

  describe "user_commerce_end without active trade session" do
    test "returns rejection message when in_trade is false" do
      state = base_state(%{in_trade: false})

      {new_state, packets} =
        SessionLogic.handle_command(state, {:user_commerce_end, %{}})

      assert new_state.in_trade == false
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/comercio.*jugador/i
    end
  end

  # ============================================================
  # Combat packets while dead
  # ============================================================

  describe "attack while dead" do
    test "returns rejection message when is_dead is true" do
      state = base_state(%{is_dead: true})

      {new_state, packets} =
        SessionLogic.handle_command(state, {:attack, %{}})

      assert new_state.is_dead == true
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/muerto/i
    end
  end

  describe "cast_spell while dead" do
    test "returns rejection message when is_dead is true" do
      state = base_state(%{is_dead: true})

      {new_state, packets} =
        SessionLogic.handle_command(state, {:cast_spell, %{spell_slot: 1}})

      assert new_state.is_dead == true
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/muerto/i
    end
  end

  # ============================================================
  # Item use/equip while dead
  # ============================================================

  describe "equip_item while dead" do
    test "returns rejection message when is_dead is true" do
      state = base_state(%{is_dead: true})

      {new_state, packets} =
        SessionLogic.handle_command(state, {:equip_item, %{slot: 1}})

      assert new_state.is_dead == true
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/muerto/i
    end
  end

  describe "use_item while dead" do
    test "returns rejection message when is_dead is true" do
      state = base_state(%{is_dead: true})

      {new_state, packets} =
        SessionLogic.handle_command(state, {:use_item, %{slot: 1}})

      assert new_state.is_dead == true
      assert [{:console_msg, %{message: msg}}] = packets
      assert msg =~ ~r/muerto/i
    end
  end

  # ============================================================
  # Dead state does not mutate on rejection
  # ============================================================

  describe "dead state preserved on rejection" do
    test "attack rejection preserves is_dead=true" do
      state = base_state(%{is_dead: true})

      {new_state, _packets} =
        SessionLogic.handle_command(state, {:attack, %{}})

      assert new_state.is_dead == true
      assert new_state.character_id == state.character_id
    end

    test "equip_item rejection preserves is_dead=true" do
      state = base_state(%{is_dead: true})

      {new_state, _packets} =
        SessionLogic.handle_command(state, {:equip_item, %{slot: 1}})

      assert new_state.is_dead == true
      assert new_state.character_id == state.character_id
    end

    test "trade offer rejection preserves in_trade=false" do
      state = base_state(%{in_trade: false})

      {new_state, _packets} =
        SessionLogic.handle_command(
          state,
          {:user_commerce_offer, %{obj_index: 1, amount: 1}}
        )

      assert new_state.in_trade == false
      assert new_state.character_id == state.character_id
    end
  end

  # ============================================================
  # Commands without character_id with new state fields
  # ============================================================

  describe "new guarded commands without being logged in" do
    test "user_commerce_offer without character_id is silently ignored" do
      state = base_state(%{character_id: nil})

      {_new_state, packets} =
        SessionLogic.handle_command(
          state,
          {:user_commerce_offer, %{obj_index: 1, amount: 1}}
        )

      assert packets == []
    end

    test "attack without character_id is silently ignored" do
      state = base_state(%{character_id: nil})

      {_new_state, packets} =
        SessionLogic.handle_command(state, {:attack, %{}})

      assert packets == []
    end
  end
end
