defmodule AoTcpGateway.MarriageTest do
  @moduledoc """
  Tests for the VB6 marriage system (/PROPONER, /DIVORCIAR).

  VB6 behavior (Protocol.bas HandleCasamiento):
  1. Both players must be on the same map near a priest (Revividor NPC)
  2. Cannot marry yourself
  3. Cannot marry if already married
  4. Target cannot be already married
  5. Mutual proposal completes the marriage
  6. /DIVORCIAR clears spouse on both sides
  """
  use ExUnit.Case, async: true

  alias AoTcpGateway.SessionLogic

  # ---- Command parsing tests ----

  describe "parse_marriage_command/1" do
    test "/PROPONER <name> parses as propose" do
      assert SessionLogic.parse_marriage_command("/PROPONER Gandalf") == {:propose, "Gandalf"}
    end

    test "/proponer is case-insensitive" do
      assert SessionLogic.parse_marriage_command("/proponer Gandalf") == {:propose, "Gandalf"}
    end

    test "/DIVORCIAR parses as divorce" do
      assert SessionLogic.parse_marriage_command("/DIVORCIAR") == :divorce
    end

    test "/divorciar is case-insensitive" do
      assert SessionLogic.parse_marriage_command("/divorciar") == :divorce
    end

    test "non-marriage command returns :not_marriage_command" do
      assert SessionLogic.parse_marriage_command("/HOGAR") == :not_marriage_command
      assert SessionLogic.parse_marriage_command("hello") == :not_marriage_command
    end

    test "/PROPONER preserves original case of target name" do
      assert SessionLogic.parse_marriage_command("/PROPONER CaseMixed") == {:propose, "CaseMixed"}
    end
  end

  # ---- Marriage logic unit tests via Social ----

  describe "handle_propose_marriage/3" do
    setup do
      ensure_npc_def_loaded()

      priest_npc = %Arena.Entity.NpcEntity{
        npc_id: 1,
        instance_id: 1001,
        char_index: 500,
        x: 50,
        y: 50,
        hp: 100,
        max_hp: 100
      }

      player_a = %AoEntities.PlayerEntity{
        char_id: 1,
        name: "Alice",
        account_id: "acct_a",
        x: 50,
        y: 51,
        spouse_id: 0,
        marriage_proposal_target: nil,
        last_clicked_npc_instance_id: 1001,
        last_clicked_npc_type: 1
      }

      player_b = %AoEntities.PlayerEntity{
        char_id: 2,
        name: "Bob",
        account_id: "acct_b",
        x: 50,
        y: 52,
        spouse_id: 0,
        marriage_proposal_target: nil,
        last_clicked_npc_instance_id: 1001,
        last_clicked_npc_type: 1
      }

      me = self()

      state = %{
        players: %{1 => player_a, 2 => player_b},
        npcs_live: %{1001 => priest_npc},
        sessions: %{1 => me, 2 => me}
      }

      {:ok, state: state}
    end

    test "proposal without priest nearby is rejected", %{state: state} do
      # Move player A far from priest
      state = put_in(state.players[1], %{state.players[1] | x: 100, y: 100})

      {:noreply, new_state} = Arena.Map.Social.handle_propose_marriage(state, 1, 2)

      assert new_state.players[1].spouse_id == 0
      assert new_state.players[2].spouse_id == 0
    end

    test "proposal without selected priest is rejected", %{state: state} do
      state =
        put_in(
          state.players[1],
          %{state.players[1] | last_clicked_npc_instance_id: nil, last_clicked_npc_type: nil}
        )

      {:noreply, new_state} = Arena.Map.Social.handle_propose_marriage(state, 1, 2)

      assert new_state.players[1].spouse_id == 0
      assert new_state.players[2].spouse_id == 0
      assert new_state.players[1].marriage_proposal_target == nil
    end

    test "cannot marry yourself", %{state: state} do
      {:noreply, new_state} = Arena.Map.Social.handle_propose_marriage(state, 1, 1)

      assert new_state.players[1].spouse_id == 0
    end

    test "already married proposer is rejected", %{state: state} do
      state = put_in(state.players[1], %{state.players[1] | spouse_id: 999})

      {:noreply, new_state} = Arena.Map.Social.handle_propose_marriage(state, 1, 2)

      assert new_state.players[1].spouse_id == 999
      assert new_state.players[2].spouse_id == 0
    end

    test "already married target is rejected", %{state: state} do
      state = put_in(state.players[2], %{state.players[2] | spouse_id: 999})

      {:noreply, new_state} = Arena.Map.Social.handle_propose_marriage(state, 1, 2)

      assert new_state.players[1].spouse_id == 0
    end

    test "first proposal sets candidato on proposer", %{state: state} do
      {:noreply, new_state} = Arena.Map.Social.handle_propose_marriage(state, 1, 2)

      assert new_state.players[1].marriage_proposal_target == 2
      assert new_state.players[1].spouse_id == 0
      assert new_state.players[2].spouse_id == 0
    end

    test "mutual proposal completes marriage", %{state: state} do
      # Alice already proposed to Bob
      state = put_in(state.players[1], %{state.players[1] | marriage_proposal_target: 2})

      # Bob proposes to Alice -> mutual -> marriage!
      {:noreply, new_state} = Arena.Map.Social.handle_propose_marriage(state, 2, 1)

      assert new_state.players[1].spouse_id == 2
      assert new_state.players[2].spouse_id == 1
      assert new_state.players[1].marriage_proposal_target == nil
      assert new_state.players[2].marriage_proposal_target == nil
    end

    test "target not on map is rejected", %{state: state} do
      {:noreply, new_state} = Arena.Map.Social.handle_propose_marriage(state, 1, 999)

      assert new_state.players[1].spouse_id == 0
    end

    test "proposal sends notification to target", %{state: state} do
      {:noreply, _new_state} = Arena.Map.Social.handle_propose_marriage(state, 1, 2)

      # Social.msg sends {:send_raw, binary} -- check we got messages
      messages = flush_all_messages()
      assert length(messages) >= 2

      # Decode the raw messages to verify content
      raw_messages =
        Enum.flat_map(messages, fn
          {:send_raw, data} -> [data]
          _ -> []
        end)

      assert length(raw_messages) >= 2
    end
  end

  describe "handle_divorce/2" do
    setup do
      me = self()

      player_a = %AoEntities.PlayerEntity{
        char_id: 1,
        name: "Alice",
        account_id: "acct_a",
        x: 50,
        y: 51,
        spouse_id: 2,
        marriage_proposal_target: nil
      }

      player_b = %AoEntities.PlayerEntity{
        char_id: 2,
        name: "Bob",
        account_id: "acct_b",
        x: 50,
        y: 52,
        spouse_id: 1,
        marriage_proposal_target: nil
      }

      state = %{
        players: %{1 => player_a, 2 => player_b},
        npcs_live: %{},
        sessions: %{1 => me, 2 => me}
      }

      {:ok, state: state}
    end

    test "divorce clears both spouses when on same map", %{state: state} do
      {:noreply, new_state} = Arena.Map.Social.handle_divorce(state, 1)

      assert new_state.players[1].spouse_id == 0
      assert new_state.players[2].spouse_id == 0
    end

    test "divorce clears proposer side when spouse is on different map", %{state: state} do
      state = %{state | players: Map.delete(state.players, 2)}

      {:noreply, new_state} = Arena.Map.Social.handle_divorce(state, 1)

      assert new_state.players[1].spouse_id == 0
    end

    test "divorce when not married is rejected", %{state: state} do
      state = put_in(state.players[1], %{state.players[1] | spouse_id: 0})

      {:noreply, new_state} = Arena.Map.Social.handle_divorce(state, 1)

      assert new_state.players[1].spouse_id == 0
    end

    test "divorce notifies spouse on same map", %{state: state} do
      {:noreply, _new_state} = Arena.Map.Social.handle_divorce(state, 1)

      # Social.msg sends {:send_raw, binary} -- check we got messages for both players
      messages = flush_all_messages()

      raw_messages =
        Enum.flat_map(messages, fn
          {:send_raw, data} -> [data]
          _ -> []
        end)

      # Should have at least 2 messages: one for divorcer, one for spouse
      assert length(raw_messages) >= 2
    end
  end

  # ---- Helpers ----

  defp ensure_npc_def_loaded do
    # Ensure ETS table exists (GameData should be started by the app)
    try do
      case Arena.Data.GameData.get_npc(1) do
        nil ->
          # Insert a Revividor NPC def directly into ETS
          :ets.insert(:arena_game_data, {{:npc, 1}, %{
            id: 1,
            name: "Sacerdote",
            npc_type: 1,
            heading: 3,
            body: 1,
            head: 1,
            min_hp: 100,
            max_hp: 100,
            min_hit: 0,
            max_hit: 0,
            defense: 0,
            magic_defense: 0,
            evasion: 0,
            attack: 0,
            give_exp: 0,
            give_gold: 0,
            movement: 0,
            hostile: false,
            comercia: false,
            items: [],
            spells: [],
            faccion: 0,
            leash_distance: 0,
            puntos_pesca: 0
          }})

        _existing ->
          :ok
      end
    rescue
      ArgumentError ->
        # ETS table might not exist yet in test env
        :ets.new(:arena_game_data, [:named_table, :set, :public, read_concurrency: true])

        :ets.insert(:arena_game_data, {{:npc, 1}, %{
          id: 1,
          name: "Sacerdote",
          npc_type: 1,
          heading: 3,
          body: 1,
          head: 1,
          min_hp: 100,
          max_hp: 100,
          min_hit: 0,
          max_hit: 0,
          defense: 0,
          magic_defense: 0,
          evasion: 0,
          attack: 0,
          give_exp: 0,
          give_gold: 0,
          movement: 0,
          hostile: false,
          comercia: false,
          items: [],
          spells: [],
          faccion: 0,
          leash_distance: 0,
          puntos_pesca: 0
        }})
    end
  end

  defp flush_all_messages do
    flush_all_messages([])
  end

  defp flush_all_messages(acc) do
    receive do
      msg -> flush_all_messages([msg | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end
