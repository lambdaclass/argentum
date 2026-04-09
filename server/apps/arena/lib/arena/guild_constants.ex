defmodule Arena.GuildConstants do
  @moduledoc """
  VB6 guild level constants. MAX_LEVEL_GUILD = 7.
  """

  @max_guild_level 7

  # Required XP to advance from level N to N+1.
  # VB6 values (approximated from modGuilds.bas progression).
  @required_exp %{
    1 => 500,
    2 => 1_500,
    3 => 4_000,
    4 => 10_000,
    5 => 25_000,
    6 => 60_000
  }

  def max_level, do: @max_guild_level

  def required_exp(level) when level >= @max_guild_level, do: :max
  def required_exp(level), do: Map.get(@required_exp, level, :max)
end
