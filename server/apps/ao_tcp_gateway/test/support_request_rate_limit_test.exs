defmodule AoTcpGateway.SupportRequestRateLimitTest do
  @moduledoc """
  Adversarial tests for support-request rate limiting.

  `question_gm` and `role_master_request` should not allow burst spam that floods
  the GM channel with repeated notifications from one client.
  """

  use ExUnit.Case, async: false

  alias AoTcpGateway.SessionLogic

  @online_table :ao_online_directory

  setup do
    unless Process.whereis(AoSession.OnlineDirectory) do
      {:ok, _} = AoSession.OnlineDirectory.start_link([])
    end

    :ets.delete_all_objects(@online_table)
    :ok
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 80001,
        map_id: 1,
        account_id: "acct_support",
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        is_gm: false
      },
      overrides
    )
  end

  defp gm_probe(tag) do
    test_pid = self()

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
      50 -> Enum.reverse(acc)
    end
  end

  describe "question_gm rate limiting" do
    test "immediate repeated support questions should not notify GMs twice" do
      gm_pid = gm_probe(:gm)

      AoSession.OnlineDirectory.register(80001, "Questioner", 1, self())
      AoSession.OnlineDirectory.register(80099, "GMSupport", 1, gm_pid, is_gm: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(80001)
        AoSession.OnlineDirectory.unregister(80099)
        send(gm_pid, :stop)
      end)

      {_state, first_packets} =
        SessionLogic.handle_command(
          base_state(),
          {:question_gm, %{consulta: "Necesito ayuda", tipo: "General"}}
        )

      {_state, second_packets} =
        SessionLogic.handle_command(
          base_state(),
          {:question_gm, %{consulta: "Necesito ayuda otra vez", tipo: "General"}}
        )

      gm_msgs = collect_tagged(:gm)
      send_raws = Enum.filter(gm_msgs, &match?({:send_raw, _}, &1))

      assert first_packets == [
               {:console_msg,
                %{message: "Tu mensaje fue recibido por el equipo de soporte.", font_index: 0}}
             ]

      assert second_packets == [] or
               second_packets == [
                 {:console_msg,
                  %{message: "Estás enviando solicitudes demasiado rápido.", font_index: 0}}
               ]

      assert length(send_raws) == 1
    end
  end

  describe "role_master_request rate limiting" do
    test "immediate repeated role requests should not notify GMs twice" do
      gm_pid = gm_probe(:gm)

      AoSession.OnlineDirectory.register(70001, "RolePlayer", 1, self())
      AoSession.OnlineDirectory.register(70099, "GMAdmin", 1, gm_pid, is_gm: true, role_master: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(70001)
        AoSession.OnlineDirectory.unregister(70099)
        send(gm_pid, :stop)
      end)

      {_state, first_packets} =
        SessionLogic.handle_command(
          base_state(%{character_id: 70001, account_id: "acct_role"}),
          {:role_master_request, %{request: "Necesito ayuda con mi rol"}}
        )

      {_state, second_packets} =
        SessionLogic.handle_command(
          base_state(%{character_id: 70001, account_id: "acct_role"}),
          {:role_master_request, %{request: "Otra consulta de rol"}}
        )

      gm_msgs = collect_tagged(:gm)
      send_raws = Enum.filter(gm_msgs, &match?({:send_raw, _}, &1))

      assert first_packets == [
               {:console_msg, %{message: "Su solicitud ha sido enviada.", font_index: 0}}
             ]

      assert second_packets == [] or
               second_packets == [
                 {:console_msg,
                  %{message: "Estás enviando solicitudes demasiado rápido.", font_index: 0}}
               ]

      assert length(send_raws) == 1
    end
  end
end
