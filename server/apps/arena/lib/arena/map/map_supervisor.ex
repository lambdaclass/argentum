defmodule Arena.Map.MapSupervisor do
  @moduledoc """
  Supervises map GenServer processes.

  Boot mode is controlled by `config :arena, boot_mode:`:
    - `:eager` (default) — start all maps found on disk at startup
    - `:lazy` — start maps on demand when a player enters

  Uses a DynamicSupervisor so maps can be started/stopped at runtime.
  """

  use DynamicSupervisor

  require Logger

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a map process under this supervisor."
  def start_map(map_id) do
    DynamicSupervisor.start_child(__MODULE__, {Arena.Map.MapServer, map_id})
  end

  @doc "Stop a running map process."
  def stop_map(map_id) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Boot maps based on the configured boot mode. Called after supervisor starts.

  In `:eager` mode, discovers and starts all map files from the maps directory.
  In `:lazy` mode, does nothing — maps are started on demand via `start_map/1`.
  """
  def boot_maps do
    case Application.get_env(:arena, :boot_mode, :eager) do
      :eager -> boot_all_maps()
      :lazy -> Logger.info("Lazy boot mode — maps will start on demand.")
    end
  end

  @doc "List all map IDs found on disk."
  def discover_map_ids do
    maps_dir = Application.get_env(:arena, :maps_dir, "../resources/raw/Mapas")

    case File.ls(maps_dir) do
      {:ok, files} ->
        files
        |> Enum.flat_map(fn name ->
          case Regex.run(~r/^mapa(\d+)\.csm$/i, name) do
            [_, id_str] -> [String.to_integer(id_str)]
            _ -> []
          end
        end)
        |> Enum.sort()

      {:error, reason} ->
        Logger.error("Cannot read maps directory #{maps_dir}: #{inspect(reason)}")
        []
    end
  end

  defp boot_all_maps do
    map_ids = discover_map_ids()
    Logger.info("Booting #{length(map_ids)} maps...")

    started =
      Enum.reduce(map_ids, 0, fn map_id, acc ->
        case start_map(map_id) do
          {:ok, _pid} -> acc + 1
          {:error, reason} ->
            Logger.error("Failed to start map #{map_id}: #{inspect(reason)}")
            acc
        end
      end)

    Logger.info("#{started}/#{length(map_ids)} map processes started, loading in background...")

    # Poll until all maps are ready or a timeout is reached.
    spawn(fn ->
      wait_all_ready(map_ids, 60_000, 1_000)
    end)
  end

  defp wait_all_ready(map_ids, timeout_ms, poll_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_all_ready(map_ids, deadline, poll_ms)
  end

  defp do_wait_all_ready(map_ids, deadline, poll_ms) do
    {ready, not_ready} =
      Enum.split_with(map_ids, fn id ->
        case Registry.lookup(Arena.MapRegistry, id) do
          [] -> false
          _ ->
            try do
              Arena.Map.MapServer.ready?(id)
            catch
              :exit, _ -> false
            end
        end
      end)

    cond do
      not_ready == [] ->
        Logger.info("All #{length(ready)} maps loaded and ready.")

      System.monotonic_time(:millisecond) >= deadline ->
        failed = length(not_ready)
        Logger.warning("Map boot timed out: #{length(ready)} ready, #{failed} still loading or failed (#{inspect(Enum.take(not_ready, 5))}...)")

      true ->
        Process.sleep(poll_ms)
        do_wait_all_ready(map_ids, deadline, poll_ms)
    end
  end
end
