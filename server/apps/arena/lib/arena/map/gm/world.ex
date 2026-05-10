defmodule Arena.Map.Gm.World do
  @moduledoc "GM world/environment commands: weather, map flags, tiles, triggers, items, audio, etc."

  alias Arena.AuditLog
  alias Arena.Data.GameData
  alias Arena.Map.{Effects, Helpers}
  alias AoProtocol.Server.Encoder

  @doc "/RAIN — toggle rain on the map via text command (VB6 parity)."
  def gm_rain_toggle(state, char_id) do
    new_rain = not Map.get(state.meta, :rain, false)
    meta = Map.put(state.meta, :rain, new_rain)
    state = %{state | meta: meta}

    rain_packet = Encoder.encode({:rain_toggle, %{raining: new_rain}})

    label = if new_rain, do: "ON", else: "OFF"
    AuditLog.log_gm_action(char_id, "rain_toggle", label)

    effects = [
      Effects.broadcast_map(rain_packet),
      Effects.send(char_id, console("Rain toggled #{label} on this map."))
    ]

    {:ok, state, effects}
  end

  def gm_toggle_weather(state, char_id, weather_type) do
    label = if weather_type == :snow, do: "Nieve", else: "Niebla"
    current = Map.get(state.meta, weather_type, false)
    new_val = !current
    meta = Map.put(state.meta, weather_type, new_val)
    state = %{state | meta: meta}
    status = if new_val, do: "activada", else: "desactivada"
    AuditLog.log_gm_action(char_id, "toggle_weather", "#{label} #{status}")

    {:ok, state, [Effects.send(char_id, console("#{label} #{status} en este mapa."))]}
  end

  def gm_change_map_flag(state, char_id, flag, value_str) do
    new_val = value_str == "1"
    meta = Map.put(state.meta, flag, new_val)
    state = %{state | meta: meta}
    status = if new_val, do: "activado", else: "desactivado"
    AuditLog.log_gm_action(char_id, "change_map_flag", "#{flag} #{status}")

    {:ok, state, [Effects.send(char_id, console("Map flag #{flag} #{status}."))]}
  end

  def gm_tile_block_toggle(state, char_id, entity) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

    {blocked_tiles, status} =
      if MapSet.member?(state.gm_blocked_tiles, {fx, fy}) do
        {MapSet.delete(state.gm_blocked_tiles, {fx, fy}), "unblocked"}
      else
        {MapSet.put(state.gm_blocked_tiles, {fx, fy}), "blocked"}
      end

    state = %{state | gm_blocked_tiles: blocked_tiles}
    AuditLog.log_gm_action(char_id, "tile_block", "(#{fx},#{fy}) #{status}")

    {:ok, state, [Effects.send(char_id, console("Tile (#{fx},#{fy}) #{status}."))]}
  end

  def gm_set_trigger(state, char_id, entity, trigger_str) do
    case Integer.parse(trigger_str) do
      {trigger, _} ->
        {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)

        triggers = Map.put(state.triggers, {fx, fy}, trigger)
        state = %{state | triggers: triggers}

        AuditLog.log_gm_action(char_id, "set_trigger", "#{trigger} at (#{fx},#{fy})")
        {:ok, state, [Effects.send(char_id, console("Trigger #{trigger} set at (#{fx},#{fy})."))]}

      :error ->
        {:ok, state, [Effects.send(char_id, console("Invalid trigger value."))]}
    end
  end

  def gm_ask_trigger(state, char_id, entity) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    trigger = Map.get(state.triggers, {fx, fy}, 0)
    {:ok, state, [Effects.send(char_id, console("Trigger at (#{fx},#{fy}): #{trigger}"))]}
  end

  def gm_items_in_floor(state, char_id) do
    items = state.ground_items
    count = map_size(items)

    header = [Effects.send(char_id, console("Items on floor: #{count}"))]

    listing =
      items
      |> Enum.take(20)
      |> Enum.map(fn {{x, y}, item} ->
        item_def = GameData.get_item(item.item_id)
        name = if item_def, do: item_def.name, else: "?"
        Effects.send(char_id, console("(#{x},#{y}): #{name} (#{item.item_id}) x#{item.amount}"))
      end)

    {:ok, state, header ++ listing}
  end

  def gm_destroy_items(state, char_id, entity) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    ground_items = Map.delete(state.ground_items, {fx, fy})
    state = %{state | ground_items: ground_items}
    AuditLog.log_gm_action(char_id, "destroy_items", "(#{fx},#{fy})")

    {:ok, state, [Effects.send(char_id, console("Items at (#{fx},#{fy}) destroyed."))]}
  end

  def gm_destroy_all_area(state, char_id, entity) do
    range = 10

    ground_items =
      Enum.reject(state.ground_items, fn {{x, y}, _item} ->
        abs(x - entity.x) <= range and abs(y - entity.y) <= range
      end)
      |> Map.new()

    state = %{state | ground_items: ground_items}
    AuditLog.log_gm_action(char_id, "destroy_all_area", "(#{entity.x},#{entity.y})")

    {:ok, state, [Effects.send(char_id, console("All items in area destroyed."))]}
  end

  def gm_clean_world(state, char_id) do
    state = %{state | ground_items: %{}}
    AuditLog.log_gm_action(char_id, "clean_world", "map #{state.map_id}")

    {:ok, state, [Effects.send(char_id, console("All ground items on this map cleaned."))]}
  end

  def gm_force_midi_map(state, char_id, midi_str, map_str) do
    with {midi, _} <- Integer.parse(midi_str),
         {_map_id, _} <- Integer.parse(map_str) do
      packet = Encoder.encode({:play_midi, %{midi: midi, loops: -1}})
      AuditLog.log_gm_action(char_id, "force_midi", "#{midi}")

      {:ok, state,
       [
         Effects.broadcast_map(packet),
         Effects.send(char_id, console("MIDI #{midi} sent to map."))
       ]}
    else
      _ -> {:ok, state, [Effects.send(char_id, console("Usage: /FORCEMIDIMAP midi map"))]}
    end
  end

  def gm_force_wave_map(state, char_id, wave_str, x_str, y_str, _map_str) do
    with {wave, _} <- Integer.parse(wave_str),
         {x, _} <- Integer.parse(x_str),
         {y, _} <- Integer.parse(y_str) do
      packet = Encoder.encode({:play_wave, %{wave: wave, x: x, y: y}})
      AuditLog.log_gm_action(char_id, "force_wave", "#{wave}")

      {:ok, state,
       [
         Effects.broadcast_map(packet),
         Effects.send(char_id, console("Wave #{wave} sent to map at (#{x},#{y})."))
       ]}
    else
      _ -> {:ok, state, [Effects.send(char_id, console("Usage: /FORCEWAVEMAP wave x y map"))]}
    end
  end

  def gm_invisible(state, char_id, entity) do
    new_invisible = not entity.invisible
    entity = %{entity | invisible: new_invisible}
    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}

    msg = if new_invisible, do: "You are now invisible.", else: "You are now visible."
    AuditLog.log_gm_action(char_id, "invisible", msg)

    visibility_effect =
      if new_invisible do
        Effects.hide_from_non_gm(entity)
      else
        Effects.reveal_to_non_gm(entity)
      end

    {:ok, state, [Effects.send(char_id, console(msg)), visibility_effect]}
  end

  def gm_spawn_item(state, char_id, entity, item_str, amount_str) do
    with {item_id, ""} <- Integer.parse(item_str),
         {amount, ""} <- Integer.parse(amount_str),
         true <- amount > 0 do
      case Arena.Inventory.add_item(entity.inventory, item_id, amount) do
        {:ok, new_inventory, slot} ->
          entity = %{entity | inventory: new_inventory}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          AuditLog.log_gm_action(char_id, "spawn_item", "#{amount}x #{item_id}")

          effects = [
            Effects.send(char_id, inventory_slot_packet(new_inventory, slot)),
            Effects.send(
              char_id,
              console("Spawned #{amount}x item #{item_id} in slot #{slot + 1}.")
            )
          ]

          {:ok, state, effects}

        {:gold, gold_amount} ->
          entity = %{entity | gold: entity.gold + gold_amount}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          AuditLog.log_gm_action(char_id, "spawn_item", "#{gold_amount}x gold")

          effects = [
            Effects.send(
              char_id,
              Encoder.encode({:update_gold, %{gold: entity.gold}})
            ),
            Effects.send(char_id, console("Added #{gold_amount} gold."))
          ]

          {:ok, state, effects}

        {:error, :inventory_full} ->
          {:ok, state, [Effects.send(char_id, console("Inventory full."))]}
      end
    else
      _ ->
        {:ok, state, [Effects.send(char_id, console("Usage: /SPAWNITEM item_id [amount]"))]}
    end
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  defp inventory_slot_packet(inventory, slot) do
    case Enum.at(inventory, slot) do
      nil ->
        Encoder.encode({:change_inventory_slot, %{slot: slot + 1, obj_index: 0, amount: 0}})

      item ->
        item_def = GameData.get_item(item.item_id)
        valor = if item_def, do: item_def.valor, else: 0
        instance_tags = Map.get(item, :elemental_tags, 0)

        Encoder.encode(
          {:change_inventory_slot,
           %{
             slot: slot + 1,
             obj_index: item.item_id,
             amount: item.amount,
             equipped: item.equipped,
             valor: valor / 1,
             elemental_tags: instance_tags
           }}
        )
    end
  end
end
