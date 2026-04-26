defmodule Arena.Map.Effects do
  @moduledoc """
  Constructors and runner for `Arena.Map.Effect.t()` lists produced by
  map-layer handlers.

  Handlers stay char_id-keyed and never see a session pid. The constructors
  wrap an encoded packet binary into a backpressure envelope (via
  `AoSession.Outbound.from_class/3`) using `AoProtocol.Classify` for the
  default class. Use the `class:` and `coalesce_key:` keyword overrides
  when the call site knows better than the classifier.

  The runner resolves char_id → session pid against `state.sessions` and
  routes envelopes through `AoSession.Egress.enqueue/2` so producer packets
  always traverse the backpressure layer, never the legacy
  `{:send_raw, _}` shim.

  Unknown effects raise — silent drops would let typos pass tests by
  accident.

  Note: `AoSession.Outbound` and `AoSession.Egress` are runtime-only
  references (declared in `arena/mix.exs` xref excludes), so we call them
  as remote functions and never construct the struct via `%Outbound{}`
  literal.

  ## MapServer dispatch convention

  Handlers migrated to this contract return `{:ok, state, effects}`. The
  MapServer adapter is uniform: call `run_handler/2` with the state and a
  closure that produces `{:ok, state', effects}`. The runner executes the
  effects against the post-handler state and returns `{:noreply, state'}`
  for the GenServer cast.

      def handle_cast({:rest, char_id}, state),
        do: Effects.run_handler(state, fn s -> Healing.handle_rest(s, char_id) end)

  Future migrations (NpcInteraction, Faction, etc.) should follow the same
  shape so the cast bodies stay one-liners and side effects stay confined
  to the runner.
  """

  alias Arena.Map.{Helpers, Visibility}

  ## Constructors ────────────────────────────────────────────────────────

  @doc """
  Unicast `packet` to the player's session.

  `packet` is an encoded server packet (binary). The default egress class
  is derived from `AoProtocol.Classify.class_for/1` keyed by the packet ID
  (the first two bytes, little-endian). Pass `class:` to override and
  `coalesce_key:` to override the coalesce key for `:coalesce` packets.
  """
  @spec send(term(), binary(), keyword()) :: Arena.Map.Effect.t()
  def send(char_id, packet, opts \\ []) when is_binary(packet) do
    {:send, char_id, build_envelope(packet, opts)}
  end

  @doc "Broadcast `packet` to every player whose AoI covers (x, y), excluding origin."
  @spec broadcast_visible(pos_integer(), pos_integer(), binary(), keyword()) ::
          Arena.Map.Effect.t()
  def broadcast_visible(x, y, packet, opts \\ []) when is_binary(packet) do
    {:broadcast_visible, x, y, build_envelope(packet, opts)}
  end

  @doc "Broadcast `packet` to every player whose AoI covers (x, y), including origin."
  @spec broadcast_visible_all(pos_integer(), pos_integer(), binary(), keyword()) ::
          Arena.Map.Effect.t()
  def broadcast_visible_all(x, y, packet, opts \\ []) when is_binary(packet) do
    {:broadcast_visible_all, x, y, build_envelope(packet, opts)}
  end

  @doc "Broadcast a character_change packet for `entity` to its visibility region."
  @spec broadcast_character_change(map()) :: Arena.Map.Effect.t()
  def broadcast_character_change(entity) do
    {:broadcast_character_change, entity}
  end

  @doc """
  Broadcast `packet` to every session on the map, ignoring AoI.

  Used for global announcements (marriage, world weather/audio). The
  envelope is built via the classifier (same as `send/3` /
  `broadcast_visible/3`); pass `class:` / `coalesce_key:` to override.
  """
  @spec broadcast_map(binary(), keyword()) :: Arena.Map.Effect.t()
  def broadcast_map(packet, opts \\ []) when is_binary(packet) do
    {:broadcast_map, build_envelope(packet, opts)}
  end

  @doc """
  Fan a `character_remove` packet to every nearby non-GM session for
  `entity`. Used when the entity becomes invisible / oculto.
  """
  @spec hide_from_non_gm(map()) :: Arena.Map.Effect.t()
  def hide_from_non_gm(entity) do
    {:hide_from_non_gm, entity}
  end

  @doc """
  Transfer the player to `(dest_map, dest_x, dest_y)`.

  The runner resolves `char_id` against `state.sessions` and sends the bare
  `{:transfer, dest_map, dest_x, dest_y, entity}` tuple expected by
  `AoTcpGateway.WsHandler` / `AoTcpGateway.ClientHandler`. Not envelope-wrapped:
  transfers are out-of-band of the egress queue.
  """
  @spec transfer(term(), pos_integer(), pos_integer(), pos_integer(), map()) ::
          Arena.Map.Effect.t()
  def transfer(char_id, dest_map, dest_x, dest_y, entity) do
    {:transfer, char_id, dest_map, dest_x, dest_y, entity}
  end

  defp build_envelope(packet, opts) when is_binary(packet) do
    {default_class, default_key} =
      case packet do
        <<id::little-signed-integer-16, _::binary>> ->
          {AoProtocol.Classify.class_for(id), AoProtocol.Classify.coalesce_key_for(id)}

        _ ->
          {:critical, nil}
      end

    class = Keyword.get(opts, :class, default_class)
    key = Keyword.get(opts, :coalesce_key, default_key)
    AoSession.Outbound.from_class(class, packet, key)
  end

  ## Runner ──────────────────────────────────────────────────────────────

  @spec run(map(), [Arena.Map.Effect.t()]) :: :ok
  def run(_state, []), do: :ok

  def run(state, effects) when is_list(effects) do
    Enum.each(effects, &dispatch(state, &1))
  end

  @doc """
  Adapter used by MapServer casts that delegate to a handler returning
  `{:ok, state, effects}`. Runs the produced effects against the new state
  and returns `{:noreply, state}` so the cast body stays one line.

  Example:

      def handle_cast({:rest, char_id}, state),
        do: Effects.run_handler(state, fn s -> Healing.handle_rest(s, char_id) end)
  """
  @spec run_handler(map(), (map() -> {:ok, map(), [Arena.Map.Effect.t()]})) ::
          {:noreply, map()}
  def run_handler(state, fun) when is_function(fun, 1) do
    {:ok, state, effects} = fun.(state)
    run(state, effects)
    {:noreply, state}
  end

  @doc """
  `handle_call` variant of `run_handler/2` — runs the handler, executes its
  effects, and returns `{:reply, :ok, state}`. Handler contract is identical
  to the cast variant (`{:ok, state, effects}`); rejection is communicated
  via console-message effects rather than a non-`:ok` reply term, keeping
  the contract uniform across cast and call dispatch.
  """
  @spec run_handler_call(map(), (map() -> {:ok, map(), [Arena.Map.Effect.t()]})) ::
          {:reply, :ok, map()}
  def run_handler_call(state, fun) when is_function(fun, 1) do
    {:ok, state, effects} = fun.(state)
    run(state, effects)
    {:reply, :ok, state}
  end

  @doc """
  Like `run_handler_call/2` but the handler returns its own reply term:
  `{:ok, state, reply, effects}`.

  Used by handlers whose downstream callers depend on a richer reply than
  `:ok` (e.g. `Social.handle_deduct_gold/3` returns `{:ok, new_gold}` /
  `{:error, reason}` because the gateway's faction-donation flow branches
  on the reply). Rejection is the reply value itself; effects still run.
  """
  @spec run_handler_call_reply(
          map(),
          (map() -> {:ok, map(), term(), [Arena.Map.Effect.t()]})
        ) :: {:reply, term(), map()}
  def run_handler_call_reply(state, fun) when is_function(fun, 1) do
    {:ok, state, reply, effects} = fun.(state)
    run(state, effects)
    {:reply, reply, state}
  end

  defp dispatch(state, {:send, char_id, outbound}) do
    Helpers.send_outbound(state.sessions, char_id, outbound)
  end

  defp dispatch(state, {:broadcast_visible, x, y, outbound}) do
    Visibility.broadcast_visible(state, x, y, nil, fn pid ->
      AoSession.Egress.enqueue(pid, outbound)
    end)
  end

  defp dispatch(state, {:broadcast_visible_all, x, y, outbound}) do
    Visibility.broadcast_visible_all(state, x, y, fn pid ->
      AoSession.Egress.enqueue(pid, outbound)
    end)
  end

  defp dispatch(state, {:broadcast_map, outbound}) do
    Visibility.broadcast_to_map(state, fn pid ->
      AoSession.Egress.enqueue(pid, outbound)
    end)
  end

  defp dispatch(state, {:broadcast_character_change, entity}) do
    Helpers.broadcast_character_change(state, entity)
  end

  defp dispatch(state, {:hide_from_non_gm, entity}) do
    Visibility.hide_from_non_gm(state, entity)
  end

  defp dispatch(state, {:transfer, char_id, dest_map, dest_x, dest_y, entity}) do
    case Map.get(state.sessions, char_id) do
      nil -> :ok
      pid -> Kernel.send(pid, {:transfer, dest_map, dest_x, dest_y, entity})
    end
  end

  defp dispatch(_state, other) do
    raise ArgumentError, "Arena.Map.Effects: unknown effect #{inspect(other)}"
  end
end
