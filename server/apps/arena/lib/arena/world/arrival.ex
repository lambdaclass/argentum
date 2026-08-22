defmodule Arena.World.Arrival do
  @moduledoc """
  Whether a character may be put down where an exit says.

  `Arena.Map.Movement.check_tile_exit/5` has always transferred a character to whatever tile
  an exit named, consulting neither the destination nor the character. `W-0097` measured what
  that admits across the corpus: **2,877 exits point at solid ground (169 of them reachable
  today), 48 at a tile the destination map does not draw at all (24 reachable), and 4 put a
  walker on water**. Nobody has to decide whether a player should end up inside rock, so this
  is a defect with a rule rather than a question with an owner.

  The rule:

    * solid destination — refuse, for everyone
    * undrawn destination — refuse, for everyone; a tile with no ground is not a place, and
      the blocked layer says nothing about whether a tile exists
    * water destination — refuse a walking character, accept a navigating one
    * walkable destination — accept either, which preserves today's boat beaching; whether a
      ship should be able to run aground is a separate content decision and is not smuggled
      in here

  Validation happens *before* the character leaves the source MapServer, so a refusal costs
  nothing: they keep their position and their owner, and no handoff is begun that has to be
  unwound. The alternative — remove, then discover — is how a player ends up owned by nobody
  or by two servers at once.
  """

  alias Arena.Map.TileSemantics

  @type reason :: :arrival_solid | :arrival_void | :arrival_requires_boat
  @type verdict :: :ok | {:error, reason()}

  @doc """
  Judge an arrival from the destination tile's class, whether the destination map draws it,
  and how the character is travelling.

  Takes the class rather than the raw byte so there is one statement of what a byte means
  (`Arena.Map.TileSemantics`) and one statement of what an arrival requires (here).
  """
  @spec validate(TileSemantics.class(), boolean(), boolean()) :: verdict()
  def validate(_class, false = _drawn?, _navigating?), do: {:error, :arrival_void}
  def validate(:solid, _drawn?, _navigating?), do: {:error, :arrival_solid}
  def validate(:water, _drawn?, true = _navigating?), do: :ok
  def validate(:water, _drawn?, false = _navigating?), do: {:error, :arrival_requires_boat}
  def validate(:walkable, _drawn?, _navigating?), do: :ok

  @doc """
  The same judgement from a raw tile value.

  Convenience for callers holding a tile grid byte rather than a class; the class function is
  the one to prefer, because it cannot be handed a value whose meaning is in doubt.
  """
  @spec validate_value(integer(), boolean(), boolean()) :: verdict()
  def validate_value(tile_value, drawn?, navigating?) do
    validate(TileSemantics.class(tile_value), drawn?, navigating?)
  end

  @doc """
  Whether a verdict permits the transfer.
  """
  @spec allowed?(verdict()) :: boolean()
  def allowed?(:ok), do: true
  def allowed?({:error, _}), do: false

  @doc """
  A stable reason string for a receipt or a log.

  Typed rather than free text: the eventual `arrival_blocked` receipt and the legacy
  adapter's correction sequence both need to name the same thing, and a message a client
  parses must not be prose somebody can reword.
  """
  @spec reason_name(reason()) :: String.t()
  def reason_name(:arrival_solid), do: "arrival_solid"
  def reason_name(:arrival_void), do: "arrival_void"
  def reason_name(:arrival_requires_boat), do: "arrival_requires_boat"
end
