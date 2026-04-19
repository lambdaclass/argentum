defmodule AoTcpGateway.GuildDisabledStubsTest do
  @moduledoc """
  Unit tests for VB6-parity disabled guild relation and election stubs.

  Task 20: Alliance/peace packets return "Relaciones de clan desactivadas por el momento."
  Task 46: Election packets return "Elecciones de clan desactivadas por el momento."

  These are direct SessionLogic.handle_command/2 unit tests that do not
  require map files or a running TCP server.
  """

  use ExUnit.Case, async: true

  alias AoTcpGateway.SessionLogic

  @relations_disabled "Relaciones de clan desactivadas por el momento."
  @elections_disabled "Elecciones de clan desactivadas por el momento."

  defp base_state do
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
    }
  end

  # ============================================================
  # Task 20: Guild relations disabled (alliance/peace)
  # ============================================================

  describe "guild_accept_peace (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_accept_peace, %{guild: "SomeGuild"}})

      assert [{:console_msg, %{message: @relations_disabled, font_index: 0}}] = packets
    end
  end

  describe "guild_reject_peace (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_reject_peace, %{guild: "SomeGuild"}})

      assert [{:console_msg, %{message: @relations_disabled, font_index: 0}}] = packets
    end
  end

  describe "guild_accept_alliance (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_accept_alliance, %{guild: "SomeGuild"}})

      assert [{:console_msg, %{message: @relations_disabled, font_index: 0}}] = packets
    end
  end

  describe "guild_reject_alliance (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_reject_alliance, %{guild: "SomeGuild"}})

      assert [{:console_msg, %{message: @relations_disabled, font_index: 0}}] = packets
    end
  end

  describe "guild_offer_peace (wired to GuildServer)" do
    test "delegates to GuildServer.propose_peace and returns empty packets" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_offer_peace, %{guild: "SomeGuild", proposal: "Let's be friends"}})

      assert packets == []
    end
  end

  describe "guild_offer_alliance (wired to GuildServer)" do
    test "delegates to GuildServer.propose_alliance and returns empty packets" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_offer_alliance, %{guild: "SomeGuild", proposal: "Unite!"}})

      assert packets == []
    end
  end

  describe "guild_alliance_details (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_alliance_details, %{guild: "SomeGuild"}})

      assert [{:console_msg, %{message: @relations_disabled, font_index: 0}}] = packets
    end
  end

  describe "guild_peace_details (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_peace_details, %{guild: "SomeGuild"}})

      assert [{:console_msg, %{message: @relations_disabled, font_index: 0}}] = packets
    end
  end

  describe "guild_alliance_prop_list (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_alliance_prop_list, %{}})

      assert [{:console_msg, %{message: @relations_disabled, font_index: 0}}] = packets
    end
  end

  describe "guild_peace_prop_list (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_peace_prop_list, %{}})

      assert [{:console_msg, %{message: @relations_disabled, font_index: 0}}] = packets
    end
  end

  # ============================================================
  # Task 46: Guild elections disabled
  # ============================================================

  describe "guild_open_elections (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_open_elections, %{}})

      assert [{:console_msg, %{message: @elections_disabled, font_index: 0}}] = packets
    end
  end

  describe "guild_vote (disabled)" do
    test "returns VB6 disabled message" do
      {_state, packets} =
        SessionLogic.handle_command(base_state(), {:guild_vote, %{vote: "CandidateName"}})

      assert [{:console_msg, %{message: @elections_disabled, font_index: 0}}] = packets
    end
  end

  # ============================================================
  # State preservation: disabled stubs must not mutate state
  # ============================================================

  describe "state preservation" do
    test "relation disabled stubs do not mutate state" do
      state = base_state()

      packets_to_test = [
        {:guild_accept_peace, %{guild: "X"}},
        {:guild_reject_peace, %{guild: "X"}},
        {:guild_accept_alliance, %{guild: "X"}},
        {:guild_reject_alliance, %{guild: "X"}},
        {:guild_offer_peace, %{guild: "X", proposal: "Y"}},
        {:guild_offer_alliance, %{guild: "X", proposal: "Y"}},
        {:guild_alliance_details, %{guild: "X"}},
        {:guild_peace_details, %{guild: "X"}},
        {:guild_alliance_prop_list, %{}},
        {:guild_peace_prop_list, %{}},
        {:guild_open_elections, %{}},
        {:guild_vote, %{vote: "X"}}
      ]

      for packet <- packets_to_test do
        {returned_state, _packets} = SessionLogic.handle_command(state, packet)
        assert returned_state == state, "State mutated for #{inspect(elem(packet, 0))}"
      end
    end
  end
end
