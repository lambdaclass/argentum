defmodule Arena.Map.CriminalStatus do
  @moduledoc """
  Port of the VB6 `VolverCriminal` procedure (Modulo_UsUaRiOs.bas:2260-2296).

  Called whenever a player commits a hostile action against a Ciudadano and
  must become a Criminal.  Centralises all of the VB6 side-effects so every
  call site (melee, spells, future PK paths) benefits:

    * Trigger == 6 tile short-circuit (safe-zone/sanctuary).
    * Ciudadano → Criminal resets `faction_score` to 0.
    * Caos / Concilio are early-returned (they cannot become criminal).
    * NoPKs maps warp the offender to `MapInfo(Map).Salida` (unless GM).
    * If the player is in a party, sends MSG 2144 and disbands/leaves.

  The helper returns `{updated_entity, updated_state}` so callers can thread
  the result into their existing reducer-style flow.
  """

  alias Arena.Map.Effects
  alias AoProtocol.Server.Encoder

  @trigger_safe_zone 6

  @doc """
  Promote `entity` to criminal status, replicating all of VB6's
  `VolverCriminal` side-effects.

  Returns `{entity, state, effects}`. Note: the NoPKs warp emits a
  `{:transfer, map, x, y, entity}` direct send (out-of-band of the egress
  envelope, same convention used by `/GOTO`); only the console messages
  for the criminal-zone notice and party-disband notice flow as map
  effects.
  """
  def volver_criminal(state, char_id, entity) do
    cond do
      # VB6:2263 — tile trigger 6 is a sanctuary; never become criminal here.
      tile_trigger(state, entity.x, entity.y) == @trigger_safe_zone ->
        {entity, state, []}

      # VB6:2271 — Caos / Concilio players cannot become criminal.
      entity.faction in [:chaos_legion, :council] ->
        {entity, state, []}

      true ->
        entity = maybe_reset_faction_score(entity)
        # VB6:2275 — `.Faccion.Status = 0` resets to Ciudadano before the
        # criminal flag is applied.  We keep `:none` here (Armada Real
        # expulsion path remains handled separately by faction code).
        entity = %{entity | criminal: true}

        {entity, state, warp_effects} = maybe_warp_no_pks(state, char_id, entity)
        {state, party_effects} = handle_party(state, char_id, entity)
        {entity, state, warp_effects ++ party_effects}
    end
  end

  # VB6:2272-2274 — Ciudadano (Status = 0, i.e. :none) with any FactionScore
  # has it wiped on the Criminal transition.  Armada players retain their
  # score because the VB6 code only zeroes FactionScore inside the
  # `Faccion.Status = Ciudadano` branch.
  defp maybe_reset_faction_score(%{faction: :none} = entity) do
    %{entity | faction_score: 0}
  end

  defp maybe_reset_faction_score(entity), do: entity

  # VB6:2276-2282 — NoPKs map: if not GM and Salida is configured, warp.
  # (MapInfo(Map).Salida.Map <> 0 — stored here as a map with :map key).
  defp maybe_warp_no_pks(state, char_id, entity) do
    no_pks = Map.get(state.meta, :no_pks, false)
    salida = Map.get(state.meta, :salida)

    if no_pks and not gm?(entity) and valid_salida?(salida) do
      # Msg580 parity: inform the user they can't be criminals here, then
      # warp them via the `:transfer` effect kind. The runner sends the
      # `{:transfer, _, _, _, _}` tuple to the session pid out-of-band of
      # the egress envelope — same convention as `/GOTO`.
      msg_packet =
        Encoder.encode(
          {:console_msg, %{message: "En este mapa no se admiten criminales.", font_index: 0}}
        )

      effects = [
        Effects.send(char_id, msg_packet),
        Effects.transfer(char_id, salida.map, salida.x, salida.y, entity)
      ]

      {entity, state, effects}
    else
      {entity, state, []}
    end
  end

  defp valid_salida?(%{map: m, x: _, y: _}) when is_integer(m) and m != 0, do: true
  defp valid_salida?(_), do: false

  defp gm?(entity) do
    Map.get(entity, :gm, false) or Map.get(entity, :gm_level) != nil
  end

  # VB6:2283-2291 — if the player is in a party, inform them and disband
  # (leader) or leave (member).  Message 2144 text kept verbatim for parity.
  defp handle_party(state, char_id, _entity) do
    case Arena.PartyServer.get_party(char_id) do
      {:ok, party} ->
        # VB6: if lider.ArrayIndex == UserIndex => FinalizarGrupo else SalirDeGrupo
        # Our PartyServer.leave/1 already handles both cases:
        #   - leader leaving dissolves the party (FinalizarGrupo)
        #   - member leaving removes them and keeps the rest (SalirDeGrupo)
        _ = party
        Arena.PartyServer.leave(char_id)

        msg_packet =
          Encoder.encode(
            {:console_msg,
             %{
               message: "Ahora sos criminal, no podes estar en un grupo con ciudadanos.",
               font_index: 0
             }}
          )

        {state, [Effects.send(char_id, msg_packet)]}

      _ ->
        {state, []}
    end
  end

  defp tile_trigger(state, x, y) do
    Map.get(state.meta[:trigger_map] || %{}, {x, y}, 0)
  end
end
