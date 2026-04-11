defmodule Mix.Tasks.Capture.Packets do
  @moduledoc """
  TCP proxy that captures raw AO20 packet traffic between a VB6 client and the
  game server, writing `.bin` + `.json` fixture pairs.

  ## Usage

      mix capture.packets [--port 7700] [--server localhost:7666] [--output captures/]

  Options:
    --port    Port to listen on for client connections (default: 7700)
    --server  Upstream server host:port (default: localhost:7666)
    --output  Directory to write capture files (default: captures/)

  The proxy forwards traffic bidirectionally and logs raw bytes to timestamped
  files. Press Ctrl+C to stop.
  """

  use Mix.Task

  @shortdoc "Start a TCP packet-capture proxy for AO20 traffic"

  @default_port 7700
  @default_server "localhost:7666"
  @default_output "captures/"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [port: :integer, server: :string, output: :string]
      )

    listen_port = Keyword.get(opts, :port, @default_port)
    server_str = Keyword.get(opts, :server, @default_server)
    output_dir = Keyword.get(opts, :output, @default_output)

    {server_host, server_port} = parse_server(server_str)

    File.mkdir_p!(output_dir)

    Mix.shell().info(
      "Capture proxy listening on port #{listen_port}, forwarding to #{server_host}:#{server_port}"
    )

    Mix.shell().info("Writing captures to #{output_dir}")
    Mix.shell().info("Press Ctrl+C to stop.\n")

    {:ok, listen_socket} =
      :gen_tcp.listen(listen_port, [
        :binary,
        active: false,
        reuseaddr: true,
        packet: :raw
      ])

    accept_loop(listen_socket, server_host, server_port, output_dir)
  end

  defp parse_server(server_str) do
    case String.split(server_str, ":") do
      [host, port_str] -> {String.to_charlist(host), String.to_integer(port_str)}
      [host] -> {String.to_charlist(host), 7666}
    end
  end

  defp accept_loop(listen_socket, server_host, server_port, output_dir) do
    {:ok, client_socket} = :gen_tcp.accept(listen_socket)
    session_id = System.os_time(:millisecond)

    Mix.shell().info("[#{session_id}] New client connection")

    spawn(fn ->
      handle_session(client_socket, server_host, server_port, output_dir, session_id)
    end)

    accept_loop(listen_socket, server_host, server_port, output_dir)
  end

  defp handle_session(client_socket, server_host, server_port, output_dir, session_id) do
    case :gen_tcp.connect(server_host, server_port, [:binary, active: false, packet: :raw], 5000) do
      {:ok, server_socket} ->
        client_ref = make_ref()
        server_ref = make_ref()
        parent = self()

        _client_data = :atomics.new(1, signed: false)
        _server_data = :atomics.new(1, signed: false)

        client_buf = Agent.start_link(fn -> <<>> end) |> elem(1)
        server_buf = Agent.start_link(fn -> <<>> end) |> elem(1)

        # Client -> Server relay
        spawn(fn ->
          relay_loop(client_socket, server_socket, client_buf, parent, client_ref)
        end)

        # Server -> Client relay
        spawn(fn ->
          relay_loop(server_socket, client_socket, server_buf, parent, server_ref)
        end)

        # Wait for either direction to close
        receive do
          {:closed, _ref} -> :ok
        end

        # Give a moment for remaining data
        Process.sleep(200)

        # Collect captured data
        client_bytes = Agent.get(client_buf, & &1)
        server_bytes = Agent.get(server_buf, & &1)

        # Write captures
        write_capture(output_dir, session_id, client_bytes, server_bytes)

        :gen_tcp.close(client_socket)
        :gen_tcp.close(server_socket)
        Agent.stop(client_buf)
        Agent.stop(server_buf)

        Mix.shell().info("[#{session_id}] Session ended, capture written")

      {:error, reason} ->
        Mix.shell().error("[#{session_id}] Cannot connect to upstream: #{inspect(reason)}")
        :gen_tcp.close(client_socket)
    end
  end

  defp relay_loop(from_socket, to_socket, buf_agent, parent, ref) do
    case :gen_tcp.recv(from_socket, 0, 30_000) do
      {:ok, data} ->
        :gen_tcp.send(to_socket, data)
        Agent.update(buf_agent, fn acc -> acc <> data end)
        relay_loop(from_socket, to_socket, buf_agent, parent, ref)

      {:error, :timeout} ->
        relay_loop(from_socket, to_socket, buf_agent, parent, ref)

      {:error, _reason} ->
        send(parent, {:closed, ref})
    end
  end

  defp write_capture(output_dir, session_id, client_bytes, server_bytes) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9T]/, "")
    base = "capture_#{ts}_#{session_id}"

    bin_path = Path.join(output_dir, "#{base}.bin")
    json_path = Path.join(output_dir, "#{base}.json")

    # Write raw client->server bytes as the .bin fixture
    File.write!(bin_path, client_bytes)

    # Extract packet IDs from both directions
    client_ids = extract_packet_ids(client_bytes)
    server_ids = extract_packet_ids(server_bytes)

    metadata = %{
      description: "Captured session #{session_id}",
      expected_server_packets: Enum.uniq(server_ids),
      client_packets: Enum.uniq(client_ids),
      captured_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(json_path, Jason.encode!(metadata, pretty: true))

    Mix.shell().info("[#{session_id}] Wrote #{bin_path} (#{byte_size(client_bytes)} bytes)")
    Mix.shell().info("[#{session_id}] Wrote #{json_path}")
  end

  defp extract_packet_ids(<<>>), do: []
  defp extract_packet_ids(data) when byte_size(data) < 2, do: []

  defp extract_packet_ids(<<packet_id::little-signed-16, rest::binary>>) do
    [packet_id | extract_packet_ids(rest)]
  end
end
