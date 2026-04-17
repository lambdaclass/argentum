defmodule AoTcpGateway.BackpressureTest do
  @moduledoc """
  Regression test: a lagging client whose mailbox exceeds the backpressure
  threshold is disconnected instead of accumulating unbounded messages.
  """

  use ExUnit.Case

  alias AoProtocol.Writer

  @connect_timeout 2000
  @recv_timeout 500

  setup_all do
    start_if_needed(:ranch_sup, fn -> Application.ensure_all_started(:ranch) end)

    start_if_needed(Arena.PubSub, fn ->
      Application.ensure_all_started(:phoenix_pubsub)
      Phoenix.PubSub.Supervisor.start_link(name: Arena.PubSub)
    end)

    start_if_needed(AoSession.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: AoSession.SessionRegistry)
    end)

    start_if_needed(Arena.MapRegistry, fn ->
      Registry.start_link(keys: :unique, name: Arena.MapRegistry)
    end)

    start_if_needed(Arena.Map.MapSupervisor, fn ->
      Arena.Map.MapSupervisor.start_link([])
    end)

    case Registry.lookup(Arena.MapRegistry, 1) do
      [] -> Arena.Map.MapSupervisor.start_map(1)
      _ -> :ok
    end

    :ok
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(GameBackend.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GameBackend.Repo, {:shared, self()})

    listener_name = :"test_bp_#{System.unique_integer([:positive])}"

    {:ok, _} =
      :ranch.start_listener(
        listener_name,
        :ranch_tcp,
        [port: 0],
        AoTcpGateway.ClientHandler,
        []
      )

    port = :ranch.get_port(listener_name)

    on_exit(fn -> :ranch.stop_listener(listener_name) end)

    %{port: port}
  end

  test "transport disconnects when mailbox exceeds backpressure threshold", %{port: port} do
    # Attach telemetry handler to capture backpressure events
    test_pid = self()
    ref = make_ref()

    handler_id = "bp_test_#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:arena, :session, :backpressure],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:backpressure, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Connect and login
    name = "BPTest_#{System.unique_integer([:positive])}"
    socket = connect(port)
    send_login(socket, name)
    _login_data = recv_all(socket)

    char_id = get_char_id(name)
    assert char_id != nil

    on_exit(fn ->
      :gen_tcp.close(socket)
      cleanup_char(char_id)
    end)

    # Find the handler PID via OnlineDirectory
    {:ok, %{session_pid: handler_pid}} = AoSession.OnlineDirectory.lookup_by_id(char_id)
    assert is_pid(handler_pid)

    # Flood the handler with messages — more than the disconnect threshold (1000).
    # We use :erlang.suspend_process to prevent the handler from draining its
    # mailbox while we fill it, then resume and let it notice the overflow.
    :erlang.suspend_process(handler_pid)

    for _ <- 1..1100 do
      send(handler_pid, {:send_raw, <<0>>})
    end

    :erlang.resume_process(handler_pid)

    # The handler should notice the mailbox overflow on the next loop iteration
    # and close the connection. Wait for the TCP socket to close.
    assert_socket_closed(socket, 3000)

    # Verify we got a disconnect telemetry event
    assert_received {:backpressure, %{mailbox_len: len}, %{action: :disconnect}}, 1000
    assert len >= 1000
  end

  test "healthy noisy session is not disconnected", %{port: port} do
    # Attach telemetry handler to verify no disconnect events fire
    test_pid = self()

    handler_id = "bp_healthy_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arena, :session, :backpressure],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:backpressure, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Connect and login
    name = "BPHealthy_#{System.unique_integer([:positive])}"
    socket = connect(port)
    send_login(socket, name)
    _login_data = recv_all(socket)

    char_id = get_char_id(name)
    assert char_id != nil

    on_exit(fn ->
      :gen_tcp.close(socket)
      cleanup_char(char_id)
    end)

    {:ok, %{session_pid: handler_pid}} = AoSession.OnlineDirectory.lookup_by_id(char_id)

    # Send a burst of messages well below the threshold while actively reading.
    # The handler should drain them normally without triggering backpressure.
    for _ <- 1..100 do
      send(handler_pid, {:send_raw, <<0>>})
    end

    # Drain whatever the server sent us
    _data = recv_all(socket)

    # Give a moment for any telemetry to fire
    Process.sleep(200)

    # Verify the session is still alive and no disconnect event fired
    assert Process.alive?(handler_pid)
    refute_received {:backpressure, _, %{action: :disconnect}}

    # Verify the socket is still open by sending a walk packet and getting a response
    # (or at least not getting :closed)
    assert {:error, :timeout} == :gen_tcp.recv(socket, 0, 100)
  end

  # ---- Helpers ----

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw], @connect_timeout)

    socket
  end

  defp send_login(socket, name) do
    token = "test_token"
    md5 = "abcdef1234567890abcdef1234567890"

    payload =
      Writer.write_string8(token) <>
        Writer.write_string8(name) <>
        Writer.write_int8(1) <> Writer.write_int8(0) <> Writer.write_int8(0) <>
        Writer.write_string8(md5) <>
        Writer.write_int8(1) <>
        Writer.write_int8(1) <>
        Writer.write_int8(6) <>
        Writer.write_int16(1) <>
        Writer.write_int8(1)

    packet = Writer.build_packet(74, payload)
    :ok = :gen_tcp.send(socket, packet)
  end

  defp recv_all(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :timeout} -> acc
      {:error, _reason} -> acc
    end
  end

  defp get_char_id(name) do
    case GameBackend.Characters.get_by_name(name) do
      nil -> nil
      char -> char.id
    end
  end

  defp cleanup_char(nil), do: :ok

  defp cleanup_char(char_id) do
    try do
      Arena.Map.MapServer.leave(1, char_id)
    catch
      :exit, _ -> :ok
    end

    AoSession.OnlineDirectory.unregister(char_id)
    AoSession.unregister(char_id)
  end

  defp start_if_needed(name, start_fun) do
    case Process.whereis(name) do
      nil -> start_fun.()
      _pid -> :ok
    end
  end

  defp assert_socket_closed(socket, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll_closed(socket, deadline)
  end

  defp poll_closed(socket, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      flunk("Socket was not closed within timeout")
    else
      case :gen_tcp.recv(socket, 0, min(remaining, 100)) do
        {:error, :closed} -> :ok
        {:ok, _data} -> poll_closed(socket, deadline)
        {:error, :timeout} -> poll_closed(socket, deadline)
        {:error, _other} -> :ok
      end
    end
  end
end
