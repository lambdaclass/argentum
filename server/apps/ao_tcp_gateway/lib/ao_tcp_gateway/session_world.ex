defmodule AoTcpGateway.SessionWorld do
  @moduledoc """
  World entry: map join, bootstrap packet building, map readiness.

  Extracted from SessionLogic as a pure structural refactor.
  """

  require Logger

  @default_map_id 1

  # ---- Enter world ----

  def enter_world(state, account_id, entity) do
    map_id = entity.map_id || @default_map_id

    with :ok <- ensure_map_started(map_id),
         {:ok, char_index, all_players, weather} <-
           Arena.Map.MapServer.enter(map_id, entity, position: {entity.x, entity.y}) do
      entity = Map.get(all_players, entity.char_id)

      Logger.info(
        "#{entity.name} entered map #{map_id} at (#{entity.x}, #{entity.y}) index=#{char_index}"
      )

      :telemetry.execute([:arena, :session, :login], %{count: 1},
        %{char_id: entity.char_id, map_id: map_id})

      state = %{
        state
        | account_id: account_id,
          character_id: entity.char_id,
          char_index: char_index,
          map_id: map_id,
          entity: entity,
          is_gm: entity.gm == true
      }

      global_rain = try do Arena.WorldWeather.raining?() rescue _ -> weather.rain catch :exit, _ -> weather.rain end
      global_snow = try do Arena.WorldWeather.snowing?() rescue _ -> weather.snow catch :exit, _ -> weather.snow end
      weather_packets =
        (if global_rain, do: [{:rain_toggle, %{raining: true}}], else: []) ++
        (if global_snow, do: [{:snow_toggle, %{snowing: true}}], else: [])

      packets =
        [
          {:logged, %{new_user: false}},
          {:user_index_in_server, %{user_index: 1}},
          {:change_map, %{map_id: map_id, version: 0}},
          {:user_char_index_in_server, %{char_index: char_index}},
          Arena.Map.Helpers.character_create_packet(entity),
          {:pos_update, %{x: entity.x, y: entity.y}},
          {:intervals, %{walk: 210}},
          {:update_hp, %{min_hp: entity.hp}},
          {:update_mana, %{min_mana: entity.mana}},
          {:update_stamina, %{min_sta: entity.stamina}},
          {:update_gold, %{gold: entity.gold}},
          {:update_hunger_and_thirst, %{
            max_hunger: 100,
            min_hunger: entity.hunger,
            max_thirst: 100,
            min_thirst: entity.thirst
          }}
        ] ++
          weather_packets ++
          exp_login_packets(entity) ++
          inventory_login_packets(entity) ++
          spell_login_packets(entity) ++
          skill_login_packets(entity) ++
          for {cid, other} <- all_players, cid != entity.char_id do
            Arena.Map.Helpers.character_create_packet(other)
          end ++
          [{:console_msg, %{message: "Welcome to Argentum Online!", font_index: 0}}]

      AoSession.OnlineDirectory.register(entity.char_id, entity.name, map_id, self(),
        is_gm: state.is_gm,
        faction: entity.faction
      )

      # Send party snapshot if player is in a party
      party_snapshot_packets =
        case Arena.PartyServer.get_party(entity.char_id) do
          {:ok, party} ->
            leader_id = party.leader
            ordered = [leader_id | Enum.filter(party.members, &(&1 != leader_id))]

            names =
              Enum.map(ordered, fn mid ->
                case AoSession.OnlineDirectory.lookup_by_id(mid) do
                  {:ok, info} -> info.name
                  :not_found -> "ID:#{mid}"
                end
              end)

            [{:datos_grupo, %{en_grupo: true, members: names, leader_index: 0}}]

          :not_in_party ->
            [{:datos_grupo, %{en_grupo: false, members: []}}]
        end

      {state, packets ++ party_snapshot_packets}
    else
      {:error, reason} ->
        Logger.error("Failed to enter map #{map_id}: #{inspect(reason)}")
        {state, [{:error_msg, %{message: "Map not available. Try again later."}}]}
    end
  end

  # ---- Map readiness ----

  def ensure_map_started(map_id) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [{_pid, _}] -> :ok
      [] -> Arena.Map.MapSupervisor.start_map(map_id)
    end

    wait_for_map_ready(map_id, 50)
  end

  defp wait_for_map_ready(_map_id, 0), do: {:error, :map_not_ready}

  defp wait_for_map_ready(map_id, retries) do
    case Registry.lookup(Arena.MapRegistry, map_id) do
      [] ->
        {:error, :map_not_found}

      _ ->
        if Arena.Map.MapServer.ready?(map_id) do
          :ok
        else
          Process.sleep(100)
          wait_for_map_ready(map_id, retries - 1)
        end
    end
  end

  # ---- Packet builders ----

  def inventory_login_packets(entity) do
    entity.inventory
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {nil, _idx} ->
        []

      {%{item_id: item_id, amount: amount, equipped: equipped}, idx} ->
        item_def = Arena.Data.GameData.get_item(item_id)
        valor = if item_def, do: item_def.valor, else: 0

        [
          {:change_inventory_slot,
           %{
             slot: idx + 1,
             obj_index: item_id,
             amount: amount,
             equipped: equipped,
             valor: valor / 1
           }}
        ]
    end)
  end

  def exp_login_packets(entity) do
    level = max(entity.level || 1, 1)
    current_xp = max(entity.xp || 0, 0)

    next_xp =
      case Arena.Data.GameData.exp_for_level(level) do
        value when is_integer(value) and value > current_xp ->
          value

        _ ->
          case Arena.Data.GameData.exp_for_level(level + 1) do
            value when is_integer(value) and value > 0 -> value
            _ -> max(current_xp, 1)
          end
      end

    [
      {:level_up, %{level: level}},
      {:update_exp, %{current_xp: current_xp, next_xp: next_xp}}
    ]
  end

  def spell_login_packets(entity) do
    (entity.spells || [])
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {spell_id, slot} when is_integer(spell_id) and spell_id > 0 ->
        [
          {:change_spell_slot,
           %{
             slot: slot,
             spell_id: spell_id
           }}
        ]

      _ ->
        []
    end)
  end

  def skill_login_packets(entity) do
    [{:send_skills, %{skills: entity.skills || %{}}}]
  end
end
