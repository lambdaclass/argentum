defmodule AoTcpGateway.SessionTransfer do
  @moduledoc """
  Map transfer and /HOGAR home travel logic.

  Extracted from SessionLogic as a pure structural refactor.
  """

  require Logger

  alias AoEntities.PlayerEntity
  alias AoTcpGateway.SessionWorld

  # VB6 e_Ciudad enum order (reverse of character_creation @home_city_atom)
  @home_city_ids %{
    ullathorpe: 1, nix: 2, banderbill: 3, lindos: 4,
    arghal: 5, arkhein: 6, forgat: 7, eldoria: 8, penthar: 9
  }

  @jail_map_id 66

  # VB6 Hogar.bas:37-50 — GM gets 5s, non-GM user types have per-type timers.
  # We keep the per-tier buckets runtime-configurable under
  # :ao_tcp_gateway, :hogar_travel_delay_ms.
  @hogar_travel_delay_defaults %{
    gm: 5_000,
    normal: 10_000,
    adventurer: 10_000,
    hero: 10_000,
    legend: 10_000
  }

  # ---- Map transfer ----

  def transfer(state, dest_map, dest_x, dest_y, entity) do
    source_map = state.map_id

    # Clear transient session-state flags before entering the destination map.
    # These are map-local interactions that must not carry across maps.
    # Mirrors the cleanup done in PlayerDeath for consistency.
    clean_entity = %{entity |
      commerce_npc_id: nil,
      bank_npc_id: nil,
      bank_gold: 0,
      trade_partner_id: nil,
      trade_request_target: nil,
      trade_offer_gold: 0,
      trade_offer_items: [],
      trade_accepted: false,
      meditating: false,
      resting: false,
      quest_npc_id: nil
    }

    # When source == dest (e.g. two tile exits on the same map both pointing to
    # the same destination, or a same-map teleport), we must leave BEFORE enter.
    # Otherwise enter() overwrites the player record and leave() then removes the
    # freshly-entered player, leaving them absent from the map entirely.
    # For cross-map transfers, enter-then-leave is correct: the player exists on
    # the destination before being removed from the source.
    if source_map == dest_map do
      do_leave(source_map, entity.char_id)
    end

    with :ok <- SessionWorld.ensure_map_started(dest_map),
         {:ok, char_index, all_players, weather} <-
           Arena.Map.MapServer.enter(dest_map, clean_entity, position: {dest_x, dest_y}) do
      # Destination entry succeeded — now remove from source (cross-map only).
      if source_map != dest_map do
        do_leave(source_map, entity.char_id)
      end

      AoSession.OnlineDirectory.update_map(state.character_id, dest_map)

      entity = Map.get(all_players, entity.char_id)

      Logger.info("#{entity.name} transferred to map #{dest_map} at (#{dest_x}, #{dest_y})")

      state = %{state | map_id: dest_map, char_index: char_index, entity: entity}

      # Cancel any active /HOGAR timer — a tile-exit transfer must not be
      # followed by a stale hogar teleport that would yank the player away.
      state = case Map.get(state, :hogar_timer_ref) do
        nil -> state
        ref ->
          Process.cancel_timer(ref)
          Map.put(state, :hogar_timer_ref, nil)
      end

      global_rain = try do Arena.WorldWeather.raining?() rescue _ -> weather.rain catch :exit, _ -> weather.rain end
      global_snow = try do Arena.WorldWeather.snowing?() rescue _ -> weather.snow catch :exit, _ -> weather.snow end
      weather_packets =
        (if global_rain, do: [{:rain_toggle, %{raining: true}}], else: [{:rain_toggle, %{raining: false}}]) ++
        (if global_snow, do: [{:snow_toggle, %{snowing: true}}], else: [{:snow_toggle, %{snowing: false}}])

      packets =
        [
          {:change_map, %{map_id: dest_map, version: 0}},
          {:user_char_index_in_server, %{char_index: char_index}},
          Arena.Map.Helpers.character_create_packet(entity),
          {:pos_update, %{x: entity.x, y: entity.y}}
        ] ++
          weather_packets ++
          for {cid, other} <- all_players, cid != entity.char_id do
            Arena.Map.Helpers.character_create_packet(other)
          end

      {state, packets}
    else
      {:error, reason} ->
        Logger.error("Failed to transfer to map #{dest_map}: #{inspect(reason)}")
        {state, [{:error_msg, %{message: "Destination map not available."}}]}
    end
  end

  # ---- Leave helper ----

  defp do_leave(map_id, char_id) do
    case Arena.Map.MapServer.leave(map_id, char_id) do
      {:ok, _departed} ->
        :ok

      :not_found ->
        Logger.warning(
          "leave(#{map_id}, #{char_id}) returned :not_found during transfer — " <>
            "player may have already been removed (tile exit cleanup)"
        )

      other ->
        Logger.warning(
          "leave(#{map_id}, #{char_id}) unexpected result during transfer: #{inspect(other)}"
        )
    end
  end

  # ---- /HOGAR — VB6 home travel (dead-only, delayed with timer bar) ----

  def handle_hogar(state) do
    case Arena.Map.MapServer.snapshot_entity(state.map_id, state.character_id) do
      {:ok, entity} ->
        handle_hogar_check(state, entity)

      _ ->
        {state, []}
    end
  end

  # Pure-logic /HOGAR handler, public for unit testing without MapServer.
  # Matches VB6 HandleHome exactly: dead-only, delayed travel with timer bar.
  @doc false
  def handle_hogar_check(state, entity) do
    handle_hogar_check(state, entity, nil)
  end

  @doc false
  def handle_hogar_check(state, entity, map_zone) do
    hogar_ref = Map.get(state, :hogar_timer_ref)

    # Resolve zone lazily — only call MapServer when not passed explicitly (tests pass it)
    zone = map_zone || try_get_map_zone(state.map_id)

    cond do
      # VB6 step 1: IsInMapCarcelRestrictedArea — jail map blocked
      state.map_id == @jail_map_id ->
        {state, [{:console_msg, %{message: "No puedes usar /HOGAR en la cárcel.", font_index: 0}}]}

      # VB6 step 2: must be dead
      not entity.dead ->
        {state, [{:console_msg, %{message: "Debes estar muerto para poder utilizar este comando.", font_index: 0}}]}

      # VB6 step 3: NEWBIE zone restriction
      zone == "NEWBIE" ->
        {state, [{:console_msg, %{message: "No puedes viajar a tu hogar desde este mapa.", font_index: 0}}]}

      # VB6 step 4: penalty (prison sentence)
      (entity.penalty || 0) > 0 ->
        {state, [{:console_msg, %{message: "No puedes usar este comando en prisión.", font_index: 0}}]}

      # VB6 step 5: EnReto (duel) blocks /HOGAR (Protocol.bas:7439)
      entity.in_duel ->
        {state, [{:console_msg, %{message: "No podés regresar desde un reto. Usá /ABANDONAR para admitir la derrota y volver a la ciudad.", font_index: 0}}]}

      # VB6 step 7: already traveling — cancel the travel
      hogar_ref != nil ->
        Process.cancel_timer(hogar_ref)
        state = Map.put(state, :hogar_timer_ref, nil)
        {state, [{:console_msg, %{message: "Ya hay un viaje en curso.", font_index: 0}}]}

      # VB6 step 6: not traveling — check home map then start
      true ->
        city_id = Map.get(@home_city_ids, entity.home_city, 1)
        spawn = Arena.Data.GameData.city_spawn(city_id)

        if state.map_id == spawn.map do
          {state, [{:console_msg, %{message: "Ya te encuentras en tu hogar.", font_index: 0}}]}
        else
          cost = hogar_gold_cost(entity.level)

          if entity.gold < cost do
            {state, [{:console_msg, %{message: "Para utilizar este comando necesitas #{cost} monedas de oro.", font_index: 0}}]}
          else
            # Deduct gold (async cast — also sends :update_gold packet to client)
            Arena.Map.MapServer.modify_gold(state.map_id, state.character_id, -cost)

            delay = hogar_travel_delay(entity)
            ref = Process.send_after(self(), :hogar_arrive, delay)
            state = Map.put(state, :hogar_timer_ref, ref)

            {state, [
              {:console_msg, %{message: "Volverás a tu hogar en unos segundos.", font_index: 0}}
            ]}
          end
        end
    end
  end

  @doc """
  Cancel an in-progress /HOGAR travel. Returns `{state, packets}`.
  Called when the player walks, attacks, casts, gets hit, or dies.
  """
  def cancel_hogar(state) do
    case Map.get(state, :hogar_timer_ref) do
      nil ->
        {state, []}

      ref ->
        Process.cancel_timer(ref)
        state = Map.put(state, :hogar_timer_ref, nil)
        {state, [{:console_msg, %{message: "Has cancelado el viaje a casa.", font_index: 0}}]}
    end
  end

  @doc """
  Convenience: cancel hogar and return just `{state, cancel_packets}`.
  Used by walk/attack/spell handlers that need to prepend cancel packets.
  """
  def maybe_cancel_hogar(state) do
    cancel_hogar(state)
  end

  @doc """
  Handle the :hogar_arrive timer message. Teleports the player to their
  home city if the timer wasn't cancelled (hogar_timer_ref still set).

  Returns either `{:transfer, map, x, y, entity}` tuple (for handler to process)
  or `{state, []}` if cancelled.
  """
  def handle_hogar_arrive(state, entity) do
    case Map.get(state, :hogar_timer_ref) do
      nil ->
        # Timer was cancelled
        {state, []}

      _ref ->
        city_id = Map.get(@home_city_ids, entity.home_city, 1)
        spawn = Arena.Data.GameData.city_spawn(city_id)

        {:transfer, spawn.map, spawn.x, spawn.y, entity}
    end
  end

  @doc """
  VB6 Hogar.bas:37-50 travel delay in milliseconds.

  GMs get 5 seconds. Non-GM players use the old per-user-type buckets:
  HomeTimerAdventurer, HomeTimerHero, HomeTimerLegend, and HomeTimer.
  """
  def hogar_travel_delay(%{gm: true}), do: hogar_travel_delay_for(:gm)

  def hogar_travel_delay(entity) do
    entity
    |> Map.get(:user_tier, :normal)
    |> PlayerEntity.normalize_user_tier()
    |> hogar_travel_delay_for()
  end

  defp hogar_travel_delay_for(tier) do
    Application.get_env(:ao_tcp_gateway, :hogar_travel_delay_ms, @hogar_travel_delay_defaults)
    |> Map.get(tier, Map.fetch!(@hogar_travel_delay_defaults, tier))
  end

  defp hogar_gold_cost(level) when level > 24, do: level * level
  defp hogar_gold_cost(level), do: level * 15 + trunc(:math.pow(level, 1.5))

  defp try_get_map_zone(map_id) do
    Arena.Map.MapServer.map_zone(map_id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
