defmodule Arena.Map.Gm.Permissions do
  @moduledoc """
  VB6-compatible GM permission tiers.

  Hierarchy (highest to lowest):
    :admin > :dios > :semi_dios > :consejero

  Each tier inherits all permissions from the tiers below it.

  - Consejero: inspection commands only (/INFO, /LOCATE, /ONLINEMAP, /CHARSTATS, etc.)
  - SemiDios:  above + moderation (/KICK, /MUTE, /JAIL, /KILL) + teleport (/GOTO, /TELEPORT) + world inspection
  - Dios:      above + character editing (/EDITCHAR, /GIVEITEM, /REVIVE) + NPC spawn + world modification
  - Admin:     all commands including /BAN, /BANCUENTA, /KICKALLCHARS, server admin
  """

  @type gm_level :: :admin | :dios | :semi_dios | :consejero | nil

  # Numeric tier for comparison (higher = more privilege)
  defp tier_rank(:admin), do: 4
  defp tier_rank(:dios), do: 3
  defp tier_rank(:semi_dios), do: 2
  defp tier_rank(:consejero), do: 1
  defp tier_rank(_), do: 0

  @doc """
  Returns true if the entity's gm_level has at least the required tier.

  If the entity has no gm_level set (nil) but gm == true, it is treated
  as :admin for backwards compatibility.
  """
  def has_tier?(entity, required_tier) do
    level = effective_gm_level(entity)
    tier_rank(level) >= tier_rank(required_tier)
  end

  @doc """
  Returns the effective GM level for an entity.

  Backwards-compatible: if gm == true but gm_level is nil, defaults to :admin.
  """
  def effective_gm_level(entity) do
    cond do
      Map.get(entity, :gm_level) != nil -> entity.gm_level
      Map.get(entity, :gm, false) -> :admin
      true -> nil
    end
  end

  @doc """
  Returns the minimum GM tier required for a given command (uppercased first word).

  Commands not listed here default to :admin (safest default).
  """
  def required_tier(command) do
    case command do
      # Inspection (consejero)
      cmd when cmd in ~w(
        /INFO /LOCATE /ONLINEMAP /CHARSTATS /CHARGOLD
        /CHARINV /CHARBANK /CHARSKILLS /CHECKSLOT
        /CREATURES /SPAWNLIST
        /ONLINE /WHERECHAR
      ) ->
        :consejero

      # Moderation + teleport (semi_dios)
      cmd when cmd in ~w(
        /KICK /MUTE /UNMUTE /JAIL /UNJAIL /KILL
        /GOTO /TELEPORT /SUMMON
        /COUNCILKICK /ROYALKICK /CHAOSKICK
        /REMOVEPUNISHMENT
        /NAVIGANDO /RMCRIMINAL /RMCITIZEN
      ) ->
        :semi_dios

      # Character editing + NPC + world modification (dios)
      cmd when cmd in ~w(
        /GIVEITEM /EDITCHAR /ALTERNAME /REVIVE /SHOWNAME /SETDESC /SETSPEED
        /SPAWNNPC /SPAWNNPCR /KILLNPC /KILLNPCPERM /MASSKILL
        /SPAWNITEM /INVISIBLE
        /NIEVE /NIEBLA /MAPPK /MAPNOMAGIC /MAPNOINVI /MAPNORESU
        /TILEBLOCK /SETTRIGGER /ASKTRIGGER
        /DESTROYITEMS /DESTROYALLAREA
        /FORCEMIDIMAP /FORCEWAVEMAP
        /ITEMSFLOOR
        /RMSG /CMSG /TALKASNPC
        /ROYALCOUNCIL /CHAOSCOUNCIL
        /INVASION
        /TOURNAMENT /EVENT
        /RAIN /SETBODY /SETHEAD /SETSKIN /SETGOLD /SETLEVEL /SETSKILL /SPAWN
      ) ->
        :dios

      # Admin-only
      cmd when cmd in ~w(
        /BAN /BANCUENTA /UNBANCUENTA /BANTEMPORAL
        /KICKALLCHARS /CLEANWORLD
        /UNBAN /IPCHAR /SYSTEMINFO
      ) ->
        :admin

      # Unknown commands default to admin
      _ ->
        :admin
    end
  end

  @doc """
  Checks whether an entity has permission to execute the given command string.

  Returns :ok or {:error, message}.
  """
  def check_permission(entity, message) do
    command =
      message
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first("")
      |> String.upcase()

    required = required_tier(command)

    if has_tier?(entity, required) do
      :ok
    else
      {:error, "Insufficient GM level for #{command}. Required: #{required}."}
    end
  end
end
