defmodule ArenaWeb.HealthControllerTest do
  @moduledoc """
  Health must reflect world readiness, not just liveness.

  A server whose maps did not all finish booting still accepts logins, and a
  player who lands on a map with no MapServer simply cannot move — with nothing
  to distinguish it from a client bug. That happened, and cost a long debugging
  detour, so readiness is now reportable and 503s until the world is up.
  """
  use ExUnit.Case, async: false
  use Phoenix.ConnTest

  alias Arena.Map.MapSupervisor

  @endpoint ArenaWeb.Endpoint
  @boot_status_key {MapSupervisor, :boot_status}

  setup do
    previous = :persistent_term.get(@boot_status_key, nil)

    on_exit(fn ->
      if previous == nil do
        :persistent_term.erase(@boot_status_key)
      else
        :persistent_term.put(@boot_status_key, previous)
      end
    end)

    :ok
  end

  defp set_boot_status(status), do: :persistent_term.put(@boot_status_key, status)

  test "reports ok with map counts once the world is ready" do
    set_boot_status(%{state: :ready, ready: 843, total: 843, not_ready: []})

    payload = json_response(get(build_conn(), "/api/health"), 200)

    assert payload["status"] == "ok"
    assert payload["maps_ready"] == 843
    assert payload["maps_total"] == 843
  end

  test "503s while the world is still booting" do
    set_boot_status(%{state: :booting, ready: 100, total: 843, not_ready: [5, 6]})

    payload = json_response(get(build_conn(), "/api/health"), 503)

    assert payload["status"] == "booting"
    assert payload["maps_ready"] == 100
  end

  test "503s and names the missing maps when boot timed out" do
    not_ready = Enum.to_list(300..340)
    set_boot_status(%{state: :degraded, ready: 518, total: 843, not_ready: not_ready})

    payload = json_response(get(build_conn(), "/api/health"), 503)

    assert payload["status"] == "degraded"
    assert payload["maps_ready"] == 518
    assert payload["maps_total"] == 843
    # Enough to identify the problem without dumping hundreds of ids.
    assert length(payload["not_ready"]) == 20
    assert payload["detail"] =~ "cannot move"
  end

  test "defaults to booting when nothing has been recorded yet" do
    :persistent_term.erase(@boot_status_key)

    assert MapSupervisor.boot_status().state == :booting
    assert json_response(get(build_conn(), "/api/health"), 503)["status"] == "booting"
  end
end
