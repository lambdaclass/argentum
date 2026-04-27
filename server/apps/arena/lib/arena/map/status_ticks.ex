defmodule Arena.Map.StatusTicks do
  @moduledoc "Buff expiry, regen, hunger/thirst, and penalty ticks."

  alias Arena.Map.Helpers
  alias Arena.Data.GameData
  alias AoProtocol.Server.Encoder

  @poison_tick_interval 3600

  @hunger_thirst_damage 5
  # VB6: IntervaloSed = 4000/25 = 160s; at 3s regen tick = 54 ticks
  @thirst_drain_interval 54
  # VB6: IntervaloHambre = 4500/25 = 180s; at 3s regen tick = 60 ticks
  @hunger_drain_interval 60
  # VB6 drains hunger/thirst by 10 per interval (not 1)
  @hunger_thirst_drain_amount 10
  # VB6: penalty (jail) decrements by 1 per minute. Tick = 3s, so 20 ticks = 1 min.
  @penalty_decrement_interval 20

  def process_player_buffs(state, char_id, entity, now) do
    was_invisible = entity.invisible
    was_paralyzed = entity.paralyzed
    was_blind = entity.blind
    was_dumb = entity.dumb
    entity = tick_potion_duration(entity)
    {expired, active} = Enum.split_with(entity.buffs, fn b -> now >= b.expires_at end)

    # Clear flags for expired buffs
    entity =
      Enum.reduce(expired, entity, fn buff, ent ->
        case buff.type do
          :paralyzed -> %{ent | paralyzed: false}
          :blind -> %{ent | blind: false}
          :dumb -> %{ent | dumb: false}
          :poisoned -> %{ent | poisoned: false}
          :invisible -> %{ent | invisible: false}
          :oculto -> %{ent | oculto: false}
          :immobilized -> %{ent | immobilized: false}
          :str_buff -> %{ent | str_buff: max(ent.str_buff - (buff[:value] || 0), 0)}
          :agi_buff -> %{ent | agi_buff: max(ent.agi_buff - (buff[:value] || 0), 0)}
          _ -> ent
        end
      end)

    # VB6: when Paralisis counter expires (Modulo_UsUaRiOs.bas:2475) the server
    # sends WriteParalizeOK so the client exits the frozen animation.
    if was_paralyzed and not entity.paralyzed do
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw, Encoder.encode({:paralize_ok, %{}})}
      )
    end

    # VB6: when Ceguera counter expires the server sends WriteBlindNoMore so
    # the client clears the blindness overlay (modUsuarios EfectoCeguera path).
    if was_blind and not entity.blind do
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw, Encoder.encode({:blind_no_more, %{}})}
      )
    end

    # VB6: when Estupidez counter expires the server sends WriteDumbNoMore so
    # the client clears the silenced overlay (modUsuarios EfectoEstupidez path).
    if was_dumb and not entity.dumb do
      Helpers.send_to_session(
        state.sessions,
        char_id,
        {:send_raw, Encoder.encode({:dumb_no_more, %{}})}
      )
    end

    # Process poison ticks on active poison buffs
    {active, entity} =
      Enum.map_reduce(active, entity, fn buff, ent ->
        if buff.type == :poisoned and now >= (buff[:next_tick] || 0) do
          damage = max(Enum.random(3..5) * div(ent.max_hp, 100), 1)
          new_hp = max(ent.hp - damage, 0)
          ent = %{ent | hp: new_hp}

          Helpers.send_to_session(state.sessions, char_id, {:send_raw, Encoder.encode({:update_hp, %{min_hp: new_hp}})})

          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:console_msg, %{message: "Veneno te hace #{damage} de daño.", font_index: 5}})}
          )

          buff = %{buff | next_tick: now + @poison_tick_interval}
          {buff, ent}
        else
          {buff, ent}
        end
      end)

    entity = %{entity | buffs: active}

    # Check poison death
    was_alive = not entity.dead

    {entity, state} =
      if entity.hp <= 0 and was_alive do
        Helpers.send_to_session(
          state.sessions,
          char_id,
          {:send_raw, Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})}
        )

        {entity, state, pd_effects} =
          Arena.Map.PlayerDeath.handle_player_death(state, char_id, entity)

        Arena.Map.Effects.run(state, pd_effects)
        {entity, state}
      else
        {entity, state}
      end

    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}

    # Reveal player if invisibility just expired
    if was_invisible and not entity.invisible do
      Arena.Map.Visibility.reveal_to_non_gm(state, entity)
    end

    if was_alive and entity.dead do
      Helpers.broadcast_character_change(state, entity)
    end

    state
  end

  # Drift #18 — VB6 General.bas:1278-1297 (DuracionPociones). Called once
  # per second (1 s buff_tick = VB6 PasarSegundo). Decrements
  # flags.DuracionEfecto; on expiry restores UserAtributos from
  # UserAtributosBackUP and clears flags.TomoPocion. In Elixir the live
  # attribute is `*_base + *_buff`; we only subtract the potion-contributed
  # portion (`*_potion_delta`) so concurrent spell buffs survive.
  defp tick_potion_duration(entity) do
    duracion = Map.get(entity, :duracion_efecto, 0)

    cond do
      duracion > 1 ->
        %{entity | duracion_efecto: duracion - 1}

      duracion == 1 ->
        str_delta = Map.get(entity, :str_potion_delta, 0)
        agi_delta = Map.get(entity, :agi_potion_delta, 0)

        %{
          entity
          | duracion_efecto: 0,
            tomo_pocion: false,
            str_buff: entity.str_buff - str_delta,
            agi_buff: entity.agi_buff - agi_delta,
            str_potion_delta: 0,
            agi_potion_delta: 0
        }

      true ->
        entity
    end
  end

  def process_regen_tick(state) do
    # Separate counters for hunger and thirst (VB6 has AGUACounter / COMCounter).
    thirst_counter = state.thirst_tick_counter + 1
    drain_thirst? = thirst_counter >= @thirst_drain_interval
    thirst_counter = if drain_thirst?, do: 0, else: thirst_counter
    state = %{state | thirst_tick_counter: thirst_counter}

    hunger_counter = state.hunger_tick_counter + 1
    drain_hunger? = hunger_counter >= @hunger_drain_interval
    hunger_counter = if drain_hunger?, do: 0, else: hunger_counter
    state = %{state | hunger_tick_counter: hunger_counter}

    state = %{state | hunger_thirst_tick_counter: thirst_counter}

    # VB6: penalty (jail timer) decrements by 1 per minute
    penalty_counter = state.penalty_tick_counter + 1
    decrement_penalty? = penalty_counter >= @penalty_decrement_interval
    penalty_counter = if decrement_penalty?, do: 0, else: penalty_counter
    state = %{state | penalty_tick_counter: penalty_counter}

    Enum.reduce(state.players, state, fn {char_id, entity}, state ->
      if entity.dead do
        state
      else
        original_entity = state.players[char_id]
        was_invisible_before_regen = entity.invisible

        # VB6: decrement jail penalty every minute
        entity =
          if decrement_penalty? and entity.penalty > 0 do
            %{entity | penalty: entity.penalty - 1}
          else
            entity
          end

        # Decrement oculto timer; when it reaches 0, break oculto
        # Exception: hunters with 100% hiding skill + camo armor stay hidden
        entity =
          if entity.oculto and entity.oculto_timer > 0 do
            hiding_skill = Map.get(entity.skills, :hiding, 0)
            armor_id = entity.equipment[:armor]
            armor_def = if armor_id, do: GameData.get_item(armor_id)
            has_camo = armor_def != nil and armor_def.obj_type == 43

            if hiding_skill >= 100 and has_camo do
              entity
            else
              new_timer = entity.oculto_timer - 1

              if new_timer <= 0 do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has vuelto a ser visible.", font_index: 0}})}
                )

                %{entity | oculto: false, oculto_timer: 0, invisible: false}
              else
                %{entity | oculto_timer: new_timer}
              end
            end
          else
            entity
          end

        # Drain thirst and hunger on their own VB6-matched intervals.
        {entity, thirst_changed} =
          if drain_thirst? and entity.thirst > 0 do
            new_thirst = max(entity.thirst - @hunger_thirst_drain_amount, 0)
            {%{entity | thirst: new_thirst}, new_thirst != entity.thirst}
          else
            {entity, false}
          end

        {entity, hunger_changed} =
          if drain_hunger? and entity.hunger > 0 do
            new_hunger = max(entity.hunger - @hunger_thirst_drain_amount, 0)
            {%{entity | hunger: new_hunger}, new_hunger != entity.hunger}
          else
            {entity, false}
          end

        vitals_changed = thirst_changed or hunger_changed

        starving = entity.hunger == 0
        dehydrated = entity.thirst == 0

        # VB6: at 0 hunger or 0 thirst, drain stamina by 1 per tick
        entity =
          if (starving or dehydrated) and entity.stamina > 0 do
            %{entity | stamina: max(entity.stamina - 1, 0)}
          else
            entity
          end

        stamina_changed = entity.stamina != original_entity.stamina

        # VB6: HP damage only when stamina == 0 AND (starving or dehydrated)
        entity =
          cond do
            entity.stamina == 0 and starving and dehydrated ->
              %{entity | hp: max(entity.hp - @hunger_thirst_damage * 2, 0)}

            entity.stamina == 0 and (starving or dehydrated) ->
              %{entity | hp: max(entity.hp - @hunger_thirst_damage, 0)}

            true ->
              entity
          end

        hp_changed = entity.hp != original_entity.hp

        # Kill on starvation
        {entity, state} =
          if entity.hp <= 0 and not entity.dead do
            {entity, state, pd_effects} =
              Arena.Map.PlayerDeath.handle_player_death(state, char_id, %{entity | hp: 0})

            Arena.Map.Effects.run(state, pd_effects)
            {entity, state}
          else
            {entity, state}
          end

        # Regen (blocked by starvation/dehydration)
        entity =
          cond do
            starving or dehydrated ->
              entity

            entity.resting and entity.hp < entity.max_hp ->
              # VB6: rest regen = con / 6, min 1
              regen = max(div(entity.con, 6), 1)
              new_hp = min(entity.hp + regen, entity.max_hp)
              entity = %{entity | hp: new_hp}

              if new_hp >= entity.max_hp do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has terminado de descansar.", font_index: 0}})}
                )

                %{entity | resting: false}
              else
                entity
              end

            entity.meditating and entity.mana < entity.max_mana ->
              # VB6: meditate regen = int * meditation_skill / 35, min 1
              med_skill = Map.get(entity.skills, :meditation, 0)
              regen = max(div(entity.int * max(med_skill, 1), 35), 1)
              new_mana = min(entity.mana + regen, entity.max_mana)
              entity = %{entity | mana: new_mana}

              if new_mana >= entity.max_mana do
                Helpers.send_to_session(
                  state.sessions,
                  char_id,
                  {:send_raw, Encoder.encode({:console_msg, %{message: "Has terminado de meditar.", font_index: 0}})}
                )

                %{entity | meditating: false}
              else
                entity
              end

            true ->
              entity
          end

        # VB6: passive HP regen (1/5 of rest rate) when not resting
        entity =
          if not entity.resting and not (starving or dehydrated) and entity.hp < entity.max_hp do
            passive_hp = max(div(entity.con, 30), 1)
            %{entity | hp: min(entity.hp + passive_hp, entity.max_hp)}
          else
            entity
          end

        # VB6: passive mana regen when not meditating
        entity =
          if not entity.meditating and not (starving or dehydrated) and entity.mana < entity.max_mana do
            passive_mana = max(div(entity.int, 35), 1)
            %{entity | mana: min(entity.mana + passive_mana, entity.max_mana)}
          else
            entity
          end

        # VB6: stamina regen (agi-based, ~1-3 per tick)
        entity =
          if not (starving or dehydrated) and entity.stamina < entity.max_stamina do
            sta_regen = max(div(entity.agi, 6), 1)
            %{entity | stamina: min(entity.stamina + sta_regen, entity.max_stamina)}
          else
            entity
          end

        # Send updates
        if vitals_changed do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw,
             Encoder.encode(
               {:update_hunger_and_thirst,
                %{
                  max_hunger: 100,
                  min_hunger: entity.hunger,
                  max_thirst: 100,
                  min_thirst: entity.thirst
                }}
             )}
          )
        end

        if hp_changed or entity.hp != original_entity.hp do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:update_hp, %{min_hp: entity.hp, shield: 0}})}
          )
        end

        if entity.mana != original_entity.mana do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:update_mana, %{min_mana: entity.mana}})}
          )
        end

        if stamina_changed or entity.stamina != original_entity.stamina do
          Helpers.send_to_session(
            state.sessions,
            char_id,
            {:send_raw, Encoder.encode({:update_stamina, %{min_sta: entity.stamina}})}
          )
        end

        state =
          if entity.dead and not original_entity.dead do
            Helpers.send_to_session(
              state.sessions,
              char_id,
              {:send_raw, Encoder.encode({:console_msg, %{message: "Has muerto de inanición.", font_index: 0}})}
            )

            state = %{state | players: Map.put(state.players, char_id, entity)}
            Helpers.broadcast_character_change(state, entity)
            state
          else
            %{state | players: Map.put(state.players, char_id, entity)}
          end

        # Reveal player if oculto/invisible just expired during this tick
        if was_invisible_before_regen and not entity.invisible do
          Arena.Map.Visibility.reveal_to_non_gm(state, entity)
        end

        state
      end
    end)
  end
end
