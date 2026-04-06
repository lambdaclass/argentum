defmodule Arena.Map.Crafting do
  @moduledoc """
  Crafting and gathering handlers for the Work packet.

  VB6 behavior: player must have the right tool equipped, be near the
  right resource (tile type or NPC), and pass a skill roll.
  """

  alias Arena.Map.Helpers
  alias Arena.Inventory
  alias Arena.Data.{GameData, CraftingRecipes}
  alias AoProtocol.Server.Encoder

  # Tool item IDs (obj_type 18 in obj.dat)
  @pickaxe_ids [187, 363, 46]         # Piquete de Minero, Dorado, Blodium
  @fishing_rod_ids [881, 2121, 2132, 2133]  # Caña de Pescar variants
  @woodcutting_axe_ids [127, 361]      # Hacha de Leñador, Élfica
  @hammer_ids [389]                     # Martillo de Herrero
  @saw_ids [198]                        # Serrucho
  @sewing_ids [886, 885, 369]           # Costurero, Tijeras, Tijeras doradas
  @alchemy_ids [887]                    # Olla de Alquimia

  # NPC types for production workstations
  @npc_type_forge 5
  @npc_type_workbench 6
  @npc_type_alchemy 7
  @npc_type_loom 8

  @work_stamina_cost 15

  @doc "Main entry point — called from Social when work packet targets a crafting skill."
  def handle_work(state, char_id, skill_atom) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            send_msg(state, char_id, "No puedes trabajar estando muerto.")
            {:noreply, state}

          entity.stamina < @work_stamina_cost ->
            send_msg(state, char_id, "Estás muy cansado para trabajar.")
            {:noreply, state}

          true ->
            do_work(state, char_id, entity, skill_atom)
        end

      :error ->
        {:noreply, state}
    end
  end

  defp do_work(state, char_id, entity, skill_atom) do
    weapon_id = entity.equipment[:weapon]

    case skill_atom do
      :mining -> gather(state, char_id, entity, :mining, weapon_id, @pickaxe_ids)
      :fishing -> fish(state, char_id, entity, weapon_id)
      :woodcutting -> gather(state, char_id, entity, :woodcutting, weapon_id, @woodcutting_axe_ids)
      :blacksmithing -> produce(state, char_id, entity, :blacksmithing, weapon_id, @hammer_ids, [@npc_type_forge])
      :carpentry -> produce(state, char_id, entity, :carpentry, weapon_id, @saw_ids, [@npc_type_workbench])
      :alchemy -> produce(state, char_id, entity, :alchemy, weapon_id, @alchemy_ids, [@npc_type_alchemy])
      :tailoring -> produce(state, char_id, entity, :tailoring, weapon_id, @sewing_ids, [@npc_type_loom])
      :taming ->
        send_msg(state, char_id, "La doma no está disponible aún.")
        {:noreply, state}
      _ ->
        send_msg(state, char_id, "No puedes trabajar en eso.")
        {:noreply, state}
    end
  end

  # ---- Gathering (mining, woodcutting) ----

  defp gather(state, char_id, entity, skill_atom, weapon_id, tool_ids) do
    cond do
      weapon_id not in tool_ids ->
        send_msg(state, char_id, "Necesitas la herramienta adecuada.")
        {:noreply, state}

      not resource_nearby?(state, entity, skill_atom) ->
        send_msg(state, char_id, "No hay recursos cerca para trabajar.")
        {:noreply, state}

      true ->
        attempt_gathering(state, char_id, entity, skill_atom)
    end
  end

  # ---- Fishing (special: check facing water tile) ----

  defp fish(state, char_id, entity, weapon_id) do
    cond do
      weapon_id not in @fishing_rod_ids ->
        send_msg(state, char_id, "Necesitas una caña de pescar.")
        {:noreply, state}

      not facing_water?(state, entity) ->
        send_msg(state, char_id, "No hay agua donde pescar.")
        {:noreply, state}

      true ->
        attempt_gathering(state, char_id, entity, :fishing)
    end
  end

  # ---- Production (blacksmithing, carpentry, etc.) ----

  defp produce(state, char_id, entity, skill_atom, weapon_id, tool_ids, npc_types) do
    cond do
      weapon_id not in tool_ids ->
        send_msg(state, char_id, "Necesitas la herramienta adecuada.")
        {:noreply, state}

      Arena.Map.Social.find_nearby_npc_of_type(state, entity, npc_types) == :not_found ->
        send_msg(state, char_id, "No hay un taller cerca.")
        {:noreply, state}

      true ->
        attempt_production(state, char_id, entity, skill_atom)
    end
  end

  # ---- Skill roll + item creation ----

  defp attempt_gathering(state, char_id, entity, skill_atom) do
    skill_value = Map.get(entity.skills, skill_atom, 0)

    {entity, state} = consume_stamina(state, char_id, entity)

    if skill_check(skill_value) do
      case CraftingRecipes.select_product(skill_atom, skill_value) do
        nil ->
          send_msg(state, char_id, "No has podido obtener nada.")
          {:noreply, state}

        item_id ->
          case Inventory.add_item(entity.inventory, item_id, 1) do
            {:ok, new_inventory, slot} ->
              entity = try_skill_up(entity, skill_atom, skill_value)
              entity = %{entity | inventory: new_inventory}
              state = update_player(state, char_id, entity)

              Helpers.send_inventory_slot(state.sessions, char_id, new_inventory, slot)
              send_skills(state, char_id, entity)

              item_def = GameData.get_item(item_id)
              name = if item_def, do: item_def.name, else: "un objeto"
              send_msg(state, char_id, "Has obtenido #{name}.")
              {:noreply, state}

            {:error, :inventory_full} ->
              send_msg(state, char_id, "No tienes espacio en el inventario.")
              {:noreply, state}

            {:gold, _} ->
              {:noreply, state}
          end
      end
    else
      send_msg(state, char_id, "No has podido obtener nada.")
      entity = try_skill_up(entity, skill_atom, skill_value)
      state = update_player(state, char_id, entity)
      send_skills(state, char_id, entity)
      {:noreply, state}
    end
  end

  defp attempt_production(state, char_id, entity, skill_atom) do
    skill_value = Map.get(entity.skills, skill_atom, 0)

    case CraftingRecipes.find_craftable(skill_atom, skill_value, entity.inventory) do
      nil ->
        send_msg(state, char_id, "No tienes los materiales necesarios.")
        {:noreply, state}

      recipe ->
        {entity, state} = consume_stamina(state, char_id, entity)

        if skill_check(skill_value) do
          case consume_ingredients(entity.inventory, recipe.ingredients) do
            {:ok, new_inventory, consumed_slots} ->
              case Inventory.add_item(new_inventory, recipe.result_id, recipe.result_amount) do
                {:ok, final_inventory, result_slot} ->
                  entity = try_skill_up(entity, skill_atom, skill_value)
                  entity = %{entity | inventory: final_inventory}
                  state = update_player(state, char_id, entity)

                  for slot <- consumed_slots do
                    Helpers.send_inventory_slot(state.sessions, char_id, final_inventory, slot)
                  end
                  Helpers.send_inventory_slot(state.sessions, char_id, final_inventory, result_slot)
                  send_skills(state, char_id, entity)

                  item_def = GameData.get_item(recipe.result_id)
                  name = if item_def, do: item_def.name, else: "un objeto"
                  send_msg(state, char_id, "Has creado #{name}.")
                  {:noreply, state}

                {:ok, final_inventory, _slot} ->
                  entity = %{entity | inventory: final_inventory}
                  state = update_player(state, char_id, entity)
                  {:noreply, state}

                {:error, :inventory_full} ->
                  send_msg(state, char_id, "No tienes espacio para el producto.")
                  {:noreply, state}

                {:gold, _} ->
                  {:noreply, state}
              end

            {:error, :missing_ingredients} ->
              send_msg(state, char_id, "No tienes los materiales necesarios.")
              {:noreply, state}
          end
        else
          send_msg(state, char_id, "No has podido crear nada.")
          entity = try_skill_up(entity, skill_atom, skill_value)
          state = update_player(state, char_id, entity)
          send_skills(state, char_id, entity)
          {:noreply, state}
        end
    end
  end

  # ---- Resource proximity checks ----

  defp resource_nearby?(state, entity, :mining) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    trigger = Map.get(state.meta[:trigger_map] || %{}, {fx, fy}, 0)
    trigger == 6
  end

  defp resource_nearby?(state, entity, :woodcutting) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    trigger = Map.get(state.meta[:trigger_map] || %{}, {fx, fy}, 0)
    trigger == 7
  end

  defp resource_nearby?(_state, _entity, _), do: true

  defp facing_water?(state, entity) do
    {fx, fy} = Helpers.facing_tile(entity.x, entity.y, entity.heading)
    Arena.TileGrid.get_tile(state.map_id, fx, fy) == 2
  end

  # ---- Helpers ----

  defp skill_check(skill_value), do: :rand.uniform(100) <= skill_value

  defp try_skill_up(entity, skill_atom, skill_value) do
    if skill_value < 100 and :rand.uniform(100) > skill_value do
      %{entity | skills: Map.put(entity.skills, skill_atom, skill_value + 1)}
    else
      entity
    end
  end

  defp consume_stamina(state, char_id, entity) do
    new_stamina = max(entity.stamina - @work_stamina_cost, 0)
    entity = %{entity | stamina: new_stamina}
    state = update_player(state, char_id, entity)

    Helpers.send_to_session(state.sessions, char_id,
      {:send_raw, Encoder.encode({:update_stamina, %{min_sta: new_stamina}})})

    {entity, state}
  end

  defp consume_ingredients(inventory, ingredients) do
    consume_ingredients(inventory, ingredients, [])
  end

  defp consume_ingredients(inventory, [], consumed_slots), do: {:ok, inventory, consumed_slots}

  defp consume_ingredients(inventory, [{item_id, amount} | rest], consumed_slots) do
    case find_item_slot(inventory, item_id) do
      nil ->
        {:error, :missing_ingredients}

      {slot, item} ->
        take = min(amount, item.amount)
        case Inventory.remove_from_slot(inventory, slot, take) do
          {:ok, new_inventory, _} ->
            remaining = amount - take
            new_consumed = [slot | consumed_slots]
            if remaining > 0 do
              consume_ingredients(new_inventory, [{item_id, remaining} | rest], new_consumed)
            else
              consume_ingredients(new_inventory, rest, new_consumed)
            end

          {:error, _} ->
            {:error, :missing_ingredients}
        end
    end
  end

  defp find_item_slot(inventory, item_id) do
    inventory
    |> Enum.with_index()
    |> Enum.find_value(fn
      {nil, _} -> nil
      {item, slot} -> if item.item_id == item_id and not item.equipped, do: {slot, item}
    end)
  end

  defp update_player(state, char_id, entity) do
    %{state | players: Map.put(state.players, char_id, entity)}
  end

  defp send_msg(state, char_id, message) do
    Helpers.send_to_session(state.sessions, char_id,
      {:send_raw, Encoder.encode({:console_msg, %{message: message, font_index: 0}})})
  end

  defp send_skills(state, char_id, entity) do
    Helpers.send_to_session(state.sessions, char_id,
      {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})})
  end
end
