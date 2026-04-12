defmodule AoTcpGateway.QuestionGmTest do
  @moduledoc """
  Tests for the question_gm (ID 215) packet handler.

  In VB6 Argentum Online, QuestionGM is sent by any player to submit a support
  question. The server reads consulta + tipo + packet_counter, pushes the
  question to the help queue, notifies online admins, and sends confirmation
  to the requesting player.
  """
  use ExUnit.Case

  alias AoTcpGateway.SessionLogic

  setup_all do
    unless Process.whereis(AoSession.OnlineDirectory) do
      {:ok, _} = AoSession.OnlineDirectory.start_link([])
    end

    :ok
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        character_id: 80001,
        map_id: 1,
        account_id: "acct_question",
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        is_gm: false
      },
      overrides
    )
  end

  describe "question_gm handler" do
    test "player receives confirmation when sending a non-empty question" do
      AoSession.OnlineDirectory.register(80001, "Questioner", 1, self())
      on_exit(fn -> AoSession.OnlineDirectory.unregister(80001) end)

      {_state, packets} =
        SessionLogic.handle_command(
          base_state(),
          {:question_gm, %{consulta: "Me robaron items", tipo: "Robo"}}
        )

      assert packets == [
               {:console_msg,
                %{message: "Tu mensaje fue recibido por el equipo de soporte.", font_index: 0}}
             ]
    end

    test "notification is forwarded to online GMs" do
      test_pid = self()

      gm_pid =
        spawn(fn ->
          loop = fn loop ->
            receive do
              :stop -> :ok
              msg -> send(test_pid, {:gm_msg, msg}); loop.(loop)
            end
          end

          loop.(loop)
        end)

      AoSession.OnlineDirectory.register(80001, "Questioner", 1, self())
      AoSession.OnlineDirectory.register(80099, "GMSupport", 1, gm_pid, is_gm: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(80001)
        AoSession.OnlineDirectory.unregister(80099)
        send(gm_pid, :stop)
      end)

      SessionLogic.handle_command(
        base_state(),
        {:question_gm, %{consulta: "Necesito ayuda", tipo: "General"}}
      )

      Process.sleep(50)

      gm_msgs = collect_tagged(:gm_msg)
      send_raws = Enum.filter(gm_msgs, &match?({:send_raw, _}, &1))
      assert length(send_raws) >= 1

      [{:send_raw, raw}] = send_raws
      <<37::little-16, payload::binary>> = raw
      <<msg_len::little-16, msg_bytes::binary-size(msg_len), _rest::binary>> = payload
      assert msg_bytes =~ "Questioner"
      assert msg_bytes =~ "soporte"
    end

    test "empty consulta is silently ignored" do
      {_state, packets} =
        SessionLogic.handle_command(
          base_state(),
          {:question_gm, %{consulta: "", tipo: "General"}}
        )

      assert packets == []
    end

    test "unauthenticated session (nil character_id) is silently ignored" do
      state = base_state(%{character_id: nil})

      {_state, packets} =
        SessionLogic.handle_command(
          state,
          {:question_gm, %{consulta: "test", tipo: "test"}}
        )

      assert packets == []
    end

    test "GM players can also send questions" do
      AoSession.OnlineDirectory.register(80002, "GMPlayer", 1, self(), is_gm: true)
      on_exit(fn -> AoSession.OnlineDirectory.unregister(80002) end)

      state = base_state(%{character_id: 80002, is_gm: true})

      {_state, packets} =
        SessionLogic.handle_command(
          state,
          {:question_gm, %{consulta: "Testing support", tipo: "Test"}}
        )

      assert packets == [
               {:console_msg,
                %{message: "Tu mensaje fue recibido por el equipo de soporte.", font_index: 0}}
             ]
    end
  end

  describe "question_gm decoder" do
    test "decodes packet ID 215 with consulta, tipo, and packet_counter" do
      consulta = "Me robaron items"
      tipo = "Robo"

      packet =
        <<215::little-16,
          byte_size(consulta)::little-16, consulta::binary,
          byte_size(tipo)::little-16, tipo::binary,
          42::little-32>>

      assert {:ok, {:question_gm, %{consulta: ^consulta, tipo: ^tipo}}, <<>>} =
               AoProtocol.Client.Decoder.decode(packet)
    end

    test "returns incomplete when packet is truncated" do
      packet = <<215::little-16, 0, 10>>
      assert :incomplete = AoProtocol.Client.Decoder.decode(packet)
    end
  end

  defp collect_tagged(tag, acc \\ []) do
    receive do
      {^tag, msg} -> collect_tagged(tag, [msg | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
