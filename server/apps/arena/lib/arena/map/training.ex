defmodule Arena.Map.Training do
  @moduledoc "NPC trainer interaction handlers (skill training, creature training)."

  alias Arena.Map.Helpers
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_entrenador 3

  @skill_order [
    :magic, :stealing, :combat_tactics, :combat_weapons, :meditation,
    :short_weapons, :hiding, :survival, :trading, :combat_defense,
    :leadership, :ranged_weapons, :wrestling, :navigation, :riding,
    :resistance, :woodcutting, :fishing, :mining, :blacksmithing,
    :carpentry, :alchemy, :tailoring, :taming
  ]
  @crafting_skills [:woodcutting, :fishing, :mining, :blacksmithing, :carpentry, :alchemy, :tailoring, :taming]

  # VB6 constants
  @max_trainer_creatures 7

  defp msg(state, char_id, message), do: Helpers.msg(state, char_id, message)

  def handle_train_skill(state, char_id, skill_index) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        skill_atom = Enum.at(@skill_order, skill_index)
        trainer_result = Helpers.resolve_nearby_npc(state, entity, [@npc_type_entrenador], 10)
        near_trainer = trainer_result != :not_found

        trainer_npc_def =
          case trainer_result do
            {:ok, _npc, npc_def} -> npc_def
            :not_found -> nil
          end

        cond do
          skill_atom == nil ->
            {:noreply, state}

          near_trainer and not trainer_accepts_skill?(trainer_npc_def, skill_atom) ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "Este entrenador no enseña esa habilidad.", font_index: 0}})}
            )

            {:noreply, state}

          near_trainer and entity.skill_points <= 0 ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "No tienes puntos de skill disponibles.", font_index: 0}})}
            )

            {:noreply, state}

          near_trainer and Map.get(entity.skills, skill_atom, 0) >= 100 ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw,
               Encoder.encode({:console_msg, %{message: "Ya tienes el maximo en esa habilidad.", font_index: 0}})}
            )

            {:noreply, state}

          near_trainer ->
            current = Map.get(entity.skills, skill_atom, 0)
            cost = max(current * 10, 10)

            if entity.gold < cost do
              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode({:console_msg, %{message: "No tienes suficiente oro. Costo: #{cost}", font_index: 0}})}
              )

              {:noreply, state}
            else
              entity = %{
                entity
                | skills: Map.put(entity.skills, skill_atom, current + 1),
                  skill_points: entity.skill_points - 1,
                  gold: entity.gold - cost
              }

              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})}
              )

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw, Encoder.encode({:update_gold, %{gold: entity.gold}})}
              )

              Helpers.send_to_session(
                state.sessions,
                char_id,
                {:send_raw,
                 Encoder.encode(
                   {:console_msg,
                    %{
                      message: "Has entrenado! Costo: #{cost} oro. Skill points restantes: #{entity.skill_points}",
                      font_index: 0
                    }}
                 )}
              )

              {:noreply, state}
            end

          skill_atom in @crafting_skills ->
            Arena.Map.Crafting.handle_work(state, char_id, skill_atom)

          true ->
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un entrenador cerca.", font_index: 0}})}
            )

            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def trainer_accepts_skill?(_npc_def, _skill_atom), do: true

  def handle_train_list(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        trainer =
          case Helpers.resolve_nearby_npc(state, entity, [@npc_type_entrenador], 10) do
            {:ok, _npc, npc_def} -> npc_def
            :not_found -> nil
          end

        if trainer != nil and trainer.creatures != [] do
          raw =
            Encoder.encode({:trainer_creature_list, %{creature_names: trainer.creatures}})

          Helpers.send_to_session(state.sessions, char_id, {:send_raw, raw})
        else
          msg(state, char_id, "No hay criaturas disponibles para entrenar.")
        end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @doc """
  Handle the Train packet (pet_index).

  VB6 flow: player double-clicks a trainer NPC (stores TargetNPC), requests
  train_list (server sends creature names), then sends Train(pet_index) to
  spawn that creature as a pet.

  VB6 checks:
  - TargetNPC must be valid and of type Entrenador (3)
  - Trainer's Mascotas < MAXMASCOTASENTRENADOR (7)
  - PetIndex > 0 and PetIndex <= NroCriaturas
  - SpawnNpc at the trainer's position
  - Sets MaestroNPC on the spawned NPC (links pet to trainer)
  """
  def handle_train_creature(state, char_id, %{pet_index: pet_index}) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        # Validate selected trainer NPC (VB6: IsValidNpcRef(.flags.TargetNPC))
        instance_id = Map.get(entity, :last_clicked_npc_instance_id)
        npc_type = Map.get(entity, :last_clicked_npc_type)

        cond do
          instance_id == nil or npc_type != @npc_type_entrenador ->
            msg(state, char_id, "Primero selecciona un entrenador.")
            {:noreply, state}

          true ->
            case Map.get(state.npcs_live, instance_id) do
              nil ->
                msg(state, char_id, "El entrenador no esta disponible.")
                {:noreply, state}

              trainer_npc ->
                # Check distance (VB6 uses implicit proximity from double-click, range 10)
                if abs(trainer_npc.x - entity.x) > 10 or abs(trainer_npc.y - entity.y) > 10 do
                  msg(state, char_id, "Estas demasiado lejos del entrenador.")
                  {:noreply, state}
                else
                  do_train_creature(state, char_id, entity, trainer_npc, pet_index)
                end
            end
        end

      :error ->
        {:noreply, state}
    end
  end

  def do_train_creature(state, char_id, entity, trainer_npc, pet_index) do
    trainer_npc_def = GameData.get_npc(trainer_npc.npc_id)

    cond do
      trainer_npc_def == nil ->
        msg(state, char_id, "Entrenador no reconocido.")
        {:noreply, state}

      trainer_npc_def.npc_type != @npc_type_entrenador ->
        msg(state, char_id, "Ese NPC no es un entrenador.")
        {:noreply, state}

      true ->
        creatures = trainer_npc_def.creatures

        # Count how many creatures this trainer has already spawned
        # VB6: NpcList(.flags.TargetNPC.ArrayIndex).Mascotas
        trainer_spawned_count =
          state.npcs_live
          |> Enum.count(fn {_id, npc} ->
            Map.get(npc, :trainer_master_id) == trainer_npc.instance_id
          end)

        cond do
          # VB6: PetIndex > 0 And PetIndex < NroCriaturas + 1
          pet_index < 1 or pet_index > length(creatures) ->
            msg(state, char_id, "Indice de criatura invalido.")
            {:noreply, state}

          # VB6: Mascotas < MAXMASCOTASENTRENADOR
          trainer_spawned_count >= @max_trainer_creatures ->
            msg(state, char_id, "El entrenador no puede invocar mas criaturas.")
            {:noreply, state}

          true ->
            # creatures list stores NPC IDs as strings (parsed from CI1..CI5 in npcs.dat)
            creature_npc_id_str = Enum.at(creatures, pet_index - 1)

            case Integer.parse(creature_npc_id_str || "") do
              {creature_npc_id, _} ->
                creature_def = GameData.get_npc(creature_npc_id)

                if creature_def == nil do
                  msg(state, char_id, "Criatura no encontrada.")
                  {:noreply, state}
                else
                  spawn_trainer_creature(
                    state,
                    char_id,
                    entity,
                    trainer_npc,
                    creature_def
                  )
                end

              :error ->
                msg(state, char_id, "Criatura no encontrada.")
                {:noreply, state}
            end
        end
    end
  end

  def spawn_trainer_creature(state, char_id, _entity, trainer_npc, creature_def) do
    alias Arena.Entity.NpcEntity

    # VB6: SpawnNpc at the trainer's position
    tx = trainer_npc.x
    ty = trainer_npc.y

    instance_id = state.next_char_index
    npc_entity = NpcEntity.from_def(creature_def, instance_id, instance_id, tx, ty)

    # Set owner to the player and link to the trainer (VB6: MaestroNPC)
    npc_entity = %{npc_entity | owner_id: char_id, trainer_master_id: trainer_npc.instance_id}

    npcs_live = Map.put(state.npcs_live, instance_id, npc_entity)
    npc_char_indices = Map.put(state.npc_char_indices, instance_id, instance_id)

    # Add to player's pet list
    player = state.players[char_id]
    player = %{player | pet_ids: [instance_id | player.pet_ids]}

    state = %{
      state
      | npcs_live: npcs_live,
        npc_char_indices: npc_char_indices,
        next_char_index: instance_id + 1,
        players: Map.put(state.players, char_id, player)
    }

    # Broadcast NPC creation to nearby players
    raw = Encoder.encode(Helpers.npc_create_packet(npc_entity, creature_def))

    Arena.Map.Visibility.broadcast_visible_all(state, tx, ty, fn pid ->
      send(pid, {:send_raw, raw})
    end)

    creature_name = creature_def.name || "la criatura"
    msg(state, char_id, "El entrenador ha invocado a #{creature_name}.")
    {:noreply, state}
  end
end
