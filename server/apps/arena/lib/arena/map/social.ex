defmodule Arena.Map.Social do
  @moduledoc """
  Chat, social commands, stat requests, NPC-gated stat panels.

  Every public top-level handler now follows the effects contract: it
  returns `{:ok, state, effects}` (or `{:ok, state, reply, effects}` for
  `handle_deduct_gold/3` whose downstream caller branches on the reply).
  The MapServer entries dispatch via `Arena.Map.Effects.run_handler/2` for
  casts, `run_handler_call/2` for `:ok`-replying calls, and
  `run_handler_call_reply/2` for calls whose reply is meaningful.
  """

  alias Arena.Clock
  alias Arena.Map.{Helpers, Faction, Effects}
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @npc_type_revividor 1
  @npc_type_banquero 4
  @npc_type_enlistador 5
  @npc_type_timbero 10

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

        {:ok, state, [Effects.send(char_id, Encoder.encode(packet))]}

      :error ->
        {:ok, state, []}
    end
  end

  # ==================================================================
  # Stat requests
  # ==================================================================

  def handle_request_atributes(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        effects = [
          Effects.send(
            char_id,
            Encoder.encode(
              {:update_user_stats,
               %{
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
               }}
            )
          ),
          Effects.send(
            char_id,
            Encoder.encode(
              {:send_atributes,
               %{
                 str: entity.str,
                 agi: entity.agi,
                 int: entity.int,
                 con: entity.con,
                 cha: entity.cha
               }}
            )
          )
        ]

        {:ok, state, effects}

      :error ->
        {:ok, state, []}
    end
  end

  def handle_request_skills(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        {:ok, state,
         [Effects.send(char_id, Encoder.encode({:send_skills, %{skills: entity.skills}}))]}

      :error ->
        {:ok, state, []}
    end
  end

  def handle_request_mini_stats(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        effects = [
          Effects.send(
            char_id,
            Encoder.encode(
              {:update_user_stats,
               %{
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
               }}
            )
          ),
          Effects.send(
            char_id,
            Encoder.encode(
              {:mini_stats,
               %{
                 ciudadanos_matados: entity.citizens_killed,
                 criminales_matados: entity.criminals_killed,
                 faction_status:
                   case Map.get(entity, :faction, :none) do
                     :royal_army -> 1
                     :chaos_legion -> 2
                     :none -> if entity.criminal, do: 3, else: 0
                   end,
                 npcs_killed: entity.npcs_killed,
                 class: Helpers.class_to_int(entity.class),
                 penalty: entity.penalty,
                 deaths: entity.deaths,
                 gender: if(entity.gender == :male, do: 1, else: 2),
                 fishing_points: entity.fishing_points,
                 race: Helpers.race_to_int(entity.race)
               }}
            )
          )
        ]

        {:ok, state, effects}

      :error ->
        {:ok, state, []}
    end
  end

  # ==================================================================
  # Move spell (VB6: reorder spell slots)
  # ==================================================================

  def handle_move_spell(state, char_id, upwards, slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        spells = entity.spells || []
        # Convert 1-based slot to 0-based index
        idx = slot - 1
        swap_idx = if upwards, do: idx - 1, else: idx + 1

        if idx >= 0 and idx < length(spells) and swap_idx >= 0 and swap_idx < length(spells) do
          a = Enum.at(spells, idx)
          b = Enum.at(spells, swap_idx)
          spells = spells |> List.replace_at(idx, b) |> List.replace_at(swap_idx, a)
          spell_cooldowns = swap_spell_cooldowns(entity.spell_cooldowns, idx + 1, swap_idx + 1)
          entity = %{entity | spells: spells, spell_cooldowns: spell_cooldowns}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          effects = [
            spell_slot_effect(char_id, spells, idx),
            spell_slot_effect(char_id, spells, swap_idx)
          ]

          {:ok, state, effects}
        else
          {:ok, state, []}
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp spell_slot_effect(char_id, spells, idx) do
    spell_id = Enum.at(spells, idx) || 0
    Effects.send(
      char_id,
      Encoder.encode({:change_spell_slot, %{slot: idx + 1, spell_id: spell_id}})
    )
  end

  defp swap_spell_cooldowns(cooldowns, slot_a, slot_b) do
    cooldown_a = Map.get(cooldowns, slot_a)
    cooldown_b = Map.get(cooldowns, slot_b)

    cooldowns
    |> put_or_delete_cooldown(slot_a, cooldown_b)
    |> put_or_delete_cooldown(slot_b, cooldown_a)
  end

  defp put_or_delete_cooldown(cooldowns, slot, nil), do: Map.delete(cooldowns, slot)
  defp put_or_delete_cooldown(cooldowns, slot, value), do: Map.put(cooldowns, slot, value)

  # ==================================================================
  # Modify skills (VB6: distribute skill points from stats screen)
  # ==================================================================

  @skill_order [
    :magic,
    :stealing,
    :combat_tactics,
    :combat_weapons,
    :meditation,
    :short_weapons,
    :hiding,
    :survival,
    :trading,
    :combat_defense,
    :leadership,
    :ranged_weapons,
    :wrestling,
    :navigation,
    :riding,
    :resistance,
    :woodcutting,
    :fishing,
    :mining,
    :blacksmithing,
    :carpentry,
    :alchemy,
    :tailoring,
    :taming
  ]

  def handle_modify_skills(state, char_id, points_list) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            {:ok, state, [Effects.send(char_id, console("Estas muerto!"))]}

          # Reject any negative values in the list
          Enum.any?(points_list, &(&1 < 0)) ->
            {:ok, state, [Effects.send(char_id, console("Valores invalidos."))]}

          true ->
            # Sum requested points — must not exceed available skill_points
            total_requested = Enum.sum(points_list)

            if total_requested <= 0 or total_requested > entity.skill_points do
              {:ok, state,
               [Effects.send(char_id, console("No tienes suficientes puntos de habilidad."))]}
            else
              # Apply points to skills, capping each at 100
              {new_skills, points_used} =
                @skill_order
                |> Enum.zip(points_list)
                |> Enum.reduce({entity.skills, 0}, fn {skill_atom, pts}, {skills, used} ->
                  if pts > 0 do
                    current = Map.get(skills, skill_atom, 0)
                    add = min(pts, 100 - current)

                    if add > 0 do
                      {Map.put(skills, skill_atom, current + add), used + add}
                    else
                      {skills, used}
                    end
                  else
                    {skills, used}
                  end
                end)

              entity = %{
                entity
                | skills: new_skills,
                  skill_points: entity.skill_points - points_used
              }

              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              {:ok, state,
               [
                 Effects.send(
                   char_id,
                   Encoder.encode({:send_skills, %{skills: entity.skills}})
                 )
               ]}
            end
        end

      :error ->
        {:ok, state, []}
    end
  end

  # ==================================================================
  # Change description
  # ==================================================================

  @max_description_length 200

  def handle_change_description(state, char_id, desc) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, [Effects.send(char_id, console("Estas muerto."))]}

      {:ok, entity} ->
        desc = String.slice(desc, 0, @max_description_length)
        entity = %{entity | description: desc}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}
        {:ok, state, [Effects.send(char_id, console("Descripcion cambiada."))]}

      :error ->
        {:ok, state, []}
    end
  end

  # ==================================================================
  # Spell info (VB6: show spell details for a slot)
  # ==================================================================

  def handle_spell_info(state, char_id, slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        idx = slot - 1
        spell_id = Enum.at(entity.spells || [], idx)

        message =
          if spell_id && spell_id > 0 do
            case GameData.get_spell(spell_id) do
              nil ->
                "Hechizo no encontrado."

              spell_def ->
                info = "#{spell_def.name} - Mana: #{spell_def.mana_required}"

                if spell_def.min_hp && spell_def.min_hp > 0 do
                  info <> " - Daño: #{spell_def.min_hp}-#{spell_def.max_hp}"
                else
                  info
                end
            end
          else
            "No hay hechizo en ese slot."
          end

        {:ok, state, [Effects.send(char_id, console(message))]}

      :error ->
        {:ok, state, []}
    end
  end

  # ==================================================================
  # Move item (swap inventory slots)
  # ==================================================================

  def handle_move_item(state, char_id, from_slot, to_slot) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        inv = entity.inventory || []
        from_idx = from_slot - 1
        to_idx = to_slot - 1

        if from_idx >= 0 and from_idx < length(inv) and to_idx >= 0 and to_idx < length(inv) do
          a = Enum.at(inv, from_idx)
          b = Enum.at(inv, to_idx)
          inv = inv |> List.replace_at(from_idx, b) |> List.replace_at(to_idx, a)
          entity = %{entity | inventory: inv}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          effects = [
            inventory_slot_effect(char_id, inv, from_idx),
            inventory_slot_effect(char_id, inv, to_idx)
          ]

          {:ok, state, effects}
        else
          {:ok, state, []}
        end

      :error ->
        {:ok, state, []}
    end
  end

  # ==================================================================
  # Modify gold (add or subtract)
  # ==================================================================

  def handle_modify_gold(state, char_id, amount) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, []}

      {:ok, entity} ->
        new_gold = max(entity.gold + amount, 0)
        entity = %{entity | gold: new_gold}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        {:ok, state,
         [Effects.send(char_id, Encoder.encode({:update_gold, %{gold: new_gold}}))]}

      :error ->
        {:ok, state, []}
    end
  end

  @doc """
  Atomically deduct gold from a player.

  Returns `{:ok, state, reply, effects}` where `reply` is `{:ok, new_gold}`
  or `{:error, reason}`. The MapServer dispatches this via
  `Effects.run_handler_call_reply/2`, which surfaces `reply` to the caller
  unchanged. Used by transfer_gold / donate_gold to avoid TOCTOU races
  where snapshot_entity reads gold then async modify fires later.
  """
  def handle_deduct_gold(state, char_id, amount) when amount > 0 do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, {:error, :dead}, []}

      {:ok, entity} when entity.gold >= amount ->
        new_gold = entity.gold - amount
        entity = %{entity | gold: new_gold}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        effects = [
          Effects.send(char_id, Encoder.encode({:update_gold, %{gold: new_gold}}))
        ]

        {:ok, state, {:ok, new_gold}, effects}

      {:ok, _entity} ->
        {:ok, state, {:error, :not_enough_gold}, []}

      :error ->
        {:ok, state, {:error, :not_on_map}, []}
    end
  end

  def handle_deduct_gold(state, _char_id, _amount) do
    {:ok, state, {:error, :invalid_amount}, []}
  end

  # ==================================================================
  # Marriage system (VB6: HandleCasamiento)
  # ==================================================================

  @doc """
  Handle a marriage proposal.

  VB6 flow (Protocol.bas HandleCasamiento):
  1. Target must be online (on same map)
  2. Proposer must have clicked a priest NPC (Revividor, type 1)
  3. Priest must be within 10 tiles
  4. Cannot marry yourself
  5. Proposer must not already be married
  6. Target must not already be married
  7. If target already proposed to proposer (mutual), marry them
  8. Otherwise, set proposer's candidato = target, notify target
  """
  def handle_propose_marriage(state, char_id, target_char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        case Map.fetch(state.players, target_char_id) do
          {:ok, target_entity} ->
            do_propose_marriage(state, char_id, entity, target_char_id, target_entity)

          :error ->
            {:ok, state,
             [Effects.send(char_id, console("El jugador no se encuentra en este mapa."))]}
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp do_propose_marriage(state, char_id, entity, target_char_id, target_entity) do
    priest_result = Helpers.resolve_selected_npc(state, entity, [@npc_type_revividor], 10)

    cond do
      # Must be near a priest
      priest_result == :not_found ->
        {:ok, state, [Effects.send(char_id, console("Primero haz click sobre un sacerdote."))]}

      # Cannot marry yourself
      char_id == target_char_id ->
        {:ok, state, [Effects.send(char_id, console("No puedes casarte contigo mismo."))]}

      # Proposer already married
      entity.spouse_id != 0 and entity.spouse_id != nil ->
        {:ok, state,
         [
           Effects.send(
             char_id,
             console(
               "Ya estas casado! Debes divorciarte de tu actual pareja para casarte nuevamente."
             )
           )
         ]}

      # Target already married
      target_entity.spouse_id != 0 and target_entity.spouse_id != nil ->
        {:ok, state,
         [
           Effects.send(
             char_id,
             console("Tu pareja debe divorciarse antes de tomar tu mano en matrimonio.")
           )
         ]}

      # Mutual proposal: target already proposed to us -> marry!
      target_entity.marriage_proposal_target == char_id ->
        # Set both as married
        entity = %{entity | spouse_id: target_entity.char_id, marriage_proposal_target: nil}

        target_entity = %{
          target_entity
          | spouse_id: entity.char_id,
            marriage_proposal_target: nil
        }

        players =
          state.players
          |> Map.put(char_id, entity)
          |> Map.put(target_char_id, target_entity)

        state = %{state | players: players}

        # Broadcast marriage announcement (VB6: SendData ToAll)
        announce =
          "El sacerdote celebra el casamiento entre #{entity.name} y #{target_entity.name}."

        # Congratulations to both (VB6: Msg1414/1415)
        congrats = "Los declaro unidos en legal matrimonio. Felicidades!"

        effects = [
          Effects.broadcast_map(console(announce)),
          Effects.send(char_id, console(congrats)),
          Effects.send(target_char_id, console(congrats))
        ]

        {:ok, state, effects}

      # First proposal: set candidato, notify target
      true ->
        entity = %{entity | marriage_proposal_target: target_char_id}
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}

        effects = [
          Effects.send(
            char_id,
            console("La solicitud de casamiento ha sido enviada a #{target_entity.name}.")
          ),
          # VB6: Msg1956
          Effects.send(
            target_char_id,
            console(
              "#{entity.name} desea casarse contigo, para permitirlo haz click en el sacerdote y escribe /PROPONER #{entity.name}."
            )
          )
        ]

        {:ok, state, effects}
    end
  end

  # ==================================================================
  # Ocultarse (hiding skill) — drift #30 VB6 parity
  # ==================================================================

  # VB6: iFragataFantasmal = 87
  @ghost_ship_body 87
  # VB6: HideAfterHitTime — cooldown after attacking before hiding is allowed (ms)
  @hide_after_hit_cooldown_ms 3_000
  # VB6: IntervaloOculto = 36_000 (server tick intervals, ~1s each)
  @intervalo_oculto 36_000

  @doc """
  VB6 cubic polynomial success chance.

  Formula: `(((0.000002 * Skill - 0.0002) * Skill + 0.0064) * Skill + 0.1124) * 100`
  Returns a float in [0, 100].
  """
  def hiding_success_chance(skill) do
    (((0.000002 * skill - 0.0002) * skill + 0.0064) * skill + 0.1124) * 100
  end

  @doc """
  VB6 class-specific hide duration range.

  Returns `{min_ticks, max_ticks}`.
  - Bandit/Thief: random range `[base/2.5, base/2]`
  - Hunter: exactly `base/2`
  - Others: exactly `base/3`
  - Pirate navigating: full IntervaloOculto

  Accepts `opts` keyword list; when `navigating: true` is set,
  pirate class gets full `@intervalo_oculto`.
  """
  def hiding_duration_range(class, skill, opts \\ []) do
    navigating = Keyword.get(opts, :navigating, false)

    if navigating and class == :pirate do
      {@intervalo_oculto, @intervalo_oculto}
    else
      base = hiding_duration_base(skill)

      case class do
        c when c in [:bandit, :thief] ->
          {trunc(base / 2.5), trunc(base / 2)}

        :hunter ->
          val = trunc(base / 2)
          {val, val}

        _other ->
          val = trunc(base / 3)
          {val, val}
      end
    end
  end

  @doc """
  Apply ghost-ship body for pirate navigating, identity otherwise.
  """
  def apply_hiding_body(entity) do
    if entity.navigating and entity.class == :pirate do
      %{entity | body_id: @ghost_ship_body}
    else
      entity
    end
  end

  # VB6 duration base polynomial:
  #   Suerte = (-0.000001*(100-Skill)^3) + (0.00009229*(100-Skill)^2) + (-0.0088*(100-Skill)) + 0.9571
  #   Suerte = Suerte * IntervaloOculto
  defp hiding_duration_base(skill) do
    inv = 100 - skill
    suerte = -0.000001 * :math.pow(inv, 3)
    suerte = suerte + 0.00009229 * :math.pow(inv, 2)
    suerte = suerte + -0.0088 * inv
    suerte = suerte + 0.9571
    suerte * @intervalo_oculto
  end

  def handle_ocultarse(state, char_id, skill_level, opts \\ []) do
    now = Keyword.get(opts, :now, Clock.now_ms())

    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        cond do
          entity.dead ->
            {:ok, state, [Effects.send(char_id, console("Estas muerto!"))]}

          entity.oculto ->
            {:ok, state, [Effects.send(char_id, console("Ya estas oculto."))]}

          skill_level < 1 ->
            {:ok, state,
             [Effects.send(char_id, console("No tienes habilidad suficiente para ocultarte."))]}

          # VB6: non-pirate cannot hide while navigating
          entity.navigating and entity.class != :pirate ->
            {:ok, state,
             [Effects.send(char_id, console("No puedes ocultarte mientras navegas."))]}

          # VB6: recent-hit cooldown — block hiding if attacked too recently
          now - entity.last_attacked_at < @hide_after_hit_cooldown_ms ->
            {:ok, state,
             [Effects.send(char_id, console("No puedes ocultarte tan pronto despues de atacar."))]}

          true ->
            # VB6: nonlinear cubic polynomial success roll
            chance = hiding_success_chance(skill_level)

            if :rand.uniform(100) <= chance do
              # VB6: class-specific duration
              {min_d, max_d} =
                hiding_duration_range(entity.class, skill_level, navigating: entity.navigating)

              timer =
                if min_d == max_d do
                  max(min_d, 1)
                else
                  max(Enum.random(min_d..max_d), 1)
                end

              # VB6: pirate navigating sets ghost-ship body
              entity = apply_hiding_body(entity)

              entity = %{entity | oculto: true, oculto_timer: timer, invisible: true}
              players = Map.put(state.players, char_id, entity)
              state = %{state | players: players}

              message =
                if entity.navigating and entity.class == :pirate do
                  "Te has camuflado como barco fantasma!"
                else
                  "Te has ocultado entre las sombras."
                end

              effects = [
                Effects.hide_from_non_gm(entity),
                Effects.send(char_id, console(message))
              ]

              {:ok, state, effects}
            else
              {:ok, state, [Effects.send(char_id, console("No has logrado ocultarte."))]}
            end
        end

      :error ->
        {:ok, state, []}
    end
  end

  # ==================================================================
  # Forum (double-click on forum object) — task 44
  # ==================================================================

  def handle_forum_open(state, char_id, forum_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, _entity} ->
        messages = Arena.Forum.get_messages(forum_id)

        raw =
          Encoder.encode(
            {:show_forum_form,
             %{
               forum_id: forum_id,
               messages: messages
             }}
          )

        # The {:set_viewing_forum, forum_id} message is a session-state
        # update (not an outbound packet) — keep it as a direct send to
        # the session pid via the legacy shim. Migrating it would require
        # a new effect kind for an in-band session-state message that no
        # other handler emits.
        Helpers.send_to_session(state.sessions, char_id, {:set_viewing_forum, forum_id})

        {:ok, state, [Effects.send(char_id, raw)]}

      :error ->
        {:ok, state, []}
    end
  end

  @doc """
  Handle divorce.

  VB6 uses a special potion, but we also support a /DIVORCIAR command.
  Both players must be on the same map. Sets spouse_id = 0 on both.
  """
  def handle_divorce(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} ->
        if entity.spouse_id == 0 or entity.spouse_id == nil do
          {:ok, state, [Effects.send(char_id, console("No estas casado."))]}
        else
          spouse_id = entity.spouse_id

          entity = %{entity | spouse_id: 0, marriage_proposal_target: nil}
          players = Map.put(state.players, char_id, entity)
          state = %{state | players: players}

          # Try to update spouse if on same map
          case Map.fetch(state.players, spouse_id) do
            {:ok, spouse_entity} ->
              spouse_entity = %{spouse_entity | spouse_id: 0, marriage_proposal_target: nil}
              players = Map.put(state.players, spouse_id, spouse_entity)
              state = %{state | players: players}

              effects = [
                Effects.send(char_id, console("Te has divorciado.")),
                Effects.send(spouse_id, console("#{entity.name} se ha divorciado de ti."))
              ]

              {:ok, state, effects}

            :error ->
              # Spouse offline or on another map -- only clear our side
              {:ok, state, [Effects.send(char_id, console("Te has divorciado."))]}
          end
        end

      :error ->
        {:ok, state, []}
    end
  end

  # ==================================================================
  # Account state — VB6: HandleRequestAccountState
  # Banker shows bank gold, Timbero shows gambling stats.
  # ==================================================================

  def handle_request_account_state(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, [Effects.send(char_id, console("No puedes hacer eso estando muerto."))]}

      {:ok, entity} ->
        case Helpers.selected_npc(state, entity) do
          {:ok, npc, npc_def} ->
            cond do
              npc_def.npc_type == @npc_type_banquero and
                  Helpers.within_vb6_distance?(entity, npc, 3) ->
                bank_gold = Map.get(entity, :bank_gold, 0)

                {:ok, state,
                 [
                   Effects.send(
                     char_id,
                     console("Tenes #{bank_gold} monedas de oro en tu cuenta.")
                   )
                 ]}

              npc_def.npc_type == @npc_type_timbero and
                  Helpers.within_vb6_distance?(entity, npc, 3) ->
                # VB6: HandleRequestAccountState shows three separate gambling counters
                wins = Map.get(entity, :gamble_wins, 0)
                losses = Map.get(entity, :gamble_losses, 0)
                plays = Map.get(entity, :gamble_plays, 0)

                effects = [
                  Effects.send(char_id, console("Apuestas ganadas: #{wins}")),
                  Effects.send(char_id, console("Apuestas perdidas: #{losses}")),
                  Effects.send(char_id, console("Veces jugadas: #{plays}"))
                ]

                {:ok, state, effects}

              npc_def.npc_type in [@npc_type_banquero, @npc_type_timbero] ->
                {:ok, state, [Effects.send(char_id, console("Estas demasiado lejos."))]}

              true ->
                {:ok, state,
                 [
                   Effects.send(
                     char_id,
                     console(
                       "Primero debes seleccionar un personaje, haz click izquierdo sobre el."
                     )
                   )
                 ]}
            end

          {:error, _reason} ->
            {:ok, state,
             [
               Effects.send(
                 char_id,
                 console(
                   "Primero debes seleccionar un personaje, haz click izquierdo sobre el."
                 )
               )
             ]}
        end

      :error ->
        {:ok, state, []}
    end
  end

  # ==================================================================
  # Reward — VB6: HandleReward requires targeting enlistador NPC
  # ==================================================================

  def handle_request_reward(state, char_id) do
    case Map.fetch(state.players, char_id) do
      {:ok, entity} when entity.dead ->
        {:ok, state, [Effects.send(char_id, console("No puedes hacer eso estando muerto."))]}

      {:ok, entity} ->
        case Helpers.selected_npc(state, entity) do
          {:ok, npc, npc_def} ->
            cond do
              npc_def.npc_type != @npc_type_enlistador ->
                {:ok, state,
                 [
                   Effects.send(
                     char_id,
                     console(
                       "Primero debes seleccionar un personaje, haz click izquierdo sobre el."
                     )
                   )
                 ]}

              not Helpers.within_vb6_distance?(entity, npc, 4) ->
                {:ok, state, [Effects.send(char_id, console("Estas demasiado lejos."))]}

              entity.faction == :none ->
                {:ok, state, [Effects.send(char_id, console("No perteneces a ninguna faccion."))]}

              Faction.npc_faccion_to_atom(npc_def.faccion) != entity.faction ->
                {:ok, state,
                 [Effects.send(char_id, console("Este enlistador no pertenece a tu faccion."))]}

              true ->
                # VB6: HandleReward — check faction_score & level vs rank
                # requirements, then award rank-up + items for any newly-
                # qualified rank. Faction is on the effects contract: it
                # returns `{:ok, state, effects}` and we surface those
                # effects directly to the runner.
                Faction.handle_faction_rank_up(state, char_id, entity, entity.faction)
            end

          {:error, _reason} ->
            {:ok, state,
             [
               Effects.send(
                 char_id,
                 console(
                   "Primero debes seleccionar un personaje, haz click izquierdo sobre el."
                 )
               )
             ]}
        end

      :error ->
        {:ok, state, []}
    end
  end

  defp console(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  defp inventory_slot_effect(char_id, inv, idx) do
    raw = inventory_slot_packet(inv, idx)
    Effects.send(char_id, raw)
  end

  # Mirror of `Helpers.send_inventory_slot/4` packet construction (without
  # the send_to_session shim). Inlined here to keep effect production in
  # the handler module.
  defp inventory_slot_packet(inventory, idx) do
    case Enum.at(inventory, idx) do
      nil ->
        Encoder.encode({:change_inventory_slot, %{slot: idx + 1, obj_index: 0, amount: 0}})

      item ->
        item_def = GameData.get_item(item.item_id)
        valor = if item_def, do: item_def.valor, else: 0
        instance_tags = Map.get(item, :elemental_tags, 0)

        Encoder.encode(
          {:change_inventory_slot,
           %{
             slot: idx + 1,
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
