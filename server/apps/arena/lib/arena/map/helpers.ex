defmodule Arena.Map.Helpers do
  @moduledoc "Shared helpers for MapServer domain modules."

  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @map_width 100
  @map_height 100
  @aoi_range_x Application.compile_env(:arena, :aoi_range_x, 11)
  @aoi_range_y Application.compile_env(:arena, :aoi_range_y, 9)

  def map_width, do: @map_width
  def map_height, do: @map_height
  def aoi_range_x, do: @aoi_range_x
  def aoi_range_y, do: @aoi_range_y

  # with_player helper to reduce boilerplate
  # For handle_call: fun receives entity, must return {:reply, term, state}
  def with_player_call(state, char_id, fun) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} -> fun.(entity)
      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  # For handle_cast: fun receives entity, must return {:noreply, state}
  def with_player_cast(state, char_id, fun) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} -> fun.(entity)
      :error -> {:noreply, state}
    end
  end

  # Occupancy grid helpers
  def occ_index(x, y), do: (y - 1) * @map_width + (x - 1)

  def set_occupancy(occ, x, y, value) when x >= 1 and x <= @map_width and y >= 1 and y <= @map_height do
    :array.set(occ_index(x, y), value, occ)
  end

  def set_occupancy(occ, _x, _y, _value), do: occ

  def clear_occupancy(occ, x, y) when x >= 1 and x <= @map_width and y >= 1 and y <= @map_height do
    :array.set(occ_index(x, y), nil, occ)
  end

  def clear_occupancy(occ, _x, _y), do: occ

  def get_occupancy(occ, x, y) when x >= 1 and x <= @map_width and y >= 1 and y <= @map_height do
    :array.get(occ_index(x, y), occ)
  end

  def get_occupancy(_occ, _x, _y), do: :out_of_bounds

  # Direct session sends
  def send_to_session(sessions, char_id, msg) do
    case Map.get(sessions, char_id) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end

  # Heading conversions
  def heading_to_int(:north), do: 1
  def heading_to_int(:east), do: 2
  def heading_to_int(:south), do: 3
  def heading_to_int(:west), do: 4
  def heading_to_int(_), do: 3

  def facing_tile(x, y, :north), do: {x, y - 1}
  def facing_tile(x, y, :south), do: {x, y + 1}
  def facing_tile(x, y, :east), do: {x + 1, y}
  def facing_tile(x, y, :west), do: {x - 1, y}
  def facing_tile(x, y, _), do: {x, y + 1}

  def opposite_heading(:north), do: :south
  def opposite_heading(:south), do: :north
  def opposite_heading(:east), do: :west
  def opposite_heading(:west), do: :east
  def opposite_heading(other), do: other

  # Packet builders

  @ghost_body_id 829

  defp visual_state(entity) do
    if entity.dead do
      %{body_id: @ghost_body_id, head_id: 0, weapon_id: 0, shield_id: 0, helmet_id: 0}
    else
      %{
        body_id: entity.body_id,
        head_id: entity.head_id,
        weapon_id: entity.equipment[:weapon] || 0,
        shield_id: entity.equipment[:shield] || 0,
        helmet_id: entity.equipment[:helmet] || 0
      }
    end
  end

  def character_create_packet(entity) do
    visual = visual_state(entity)
    {clan_index, clan_nivel} = guild_display_info(entity.char_id)

    {:character_create,
     %{
       char_index: entity.char_index,
       body_id: visual.body_id,
       head_id: visual.head_id,
       heading: heading_to_int(entity.heading),
       x: entity.x,
       y: entity.y,
       name: entity.name || "Unknown",
       weapon_id: visual.weapon_id,
       shield_id: visual.shield_id,
       helmet_id: visual.helmet_id,
       min_hp: entity.hp,
       max_hp: entity.max_hp,
       min_mana: entity.mana,
       max_mana: entity.max_mana,
       speed: entity.speeding,
       clan_index: clan_index,
       clan_nivel: clan_nivel
     }}
  end

  defp guild_display_info(char_id) do
    case Arena.GuildServer.get_guild(char_id) do
      {:ok, guild} -> {guild.id, guild.level}
      :not_in_guild -> {0, 0}
    end
  rescue
    # GuildServer may not be running in tests
    _ -> {0, 0}
  end

  def character_change_packet(entity) do
    visual = visual_state(entity)

    {:character_change,
     %{
       char_index: entity.char_index,
       body_id: visual.body_id,
       head_id: visual.head_id,
       heading: heading_to_int(entity.heading),
       weapon_id: visual.weapon_id,
       shield_id: visual.shield_id,
       helmet_id: visual.helmet_id
     }}
  end

  @doc """
  Broadcast a character_change packet to all players that can see (x, y).
  Used after death, revive, and equipment changes.
  """
  def broadcast_character_change(state, entity) do
    raw = Encoder.encode(character_change_packet(entity))

    Arena.Map.Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
      send(pid, {:send_raw, raw})
    end)
  end

  # NPC create packet (used by visibility and NPC AI)
  def npc_create_packet(npc_entity, npc_def) do
    {:character_create,
     %{
       char_index: npc_entity.char_index,
       body_id: npc_def.body,
       head_id: npc_def.head,
       heading: npc_def.heading,
       x: npc_entity.x,
       y: npc_entity.y,
       name: npc_def.name || "NPC",
       min_hp: npc_entity.hp,
       max_hp: npc_entity.max_hp,
       es_npc: 1
     }}
  end

  # Inventory slot send
  def send_inventory_slot(sessions, char_id, inventory, slot) do
    case Enum.at(inventory, slot) do
      nil ->
        send_to_session(
          sessions,
          char_id,
          {:send_raw, Encoder.encode({:change_inventory_slot, %{slot: slot + 1, obj_index: 0, amount: 0}})}
        )

      item ->
        item_def = GameData.get_item(item.item_id)
        valor = if item_def, do: item_def.valor, else: 0
        instance_tags = Map.get(item, :elemental_tags, 0)

        send_to_session(
          sessions,
          char_id,
          {:send_raw,
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
           )}
        )
    end
  end

  # Class/Race integer conversions
  @class_id_map %{
    mago: 1,
    clerigo: 2,
    paladin: 3,
    cazador: 4,
    trabajador: 5,
    guerrero: 6,
    ladron: 7,
    bandido: 8,
    asesino: 9,
    druida: 10,
    bardo: 11,
    pirata: 12
  }

  def class_atom_to_id(class_atom), do: Map.get(@class_id_map, class_atom, 6)

  def class_to_int(:mage), do: 1
  def class_to_int(:cleric), do: 2
  def class_to_int(:warrior), do: 3
  def class_to_int(:assassin), do: 4
  def class_to_int(:thief), do: 5
  def class_to_int(:bard), do: 6
  def class_to_int(:druid), do: 7
  def class_to_int(:bandit), do: 8
  def class_to_int(:paladin), do: 9
  def class_to_int(:hunter), do: 10
  def class_to_int(:worker), do: 11
  def class_to_int(:pirate), do: 12
  def class_to_int(_), do: 3

  def race_to_int(:human), do: 1
  def race_to_int(:elf), do: 2
  def race_to_int(:dark_elf), do: 3
  def race_to_int(:gnome), do: 4
  def race_to_int(:dwarf), do: 5
  def race_to_int(_), do: 1

  # Break invisibility and oculto (used by combat, inventory, movement)
  # VB6: RemoveUserInvisibility clears both invisible and oculto flags
  def break_invisibility(entity, state, char_id) do
    if entity.invisible or entity.oculto do
      buffs = Enum.reject(entity.buffs, &(&1.type in [:invisible, :oculto]))
      entity = %{entity | invisible: false, oculto: false, buffs: buffs}

      send_to_session(
        state.sessions,
        char_id,
        {:send_raw, Encoder.encode({:console_msg, %{message: "Has vuelto a ser visible.", font_index: 0}})}
      )

      entity
    else
      entity
    end
  end

  # Ground item helpers
  def broadcast_object_create(state, x, y, item_id, amount, elemental_tags \\ 0) do
    item_def = GameData.get_item(item_id)
    grh = if item_def, do: item_def.grh_index, else: 0

    raw =
      Encoder.encode({:object_create, %{x: x, y: y, obj_index: grh, amount: amount, elemental_tags: elemental_tags}})

    broadcast_visible_all(state, x, y, fn pid -> send(pid, {:send_raw, raw}) end)
  end

  def broadcast_object_delete(state, x, y) do
    raw = Encoder.encode({:object_delete, %{x: x, y: y}})
    broadcast_visible_all(state, x, y, fn pid -> send(pid, {:send_raw, raw}) end)
  end

  # ---- Map restriction checks (VB6: restrict_mode) ----

  # VB6: GMs bypass all map restrictions
  def check_map_restriction(_mode, %{gm: true}), do: :ok
  def check_map_restriction("", _entity), do: :ok

  def check_map_restriction("NEWBIE", entity) do
    if entity.level <= 12 and not entity.criminal,
      do: :ok,
      else: {:error, "No puedes entrar a este mapa."}
  end

  # VB6: ARMADA/REAL maps -- only Royal Army faction can enter
  def check_map_restriction("ARMADA", entity) do
    if Map.get(entity, :faction, :none) == :royal_army,
      do: :ok,
      else: {:error, "Solo miembros del Ejercito Real pueden entrar a este mapa."}
  end

  def check_map_restriction("REAL", entity) do
    if Map.get(entity, :faction, :none) == :royal_army,
      do: :ok,
      else: {:error, "Solo miembros del Ejercito Real pueden entrar a este mapa."}
  end

  # VB6: CAOS maps -- only Chaos Legion faction can enter
  def check_map_restriction("CAOS", entity) do
    if Map.get(entity, :faction, :none) == :chaos_legion,
      do: :ok,
      else: {:error, "Solo miembros de la Legion del Caos pueden entrar a este mapa."}
  end

  # VB6: CIUDADANO maps -- no criminals allowed (citizens and faction members OK)
  def check_map_restriction("CIUDADANO", entity) do
    if not entity.criminal,
      do: :ok,
      else: {:error, "Criminales no pueden entrar a este mapa."}
  end

  # VB6: FACCION maps require belonging to a faction (Royal Army or Chaos Legion)
  def check_map_restriction("FACCION", entity) do
    faction = Map.get(entity, :faction, :none)

    if faction in [:royal_army, :chaos_legion],
      do: :ok,
      else: {:error, "Necesitas pertenecer a una faccion para entrar."}
  end

  def check_map_restriction(_unknown, _entity), do: :ok

  # Broadcast helpers — delegate to Visibility module
  defdelegate broadcast_visible(state, x, y, exclude_id, fun), to: Arena.Map.Visibility
  defdelegate broadcast_visible_all(state, x, y, fun), to: Arena.Map.Visibility
  defdelegate broadcast_range(state, x, y, range_x, range_y, fun), to: Arena.Map.Visibility
end
