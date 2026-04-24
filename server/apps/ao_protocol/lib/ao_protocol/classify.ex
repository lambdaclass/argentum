defmodule AoProtocol.Classify do
  @moduledoc """
  Default egress class for server→client packets.

  The session backpressure layer (`AoSession.Egress`) classifies every
  outbound packet as `:critical`, `:lossy`, or `:coalesce`. Most producer
  modules already know the right class — e.g., movement fan-out is clearly
  lossy, a trade confirmation is clearly critical. But some call sites
  encode a packet by ID and shouldn't have to memorize the policy. This
  module is the single source of truth for that default.

    * `:critical` — must deliver: chat, combat, inventory/spell slots,
      commerce/bank/trade flows, character create/remove, map change, error
      messages. Dropping these desyncs game state or swallows a user-visible
      event.
    * `:lossy` — visual-only, replaceable by the next tick or a reconnect
      snapshot: character_move, FX, sounds, weather toggles.
    * `:coalesce` — value-over-time streams where only the newest sample
      matters: HP/mana/stamina/stats updates, position updates, mini-stats,
      hunger/thirst. Callers must supply a coalesce key (usually scoped by
      char_id or map_id).

  Unknown IDs default to `:critical`. Conservatively buffering an
  unclassified packet is safer than silently dropping it.
  """

  alias AoProtocol.PacketIds.Server, as: S

  @type class :: :critical | :lossy | :coalesce

  @doc "Returns the default class for a server packet ID."
  @spec class_for(integer()) :: class()
  def class_for(packet_id) when is_integer(packet_id) do
    cond do
      lossy?(packet_id) -> :lossy
      coalesce?(packet_id) -> :coalesce
      true -> :critical
    end
  end

  defp lossy?(id) do
    id == S.character_move() or
      id == S.create_fx() or
      id == S.play_wave() or
      id == S.play_midi() or
      id == S.rain_toggle() or
      id == S.snow_toggle() or
      id == S.pause_toggle() or
      id == S.area_changed()
  end

  defp coalesce?(id) do
    id == S.update_hp() or
      id == S.update_mana() or
      id == S.update_sta() or
      id == S.update_gold() or
      id == S.update_exp() or
      id == S.update_hunger_and_thirst() or
      id == S.update_user_stats() or
      id == S.mini_stats() or
      id == S.pos_update()
  end
end
