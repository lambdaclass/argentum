defmodule Arena.Map.Healing do
  @moduledoc "Rest, meditate, heal, and resurrect handlers."

  alias Arena.Map.{Effects, Helpers}
  alias AoProtocol.Server.Encoder

  @magical_classes [:mage, :cleric, :druid, :bard, :paladin]
  @npc_type_revividor 1
  @npc_type_resucitador_newbie 9
  # VB6: MAP_HOME_IN_JAIL = 66
  @jail_map_id 66
  # VB6: FOGATA object id (OBJ_INDEX_FOGATA = 21)
  @fogata_obj_index 21
  # VB6: HayOBJarea checks within 8 tiles
  @fogata_radius 8

  defp selected_priest(state, entity, max_distance) do
    Helpers.resolve_selected_npc(
      state,
      entity,
      [@npc_type_revividor, @npc_type_resucitador_newbie],
      max_distance
    )
  end

  def handle_rest(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            {:ok, state, [Effects.send(char_id, console("Estas muerto."))]}

          entity.hp >= entity.max_hp ->
            {:ok, state, [Effects.send(char_id, console("Estas sano."))]}

          # VB6: If HayOBJarea(.pos, FOGATA) Then — resting requires nearby campfire
          not has_nearby_fogata?(state, entity) ->
            {:ok, state, [Effects.send(char_id, console("No hay fogata cerca."))]}

          true ->
            new_resting = not entity.resting
            entity = %{entity | resting: new_resting, meditating: false}
            players = Map.put(state.players, char_id, entity)
            msg = if new_resting, do: "Has comenzado a descansar.", else: "Has dejado de descansar."

            effects = [
              Effects.send(char_id, console(msg)),
              # VB6 Protocol.bas:1693 — WriteRestOK flips the client-side resting
              # animation. Sent regardless of direction (start or stop).
              Effects.send(char_id, Encoder.encode({:rest_ok, %{}}))
            ]

            {:ok, %{state | players: players}, effects}
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  def handle_meditate(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            {:ok, state, [Effects.send(char_id, console("Estas muerto."))]}

          # VB6: If .flags.Montado = 1 Then → "No podes meditar estando montado"
          entity.mounted ->
            {:ok, state, [Effects.send(char_id, console("No podes meditar estando montado."))]}

          entity.class not in @magical_classes ->
            {:ok, state, [Effects.send(char_id, console("Solo las clases magicas pueden meditar."))]}

          entity.mana >= entity.max_mana ->
            {:ok, state, [Effects.send(char_id, console("Tienes el mana completo."))]}

          true ->
            new_meditating = not entity.meditating
            entity = %{entity | meditating: new_meditating, resting: false}
            players = Map.put(state.players, char_id, entity)
            msg = if new_meditating, do: "Has comenzado a meditar.", else: "Has dejado de meditar."

            effects = [Effects.send(char_id, console(msg))]

            # VB6: show meditate FX (varies by level/faction; simplified to fx_id 4 here)
            effects =
              if new_meditating do
                fx = Encoder.encode({:create_fx, %{char_index: entity.char_index, fx: 4, loops: 0}})
                effects ++ [Effects.broadcast_visible_all(entity.x, entity.y, fx)]
              else
                effects
              end

            {:ok, %{state | players: players}, effects}
        end

      :error ->
        {:ok, state, []}
    end
  end

  def handle_heal(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            {:ok, state, [Effects.send(char_id, console("Estas muerto."))]}

          entity.hp >= entity.max_hp ->
            {:ok, state, [Effects.send(char_id, console("Estas sano."))]}

          true ->
            # VB6: heal is NPC interaction -- full heal from Revividor NPC.
            # VB6: If .pos.Map = MAP_HOME_IN_JAIL And NpcList(...).npcType = Revividor Then Exit Sub
            case selected_priest(state, entity, 10) do
              {:ok, _npc, npc_def} ->
                cond do
                  # VB6: If .pos.Map = MAP_HOME_IN_JAIL And NpcList(...).npcType = Revividor Then Exit Sub
                  state.map_id == @jail_map_id and npc_def.npc_type == @npc_type_revividor ->
                    {:ok, state,
                     [Effects.send(char_id, console("No puedes curarte en la carcel."))]}

                  true ->
                    entity = %{entity | hp: entity.max_hp}
                    players = Map.put(state.players, char_id, entity)

                    effects = [
                      Effects.send(char_id, console("Has sido curado.")),
                      Effects.send(
                        char_id,
                        Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})
                      )
                    ]

                    {:ok, %{state | players: players}, effects}
                end

              :not_found ->
                {:ok, state, [Effects.send(char_id, console("No hay un sacerdote cerca."))]}
            end
        end

      :error ->
        {:ok, state, []}
    end
  end

  def handle_resucitate(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          # VB6: resurrection requires Revividor NPC nearby
          case selected_priest(state, entity, 10) do
            {:ok, _npc, npc_def} ->
              # VB6: ResucitadorNewbie only serves newbies (level <= 12)
              if npc_def.npc_type == @npc_type_resucitador_newbie and entity.level > 12 do
                {:ok, state,
                 [Effects.send(char_id, console("Solo los newbies pueden ser resucitados aqui."))]}
              else
                # VB6: NPC resurrect does NOT zero mana (only spell-based revive does)
                entity = %{
                  entity
                  | dead: false,
                    hp: entity.max_hp,
                    buffs: [],
                    paralyzed: false,
                    poisoned: false,
                    invisible: false
                }

                players = Map.put(state.players, char_id, entity)
                state = %{state | players: players}

                fx_packet =
                  Encoder.encode({:create_fx, %{char_index: entity.char_index, fx: 15, loops: 0}})

                effects = [
                  Effects.send(
                    char_id,
                    Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})
                  ),
                  Effects.send(
                    char_id,
                    Encoder.encode({:update_mana, %{min_mana: entity.mana}})
                  ),
                  Effects.send(char_id, console("Has sido resucitado.")),
                  Effects.broadcast_character_change(entity),
                  Effects.broadcast_visible_all(entity.x, entity.y, fx_packet)
                ]

                {:ok, state, effects}
              end

            :not_found ->
              {:ok, state, [Effects.send(char_id, console("No hay un sacerdote cerca."))]}
          end
        else
          {:ok, state, [Effects.send(char_id, console("No estas muerto."))]}
        end

      :error ->
        {:ok, state, []}
    end
  end

  # VB6: HayOBJarea(.pos, FOGATA) — checks if a campfire ground object
  # exists within @fogata_radius tiles of the entity.
  defp has_nearby_fogata?(state, entity) do
    ground_items = state.ground_items || %{}

    Enum.any?(ground_items, fn {{gx, gy}, item} ->
      item.item_id == @fogata_obj_index and
        abs(gx - entity.x) <= @fogata_radius and
        abs(gy - entity.y) <= @fogata_radius
    end)
  end
end
