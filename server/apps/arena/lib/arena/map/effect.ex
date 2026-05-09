defmodule Arena.Map.Effect do
  @moduledoc """
  Canonical map-layer side effects.

  Map handlers stay pure: they take state, return `{:ok, state, [Effect.t()]}`,
  and never call sockets, broadcasts, or persistence directly. The
  `Arena.Map.Effects` runner interprets the list after the handler returns.

  ## Constructor / runtime shape

  Producers MUST build effects through `Arena.Map.Effects.*` constructors,
  never raw tuple literals. The constructors classify the packet via
  `AoProtocol.Classify` and wrap it in an `AoSession.Outbound` envelope so
  every packet that hits the runner already carries its egress class
  (`:critical | :lossy | :coalesce`) and coalesce key. Tests pattern-match
  on `%{payload: <<id::little-signed-integer-16, _::binary>>}` — that's
  the post-wrap shape.

  Bare-tuple shapes from before the outbound migration (e.g. `{:send,
  char_id, raw_iodata_packet}`) are no longer accepted: `Effects.send/3`
  raises if `packet` isn't a binary, and the dispatch in `Effects` only
  understands `%Outbound{}` envelopes.

  Two effect kinds carry their entity payload directly instead of an
  envelope: `:broadcast_character_change`, `:hide_from_non_gm`,
  `:reveal_to_non_gm` — the runner builds the packet at dispatch time
  from the entity (visibility / appearance can change between handler
  return and dispatch).

  `:transfer` is also envelope-free — it's out-of-band of the egress
  queue (transfers must not be coalesced or shed).

  ## Effect kinds

    * `{:send, char_id, %Outbound{}}` — unicast through
      `AoSession.Egress.enqueue/2`.
    * `{:broadcast_visible, x, y, %Outbound{}}` — fan to every session
      whose AoI covers `(x, y)`, excluding origin where the helper
      enforces it.
    * `{:broadcast_visible_all, x, y, %Outbound{}}` — same fan, includes
      origin (ground-item create/delete, NPC create/move, etc.).
    * `{:broadcast_visible_except, x, y, exclude_char_id, %Outbound{}}` —
      fan to every visible session whose `char_id` is not
      `exclude_char_id`. Used for animation packets like `char_swing`.
    * `{:broadcast_map, %Outbound{}}` — every session on the map,
      ignoring AoI. Used for global announcements (marriage,
      world-state).
    * `{:broadcast_character_change, entity}` — runner re-encodes
      `character_change` from the live entity.
    * `{:hide_from_non_gm, entity}` — runner fans `character_remove` to
      every nearby non-GM session (entity went invisible / oculto).
    * `{:reveal_to_non_gm, entity}` — symmetric counterpart: runner fans
      `character_create` (break_invisibility, RemoveInvisibility spell,
      status-tick expiry).
    * `{:transfer, char_id, dest_map, dest_x, dest_y, entity}` — runner
      resolves `char_id` and sends the bare transfer tuple expected by
      the session handlers (`AoTcpGateway.WsHandler`,
      `AoTcpGateway.ClientHandler`). Out-of-band of the egress queue.

  Future kinds (`:persist_character`, `:telemetry`, `:log`) are declared
  in the typespec when their first migration target lands; the runner
  fails loudly on unknown effects rather than silently dropping.

  ## Why tagged tuples and not structs

  Tagged tuples keep cognitive overhead low and pattern-match cheaply in
  the runner. `Arena.NpcAi` previously had its own three-tuple effect
  shape with a private dispatcher; the unification folded it into this
  contract so every map-layer producer (handlers, status ticks, NPC AI)
  emits the same `Effect.t()` and goes through `Arena.Map.Effects.run/2`.
  """

  @typedoc """
  Outbound envelope produced by the constructors. Concrete struct lives
  in the `ao_session` app (`AoSession.Outbound`); arena depends on it
  only at runtime via xref excludes, so we type it as opaque from the
  arena side.
  """
  @type envelope :: term()

  @type char_id :: term()
  @type coord :: pos_integer()

  @type t ::
          {:send, char_id(), envelope()}
          | {:broadcast_visible, coord(), coord(), envelope()}
          | {:broadcast_visible_all, coord(), coord(), envelope()}
          | {:broadcast_visible_except, coord(), coord(), char_id(), envelope()}
          | {:broadcast_map, envelope()}
          | {:broadcast_character_change, entity :: map()}
          | {:hide_from_non_gm, entity :: map()}
          | {:reveal_to_non_gm, entity :: map()}
          | {:transfer, char_id(), dest_map :: pos_integer(), coord(), coord(),
             entity :: map()}
end
