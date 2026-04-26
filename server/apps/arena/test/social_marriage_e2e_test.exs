defmodule Arena.Map.SocialMarriageE2ETest do
  @moduledoc """
  End-to-end tests for the Social marriage / divorce flows. Pins the
  Social effects-contract migration (Sub E: propose_marriage, divorce).

  This is the marquee test for the new `:broadcast_map` effect kind:
  the mutual-marriage path emits a map-wide announcement that must
  reach EVERY session on the map (including those outside the
  proposer's AoI), unlike `:broadcast_visible_all`.

  Outbound packets flow through `AoSession.Egress.enqueue/2` and arrive
  in the test pid mailbox as `{:egress, %AoSession.Outbound{...}}`
  envelopes — never via the legacy `{:send_raw, _}` shim.
  """

  use ExUnit.Case, async: false

  alias Arena.Map.MapServer
  alias Arena.Data.GameData
  alias AoEntities.PlayerEntity

  import Arena.Test.MapStateFactory

  @npc_type_revividor 1

  setup_all do
    case GameData.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    drain()
    :ok
  end

  defp drain do
    receive do
      _ -> drain()
    after
      10 -> :ok
    end
  end

  defp find_priest_npc_id do
    Enum.find_value(1..2000, fn id ->
      case GameData.get_npc(id) do
        %{npc_type: @npc_type_revividor} -> id
        _ -> nil
      end
    end)
  end

  defp make_player(overrides \\ %{}) do
    defaults = %{
      char_id: :alice,
      name: "Alice",
      account_id: "acc_alice",
      x: 50,
      y: 50,
      char_index: 1,
      map_id: 1,
      hp: 100,
      max_hp: 100,
      gold: 0,
      level: 25,
      class: :warrior,
      race: :human,
      gender: :female,
      str: 18,
      agi: 18,
      int: 18,
      con: 18,
      cha: 18,
      skills: %{},
      inventory: List.duplicate(nil, 24),
      faction: :none,
      dead: false,
      spouse_id: 0,
      marriage_proposal_target: nil,
      last_clicked_npc_instance_id: :priest,
      last_clicked_npc_type: @npc_type_revividor
    }

    struct!(PlayerEntity, Map.merge(defaults, overrides))
  end

  defp priest_npc do
    priest_id = find_priest_npc_id()
    assert priest_id != nil, "no priest NPC (type 1) in GameData"
    %{npc_id: priest_id, x: 51, y: 50, instance_id: :priest}
  end

  defp state_with_two(alice, bob, opts \\ []) do
    sessions = Keyword.get(opts, :sessions, %{alice.char_id => self()})
    npcs_live = Keyword.get(opts, :npcs_live, %{priest: priest_npc()})

    map_state(
      players: %{alice.char_id => alice, bob.char_id => bob},
      sessions: sessions,
      npcs_live: npcs_live,
      occupancy: Keyword.get(opts, :occupancy, %{}),
      visibility_mode: :global
    )
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:propose_marriage, ...})
  # ════════════════════════════════════════════════════════════════════════

  describe "propose_marriage via MapServer cast" do
    test "first proposal: candidato set, both proposer and target receive consoles" do
      alice = make_player()
      bob = make_player(%{char_id: :bob, name: "Bob", char_index: 2, x: 51, y: 51})

      origin = self()
      bob_pid = spawn_link(fn -> mailbox_relay(origin, :bob_received) end)

      sessions = %{alice.char_id => origin, bob.char_id => bob_pid}
      state = state_with_two(alice, bob, sessions: sessions)

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:propose_marriage, :alice, :bob}, state)

      # Alice's candidato now points at Bob
      assert new_state.players[:alice].marriage_proposal_target == :bob
      # Neither is married yet
      assert new_state.players[:alice].spouse_id == 0
      assert new_state.players[:bob].spouse_id == 0

      # Alice receives confirmation envelope
      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "casamiento") != :nomatch

      # Bob receives notification envelope
      assert_receive {:bob_received,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = b_payload}}

      assert :binary.match(b_payload, "casarse") != :nomatch

      refute_receive {:send_raw, _}, 50
    end

    test "mutual proposal: marriage solemnised, broadcast_map announcement reaches everyone" do
      # Alice has already been proposed to by Bob (his candidato is Alice).
      # Alice now proposes back -> they should marry.
      alice = make_player()

      bob =
        make_player(%{
          char_id: :bob,
          name: "Bob",
          char_index: 2,
          x: 51,
          y: 51,
          marriage_proposal_target: :alice
        })

      # `bystander` is OUTSIDE any AoI window — the marriage announcement
      # must still reach them because :broadcast_map ignores AoI.
      bystander = make_player(%{char_id: :far, name: "Far", char_index: 3, x: 500, y: 500})

      origin = self()

      bob_pid =
        spawn_link(fn -> mailbox_relay(origin, :bob_received) end)

      far_pid =
        spawn_link(fn -> mailbox_relay(origin, :far_received) end)

      sessions = %{
        alice.char_id => self(),
        bob.char_id => bob_pid,
        bystander.char_id => far_pid
      }

      state =
        map_state(
          players: %{
            alice.char_id => alice,
            bob.char_id => bob,
            bystander.char_id => bystander
          },
          sessions: sessions,
          npcs_live: %{priest: priest_npc()},
          occupancy: %{},
          visibility_mode: :global
        )

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:propose_marriage, :alice, :bob}, state)

      # Both are now married, candidato cleared
      assert new_state.players[:alice].spouse_id == :bob
      assert new_state.players[:bob].spouse_id == :alice
      assert new_state.players[:alice].marriage_proposal_target == nil
      assert new_state.players[:bob].marriage_proposal_target == nil

      # The marriage announcement (broadcast_map) reaches:
      #   - Alice's session (origin)
      #   - Bob's session
      #   - The faraway bystander (proves AoI is bypassed)
      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = a_payload}}

      assert :binary.match(a_payload, "casamiento") != :nomatch

      assert_receive {:bob_received,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = b_payload}}

      assert_receive {:far_received,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = f_payload}}

      # The faraway bystander only receives the broadcast_map announcement,
      # not the per-player congrats. Its payload must contain the
      # announcement text "casamiento entre Alice y Bob".
      assert :binary.match(f_payload, "casamiento entre Alice y Bob") != :nomatch
      assert :binary.match(b_payload, "casamiento entre Alice y Bob") != :nomatch ||
               :binary.match(b_payload, "Felicidades") != :nomatch

      refute_receive {:send_raw, _}, 50
    end

    test "no priest selected: rejection console envelope, state unchanged" do
      alice = make_player(%{last_clicked_npc_instance_id: nil, last_clicked_npc_type: nil})
      bob = make_player(%{char_id: :bob, name: "Bob", char_index: 2, x: 51, y: 51})

      state = state_with_two(alice, bob, npcs_live: %{})

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:propose_marriage, :alice, :bob}, state)

      assert new_state.players[:alice].marriage_proposal_target == nil
      assert new_state.players[:alice].spouse_id == 0

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "sacerdote") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "self-proposal: rejection console envelope" do
      alice = make_player()

      state =
        map_state(
          players: %{alice.char_id => alice},
          sessions: %{alice.char_id => self()},
          npcs_live: %{priest: priest_npc()},
          occupancy: %{}
        )

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:propose_marriage, :alice, :alice}, state)

      assert new_state.players[:alice].marriage_proposal_target == nil

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "contigo mismo") != :nomatch
    end

    test "proposer already married: rejection console envelope" do
      alice = make_player(%{spouse_id: :existing_spouse})
      bob = make_player(%{char_id: :bob, name: "Bob", char_index: 2, x: 51, y: 51})

      state = state_with_two(alice, bob)
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} =
               MapServer.handle_cast({:propose_marriage, :alice, :bob}, state)

      assert new_state.players[:alice].spouse_id == :existing_spouse

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "Ya estas casado") != :nomatch
    end

    test "target already married: rejection console envelope" do
      alice = make_player()

      bob =
        make_player(%{
          char_id: :bob,
          name: "Bob",
          char_index: 2,
          x: 51,
          y: 51,
          spouse_id: :other
        })

      state = state_with_two(alice, bob)
      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, _} =
               MapServer.handle_cast({:propose_marriage, :alice, :bob}, state)

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "divorciarse") != :nomatch
    end

    test "target not on map: rejection console envelope" do
      alice = make_player()

      state =
        map_state(
          players: %{alice.char_id => alice},
          sessions: %{alice.char_id => self()},
          npcs_live: %{priest: priest_npc()},
          occupancy: %{}
        )

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, _} =
               MapServer.handle_cast({:propose_marriage, :alice, :ghost}, state)

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "no se encuentra") != :nomatch
    end

    test "missing proposer: silent no-op" do
      state = map_state(players: %{}, sessions: %{}, npcs_live: %{})

      assert {:noreply, _} =
               MapServer.handle_cast({:propose_marriage, :ghost, :other}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # MapServer.handle_cast({:divorce, _})
  # ════════════════════════════════════════════════════════════════════════

  describe "divorce via MapServer cast" do
    test "married pair on same map: both unmarried, both notified" do
      alice = make_player(%{spouse_id: :bob})

      bob =
        make_player(%{
          char_id: :bob,
          name: "Bob",
          char_index: 2,
          x: 51,
          y: 51,
          spouse_id: :alice
        })

      origin = self()
      bob_pid = spawn_link(fn -> mailbox_relay(origin, :bob_received) end)

      state =
        state_with_two(alice, bob,
          sessions: %{alice.char_id => origin, bob.char_id => bob_pid}
        )

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} = MapServer.handle_cast({:divorce, :alice}, state)

      assert new_state.players[:alice].spouse_id == 0
      assert new_state.players[:bob].spouse_id == 0

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = a_payload}}

      assert :binary.match(a_payload, "divorciado") != :nomatch

      assert_receive {:bob_received,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = b_payload}}

      assert :binary.match(b_payload, "divorciado") != :nomatch
      refute_receive {:send_raw, _}, 50
    end

    test "spouse offline / not on map: only proposer's side cleared and notified" do
      alice = make_player(%{spouse_id: :offline_spouse})

      state =
        map_state(
          players: %{alice.char_id => alice},
          sessions: %{alice.char_id => self()},
          npcs_live: %{},
          occupancy: %{}
        )

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} = MapServer.handle_cast({:divorce, :alice}, state)

      assert new_state.players[:alice].spouse_id == 0

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "divorciado") != :nomatch
    end

    test "not married: rejection console envelope, state unchanged" do
      alice = make_player(%{spouse_id: 0})

      state =
        map_state(
          players: %{alice.char_id => alice},
          sessions: %{alice.char_id => self()},
          npcs_live: %{},
          occupancy: %{}
        )

      console_id = AoProtocol.PacketIds.Server.console_msg()

      assert {:noreply, new_state} = MapServer.handle_cast({:divorce, :alice}, state)

      assert new_state.players[:alice].spouse_id == 0

      assert_receive {:egress,
                      %{payload: <<^console_id::little-signed-integer-16, _::binary>> = payload}}

      assert :binary.match(payload, "No estas casado") != :nomatch
    end

    test "missing player: silent no-op" do
      state = map_state(players: %{}, sessions: %{}, npcs_live: %{})

      assert {:noreply, _} = MapServer.handle_cast({:divorce, :ghost}, state)

      refute_receive {:egress, _}, 50
      refute_receive {:send_raw, _}, 50
    end
  end

  # Forward egress envelopes from a peer's mailbox to the test pid under a
  # custom tag so multiple peers can coexist without colliding.
  defp mailbox_relay(test_pid, tag) do
    receive do
      {:egress, env} ->
        Kernel.send(test_pid, {tag, env})
        mailbox_relay(test_pid, tag)

      _ ->
        mailbox_relay(test_pid, tag)
    end
  end
end
