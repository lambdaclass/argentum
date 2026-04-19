defmodule AoTcpGateway.RoleMasterRequestTest do
  @moduledoc """
  Tests for the role_master_request packet handler.

  In VB6 Argentum Online, RoleMasterRequest (opcode 63) is sent by any player
  via /ROL. The server reads a request string, forwards it to online
  RoleMasters/GMs, and confirms to the player.
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
        character_id: 70001,
        map_id: 1,
        account_id: "acct_role",
        entity: nil,
        char_index: 1,
        target_x: nil,
        target_y: nil,
        is_gm: false
      },
      overrides
    )
  end

  describe "role_master_request" do
    test "player with non-empty request gets confirmation" do
      # Register the player so resolve_char_name works
      AoSession.OnlineDirectory.register(70001, "TestPlayer", 1, self())

      on_exit(fn -> AoSession.OnlineDirectory.unregister(70001) end)

      {_state, packets} =
        SessionLogic.handle_command(
          base_state(),
          {:role_master_request, %{request: "Necesito ayuda con mi rol"}}
        )

      assert packets == [
               {:console_msg, %{message: "Su solicitud ha sido enviada.", font_index: 0}}
             ]
    end

    test "request is forwarded to online GMs" do
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

      AoSession.OnlineDirectory.register(70001, "TestPlayer", 1, self())
      AoSession.OnlineDirectory.register(70099, "GMAdmin", 1, gm_pid, is_gm: true, role_master: true)

      on_exit(fn ->
        AoSession.OnlineDirectory.unregister(70001)
        AoSession.OnlineDirectory.unregister(70099)
        send(gm_pid, :stop)
      end)

      SessionLogic.handle_command(
        base_state(),
        {:role_master_request, %{request: "Pregunta sobre mi personaje"}}
      )

      Process.sleep(50)

      gm_msgs = collect_tagged(:gm_msg)
      send_raws = Enum.filter(gm_msgs, &match?({:send_raw, _}, &1))
      assert length(send_raws) >= 1

      [{:send_raw, raw}] = send_raws
      # The console_msg should contain the player name and the request
      <<37::little-16, payload::binary>> = raw
      <<msg_len::little-16, msg_bytes::binary-size(msg_len), _rest::binary>> = payload
      assert msg_bytes =~ "TestPlayer"
      assert msg_bytes =~ "PREGUNTA ROL"
      assert msg_bytes =~ "Pregunta sobre mi personaje"
    end

    test "empty request is silently ignored" do
      {_state, packets} =
        SessionLogic.handle_command(
          base_state(),
          {:role_master_request, %{request: ""}}
        )

      assert packets == []
    end

    test "unauthenticated session (nil character_id) is silently ignored" do
      state = base_state(%{character_id: nil})

      {_state, packets} =
        SessionLogic.handle_command(state, {:role_master_request, %{request: "test"}})

      assert packets == []
    end
  end

  describe "role_master_request decoder" do
    test "decodes packet ID 63 with string8 request field" do
      request = "Mi pregunta de rol"
      req_bytes = <<byte_size(request)::little-16, request::binary>>
      packet = <<63::little-16, req_bytes::binary>>

      assert {:ok, {:role_master_request, %{request: ^request}}, <<>>} =
               AoProtocol.Client.Decoder.decode(packet)
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
