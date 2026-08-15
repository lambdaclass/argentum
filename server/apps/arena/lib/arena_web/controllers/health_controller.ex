defmodule ArenaWeb.HealthController do
  use ArenaWeb, :controller

  @doc """
  Liveness plus world readiness.

  Reports 503 while the world is still booting or came up degraded. A server
  whose maps did not all load still accepts logins, and players who land on a
  missing map simply cannot move — indistinguishable from a client bug unless
  something says so. This is that something.
  """
  def check(conn, _params) do
    status = Arena.Map.MapSupervisor.boot_status()

    case status.state do
      :ready ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ok", maps_ready: status.ready, maps_total: status.total})

      :booting ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "booting",
          maps_ready: status.ready,
          maps_total: status.total,
          detail: "World is still loading. Movement on unloaded maps will not work yet."
        })

      :degraded ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "degraded",
          maps_ready: status.ready,
          maps_total: status.total,
          not_ready: Enum.take(status.not_ready, 20),
          detail: "Map boot timed out. Players on the missing maps cannot move. Restart the server."
        })
    end
  end

  def version(conn, _params) do
    conn
    |> put_status(:ok)
    |> text(Application.spec(:arena, :vsn))
  end
end
