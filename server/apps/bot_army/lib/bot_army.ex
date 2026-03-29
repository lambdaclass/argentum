defmodule BotArmy do
  @moduledoc """
  Public API for the bot army load-testing tool.

  ## Usage

      BotArmy.spawn(100)        # Spawn 100 bots
      BotArmy.status()          # => %{total: 100, connected: 98, disconnected: 2}
      BotArmy.stop_all()        # Kill all bots
  """

  defdelegate spawn(count, opts \\ []), to: BotArmy.Swarm, as: :start
  defdelegate stop_all(), to: BotArmy.Swarm
  defdelegate status(), to: BotArmy.Swarm
  defdelegate metrics(), to: BotArmy.Swarm
  defdelegate reset_metrics(), to: BotArmy.Swarm
end
