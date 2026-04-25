defmodule AoTcpGateway.MetricsHandler do
  @moduledoc """
  Cowboy HTTP handler for Prometheus scrapes.

  Mounted at `/metrics` on the WebSocket listener. Returns the
  text-format exposition body produced by `Arena.PromEx.scrape/0`.
  Only `GET` is supported; everything else returns 405.
  """

  def init(req, state) do
    case :cowboy_req.method(req) do
      "GET" ->
        body = Arena.PromEx.scrape()

        req =
          :cowboy_req.reply(
            200,
            %{"content-type" => "text/plain; version=0.0.4; charset=utf-8"},
            body,
            req
          )

        {:ok, req, state}

      _ ->
        req =
          :cowboy_req.reply(
            405,
            %{"content-type" => "text/plain; charset=utf-8", "allow" => "GET"},
            "Method Not Allowed\n",
            req
          )

        {:ok, req, state}
    end
  end
end
