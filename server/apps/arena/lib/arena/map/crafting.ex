defmodule Arena.Map.Crafting do
  @moduledoc """
  Crafting and gathering handlers for the Work packet.

  VB6 behavior: player must have the right tool equipped, be near the
  right resource (tile type or object), and pass a skill roll.

  Production crafting follows the legacy VB6 trigger model:
  - **Blacksmithing**: requires the smith hammer equipped plus a selected anvil
    or forge object within 2 tiles.
  - **Alchemy / Carpentry / Tailoring**: forms are opened by using the equipped
    working tool, not by standing near a workstation NPC.

  All public handlers are on the effects contract — they return
  `{:ok, state, [Effect.t()]}` and rejection paths are communicated as
  console-message effects rather than non-`:ok` reply terms. The
  exception is `handle_tool_use/4..6`, which is invoked from
  `InventoryHandlers.apply_item_use/6` and returns the richer
  `{:ok, entity, state, effects} | {:error, reason}` shape so the
  inventory-use cooldown can be applied around the call.
  """

  alias Arena.Map.{Effects, Helpers}
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

  # VB6 object types: otAnvil=27, otForge=28
  @blacksmith_object_types [27, 28]
  @blacksmith_target_range 2

  @work_stamina_cost 15

  # VB6 parity: workers (clase Trabajador) craft at normal stamina cost.
  # All other classes pay 3x the stamina cost per work action.
  @non_worker_stamina_multiplier 3
  @worker_classes [:worker, :trabajador]
  @must_equip_tool_msg "Antes de usar la herramienta deberias equipartela."
  @must_click_anvil_msg "Debes hacer click derecho sobre el yunque."
  @too_far_msg "Estas demasiado lejos."
  @use_equipped_tool_msg "Debes usar la herramienta equipada para construir."


  defp effective_stamina_cost(entity) do
    if entity.class in @worker_classes do
      @work_stamina_cost
    else
      @work_stamina_cost * @non_worker_stamina_multiplier
    end
  end

  @doc "Main entry point — called from Social/Training when work packet targets a crafting skill."
  def handle_work(state, char_id, skill_atom) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cost = effective_stamina_cost(entity)

        cond do
          entity.dead ->
            {:ok, state, [Effects.send(char_id, console("No puedes trabajar estando muerto."))]}

          entity.stamina < cost ->
            {:ok, state, [Effects.send(char_id, console("Estás muy cansado para trabajar."))]}

          true ->
            do_work(state, char_id, entity, skill_atom)
        end

      :error ->
        {:ok, state, []}
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
        prompt_production_trigger(state, char_id, :blacksmithing)

      :carpentry ->
        prompt_production_trigger(state, char_id, :carpentry)

      :alchemy ->
        prompt_production_trigger(state, char_id, :alchemy)

      :tailoring ->
        prompt_production_trigger(state, char_id, :tailoring)

      :taming ->
        attempt_taming(state, char_id, entity)

      _ ->
        {:ok, state, [Effects.send(char_id, console("No puedes trabajar en eso."))]}
    end
  end

  defp prompt_production_trigger(state, char_id, :blacksmithing) do
    {:ok, state, [Effects.send(char_id, console(@must_click_anvil_msg))]}
  end

  defp prompt_production_trigger(state, char_id, _skill_atom) do
    {:ok, state, [Effects.send(char_id, console(@use_equipped_tool_msg))]}
  end

  @doc """
  Open a production crafting form from the equipped working tool.

  Called from `InventoryHandlers.apply_item_use/6` when an `obj_type 18`
  working tool is used. Returns the richer
  `{:ok, entity, state, effects} | {:error, reason}` shape so the caller
  can apply the inventory-use cooldown to `entity` around the call.

  VB6:
  - hammer -> selected anvil/forge object
  - saw/pot/sewing kit -> direct form open from equipped tool use
  """
  def handle_tool_use(state, char_id, entity, item_id, target_x \\ nil, target_y \\ nil) do
    cond do
      item_id in @hammer_ids ->
        open_blacksmith_window(state, char_id, entity, target_x, target_y)

      item_id in @saw_ids ->
        open_tool_window(state, char_id, entity, :carpentry, @saw_ids)

      item_id in @alchemy_ids ->
        open_tool_window(state, char_id, entity, :alchemy, @alchemy_ids)

      item_id in @sewing_ids ->
        open_tool_window(state, char_id, entity, :tailoring, @sewing_ids)

      true ->
        {:error, :not_usable}
    end
  end

  defp open_blacksmith_window(state, char_id, entity, target_x, target_y) do
    cond do
      not tool_equipped?(entity, @hammer_ids) ->
        # Caller (`apply_item_use`) treats `{:error, _}` as "no state change,
        # no effects" — emit the console message inline via the effects
        # runner so the rejection still reaches the player.
        Effects.run(state, [Effects.send(char_id, console(@must_equip_tool_msg))])
        {:error, :must_equip_tool}

      true ->
        case validate_blacksmith_target(state, entity, target_x, target_y) do
          {:ok, []} ->
            {:ok, state, effects} = open_crafting_window(state, char_id, :blacksmithing)
            {:ok, entity, state, effects}

          {:error, reason, effects} ->
            Effects.run(state, effects)
            {:error, reason}
        end
    end
  end

  defp open_tool_window(state, char_id, entity, skill_atom, tool_ids) do
    if tool_equipped?(entity, tool_ids) do
      {:ok, state, effects} = open_crafting_window(state, char_id, skill_atom)
      {:ok, entity, state, effects}
    else
      Effects.run(state, [Effects.send(char_id, console(@must_equip_tool_msg))])
      {:error, :must_equip_tool}
    end
  end

  @max_pets 3
  @taming_range 3
  # VB6 parity: max 2 pets of the same NPC type (PuedeDomarMascota)
  @max_same_type_pets 2
  # VB6 parity: Druids divide puntosDomar by 6, all others by 118
  @druid_taming_divisor 6
  @default_taming_divisor 118

  # ---- Taming ----

  @doc """
  VB6 taming score formula (public for testability).

  puntosDomar = Charisma * TamingSkill
  Druids: puntosDomar / 6
  Others: puntosDomar / 118
  """
  def taming_score(entity, class) do
    cha = Map.get(entity, :cha, 18)
    skill_value = Map.get(entity.skills, :taming, 0)
    raw = cha * skill_value

    case class do
      :druida -> div(raw, @druid_taming_divisor)
      _ -> div(raw, @default_taming_divisor)
    end
  end

  defp attempt_taming(state, char_id, entity) do
    cond do
      length(entity.pet_ids) >= @max_pets ->
        {:ok, state, [Effects.send(char_id, console("Ya tienes demasiadas mascotas."))]}

      true ->
        case find_tameable_npc(state, entity) do
          nil ->
            {:ok, state,
             [Effects.send(char_id, console("No hay criaturas cerca para domar."))]}

          {instance_id, npc} ->
            npc_def = GameData.get_npc(npc.npc_id)
            skill_value = Map.get(entity.skills, :taming, 0)

            cond do
              # VB6 drift #3: minimum tame level check
              npc_def != nil and Map.get(npc_def, :min_tame_level, 1) > entity.level ->
                min_level = Map.get(npc_def, :min_tame_level, 1)

                {:ok, state,
                 [
                   Effects.send(
                     char_id,
                     console(
                       "Debes ser nivel #{min_level} o superior para domar esta criatura."
                     )
                   )
                 ]}

              # VB6 drift #5: duplicate-type pet limit (max 2 of same NPC type)
              not can_tame_pet_type?(state, entity, npc.npc_id) ->
                {:ok, state,
                 [Effects.send(char_id, console("Ya tienes demasiadas mascotas de ese tipo."))]}

              true ->
                {entity, state, stamina_effects} = consume_stamina(state, char_id, entity)

                # VB6 drift #1 + #2: Charisma * Taming / class_divisor
                score = taming_score(entity, entity.class)
                domable = if npc_def, do: Map.get(npc_def, :domable, 0), else: 0

                # VB6 drift #4: domable check AND 1-in-5 random gate
                if domable <= score and Arena.Rng.uniform(5) == 1 do
                  # Taming success — set ownership
                  npc = %{npc | owner_id: char_id, target_id: nil}
                  state = put_in(state.npcs_live[instance_id], npc)

                  entity = %{entity | pet_ids: [instance_id | entity.pet_ids]}
                  entity = try_skill_up(entity, :taming, skill_value)
                  state = update_player(state, char_id, entity)

                  name = if npc_def, do: npc_def.name, else: "la criatura"

                  base_effects =
                    stamina_effects ++
                      [
                        skills_effect(char_id, entity),
                        Effects.send(char_id, console("Has domado a #{name}!"))
                      ]

                  # VB6 drift #6: safe-zone pet handling
                  no_mascotas =
                    Map.get(state.meta, :no_mascotas, false) or
                      Map.get(state.meta, :safe_zone, false)

                  if no_mascotas do
                    # Remove NPC from map but keep in pet_ids
                    state = %{state | npcs_live: Map.delete(state.npcs_live, instance_id)}

                    {:ok, state,
                     base_effects ++
                       [Effects.send(char_id, console("Tu mascota te aguarda afuera."))]}
                  else
                    {:ok, state, base_effects}
                  end
                else
                  entity = try_skill_up(entity, :taming, skill_value)
                  state = update_player(state, char_id, entity)

                  effects =
                    stamina_effects ++
                      [
                        skills_effect(char_id, entity),
                        Effects.send(char_id, console("No has podido domar a la criatura."))
                      ]

                  {:ok, state, effects}
                end
            end
        end
    end
  end

  # VB6 parity (PuedeDomarMascota): max 2 pets of the same NPC type.
  defp can_tame_pet_type?(state, entity, target_npc_id) do
    same_type_count =
      entity.pet_ids
      |> Enum.count(fn instance_id ->
        case Map.get(state.npcs_live, instance_id) do
          nil -> false
          pet -> pet.npc_id == target_npc_id
        end
      end)

    same_type_count < @max_same_type_pets
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
    |> Enum.min_by(fn {_id, npc} -> Helpers.vb6_distancia(npc, entity) end, fn -> nil end)
  end

  # ---- Gathering (mining, woodcutting) ----

  defp gather(state, char_id, entity, skill_atom, weapon_id, tool_ids) do
    cond do
      weapon_id not in tool_ids ->
        {:ok, state,
         [Effects.send(char_id, console("Necesitas la herramienta adecuada."))]}

      not resource_nearby?(state, entity, skill_atom) ->
        {:ok, state,
         [Effects.send(char_id, console("No hay recursos cerca para trabajar."))]}

      true ->
        attempt_gathering(state, char_id, entity, skill_atom)
    end
  end

  # ---- Fishing (special: check facing water tile) ----

  defp fish(state, char_id, entity, weapon_id) do
    cond do
      weapon_id not in @fishing_rod_ids ->
        {:ok, state, [Effects.send(char_id, console("Necesitas una caña de pescar."))]}

      not facing_water?(state, entity) ->
        {:ok, state, [Effects.send(char_id, console("No hay agua donde pescar."))]}

      true ->
        attempt_gathering(state, char_id, entity, :fishing)
    end
  end

  # ---- Skill roll + item creation ----

  defp attempt_gathering(state, char_id, entity, skill_atom) do
    skill_value = Map.get(entity.skills, skill_atom, 0)

    {entity, state, stamina_effects} = consume_stamina(state, char_id, entity)

    if skill_check(skill_value) do
      case CraftingRecipes.select_product(skill_atom, skill_value) do
        nil ->
          {:ok, state,
           stamina_effects ++ [Effects.send(char_id, console("No has podido obtener nada."))]}

        item_id ->
          case Inventory.add_item(entity.inventory, item_id, 1) do
            {:ok, new_inventory, slot} ->
              entity = try_skill_up(entity, skill_atom, skill_value)
              entity = %{entity | inventory: new_inventory}
              state = update_player(state, char_id, entity)

              item_def = GameData.get_item(item_id)
              name = if item_def, do: item_def.name, else: "un objeto"

              effects =
                stamina_effects ++
                  [
                    Effects.send(char_id, inventory_slot_packet(new_inventory, slot)),
                    skills_effect(char_id, entity),
                    Effects.send(char_id, console("Has obtenido #{name}."))
                  ]

              {:ok, state, effects}

            {:error, :inventory_full} ->
              {:ok, state,
               stamina_effects ++
                 [Effects.send(char_id, console("No tienes espacio en el inventario."))]}

            {:gold, _} ->
              {:ok, state, stamina_effects}
          end
      end
    else
      entity = try_skill_up(entity, skill_atom, skill_value)
      state = update_player(state, char_id, entity)

      effects =
        stamina_effects ++
          [
            Effects.send(char_id, console("No has podido obtener nada.")),
            skills_effect(char_id, entity)
          ]

      {:ok, state, effects}
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

  defp skill_check(skill_value), do: Arena.Rng.uniform(100) <= skill_value

  defp try_skill_up(entity, skill_atom, skill_value) do
    if skill_value < 100 and Arena.Rng.uniform(100) > skill_value do
      %{entity | skills: Map.put(entity.skills, skill_atom, skill_value + 1)}
    else
      entity
    end
  end

  # Returns `{entity, state, [effect]}` — caller threads effects through the
  # outgoing list so all packets traverse the egress queue.
  defp consume_stamina(state, char_id, entity) do
    cost = effective_stamina_cost(entity)
    new_stamina = max(entity.stamina - cost, 0)
    entity = %{entity | stamina: new_stamina}
    state = update_player(state, char_id, entity)

    effects = [
      Effects.send(char_id, Encoder.encode({:update_stamina, %{min_sta: new_stamina}}))
    ]

    {entity, state, effects}
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

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  defp skills_effect(char_id, entity) do
    Effects.send(char_id, Encoder.encode({:send_skills, %{skills: entity.skills}}))
  end

  # Mirror of `Helpers.send_inventory_slot/4` packet construction (sans
  # transmission). Crafting handlers emit the binary packet through an
  # `Effects.send/2` effect rather than calling the legacy
  # `{:send_raw, _}` shim.
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

  # ==================================================================
  # Crafting UI: open window (send recipe list) and craft specific item
  # ==================================================================

  @doc """
  Send the crafting window for a given skill to the player.
  Sends the recipe list followed by the show-form packet.
  VB6 flow: equipped tool or selected workstation object → server sends item
  list + show form → client opens window.
  """
  def open_crafting_window(state, char_id, skill_atom) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        skill_value = Map.get(entity.skills, skill_atom, 0)
        items = CraftingRecipes.craftable_item_ids(skill_atom, skill_value)

        effects = [
          Effects.send(char_id, recipe_list_packet(skill_atom, items)),
          Effects.send(char_id, show_form_packet(skill_atom))
        ]

        {:ok, state, effects}

      :error ->
        {:ok, state, []}
    end
  end

  @doc """
  Handle a craft request for a specific item from the crafting UI.
  The client sends the item_id (result) that the player selected in the window.
  The 4-arity version defaults to amount=1 (backwards compatible).
  The 5-arity version accepts an amount for batch crafting (CraftCarpenter).
  """
  def handle_craft_item(state, char_id, skill_atom, item_id),
    do: handle_craft_item(state, char_id, skill_atom, item_id, 1, nil, nil)

  def handle_craft_item(state, char_id, skill_atom, item_id, amount) when amount >= 1 do
    handle_craft_item(state, char_id, skill_atom, item_id, amount, nil, nil)
  end

  def handle_craft_item(state, char_id, skill_atom, item_id, amount, target_x, target_y)
      when amount >= 1 do
    do_craft_item_loop(state, char_id, skill_atom, item_id, amount, target_x, target_y, [])
  end

  def handle_craft_item(state, _char_id, _skill_atom, _item_id, _amount, _target_x, _target_y) do
    {:ok, state, []}
  end

  defp do_craft_item_loop(state, _char_id, _skill_atom, _item_id, 0, _target_x, _target_y, acc),
    do: {:ok, state, acc}

  defp do_craft_item_loop(state, char_id, skill_atom, item_id, remaining, target_x, target_y, acc) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cost = effective_stamina_cost(entity)

        cond do
          entity.dead ->
            {:ok, state,
             acc ++ [Effects.send(char_id, console("No puedes trabajar estando muerto."))]}

          entity.stamina < cost ->
            {:ok, state,
             acc ++ [Effects.send(char_id, console("Estás muy cansado para trabajar."))]}

          true ->
            case do_craft_item(state, char_id, entity, skill_atom, item_id, target_x, target_y) do
              {:ok, new_state, step_effects, :continue} when remaining > 1 ->
                do_craft_item_loop(
                  new_state,
                  char_id,
                  skill_atom,
                  item_id,
                  remaining - 1,
                  target_x,
                  target_y,
                  acc ++ step_effects
                )

              {:ok, new_state, step_effects, _} ->
                {:ok, new_state, acc ++ step_effects}
            end
        end

      :error ->
        {:ok, state, acc}
    end
  end

  # Returns `{:ok, state, effects, :continue | :stop}` so the loop knows
  # whether to keep iterating after a successful craft (continue) or to
  # halt on rejection / partial-success (stop).
  defp do_craft_item(state, char_id, entity, skill_atom, item_id, target_x, target_y) do
    skill_value = Map.get(entity.skills, skill_atom, 0)

    case CraftingRecipes.find_recipe_by_item(skill_atom, item_id) do
      nil ->
        {:ok, state,
         [Effects.send(char_id, console("No puedes construir ese objeto."))], :stop}

      recipe ->
        case validate_crafting_request(state, char_id, entity, skill_atom, target_x, target_y) do
          {:ok, []} ->
            cond do
              skill_value < recipe.min_skill ->
                {:ok, state,
                 [Effects.send(char_id, console("No tienes suficiente habilidad."))], :stop}

              not has_ingredients_for?(entity.inventory, recipe.ingredients) ->
                {:ok, state,
                 [Effects.send(char_id, console("No tienes los materiales necesarios."))],
                 :stop}

              true ->
                {entity, state, stamina_effects} = consume_stamina(state, char_id, entity)

                case consume_ingredients(entity.inventory, recipe.ingredients) do
                  {:ok, new_inventory, consumed_slots} ->
                    case Inventory.add_item(
                           new_inventory,
                           recipe.result_id,
                           recipe.result_amount
                         ) do
                      {:ok, final_inventory, result_slot} ->
                        entity = try_skill_up(entity, skill_atom, skill_value)
                        entity = %{entity | inventory: final_inventory}
                        state = update_player(state, char_id, entity)

                        consumed_effects =
                          for slot <- consumed_slots do
                            Effects.send(
                              char_id,
                              inventory_slot_packet(final_inventory, slot)
                            )
                          end

                        item_def = GameData.get_item(recipe.result_id)
                        name = if item_def, do: item_def.name, else: "un objeto"

                        effects =
                          stamina_effects ++
                            consumed_effects ++
                            [
                              Effects.send(
                                char_id,
                                inventory_slot_packet(final_inventory, result_slot)
                              ),
                              skills_effect(char_id, entity),
                              Effects.send(char_id, console("Has creado #{name}."))
                            ]

                        {:ok, state, effects, :continue}

                      {:error, :inventory_full} ->
                        {:ok, state,
                         stamina_effects ++
                           [
                             Effects.send(
                               char_id,
                               console("No tienes espacio en el inventario.")
                             )
                           ], :stop}

                      {:gold, _} ->
                        {:ok, state, stamina_effects, :stop}
                    end

                  {:error, :missing_ingredients} ->
                    {:ok, state,
                     stamina_effects ++
                       [
                         Effects.send(
                           char_id,
                           console("No tienes los materiales necesarios.")
                         )
                       ], :stop}
                end
            end

          {:error, _reason, effects} ->
            {:ok, state, effects, :stop}
        end
    end
  end

  # validate_crafting_request returns `{:ok, []}` on success or
  # `{:error, reason, effects}` on rejection. Effects include the
  # console rejection messages so callers can append them to the
  # outgoing list.
  defp validate_crafting_request(state, char_id, entity, :blacksmithing, target_x, target_y) do
    cond do
      not tool_equipped?(entity, @hammer_ids) ->
        {:error, :must_equip_tool,
         [Effects.send(char_id, console(@must_equip_tool_msg))]}

      true ->
        validate_blacksmith_target(state, entity, target_x, target_y)
    end
  end

  defp validate_crafting_request(_state, char_id, entity, skill_atom, _target_x, _target_y)
       when skill_atom in [:carpentry, :alchemy, :tailoring] do
    if tool_equipped?(entity, required_tool_ids(skill_atom)) do
      {:ok, []}
    else
      {:error, :must_equip_tool,
       [Effects.send(char_id, console(@must_equip_tool_msg))]}
    end
  end

  defp validate_crafting_request(_state, _char_id, _entity, _skill_atom, _target_x, _target_y),
    do: {:ok, []}

  defp tool_equipped?(entity, tool_ids), do: Map.get(entity.equipment, :weapon) in tool_ids

  defp required_tool_ids(:blacksmithing), do: @hammer_ids
  defp required_tool_ids(:carpentry), do: @saw_ids
  defp required_tool_ids(:alchemy), do: @alchemy_ids
  defp required_tool_ids(:tailoring), do: @sewing_ids

  defp validate_blacksmith_target(state, entity, target_x, target_y) do
    cond do
      is_nil(target_x) or is_nil(target_y) ->
        {:error, :missing_target,
         [Effects.send(entity.char_id, console(@must_click_anvil_msg))]}

      Helpers.vb6_distancia_xy(entity.x, entity.y, target_x, target_y) > @blacksmith_target_range ->
        {:error, :too_far, [Effects.send(entity.char_id, console(@too_far_msg))]}

      true ->
        case blacksmith_target_object(state, target_x, target_y) do
          nil ->
            {:error, :invalid_target,
             [Effects.send(entity.char_id, console(@must_click_anvil_msg))]}

          _obj ->
            {:ok, []}
        end
    end
  end

  defp blacksmith_target_object(state, target_x, target_y) do
    state.meta
    |> Map.get(:objects, [])
    |> Enum.find(fn %{x: x, y: y, obj_index: obj_index} ->
      x == target_x and y == target_y and blacksmith_object?(obj_index)
    end)
  end

  defp blacksmith_object?(obj_index) do
    case GameData.get_item(obj_index) do
      nil -> false
      item_def -> item_def.obj_type in @blacksmith_object_types
    end
  end

  defp has_ingredients_for?(inventory, ingredients) do
    Enum.all?(ingredients, fn {item_id, amount} ->
      count =
        inventory
        |> Enum.filter(& &1)
        |> Enum.filter(&(&1.item_id == item_id))
        |> Enum.map(& &1.amount)
        |> Enum.sum()

      count >= amount
    end)
  end

  defp recipe_list_packet(:blacksmithing, items),
    do: Encoder.encode({:blacksmith_weapons, %{items: items}})

  defp recipe_list_packet(:carpentry, items),
    do: Encoder.encode({:carpenter_objects, %{items: items}})

  defp recipe_list_packet(:alchemy, items),
    do: Encoder.encode({:alquimista_objects, %{items: items}})

  defp recipe_list_packet(:tailoring, items),
    do: Encoder.encode({:sastre_objects, %{items: items}})

  defp show_form_packet(:blacksmithing), do: Encoder.encode({:show_blacksmith_form, %{}})
  defp show_form_packet(:carpentry), do: Encoder.encode({:show_carpenter_form, %{}})
  defp show_form_packet(:alchemy), do: Encoder.encode({:show_alchemy_form, %{}})
  defp show_form_packet(:tailoring), do: Encoder.encode({:show_tailor_form, %{}})
end
