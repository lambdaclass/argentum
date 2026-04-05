defmodule Arena.Map.Social do
  @moduledoc "Chat, social commands, stat requests, and NPC interaction."

  alias Arena.Map.{Helpers, Visibility}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_revividor 1
  @npc_type_banquero 4
  @npc_type_resucitador_newbie 9
  @yell_range_x (Application.compile_env(:arena, :aoi_range_x, 11)) * 2
  @yell_range_y (Application.compile_env(:arena, :aoi_range_y, 9)) * 2
  @magical_classes [:mage, :cleric, :druid, :bard, :paladin]

  # ==================================================================
  # Safe toggle
  # ==================================================================

  def handle_safe_toggle(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        new_safe = not entity.safe_mode
        entity = %{entity | safe_mode: new_safe}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        packet = if new_safe, do: {:safe_mode_on, %{}}, else: {:safe_mode_off, %{}}
        Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode(packet)})

        {:reply, :ok, state}

      :error -> {:reply, {:error, :not_on_map}, state}
    end
  end

  # ==================================================================
  # Chat / Social
  # ==================================================================

  def handle_chat(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        chat_raw = Encoder.encode({:chat_over_head, %{
          message: message,
          char_index: entity.char_index,
          color: 0x00FFFFFF,
          x: entity.x,
          y: entity.y,
          min_display_time: 2000,
          max_display_time: 5000
        }})

        # Send to nearby players including the speaker
        chat_recipients =
          Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
            send(pid, {:send_raw, chat_raw})
          end)

        Arena.Metrics.inc_chat(chat_recipients)

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_yell(state, char_id, message) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
          {:noreply, state}
        else
          # VB6: yelling breaks invisibility
          entity = Helpers.break_invisibility(entity, state, char_id)
          players = Map.put(state.players, char_id, entity)

          yell_raw = Encoder.encode({:chat_over_head, %{
            message: message,
            char_index: entity.char_index,
            color: 0x00FF0000,
            x: entity.x,
            y: entity.y,
            min_display_time: 3000,
            max_display_time: 6000
          }})

          Visibility.broadcast_range(%{state | players: players}, entity.x, entity.y, @yell_range_x, @yell_range_y, fn pid ->
            send(pid, {:send_raw, yell_raw})
          end)

          {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_rest(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
            {:noreply, state}

          entity.hp >= entity.max_hp ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas sano.", font_index: 0}})})
            {:noreply, state}

          true ->
            new_resting = not entity.resting
            entity = %{entity | resting: new_resting, meditating: false}
            players = Map.put(state.players, char_id, entity)

            msg = if new_resting, do: "Has comenzado a descansar.", else: "Has dejado de descansar."
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: msg, font_index: 0}})})

            {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_meditate(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
            {:noreply, state}

          entity.class not in @magical_classes ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Solo las clases magicas pueden meditar.", font_index: 0}})})
            {:noreply, state}

          entity.mana >= entity.max_mana ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Tienes el mana completo.", font_index: 0}})})
            {:noreply, state}

          true ->
            new_meditating = not entity.meditating
            entity = %{entity | meditating: new_meditating, resting: false}
            players = Map.put(state.players, char_id, entity)

            msg = if new_meditating, do: "Has comenzado a meditar.", else: "Has dejado de meditar."
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: msg, font_index: 0}})})

            # VB6: show meditate FX (varies by level/faction; simplified to fx_id 4 here)
            if new_meditating do
              Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
                send(pid, {:send_raw, Encoder.encode({:create_fx, %{char_index: entity.char_index, fx_id: 4, loops: 0}})})
              end)
            end

            {:noreply, %{state | players: players}}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_heal(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas muerto.", font_index: 0}})})
            {:noreply, state}

          entity.hp >= entity.max_hp ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas sano.", font_index: 0}})})
            {:noreply, state}

          true ->
            # VB6: heal is NPC interaction -- full heal from Revividor NPC.
            case find_nearby_npc_of_type(state, entity, [@npc_type_revividor, @npc_type_resucitador_newbie]) do
              {:ok, _npc, npc_def} ->
                # VB6: ResucitadorNewbie only serves newbies (level <= 12)
                if npc_def.npc_type == @npc_type_resucitador_newbie and entity.level > 12 do
                  Helpers.send_to_session(state.sessions, char_id,
                    {:send_raw, Encoder.encode({:console_msg, %{message: "Solo los newbies pueden ser curados aqui.", font_index: 0}})})
                  {:noreply, state}
                else
                  entity = %{entity | hp: entity.max_hp}
                  players = Map.put(state.players, char_id, entity)

                  Helpers.send_to_session(state.sessions, char_id,
                    {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido curado.", font_index: 0}})})
                  Helpers.send_to_session(state.sessions, char_id,
                    {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})})

                  {:noreply, %{state | players: players}}
                end

              :not_found ->
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un sacerdote cerca.", font_index: 0}})})
                {:noreply, state}
            end
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_resucitate(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          # VB6: resurrection requires Revividor NPC nearby
          case find_nearby_npc_of_type(state, entity, [@npc_type_revividor, @npc_type_resucitador_newbie]) do
            {:ok, _npc, npc_def} ->
              # VB6: ResucitadorNewbie only serves newbies (level <= 12)
              if npc_def.npc_type == @npc_type_resucitador_newbie and entity.level > 12 do
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Solo los newbies pueden ser resucitados aqui.", font_index: 0}})})
                {:noreply, state}
              else
                entity = %{entity |
                  dead: false,
                  hp: entity.max_hp,
                  mana: 0,
                  buffs: [],
                  paralyzed: false,
                  poisoned: false,
                  invisible: false
                }
                players = Map.put(state.players, char_id, entity)

                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.max_hp, shield: 0}})})
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:update_mana, %{min_mana: 0}})})
                Helpers.send_to_session(state.sessions, char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has sido resucitado.", font_index: 0}})})

                Visibility.broadcast_visible_all(state, entity.x, entity.y, fn pid ->
                  send(pid, {:send_raw, Encoder.encode({:create_fx, %{char_index: entity.char_index, fx_id: 15, loops: 0}})})
                end)

                {:noreply, %{state | players: players}}
              end

            :not_found ->
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "No hay un sacerdote cerca.", font_index: 0}})})
              {:noreply, state}
          end
        else
          Helpers.send_to_session(state.sessions, char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "No estas muerto.", font_index: 0}})})
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Stat requests
  # ==================================================================

  def handle_request_atributes(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:update_user_stats, %{
            max_hp: entity.max_hp,
            min_hp: entity.hp,
            shield: 0,
            max_mana: entity.max_mana,
            min_mana: entity.mana,
            max_sta: entity.max_stamina,
            min_sta: entity.stamina,
            gold: entity.gold,
            gold_cap: 1_000_000,
            level: entity.level,
            exp_next_level: GameData.exp_for_level(entity.level + 1) || 0,
            exp: entity.xp,
            class: Helpers.class_to_int(entity.class)
          }})})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_request_skills(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  @skill_order [
    :magic, :stealing, :combat_tactics, :combat_weapons, :meditation,
    :short_weapons, :hiding, :survival, :trading, :combat_defense,
    :leadership, :ranged_weapons, :wrestling, :navigation, :riding,
    :resistance, :woodcutting, :fishing, :mining, :blacksmithing,
    :carpentry, :alchemy, :tailoring, :taming
  ]

  def handle_train_skill(state, char_id, skill_index) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        skill_atom = Enum.at(@skill_order, skill_index)

        cond do
          skill_atom == nil ->
            {:noreply, state}

          entity.skill_points <= 0 ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "No tienes puntos de skill disponibles.", font_index: 0}})})
            {:noreply, state}

          Map.get(entity.skills, skill_atom, 0) >= 100 ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Ya tienes el maximo en esa habilidad.", font_index: 0}})})
            {:noreply, state}

          true ->
            current = Map.get(entity.skills, skill_atom, 0)
            entity = %{entity |
              skills: Map.put(entity.skills, skill_atom, current + 1),
              skill_points: entity.skill_points - 1
            }
            players = Map.put(state.players, char_id, entity)
            state = %{state | players: players}

            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:send_skills, %{skills: entity.skills}})})
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Skill points restantes: #{entity.skill_points}", font_index: 0}})})

            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_request_mini_stats(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        Helpers.send_to_session(state.sessions, char_id,
          {:send_raw, Encoder.encode({:mini_stats, %{
            ciudadanos_matados: 0,
            criminales_matados: 0,
            faction_status: if(entity.criminal, do: 1, else: 0),
            npcs_killed: 0,
            class: Helpers.class_to_int(entity.class),
            penalty: 0,
            deaths: 0,
            gender: if(entity.gender == :male, do: 1, else: 2),
            fishing_points: 0,
            race: Helpers.race_to_int(entity.race)
          }})})

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # ==================================================================
  # Double-click / NPC interaction
  # ==================================================================

  def handle_double_click(state, char_id, x, y) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.dead do
          {:noreply, state}
        else
          # VB6 uses distance <= 4 for most NPC interactions
          if abs(entity.x - x) <= 4 and abs(entity.y - y) <= 4 do
            case Helpers.get_occupancy(state.occupancy, x, y) do
              {:npc, instance_id} ->
                handle_npc_double_click(state, char_id, entity, instance_id)

              _ ->
                {:noreply, state}
            end
          else
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Estas demasiado lejos.", font_index: 0}})})
            {:noreply, state}
          end
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_npc_double_click(state, char_id, entity, instance_id) do
    case Map.get(state.npcs_live, instance_id) do
      nil ->
        {:noreply, state}

      npc ->
        npc_def = GameData.get_npc(npc.npc_id)

        cond do
          npc_def == nil ->
            {:noreply, state}

          # Shopkeeper -- open commerce
          npc_def.comercia ->
            GenServer.cast(self(), {:open_commerce_internal, char_id, entity.x, entity.y, npc, npc_def})
            {:noreply, state}

          # Revividor / ResucitadorNewbie -- show healer prompt
          npc_def.npc_type in [@npc_type_revividor, @npc_type_resucitador_newbie] ->
            if entity.dead do
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Puedo resucitarte. Usa el comando /resucitar.", font_index: 0}})})
            else
              Helpers.send_to_session(state.sessions, char_id,
                {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Puedo curarte. Usa el comando /curar.", font_index: 0}})})
            end
            {:noreply, state}

          # Banker
          npc_def.npc_type == @npc_type_banquero ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "#{npc_def.name} dice: Bienvenido al banco.", font_index: 0}})})
            {:noreply, state}

          # Default: show NPC name
          true ->
            Helpers.send_to_session(state.sessions, char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Ves a #{npc_def.name}.", font_index: 0}})})
            {:noreply, state}
        end
    end
  end

  def find_nearby_npc_of_type(state, entity, npc_types) do
    result =
      Enum.find_value(state.npcs_live, fn {_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)
        if npc_def != nil and
          npc_def.npc_type in npc_types and
          abs(npc.x - entity.x) <= 5 and
          abs(npc.y - entity.y) <= 5 do
          {npc, npc_def}
        end
      end)

    case result do
      {npc, npc_def} -> {:ok, npc, npc_def}
      nil -> :not_found
    end
  end
end
