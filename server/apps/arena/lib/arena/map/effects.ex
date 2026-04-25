defmodule Arena.Map.Effects do
  @moduledoc """
  Runner for `Arena.Map.Effect.t()` lists produced by map-layer handlers.

  Outbound packets reach the client through `Helpers.send_to_session/3` and
  the visibility broadcast helpers, the same paths the inline call sites
  used before the refactor. Behaviour is unchanged at the wire — only the
  call site moves.

  Unknown effects raise: silent drops would let typos pass tests by
  accident.
  """

  alias Arena.Map.{Helpers, Visibility}

  @spec run(map(), [Arena.Map.Effect.t()]) :: :ok
  def run(_state, []), do: :ok

  def run(state, effects) when is_list(effects) do
    Enum.each(effects, &dispatch(state, &1))
  end

  defp dispatch(state, {:send, char_id, packet}) do
    Helpers.send_to_session(state.sessions, char_id, {:send_raw, packet})
  end

  defp dispatch(state, {:broadcast_visible, x, y, packet}) do
    Visibility.broadcast_visible(state, x, y, nil, fn pid ->
      Kernel.send(pid, {:send_raw, packet})
    end)
  end

  defp dispatch(state, {:broadcast_visible_all, x, y, packet}) do
    Visibility.broadcast_visible_all(state, x, y, fn pid ->
      Kernel.send(pid, {:send_raw, packet})
    end)
  end

  defp dispatch(state, {:broadcast_character_change, entity}) do
    Helpers.broadcast_character_change(state, entity)
  end

  defp dispatch(_state, other) do
    raise ArgumentError, "Arena.Map.Effects: unknown effect #{inspect(other)}"
  end
end
