defmodule Arena.Test.Scenario.Assertions do
  @moduledoc """
  Gameplay-shape assertions over `Arena.Map.Effect.t()` lists captured
  by a scenario. Slice 1 supports `:send` only — broadcasts /
  character-change / hide / reveal / transfer arrive in later slices as
  needed.
  """

  alias Arena.Test.Scenario

  import ExUnit.Assertions

  @doc """
  Assert that the scenario emitted a `:send` effect to `to:` whose
  payload's first two bytes (the packet id) match
  `AoProtocol.PacketIds.Server.<packet>/0`.

      assert_effect(s, :send, to: :defender, packet: :user_hitted_by_user)

  When `packet:` is omitted, any `:send` to `to:` matches.
  """
  defmacro assert_effect(scenario, kind, opts \\ []) do
    quote do
      Arena.Test.Scenario.Assertions.__assert_effect__(
        unquote(scenario),
        unquote(kind),
        unquote(opts)
      )
    end
  end

  @doc false
  def __assert_effect__(%Scenario{} = scenario, :send, opts) do
    to = Keyword.fetch!(opts, :to)
    packet_id = packet_id_for(opts)

    matched =
      Enum.any?(Scenario.emitted_effects(scenario), fn
        {:send, ^to, %{payload: <<id::little-signed-integer-16, _::binary>>}} ->
          packet_id == nil or id == packet_id

        _ ->
          false
      end)

    assert matched,
           "expected :send to #{inspect(to)}#{packet_label(opts)}; got: #{inspect(Scenario.emitted_effects(scenario), pretty: true, limit: :infinity)}"

    scenario
  end

  defp packet_id_for(opts) do
    case Keyword.get(opts, :packet) do
      nil -> nil
      name when is_atom(name) -> apply(AoProtocol.PacketIds.Server, name, [])
    end
  end

  defp packet_label(opts) do
    case Keyword.get(opts, :packet) do
      nil -> ""
      name -> ", packet: #{inspect(name)}"
    end
  end
end
