defmodule Arena.GmSupportDriftTest do
  @moduledoc """
  VB6-parity tests for GM/support system drifts #14-#18.

  Drift #14: QuestionGM should enqueue into SOS queue (Ayuda.Push)
  Drift #15: RoleMasterRequest should go to role masters, not all GMs
  Drift #16: Support cooldown should be 300_000ms for QuestionGM, separate for /ROL
  Drift #17: SOS commands should be wired to the SOS queue (not stubbed)
  Drift #18: GM /GOTO should require SOS request for lower-tier GMs
  """

  use ExUnit.Case, async: false

  alias AoEntities.PlayerEntity

  @online_table :ao_online_directory

  setup do
    # Ensure OnlineDirectory is running
    unless Process.whereis(AoSession.OnlineDirectory) do
      {:ok, _} = AoSession.OnlineDirectory.start_link([])
    end

    :ets.delete_all_objects(@online_table)

    # Ensure SosQueue is running and cleared
    unless Process.whereis(AoSession.SosQueue) do
      {:ok, _} = AoSession.SosQueue.start_link([])
    end

    AoSession.SosQueue.clear()

    # Clear rate limit table if it exists
    try do
      :ets.delete_all_objects(:ao_support_rate_limit)
    catch
      :error, :badarg -> :ok
    end

    # Clear separate cooldown tables
    for table <- [:ao_question_gm_cooldown, :ao_role_master_cooldown] do
      try do
        :ets.delete_all_objects(table)
      catch
        :error, :badarg -> :ok
      end
    end

    :ok
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 90001,
        map_id: 1,
        account_id: "acct_test",
        entity: %PlayerEntity{
          char_id: 90001,
          name: "TestPlayer",
          account_id: "acct_test",
          x: 50,
          y: 50,
          level: 10,
          gm: false
        },
        char_index: 1,
        target_x: nil,
        target_y: nil,
        is_gm: false
      },
      overrides
    )
  end

  defp gm_state(overrides \\ %{}) do
    base_state(
      Map.merge(
        %{
          character_id: 90100,
          is_gm: true,
          entity: %PlayerEntity{
            char_id: 90100,
            name: "GMAdmin",
            account_id: "acct_gm",
            x: 50,
            y: 50,
            level: 45,
            gm: true,
            gm_level: :admin
          }
        },
        overrides
      )
    )
  end

  defp spawn_listener(test_pid, tag) do
    spawn(fn ->
      loop = fn loop ->
        receive do
          :stop -> :ok
          msg ->
            send(test_pid, {tag, msg})
            loop.(loop)
        end
      end

      loop.(loop)
    end)
  end

  defp collect_tagged(tag, acc \\ []) do
    receive do
      {^tag, msg} -> collect_tagged(tag, [msg | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # ===========================================================================
  # Drift #14: QuestionGM should enqueue into SOS queue
  # ===========================================================================

  describe "Drift #14: QuestionGM enqueues into SOS queue" do
    test "question_gm adds request to SosQueue" do
      AoSession.OnlineDirectory.register(90001, "TestPlayer", 1, self())
      gm_pid = spawn_listener(self(), :gm)
      AoSession.OnlineDirectory.register(90100, "GMAdmin", 1, gm_pid, is_gm: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(90001)
        AoSession.OnlineDirectory.unregister(90100)
        send(gm_pid, :stop)
      end)

      state = base_state()

      AoTcpGateway.SessionLogic.handle_command(
        state,
        {:question_gm, %{consulta: "Necesito ayuda", tipo: "General"}}
      )

      # The request should be in the SOS queue
      requests = AoSession.SosQueue.list_requests()
      assert length(requests) == 1

      [req] = requests
      assert req.char_id == 90001
      assert req.name == "TestPlayer"
      assert req.message == "Necesito ayuda"
    end

    test "question_gm still broadcasts to GMs (existing behavior preserved)" do
      AoSession.OnlineDirectory.register(90001, "TestPlayer", 1, self())
      gm_pid = spawn_listener(self(), :gm)
      AoSession.OnlineDirectory.register(90100, "GMAdmin", 1, gm_pid, is_gm: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(90001)
        AoSession.OnlineDirectory.unregister(90100)
        send(gm_pid, :stop)
      end)

      state = base_state()

      AoTcpGateway.SessionLogic.handle_command(
        state,
        {:question_gm, %{consulta: "Help me", tipo: "Bug"}}
      )

      gm_msgs = collect_tagged(:gm)
      send_raws = Enum.filter(gm_msgs, &match?({:send_raw, _}, &1))
      assert length(send_raws) >= 1
    end

    test "SosQueue module exists and has the required API" do
      # add_request/3 returns :ok
      assert :ok = AoSession.SosQueue.add_request(1, "TestName", "TestMessage")

      # list_requests/0 returns list of request maps
      requests = AoSession.SosQueue.list_requests()
      assert is_list(requests)
      assert length(requests) >= 1

      [req | _] = requests
      assert Map.has_key?(req, :char_id)
      assert Map.has_key?(req, :name)
      assert Map.has_key?(req, :message)
      assert Map.has_key?(req, :timestamp)

      # remove_request/1 returns :ok or {:error, :not_found}
      result = AoSession.SosQueue.remove_request(1)
      assert result in [:ok, {:error, :not_found}]

      # clear/0 returns :ok
      assert :ok = AoSession.SosQueue.clear()
      assert AoSession.SosQueue.list_requests() == []
    end
  end

  # ===========================================================================
  # Drift #15: RoleMasterRequest goes to role masters, not all GMs
  # ===========================================================================

  describe "Drift #15: RoleMasterRequest goes to role masters only" do
    test "role_master_request notifies role masters but not regular GMs" do
      role_master_pid = spawn_listener(self(), :role_master)
      regular_gm_pid = spawn_listener(self(), :regular_gm)

      # Register a role master GM
      AoSession.OnlineDirectory.register(90200, "RoleMasterGM", 1, role_master_pid,
        is_gm: true,
        role_master: true
      )

      # Register a regular GM (not a role master)
      AoSession.OnlineDirectory.register(90201, "RegularGM", 1, regular_gm_pid, is_gm: true)

      # Register the requesting player
      AoSession.OnlineDirectory.register(90001, "TestPlayer", 1, self())

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(90200)
        AoSession.OnlineDirectory.unregister(90201)
        AoSession.OnlineDirectory.unregister(90001)
        send(role_master_pid, :stop)
        send(regular_gm_pid, :stop)
      end)

      state = base_state()

      AoTcpGateway.SessionLogic.handle_command(
        state,
        {:role_master_request, %{request: "Pregunta de rol"}}
      )

      # Role master should receive the message
      rm_msgs = collect_tagged(:role_master)
      rm_raws = Enum.filter(rm_msgs, &match?({:send_raw, _}, &1))
      assert length(rm_raws) >= 1

      # Regular GM should NOT receive the message
      gm_msgs = collect_tagged(:regular_gm)
      gm_raws = Enum.filter(gm_msgs, &match?({:send_raw, _}, &1))
      assert length(gm_raws) == 0
    end

    test "broadcast_to_role_masters function exists in OnlineDirectory" do
      role_master_pid = spawn_listener(self(), :rm)

      AoSession.OnlineDirectory.register(90300, "RoleMasterGM", 1, role_master_pid,
        is_gm: true,
        role_master: true
      )

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(90300)
        send(role_master_pid, :stop)
      end)

      # The function should exist and send to role masters
      count = AoSession.OnlineDirectory.broadcast_to_role_masters({:test_msg, "hello"})
      assert count >= 1

      msgs = collect_tagged(:rm)
      assert Enum.any?(msgs, &match?({:test_msg, "hello"}, &1))
    end
  end

  # ===========================================================================
  # Drift #16: Cooldown semantics differ
  # ===========================================================================

  describe "Drift #16: separate cooldowns for QuestionGM and RoleMasterRequest" do
    test "question_gm has 300_000ms cooldown (VB6: IntervaloConsultaGM)" do
      AoSession.OnlineDirectory.register(90001, "TestPlayer", 1, self())
      gm_pid = spawn_listener(self(), :gm)
      AoSession.OnlineDirectory.register(90100, "GMAdmin", 1, gm_pid, is_gm: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(90001)
        AoSession.OnlineDirectory.unregister(90100)
        send(gm_pid, :stop)
      end)

      state = base_state()

      # First request should succeed
      {_state, first_packets} =
        AoTcpGateway.SessionLogic.handle_command(
          state,
          {:question_gm, %{consulta: "Help 1", tipo: "General"}}
        )

      assert Enum.any?(first_packets, fn
               {:console_msg, %{message: msg}} ->
                 String.contains?(msg, "recibido")

               _ ->
                 false
             end)

      # Immediately after, second request should be rate limited
      {_state, second_packets} =
        AoTcpGateway.SessionLogic.handle_command(
          state,
          {:question_gm, %{consulta: "Help 2", tipo: "General"}}
        )

      assert Enum.any?(second_packets, fn
               {:console_msg, %{message: msg}} ->
                 String.contains?(msg, "rápido") or String.contains?(msg, "minutos") or
                   String.contains?(msg, "cooldown")

               _ ->
                 false
             end)
    end

    test "question_gm and role_master_request have independent cooldowns" do
      AoSession.OnlineDirectory.register(90001, "TestPlayer", 1, self())
      gm_pid = spawn_listener(self(), :gm)

      AoSession.OnlineDirectory.register(90100, "GMAdmin", 1, gm_pid,
        is_gm: true,
        role_master: true
      )

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(90001)
        AoSession.OnlineDirectory.unregister(90100)
        send(gm_pid, :stop)
      end)

      state = base_state()

      # Send a question_gm first
      {_state, _} =
        AoTcpGateway.SessionLogic.handle_command(
          state,
          {:question_gm, %{consulta: "Help via GM", tipo: "General"}}
        )

      # Immediately after, send a role_master_request - should NOT be rate limited
      # because they use separate cooldowns
      {_state, rol_packets} =
        AoTcpGateway.SessionLogic.handle_command(
          state,
          {:role_master_request, %{request: "Pregunta de rol"}}
        )

      # The role_master_request should succeed (not rate limited)
      assert Enum.any?(rol_packets, fn
               {:console_msg, %{message: msg}} ->
                 String.contains?(msg, "solicitud ha sido enviada")

               _ ->
                 false
             end)
    end
  end

  # ===========================================================================
  # Drift #17: SOS commands wired to SOS queue
  # ===========================================================================

  describe "Drift #17: SOS commands wired to real queue" do
    test "sos_show_list shows actual pending requests" do
      # Add some requests to the queue
      AoSession.SosQueue.add_request(1001, "PlayerOne", "Need help with quest")
      AoSession.SosQueue.add_request(1002, "PlayerTwo", "Bug report")

      state = gm_state()

      {_state, packets} =
        AoTcpGateway.SessionCommands.Gm.handle_command(state, {:sos_show_list, %{}})

      # Should list actual requests, not just "(vacia)"
      messages =
        for {:console_msg, %{message: msg}} <- packets do
          msg
        end

      combined = Enum.join(messages, " ")
      assert String.contains?(combined, "PlayerOne")
      assert String.contains?(combined, "PlayerTwo")
    end

    test "sos_show_list shows empty when no requests" do
      state = gm_state()

      {_state, packets} =
        AoTcpGateway.SessionCommands.Gm.handle_command(state, {:sos_show_list, %{}})

      messages =
        for {:console_msg, %{message: msg}} <- packets do
          msg
        end

      combined = Enum.join(messages, " ")
      # Should indicate empty/no requests
      assert String.contains?(combined, "vacia") or String.contains?(combined, "0") or
               combined == ""
    end

    test "sos_remove removes a request by character name" do
      AoSession.SosQueue.add_request(1001, "PlayerOne", "Need help")
      AoSession.SosQueue.add_request(1002, "PlayerTwo", "Bug report")

      state = gm_state()

      {_state, _packets} =
        AoTcpGateway.SessionCommands.Gm.handle_command(
          state,
          {:sos_remove, %{name: "PlayerOne"}}
        )

      # PlayerOne should be removed
      requests = AoSession.SosQueue.list_requests()
      names = Enum.map(requests, & &1.name)
      refute "PlayerOne" in names
      assert "PlayerTwo" in names
    end

    test "clean_sos clears all requests" do
      AoSession.SosQueue.add_request(1001, "PlayerOne", "Help 1")
      AoSession.SosQueue.add_request(1002, "PlayerTwo", "Help 2")

      state = gm_state()

      {_state, _packets} =
        AoTcpGateway.SessionCommands.Gm.handle_command(state, {:clean_sos, %{}})

      assert AoSession.SosQueue.list_requests() == []
    end
  end

  # ===========================================================================
  # Drift #18: GM /GOTO requires SOS for lower-tier GMs
  # ===========================================================================

  describe "Drift #18: GM /GOTO gates lower-tier GMs through SOS queue" do
    test "consejero GM cannot /GOTO a player without active SOS request" do
      # A consejero-level entity
      consejero_entity = %PlayerEntity{
        char_id: 90500,
        name: "GMConsejero",
        account_id: "acct_consejero",
        x: 50,
        y: 50,
        level: 45,
        gm: true,
        gm_level: :consejero,
        map_id: 1
      }

      # Target player entity on same map
      target_entity = %PlayerEntity{
        char_id: 90501,
        name: "TargetPlayer",
        account_id: "acct_target",
        x: 60,
        y: 60,
        level: 10,
        gm: false,
        map_id: 1
      }

      test_pid = self()

      # Map state uses :players (not :entities) for find_player_by_name
      map_state = %{
        map_id: 1,
        players: %{
          90500 => consejero_entity,
          90501 => target_entity
        },
        sessions: %{
          90500 => test_pid,
          90501 => test_pid
        }
      }

      # No SOS request in queue -> should be rejected
      {:ok, new_state, effects} =
        Arena.Map.Gm.Teleport.gm_goto(map_state, 90500, consejero_entity, "TargetPlayer")

      Arena.Map.Effects.run(new_state, effects)

      # Check that a rejection console message was sent (egress envelope routed
      # through the effects runner — `:send_raw` is the legacy path that the
      # adversarial guard still accepts via the lenient `kind in [...]` pattern).
      assert_receive {kind, _packet} when kind in [:egress, :send_raw]

      # Should NOT receive a :transfer message (teleport was blocked)
      refute_receive {:transfer, _, _, _, _}, 50
    end

    test "admin GM can /GOTO any player without SOS request" do
      admin_entity = %PlayerEntity{
        char_id: 90600,
        name: "GMAdmin",
        account_id: "acct_admin",
        x: 50,
        y: 50,
        level: 45,
        gm: true,
        gm_level: :admin,
        map_id: 1
      }

      target_entity = %PlayerEntity{
        char_id: 90601,
        name: "TargetPlayer2",
        account_id: "acct_target2",
        x: 60,
        y: 60,
        level: 10,
        gm: false,
        map_id: 1
      }

      test_pid = self()

      map_state = %{
        map_id: 1,
        players: %{
          90600 => admin_entity,
          90601 => target_entity
        },
        sessions: %{
          90600 => test_pid,
          90601 => test_pid
        }
      }

      # Admin should be able to GOTO without SOS
      {:ok, new_state, effects} =
        Arena.Map.Gm.Teleport.gm_goto(map_state, 90600, admin_entity, "TargetPlayer2")

      Arena.Map.Effects.run(new_state, effects)

      # Should receive a transfer message (teleport happened)
      assert_receive {:transfer, 1, 60, 60, _entity}, 200
    end

    test "consejero GM can /GOTO a player WITH active SOS request" do
      consejero_entity = %PlayerEntity{
        char_id: 90700,
        name: "GMConsejero2",
        account_id: "acct_consejero2",
        x: 50,
        y: 50,
        level: 45,
        gm: true,
        gm_level: :consejero,
        map_id: 1
      }

      target_entity = %PlayerEntity{
        char_id: 90701,
        name: "SOSPlayer",
        account_id: "acct_sos",
        x: 70,
        y: 70,
        level: 10,
        gm: false,
        map_id: 1
      }

      test_pid = self()

      map_state = %{
        map_id: 1,
        players: %{
          90700 => consejero_entity,
          90701 => target_entity
        },
        sessions: %{
          90700 => test_pid,
          90701 => test_pid
        }
      }

      # Add an SOS request for the target player
      AoSession.SosQueue.add_request(90701, "SOSPlayer", "Need help please")

      # Now consejero should be able to GOTO
      {:ok, new_state, effects} =
        Arena.Map.Gm.Teleport.gm_goto(map_state, 90700, consejero_entity, "SOSPlayer")

      Arena.Map.Effects.run(new_state, effects)

      # Should receive a transfer message (teleport happened)
      assert_receive {:transfer, 1, 70, 70, _entity}, 200
    end
  end
end
