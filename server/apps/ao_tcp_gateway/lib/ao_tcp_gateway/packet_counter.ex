defmodule AoTcpGateway.PacketCounter do
  @moduledoc """
  Anti-replay packet counter validation.

  VB6 clients send an incrementing counter with 13 packet types.
  The server validates that each counter is strictly greater than
  the last seen value. Duplicate or decreasing counters indicate
  packet replay (cheating) and trigger disconnect.

  Packet types with counters: talk, walk, attack, cast_spell, drop,
  equip_item, change_heading, use_item, left_click, work,
  guild_message, work_left_click, question_gm.
  """

  require Logger

  @counted_commands ~w(
    talk walk attack cast_spell drop equip_item change_heading
    use_item left_click work guild_message work_left_click question_gm
  )a

  @doc "Returns initial packet counter state (empty map)."
  def new, do: %{}

  @doc """
  Verify the packet counter for a command.

  Returns `{:ok, updated_counters}` if the counter is valid (strictly increasing),
  or `{:replay, updated_counters}` if a duplicate/decreasing counter is detected.

  Commands without a `packet_count` field pass through as valid.
  """
  def verify(counters, {command_name, %{packet_count: count}})
      when command_name in @counted_commands do
    last = Map.get(counters, command_name, 0)

    if count > last do
      {:ok, Map.put(counters, command_name, count)}
    else
      Logger.warning(
        "[ANTICHEAT] packet_replay command=#{command_name} count=#{count} last=#{last}"
      )

      {:replay, Map.put(counters, command_name, count)}
    end
  end

  # Commands without packet_count or not in the counted list pass through
  def verify(counters, _command), do: {:ok, counters}
end
