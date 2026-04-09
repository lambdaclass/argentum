defmodule Arena.GuildAlignment do
  @moduledoc """
  VB6 guild alignment system (e_ALINEACION_GUILD).
  Determines which players can join a guild based on faction/criminal status.
  """

  @neutral 0
  @armada 1
  @caotica 2
  @ciudadana 3
  @criminal 4

  def neutral, do: @neutral
  def armada, do: @armada
  def caotica, do: @caotica
  def ciudadana, do: @ciudadana
  def criminal, do: @criminal

  @doc "Derive guild alignment from the founder's character state."
  def from_character(entity) do
    cond do
      entity.faction == :royal_army -> @armada
      entity.faction == :chaos_legion -> @caotica
      entity.criminal -> @criminal
      true -> @ciudadana
    end
  end

  @doc "Derive a player's alignment for membership checks."
  def player_alignment(entity) do
    cond do
      entity.faction == :royal_army -> @armada
      entity.faction == :chaos_legion -> @caotica
      entity.criminal -> @criminal
      true -> @ciudadana
    end
  end

  @doc """
  Check if a player alignment is compatible with a guild alignment.
  Neutral guilds accept anyone. Otherwise alignment must match.
  """
  def compatible?(guild_alignment, _player_alignment) when guild_alignment == @neutral, do: true
  def compatible?(guild_alignment, player_alignment), do: guild_alignment == player_alignment

  def name(@neutral), do: "Neutral"
  def name(@armada), do: "Armada Real"
  def name(@caotica), do: "Legion Oscura"
  def name(@ciudadana), do: "Ciudadana"
  def name(@criminal), do: "Criminal"
  def name(_), do: "Desconocida"
end
