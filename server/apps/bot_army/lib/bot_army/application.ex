defmodule BotArmy.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: BotArmy.BotSupervisor, strategy: :one_for_one, max_restarts: 0},
      {BotArmy.Swarm, []}
    ]

    opts = [strategy: :one_for_one, name: BotArmy.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
