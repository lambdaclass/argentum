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
  # Piquete de Minero, Dorado, Blodium
  @pickaxe_ids [187, 363, 46]
  # Caña de Pescar variants
  @fishing_rod_ids [881, 2121, 2132, 2133]
  # Hacha de Leñador, Élfica
  @woodcutting_axe_ids [127, 361]
  # Martillo de Herrero
  @hammer_ids [389]
  # Serrucho
  @saw_ids [198]
  # Costurero, Tijeras, Tijeras doradas
  @sewing_ids [886, 885, 369]
  # Olla de Alquimia
  @alchemy_ids [887]

  # NPC types for production workstations
  @npc_type_forge 5
  @npc_type_workbench 6
  @npc_type_alchemy 7
  @npc_type_loom 8

  @work_stamina_cost 15

  # VB6 parity: workers (clase Trabajador) craft at normal stamina cost.
  # All other classes pay 3x the stamina cost per work action.
  @non_worker_stamina_multiplier 3
  @worker_classes [:worker, :trabajador]


  defp effective_stamina_cost(entity) do
    if entity.class in @worker_classes do
      @work_stamina_cost
    else
      @work_stamina_cost * @non_worker_stamina_multiplier
    end
  end

  @doc "Main entry point — called from Social when work packet targets a crafting skill."
  def handle_work(state, char_id, skill_atom) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cost = effective_stamina_cost(entity)

        cond do
          entity.dead ->
            send_msg(state, char_id, "No puedes trabajar estando muerto.")
            {:noreply, state}

          entity.stamina < cost ->
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
      :mining ->
        gather(state, char_id, entity, :mining, weapon_id, @pickaxe_ids)

      :fishing ->
        fish(state, char_id, entity, weapon_id)

      :woodcutting ->
        gather(state, char_id, entity, :woodcutting, weapon_id, @woodcutting_axe_ids)

      :blacksmithing ->
        produce(state, char_id, entity, :blacksmithing, weapon_id, @hammer_ids, [@npc_type_forge])

      :carpentry ->
        produce(state, char_id, entity, :carpentry, weapon_id, @saw_ids, [@npc_type_workbench])

      :alchemy ->
        produce(state, char_id, entity, :alchemy, weapon_id, @alchemy_ids, [@npc_type_alchemy])

      :tailoring ->
        produce(state, char_id, entity, :tailoring, weapon_id, @sewing_ids, [@npc_type_loom])

      :taming ->
        attempt_taming(state, char_id, entity)

      _ ->
        send_msg(state, char_id, "No puedes trabajar en eso.")
        {:noreply, state}
    end
  end

  @max_pets 3
  @taming_range 3

  # ---- Taming ----

  defp attempt_taming(state, char_id, entity) do
    cond do
      length(entity.pet_ids) >= @max_pets ->
        send_msg(state, char_id, "Ya tienes demasiadas mascotas.")
        {:noreply, state}

      true ->
        case find_tameable_npc(state, entity) do
          nil ->
            send_msg(state, char_id, "No hay criaturas cerca para domar.")
            {:noreply, state}

          {instance_id, npc} ->
            skill_value = Map.get(entity.skills, :taming, 0)
            {entity, state} = consume_stamina(state, char_id, entity)

            if skill_check(skill_value) do
              # Taming success — set ownership
              npc = %{npc | owner_id: char_id, target_id: nil}
              state = put_in(state.npcs_live[instance_id], npc)

              entity = %{entity | pet_ids: [instance_id | entity.pet_ids]}
              entity = try_skill_up(entity, :taming, skill_value)
              state = update_player(state, char_id, entity)
              send_skills(state, char_id, entity)

              npc_def = GameData.get_npc(npc.npc_id)
              name = if npc_def, do: npc_def.name, else: "la criatura"
              send_msg(state, char_id, "Has domado a #{name}!")
              {:noreply, state}
            else
              entity = try_skill_up(entity, :taming, skill_value)
              state = update_player(state, char_id, entity)
              send_skills(state, char_id, entity)
              send_msg(state, char_id, "No has podido domar a la criatura.")
              {:noreply, state}
            end
        end
    end
  end

  # Find the nearest alive hostile NPC within taming range that is not already a pet.
  defp find_tameable_npc(state, entity) do
    state.npcs_live
    |> Enum.filter(fn {_id, npc} ->
      npc.alive and npc.owner_id == nil and
        abs(npc.x - entity.x) <= @taming_range and
        abs(npc.y - entity.y) <= @taming_range
    end)
    |> Enum.filter(fn {_id, npc} ->
      npc_def = GameData.get_npc(npc.npc_id)
      npc_def != nil and npc_def.hostile
    end)
    |> Enum.min_by(fn {_id, npc} -> abs(npc.x - entity.x) + abs(npc.y - entity.y) end, fn -> nil end)
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

      Arena.Map.Helpers.find_nearby_npc_of_type(state, entity, npc_types, 5) == :not_found ->
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
    TileGrid.get_tile(state.map_id, fx, fy) == 2
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
    cost = effective_stamina_cost(entity)
    new_stamina = max(entity.stamina - cost, 0)
    entity = %{entity | stamina: new_stamina}
    state = update_player(state, char_id, entity)

    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:update_stamina, %{min_sta: new_stamina}})}
    )

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
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:console_msg, %{message: message, font_index: 0}})}
    )
  end

  defp send_skills(state, char_id, entity) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})}
    )
  end

  # ==================================================================
  # Crafting UI: open window (send recipe list) and craft specific item
  # ==================================================================

  @doc """
  Send the crafting window for a given skill to the player.
  Sends the recipe list followed by the show-form packet.
  VB6 flow: NPC interaction → server sends item list + show form → client opens window.
  """
  def open_crafting_window(state, char_id, skill_atom) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        skill_value = Map.get(entity.skills, skill_atom, 0)
        items = CraftingRecipes.craftable_item_ids(skill_atom, skill_value)

        send_recipe_list(state, char_id, skill_atom, items)
        send_show_form(state, char_id, skill_atom)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @doc """
  Handle a craft request for a specific item from the crafting UI.
  The client sends the item_id (result) that the player selected in the window.
  The 4-arity version defaults to amount=1 (backwards compatible).
  The 5-arity version accepts an amount for batch crafting (CraftCarpenter).
  """
  def handle_craft_item(state, char_id, skill_atom, item_id),
    do: handle_craft_item(state, char_id, skill_atom, item_id, 1)

  def handle_craft_item(state, char_id, skill_atom, item_id, amount) when amount >= 1 do
    do_craft_item_loop(state, char_id, skill_atom, item_id, amount)
  end

  def handle_craft_item(state, _char_id, _skill_atom, _item_id, _amount) do
    {:noreply, state}
  end

  defp do_craft_item_loop(state, _char_id, _skill_atom, _item_id, 0), do: {:noreply, state}

  defp do_craft_item_loop(state, char_id, skill_atom, item_id, remaining) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cost = effective_stamina_cost(entity)

        cond do
          entity.dead ->
            send_msg(state, char_id, "No puedes trabajar estando muerto.")
            {:noreply, state}

          entity.stamina < cost ->
            send_msg(state, char_id, "Estás muy cansado para trabajar.")
            {:noreply, state}

          true ->
            case do_craft_item(state, char_id, entity, skill_atom, item_id) do
              {:noreply, new_state} when remaining > 1 ->
                do_craft_item_loop(new_state, char_id, skill_atom, item_id, remaining - 1)

              result ->
                result
            end
        end

      :error ->
        {:noreply, state}
    end
  end

  defp do_craft_item(state, char_id, entity, skill_atom, item_id) do
    skill_value = Map.get(entity.skills, skill_atom, 0)

    case CraftingRecipes.find_recipe_by_item(skill_atom, item_id) do
      nil ->
        send_msg(state, char_id, "No puedes construir ese objeto.")
        {:noreply, state}

      recipe ->
        cond do
          skill_value < recipe.min_skill ->
            send_msg(state, char_id, "No tienes suficiente habilidad.")
            {:noreply, state}

          not has_ingredients_for?(entity.inventory, recipe.ingredients) ->
            send_msg(state, char_id, "No tienes los materiales necesarios.")
            {:noreply, state}

          true ->
            {entity, state} = consume_stamina(state, char_id, entity)

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

                  {:error, :inventory_full} ->
                    send_msg(state, char_id, "No tienes espacio en el inventario.")
                    {:noreply, state}

                  {:gold, _} ->
                    {:noreply, state}
                end

              {:error, :missing_ingredients} ->
                send_msg(state, char_id, "No tienes los materiales necesarios.")
                {:noreply, state}
            end
        end
    end
  end

  defp has_ingredients_for?(inventory, ingredients) do
    Enum.all?(ingredients, fn {item_id, amount} ->
      count = inventory |> Enum.filter(& &1) |> Enum.filter(&(&1.item_id == item_id)) |> Enum.map(& &1.amount) |> Enum.sum()
      count >= amount
    end)
  end

  defp send_recipe_list(state, char_id, :blacksmithing, items) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:blacksmith_weapons, %{items: items}})}
    )
  end

  defp send_recipe_list(state, char_id, :carpentry, items) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:carpenter_objects, %{items: items}})}
    )
  end

  defp send_recipe_list(state, char_id, :alchemy, items) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:alquimista_objects, %{items: items}})}
    )
  end

  defp send_recipe_list(state, char_id, :tailoring, items) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:sastre_objects, %{items: items}})}
    )
  end

  defp send_show_form(state, char_id, :blacksmithing) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:show_blacksmith_form, %{}})}
    )
  end

  defp send_show_form(state, char_id, :carpentry) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:show_carpenter_form, %{}})}
    )
  end

  defp send_show_form(state, char_id, :alchemy) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:show_alchemy_form, %{}})}
    )
  end

  defp send_show_form(state, char_id, :tailoring) do
    Helpers.send_to_session(
      state.sessions,
      char_id,
      {:send_raw, Encoder.encode({:show_tailor_form, %{}})}
    )
  end
end
