defmodule AoTcpGateway.Listener do
  @moduledoc """
  Ranch-based TCP listener. Starts a ranch listener that spawns
  an AoTcpGateway.ClientHandler process for each accepted connection.
  """

  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)

    :ranch.child_spec(
      __MODULE__,
      :ranch_tcp,
      [port: port, max_connections: :infinity],
      AoTcpGateway.ClientHandler,
      []
    )
  end
end
