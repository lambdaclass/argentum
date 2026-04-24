defmodule AoSession.Outbound do
  @moduledoc """
  Envelope for all server→client packets.

  Every producer (visibility fan-out, combat, chat, commerce, etc.) wraps its
  encoded binary payload in an `%Outbound{}` before handing it to
  `AoSession.Egress.enqueue/2`. The class decides how the egress layer treats
  the packet under pressure:

    * `:critical` — must never be dropped or coalesced. Chat, combat, inventory,
      trade, commerce, transfers, character lifecycle (create/remove).
    * `:lossy`    — may be dropped under pressure. Visual-only packets whose
      absence does not desync game state: movement, heading, FX, ambient sound.
    * `:coalesce` — latest-wins per `coalesce_key`. Value-over-time updates
      where only the most recent sample matters: HP, mana, stamina, stats,
      mini-stats, weather, position updates.

  Construct envelopes with `critical/1`, `lossy/1`, `coalesce/2`. Do not invent
  new tuple shapes in producer modules — the envelope is the wire contract
  between producers and the egress layer.
  """

  @type class :: :critical | :lossy | :coalesce
  @type coalesce_key :: term()

  @enforce_keys [:class, :payload, :bytes]
  defstruct [:class, :payload, :bytes, :coalesce_key]

  @type t :: %__MODULE__{
          class: class(),
          payload: binary(),
          bytes: non_neg_integer(),
          coalesce_key: coalesce_key() | nil
        }

  @doc "Wrap a binary payload as critical — must be delivered."
  @spec critical(binary()) :: t()
  def critical(payload) when is_binary(payload) do
    %__MODULE__{class: :critical, payload: payload, bytes: byte_size(payload)}
  end

  @doc "Wrap a binary payload as lossy — may be dropped under pressure."
  @spec lossy(binary()) :: t()
  def lossy(payload) when is_binary(payload) do
    %__MODULE__{class: :lossy, payload: payload, bytes: byte_size(payload)}
  end

  @doc """
  Wrap a binary payload as coalescing — latest-wins on `key`.

  Two packets with the same `key` collapse to the newer payload. Callers choose
  keys that identify the logical stream, typically `{:hp, char_id}`,
  `{:mana, char_id}`, `{:weather, map_id}`, etc.
  """
  @spec coalesce(binary(), coalesce_key()) :: t()
  def coalesce(payload, key) when is_binary(payload) do
    %__MODULE__{
      class: :coalesce,
      payload: payload,
      bytes: byte_size(payload),
      coalesce_key: key
    }
  end

  @doc """
  Build an envelope from a precomputed class atom.

  Bridge helper for producers that consult a classifier (e.g.,
  `AoProtocol.Classify.class_for/1`) — they already have the class and
  payload, so they shouldn't have to re-branch on it here. For `:coalesce`
  without a key, falls back to `:critical` since silently dropping a
  value-over-time packet without a coalesce slot would be worse than
  buffering it.
  """
  @spec from_class(class(), binary(), coalesce_key() | nil) :: t()
  def from_class(class, payload, key \\ nil)

  def from_class(:critical, payload, _), do: critical(payload)
  def from_class(:lossy, payload, _), do: lossy(payload)
  def from_class(:coalesce, payload, nil), do: critical(payload)
  def from_class(:coalesce, payload, key), do: coalesce(payload, key)
end
