defmodule AoTcpGateway.FixtureReplayTest do
  @moduledoc """
  Replay real (or synthetic) VB6 packet capture fixtures against the server.

  Each fixture is a `.bin` file containing raw AO20 client packets paired with
  a `.json` sidecar describing the expected server response packet IDs. The test
  opens a TCP connection, replays the client packets, and verifies the server
  responds with at least the expected packet IDs.

  Fixtures live in `test/fixtures/packet_captures/`. If no fixtures exist the
  test suite is skipped gracefully.
  """

  use ExUnit.Case, async: false

  alias AoProtocol.Writer
  alias AoTcpGateway.TestPacketDecoder, as: Decoder

  @moduletag :fixture

  @fixtures_dir Path.expand("fixtures/packet_captures", __DIR__)
  @connect_timeout 2000

  # ── Generate synthetic .bin at compile time so fixtures are available ──

  @synthetic_bin Path.join(@fixtures_dir, "login_synthetic_001.bin")

  unless File.exists?(@synthetic_bin) do
    File.mkdir_p!(@fixtures_dir)

    token = "test_token"
    name = "FixtureBot_1"
    md5 = "abcdef1234567890abcdef1234567890"

    payload =
      <<10::little-signed-16, token::binary,
        12::little-signed-16, name::binary,
        1::8, 0::8, 0::8,
        32::little-signed-16, md5::binary,
        1::8, 1::8, 6::8,
        1::little-signed-16,
        1::8>>

    packet = <<74::little-signed-16, payload::binary>>
    File.write!(@synthetic_bin, packet)
  end

  # ── Discover fixtures at compile time ──

  @fixture_pairs (
    if File.dir?(@fixtures_dir) do
      @fixtures_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".bin"))
      |> Enum.sort()
      |> Enum.flat_map(fn bin_name ->
        json_name = String.replace_suffix(bin_name, ".bin", ".json")
        json_full = Path.join(@fixtures_dir, json_name)

        if File.exists?(json_full) do
          [{Path.join(@fixtures_dir, bin_name), json_full}]
        else
          []
        end
      end)
    else
      []
    end
  )

  # ── setup_all: shared infrastructure (same as packet_trace_replay_test) ──

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
    owner_pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GameBackend.Repo, shared: true)

    listener_name = :"fixture_listener_#{System.unique_integer([:positive])}"

    {:ok, _} =
      :ranch.start_listener(
        listener_name,
        :ranch_tcp,
        [port: 0],
        AoTcpGateway.ClientHandler,
        []
      )

    port = :ranch.get_port(listener_name)

    on_exit(fn ->
      :ranch.stop_listener(listener_name)
      Process.sleep(200)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner_pid)
    end)

    %{port: port}
  end

  # ── Dynamic fixture tests ──

  if @fixture_pairs == [] do
    test "no fixture files found -- skipping", _context do
      IO.puts("\n  No .bin fixtures in #{@fixtures_dir}; skipping fixture replay tests.")
      :ok
    end
  end

  for {bin_path, json_path} <- @fixture_pairs do
    base = Path.basename(bin_path, ".bin")

    @tag fixture_bin: bin_path
    @tag fixture_json: json_path

    test "replay fixture: #{base}", %{port: port} do
      bin_path = unquote(bin_path)
      json_path = unquote(json_path)

      client_bytes = File.read!(bin_path)
      meta = json_path |> File.read!() |> Jason.decode!()

      expected_ids = Map.get(meta, "expected_server_packets", [])

      # Connect and replay
      {:ok, socket} =
        :gen_tcp.connect(
          ~c"localhost",
          port,
          [:binary, active: false, packet: :raw],
          @connect_timeout
        )

      # Patch synthetic login fixtures so each run uses a unique character name
      # to avoid DB conflicts between test runs.
      client_bytes = maybe_patch_unique_name(client_bytes, meta)

      :ok = :gen_tcp.send(socket, client_bytes)

      # Wait for all expected packets
      packets =
        if expected_ids != [] do
          Decoder.recv_until_all_packets(socket, expected_ids, 5_000)
        else
          Process.sleep(500)
          Decoder.decode_all_packets(Decoder.recv_all(socket))
        end

      received_ids = Decoder.packet_ids(packets) |> Enum.uniq()

      for expected_id <- expected_ids do
        assert expected_id in received_ids,
               "Fixture #{Path.basename(bin_path)}: expected server packet #{expected_id} " <>
                 "but got #{inspect(received_ids)}"
      end

      # Cleanup: if this was a login fixture, clean up the character
      cleanup_after_fixture(meta)

      :gen_tcp.close(socket)
    end
  end

  # ── Helpers ──

  defp start_if_needed(name, start_fun) do
    case Process.whereis(name) do
      nil -> start_fun.()
      _pid -> :ok
    end
  end

  # For synthetic login fixtures, patch the character name to a unique one
  # so concurrent/repeated runs don't collide.
  defp maybe_patch_unique_name(client_bytes, %{"client_packets" => [74 | _]} = meta) do
    if Map.get(meta, "synthetic", false) do
      unique_name = "FxBot_#{System.unique_integer([:positive])}"
      Process.put(:fixture_char_name, unique_name)

      token = "test_token"
      md5 = "abcdef1234567890abcdef1234567890"

      payload =
        Writer.write_string8(token) <>
          Writer.write_string8(unique_name) <>
          Writer.write_int8(1) <>
          Writer.write_int8(0) <>
          Writer.write_int8(0) <>
          Writer.write_string8(md5) <>
          Writer.write_int8(1) <>
          Writer.write_int8(1) <>
          Writer.write_int8(6) <>
          Writer.write_int16(1) <>
          Writer.write_int8(1)

      Writer.build_packet(74, payload)
    else
      client_bytes
    end
  end

  defp maybe_patch_unique_name(client_bytes, _meta), do: client_bytes

  defp cleanup_after_fixture(%{"client_packets" => packets} = _meta) do
    if 74 in packets do
      name = Process.get(:fixture_char_name)

      if name do
        try do
          case GameBackend.Characters.get_by_name(name) do
            nil ->
              :ok

            char ->
              try do
                Arena.Map.MapServer.leave(1, char.id)
              catch
                :exit, _ -> :ok
              end

              AoSession.OnlineDirectory.unregister(char.id)
              AoSession.unregister(char.id)
          end
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp cleanup_after_fixture(_meta), do: :ok
end
