defmodule Arena.Map.Effect do
  @moduledoc """
  Canonical map-layer side effects.

  Map handlers stay pure: they take state, return `{:ok, state, [Effect.t()]}`,
  and never call sockets, broadcasts, or persistence directly. The
  `Arena.Map.Effects` runner interprets the list after the handler returns.

  ## Effect kinds

    * `{:send, char_id, packet}` — unicast a server packet (iodata) to one
      player session. Goes through `Helpers.send_to_session/3`.
    * `{:broadcast_visible, x, y, packet}` — send the packet to every player
      whose AoI covers `(x, y)`, excluding origin if the call site does so.
    * `{:broadcast_visible_all, x, y, packet}` — same, including origin.
    * `{:broadcast_character_change, entity}` — broadcasts a character_change
      packet for `entity` via the existing helper.
    * `{:transfer, char_id, dest_map, dest_x, dest_y, entity}` — instructs the
      player's session to transfer to `(dest_map, dest_x, dest_y)`. The runner
      resolves `char_id` against `state.sessions` and sends the bare
      `{:transfer, dest_map, dest_x, dest_y, entity}` tuple expected by the
      session handlers (`AoTcpGateway.WsHandler`, `AoTcpGateway.ClientHandler`).
      Not envelope-wrapped — transfers are out-of-band of the egress queue.

  Future kinds (`:persist_character`, `:telemetry`, `:log`) are declared in
  the typespec when their first migration target lands; the runner should
  fail loudly if it sees an unknown effect rather than silently dropping.

  ## Why tagged tuples and not structs

  The existing `Arena.NpcAi.dispatch_effects/2` already uses tagged tuples;
  matching that shape keeps cognitive overhead low and lets a future commit
  fold both runners together without a data migration.
  """

  @type packet :: iodata()
  @type char_id :: term()
  @type coord :: pos_integer()

  @type t ::
          {:send, char_id(), packet()}
          | {:broadcast_visible, coord(), coord(), packet()}
          | {:broadcast_visible_all, coord(), coord(), packet()}
          | {:broadcast_character_change, entity :: map()}
          | {:transfer, char_id(), dest_map :: pos_integer(), coord(), coord(),
             entity :: map()}
end
